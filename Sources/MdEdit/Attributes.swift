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
    /// Set on table rows: a `TableGrid` when the table is drawn as a grid,
    /// otherwise striped source — the width it needs when too wide for a grid.
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
    /// Set on lines still waiting for an image or a typeset formula, so its
    /// arrival restyles those lines rather than the whole document.
    static let mdAwaiting = NSAttributedString.Key("mdAwaiting")
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
        var clearsCodeCard: Bool
    }

    mutating func style(
        listDepth: Int,
        quoteDepth: Int,
        isCode: Bool,
        isHeading: Bool,
        isListItem: Bool = false,
        hangingIndent: CGFloat,
        endsBlock: Bool = false,
        clearsCodeCard: Bool = false,
        theme: Theme
    ) -> NSParagraphStyle {
        let key = Key(
            listDepth: listDepth,
            quoteDepth: quoteDepth,
            isCode: isCode,
            isHeading: isHeading,
            isListItem: isListItem,
            hangingIndent: hangingIndent,
            endsBlock: endsBlock,
            clearsCodeCard: clearsCodeCard
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
        // Blank lines already separate blocks; Settings can add more after
        // each one. Nothing goes before a heading: TextKit 1 drops that space
        // while `## ` is concealed and adds it once the marker shows, so the
        // page would drop a few points each time the caret reached a heading.
        style.paragraphSpacing = endsBlock ? theme.paragraphSpacing : 0
        // The card's padding, and as much again between it and the caret.
        if clearsCodeCard { style.paragraphSpacing = 2 * Metrics.codeCardPadding }
        style.paragraphSpacingBefore = 0
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
        return FontCache.font(base, withTraits: traits)
    }
}

/// One row of a table drawn as a grid: where its column lines fall and how
/// tall it is. The cells' text is laid into the columns by kerning the
/// invisible pipes between them.
final class TableGrid: NSObject {
    /// Column edges, from the paragraph's indent; one more than the columns.
    let edges: [CGFloat]
    /// The paragraph's indent, where the grid starts.
    let indent: CGFloat
    let height: CGFloat
    let isHeader: Bool
    let isLast: Bool
    /// The delimiter row, shown as source while the caret is on it: only the
    /// outer lines are drawn, as its dashes do not sit in the columns.
    let isDelimiter: Bool
    /// How wide the grid would be with no cell wrapping.
    let naturalWidth: CGFloat
    /// Set when the table is too wide for the column and its cells wrap:
    /// `TableTypesetter` then lays out the row, each cell in its column.
    let wrapping: Wrapping?

    struct Wrapping: Equatable {
        /// Where the cells' text is, from the start of the line.
        var cells: [NSRange]
        var padding: CGFloat
        var verticalPadding: CGFloat
        /// The height of each line of a cell, and where its baseline sits.
        var lineHeight: CGFloat
        var baseline: CGFloat
        /// Each column's alignment: 0 left, 0.5 centred, 1 right.
        var alignment: [CGFloat]
    }

    init(
        edges: [CGFloat], indent: CGFloat, height: CGFloat, isHeader: Bool, isLast: Bool, isDelimiter: Bool,
        naturalWidth: CGFloat? = nil, wrapping: Wrapping? = nil
    ) {
        self.naturalWidth = naturalWidth ?? indent + (edges.last ?? 0)
        self.wrapping = wrapping
        self.edges = edges
        self.indent = indent
        self.height = height
        self.isHeader = isHeader
        self.isLast = isLast
        self.isDelimiter = isDelimiter
    }

    // Equal by value, so restyling a row the same way leaves it unchanged.
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? TableGrid else { return false }
        return edges == other.edges && indent == other.indent && height == other.height
            && isHeader == other.isHeader && isLast == other.isLast && isDelimiter == other.isDelimiter
            && naturalWidth == other.naturalWidth && wrapping == other.wrapping
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(edges)
        hasher.combine(height)
        hasher.combine(isHeader)
        return hasher.finalize()
    }
}
