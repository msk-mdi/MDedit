import Foundation

public enum TokenKind: Int, Equatable, Sendable {
    case keyword
    case type
    case constant
    case string
    case number
    case comment
    case function
    case variable
    /// A JSON/YAML key, an HTML attribute name, a CSS property.
    case attribute
    /// A markup tag name.
    case tag
    /// An added line in a diff.
    case inserted
    /// A removed line in a diff.
    case deleted
}

/// A coloured span within one line of code.
public struct Token: Equatable, Sendable {
    public var range: NSRange
    public var kind: TokenKind

    public init(range: NSRange, kind: TokenKind) {
        self.range = range
        self.kind = kind
    }
}

/// What a line of code carries over to the next one.
///
/// Part of `CarryState`, so an edit inside a block comment restyles the rest of
/// the comment and stops as soon as the state matches again — the same
/// incremental rule the block parser uses.
public struct CodeState: Equatable, Sendable {
    public var inBlockComment = false
    /// The triple-quote delimiter currently open, if any.
    public var openTripleQuote: String?

    public static let start = CodeState()
}

public enum SyntaxHighlighter {
    /// Tokenises one line, advancing the state it carries to the next line.
    public static func tokens(
        line: [UInt16],
        language: Language,
        state: inout CodeState
    ) -> [Token] {
        var tokens: [Token] = []
        var cursor = 0

        if language.lineDiff {
            return diffTokens(line: line)
        }

        // Finish anything left open by the line above.
        if state.inBlockComment, let block = language.blockComment {
            let end = scanUntil(line, from: 0, marker: block.close)
            tokens.append(Token(range: NSRange(location: 0, length: end.index), kind: .comment))
            if !end.found { return tokens }
            state.inBlockComment = false
            cursor = end.index
        } else if let quote = state.openTripleQuote {
            let end = scanUntil(line, from: 0, marker: quote)
            tokens.append(Token(range: NSRange(location: 0, length: end.index), kind: .string))
            if !end.found { return tokens }
            state.openTripleQuote = nil
            cursor = end.index
        }

        // A leading `#` in C is a preprocessor directive, not a comment.
        if language.preprocessorHash, cursor == 0 {
            let start = skipSpaces(line, from: 0, limit: Int.max)
            if start < line.count, line[start] == UInt16(ascii: "#") {
                var end = start + 1
                while end < line.count, isASCIILetter(line[end]) { end += 1 }
                tokens.append(Token(range: NSRange(location: start, length: end - start), kind: .keyword))
                cursor = end
            }
        }

        while cursor < line.count {
            let character = line[cursor]

            if isSpaceOrTab(character) {
                cursor += 1
                continue
            }

            if matchesLineComment(line, at: cursor, language: language) {
                tokens.append(Token(range: NSRange(location: cursor, length: line.count - cursor), kind: .comment))
                return tokens
            }

            if let block = language.blockComment, matches(line, at: cursor, text: block.open) {
                let end = scanUntil(line, from: cursor + block.open.utf16.count, marker: block.close)
                tokens.append(Token(range: NSRange(location: cursor, length: end.index - cursor), kind: .comment))
                if !end.found {
                    state.inBlockComment = true
                    return tokens
                }
                cursor = end.index
                continue
            }

            if language.markupTags, character == UInt16(ascii: "<") {
                cursor = scanTag(line, from: cursor, into: &tokens)
                continue
            }

            if let triple = language.tripleQuotes.first(where: { matches(line, at: cursor, text: $0) }) {
                let end = scanUntil(line, from: cursor + triple.utf16.count, marker: triple)
                tokens.append(Token(range: NSRange(location: cursor, length: end.index - cursor), kind: .string))
                if !end.found {
                    state.openTripleQuote = triple
                    return tokens
                }
                cursor = end.index
                continue
            }

            if language.stringDelimiterUnits.contains(character) {
                let end = scanString(line, from: cursor, delimiter: character, escape: language.escapeCharacter)
                var kind = TokenKind.string
                // `"key":` reads as a key in JSON and YAML.
                if language.jsonStyleKeys, isFollowedByColon(line, from: end) {
                    kind = .attribute
                }
                tokens.append(Token(range: NSRange(location: cursor, length: end - cursor), kind: kind))
                cursor = end
                continue
            }

            if language.dollarVariables, character == UInt16(ascii: "$") {
                let end = scanVariable(line, from: cursor)
                tokens.append(Token(range: NSRange(location: cursor, length: end - cursor), kind: .variable))
                cursor = end
                continue
            }

            if isASCIIDigit(character) {
                let end = scanNumber(line, from: cursor)
                tokens.append(Token(range: NSRange(location: cursor, length: end - cursor), kind: .number))
                cursor = end
                continue
            }

            if isIdentifierStart(character) {
                let end = scanIdentifier(line, from: cursor)
                let word = string(line, from: cursor, to: end)
                let range = NSRange(location: cursor, length: end - cursor)

                if language.keywords.contains(word) {
                    tokens.append(Token(range: range, kind: .keyword))
                } else if language.constants.contains(word) {
                    tokens.append(Token(range: range, kind: .constant))
                } else if language.types.contains(word) {
                    tokens.append(Token(range: range, kind: .type))
                } else if language.jsonStyleKeys, cursor == firstNonSpace(line), isFollowedByColon(line, from: end) {
                    tokens.append(Token(range: range, kind: .attribute))
                } else if language.callsAreFunctions, isFollowedByOpenParen(line, from: end) {
                    tokens.append(Token(range: range, kind: .function))
                }
                cursor = end
                continue
            }

            // `@media`, `@interface`, Swift attributes: keyword-like words that
            // begin with a sigil.
            if character == UInt16(ascii: "@") {
                let end = scanIdentifier(line, from: cursor + 1)
                let word = string(line, from: cursor, to: end)
                let range = NSRange(location: cursor, length: end - cursor)
                tokens.append(Token(range: range, kind: language.keywords.contains(word) ? .keyword : .attribute))
                cursor = max(end, cursor + 1)
                continue
            }

            cursor += 1
        }

        return tokens
    }

