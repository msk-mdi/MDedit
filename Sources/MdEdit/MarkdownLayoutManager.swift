import AppKit
import MarkdownKit

/// Where the editor stops looking like a source view.
///
/// Two jobs, both of which TextKit 1 hands you directly: markers carrying
/// `.mdConcealed` generate no glyphs at all, and block decoration — code
/// backgrounds, quote bars, table stripes, rules — is painted behind the text.
final class MarkdownLayoutManager: NSLayoutManager {
    var theme: Theme = .light

    /// In focus mode, the range left at full contrast; everything else dims.
    var focusRange: NSRange?

    /// Text gliding into place after a line revealed or hid its markdown.
    var revealMotion: RevealMotion?

    private var substituteGlyphs: [String: CGGlyph] = [:]

    override init() {
        super.init()
        delegate = self
        // Custom glyph generation and non-contiguous layout do not mix: the
        // layout manager throws filling glyph holes it never generated.
        allowsNonContiguousLayout = false
        typesetter = TableTypesetter()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Focus mode dims every line but the one being written.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawThroughMotion(glyphsToShow, at: origin) { super.drawGlyphs(forGlyphRange: $0, at: $1) }
        drawInlineMath(forGlyphRange: glyphsToShow, at: origin)
        guard let focusRange, let container = textContainers.first else { return }

        let focusGlyphs = glyphRange(forCharacterRange: focusRange, actualCharacterRange: nil)
        theme.canvas.withAlphaComponent(0.55).setFill()
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, lineGlyphRange, _ in
            guard NSIntersectionRange(lineGlyphRange, focusGlyphs).length == 0 else { return }
            var dim = rect.offsetBy(dx: origin.x, dy: origin.y)
            // A wrapping table's cells sit side by side: each dims its own.
            let isCell = self.wrappedRow(atCharacter: self.characterIndexForGlyph(at: lineGlyphRange.location)) != nil
            if !isCell { dim.size.width = container.size.width }
            dim.fill(using: .sourceOver)
        }
    }

    /// Typeset formulas sit on the baseline of the invisible glyph kerned
    /// to make room for them.
    private func drawInlineMath(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        guard let storage = textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)
        storage.enumerateAttribute(.mdMath, in: characters) { value, range, _ in
            guard let math = value as? InlineImage else { return }
            let glyph = glyphIndexForCharacter(at: range.location)
            guard glyph < numberOfGlyphs, attribute(forGlyphAt: glyph) else { return }
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let baseline = location(forGlyphAt: glyph)
            let frame = NSRect(
                x: origin.x + fragment.minX + baseline.x,
                y: origin.y + fragment.minY + baseline.y - (math.size.height - math.descent),
                width: math.size.width,
                height: math.size.height
            )
            math.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    /// Whether a glyph is drawn at all; folded and concealed ones are not.
    private func attribute(forGlyphAt glyph: Int) -> Bool {
        !propertyForGlyph(at: glyph).contains(.null)
    }

    // MARK: - Block decoration

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        drawBackgroundThroughMotion(glyphsToShow, at: origin) { drawDecoratedBackground(forGlyphRange: $0, at: $1) }
    }

    /// An edit renumbers the glyphs a motion refers to, so it stops there.
    override func processEditing(
        for textStorage: NSTextStorage,
        edited editMask: NSTextStorageEditActions,
        range newCharRange: NSRange,
        changeInLength delta: Int,
        invalidatedRange invalidatedCharRange: NSRange
    ) {
        if editMask.contains(.editedCharacters) { revealMotion = nil }
        super.processEditing(for: textStorage, edited: editMask, range: newCharRange, changeInLength: delta, invalidatedRange: invalidatedCharRange)
    }

    private func drawDecoratedBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        // Each code block is filled once, as a whole, wherever its lines start,
        // and so is each row of a wrapping table.
        var drawnCodeBlocks = Set<Int>()
        var drawnRows = Set<Int>()

        enumerateLineFragments(forGlyphRange: glyphsToShow) { fragmentRect, usedRect, _, lineGlyphRange, _ in
            let lineCharacters = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard lineCharacters.location < storage.length else { return }
            let attributes = storage.attributes(at: lineCharacters.location, effectiveRange: nil)
            // Folded lines are a hair tall; nothing of theirs is drawn.
            if attributes[.mdFolded] != nil { return }
            // An image sits in the space its paragraph reserved above the
            // first line, so only the paragraph's first fragment draws it; a
            // preview below a line goes in the space after its last fragment.
            if let inline = attributes[.mdImage] as? InlineImage,
               inline.below
                   ? self.isLastFragmentOfParagraph(lineCharacters, in: storage)
                   : self.isFirstFragmentOfParagraph(lineCharacters.location, in: storage) {
                let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
                var x = origin.x + container.lineFragmentPadding + indent
                if inline.centered {
                    let column = container.size.width - 2 * container.lineFragmentPadding - indent
                    x += max(0, (column - inline.size.width) / 2)
                }
                let frame = NSRect(
                    x: x,
                    y: (inline.below ? usedRect.maxY + Metrics.imageSpacing * 2 : fragmentRect.minY + Metrics.imageSpacing) + origin.y,
                    width: inline.size.width,
                    height: inline.size.height
                )
                inline.image.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }

            if let markdown = storage as? MarkdownTextStorage, markdown.numberHeadings,
               self.isFirstFragmentOfParagraph(lineCharacters.location, in: storage),
               // Revealed markers hang where the number would go.
               self.hangingMarkers(at: lineCharacters.location, in: storage) == nil,
               let number = markdown.headingNumber(forLine: markdown.line(at: lineCharacters.location)) {
                self.drawHeadingNumber(number, glyphRange: lineGlyphRange, fragment: fragmentRect, attributes: attributes, origin: origin)
            }

            var rect = usedRect.offsetBy(dx: origin.x, dy: origin.y)
            // Decoration spans the text column, not just the glyphs that were
            // used. `origin` already accounts for the container inset.
            rect.origin.x = origin.x
            rect.size.width = container.size.width

            if attributes[.mdCodeBlock] != nil {
                let block = self.codeBlockRange(containing: lineCharacters.location, in: storage, within: characterRange)
                if drawnCodeBlocks.insert(block.range.location).inserted {
                    self.drawCodeCard(for: block, in: container, origin: origin)
                }
            }

            if let grid = attributes[.mdTableRow] as? TableGrid, grid.wrapping != nil {
                if let row = self.wrappedRow(atCharacter: lineCharacters.location), drawnRows.insert(row.line.location).inserted {
                    let bounds = self.bounds(of: row)
                    let left = origin.x + container.lineFragmentPadding + grid.indent
                    self.drawTableRow(grid, in: NSRect(x: left, y: origin.y + bounds.minY, width: grid.edges.last ?? 0, height: bounds.height))
                }
            } else if let grid = attributes[.mdTableRow] as? TableGrid {
                let left = origin.x + container.lineFragmentPadding + grid.indent
                self.drawTableRow(grid, in: NSRect(x: left, y: origin.y + fragmentRect.minY, width: grid.edges.last ?? 0, height: grid.height))
            } else if attributes[.mdTableRow] != nil {
                self.theme.codeBackground.withAlphaComponent(0.5).setFill()
                rect.fill()
            }

            if let depth = attributes[.mdQuoteDepth] as? Int, depth > 0 {
                self.theme.quoteBar.setFill()
                for level in 0..<depth {
                    let bar = NSRect(
                        x: rect.minX + CGFloat(level) * 22 + 4,
                        y: rect.minY,
                        width: 3,
                        height: rect.height
                    )
                    NSBezierPath(roundedRect: bar, xRadius: 1.5, yRadius: 1.5).fill()
                }
            }

            if attributes[.mdThematicBreak] != nil {
                self.theme.rule.setFill()
                let rule = NSRect(
                    x: rect.minX + 4,
                    y: rect.midY - 0.5,
                    width: rect.width - 8,
                    height: 1
                )
                rule.fill()
            }
        }

        // A folded heading ends in a ⋯ chip, which unfolds it when clicked.
        if let markdown = storage as? MarkdownTextStorage, !markdown.foldedHeadings.isEmpty {
            let lines = markdown.line(at: characterRange.location)...markdown.line(at: NSMaxRange(characterRange))
            for heading in markdown.foldedHeadings where lines.contains(heading) {
                guard let chip = foldIndicatorRect(forHeadingLine: heading) else { continue }
                drawFoldIndicator(in: chip.offsetBy(dx: origin.x, dy: origin.y))
            }
        }

        // Inline code gets a rounded chip behind it.
        storage.enumerateAttribute(.mdInlineCode, in: characterRange) { value, range, _ in
            guard value != nil else { return }
            let glyphRange = self.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.enumerateEnclosingRects(
                forGlyphRange: glyphRange,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                in: container
            ) { rect, _ in
                let chip = rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -2, dy: 1)
                self.theme.codeBackground.setFill()
                NSBezierPath(roundedRect: chip, xRadius: 3, yRadius: 3).fill()
            }
        }
    }

    /// Whether the character at an index is in a code block.
    private func isCode(at index: Int, in storage: NSTextStorage) -> Bool {
        index >= 0 && index < storage.length && storage.attribute(.mdCodeBlock, at: index, effectiveRange: nil) != nil
    }

    /// The part of a code block being drawn.
    private struct CodeBlockPart {
        var range: NSRange
        /// The block goes on before or after what is drawn.
        var continuesBefore: Bool
        var continuesAfter: Bool
    }

    /// The code block around a character, across line breaks whether or not
    /// the breaks themselves carry the attribute — looked for only a little
    /// past the characters being drawn: following a long block to its ends,
    /// a line at a time, on every redraw cost tens of milliseconds.
    private func codeBlockRange(containing index: Int, in storage: NSTextStorage, within drawn: NSRange) -> CodeBlockPart {
        let text = Self.text(of: storage)
        // Two characters either side: enough to see a line break and the code beyond it.
        let lower = max(0, drawn.location - 2)
        let window = NSRange(location: lower, length: min(storage.length, NSMaxRange(drawn) + 2) - lower)
        var start = index
        var end = index
        func effective(_ at: Int) -> NSRange {
            var range = NSRange()
            storage.attribute(.mdCodeBlock, at: at, longestEffectiveRange: &range, in: window)
            return range
        }
        var range = effective(index)
        start = range.location
        end = NSMaxRange(range)
        var continuesBefore = false
        var continuesAfter = false
        while true {
            if start <= window.location,
               isCode(at: start - 1, in: storage)
                || (start >= 2 && text.character(at: start - 1) == 0x0A && isCode(at: start - 2, in: storage)) {
                continuesBefore = true
                break
            }
            if isCode(at: start - 1, in: storage) {
                start = effective(start - 1).location
            } else if start >= 2, text.character(at: start - 1) == 0x0A, isCode(at: start - 2, in: storage) {
                start = effective(start - 2).location
            } else { break }
        }
        while true {
            if end >= NSMaxRange(window),
               isCode(at: end, in: storage)
                || (end < storage.length - 1 && text.character(at: end) == 0x0A && isCode(at: end + 1, in: storage)) {
                continuesAfter = true
                break
            }
            if isCode(at: end, in: storage) {
                end = NSMaxRange(effective(end))
            } else if end < storage.length - 1, text.character(at: end) == 0x0A, isCode(at: end + 1, in: storage) {
                end = NSMaxRange(effective(end + 1))
            } else { break }
        }
        return CodeBlockPart(
            range: NSRange(location: start, length: end - start),
            continuesBefore: continuesBefore,
            continuesAfter: continuesAfter
        )
    }

    /// Fills a code block as one card with rounded corners, around the
    /// lines that show text. Hidden fences are left outside it: their
    /// concealed glyphs ride on the line before, which would otherwise
    /// stretch the card over empty space.
    ///
    /// Only the part among the glyphs being drawn is looked at: walking
    /// every line of a long block on each redraw cost a tenth of a second.
    /// Where the block goes on past them, the card does too, out of sight.
    private func drawCodeCard(for block: CodeBlockPart, in container: NSTextContainer, origin: NSPoint) {
        guard let storage = textStorage else { return }
        let glyphs = glyphRange(forCharacterRange: block.range, actualCharacterRange: nil)
        guard glyphs.length > 0 else { return }
        let startsHere = !block.continuesBefore
        let endsHere = !block.continuesAfter
        let text = Self.text(of: storage)
        var top: CGFloat?
        var bottom: CGFloat = 0
        var firstTop: CGFloat?
        var lastBottom: CGFloat = 0
        enumerateLineFragments(forGlyphRange: glyphs) { _, usedRect, _, lineGlyphs, _ in
            if firstTop == nil { firstTop = usedRect.minY }
            lastBottom = usedRect.maxY
            let shown = lineGlyphs.intersection(glyphs) ?? NSRange(location: 0, length: 0)
            let showsText = (shown.location..<NSMaxRange(shown)).contains { glyph in
                guard self.attribute(forGlyphAt: glyph) else { return false }
                let character = self.characterIndexForGlyph(at: glyph)
                guard character < text.length else { return false }
                // Code lines left blank inside a block still belong to it;
                // only line breaks and hidden markers do not count.
                let unit = text.character(at: character)
                return unit != 0x0A && unit != 0x0D
                    || storage.attribute(.mdMarker, at: character, effectiveRange: nil) == nil
                        && self.isBlankCodeLine(at: character, in: text)
            }
            guard showsText else { return }
            if top == nil { top = usedRect.minY }
            bottom = usedRect.maxY
        }
        let padding = Metrics.codeCardPadding
        // Far enough past the edge that neither padding nor a rounded corner shows.
        let overhang = padding + 2 * Metrics.codeCardRadius
        if !startsHere, let firstTop { top = firstTop - overhang }
        if !endsHere { bottom = lastBottom + overhang }
        guard let top, bottom > top else { return }
        let card = NSRect(
            x: origin.x,
            y: origin.y + top - padding,
            width: container.size.width,
            height: bottom - top + 2 * padding
        )
        theme.codeBackground.setFill()
        NSBezierPath(roundedRect: card, xRadius: Metrics.codeCardRadius, yRadius: Metrics.codeCardRadius).fill()
    }

    /// Whether the line break at an index ends an empty line.
    private func isBlankCodeLine(at index: Int, in text: NSString) -> Bool {
        index == 0 || text.character(at: index - 1) == 0x0A
    }

    /// A table row's cell lines, as in rendered output: each row draws the
    /// line above it, the last also the one below; the header is shaded.
    private func drawTableRow(_ grid: TableGrid, in row: NSRect) {
        if grid.isHeader {
            theme.codeBackground.setFill()
            row.fill()
        }
        theme.rule.setFill()
        NSRect(x: row.minX, y: row.minY, width: row.width, height: 1).fill()
        if grid.isLast {
            NSRect(x: row.minX, y: row.maxY - 1, width: row.width, height: 1).fill()
        }
        let edges = grid.isDelimiter ? [grid.edges.first, grid.edges.last].compactMap(\.self) : grid.edges
        for (index, edge) in edges.enumerated() {
            // The last edge sits inside the row, so the grid is as wide as measured.
            let x = row.minX + edge - (index == edges.count - 1 ? 1 : 0)
            NSRect(x: x, y: row.minY, width: 1, height: row.height).fill()
        }
    }

    /// Draws a heading's outline number in the margin, right-aligned against
    /// the text column and on the heading's baseline.
    private func drawHeadingNumber(
        _ number: String,
        glyphRange: NSRange,
        fragment: NSRect,
        attributes: [NSAttributedString.Key: Any],
        origin: NSPoint
    ) {
        guard let font = attributes[.font] as? NSFont, let container = textContainers.first else { return }
        let numberFont = NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask)
        let label = NSAttributedString(string: number, attributes: [
            .font: numberFont,
            .foregroundColor: theme.marker,
        ])
        let baseline = location(forGlyphAt: glyphRange.location).y
        let size = label.size()
        let indent = (attributes[.paragraphStyle] as? NSParagraphStyle)?.firstLineHeadIndent ?? 0
        let right = origin.x + container.lineFragmentPadding + indent - 10
        label.draw(at: NSPoint(x: right - size.width, y: origin.y + fragment.minY + baseline - numberFont.ascender))
    }

    /// Where a folded heading's ⋯ chip sits, in container coordinates: just
    /// past the heading's last glyph, centred on its line.
    func foldIndicatorRect(forHeadingLine line: Int) -> NSRect? {
        guard let storage = textStorage as? MarkdownTextStorage, line < storage.structure.lineCount,
              let container = textContainers.first
        else { return nil }
        let content = storage.structure.index.contentRange(ofLine: line, in: storage.text)
        let last = max(content.location, NSMaxRange(content) - 1)
        guard last < storage.length else { return nil }
        let glyphs = glyphRange(forCharacterRange: NSRange(location: last, length: 1), actualCharacterRange: nil)
        guard glyphs.location < numberOfGlyphs else { return nil }
        let used = lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let glyphBounds = boundingRect(forGlyphRange: glyphs, in: container)
        let height: CGFloat = 16
        let lineBox = glyphBounds.height > 0 ? glyphBounds : used
        return NSRect(x: max(used.maxX, glyphBounds.maxX) + 8, y: lineBox.midY - height / 2, width: 26, height: height)
    }

    private func drawFoldIndicator(in rect: NSRect) {
        theme.codeBackground.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let dots = NSAttributedString(string: "⋯", attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: theme.secondaryText,
        ])
        let size = dots.size()
        dots.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }

    /// A fragment's characters start after any concealed glyphs, so the
    /// paragraph's first fragment is the one with only concealed text before it.
    private func isFirstFragmentOfParagraph(_ location: Int, in storage: NSTextStorage) -> Bool {
        let start = Self.text(of: storage).paragraphRange(for: NSRange(location: location, length: 0)).location
        // Run by run, not character by character: a long wrapped paragraph
        // asks this once per fragment.
        var index = start
        while index < location {
            var run = NSRange()
            guard storage.attribute(.mdConcealed, at: index, longestEffectiveRange: &run, in: NSRange(location: index, length: location - index)) != nil
            else { return false }
            index = NSMaxRange(run)
        }
        return true
    }

    private func isLastFragmentOfParagraph(_ lineCharacters: NSRange, in storage: NSTextStorage) -> Bool {
        let paragraph = Self.text(of: storage).paragraphRange(for: NSRange(location: lineCharacters.location, length: 0))
        return NSMaxRange(lineCharacters) >= NSMaxRange(paragraph)
    }

    /// The characters, without copying them out of a markdown storage.
    private static func text(of storage: NSTextStorage) -> NSString {
        (storage as? MarkdownTextStorage)?.text ?? storage.string as NSString
    }

    /// The glyph for a replacement character in a given font, cached.
    fileprivate func glyph(for replacement: String, in font: NSFont) -> CGGlyph? {
        let key = "\(replacement)-\(font.fontName)-\(font.pointSize)"
        if let cached = substituteGlyphs[key] { return cached }
        var characters: [UniChar] = Array(replacement.utf16)
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        guard CTFontGetGlyphsForCharacters(font as CTFont, &characters, &glyphs, characters.count),
              let glyph = glyphs.first, glyph != 0
        else { return nil }
        substituteGlyphs[key] = glyph
        return glyph
    }
}

