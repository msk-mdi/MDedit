import AppKit
import MarkdownKit

/// The Format menu, implemented against the selection.
///
/// Every command goes through `insertText(_:replacementRange:)` so undo,
/// reparsing and restyling all follow for free.
extension EditorViewController {
    /// Wraps or unwraps the selection in a delimiter, e.g. `**` for bold.
    func toggleInline(_ delimiter: String) {
        let text = storage.string as NSString
        var range = textView.selectedRange()
        if range.length == 0 {
            range = wordRange(around: range.location)
        }

        let length = delimiter.utf16.count
        let selected = text.substring(with: range)

        // Already wrapped, inside the selection?
        if selected.hasPrefix(delimiter), selected.hasSuffix(delimiter), selected.utf16.count >= 2 * length {
            let stripped = String(selected.dropFirst(delimiter.count).dropLast(delimiter.count))
            replace(range, with: stripped, select: NSRange(location: range.location, length: stripped.utf16.count))
            return
        }

        // Already wrapped, just outside the selection?
        let before = NSRange(location: range.location - length, length: length)
        let after = NSRange(location: NSMaxRange(range), length: length)
        if before.location >= 0,
           NSMaxRange(after) <= text.length,
           text.substring(with: before) == delimiter,
           text.substring(with: after) == delimiter {
            let outer = NSRange(location: before.location, length: range.length + 2 * length)
            replace(outer, with: selected, select: NSRange(location: before.location, length: range.length))
            return
        }

        let wrapped = delimiter + selected + delimiter
        replace(range, with: wrapped, select: NSRange(location: range.location + length, length: range.length))
    }

    /// Sets or clears the heading level of every line the selection touches.
    func setHeading(level: Int) {
        forEachSelectedLine { characters, info in
            // `contentStart` already skips whatever marker the line had, so
            // setting a level and clearing one are the same operation.
            let body = String(decoding: characters[min(info.contentStart, characters.count)...], as: UTF16.self)
            let prefix = level > 0 ? String(repeating: "#", count: level) + " " : ""
            return prefix + body
        }
    }

    /// Adds or removes a list marker on every selected line.
    func toggleList(ordered: Bool, task: Bool = false) {
        var number = 0
        forEachSelectedLine { characters, info in
            number += 1
            let body = String(decoding: characters[min(info.contentStart, characters.count)...], as: UTF16.self)
            let existing = String(decoding: characters[0..<min(info.contentStart, characters.count)], as: UTF16.self)

            if case .listItem = info.kind {
                // Toggling the same kind off leaves the bare text behind.
                let wantsTask = task && !existing.contains("[")
                if !wantsTask { return body }
            }
            let marker = ordered ? "\(number). " : "- "
            return marker + (task ? "[ ] " : "") + body
        }
    }

    /// Adds or removes a `>` prefix on every selected line.
    func toggleQuote() {
        forEachSelectedLine { characters, info in
            let full = String(decoding: characters, as: UTF16.self)
            if info.quoteDepth > 0 {
                let markerLength = info.markers.first(where: { $0.kind == .quote })
                    .map { NSMaxRange($0.range) } ?? 0
                return String(decoding: characters[min(markerLength, characters.count)...], as: UTF16.self)
            }
            return "> " + full
        }
    }

    /// Wraps the selection in a fenced code block.
    func insertCodeBlock() {
        let text = storage.string as NSString
        let range = lineRange(for: textView.selectedRange())
        let body = text.substring(with: range)
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        let replacement = "```\n" + trimmed + "\n```\n"
        replace(range, with: replacement, select: NSRange(location: range.location + 3, length: 0))
    }

    /// Wraps the selection as a link, using a URL from the clipboard if there
    /// is one, and leaving the caret where the destination goes otherwise.
    func insertLink() {
        let text = storage.string as NSString
        var range = textView.selectedRange()
        if range.length == 0 {
            range = wordRange(around: range.location)
        }
        let selected = text.substring(with: range)
        let clipboard = NSPasteboard.general.string(forType: .string) ?? ""
        let destination = looksLikeURL(clipboard) ? clipboard : ""

        let replacement = "[\(selected)](\(destination))"
        let caret = range.location + selected.utf16.count + 3
        replace(
            range,
            with: replacement,
            select: NSRange(location: caret, length: destination.utf16.count)
        )
    }

    // MARK: - Helpers

    private func looksLikeURL(_ value: String) -> Bool {
        guard !value.contains(where: \.isWhitespace), let url = URL(string: value) else { return false }
        return url.scheme != nil
    }

    func replace(_ range: NSRange, with replacement: String, select selection: NSRange) {
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.insertText(replacement, replacementRange: range)
        textView.setSelectedRange(selection)
    }

    /// The word around a location, so a command with no selection still has
    /// something to act on.
    private func wordRange(around location: Int) -> NSRange {
        let text = storage.string as NSString
        guard text.length > 0 else { return NSRange(location: location, length: 0) }
        let separators = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*_`[]()#>"))

        var start = min(location, text.length)
        while start > 0,
              let scalar = Unicode.Scalar(text.character(at: start - 1)),
              !separators.contains(scalar) {
            start -= 1
        }
        var end = min(location, text.length)
        while end < text.length,
              let scalar = Unicode.Scalar(text.character(at: end)),
              !separators.contains(scalar) {
            end += 1
        }
        return NSRange(location: start, length: end - start)
    }

    private func lineRange(for range: NSRange) -> NSRange {
        let first = storage.line(at: range.location)
        let last = storage.line(at: NSMaxRange(range))
        return storage.characterRange(forLines: first...last)
    }

    /// Rewrites every line the selection touches, in one undoable edit.
    private func forEachSelectedLine(_ transform: ([UInt16], LineInfo) -> String) {
        let selection = textView.selectedRange()
        let first = storage.line(at: selection.location)
        let last = storage.line(at: NSMaxRange(selection))
        let text = storage.string as NSString

        var rewritten: [String] = []
        for line in first...last {
            guard let info = storage.structure.info(forLine: line) else { continue }
            rewritten.append(transform(storage.structure.characters(of: text, line: line), info))
        }

        let range = storage.characterRange(forLines: first...last)
        var replacement = rewritten.joined(separator: "\n")
        if text.substring(with: range).hasSuffix("\n") { replacement += "\n" }

        let lengthDelta = replacement.utf16.count - range.length
        replace(
            range,
            with: replacement,
            select: NSRange(
                location: selection.location,
                length: max(0, selection.length + (selection.length > 0 ? lengthDelta : 0))
            )
        )
    }
}