    /// Convenience for a whole block of code, as used by the HTML renderer.
    public static func tokens(code: String, language: Language) -> [[Token]] {
        var state = CodeState.start
        return code.components(separatedBy: "\n").map { line in
            tokens(line: Array(line.utf16), language: language, state: &state)
        }
    }
}

// MARK: - Scanners

private func matches(_ line: [UInt16], at index: Int, text: String) -> Bool {
    let units = Array(text.utf16)
    guard index + units.count <= line.count else { return false }
    for offset in units.indices where line[index + offset] != units[offset] {
        return false
    }
    return true
}

private func matchesLineComment(_ line: [UInt16], at index: Int, language: Language) -> Bool {
    language.lineComments.contains { matches(line, at: index, text: $0) }
}

/// Scans to just past `marker`, or to the end of the line if it is not there.
private func scanUntil(_ line: [UInt16], from index: Int, marker: String) -> (index: Int, found: Bool) {
    var cursor = index
    while cursor < line.count {
        if matches(line, at: cursor, text: marker) {
            return (cursor + marker.utf16.count, true)
        }
        cursor += 1
    }
    return (line.count, false)
}

private func scanString(_ line: [UInt16], from index: Int, delimiter: UInt16, escape: Character?) -> Int {
    let escapeUnit = escape.map { UInt16(ascii: String($0).unicodeScalars.first!) }
    var cursor = index + 1
    while cursor < line.count {
        let character = line[cursor]
        if let escapeUnit, character == escapeUnit {
            cursor += 2
            continue
        }
        if character == delimiter { return cursor + 1 }
        cursor += 1
    }
    return line.count
}

private func scanNumber(_ line: [UInt16], from index: Int) -> Int {
    var cursor = index
    // 0x, 0b and 0o literals, then digits, separators, exponents and suffixes.
    if line[cursor] == UInt16(ascii: "0"), cursor + 1 < line.count {
        let next = line[cursor + 1]
        if next == UInt16(ascii: "x") || next == UInt16(ascii: "X")
            || next == UInt16(ascii: "b") || next == UInt16(ascii: "B")
            || next == UInt16(ascii: "o") || next == UInt16(ascii: "O") {
            cursor += 2
        }
    }
    while cursor < line.count {
        let character = line[cursor]
        if isASCIIDigit(character) || isASCIILetter(character)
            || character == UInt16(ascii: ".") || character == UInt16(ascii: "_") {
            // A signed exponent keeps its sign: `3.14e-2` is one number.
            if character == UInt16(ascii: "e") || character == UInt16(ascii: "E"),
               cursor + 1 < line.count,
               line[cursor + 1] == UInt16(ascii: "-") || line[cursor + 1] == UInt16(ascii: "+"),
               cursor + 2 < line.count,
               isASCIIDigit(line[cursor + 2]) {
                cursor += 2
                continue
            }
            cursor += 1
        } else {
            break
        }
    }
    return cursor
}

