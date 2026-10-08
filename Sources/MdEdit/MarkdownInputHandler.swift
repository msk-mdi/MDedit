import AppKit
import MarkdownKit

/// The typing affordances that make markdown pleasant to write by hand:
/// lists that continue themselves, Tab that indents an item, and delimiters
/// that pair up around a selection.
@MainActor
struct MarkdownInputHandler {
    let storage: MarkdownTextStorage

    /// Pairs that wrap a selection, or auto-close on an empty one.
    private static let pairs: [String: String] = [
        "*": "*", "_": "_", "`": "`", "[": "]", "(": ")", "\"": "\"", "~": "~",
    ]

    /// Handles Return, Tab and Shift-Tab. Returns true when it consumed the key.
    func handleCommand(_ selector: Selector, in textView: NSTextView) -> Bool {
        // Inside a table, Tab, Shift-Tab and Return move between cells and rows.
        let table = TableEditor(storage: storage, textView: textView)
        switch selector {
        case #selector(NSResponder.insertTab(_:)) where table.isInTable:
            return table.moveToNextCell()
        case #selector(NSResponder.insertBacktab(_:)) where table.isInTable:
            return table.moveToPreviousCell()
        case #selector(NSResponder.insertNewline(_:)) where table.isInTable && textView.selectedRange().length == 0:
            return table.insertNewline()
        default:
            break
        }
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            return continueBlock(in: textView)
        case #selector(NSResponder.insertTab(_:)):
            return changeIndent(by: 1, in: textView)
        case #selector(NSResponder.insertBacktab(_:)):
            return changeIndent(by: -1, in: textView)
        case #selector(NSResponder.deleteBackward(_:)):
            return deleteEmptyPair(in: textView)
        default:
            return false
        }
    }

    /// Return inside a list or quote repeats its marker; on an empty item it
    /// removes the marker instead, which is how you leave a list.
    private func continueBlock(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }

        let line = storage.line(at: selection.location)
        guard let info = storage.structure.info(forLine: line) else { return false }
        let lineRange = storage.structure.index.range(ofLine: line)
        let text = storage.string as NSString
        let characters = storage.structure.characters(of: text, line: line)

        // Only continue when the caret is at the end of the line's content.
        let contentEnd = lineRange.location + characters.count
        guard selection.location == contentEnd else { return false }

        let prefixLength: Int
        switch info.kind {
        case .listItem:
            prefixLength = info.contentStart
        case .paragraph where info.quoteDepth > 0:
            prefixLength = info.contentStart
        default:
            return false
        }

        // An empty item ends the list rather than making another one.
        if info.contentStart >= characters.count {
            let replaceRange = NSRange(location: lineRange.location, length: characters.count)
            guard textView.shouldChangeText(in: replaceRange, replacementString: "") else { return true }
            textView.insertText("", replacementRange: replaceRange)
            return true
        }

        var prefix = string(characters, from: 0, to: prefixLength)
        // A numbered item continues with the next number.
        if case .listItem(true, _) = info.kind {
            prefix = incrementOrderedMarker(prefix)
        }
        // A finished task starts the next one unchecked.
        prefix = prefix.replacingOccurrences(of: "[x]", with: "[ ]")
            .replacingOccurrences(of: "[X]", with: "[ ]")

        let insertion = "\n" + prefix
        guard textView.shouldChangeText(in: selection, replacementString: insertion) else { return true }
        textView.insertText(insertion, replacementRange: selection)
        return true
    }

    /// Tab indents the list item the caret is in; elsewhere it inserts spaces.
    private func changeIndent(by direction: Int, in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        let firstLine = storage.line(at: selection.location)
        let lastLine = storage.line(at: NSMaxRange(selection))

        var isList = false
        for line in firstLine...lastLine {
            if case .listItem? = storage.structure.info(forLine: line)?.kind { isList = true }
        }
        guard isList else {
            guard direction > 0, selection.length == 0 else { return false }
            textView.insertText("    ", replacementRange: selection)
            return true
        }

        let text = storage.string as NSString
        let start = storage.structure.index.range(ofLine: firstLine).location
        let end = NSMaxRange(storage.structure.index.range(ofLine: lastLine))
        let range = NSRange(location: start, length: end - start)

        var lines = text.substring(with: range).components(separatedBy: "\n")
        let hadTrailingNewline = lines.last == ""
        if hadTrailingNewline { lines.removeLast() }

        lines = lines.map { line in
            if direction > 0 { return "  " + line }
            if line.hasPrefix("  ") { return String(line.dropFirst(2)) }
            if line.hasPrefix(" ") { return String(line.dropFirst()) }
            return line
        }

        var replacement = lines.joined(separator: "\n")
        if hadTrailingNewline { replacement += "\n" }
        guard replacement != text.substring(with: range) else { return true }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return true }
        textView.insertText(replacement, replacementRange: range)

        let shift = direction > 0 ? 2 : -2
        textView.setSelectedRange(NSRange(
            location: max(start, selection.location + shift),
            length: selection.length
        ))
        return true
    }

    /// Brackets that close themselves as you type the opening one.
    private static let autoPairs: [String: String] = ["(": ")", "[": "]", "{": "}", "`": "`"]

    static let autoPairDefaultsKey = "autoPairBrackets"

    private var autoPairEnabled: Bool {
        UserDefaults.standard.object(forKey: Self.autoPairDefaultsKey) as? Bool ?? true
    }

    /// Wraps a selection in a delimiter. With no selection, types over a
    /// closing bracket that is already there, or closes a new pair.
    func handleInsertion(of input: String, in textView: NSTextView, range: NSRange) -> Bool {
        if range.length == 0 {
            return autoPairEnabled && handleTyping(input, in: textView, at: range.location)
        }
        guard let closing = Self.pairs[input] else { return false }

        let text = storage.string as NSString
        let selected = text.substring(with: range)
        let replacement = input + selected + closing
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return true }
        textView.insertText(replacement, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + input.utf16.count, length: range.length))
        return true
    }

    private func handleTyping(_ input: String, in textView: NSTextView, at location: Int) -> Bool {
        let text = storage.string as NSString
        let next: String? = location < text.length ? text.substring(with: NSRange(location: location, length: 1)) : nil
        let previous: String? = location > 0 ? text.substring(with: NSRange(location: location - 1, length: 1)) : nil

        // Typing the closer that auto-pairing put there just steps over it.
        if Self.autoPairs.values.contains(input), next == input {
            textView.setSelectedRange(NSRange(location: location + 1, length: 0))
            return true
        }

        guard let closing = Self.autoPairs[input] else { return false }
        // Only pair where a pair makes sense: before space, end of line or a closer.
        if let next, !(next.first?.isWhitespace ?? false), !")]}".contains(next) { return false }
        // A backtick after a word or another backtick is a closer or a fence.
        if input == "`", let previous, previous == "`" || (previous.first?.isLetter ?? false) || (previous.first?.isNumber ?? false) {
            return false
        }
        let pair = input + closing
        let range = NSRange(location: location, length: 0)
        guard textView.shouldChangeText(in: range, replacementString: pair) else { return true }
        textView.insertText(pair, replacementRange: range)
        textView.setSelectedRange(NSRange(location: location + input.utf16.count, length: 0))
        return true
    }

    /// Backspace between `(` and `)` removes both.
    private func deleteEmptyPair(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard autoPairEnabled, selection.length == 0, selection.location > 0 else { return false }
        let text = storage.string as NSString
        guard selection.location < text.length else { return false }
        let pairRange = NSRange(location: selection.location - 1, length: 2)
        let pair = text.substring(with: pairRange)
        guard let opening = pair.first.map(String.init), Self.autoPairs[opening] == String(pair.dropFirst()) else { return false }
        guard textView.shouldChangeText(in: pairRange, replacementString: "") else { return true }
        textView.insertText("", replacementRange: pairRange)
        return true
    }

    /// `3. ` after `2. `.
    private func incrementOrderedMarker(_ prefix: String) -> String {
        guard let range = prefix.range(of: #"\d+"#, options: .regularExpression),
              let value = Int(prefix[range])
        else { return prefix }
        return prefix.replacingCharacters(in: range, with: String(value + 1))
    }

    private func string(_ characters: [UInt16], from start: Int, to end: Int) -> String {
        guard start < end, end <= characters.count else { return "" }
        return String(decoding: characters[start..<end], as: UTF16.self)
    }
}