// MARK: - Wrapping table rows

/// `TableTypesetter` lays each cell of a wrapping table row out in its own
/// column, so the row's line fragments go down each cell and back up for the
/// next. TextKit searches fragments as if they only went down, so finding the
/// glyphs in a rect, or under a point, is done here for those rows.
extension MarkdownLayoutManager {
    struct WrappedRow {
        /// The row's line of markdown.
        var line: NSRange
        var grid: TableGrid
        var wrapping: TableGrid.Wrapping
        /// Its line fragments, a line of a cell each, in glyph order.
        var fragments: [(rect: NSRect, glyphs: NSRange)]
    }

    /// The wrapping table row a character is in, laid out.
    func wrappedRow(atCharacter index: Int) -> WrappedRow? {
        guard let storage = textStorage, index >= 0, index < storage.length else { return nil }
        let line = Self.text(of: storage).lineRange(for: NSRange(location: index, length: 0))
        guard let grid = storage.attribute(.mdTableRow, at: line.location, effectiveRange: nil) as? TableGrid,
              let wrapping = grid.wrapping
        else { return nil }
        let start = glyphIndexForCharacter(at: line.location)
        let end = NSMaxRange(line) >= storage.length ? numberOfGlyphs : glyphIndexForCharacter(at: NSMaxRange(line))
        var fragments: [(rect: NSRect, glyphs: NSRange)] = []
        var glyph = start
        while glyph < numberOfGlyphs, glyph < end || fragments.isEmpty {
            var range = NSRange()
            let rect = lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range, withoutAdditionalLayout: true)
            guard range.length > 0 else { break }
            // The row's concealed leading pipe goes with the fragment before it.
            if range.location >= start { fragments.append((rect, range)) }
            glyph = NSMaxRange(range)
        }
        return fragments.isEmpty ? nil : WrappedRow(line: line, grid: grid, wrapping: wrapping, fragments: fragments)
    }

    /// The row's extent, from the top of its cells to the bottom of the deepest.
    func bounds(of row: WrappedRow) -> NSRect {
        let top = row.fragments.map(\.rect.minY).min() ?? 0
        let bottom = row.fragments.map(\.rect.maxY).max() ?? 0
        let left = row.fragments.map(\.rect.minX).min() ?? 0
        let right = row.fragments.map(\.rect.maxX).max() ?? 0
        return NSRect(x: left, y: top - row.wrapping.verticalPadding, width: right - left,
                      height: bottom - top + 2 * row.wrapping.verticalPadding)
    }

    /// The wrapping rows near a glyph TextKit found: its own, and the rows on
    /// either side, as the search can land a row off.
    private func wrappedRows(around glyph: Int) -> [WrappedRow] {
        guard let storage = textStorage, glyph < numberOfGlyphs else { return [] }
        let text = Self.text(of: storage)
        let character = characterIndexForGlyph(at: glyph)
        let line = text.lineRange(for: NSRange(location: min(character, max(0, text.length - 1)), length: 0))
        var rows: [WrappedRow] = []
        if line.location > 0, let before = wrappedRow(atCharacter: line.location - 1) { rows.append(before) }
        if let own = wrappedRow(atCharacter: line.location) { rows.append(own) }
        if NSMaxRange(line) < text.length, let after = wrappedRow(atCharacter: NSMaxRange(line)) { rows.append(after) }
        return rows
    }

    override func glyphRange(forBoundingRect bounds: NSRect, in container: NSTextContainer) -> NSRange {
        widened(super.glyphRange(forBoundingRect: bounds, in: container), toRowsIn: bounds, of: container)
    }

    override func glyphRange(forBoundingRectWithoutAdditionalLayout bounds: NSRect, in container: NSTextContainer) -> NSRange {
        widened(super.glyphRange(forBoundingRectWithoutAdditionalLayout: bounds, in: container), toRowsIn: bounds, of: container)
    }

    /// Widens a range to the whole of each wrapping row in the rect: the
    /// search stops at the first fragment past it, where a row's next cell
    /// goes back up, and finds nothing in a row's padding, where no line is.
    private func widened(_ range: NSRange, toRowsIn bounds: NSRect, of container: NSTextContainer) -> NSRange {
        guard textStorage?.length ?? 0 > 0, numberOfGlyphs > 0 else { return range }
        var lower = range.location, upper = NSMaxRange(range)
        var probes = range.length > 0 ? [range.location, NSMaxRange(range) - 1] : []
        for y in [bounds.minY, bounds.maxY] {
            probes.append(super.glyphIndex(for: NSPoint(x: bounds.minX, y: y), in: container, fractionOfDistanceThroughGlyph: nil))
        }
        if range.length == 0 { lower = numberOfGlyphs; upper = 0 }
        for glyph in probes {
            for row in wrappedRows(around: glyph) where self.bounds(of: row).intersects(bounds) {
                lower = min(lower, row.fragments.first?.glyphs.location ?? lower)
                upper = max(upper, row.fragments.last.map { NSMaxRange($0.glyphs) } ?? upper)
            }
        }
        guard lower < upper else { return range }
        return NSRange(location: lower, length: upper - lower)
    }

    override func glyphIndex(
        for point: NSPoint, in container: NSTextContainer, fractionOfDistanceThroughGlyph fraction: UnsafeMutablePointer<CGFloat>?
    ) -> Int {
        let found = super.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: fraction)
        guard let row = wrappedRows(around: found).first(where: { self.bounds(of: $0).insetBy(dx: -0.5, dy: 0).minY <= point.y && point.y < self.bounds(of: $0).maxY })
        else { return found }
        return glyphIndex(for: point, in: row, fraction: fraction)
    }

    override func characterIndex(
        for point: NSPoint, in container: NSTextContainer, fractionOfDistanceBetweenInsertionPoints fraction: UnsafeMutablePointer<CGFloat>?
    ) -> Int {
        let found = super.characterIndex(for: point, in: container, fractionOfDistanceBetweenInsertionPoints: fraction)
        let glyph = glyphIndexForCharacter(at: found)
        guard let row = wrappedRows(around: glyph).first(where: { self.bounds(of: $0).minY <= point.y && point.y < self.bounds(of: $0).maxY })
        else { return found }
        var through: CGFloat = 0
        let index = characterIndexForGlyph(at: glyphIndex(for: point, in: row, fraction: &through))
        fraction?.pointee = through
        return index
    }

    /// The glyph under a point in a wrapping row: the cell by the column the
    /// point is in, then its line, then the glyph along it. Below a cell's
    /// last line, the end of the cell.
    private func glyphIndex(for point: NSPoint, in row: WrappedRow, fraction: UnsafeMutablePointer<CGFloat>?) -> Int {
        let byColumn = Dictionary(grouping: row.fragments) { $0.rect.minX }
        let column = byColumn.keys.min { abs(distance(point.x, $0, byColumn[$0]?.first?.rect.width ?? 0)) < abs(distance(point.x, $1, byColumn[$1]?.first?.rect.width ?? 0)) } ?? 0
        let lines = (byColumn[column] ?? []).sorted { $0.rect.minY < $1.rect.minY }
        guard let fragment = lines.first(where: { point.y < $0.rect.maxY }) ?? lines.last else { return 0 }
        var best = fragment.glyphs.location
        var bestFraction: CGFloat = 0
        // The nearest glyph that is drawn: concealed ones take no room.
        for glyph in fragment.glyphs.location..<NSMaxRange(fragment.glyphs) where !propertyForGlyph(at: glyph).contains(.null) {
            let start = fragment.rect.minX + location(forGlyphAt: glyph).x
            let next = glyph + 1 < NSMaxRange(fragment.glyphs) ? fragment.rect.minX + location(forGlyphAt: glyph + 1).x : start
            let width = max(0, next - start)
            best = glyph
            if point.x < start + width || width == 0 && point.x < start {
                bestFraction = width > 0 ? max(0, min(1, (point.x - start) / width)) : 0
                break
            }
            bestFraction = 1
        }
        fraction?.pointee = bestFraction
        return best
    }

    /// How far a point is from a column: 0 inside it.
    private func distance(_ x: CGFloat, _ left: CGFloat, _ width: CGFloat) -> CGFloat {
        x < left ? left - x : x > left + width ? x - left - width : 0
    }
}

