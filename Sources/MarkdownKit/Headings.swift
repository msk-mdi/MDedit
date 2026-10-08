import Foundation

/// A heading as a reader sees it: for anchors, export ids and the outline.
public struct Heading: Equatable, Sendable {
    /// The line holding the heading's text (for setext headings, the line
    /// above the underline).
    public var line: Int
    public var level: Int
    /// The heading's text with inline markup removed.
    public var title: String
    /// The anchor `#slug` links to, unique within the document.
    public var slug: String
}

/// GitHub-style anchors: lowercase, punctuation dropped, spaces to hyphens.
public func headingSlug(_ title: String) -> String {
    var slug = ""
    for character in title.lowercased() {
        if character.isLetter || character.isNumber || character == "-" || character == "_" {
            slug.append(character)
        } else if character == " " {
            slug.append("-")
        }
    }
    return slug
}

/// Makes repeated titles unique the way GitHub does: `a`, `a-1`, `a-2`.
public struct SlugGenerator {
    private var counts: [String: Int] = [:]

    public init() {}

    public mutating func slug(for title: String) -> String {
        let base = headingSlug(title)
        let count = counts[base, default: 0]
        counts[base] = count + 1
        return count == 0 ? base : "\(base)-\(count)"
    }
}

/// Inline content flattened to the text a reader sees.
public func plainText(_ characters: [UInt16], from low: Int, to high: Int) -> String {
    guard low < high else { return "" }
    return flattenInline(InlineParser.parse(characters, from: low, to: high), characters)
        .trimmingCharacters(in: .whitespaces)
}

/// The text a reader sees in inline nodes, as in image alt text and outlines.
func flattenInline(_ nodes: [InlineNode], _ characters: [UInt16]) -> String {
    var out = ""
    for node in nodes {
        switch node {
        case let .text(range):
            out += string(characters, from: range.location, to: NSMaxRange(range))
        case let .code(_, content, _):
            out += codeSpanText(string(characters, from: content.location, to: NSMaxRange(content)))
        case let .escape(_, _, character):
            out += string(characters, from: character.location, to: NSMaxRange(character))
        case let .image(_, _, _, alt, _):
            out += alt
        case let .autolink(range, markers, _):
            let shown = markers.count == 2 ? NSRange(location: range.location + 1, length: range.length - 2) : range
            out += string(characters, from: shown.location, to: NSMaxRange(shown))
        case let .math(_, _, content, _):
            out += string(characters, from: content.location, to: NSMaxRange(content))
        case let .emoji(_, _, _, emoji):
            out += emoji
        case let .entity(_, text):
            out += text
        case let .lineBreak(_, hard):
            out += hard ? "\n" : " "
        case .rawHTML, .footnoteReference:
            break
        case .emphasis, .strong, .strikethrough, .highlight, .link, .superscript, .subscript:
            out += flattenInline(node.children, characters)
        }
    }
    return out
}

/// The end of an ATX heading's text, excluding any closing `###`.
func headingContentEnd(_ info: LineInfo, _ characters: [UInt16]) -> Int {
    if let closing = info.markers.last, closing.kind == .conceal, closing.range.location > info.contentStart,
       NSMaxRange(closing.range) == characters.count, info.markers.count > 1 {
        return closing.range.location
    }
    return characters.count
}

extension BlockStructure {
    /// Every heading in document order, with unique slugs.
    public func headings(in text: NSString) -> [Heading] {
        var slugs = SlugGenerator()
        var result: [Heading] = []
        for (line, info) in lines.enumerated() {
            let level: Int
            var end: Int?
            if case let .atxHeading(atxLevel) = info.kind {
                level = atxLevel
            } else if info.kind == .paragraph, line + 1 < lines.count,
                      case let .setextUnderline(setextLevel) = lines[line + 1].kind {
                level = setextLevel
            } else {
                continue
            }
            let characters = self.characters(of: text, line: line)
            if case .atxHeading = info.kind { end = headingContentEnd(info, characters) }
            let title = plainText(characters, from: info.contentStart, to: end ?? characters.count)
            result.append(Heading(line: line, level: level, title: title, slug: slugs.slug(for: title)))
        }
        return result
    }
}
