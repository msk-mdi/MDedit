import Foundation

extension UInt16 {
    /// `UInt16(ascii:)` has no standard-library counterpart to `UInt8`'s.
    init(ascii scalar: Unicode.Scalar) {
        self = UInt16(scalar.value)
    }
}

/// Primitives shared by the block and inline parsers. All offsets are indices
/// into a single line's UTF-16 code units.
enum Scan {
    static let space = UInt16(ascii: " ")
    static let tab = UInt16(ascii: "\t")
}

func isSpaceOrTab(_ character: UInt16) -> Bool {
    character == Scan.space || character == Scan.tab
}

/// Advances past at most `limit` spaces (a tab counts as one character here).
func skipSpaces(_ line: [UInt16], from index: Int, limit: Int) -> Int {
    var cursor = index
    var used = 0
    while cursor < line.count, used < limit, isSpaceOrTab(line[cursor]) {
        cursor += 1
        used += 1
    }
    return cursor
}

/// Indentation width from `index`, counting a tab as four columns.
func indentWidth(_ line: [UInt16], from index: Int) -> Int {
    var width = 0
    var cursor = index
    while cursor < line.count, isSpaceOrTab(line[cursor]) {
        width += line[cursor] == Scan.tab ? 4 : 1
        cursor += 1
    }
    return width
}

func isBlank(_ line: [UInt16], from index: Int) -> Bool {
    var cursor = index
    while cursor < line.count {
        if !isSpaceOrTab(line[cursor]) { return false }
        cursor += 1
    }
    return true
}

func contains(_ line: [UInt16], from index: Int, character: UInt16) -> Bool {
    var cursor = index
    while cursor < line.count {
        if line[cursor] == character { return true }
        cursor += 1
    }
    return false
}

func string(_ line: [UInt16], from start: Int, to end: Int) -> String {
    guard start < end, start >= 0, end <= line.count else { return "" }
    return String(decoding: line[start..<end], as: UTF16.self)
}

struct DelimiterRun {
    var character: UInt16
    var start: Int
    var end: Int
    var count: Int { end - start }
}

/// The run of identical characters starting at `index`, optionally required to
/// be of a particular character.
func delimiterRun(_ line: [UInt16], at index: Int, character: UInt16?) -> DelimiterRun? {
    guard index < line.count else { return nil }
    let value = line[index]
    if let character, value != character { return nil }
    var end = index
    while end < line.count, line[end] == value { end += 1 }
    return DelimiterRun(character: value, start: index, end: end)
}

func isASCIIDigit(_ character: UInt16) -> Bool {
    character >= UInt16(ascii: "0") && character <= UInt16(ascii: "9")
}

func isASCIILetter(_ character: UInt16) -> Bool {
    (character >= UInt16(ascii: "a") && character <= UInt16(ascii: "z"))
        || (character >= UInt16(ascii: "A") && character <= UInt16(ascii: "Z"))
}

/// Unicode whitespace, as the flanking rules define it.
func isUnicodeWhitespace(_ character: UInt16) -> Bool {
    guard let scalar = Unicode.Scalar(character) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
}

/// Unicode punctuation, as the flanking rules define it.
func isUnicodePunctuation(_ character: UInt16) -> Bool {
    guard let scalar = Unicode.Scalar(character) else { return false }
    return CharacterSet.punctuationCharacters.contains(scalar)
        || CharacterSet.symbols.contains(scalar)
}
