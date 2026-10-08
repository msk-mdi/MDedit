import Foundation

/// Inline markup as a tree, so one structure serves both the editor (apply
/// attributes while walking) and the HTML renderer (emit nested tags).
///
/// Every range is relative to the start of the character array handed to the
/// parser; callers add the line's own offset.
public indirect enum InlineNode: Equatable, Sendable {
    case text(NSRange)
    case code(range: NSRange, content: NSRange, markers: [Marker])
    case emphasis(range: NSRange, markers: [Marker], children: [InlineNode])
    case strong(range: NSRange, markers: [Marker], children: [InlineNode])
    case strikethrough(range: NSRange, markers: [Marker], children: [InlineNode])
    /// `==marked==`.
    case highlight(range: NSRange, markers: [Marker], children: [InlineNode])
    case link(range: NSRange, markers: [Marker], destination: String, title: String?, children: [InlineNode])
    case image(range: NSRange, markers: [Marker], source: String, alt: String)
    case autolink(range: NSRange, markers: [Marker], url: String)
    case escape(range: NSRange, marker: NSRange, character: NSRange)
    case rawHTML(NSRange)
    /// `[^label]`, a reference to a footnote.
    case footnoteReference(range: NSRange, markers: [Marker], label: String)
    /// `$x^2$` (inline) or `$$x^2$$` (display) TeX, not parsed further.
    case math(range: NSRange, markers: [Marker], content: NSRange, display: Bool)
    /// `^up^` and `~down~`.
    case superscript(range: NSRange, markers: [Marker], children: [InlineNode])
    case `subscript`(range: NSRange, markers: [Marker], children: [InlineNode])
    /// `:smile:`, with the emoji it names.
    case emoji(range: NSRange, markers: [Marker], shortcode: String, emoji: String)

    public var range: NSRange {
        switch self {
        case let .text(range): range
        case let .code(range, _, _): range
        case let .emphasis(range, _, _): range
        case let .strong(range, _, _): range
        case let .strikethrough(range, _, _): range
        case let .highlight(range, _, _): range
        case let .footnoteReference(range, _, _): range
        case let .math(range, _, _, _): range
        case let .superscript(range, _, _): range
        case let .subscript(range, _, _): range
        case let .emoji(range, _, _, _): range
        case let .link(range, _, _, _, _): range
        case let .image(range, _, _, _): range
        case let .autolink(range, _, _): range
        case let .escape(range, _, _): range
        case let .rawHTML(range): range
        }
    }

    public var markers: [Marker] {
        switch self {
        case .text, .rawHTML: []
        case let .code(_, _, markers): markers
        case let .emphasis(_, markers, _): markers
        case let .strong(_, markers, _): markers
        case let .strikethrough(_, markers, _): markers
        case let .highlight(_, markers, _): markers
        case let .footnoteReference(_, markers, _): markers
        case let .math(_, markers, _, _): markers
        case let .superscript(_, markers, _): markers
        case let .subscript(_, markers, _): markers
        case let .emoji(_, markers, _, _): markers
        case let .link(_, markers, _, _, _): markers
        case let .image(_, markers, _, _): markers
        case let .autolink(_, markers, _): markers
        case let .escape(_, marker, _): [Marker(range: marker, kind: .conceal)]
        }
    }

    public var children: [InlineNode] {
        switch self {
        case let .emphasis(_, _, children): children
        case let .strong(_, _, children): children
        case let .strikethrough(_, _, children): children
        case let .highlight(_, _, children): children
        case let .superscript(_, _, children): children
        case let .subscript(_, _, children): children
        case let .link(_, _, _, _, children): children
        default: []
        }
    }
}

/// The link and footnote definitions a document makes, for resolving
/// `[text][label]`, `[label]` and `[^note]`.
public struct LinkReferences: Equatable, Sendable {
    /// Keyed by `normalizeLabel`.
    public var links: [String: LinkDefinition]
    public var footnotes: Set<String>
    /// Export only links what is defined. The editor styles `[text][label]` as
    /// a link either way, because adding a definition does not restyle every
    /// line that uses it.
    public var requireDefinitions: Bool

    public init(links: [String: LinkDefinition] = [:], footnotes: Set<String> = [], requireDefinitions: Bool = false) {
        self.links = links
        self.footnotes = footnotes
        self.requireDefinitions = requireDefinitions
    }

