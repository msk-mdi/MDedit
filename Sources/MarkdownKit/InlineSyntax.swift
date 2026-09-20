import Foundation

// Recognisers for individual inline constructs. Each returns the node it built
// and the offset just past it, or nil to let the character be plain text.

struct InlineMatch {
    var node: InlineNode
    var end: Int
}

private func marker(_ location: Int, _ length: Int) -> Marker {
    Marker(range: NSRange(location: location, length: length), kind: .conceal)
}

/// A code span: a run of backticks, matched by a run of exactly the same length.
func parseCodeSpan(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    guard let open = delimiterRun(characters, at: index, character: UInt16(ascii: "`")),
          open.end <= limit
    else { return nil }

    var cursor = open.end
    while cursor < limit {
        guard characters[cursor] == UInt16(ascii: "`") else {
            cursor += 1
            continue
        }
        guard let close = delimiterRun(characters, at: cursor, character: UInt16(ascii: "`")) else { break }
        if close.count == open.count, close.end <= limit {
            let range = NSRange(location: index, length: close.end - index)
            let content = NSRange(location: open.end, length: cursor - open.end)
            return InlineMatch(
                node: .code(
                    range: range,
                    content: content,
                    markers: [marker(index, open.count), marker(cursor, close.count)]
                ),
                end: close.end
            )
        }
        cursor = close.end
    }
    return nil
}

/// `<https://example.com>` and `<someone@example.com>`.
func parseAutolink(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    var cursor = index + 1
    var sawColon = false
    var sawAt = false
    while cursor < limit {
        let character = characters[cursor]
        if character == UInt16(ascii: ">") { break }
        if isUnicodeWhitespace(character) || character == UInt16(ascii: "<") { return nil }
        if character == UInt16(ascii: ":") { sawColon = true }
        if character == UInt16(ascii: "@") { sawAt = true }
        cursor += 1
    }
    guard cursor < limit, cursor > index + 1, sawColon || sawAt else { return nil }

    let body = string(characters, from: index + 1, to: cursor)
    let url = sawColon ? body : "mailto:\(body)"
    return InlineMatch(
        node: .autolink(
            range: NSRange(location: index, length: cursor + 1 - index),
            markers: [marker(index, 1), marker(cursor, 1)],
            url: url
        ),
        end: cursor + 1
    )
}

/// A bare HTML tag, passed through untouched.
func parseRawHTML(_ characters: [UInt16], at index: Int, limit: Int) -> Int? {
    var cursor = index + 1
    if cursor < limit, characters[cursor] == UInt16(ascii: "/") { cursor += 1 }
    guard cursor < limit, isASCIILetter(characters[cursor]) else { return nil }
    while cursor < limit, characters[cursor] != UInt16(ascii: ">") {
        if characters[cursor] == UInt16(ascii: "<") { return nil }
        cursor += 1
    }
    guard cursor < limit else { return nil }
    return cursor + 1
}

/// The matching `]` for a `[`, tolerating nesting, escapes and code spans.
private func matchingBracket(_ characters: [UInt16], from index: Int, limit: Int) -> Int? {
    var depth = 0
    var cursor = index
    while cursor < limit {
        switch characters[cursor] {
        case UInt16(ascii: "\\"):
            cursor += 1
        case UInt16(ascii: "`"):
            if let code = parseCodeSpan(characters, at: cursor, limit: limit) {
                cursor = code.end - 1
            }
        case UInt16(ascii: "["):
            depth += 1
        case UInt16(ascii: "]"):
            depth -= 1
            if depth == 0 { return cursor }
        default:
            break
        }
        cursor += 1
    }
    return nil
}

