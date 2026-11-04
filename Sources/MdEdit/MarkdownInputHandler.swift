import AppKit
import MarkdownKit

/// The typing affordances that make markdown pleasant to write by hand:
/// lists that continue themselves, Tab that indents an item, delimiters
/// that pair up around a selection, emphasis that closes itself, and code
/// blocks that type like a code editor.
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
            return deleteEmptyPair(in: textView) || deleteCodeIndent(in: textView)
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
        let text = storage.text
        let characters = storage.structure.characters(of: text, line: line)

        // In code, a new line starts at the same indentation (and inside the
        // same quote), one level deeper after an opening bracket; between a
        // bracket pair, the closer moves to a line of its own.
        if info.kind == .codeLine || info.kind == .indentedCode {
            let prefixEnd = min(info.contentStart, characters.count)
            var indentEnd = prefixEnd
            while indentEnd < characters.count, characters[indentEnd] == 0x20 || characters[indentEnd] == 0x09 { indentEnd += 1 }
            let caretOffset = selection.location - lineRange.location
            let base = string(characters, from: 0, to: min(indentEnd, caretOffset))

            var before = caretOffset - 1
            while before >= prefixEnd, characters[before] == 0x20 || characters[before] == 0x09 { before -= 1 }
            var after = caretOffset
            while after < characters.count, characters[after] == 0x20 || characters[after] == 0x09 { after += 1 }
            let opener: UInt16? = before >= prefixEnd ? characters[before] : nil
            let closer: UInt16? = after < characters.count ? characters[after] : nil

            let opensBlock: Bool
            switch opener {
            case 0x7B?, 0x28?, 0x5B?: opensBlock = true  // { ( [
            case 0x3A?: opensBlock = isPython(line: line)  // :
            default: opensBlock = false
            }
            guard opensBlock else {
                textView.insertText("\n" + base, replacementRange: selection)
                return true
            }
            let inner = base + indentUnit(for: string(characters, from: prefixEnd, to: min(indentEnd, caretOffset)))
            if let opener, let closer, Self.codeBrackets[opener] == closer {
                // Spaces between the caret and the closer go with the split.
                let replaced = NSRange(location: selection.location, length: after - caretOffset)
                textView.insertText("\n" + inner + "\n" + base, replacementRange: replaced)
                textView.setSelectedRange(NSRange(location: selection.location + 1 + (inner as NSString).length, length: 0))
            } else {
                textView.insertText("\n" + inner, replacementRange: selection)
            }
            return true
        }

        // Only continue when the caret is at the end of the line's content.
        let contentEnd = lineRange.location + characters.count
        guard selection.location == contentEnd else { return false }

        // Return after ``` on an unclosed fence closes it, leaving the caret inside.
        if info.kind.isFenceStart, selection.location == lineRange.location + characters.count,
           let block = CodeBlock.containing(line: line, in: storage), block.closeLine == nil {
            let fence = fenceRun(characters)
            // The line left for the code is inside the same quote or list
            // item; without its prefix, it would end them.
            let insertion = "\n" + fence.prefix + "\n" + fence.prefix + fence.run
            textView.insertText(insertion, replacementRange: selection)
            textView.setSelectedRange(NSRange(location: selection.location + 1 + (fence.prefix as NSString).length, length: 0))
            return true
        }

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
        textView.insertText(insertion, replacementRange: selection)
        return true
    }

    /// Tab indents the list item the caret is in; elsewhere it inserts spaces.
    private func changeIndent(by direction: Int, in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        let firstLine = storage.line(at: selection.location)
        let lastLine = storage.lastLine(of: selection)
        if isCode(line: firstLine) {
            return indentCode(by: direction, lines: firstLine...lastLine, in: textView)
        }

        var isList = false
        for line in firstLine...lastLine {
            if case .listItem? = storage.structure.info(forLine: line)?.kind { isList = true }
        }
        guard isList else {
            guard direction > 0, selection.length == 0 else { return false }
            textView.insertText("    ", replacementRange: selection)
            return true
        }

        let text = storage.text
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
        let original = text.substring(with: range)
        guard replacement != original else { return true }
        // How far the first line moved, and the whole text: a selection
        // keeping its old length lost a line's worth per indent, so the
        // next Tab missed the last item.
        let firstLineBefore = original.prefix { $0 != "\n" }
        let firstShift = ((lines.first ?? "") as NSString).length - (String(firstLineBefore) as NSString).length
        let totalShift = (replacement as NSString).length - (original as NSString).length
        textView.insertText(replacement, replacementRange: range)

        let location = max(start, selection.location + firstShift)
        let selectionEnd = selection.length == 0 ? location : max(location, NSMaxRange(selection) + totalShift)
        textView.setSelectedRange(NSRange(location: location, length: selectionEnd - location))
        return true
    }

    /// Brackets that close themselves as you type the opening one.
    private static let autoPairs: [String: String] = ["(": ")", "[": "]", "{": "}", "`": "`"]

    static let autoPairDefaultsKey = Settings.Key.autoPair

    private var autoPairEnabled: Bool {
        Settings().autoPair
    }

    /// Wraps a selection in a delimiter. With no selection, types over a
    /// closing bracket that is already there, or closes a new pair.
    func handleInsertion(of input: String, in textView: NSTextView, range: NSRange) -> Bool {
        if range.length == 0 {
            return autoPairEnabled && handleTyping(input, in: textView, at: range.location)
        }
        guard let closing = Self.pairs[input] else { return false }
        // In code, only brackets and quotes wrap; `*` is code there.
        if isCode(line: storage.line(at: range.location)), !"([\"".contains(input) { return false }

        let text = storage.text
        let selected = text.substring(with: range)
        let replacement = input + selected + closing
        textView.insertText(replacement, replacementRange: range)
        textView.setSelectedRange(NSRange(location: range.location + input.utf16.count, length: range.length))
        return true
    }

    private func handleTyping(_ input: String, in textView: NSTextView, at location: Int) -> Bool {
        // Only a typed character: pairs and indentation this handler inserts
        // come back through here and must go in as they are.
        guard input.utf16.count == 1, let typed = input.utf16.first else { return false }
        let line = storage.line(at: location)
        if isCode(line: line) {
            return typeCode(typed, in: textView, at: location, line: line)
        }

        let text = storage.text
        let next: String? = location < text.length ? text.substring(with: NSRange(location: location, length: 1)) : nil
        let previous: String? = location > 0 ? text.substring(with: NSRange(location: location - 1, length: 1)) : nil

        if typeEmphasis(typed, in: textView, at: location, line: line) { return true }

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
        textView.insertText(pair, replacementRange: range)
        textView.setSelectedRange(NSRange(location: location + input.utf16.count, length: 0))
        return true
    }

    // MARK: Emphasis

    /// Emphasis delimiters, and the longest run that pairs: `***` for bold
    /// italic, `~~` and `==` for strikethrough and highlight.
    private static let emphasisMarks: [UInt16: Int] = [0x2A: 3, 0x5F: 3, 0x7E: 2, 0x3D: 2]  // * _ ~ =
    /// Marks that pair only once doubled: a lone `~` or `=` is mostly text.
    private static let doubledMarks: Set<UInt16> = [0x7E, 0x3D]

    /// The runs of a mark on either side of the caret, on its line.
    private struct MarkRuns {
        var left = 0
        var right = 0
        /// The characters just outside the runs; nil at the line's edges.
        var beforeLeft: UInt16?
        var afterRight: UInt16?
        /// Whether only spaces and quote markers precede the left run.
        var atLineStart = false
    }

    private func runs(of mark: UInt16, at location: Int, line: Int) -> MarkRuns {
        let text = storage.text
        let lineRange = storage.structure.index.range(ofLine: line)
        let lineStart = lineRange.location
        let lineEnd = lineStart + storage.structure.characters(of: text, line: line).count
        var runs = MarkRuns()
        while location - runs.left > lineStart, text.character(at: location - runs.left - 1) == mark { runs.left += 1 }
        while location + runs.right < lineEnd, text.character(at: location + runs.right) == mark { runs.right += 1 }
        let leftEdge = location - runs.left
        let rightEdge = location + runs.right
        runs.beforeLeft = leftEdge > lineStart ? text.character(at: leftEdge - 1) : nil
        runs.afterRight = rightEdge < lineEnd ? text.character(at: rightEdge) : nil
        var cursor = lineStart
        while cursor < leftEdge, [0x20, 0x09, 0x3E].contains(text.character(at: cursor)) { cursor += 1 }
        runs.atLineStart = cursor == leftEdge
        return runs
    }

    /// A delimiter can open after a space, the line's start or punctuation,
    /// not in a word: `snake_case` and `2*3` stay as typed.
    private func canOpen(after character: UInt16?) -> Bool {
        guard let character else { return true }
        if character == 0x5C { return false }  // a backslash escapes it
        if [0x29, 0x5D, 0x7D].contains(character) { return false }  // ) ] }
        return !isWordCharacter(character)
    }

    /// A delimiter can close before a space, the line's end or punctuation.
    private func canClose(before character: UInt16?) -> Bool {
        guard let character else { return true }
        return !isWordCharacter(character)
    }

    private func isWordCharacter(_ character: UInt16) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }  // half a surrogate pair
        return CharacterSet.alphanumerics.contains(scalar)
    }

    /// Whether the empty space between two runs is a pair the editor closed.
    private func isEmptyPair(_ runs: MarkRuns) -> Bool {
        runs.left > 0 && runs.left == runs.right && canOpen(after: runs.beforeLeft) && canClose(before: runs.afterRight)
    }

    /// `*` closes itself as `*|*`, a second one makes `**|**`, a third
    /// `***|***`; typed at the closer, it steps over. `~~` and `==` close
    /// once doubled. A space in an empty pair takes the closer away again,
    /// so a list's `* ` and a sum's ` * ` type as before.
    private func typeEmphasis(_ typed: UInt16, in textView: NSTextView, at location: Int, line: Int) -> Bool {
        // An empty `****` or `====` pair reads as a rule or an underline.
        guard let kind = storage.structure.info(forLine: line)?.kind, !isInInlineCode(location, line: line) else { return false }
        switch kind {
        case .blank, .thematicBreak, .setextUnderline: break
        default: guard kind.hasInlineContent else { return false }
        }
        if typed == 0x20, location > 0 {
            let text = storage.text
            let mark = text.character(at: location - 1)
            guard Self.emphasisMarks[mark] != nil else { return false }
            let runs = runs(of: mark, at: location, line: line)
            guard isEmptyPair(runs) else { return false }
            textView.insertText(" ", replacementRange: NSRange(location: location, length: runs.right))
            return true
        }

        guard let longest = Self.emphasisMarks[typed] else { return false }
        let mark = String(utf16CodeUnits: [typed], count: 1)
        let runs = runs(of: typed, at: location, line: line)

        if isEmptyPair(runs) {
            // `***`, `___` on a line of their own are a rule; `~~~` a fence,
            // `===` a heading's underline: the closer gives way to them.
            if runs.atLineStart, runs.left + 1 >= (Self.doubledMarks.contains(typed) ? 2 : 3) {
                let whole = NSRange(location: location - runs.left, length: runs.left + runs.right)
                let marks = String(repeating: mark, count: runs.left + 1)
                textView.insertText(marks, replacementRange: whole)
                return true
            }
            guard runs.left < longest else { return false }
            textView.insertText(mark + mark, replacementRange: NSRange(location: location, length: 0))
            textView.setSelectedRange(NSRange(location: location + 1, length: 0))
            return true
        }

        // At the closer, after some text, typing it steps over.
        if runs.right > 0, let before = runs.beforeLeft, before != 0x20, before != 0x09,
           canClose(before: runs.afterRight), opensEarlier(typed, before: location - runs.left, line: line) {
            textView.setSelectedRange(NSRange(location: location + 1, length: 0))
            return true
        }

        guard runs.right == 0, canClose(before: runs.afterRight) else { return false }
        if Self.doubledMarks.contains(typed) {
            // The second `~` of `~~` closes the pair.
            guard runs.left == 1, !runs.atLineStart, canOpen(after: runs.beforeLeft) else { return false }
            textView.insertText(mark + mark + mark, replacementRange: NSRange(location: location, length: 0))
            textView.setSelectedRange(NSRange(location: location + 1, length: 0))
            return true
        }
        guard runs.left == 0, canOpen(after: runs.beforeLeft) else { return false }
        textView.insertText(mark + mark, replacementRange: NSRange(location: location, length: 0))
        textView.setSelectedRange(NSRange(location: location + 1, length: 0))
        return true
    }

    /// Whether the mark appears earlier on the line, so a run after the
    /// caret is likely its closer rather than the start of something else.
    private func opensEarlier(_ mark: UInt16, before location: Int, line: Int) -> Bool {
        let text = storage.text
        var cursor = storage.structure.index.range(ofLine: line).location
        while cursor < location {
            if text.character(at: cursor) == mark { return true }
            cursor += 1
        }
        return false
    }

    /// An odd number of backticks before the caret puts it in inline code.
    private func isInInlineCode(_ location: Int, line: Int) -> Bool {
        let text = storage.text
        var cursor = storage.structure.index.range(ofLine: line).location
        var ticks = 0
        while cursor < location {
            if text.character(at: cursor) == 0x60 { ticks += 1 }
            cursor += 1
        }
        return ticks % 2 == 1
    }

    // MARK: Code

    private static let codeBrackets: [UInt16: UInt16] = [0x28: 0x29, 0x5B: 0x5D, 0x7B: 0x7D]  // () [] {}
    private static let codeQuotes: Set<UInt16> = [0x22, 0x27]  // " '

    private func isCode(line: Int) -> Bool {
        switch storage.structure.info(forLine: line)?.kind {
        case .codeLine?, .indentedCode?: true
        default: false
        }
    }

    /// Where a code line's own text starts, past a quote's or a list's prefix.
    private func codeStart(line: Int) -> Int {
        let range = storage.structure.index.range(ofLine: line)
        let length = storage.structure.characters(of: storage.text, line: line).count
        return range.location + min(storage.structure.info(forLine: line)?.contentStart ?? 0, length)
    }

    private func isPython(line: Int) -> Bool {
        guard let block = CodeBlock.containing(line: line, in: storage) else { return false }
        let language = block.info.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return ["python", "py", "python3", "gdscript", "nim", "yaml", "yml"].contains(language)
    }

    /// One more level of the indentation a line already uses: a tab where
    /// it is indented with tabs, four spaces otherwise.
    private func indentUnit(for indentation: String) -> String {
        indentation.contains("\t") ? "\t" : "    "
    }

    /// Typing in a code block works as in a code editor: brackets and
    /// quotes close themselves and are typed over, and `}` on a line of its
    /// own lines up with the block it closes. Emphasis is not paired here.
    private func typeCode(_ typed: UInt16, in textView: NSTextView, at location: Int, line: Int) -> Bool {
        let text = storage.text
        let start = codeStart(line: line)
        let next: UInt16? = location < text.length ? text.character(at: location) : nil
        let previous: UInt16? = location > start ? text.character(at: location - 1) : nil
        let character = String(utf16CodeUnits: [typed], count: 1)

        let isCloser = Self.codeBrackets.values.contains(typed)
        if isCloser || Self.codeQuotes.contains(typed), next == typed, previous != 0x5C {
            textView.setSelectedRange(NSRange(location: location + 1, length: 0))
            return true
        }

        if typed == 0x7D, location > start {
            let leading = text.substring(with: NSRange(location: start, length: location - start))
            if leading.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let trailingSpaces = leading.reversed().prefix { $0 == " " }.count
                let remove = leading.hasSuffix("\t") ? 1 : (trailingSpaces % 4 == 0 ? min(4, trailingSpaces) : trailingSpaces % 4)
                let range = NSRange(location: location - remove, length: remove)
                textView.insertText(character, replacementRange: range)
                return true
            }
        }

        // Pair before a space, the line's end, a closer or a separator.
        let pairsBefore: Set<UInt16> = [0x20, 0x09, 0x0A, 0x29, 0x5D, 0x7D, 0x3B, 0x2C, 0x3A]
        if let next, !pairsBefore.contains(next) { return false }
        let closing: UInt16
        if let bracket = Self.codeBrackets[typed] {
            closing = bracket
        } else if Self.codeQuotes.contains(typed) {
            // An apostrophe in a word or a comment, an escaped quote: no pair.
            if let previous, isWordCharacter(previous) || previous == 0x5C || previous == typed { return false }
            closing = typed
        } else {
            return false
        }
        let pair = character + String(utf16CodeUnits: [closing], count: 1)
        textView.insertText(pair, replacementRange: NSRange(location: location, length: 0))
        textView.setSelectedRange(NSRange(location: location + 1, length: 0))
        return true
    }

    /// Tab and Shift-Tab in code indent or outdent every selected line by a
    /// level; Tab at a caret goes to the next four-column stop.
    private func indentCode(by direction: Int, lines: ClosedRange<Int>, in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        let text = storage.text
        if direction > 0, lines.count == 1, selection.length == 0 {
            let start = codeStart(line: lines.lowerBound)
            let column = selection.location - start
            let indentation = text.substring(with: NSRange(location: start, length: column))
            let unit = indentation.contains("\t") ? "\t" : String(repeating: " ", count: 4 - column % 4)
            textView.insertText(unit, replacementRange: selection)
            return true
        }

        let firstStart = storage.structure.index.range(ofLine: lines.lowerBound).location
        var pieces: [String] = []
        var firstShift = 0
        var totalShift = 0
        var end = firstStart
        for line in lines {
            let characters = storage.structure.characters(of: text, line: line)
            let prefixEnd = isCode(line: line) ? min(storage.structure.info(forLine: line)?.contentStart ?? 0, characters.count) : 0
            let prefix = string(characters, from: 0, to: prefixEnd)
            var body = string(characters, from: prefixEnd, to: characters.count)
            var shift = 0
            if direction > 0 {
                // Blank lines in a selection stay blank.
                if !body.isEmpty || lines.count == 1 {
                    let unit = indentUnit(for: String(body.prefix { $0 == " " || $0 == "\t" }))
                    body = unit + body
                    shift = (unit as NSString).length
                }
            } else {
                let removed = body.hasPrefix("\t") ? 1 : body.prefix(4).prefix { $0 == " " }.count
                body = String(body.dropFirst(removed))
                shift = -removed
            }
            if line == lines.lowerBound { firstShift = shift }
            totalShift += shift
            pieces.append(prefix + body)
            end = storage.structure.index.range(ofLine: line).location + characters.count
        }
        let range = NSRange(location: firstStart, length: end - firstStart)
        let replacement = pieces.joined(separator: "\n")
        guard replacement != text.substring(with: range) else { return true }
        textView.insertText(replacement, replacementRange: range)

        let lineStart = codeStart(line: lines.lowerBound)
        let location = max(min(lineStart, selection.location), selection.location + firstShift)
        let selectionEnd = selection.length == 0 ? location : max(location, NSMaxRange(selection) + totalShift)
        textView.setSelectedRange(NSRange(location: location, length: selectionEnd - location))
        return true
    }

    /// Backspace in a code line's indentation removes a level of spaces.
    private func deleteCodeIndent(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard selection.length == 0 else { return false }
        let line = storage.line(at: selection.location)
        guard isCode(line: line) else { return false }
        let start = codeStart(line: line)
        let count = selection.location - start
        guard count >= 2 else { return false }
        let leading = storage.text.substring(with: NSRange(location: start, length: count))
        guard leading.allSatisfy({ $0 == " " }) else { return false }
        let remove = count % 4 == 0 ? 4 : count % 4
        textView.insertText("", replacementRange: NSRange(location: selection.location - remove, length: remove))
        return true
    }

    /// Backspace between `(` and `)` removes both.
    private func deleteEmptyPair(in textView: NSTextView) -> Bool {
        let selection = textView.selectedRange()
        guard autoPairEnabled, selection.length == 0, selection.location > 0 else { return false }
        let text = storage.text
        guard selection.location < text.length else { return false }
        let pairRange = NSRange(location: selection.location - 1, length: 2)
        let pair = text.substring(with: pairRange)
        let line = storage.line(at: selection.location)
        if isCode(line: line) {
            let opening = text.character(at: selection.location - 1)
            let closing = text.character(at: selection.location)
            guard Self.codeBrackets[opening] == closing || (Self.codeQuotes.contains(opening) && opening == closing) else { return false }
            textView.insertText("", replacementRange: pairRange)
            return true
        }
        let mark = text.character(at: selection.location - 1)
        if Self.emphasisMarks[mark] != nil, isEmptyPair(runs(of: mark, at: selection.location, line: line)) {
            textView.insertText("", replacementRange: pairRange)
            return true
        }
        guard let opening = pair.first.map(String.init), Self.autoPairs[opening] == String(pair.dropFirst()) else { return false }
        textView.insertText("", replacementRange: pairRange)
        return true
    }

    /// A fence line's leading quote markers and indentation, and its run of
    /// backticks or tildes, for writing the matching closer.
    private func fenceRun(_ characters: [UInt16]) -> (prefix: String, run: String) {
        var start = 0
        while start < characters.count, characters[start] == 0x20 || characters[start] == 0x3E { start += 1 }
        var end = start
        while end < characters.count, characters[end] == characters[start] { end += 1 }
        return (string(characters, from: 0, to: start), string(characters, from: start, to: end))
    }

    /// `3. ` after `2. `; `1. ` after `1. ` when lists are numbered all-ones.
    private func incrementOrderedMarker(_ prefix: String) -> String {
        guard let range = prefix.range(of: #"\d+"#, options: .regularExpression),
              let value = Int(prefix[range])
        else { return prefix }
        if value == 1, Settings().orderedNumbering == .allOnes { return prefix }
        return prefix.replacingCharacters(in: range, with: String(value + 1))
    }

    private func string(_ characters: [UInt16], from start: Int, to end: Int) -> String {
        guard start < end, end <= characters.count else { return "" }
        return String(decoding: characters[start..<end], as: UTF16.self)
    }
}