    public static let lenient = LinkReferences()

    /// Gathers every definition in a document; the first of a label wins.
    public static func collect(from structure: BlockStructure, requireDefinitions: Bool) -> LinkReferences {
        var references = LinkReferences(requireDefinitions: requireDefinitions)
        for line in structure.lines {
            switch line.kind {
            case let .linkReferenceDefinition(label, definition):
                let key = normalizeLabel(label)
                if references.links[key] == nil { references.links[key] = definition }
            case let .footnoteDefinition(label):
                references.footnotes.insert(normalizeLabel(label))
            default:
                break
            }
        }
        return references
    }
}

public enum InlineParser {
    public static func parse(_ characters: [UInt16], references: LinkReferences = .lenient) -> [InlineNode] {
        parse(characters, from: 0, to: characters.count, references: references)
    }

    public static func parse(
        _ characters: [UInt16],
        from low: Int,
        to high: Int,
        references: LinkReferences = .lenient
    ) -> [InlineNode] {
        var nodes: [InlineNode] = []
        var textStart = low
        var cursor = low

        func flushText(upTo end: Int) {
            if end > textStart {
                nodes.append(.text(NSRange(location: textStart, length: end - textStart)))
            }
        }

        while cursor < high {
            let character = characters[cursor]
            var node: InlineNode?
            var nextCursor = cursor

            switch character {
            case UInt16(ascii: "\\"):
                if cursor + 1 < high, isUnicodePunctuation(characters[cursor + 1]) {
                    node = .escape(
                        range: NSRange(location: cursor, length: 2),
                        marker: NSRange(location: cursor, length: 1),
                        character: NSRange(location: cursor + 1, length: 1)
                    )
                    nextCursor = cursor + 2
                }

            case UInt16(ascii: "`"):
                if let code = parseCodeSpan(characters, at: cursor, limit: high) {
                    node = code.node
                    nextCursor = code.end
                }

            case UInt16(ascii: "<"):
                if let auto = parseAutolink(characters, at: cursor, limit: high) {
                    node = auto.node
                    nextCursor = auto.end
                } else if let html = parseRawHTML(characters, at: cursor, limit: high) {
                    node = .rawHTML(NSRange(location: cursor, length: html - cursor))
                    nextCursor = html
                }

            case UInt16(ascii: "!"), UInt16(ascii: "["):
                if let footnote = parseFootnoteReference(characters, at: cursor, limit: high, references: references) {
                    node = footnote.node
                    nextCursor = footnote.end
                } else if let link = parseLinkOrImage(characters, at: cursor, limit: high, references: references) {
                    node = link.node
                    nextCursor = link.end
                }

            case UInt16(ascii: "$"):
                if let math = parseMath(characters, at: cursor, limit: high) {
                    node = math.node
                    nextCursor = math.end
                }

            case UInt16(ascii: "^"):
                if let superscript = parseSuperscript(characters, at: cursor, limit: high, references: references) {
                    node = superscript.node
                    nextCursor = superscript.end
                }

            case UInt16(ascii: ":"):
                if cursor == low || !isWordCharacter(characters[cursor - 1]),
                   let emoji = parseEmoji(characters, at: cursor, limit: high) {
                    node = emoji.node
                    nextCursor = emoji.end
                }

            case UInt16(ascii: "h"), UInt16(ascii: "w"):
                // Bare URLs start a word: at the start, or after space or opening punctuation.
                if cursor == low || isURLBoundary(characters[cursor - 1]),
                   let url = parseBareURL(characters, at: cursor, limit: high) {
                    node = url.node
                    nextCursor = url.end
                }

            case UInt16(ascii: "*"), UInt16(ascii: "_"), UInt16(ascii: "~"), UInt16(ascii: "="):
                if let emphasis = parseEmphasis(characters, at: cursor, limit: high, references: references) {
                    flushText(upTo: emphasis.openStart)
                    textStart = emphasis.openStart
                    node = emphasis.node
                    nextCursor = emphasis.end
                }

            default:
                break
            }

            if let node {
                flushText(upTo: node.range.location)
                nodes.append(node)
                cursor = nextCursor
                textStart = cursor
            } else {
                cursor += 1
            }
        }

        flushText(upTo: high)
        return nodes
    }
}
