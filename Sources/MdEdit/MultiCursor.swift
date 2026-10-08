import AppKit

/// Typing in several places at once.
///
/// `NSTextView` keeps several selected ranges — a ⌥-drag column selection, or
/// occurrences added one by one — but types only into the first, and it
/// cannot hold more than one empty caret. So extra carets live in
/// `additionalCarets`, are drawn here, and typing and deleting are applied
/// to every target as one undoable change.
extension MarkdownTextView {
    /// Every place an edit applies: the selected ranges and the extra
    /// carets, in order, without duplicates.
    var editTargets: [NSRange] {
        var ranges = selectedRanges.map(\.rangeValue)
        ranges += additionalCarets.map { NSRange(location: $0, length: 0) }
        return Self.merged(ranges)
    }

    var hasMultipleTargets: Bool { editTargets.count > 1 }

    /// Sorted, with overlapping ranges joined and repeated carets dropped.
    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.sorted(by: { ($0.location, $0.length) < ($1.location, $1.length) }) {
            if let last = result.last, range.location < NSMaxRange(last) || (range.length == 0 && range.location == NSMaxRange(last) && last.length == 0) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else if let last = result.last, last.length == 0, range.location == last.location {
                result[result.count - 1] = range
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Replaces each range with its string as one change, then leaves a caret
    /// after each replacement.
    func replace(at ranges: [NSRange], with replacement: (NSRange) -> String) {
        guard let storage = textStorage, !ranges.isEmpty else { return }
        let strings = ranges.map(replacement)
        guard shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: strings) else { return }
        isEditingAtCaretsScope {
            storage.beginEditing()
            for (range, string) in zip(ranges, strings).reversed() {
                storage.replaceCharacters(in: range, with: string)
            }
            storage.endEditing()
            didChangeText()

            var shift = 0
            var carets: [Int] = []
            for (range, string) in zip(ranges, strings) {
                let length = (string as NSString).length
                carets.append(range.location + shift + length)
                shift += length - range.length
            }
            setSelectedRange(NSRange(location: carets[0], length: 0))
            additionalCarets = Array(carets.dropFirst())
        }
    }

    // MARK: - Typing

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if replacementRange.location == NSNotFound, !hasMarkedText(), hasMultipleTargets {
            let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
            replace(at: editTargets) { _ in text }
            return
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func insertNewline(_ sender: Any?) {
        guard hasMultipleTargets else { return super.insertNewline(sender) }
        replace(at: editTargets) { _ in "\n" }
    }

    override func insertTab(_ sender: Any?) {
        guard hasMultipleTargets else { return super.insertTab(sender) }
        replace(at: editTargets) { _ in "    " }
    }

    override func deleteBackward(_ sender: Any?) {
        guard hasMultipleTargets else { return super.deleteBackward(sender) }
        deleteAtTargets(forward: false)
    }

    override func deleteForward(_ sender: Any?) {
        guard hasMultipleTargets else { return super.deleteForward(sender) }
        deleteAtTargets(forward: true)
    }

    private func deleteAtTargets(forward: Bool) {
        let text = string as NSString
        let ranges: [NSRange] = editTargets.compactMap { target in
            if target.length > 0 { return target }
            if forward {
                return target.location < text.length ? text.rangeOfComposedCharacterSequence(at: target.location) : nil
            }
            return target.location > 0 ? text.rangeOfComposedCharacterSequence(at: target.location - 1) : nil
        }
        guard !ranges.isEmpty else { return NSSound.beep() }
        replace(at: Self.merged(ranges)) { _ in "" }
    }

    /// Escape drops the extra carets before anything else.
    override func cancelOperation(_ sender: Any?) {
        if !additionalCarets.isEmpty || selectedRanges.count > 1 {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            return
        }
        super.cancelOperation(sender)
    }

    // MARK: - Adding carets and occurrences

    /// Adds a caret on the line above or below the outermost one, at the same
    /// column or the line's end if it is shorter.
    func addCaret(below: Bool) {
        guard let storage = textStorage as? MarkdownTextStorage else { return }
        let carets = editTargets.map(\.location)
        guard let from = below ? carets.max() : carets.min() else { return }
        let line = storage.line(at: from)
        let target = line + (below ? 1 : -1)
        guard target >= 0, target < storage.structure.lineCount else { return NSSound.beep() }
        let column = from - storage.structure.index.range(ofLine: line).location
        let content = storage.structure.index.contentRange(ofLine: target, in: storage.string as NSString)
        let location = content.location + min(column, content.length)
        additionalCarets = Array(Set(additionalCarets + [location]).subtracting([selectedRange().location])).sorted()
        scrollRangeToVisible(NSRange(location: location, length: 0))
    }

    /// Selects the next match of the last selection, adding it to the others.
    /// With nothing selected, selects the word at the caret first.
    func addNextOccurrence(wordRange: (Int) -> NSRange) {
        let text = string as NSString
        let ranges = selectedRanges.map(\.rangeValue)
        guard let last = ranges.last, text.length > 0 else { return }
        if ranges.count == 1, last.length == 0 {
            let word = wordRange(last.location)
            if word.length > 0 { setSelectedRange(word) }
            return
        }
        let needle = text.substring(with: last)
        let after = NSRange(location: NSMaxRange(last), length: text.length - NSMaxRange(last))
        var found = text.range(of: needle, options: [], range: after)
        if found.location == NSNotFound {
            found = text.range(of: needle, options: [], range: NSRange(location: 0, length: last.location))
        }
        guard found.location != NSNotFound, !ranges.contains(found) else { return NSSound.beep() }
        let all = Self.merged(ranges + [found])
        isEditingAtCaretsScope {
            selectedRanges = all.map { NSValue(range: $0) }
        }
        scrollRangeToVisible(found)
        showFindIndicator(for: found)
    }

    /// Selects every match of the selection, or of the word at the caret.
    func selectAllOccurrences(wordRange: (Int) -> NSRange) {
        let text = string as NSString
        var needleRange = selectedRange()
        if needleRange.length == 0 { needleRange = wordRange(needleRange.location) }
        guard needleRange.length > 0 else { return NSSound.beep() }
        let needle = text.substring(with: needleRange)
        var matches: [NSRange] = []
        var search = NSRange(location: 0, length: text.length)
        while search.length > 0 {
            let found = text.range(of: needle, options: [], range: search)
            guard found.location != NSNotFound else { break }
            matches.append(found)
            search = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
        }
        guard !matches.isEmpty else { return }
        isEditingAtCaretsScope {
            selectedRanges = matches.map { NSValue(range: $0) }
        }
    }

    // MARK: - Drawing

    /// Extra carets are drawn steadily rather than blinking: AppKit only
    /// redraws the primary caret's rectangle on each blink.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !additionalCarets.isEmpty else { return }
        insertionPointColor.setFill()
        for caret in additionalCarets {
            guard let rect = caretRect(at: caret), rect.intersects(dirtyRect) else { continue }
            rect.fill()
        }
    }

    /// The rectangle a caret at a location occupies, in view coordinates.
    func caretRect(at location: Int) -> NSRect? {
        guard let layoutManager, let textContainer, let storage = textStorage else { return nil }
        let origin = textContainerOrigin
        if location >= storage.length {
            let extra = layoutManager.extraLineFragmentRect
            if extra.height > 0 {
                return NSRect(x: origin.x + extra.minX + textContainer.lineFragmentPadding, y: origin.y + extra.minY, width: 2, height: extra.height)
            }
        }
        guard layoutManager.numberOfGlyphs > 0 else { return nil }
        let atEnd = location >= storage.length
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, storage.length - 1))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        var x = fragment.minX + layoutManager.location(forGlyphAt: glyph).x
        if atEnd {
            x = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer).maxX
        }
        return NSRect(x: origin.x + x, y: origin.y + fragment.minY, width: 2, height: fragment.height)
    }

    private func isEditingAtCaretsScope(_ body: () -> Void) {
        setEditingAtCarets(true)
        body()
        setEditingAtCarets(false)
    }
}
