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
    case link(range: NSRange, markers: [Marker], destination: String, title: String?, children: [InlineNode])
    case image(range: NSRange, markers: [Marker], source: String, alt: String)
    case autolink(range: NSRange, markers: [Marker], url: String)
    case escape(range: NSRange, marker: NSRange, character: NSRange)
    case rawHTML(NSRange)

    public var range: NSRange {
        switch self {
        case let .text(range): range
        case let .code(range, _, _): range
        case let .emphasis(range, _, _): range
        case let .strong(range, _, _): range
        case let .strikethrough(range, _, _): range
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
        case let .link(_, _, _, _, children): children
        default: []
        }
    }
}

public enum InlineParser {
    public static func parse(_ characters: [UInt16]) -> [InlineNode] {
        parse(characters, from: 0, to: characters.count)
    }

    public static func parse(_ characters: [UInt16], from low: Int, to high: Int) -> [InlineNode] {
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
                if let link = parseLinkOrImage(characters, at: cursor, limit: high) {
                    node = link.node
                    nextCursor = link.end
                }

            case UInt16(ascii: "*"), UInt16(ascii: "_"), UInt16(ascii: "~"):
                if let emphasis = parseEmphasis(characters, at: cursor, limit: high) {
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
