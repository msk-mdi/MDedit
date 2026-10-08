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

/// `[text](destination "title")` and `![alt](source)`, or the reference forms
/// `[text][label]`, `[text][]` and `[label]`.
func parseLinkOrImage(_ characters: [UInt16], at index: Int, limit: Int, references: LinkReferences) -> InlineMatch? {
    let isImage = characters[index] == UInt16(ascii: "!")
    let bracket = isImage ? index + 1 : index
    guard bracket < limit, characters[bracket] == UInt16(ascii: "[") else { return nil }
    guard let closingBracket = matchingBracket(characters, from: bracket, limit: limit) else { return nil }
    if closingBracket + 1 < limit, characters[closingBracket + 1] == UInt16(ascii: "("),
       let inline = parseInlineLinkTail(
           characters, at: index, bracket: bracket, closingBracket: closingBracket,
           limit: limit, isImage: isImage, references: references
       ) {
        return inline
    }
    return parseReferenceLinkTail(
        characters, at: index, bracket: bracket, closingBracket: closingBracket,
        limit: limit, isImage: isImage, references: references
    )
}

/// The reference forms. A shortcut `[label]` needs a known definition even in
/// the editor, or every bracketed aside would turn into a link.
private func parseReferenceLinkTail(
    _ characters: [UInt16],
    at index: Int,
    bracket: Int,
    closingBracket: Int,
    limit: Int,
    isImage: Bool,
    references: LinkReferences
) -> InlineMatch? {
    var label = string(characters, from: bracket + 1, to: closingBracket)
    var end = closingBracket + 1
    var isShortcut = true
    if end < limit, characters[end] == UInt16(ascii: "[") {
        var cursor = end + 1
        while cursor < limit, characters[cursor] != UInt16(ascii: "]") {
            if characters[cursor] == UInt16(ascii: "[") { return nil }
            if characters[cursor] == UInt16(ascii: "\\") { cursor += 1 }
            cursor += 1
        }
        if cursor < limit {
            let explicit = string(characters, from: end + 1, to: min(cursor, limit))
            if !explicit.isEmpty { label = explicit }
            end = cursor + 1
            isShortcut = false
        }
    }
    let key = normalizeLabel(label)
    guard !key.isEmpty else { return nil }
    let definition = references.links[key]
    if definition == nil, references.requireDefinitions || isShortcut { return nil }

    let range = NSRange(location: index, length: end - index)
    let markers = [
        marker(index, bracket + 1 - index),
        marker(closingBracket, end - closingBracket),
    ]
    if isImage {
        return InlineMatch(
            node: .image(
                range: range,
                markers: markers,
                source: definition?.destination ?? "",
                alt: string(characters, from: bracket + 1, to: closingBracket)
            ),
            end: end
        )
    }
    return InlineMatch(
        node: .link(
            range: range,
            markers: markers,
            destination: definition?.destination ?? "",
            title: definition?.title,
            children: unlinked(InlineParser.parse(characters, from: bracket + 1, to: closingBracket, references: references))
        ),
        end: end
    )
}

