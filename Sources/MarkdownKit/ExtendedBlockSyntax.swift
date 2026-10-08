import Foundation

// Recognisers for front matter, HTML blocks, and link and footnote definitions.

/// `---` alone on the first line opens YAML front matter.
func isFrontMatterOpening(_ line: [UInt16]) -> Bool {
    guard line.count >= 3, line[0] == UInt16(ascii: "-"), line[1] == UInt16(ascii: "-"), line[2] == UInt16(ascii: "-")
    else { return false }
    return isBlank(line, from: 3)
}

/// `---` or `...` closes it.
func isFrontMatterClosing(_ line: [UInt16]) -> Bool {
    if isFrontMatterOpening(line) { return true }
    guard line.count >= 3, line[0] == UInt16(ascii: "."), line[1] == UInt16(ascii: "."), line[2] == UInt16(ascii: ".")
    else { return false }
    return isBlank(line, from: 3)
}

/// `$$` alone on a line (spaces aside) opens or closes display math.
func isMathFence(_ line: [UInt16], from index: Int) -> Bool {
    guard index + 1 < line.count, line[index] == UInt16(ascii: "$"), line[index + 1] == UInt16(ascii: "$") else { return false }
    return isBlank(line, from: index + 2)
}

/// What ends an HTML block, per the CommonMark start conditions.
public enum HTMLBlockEnd: Equatable, Sendable {
    case blankLine
    /// A lowercase string whose appearance on a line ends the block there.
    case terminator(String)
}

private let rawTextTags = ["script", "pre", "style", "textarea"]

private let blockTags: Set<String> = [
    "address", "article", "aside", "base", "basefont", "blockquote", "body", "caption", "center", "col",
    "colgroup", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure",
    "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hr",
    "html", "iframe", "legend", "li", "link", "main", "menu", "menuitem", "nav", "noframes", "ol",
    "optgroup", "option", "p", "param", "search", "section", "summary", "table", "tbody", "td", "tfoot",
    "th", "thead", "title", "tr", "track", "ul",
]

/// Whether a line opens an HTML block, and if so what will close it.
///
/// - Parameter afterParagraph: the line would otherwise continue a paragraph,
///   which only the first six kinds of HTML block may interrupt.
func htmlBlockStart(_ line: [UInt16], from index: Int, afterParagraph: Bool) -> HTMLBlockEnd? {
    guard index < line.count, line[index] == UInt16(ascii: "<") else { return nil }
    let rest = string(line, from: index, to: line.count).lowercased()

    for tag in rawTextTags where rest.hasPrefix("<" + tag) {
        let after = rest.dropFirst(tag.count + 1).first
        if after == nil || after == " " || after == "\t" || after == ">" {
            return .terminator("</\(tag)>")
        }
    }
    if rest.hasPrefix("<!--") { return .terminator("-->") }
    if rest.hasPrefix("<?") { return .terminator("?>") }
    if rest.hasPrefix("<![cdata[") { return .terminator("]]>") }
    if rest.hasPrefix("<!"), let letter = rest.dropFirst(2).first, letter.isLetter { return .terminator(">") }

    // A known block-level tag name, opening or closing.
    let nameStart = rest.hasPrefix("</") ? 2 : 1
    let name = rest.dropFirst(nameStart).prefix { $0.isLetter || $0.isNumber }
    if blockTags.contains(String(name)) {
        let after = rest.dropFirst(nameStart + name.count)
        if after.isEmpty || after.hasPrefix(" ") || after.hasPrefix("\t") || after.hasPrefix(">") || after.hasPrefix("/>") {
            return .blankLine
        }
    }

    // Any other complete tag alone on its line, unless it would interrupt a paragraph.
    // The name must end at whitespace, `/` or `>`, which rules out `<https://…>`.
    let afterName = rest.dropFirst(nameStart + name.count).first
    let nameEndsCleanly = afterName == nil || afterName == " " || afterName == "\t" || afterName == "/" || afterName == ">"
    if !afterParagraph, !name.isEmpty, nameEndsCleanly, !rawTextTags.contains(String(name)),
       let end = parseRawHTML(line, at: index, limit: line.count), isBlank(line, from: end) {
        return .blankLine
    }
    return nil
}

