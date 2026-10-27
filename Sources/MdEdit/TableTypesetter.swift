import AppKit

/// Lays out the rows of tables too wide for the text column, their cells
/// wrapping side by side in their columns.
///
/// TextKit 1 stacks a paragraph's lines one under the next, and a row is one
/// paragraph: one line of markdown. So a wrapping row is laid out here by
/// hand, a line fragment for each line of each cell, every cell starting at
/// the top of the row. Its cells' text, columns and line height come from the
/// row's `TableGrid`; every other paragraph is laid out as usual.
final class TableTypesetter: NSATSTypesetter {
    override func layoutParagraph(at lineFragmentOrigin: UnsafeMutablePointer<NSPoint>) -> Int {
        // A code card reaches its padding above its first line, and drawing
        // is clipped to the text container: a block opening the document
        // would lose the top of its card, rounded corners and all. TextKit
        // drops space before the first paragraph, so the line moves down here.
        if paragraphCharacterRange.location == 0, lineFragmentOrigin.pointee.y == 0,
           let storage = layoutManager?.textStorage, storage.length > 0,
           storage.attribute(.mdCodeBlock, at: 0, effectiveRange: nil) != nil {
            lineFragmentOrigin.pointee.y = Metrics.codeCardPadding
        }
        guard let layoutManager, let storage = layoutManager.textStorage, let container = currentTextContainer,
              paragraphGlyphRange.length + paragraphSeparatorGlyphRange.length > 0
        else { return super.layoutParagraph(at: lineFragmentOrigin) }
        let text = (storage as? MarkdownTextStorage)?.text ?? storage.string as NSString
        let paragraph = paragraphCharacterRange
        guard paragraph.location < text.length else { return super.layoutParagraph(at: lineFragmentOrigin) }
        // A row's leading pipe is concealed, and its null glyph goes with the
        // paragraph before: the paragraph starts after it, the line does not.
        let line = text.lineRange(for: NSRange(location: paragraph.location, length: 0))
        guard let grid = storage.attribute(.mdTableRow, at: line.location, effectiveRange: nil) as? TableGrid,
              let wrapping = grid.wrapping, grid.edges.count > 1
        else { return super.layoutParagraph(at: lineFragmentOrigin) }

        let firstGlyph = paragraphGlyphRange.location
        let endGlyph = max(NSMaxRange(paragraphGlyphRange), NSMaxRange(paragraphSeparatorGlyphRange))
        let columns = grid.edges.count - 1

        // Where each line of each cell starts, in glyphs, in order.
        struct Line {
            var column: Int
            var index: Int
            var start: Int
        }
        var lines: [Line] = []
        for (column, cell) in wrapping.cells.prefix(columns).enumerated() {
            let cellStart = column == 0 ? firstGlyph
                : layoutManager.glyphIndexForCharacter(at: line.location + NSMaxRange(wrapping.cells[column - 1]))
            let width = grid.edges[column + 1] - grid.edges[column] - 2 * wrapping.padding
            let breaks = lineBreaks(in: NSRange(location: line.location + cell.location, length: cell.length), width: width, storage: storage)
            var index = 0
            for start in [cellStart] + breaks.map({ layoutManager.glyphIndexForCharacter(at: $0) }) {
                // Each line takes at least a glyph, so they never go backwards.
                let previous = lines.last?.start ?? firstGlyph - 1
                guard start < endGlyph && start > previous else { continue }
                lines.append(Line(column: column, index: index, start: start))
                index += 1
            }
        }
        guard !lines.isEmpty else { return super.layoutParagraph(at: lineFragmentOrigin) }
        lines[0].start = firstGlyph

        let top = lineFragmentOrigin.pointee.y
        let left = lineFragmentOrigin.pointee.x + container.lineFragmentPadding + grid.indent
        var deepest = 1
        var fonts = FontRun(storage: storage)
        for (number, cellLine) in lines.enumerated() {
            let end = number + 1 < lines.count ? lines[number + 1].start : endGlyph
            let glyphs = NSRange(location: cellLine.start, length: end - cellLine.start)
            guard glyphs.length > 0 else { continue }
            deepest = max(deepest, cellLine.index + 1)

            var advances: [CGFloat] = []
            var hidden: [Int] = []  // concealed markup and line ends, drawn as nothing
            var drawn: CGFloat = 0  // up to the last glyph that is not a space
            for glyph in glyphs.location..<NSMaxRange(glyphs) {
                let properties = layoutManager.propertyForGlyph(at: glyph)
                guard !properties.contains(.null), !properties.contains(.controlCharacter) else {
                    hidden.append(glyph)
                    advances.append(0)
                    continue
                }
                let character = layoutManager.characterIndexForGlyph(at: glyph)
                let font = fonts.font(at: character)
                let kern = storage.attribute(.kern, at: character, effectiveRange: nil) as? CGFloat ?? 0
                advances.append(font.advancement(forCGGlyph: layoutManager.cgGlyph(at: glyph)).width + kern)
                if !CharacterSet.whitespaces.contains(Unicode.Scalar(text.character(at: character)) ?? " ") {
                    drawn = advances.reduce(0, +)
                }
            }

            let column = cellLine.column
            let cellWidth = grid.edges[column + 1] - grid.edges[column]
            let slack = max(0, cellWidth - 2 * wrapping.padding - drawn)
            let alignment = column < wrapping.alignment.count ? wrapping.alignment[column] : 0
            let x = wrapping.padding + slack * alignment
            let rect = NSRect(
                x: left + grid.edges[column],
                y: top + wrapping.verticalPadding + CGFloat(cellLine.index) * wrapping.lineHeight,
                width: cellWidth,
                height: wrapping.lineHeight
            )
            layoutManager.setTextContainer(container, forGlyphRange: glyphs)
            layoutManager.setLineFragmentRect(
                rect, forGlyphRange: glyphs,
                usedRect: NSRect(x: rect.minX + x, y: rect.minY, width: drawn, height: rect.height)
            )
            var points: [NSPoint] = []
            var starts: [Int] = []
            var offset = x
            for (index, advance) in advances.enumerated() {
                points.append(NSPoint(x: offset, y: wrapping.baseline))
                starts.append(glyphs.location + index)
                offset += advance
            }
            layoutManager.setLocations(&points, startingGlyphIndexes: &starts, count: points.count, forGlyphRange: glyphs)
            // After the locations, which would show them again.
            for glyph in hidden { layoutManager.setNotShownAttribute(true, forGlyphAt: glyph) }
        }

        let bottom = top + 2 * wrapping.verticalPadding + CGFloat(deepest) * wrapping.lineHeight
        // The empty line after a document's last row still has a place.
        if NSMaxRange(line) == text.length, line.length > 0, text.character(at: NSMaxRange(line) - 1) == 0x0A {
            let extra = NSRect(x: 0, y: bottom, width: container.size.width, height: wrapping.lineHeight)
            layoutManager.setExtraLineFragmentRect(
                extra, usedRect: NSRect(x: extra.minX, y: extra.minY, width: 1, height: extra.height), textContainer: container
            )
        }
        lineFragmentOrigin.pointee.y = bottom
        return endGlyph
    }

