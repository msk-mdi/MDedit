import Foundation

// Recognisers for individual block constructs, kept apart from the line-by-line
// state machine in `BlockParser`.

struct ATXHeading {
    var level: Int
    /// Line-relative offset where the heading text begins.
    var contentStart: Int
    /// A trailing `###` run, which is syntax rather than text.
    var closingRange: NSRange?
}

func atxHeading(_ line: [UInt16], from index: Int) -> ATXHeading? {
    guard let run = delimiterRun(line, at: index, character: UInt16(ascii: "#")),
          run.count <= 6
    else { return nil }
    // `#text` is a paragraph; the marker needs a space or end of line after it.
    if run.end < line.count, !isSpaceOrTab(line[run.end]) { return nil }

    let contentStart = skipSpaces(line, from: run.end, limit: Int.max)

    // A closing run of `#` preceded by a space is decoration, not content.
    var closingRange: NSRange?
    var end = line.count
    while end > contentStart, isSpaceOrTab(line[end - 1]) { end -= 1 }
    var hashStart = end
    while hashStart > contentStart, line[hashStart - 1] == UInt16(ascii: "#") { hashStart -= 1 }
    if hashStart < end, hashStart > contentStart, isSpaceOrTab(line[hashStart - 1]) {
        closingRange = NSRange(location: hashStart - 1, length: line.count - hashStart + 1)
    }

    return ATXHeading(level: run.count, contentStart: contentStart, closingRange: closingRange)
}

/// `===` or `---` under a paragraph.
func setextLevel(_ line: [UInt16], from index: Int) -> Int? {
    guard index < line.count else { return nil }
    let character = line[index]
    guard character == UInt16(ascii: "=") || character == UInt16(ascii: "-") else { return nil }
    guard let run = delimiterRun(line, at: index, character: character),
          isBlank(line, from: run.end)
    else { return nil }
    return character == UInt16(ascii: "=") ? 1 : 2
}

func isThematicBreak(_ line: [UInt16], from index: Int) -> Bool {
    guard index < line.count else { return false }
    let character = line[index]
    guard character == UInt16(ascii: "-")
        || character == UInt16(ascii: "_")
        || character == UInt16(ascii: "*")
    else { return false }

    var count = 0
    var cursor = index
    while cursor < line.count {
        let value = line[cursor]
        if value == character {
            count += 1
        } else if !isSpaceOrTab(value) {
            return false
        }
        cursor += 1
    }
    return count >= 3
}

struct ListMarker {
    var ordered: Bool
    /// Line-relative offset where the item's content begins.
    var contentStart: Int
}

func listMarker(_ line: [UInt16], from index: Int) -> ListMarker? {
    guard index < line.count else { return nil }
    let character = line[index]

    if character == UInt16(ascii: "-") || character == UInt16(ascii: "*") || character == UInt16(ascii: "+") {
        // `- ` needs the space; `---` is a thematic break, handled earlier.
        guard index + 1 < line.count, isSpaceOrTab(line[index + 1]) else { return nil }
        return ListMarker(ordered: false, contentStart: skipSpaces(line, from: index + 1, limit: Int.max))
    }

    guard isASCIIDigit(character) else { return nil }
    var cursor = index
    var digits = 0
    while cursor < line.count, isASCIIDigit(line[cursor]), digits < 9 {
        cursor += 1
        digits += 1
    }
    guard cursor < line.count,
          line[cursor] == UInt16(ascii: ".") || line[cursor] == UInt16(ascii: ")"),
          cursor + 1 < line.count,
          isSpaceOrTab(line[cursor + 1])
    else { return nil }
    return ListMarker(ordered: true, contentStart: skipSpaces(line, from: cursor + 1, limit: Int.max))
}

struct TaskBox {
    var state: TaskState
    var end: Int
}

/// A GFM task marker, `[ ]` or `[x]`, at the start of a list item's content.
func taskBox(_ line: [UInt16], from index: Int) -> TaskBox? {
    guard index + 2 < line.count,
          line[index] == UInt16(ascii: "["),
          line[index + 2] == UInt16(ascii: "]")
    else { return nil }
    let inner = line[index + 1]
    let state: TaskState
    if inner == Scan.space {
        state = .unchecked
    } else if inner == UInt16(ascii: "x") || inner == UInt16(ascii: "X") {
        state = .checked
    } else {
        return nil
    }
    return TaskBox(state: state, end: skipSpaces(line, from: index + 3, limit: Int.max))
}

/// A GFM table delimiter row, e.g. `| :--- | ---: |`, returning column alignments.
func tableDelimiter(_ line: [UInt16], from index: Int) -> [ColumnAlignment]? {
    guard contains(line, from: index, character: UInt16(ascii: "|")) else { return nil }

    var alignments: [ColumnAlignment] = []
    var cursor = index
    var sawDash = false

    // Leading pipe is optional.
    if cursor < line.count, line[cursor] == UInt16(ascii: "|") { cursor += 1 }

    while cursor < line.count {
        cursor = skipSpaces(line, from: cursor, limit: Int.max)
        var left = false
        var right = false
        var dashes = 0
        if cursor < line.count, line[cursor] == UInt16(ascii: ":") {
            left = true
            cursor += 1
        }
        while cursor < line.count, line[cursor] == UInt16(ascii: "-") {
            dashes += 1
            cursor += 1
        }
        if cursor < line.count, line[cursor] == UInt16(ascii: ":") {
            right = true
            cursor += 1
        }
        cursor = skipSpaces(line, from: cursor, limit: Int.max)

        guard dashes > 0 else { return nil }
        sawDash = true
        switch (left, right) {
        case (true, true): alignments.append(.center)
        case (true, false): alignments.append(.left)
        case (false, true): alignments.append(.right)
        case (false, false): alignments.append(.none)
        }

        if cursor < line.count, line[cursor] == UInt16(ascii: "|") {
            cursor += 1
        } else {
            break
        }
    }

    guard sawDash, isBlank(line, from: cursor) else { return nil }
    return alignments
}

/// A list item at `indent` opens, continues, or closes nesting levels.
func pushListLevel(_ lists: inout [ListLevel], indent: Int, ordered: Bool) {
    while let top = lists.last, indent < top.indent {
        lists.removeLast()
    }
    if let top = lists.last, indent == top.indent {
        lists[lists.count - 1].ordered = ordered
    } else {
        lists.append(ListLevel(indent: indent, ordered: ordered))
    }
}

/// A non-list line closes any level indented deeper than it.
func popListLevels(_ lists: inout [ListLevel], toIndent indent: Int) {
    while let top = lists.last, indent < top.indent {
        lists.removeLast()
    }
}