/// Whether a line inside an HTML block is its last.
func htmlBlockEnds(_ end: HTMLBlockEnd, on line: [UInt16], from index: Int) -> Bool {
    guard case let .terminator(terminator) = end else { return false }
    return string(line, from: index, to: line.count).lowercased().contains(terminator)
}

public struct LinkDefinition: Equatable, Sendable {
    public var destination: String
    public var title: String?

    public init(destination: String, title: String? = nil) {
        self.destination = destination
        self.title = title
    }
}

/// Labels match with Unicode case folding (so `ẞ` matches `SS`) and
/// internal whitespace collapsed.
public func normalizeLabel(_ label: String) -> String {
    label.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        .folding(options: .caseInsensitive, locale: nil).lowercased()
}

/// `[label]: destination "optional title"`, on a single line.
func linkReferenceDefinition(_ line: [UInt16], from index: Int) -> (label: String, definition: LinkDefinition)? {
    guard index < line.count, line[index] == UInt16(ascii: "[") else { return nil }
    var cursor = index + 1
    while cursor < line.count, line[cursor] != UInt16(ascii: "]") {
        if line[cursor] == UInt16(ascii: "[") { return nil }
        if line[cursor] == UInt16(ascii: "\\") { cursor += 1 }
        cursor += 1
    }
    guard cursor < line.count else { return nil }
    let label = string(line, from: index + 1, to: cursor)
    guard !normalizeLabel(label).isEmpty, !label.hasPrefix("^") else { return nil }
    cursor += 1
    guard cursor < line.count, line[cursor] == UInt16(ascii: ":") else { return nil }
    cursor = skipSpaces(line, from: cursor + 1, limit: Int.max)
    guard cursor < line.count else { return nil }

    var destination: String
    if line[cursor] == UInt16(ascii: "<") {
        let start = cursor + 1
        cursor = start
        while cursor < line.count, line[cursor] != UInt16(ascii: ">") { cursor += 1 }
        guard cursor < line.count else { return nil }
        destination = string(line, from: start, to: cursor)
        cursor += 1
    } else {
        let start = cursor
        while cursor < line.count, !isUnicodeWhitespace(line[cursor]) { cursor += 1 }
        destination = string(line, from: start, to: cursor)
    }

    let afterDestination = cursor
    cursor = skipSpaces(line, from: cursor, limit: Int.max)
    var title: String?
    if cursor < line.count {
        // A title must be separated from the destination by whitespace.
        guard cursor > afterDestination else { return nil }
        let open = line[cursor]
        let close: UInt16
        switch open {
        case UInt16(ascii: "\""), UInt16(ascii: "'"): close = open
        case UInt16(ascii: "("): close = UInt16(ascii: ")")
        default: return nil
        }
        let start = cursor + 1
        cursor = start
        while cursor < line.count, line[cursor] != close {
            if line[cursor] == UInt16(ascii: "\\") { cursor += 1 }
            cursor += 1
        }
        guard cursor < line.count else { return nil }
        title = string(line, from: start, to: cursor)
        guard isBlank(line, from: cursor + 1) else { return nil }
    }
    return (label, LinkDefinition(destination: destination, title: title))
}

/// `[^label]: text` — returns the label and where the text begins.
func footnoteDefinition(_ line: [UInt16], from index: Int) -> (label: String, labelEnd: Int, contentStart: Int)? {
    guard let label = footnoteLabel(line, at: index, limit: line.count) else { return nil }
    guard label.end < line.count, line[label.end] == UInt16(ascii: ":") else { return nil }
    let labelEnd = label.end + 1
    return (label.label, labelEnd, skipSpaces(line, from: labelEnd, limit: Int.max))
}

/// `[^label]`: a caret, then a label with no whitespace or brackets.
func footnoteLabel(_ characters: [UInt16], at index: Int, limit: Int) -> (label: String, end: Int)? {
    guard index + 2 < limit,
          characters[index] == UInt16(ascii: "["),
          characters[index + 1] == UInt16(ascii: "^")
    else { return nil }
    var cursor = index + 2
    while cursor < limit, characters[cursor] != UInt16(ascii: "]") {
        let character = characters[cursor]
        if isUnicodeWhitespace(character) || character == UInt16(ascii: "[") { return nil }
        cursor += 1
    }
    guard cursor < limit, cursor > index + 2 else { return nil }
    return (string(characters, from: index + 2, to: cursor), cursor + 1)
}
