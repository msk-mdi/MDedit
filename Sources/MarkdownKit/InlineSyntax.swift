import Foundation

// Recognisers for individual inline constructs, following the CommonMark
// spec's definitions. Each returns what it found and the offset just past it,
// or nil to let the characters be plain text. Emphasis and links are not
// here: they need the delimiter and bracket stacks in `InlineParser`.

struct InlineMatch {
    var node: InlineNode
    var end: Int
}

func marker(_ location: Int, _ length: Int) -> Marker {
    Marker(range: NSRange(location: location, length: length), kind: .conceal)
}

func isASCIIPunctuation(_ character: UInt16) -> Bool {
    (0x21...0x2F).contains(character) || (0x3A...0x40).contains(character)
        || (0x5B...0x60).contains(character) || (0x7B...0x7E).contains(character)
}

/// Letters and digits, for word boundaries.
func isWordCharacter(_ character: UInt16) -> Bool {
    isASCIILetter(character) || isASCIIDigit(character)
}

private func isLineEnding(_ character: UInt16) -> Bool {
    character == 0x0A || character == 0x0D
}

private func isWhitespaceOrLineEnding(_ character: UInt16) -> Bool {
    isSpaceOrTab(character) || isLineEnding(character)
}

// MARK: - Code spans

/// A run of backticks, closed by a run of exactly the same length. Nil when
/// there is no such run, in which case the whole opening run is literal.
func parseCodeSpan(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    guard let open = delimiterRun(characters, at: index, character: UInt16(ascii: "`")), open.end <= limit else { return nil }
    var cursor = open.end
    while cursor < limit {
        guard characters[cursor] == UInt16(ascii: "`") else {
            cursor += 1
            continue
        }
        var closeEnd = cursor
        while closeEnd < limit, characters[closeEnd] == UInt16(ascii: "`") { closeEnd += 1 }
        if closeEnd - cursor == open.count {
            return InlineMatch(
                node: .code(
                    range: NSRange(location: index, length: closeEnd - index),
                    content: NSRange(location: open.end, length: cursor - open.end),
                    markers: [marker(index, open.count), marker(cursor, open.count)]
                ),
                end: closeEnd
            )
        }
        cursor = closeEnd
    }
    return nil
}

/// A code span's text as it renders: line endings become spaces, and one
/// space is stripped from each end when both ends have one and the content
/// is not all spaces.
func codeSpanText(_ raw: String) -> String {
    var text = raw.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
    if text.count >= 2, text.first == " ", text.last == " ", text.contains(where: { $0 != " " }) {
        text = String(text.dropFirst().dropLast())
    }
    return text
}

// MARK: - Autolinks and raw HTML

/// `<scheme:anything>` or `<user@example.com>`.
func parseAutolink(_ characters: [UInt16], at index: Int, limit: Int) -> InlineMatch? {
    let cursor = index + 1
    var close = cursor
    while close < limit, characters[close] != UInt16(ascii: ">") {
        let character = characters[close]
        if character == UInt16(ascii: "<") || character <= 0x20 { return nil }
        close += 1
    }
    guard close < limit, close > cursor else { return nil }
    let body = string(characters, from: cursor, to: close)
    let range = NSRange(location: index, length: close + 1 - index)
    let markers = [marker(index, 1), marker(close, 1)]

    // A URI: a scheme of 2–32 characters, a colon, then no spaces or angle brackets.
    var schemeEnd = cursor
    if schemeEnd < close, isASCIILetter(characters[schemeEnd]) {
        schemeEnd += 1
        while schemeEnd < close, isASCIILetter(characters[schemeEnd]) || isASCIIDigit(characters[schemeEnd])
            || characters[schemeEnd] == UInt16(ascii: "+") || characters[schemeEnd] == UInt16(ascii: ".")
            || characters[schemeEnd] == UInt16(ascii: "-") {
            schemeEnd += 1
        }
        let schemeLength = schemeEnd - cursor
        if schemeEnd < close, characters[schemeEnd] == UInt16(ascii: ":"), (2...32).contains(schemeLength) {
            return InlineMatch(node: .autolink(range: range, markers: markers, url: body), end: close + 1)
        }
    }

    // An email address.
    guard let at = body.firstIndex(of: "@") else { return nil }
    let local = body[..<at]
    let domain = body[body.index(after: at)...]
    let localAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-")
    guard !local.isEmpty, local.unicodeScalars.allSatisfy(localAllowed.contains) else { return nil }
    let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
    guard !labels.isEmpty, labels.allSatisfy(isDomainLabel) else { return nil }
    return InlineMatch(node: .autolink(range: range, markers: markers, url: "mailto:" + body), end: close + 1)
}

private func isDomainLabel(_ label: Substring) -> Bool {
    guard (1...63).contains(label.count), let first = label.first, let last = label.last,
          first.isASCII, first.isLetter || first.isNumber, last.isASCII, last.isLetter || last.isNumber
    else { return false }
    return label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
}

