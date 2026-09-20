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

    // MARK: - Block decoration

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let storage = textStorage, let container = textContainers.first else { return }

        let characterRange = self.characterRange(forGlyphRange: glyphsToShow, actualGlyphRange: nil)

        enumerateLineFragments(forGlyphRange: glyphsToShow) { _, usedRect, _, lineGlyphRange, _ in
            let lineCharacters = self.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
            guard lineCharacters.location < storage.length else { return }
            let attributes = storage.attributes(at: lineCharacters.location, effectiveRange: nil)

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

        for offset in 0..<glyphRange.length {
            let characterIndex = characterIndexes[offset]
            guard characterIndex < storage.length else { continue }

            if storage.attribute(.mdConcealed, at: characterIndex, effectiveRange: nil) != nil {
                newProperties[offset] = .null
                changed = true
                continue
            }

            guard let raw = storage.attribute(.mdMarker, at: characterIndex, effectiveRange: nil) as? Int,
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