/// `[text](destination "title")` and `![alt](source)`.
func parseLinkOrImage(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    let isImage = characters[index] == UInt16(ascii: "!")
    let bracket = isImage ? index + 1 : index
    guard bracket < limit, characters[bracket] == UInt16(ascii: "[") else { return nil }
    guard let closingBracket = matchingBracket(characters, from: bracket, limit: limit) else { return nil }
    guard closingBracket + 1 < limit, characters[closingBracket + 1] == UInt16(ascii: "(") else { return nil }

    // Destination, optionally angle-bracketed, then an optional quoted title.
    var cursor = skipSpaces(characters, from: closingBracket + 2, limit: Int.max)
    var destination = ""
    if cursor < limit, characters[cursor] == UInt16(ascii: "<") {
        let start = cursor + 1
        while cursor < limit, characters[cursor] != UInt16(ascii: ">") { cursor += 1 }
        guard cursor < limit else { return nil }
        destination = string(characters, from: start, to: cursor)
        cursor += 1
    } else {
        let start = cursor
        var depth = 0
        while cursor < limit {
            let character = characters[cursor]
            if character == UInt16(ascii: "\\") { cursor += 2; continue }
            if character == UInt16(ascii: "(") { depth += 1 }
            if character == UInt16(ascii: ")") {
                if depth == 0 { break }
                depth -= 1
            }
            if isSpaceOrTab(character) { break }
            cursor += 1
        }
        destination = string(characters, from: start, to: min(cursor, limit))
    }

    var title: String?
    cursor = skipSpaces(characters, from: cursor, limit: Int.max)
    if cursor < limit, characters[cursor] == UInt16(ascii: "\"") || characters[cursor] == UInt16(ascii: "'") {
        let quote = characters[cursor]
        let start = cursor + 1
        cursor += 1
        while cursor < limit, characters[cursor] != quote { cursor += 1 }
        guard cursor < limit else { return nil }
        title = string(characters, from: start, to: cursor)
        cursor += 1
    }
    cursor = skipSpaces(characters, from: cursor, limit: Int.max)
    guard cursor < limit, characters[cursor] == UInt16(ascii: ")") else { return nil }

    let end = cursor + 1
    let range = NSRange(location: index, length: end - index)
    let textRange = (bracket + 1)..<closingBracket
    // Everything except the link text is syntax.
    let markers = [
        marker(index, bracket + 1 - index),
        marker(closingBracket, end - closingBracket),
    ]

    if isImage {
        return InlineMatch(
            node: .image(
                range: range,
                markers: markers,
                source: destination,
                alt: string(characters, from: textRange.lowerBound, to: textRange.upperBound)
            ),
            end: end
        )
    }
    return InlineMatch(
        node: .link(
            range: range,
            markers: markers,
            destination: destination,
            title: title,
            children: InlineParser.parse(characters, from: textRange.lowerBound, to: textRange.upperBound)
        ),
        end: end
    )
}

struct EmphasisMatch {
    var node: InlineNode
    /// Where the consumed opening delimiters begin; leftover run characters
    /// before this stay as text.
    var openStart: Int
    var end: Int
}

/// `*em*`, `**strong**`, `***both***`, `_em_`, `~~struck~~`.
func parseEmphasis(_ characters: [UInt16], at index: Int, limit: Int) -> EmphasisMatch? {
    guard let open = delimiterRun(characters, at: index, character: nil) else { return nil }
    let character = open.character
    let isTilde = character == UInt16(ascii: "~")

    // Left-flanking: content must follow immediately.
    guard open.end < limit, !isUnicodeWhitespace(characters[open.end]) else { return nil }
    if character == UInt16(ascii: "_"), index > 0, isWordCharacter(characters[index - 1]) { return nil }
    if isTilde, open.count > 2 { return nil }

    // Find a closing run, stepping over code spans so their contents can't close us.
    var cursor = open.end
    while cursor < limit {
        if characters[cursor] == UInt16(ascii: "\\") {
            cursor += 2
            continue
        }
        if characters[cursor] == UInt16(ascii: "`"),
           let code = parseCodeSpan(characters, at: cursor, limit: limit) {
            cursor = code.end
            continue
        }
        guard characters[cursor] == character, let close = delimiterRun(characters, at: cursor, character: character) else {
            cursor += 1
            continue
        }
        // Right-flanking: content must precede immediately.
        guard !isUnicodeWhitespace(characters[cursor - 1]) else {
            cursor = close.end
            continue
        }
        if character == UInt16(ascii: "_"), close.end < limit, isWordCharacter(characters[close.end]) {
            cursor = close.end
            continue
        }

        var pairs = min(open.count, close.count)
        if isTilde {
            guard close.count == open.count else {
                cursor = close.end
                continue
            }
        } else {
            pairs = min(pairs, 3)
        }

        // Build from the inside out, so `***x***` is em(strong(x)).
        var low = open.end
        var high = cursor
        var children = InlineParser.parse(characters, from: low, to: high)
        var remaining = pairs

        while remaining > 0 {
            let take = isTilde ? pairs : (remaining >= 2 ? 2 : 1)
            low -= take
            high += take
            let range = NSRange(location: low, length: high - low)
            let markers = [marker(low, take), marker(high - take, take)]
            let node: InlineNode = if isTilde {
                .strikethrough(range: range, markers: markers, children: children)
            } else if take == 2 {
                .strong(range: range, markers: markers, children: children)
            } else {
                .emphasis(range: range, markers: markers, children: children)
            }
            children = [node]
            remaining -= take
        }

        guard let node = children.first else { return nil }
        return EmphasisMatch(node: node, openStart: low, end: high)
    }
    return nil
}

/// Letters and digits, for the intraword `_` rule.
private func isWordCharacter(_ character: UInt16) -> Bool {
    isASCIILetter(character) || isASCIIDigit(character)
}