/// Raw HTML as CommonMark defines it: an open or closing tag, a comment, a
/// processing instruction, a declaration or a CDATA section. Returns the end.
func parseRawHTML(_ characters: [UInt16], at index: Int, limit: Int) -> Int? {
    guard index + 1 < limit, characters[index] == UInt16(ascii: "<") else { return nil }
    let next = characters[index + 1]

    func find(_ terminator: String, from start: Int) -> Int? {
        let units = Array(terminator.utf16)
        var cursor = start
        while cursor + units.count <= limit {
            if Array(characters[cursor..<(cursor + units.count)]) == units { return cursor + units.count }
            cursor += 1
        }
        return nil
    }
    func hasPrefix(_ prefix: String) -> Bool {
        let units = Array(prefix.utf16)
        return index + units.count <= limit && Array(characters[index..<(index + units.count)]) == units
    }

    if hasPrefix("<!--") {
        if hasPrefix("<!-->") { return index + 5 }
        if hasPrefix("<!--->") { return index + 6 }
        return find("-->", from: index + 4)
    }
    if hasPrefix("<?") { return find("?>", from: index + 2) }
    if hasPrefix("<![CDATA[") { return find("]]>", from: index + 9) }
    if next == UInt16(ascii: "!") {
        guard index + 2 < limit, isASCIILetter(characters[index + 2]) else { return nil }
        return find(">", from: index + 2)
    }
    if next == UInt16(ascii: "/") {
        guard let nameEnd = tagNameEnd(characters, from: index + 2, limit: limit) else { return nil }
        let cursor = skipWhitespace(characters, from: nameEnd, limit: limit)
        return cursor < limit && characters[cursor] == UInt16(ascii: ">") ? cursor + 1 : nil
    }

    // An open tag: name, attributes, optional `/`, `>`.
    guard var cursor = tagNameEnd(characters, from: index + 1, limit: limit) else { return nil }
    while true {
        let afterSpace = skipWhitespace(characters, from: cursor, limit: limit)
        guard afterSpace < limit else { return nil }
        if characters[afterSpace] == UInt16(ascii: ">") { return afterSpace + 1 }
        if characters[afterSpace] == UInt16(ascii: "/") {
            return afterSpace + 1 < limit && characters[afterSpace + 1] == UInt16(ascii: ">") ? afterSpace + 2 : nil
        }
        // Each attribute needs whitespace before it.
        guard afterSpace > cursor, let attributeEnd = attribute(characters, from: afterSpace, limit: limit) else { return nil }
        cursor = attributeEnd
    }
}

private func tagNameEnd(_ characters: [UInt16], from start: Int, limit: Int) -> Int? {
    guard start < limit, isASCIILetter(characters[start]) else { return nil }
    var cursor = start + 1
    while cursor < limit, isASCIILetter(characters[cursor]) || isASCIIDigit(characters[cursor]) || characters[cursor] == UInt16(ascii: "-") {
        cursor += 1
    }
    return cursor
}

private func skipWhitespace(_ characters: [UInt16], from start: Int, limit: Int) -> Int {
    var cursor = start
    while cursor < limit, isWhitespaceOrLineEnding(characters[cursor]) { cursor += 1 }
    return cursor
}

/// `name`, optionally followed by `= value`, unquoted or quoted.
private func attribute(_ characters: [UInt16], from start: Int, limit: Int) -> Int? {
    let first = characters[start]
    guard isASCIILetter(first) || first == UInt16(ascii: "_") || first == UInt16(ascii: ":") else { return nil }
    var cursor = start + 1
    while cursor < limit {
        let character = characters[cursor]
        guard isASCIILetter(character) || isASCIIDigit(character) || character == UInt16(ascii: "_")
            || character == UInt16(ascii: ".") || character == UInt16(ascii: ":") || character == UInt16(ascii: "-")
        else { break }
        cursor += 1
    }
    let nameEnd = cursor
    let equals = skipWhitespace(characters, from: nameEnd, limit: limit)
    guard equals < limit, characters[equals] == UInt16(ascii: "=") else { return nameEnd }
    var value = skipWhitespace(characters, from: equals + 1, limit: limit)
    guard value < limit else { return nil }
    let quote = characters[value]
    if quote == UInt16(ascii: "\"") || quote == UInt16(ascii: "'") {
        value += 1
        while value < limit, characters[value] != quote { value += 1 }
        return value < limit ? value + 1 : nil
    }
    let valueStart = value
    while value < limit {
        let character = characters[value]
        if isWhitespaceOrLineEnding(character) || "\"'=<>`".utf16.contains(character) { break }
        value += 1
    }
    return value > valueStart ? value : nil
}

// MARK: - Link destinations, titles and labels