private func scanVariable(_ line: [UInt16], from index: Int) -> Int {
    var cursor = index + 1
    guard cursor < line.count else { return cursor }
    if line[cursor] == UInt16(ascii: "{") {
        while cursor < line.count, line[cursor] != UInt16(ascii: "}") { cursor += 1 }
        return min(cursor + 1, line.count)
    }
    if line[cursor] == UInt16(ascii: "(") {
        return cursor  // command substitution: let the contents tokenise normally
    }
    while cursor < line.count, isIdentifierPart(line[cursor]) { cursor += 1 }
    return cursor
}

private func scanIdentifier(_ line: [UInt16], from index: Int) -> Int {
    var cursor = index
    while cursor < line.count, isIdentifierPart(line[cursor]) { cursor += 1 }
    return max(cursor, index)
}

/// `<tag attr="value">`: the tag name and attribute names colour apart from
/// their values.
private func scanTag(_ line: [UInt16], from index: Int, into tokens: inout [Token]) -> Int {
    var cursor = index + 1
    if cursor < line.count, line[cursor] == UInt16(ascii: "/") { cursor += 1 }
    let nameStart = cursor
    while cursor < line.count, isIdentifierPart(line[cursor]) || line[cursor] == UInt16(ascii: ":") {
        cursor += 1
    }
    guard cursor > nameStart else { return index + 1 }
    tokens.append(Token(range: NSRange(location: index, length: cursor - index), kind: .tag))

    while cursor < line.count, line[cursor] != UInt16(ascii: ">") {
        if isSpaceOrTab(line[cursor]) {
            cursor += 1
            continue
        }
        if line[cursor] == UInt16(ascii: "\"") || line[cursor] == UInt16(ascii: "'") {
            let end = scanString(line, from: cursor, delimiter: line[cursor], escape: "\\")
            tokens.append(Token(range: NSRange(location: cursor, length: end - cursor), kind: .string))
            cursor = end
            continue
        }
        if isIdentifierStart(line[cursor]) {
            let end = scanIdentifier(line, from: cursor)
            tokens.append(Token(range: NSRange(location: cursor, length: end - cursor), kind: .attribute))
            cursor = end
            continue
        }
        cursor += 1
    }
    if cursor < line.count {
        tokens.append(Token(range: NSRange(location: cursor, length: 1), kind: .tag))
        cursor += 1
    }
    return cursor
}

/// Whole-line colouring for diffs.
private func diffTokens(line: [UInt16]) -> [Token] {
    guard let first = line.first else { return [] }
    let whole = NSRange(location: 0, length: line.count)
    if first == UInt16(ascii: "+") {
        return matches(line, at: 0, text: "+++") ? [Token(range: whole, kind: .keyword)] : [Token(range: whole, kind: .inserted)]
    }
    if first == UInt16(ascii: "-") {
        return matches(line, at: 0, text: "---") ? [Token(range: whole, kind: .keyword)] : [Token(range: whole, kind: .deleted)]
    }
    if first == UInt16(ascii: "@") { return [Token(range: whole, kind: .type)] }
    if matches(line, at: 0, text: "diff ") || matches(line, at: 0, text: "index ") {
        return [Token(range: whole, kind: .comment)]
    }
    return []
}

// MARK: - Character classes

private func isIdentifierStart(_ character: UInt16) -> Bool {
    isASCIILetter(character) || character == UInt16(ascii: "_") || character > 127
}

private func isIdentifierPart(_ character: UInt16) -> Bool {
    isIdentifierStart(character) || isASCIIDigit(character) || character == UInt16(ascii: "-")
}

private func firstNonSpace(_ line: [UInt16]) -> Int {
    skipSpaces(line, from: 0, limit: Int.max)
}

private func isFollowedByColon(_ line: [UInt16], from index: Int) -> Bool {
    let next = skipSpaces(line, from: index, limit: Int.max)
    return next < line.count && line[next] == UInt16(ascii: ":")
}

private func isFollowedByOpenParen(_ line: [UInt16], from index: Int) -> Bool {
    index < line.count && line[index] == UInt16(ascii: "(")
}
