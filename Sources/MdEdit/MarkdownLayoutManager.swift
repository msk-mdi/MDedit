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

    private var substituteGlyphs: [String: CGGlyph] = [:]

    override init() {
        super.init()
        delegate = self
        // Custom glyph generation and non-contiguous layout do not mix: the
        // layout manager throws filling glyph holes it never generated.
        allowsNonContiguousLayout = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Focus mode dims every line but the one being written.
    override func drawGlyphs(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawGlyphs(forGlyphRange: glyphsToShow, at: origin)
        drawInlineMath(forGlyphRange: glyphsToShow, at: origin)
        guard let focusRange, let container = textContainers.first else { return }

        let focusGlyphs = glyphRange(forCharacterRange: focusRange, actualCharacterRange: nil)
        theme.canvas.withAlphaComponent(0.55).setFill()
        enumerateLineFragments(forGlyphRange: glyphsToShow) { rect, _, _, lineGlyphRange, _ in
            guard NSIntersectionRange(lineGlyphRange, focusGlyphs).length == 0 else { return }
            var dim = rect.offsetBy(dx: origin.x, dy: origin.y)
            dim.size.width = container.size.width
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
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

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
               let number = markdown.headingNumber(forLine: markdown.line(at: lineCharacters.location)) {
                self.drawHeadingNumber(number, glyphRange: lineGlyphRange, fragment: fragmentRect, attributes: attributes, origin: origin)
            }

            var rect = usedRect.offsetBy(dx: origin.x, dy: origin.y)
            // Decoration spans the text column, not just the glyphs that were
            // used. `origin` already accounts for the container inset.
            rect.origin.x = origin.x
            rect.size.width = container.size.width

            if attributes[.mdCodeBlock] != nil {
                self.theme.codeBackground.setFill()
                rect.fill()
            }

            if attributes[.mdTableRow] != nil {
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
        let content = storage.structure.index.contentRange(ofLine: line, in: storage.string as NSString)
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
        let start = (storage.string as NSString).paragraphRange(for: NSRange(location: location, length: 0)).location
        for index in start..<location where storage.attribute(.mdConcealed, at: index, effectiveRange: nil) == nil {
            return false
        }
        return true
    }

    private func isLastFragmentOfParagraph(_ lineCharacters: NSRange, in storage: NSTextStorage) -> Bool {
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: lineCharacters.location, length: 0))
        return NSMaxRange(lineCharacters) >= NSMaxRange(paragraph)
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

extension MarkdownLayoutManager: NSLayoutManagerDelegate {
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
            case .listBullet: isBulletCharacter(storage.string, at: characterIndex) ? ["•"] : []
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

    private func isBulletCharacter(_ string: String, at index: Int) -> Bool {
        let character = (string as NSString).character(at: index)
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