extension MarkdownLayoutManager {
    /// Marker kinds that hang into the margin when revealed: a quote's `>`,
    /// which sits beside the quote bar. Everything else, a heading's `## `
    /// included, makes room in the line and the text glides over for it.
    private static let hangingKinds: Set<Int> = [MarkerKind.quote.rawValue]

    /// The revealed quote markers a line starts with, when the line starts
    /// here; nil if it has none.
    fileprivate func hangingMarkers(at location: Int, in storage: NSTextStorage) -> NSRange? {
        let text = Self.text(of: storage)
        guard location < storage.length, location == 0 || text.character(at: location - 1) == 0x0A else { return nil }
        var end = location
        // Markers are short; this bounds the walk on a malformed line.
        let limit = min(storage.length, location + 16)
        while end < limit {
            let attributes = storage.attributes(at: end, effectiveRange: nil)
            guard let kind = attributes[.mdMarker] as? Int, Self.hangingKinds.contains(kind),
                  attributes[.mdConcealed] == nil, text.character(at: end) != 0x0A
            else { break }
            end += 1
        }
        return end > location ? NSRange(location: location, length: end - location) : nil
    }
}

extension MarkdownLayoutManager: NSLayoutManagerDelegate {
    /// A revealed quote's `> ` hangs into the margin beside the quote bar,
    /// so the quoted text stays where it sat while the marker was hidden.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>,
        lineFragmentUsedRect: UnsafeMutablePointer<NSRect>,
        baselineOffset: UnsafeMutablePointer<CGFloat>,
        in textContainer: NSTextContainer,
        forGlyphRange glyphRange: NSRange
    ) -> Bool {
        guard let storage = textStorage, glyphRange.length > 0 else { return false }
        let start = characterIndexForGlyph(at: glyphRange.location)
        guard let markers = hangingMarkers(at: start, in: storage) else { return false }
        let width = storage.attributedSubstring(from: markers).size().width
        // Only as far as the margin goes: a narrow window has little to spare.
        let margin = lineFragmentRect.pointee.minX + (firstTextView?.textContainerInset.width ?? 0)
        let shift = min(width, max(0, margin))
        guard shift > 0 else { return false }
        lineFragmentRect.pointee.origin.x -= shift
        lineFragmentUsedRect.pointee.origin.x -= shift
        return true
    }

    /// Concealed markers produce no glyphs, so `**bold**` reads as bold — while
    /// the characters are still there for the caret, selection and undo.
    func layoutManager(
        _ layoutManager: NSLayoutManager,
        shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
        properties: UnsafePointer<NSLayoutManager.GlyphProperty>,
        characterIndexes: UnsafePointer<Int>,
        font: NSFont,
        forGlyphRange glyphRange: NSRange
    ) -> Int {
        guard let storage = textStorage, storage.length > 0 else { return 0 }

        var newProperties = Array(UnsafeBufferPointer(start: properties, count: glyphRange.length))
        var newGlyphs = Array(UnsafeBufferPointer(start: glyphs, count: glyphRange.length))
        var changed = false
        // Attributes come in runs, so each is looked up once per run rather
        // than once per glyph: this runs for every glyph laid out.
        let length = storage.length
        var concealed = AttributeRun(key: .mdConcealed)
        var emojis = AttributeRun(key: .mdEmoji)
        var markers = AttributeRun(key: .mdMarker)

        for offset in 0..<glyphRange.length {
            let characterIndex = characterIndexes[offset]
            guard characterIndex < length else { continue }

            if concealed.value(at: characterIndex, in: storage) != nil {
                newProperties[offset] = .null
                changed = true
                continue
            }

            if let emoji = emojis.value(at: characterIndex, in: storage) as? String,
               let substitute = glyph(for: emoji, in: font) {
                newGlyphs[offset] = substitute
                // The colon has no glyph in the emoji font, so it arrives
                // flagged null; the substitute must be drawn.
                newProperties[offset] = []
                changed = true
                continue
            }

            guard let raw = markers.value(at: characterIndex, in: storage) as? Int,
                  let kind = MarkerKind(rawValue: raw)
            else { continue }

            // `-` becomes a bullet, `[x]` becomes a checkbox: the source stays
            // exactly as typed, only the glyphs change.
            // Fallbacks matter: not every font carries every box character.
            let candidates: [String] = switch kind {
            case .listBullet: isBulletCharacter(Self.text(of: storage), at: characterIndex) ? ["•"] : []
            case .taskChecked: ["☑", "✓", "•"]
            case .taskUnchecked: ["☐", "□", "▫", "◦"]
            default: []
            }
            if let substitute = candidates.lazy.compactMap({ self.glyph(for: $0, in: font) }).first {
                newGlyphs[offset] = substitute
                changed = true
            }
        }

        guard changed, newGlyphs.count == glyphRange.length, newProperties.count == glyphRange.length else {
            return 0
        }
        layoutManager.setGlyphs(
            &newGlyphs,
            properties: &newProperties,
            characterIndexes: characterIndexes,
            font: font,
            forGlyphRange: glyphRange
        )
        return glyphRange.length
    }

    private func isBulletCharacter(_ text: NSString, at index: Int) -> Bool {
        let character = text.character(at: index)
        return character == UInt16(UnicodeScalar("-").value)
            || character == UInt16(UnicodeScalar("*").value)
            || character == UInt16(UnicodeScalar("+").value)
    }
}

/// One attribute's value over the run holding the last index asked about.
private struct AttributeRun {
    let key: NSAttributedString.Key
    private var range = NSRange(location: NSNotFound, length: 0)
    private var current: Any?

    init(key: NSAttributedString.Key) {
        self.key = key
    }

    mutating func value(at index: Int, in storage: NSTextStorage) -> Any? {
        if !NSLocationInRange(index, range) {
            current = storage.attribute(key, at: index, effectiveRange: &range)
        }
        return current
    }
}
