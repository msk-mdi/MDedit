import AppKit
import MarkdownKit

extension NSAttributedString.Key {
    /// A syntax marker, carrying its `MarkerKind` raw value. The layout manager
    /// hides or substitutes glyphs for these.
    static let mdMarker = NSAttributedString.Key("mdMarker")
    /// Set on markers that should not be drawn at all right now.
    static let mdConcealed = NSAttributedString.Key("mdConcealed")
    /// Set on lines inside a fenced or indented code block.
    static let mdCodeBlock = NSAttributedString.Key("mdCodeBlock")
    /// Set on inline code spans.
    static let mdInlineCode = NSAttributedString.Key("mdInlineCode")
    /// Blockquote nesting depth, used to draw the quote bars.
    static let mdQuoteDepth = NSAttributedString.Key("mdQuoteDepth")
    /// A link's destination, for Command-click.
    static let mdLink = NSAttributedString.Key("mdLink")
    /// Set on a thematic break line, drawn as a rule.
    static let mdThematicBreak = NSAttributedString.Key("mdThematicBreak")
    /// Set on table rows, for striping.
    static let mdTableRow = NSAttributedString.Key("mdTableRow")
    /// The emoji a shortcode's closing colon is drawn as.
    static let mdEmoji = NSAttributedString.Key("mdEmoji")
    /// An `InlineImage` drawn above a line that holds only an image.
    static let mdImage = NSAttributedString.Key("mdImage")
    /// An `InlineImage` of typeset TeX, drawn over the invisible glyph that
    /// holds its place in the line.
    static let mdMath = NSAttributedString.Key("mdMath")
    /// Set on lines folded away under a heading.
    static let mdFolded = NSAttributedString.Key("mdFolded")
}

/// Paragraph styles are shared: one per shape of line, built once.
struct ParagraphStyleCache {
    private var styles: [Key: NSParagraphStyle] = [:]

    private struct Key: Hashable {
        var listDepth: Int
        var quoteDepth: Int
        var isCode: Bool
        var isHeading: Bool
        var isListItem: Bool
        var hangingIndent: CGFloat
        var endsBlock: Bool
    }

    mutating func style(
        listDepth: Int,
        quoteDepth: Int,
        isCode: Bool,
        isHeading: Bool,
        isListItem: Bool = false,
        hangingIndent: CGFloat,
        endsBlock: Bool = false,
        theme: Theme
    ) -> NSParagraphStyle {
        let key = Key(
            listDepth: listDepth,
            quoteDepth: quoteDepth,
            isCode: isCode,
            isHeading: isHeading,
            isListItem: isListItem,
            hangingIndent: hangingIndent,
            endsBlock: endsBlock
        )
        if let cached = styles[key] { return cached }

        let style = NSMutableParagraphStyle()
        let step: CGFloat = 22
        let indent = CGFloat(listDepth + quoteDepth) * step
        style.firstLineHeadIndent = indent
        // Wrapped lines line up with the text, not the bullet.
        style.headIndent = indent + hangingIndent
        // Code keeps the default's proportion to prose: a little tighter.
        style.lineHeightMultiple = isCode ? theme.lineHeight * (1.2 / 1.35) : theme.lineHeight
        // Blank lines already separate blocks, so by default only headings add
        // space of their own; Settings can add more after each block.
        style.paragraphSpacing = endsBlock ? theme.paragraphSpacing : 0
        style.paragraphSpacingBefore = isHeading ? theme.bodyFontSize * 0.5 : 0
        style.tighteningFactorForTruncation = 0

        let immutable = style.copy() as! NSParagraphStyle
        styles[key] = immutable
        return immutable
    }

    mutating func removeAll() {
        styles.removeAll()
    }
}

/// Traits accumulated while walking nested inline nodes.
struct InlineStyle {
    var bold = false
    var italic = false
    var strikethrough = false

    func font(base: NSFont) -> NSFont {
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        guard !traits.isEmpty else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: traits)
    }
}