    /// Where a cell's text breaks to fit its column: the characters that start
    /// each line after its first. Concealed markup takes no room.
    private func lineBreaks(in cell: NSRange, width: CGFloat, storage: NSTextStorage) -> [Int] {
        guard cell.length > 0 else { return [] }
        let visible = NSMutableAttributedString()
        var characters: [Int] = []  // the storage index behind each visible UTF-16 unit
        storage.enumerateAttributes(in: cell) { attributes, run, _ in
            guard attributes[.mdConcealed] == nil else { return }
            let piece: NSAttributedString
            if let emoji = attributes[.mdEmoji] as? String, let font = attributes[.font] as? NSFont,
               let emojiFont = NSFont(name: "AppleColorEmoji", size: font.pointSize) {
                piece = NSAttributedString(string: emoji, attributes: [.font: emojiFont])
                characters += Array(repeating: run.location, count: piece.length)
            } else {
                piece = storage.attributedSubstring(from: run)
                characters += run.location..<NSMaxRange(run)
            }
            visible.append(piece)
        }
        guard visible.length > 0 else { return [] }
        let typesetter = CTTypesetterCreateWithAttributedString(visible)
        var breaks: [Int] = []
        var start = 0
        while true {
            let count = max(1, CTTypesetterSuggestLineBreak(typesetter, start, Double(max(1, width))))
            start += count
            guard start < characters.count else { break }
            breaks.append(characters[start])
        }
        return breaks
    }
}

/// The font over the run holding the last character asked about.
private struct FontRun {
    let storage: NSTextStorage
    private var range = NSRange(location: NSNotFound, length: 0)
    private var current: NSFont = .systemFont(ofSize: NSFont.systemFontSize)

    init(storage: NSTextStorage) {
        self.storage = storage
    }

    mutating func font(at index: Int) -> NSFont {
        if !NSLocationInRange(index, range) {
            current = storage.attribute(.font, at: index, effectiveRange: &range) as? NSFont ?? current
        }
        return current
    }
}