/// `(destination "title")` after the link text.
private func parseInlineLinkTail(
    _ characters: [UInt16],
    at index: Int,
    bracket: Int,
    closingBracket: Int,
    limit: Int,
    isImage: Bool,
    references: LinkReferences
) -> InlineMatch? {
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
            children: unlinked(InlineParser.parse(characters, from: textRange.lowerBound, to: textRange.upperBound, references: references))
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

/// `*em*`, `**strong**`, `***both***`, `_em_`, `~~struck~~`, `==marked==`.
func parseEmphasis(_ characters: [UInt16], at index: Int, limit: Int, references: LinkReferences) -> EmphasisMatch? {
    guard let open = delimiterRun(characters, at: index, character: nil) else { return nil }
    let character = open.character
    let isEquals = character == UInt16(ascii: "=")
    if isEquals, open.count != 2 { return nil }
    // `~~` and `==` pair whole runs rather than nesting like `*`.
    let isTilde = character == UInt16(ascii: "~") || isEquals

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
        var children = InlineParser.parse(characters, from: low, to: high, references: references)
        var remaining = pairs

        while remaining > 0 {
            let take = isTilde ? pairs : (remaining >= 2 ? 2 : 1)
            low -= take
            high += take
            let range = NSRange(location: low, length: high - low)
            let markers = [marker(low, take), marker(high - take, take)]
            // A single `~` around one word is a subscript; around words it
            // strikes through, as GFM has it.
            let isSubscript = isTilde && !isEquals && take == 1
                && !characters[(low + 1)..<(high - 1)].contains(where: isUnicodeWhitespace)
            let node: InlineNode = if isEquals {
                .highlight(range: range, markers: markers, children: children)
            } else if isSubscript {
                .subscript(range: range, markers: markers, children: children)
            } else if isTilde {
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
func isWordCharacter(_ character: UInt16) -> Bool {
    isASCIILetter(character) || isASCIIDigit(character)
}

/// `[^label]`. Export only links footnotes that are defined.
func parseFootnoteReference(_ characters: [UInt16], at index: Int, limit: Int, references: LinkReferences) -> InlineMatch? {
    guard let label = footnoteLabel(characters, at: index, limit: limit) else { return nil }
    if references.requireDefinitions, !references.footnotes.contains(normalizeLabel(label.label)) { return nil }
    return InlineMatch(
        node: .footnoteReference(
            range: NSRange(location: index, length: label.end - index),
            markers: [marker(index, 2), marker(label.end - 1, 1)],
            label: label.label
        ),
        end: label.end
    )
}

/// Characters a bare URL may follow.
func isURLBoundary(_ character: UInt16) -> Bool {
    isUnicodeWhitespace(character)
        || character == UInt16(ascii: "(")
        || character == UInt16(ascii: "*")
        || character == UInt16(ascii: "_")
        || character == UInt16(ascii: "~")
        || character == UInt16(ascii: "=")
}

/// GFM's extended autolinks: `https://…`, `http://…` and `www.…` without
/// angle brackets. Trailing punctuation and unbalanced `)` stay outside.
func parseBareURL(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    let prefixes = ["https://", "http://", "www."]
    guard let prefix = prefixes.first(where: { prefix in
        let units = Array(prefix.utf16)
        return index + units.count <= limit && Array(characters[index..<(index + units.count)]) == units
    }) else { return nil }
    let bodyStart = index + prefix.utf16.count

    var end = bodyStart
    while end < limit, !isUnicodeWhitespace(characters[end]), characters[end] != UInt16(ascii: "<") { end += 1 }

    let trailing = Set("?!.,:;*_~'\"=".utf16)
    while end > bodyStart {
        let last = characters[end - 1]
        if trailing.contains(last) {
            end -= 1
            continue
        }
        if last == UInt16(ascii: ")") {
            let span = characters[index..<end]
            let opens = span.filter { $0 == UInt16(ascii: "(") }.count
            let closes = span.filter { $0 == UInt16(ascii: ")") }.count
            if closes > opens {
                end -= 1
                continue
            }
        }
        break
    }
    // The host needs at least one character.
    guard end > bodyStart else { return nil }
    let text = string(characters, from: index, to: end)
    return InlineMatch(
        node: .autolink(
            range: NSRange(location: index, length: end - index),
            markers: [],
            url: prefix == "www." ? "http://" + text : text
        ),
        end: end
    )
}

/// Link text cannot contain another link, so a bare URL there is just text.
private func unlinked(_ nodes: [InlineNode]) -> [InlineNode] {
    nodes.map { node in
        switch node {
        case let .autolink(range, markers, _) where markers.isEmpty: .text(range)
        case let .emphasis(range, markers, children): .emphasis(range: range, markers: markers, children: unlinked(children))
        case let .strong(range, markers, children): .strong(range: range, markers: markers, children: unlinked(children))
        case let .strikethrough(range, markers, children): .strikethrough(range: range, markers: markers, children: unlinked(children))
        case let .highlight(range, markers, children): .highlight(range: range, markers: markers, children: unlinked(children))
        default: node
        }
    }
}

/// `$…$` inline or `$$…$$` display math. An inline span must hug its
/// content — `$ 5` or `5 $` does not open or close one — and a closing `$`
/// followed by a digit is a price, not the end of a formula.
func parseMath(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    let display = index + 1 < limit && characters[index + 1] == UInt16(ascii: "$")
    let delimiter = display ? 2 : 1
    let start = index + delimiter
    guard start < limit else { return nil }
    if !display, isUnicodeWhitespace(characters[start]) { return nil }

    var cursor = start
    while cursor < limit {
        let character = characters[cursor]
        if character == UInt16(ascii: "\\") {
            cursor += 2
            continue
        }
        if character == UInt16(ascii: "$") {
            if display {
                if cursor + 1 < limit, characters[cursor + 1] == UInt16(ascii: "$"), cursor > start {
                    return mathMatch(index: index, start: start, close: cursor, delimiter: 2, display: true)
                }
            } else if cursor > start, !isUnicodeWhitespace(characters[cursor - 1]),
                      !(cursor + 1 < limit && isASCIIDigit(characters[cursor + 1])) {
                return mathMatch(index: index, start: start, close: cursor, delimiter: 1, display: false)
            }
        }
        cursor += 1
    }
    return nil
}

private func mathMatch(index: Int, start: Int, close: Int, delimiter: Int, display: Bool) -> InlineMatch {
    let end = close + delimiter
    return InlineMatch(
        node: .math(
            range: NSRange(location: index, length: end - index),
            markers: [marker(index, delimiter), marker(close, delimiter)],
            content: NSRange(location: start, length: close - start),
            display: display
        ),
        end: end
    )
}

/// `^text^`, with no spaces inside, as in Pandoc.
func parseSuperscript(_ characters: [UInt16], at index: Int, limit: Int, references: LinkReferences) -> InlineMatch? {
    var cursor = index + 1
    while cursor < limit, characters[cursor] != UInt16(ascii: "^") {
        if isUnicodeWhitespace(characters[cursor]) { return nil }
        if characters[cursor] == UInt16(ascii: "\\") { cursor += 1 }
        cursor += 1
    }
    guard cursor < limit, cursor > index + 1 else { return nil }
    return InlineMatch(
        node: .superscript(
            range: NSRange(location: index, length: cursor + 1 - index),
            markers: [marker(index, 1), marker(cursor, 1)],
            children: InlineParser.parse(characters, from: index + 1, to: cursor, references: references)
        ),
        end: cursor + 1
    )
}

/// `:name:` for a known shortcode. Everything but the closing colon is
/// hidden; the editor draws the emoji in that colon's place.
func parseEmoji(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    var cursor = index + 1
    while cursor < limit, cursor - index <= 40 {
        let character = characters[cursor]
        if character == UInt16(ascii: ":") { break }
        guard isASCIILetter(character) || isASCIIDigit(character)
            || character == UInt16(ascii: "_") || character == UInt16(ascii: "+") || character == UInt16(ascii: "-")
        else { return nil }
        cursor += 1
    }
    guard cursor < limit, characters[cursor] == UInt16(ascii: ":"), cursor > index + 1 else { return nil }
    let name = string(characters, from: index + 1, to: cursor).lowercased()
    guard let emoji = Emoji.shortcodes[name] else { return nil }
    return InlineMatch(
        node: .emoji(
            range: NSRange(location: index, length: cursor + 1 - index),
            markers: [marker(index, cursor - index)],
            shortcode: name,
            emoji: emoji
        ),
        end: cursor + 1
    )
}