/// `(destination "title")` starting at the `(`.
func parseLinkTail(_ characters: [UInt16], at open: Int, limit: Int) -> (end: Int, destination: String, title: String?)? {
    guard open < limit, characters[open] == UInt16(ascii: "(") else { return nil }
    var cursor = skipWhitespace(characters, from: open + 1, limit: limit)
    if cursor < limit, characters[cursor] == UInt16(ascii: ")") { return (cursor + 1, "", nil) }
    guard let destination = parseLinkDestination(characters, at: cursor, limit: limit) else { return nil }
    cursor = destination.end
    let beforeTitle = cursor
    cursor = skipWhitespace(characters, from: cursor, limit: limit)
    var title: String?
    if cursor > beforeTitle, let parsed = parseLinkTitle(characters, at: cursor, limit: limit) {
        title = parsed.title
        cursor = skipWhitespace(characters, from: parsed.end, limit: limit)
    }
    guard cursor < limit, characters[cursor] == UInt16(ascii: ")") else { return nil }
    return (cursor + 1, destination.value, title)
}

/// `<anything but line endings and unescaped <>>`, or a run with balanced
/// parentheses and no spaces or control characters.
func parseLinkDestination(_ characters: [UInt16], at start: Int, limit: Int) -> (value: String, end: Int)? {
    guard start < limit else { return nil }
    if characters[start] == UInt16(ascii: "<") {
        var cursor = start + 1
        while cursor < limit {
            let character = characters[cursor]
            if character == UInt16(ascii: "\\"), cursor + 1 < limit, isASCIIPunctuation(characters[cursor + 1]) {
                cursor += 2
                continue
            }
            if character == UInt16(ascii: ">") {
                return (unescapeLinkText(string(characters, from: start + 1, to: cursor)), cursor + 1)
            }
            if character == UInt16(ascii: "<") || isLineEnding(character) { return nil }
            cursor += 1
        }
        return nil
    }
    var cursor = start
    var depth = 0
    while cursor < limit {
        let character = characters[cursor]
        if character == UInt16(ascii: "\\"), cursor + 1 < limit, isASCIIPunctuation(characters[cursor + 1]) {
            cursor += 2
            continue
        }
        if character <= 0x20 || character == 0x7F { break }
        if character == UInt16(ascii: "(") {
            depth += 1
            if depth > 32 { return nil }
        }
        if character == UInt16(ascii: ")") {
            if depth == 0 { break }
            depth -= 1
        }
        cursor += 1
    }
    guard cursor > start, depth == 0 else { return nil }
    return (unescapeLinkText(string(characters, from: start, to: cursor)), cursor)
}

/// `"title"`, `'title'` or `(title)`, possibly across lines.
func parseLinkTitle(_ characters: [UInt16], at start: Int, limit: Int) -> (title: String, end: Int)? {
    guard start < limit else { return nil }
    let open = characters[start]
    let close: UInt16
    switch open {
    case UInt16(ascii: "\""), UInt16(ascii: "'"): close = open
    case UInt16(ascii: "("): close = UInt16(ascii: ")")
    default: return nil
    }
    var cursor = start + 1
    while cursor < limit {
        let character = characters[cursor]
        if character == UInt16(ascii: "\\"), cursor + 1 < limit, isASCIIPunctuation(characters[cursor + 1]) {
            cursor += 2
            continue
        }
        if character == close {
            return (unescapeLinkText(string(characters, from: start + 1, to: cursor)), cursor + 1)
        }
        if open == UInt16(ascii: "("), character == UInt16(ascii: "(") { return nil }
        cursor += 1
    }
    return nil
}

/// `[label]` starting at the `[`: at most 999 characters, no unescaped
/// brackets, and something other than whitespace inside.
func parseLinkLabel(_ characters: [UInt16], at start: Int, limit: Int) -> (label: String, end: Int)? {
    guard start < limit, characters[start] == UInt16(ascii: "[") else { return nil }
    var cursor = start + 1
    while cursor < limit, cursor - start <= 1000 {
        let character = characters[cursor]
        if character == UInt16(ascii: "\\"), cursor + 1 < limit {
            cursor += 2
            continue
        }
        if character == UInt16(ascii: "[") { return nil }
        if character == UInt16(ascii: "]") {
            return (string(characters, from: start + 1, to: cursor), cursor + 1)
        }
        cursor += 1
    }
    return nil
}

/// Whether text between brackets could be a link label, for shortcut and
/// collapsed references.
func isValidLabel(_ text: String) -> Bool {
    guard text.utf16.count <= 999, !normalizeLabel(text).isEmpty else { return false }
    var escaped = false
    for character in text {
        if escaped {
            escaped = false
        } else if character == "\\" {
            escaped = true
        } else if character == "[" || character == "]" {
            return false
        }
    }
    return true
}

/// Backslash escapes and entity references resolved, as in destinations,
/// titles and info strings.
func unescapeLinkText(_ text: String) -> String {
    guard text.contains("\\") || text.contains("&") else { return text }
    var out = ""
    var iterator = text.makeIterator()
    while let character = iterator.next() {
        if character == "\\" {
            guard let next = iterator.next() else {
                out.append(character)
                break
            }
            if next.isASCII, next.isPunctuation || next.isSymbol {
                out.append(next)
            } else {
                out.append(character)
                out.append(next)
            }
        } else {
            out.append(character)
        }
    }
    return Entities.decodeAll(out)
}

// MARK: - Extensions

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
