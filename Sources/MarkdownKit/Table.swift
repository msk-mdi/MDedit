import Foundation

/// A GFM pipe table as rows of cell text, for editing: parse it from source
/// lines, change its shape, and write it back with columns aligned.
public struct MarkdownTable: Equatable, Sendable {
    public var header: [String]
    public var alignments: [ColumnAlignment]
    public var rows: [[String]]

    public init(header: [String], alignments: [ColumnAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
        normalize()
    }

    /// A header line, a delimiter line, then body lines. Nil when the second
    /// line is not a delimiter row.
    public init?(lines: [String]) {
        guard lines.count >= 2 else { return nil }
        let delimiter = Array(lines[1].utf16)
        guard let alignments = tableDelimiter(delimiter, from: skipSpaces(delimiter, from: 0, limit: Int.max)) else { return nil }
        self.init(
            header: Self.cells(of: lines[0]),
            alignments: alignments,
            rows: lines.dropFirst(2).map(Self.cells(of:))
        )
    }

    public var columnCount: Int { header.count }

    /// Splits a row on unescaped pipes, dropping the optional outer ones and
    /// trimming each cell. Escaped pipes stay escaped: they are cell text.
    public static func cells(of line: String) -> [String] {
        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in line {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\" {
                current.append(character)
                escaped = true
            } else if character == "|" {
                cells.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current)
        let trimmed = cells.map { $0.trimmingCharacters(in: .whitespaces) }
        var result = trimmed[...]
        // `| a | b |` splits into ["", "a", "b", ""]: the outer pipes are optional decoration.
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), result.first == "" { result = result.dropFirst() }
        if result.count > 1, hasTrailingPipe(line), result.last == "" { result = result.dropLast() }
        return Array(result)
    }

    private static func hasTrailingPipe(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("|") else { return false }
        // An odd run of backslashes before it escapes the pipe.
        let backslashes = trimmed.dropLast().reversed().prefix { $0 == "\\" }.count
        return backslashes % 2 == 0
    }

    /// Pads every row and the alignments to the widest row, so every column
    /// exists everywhere. Rows longer than the header widen the table.
    public mutating func normalize() {
        let count = max(1, header.count, alignments.count, rows.map(\.count).max() ?? 0)
        func pad(_ cells: [String]) -> [String] { cells + Array(repeating: "", count: count - cells.count) }
        header = pad(header)
        alignments += Array(repeating: .none, count: count - alignments.count)
        rows = rows.map(pad)
    }

    // MARK: - Editing

    public mutating func insertRow(at index: Int) {
        rows.insert(Array(repeating: "", count: columnCount), at: min(max(0, index), rows.count))
    }

    public mutating func removeRow(at index: Int) {
        guard rows.indices.contains(index) else { return }
        rows.remove(at: index)
    }

    public mutating func insertColumn(at index: Int) {
        let column = min(max(0, index), columnCount)
        header.insert("", at: column)
        alignments.insert(.none, at: column)
        for row in rows.indices { rows[row].insert("", at: column) }
    }

    /// Removes a column; the last column stays, since a table needs one.
    public mutating func removeColumn(at index: Int) {
        guard columnCount > 1, header.indices.contains(index) else { return }
        header.remove(at: index)
        alignments.remove(at: index)
        for row in rows.indices { rows[row].remove(at: index) }
    }

    public mutating func setAlignment(_ alignment: ColumnAlignment, column: Int) {
        guard alignments.indices.contains(column) else { return }
        alignments[column] = alignment
    }

    // MARK: - Formatting

    /// The table's source with every column padded to the same width.
    public struct Formatted: Equatable, Sendable {
        /// Header, delimiter, then body lines.
        public var lines: [String]
        /// For each line, each cell's text range (UTF-16, within the line).
        /// The delimiter line's entry is empty.
        public var cells: [[NSRange]]

        public var text: String { lines.joined(separator: "\n") }
    }

    public func formatted() -> Formatted {
        let all = [header] + rows
        let widths = (0..<columnCount).map { column in
            max(3, all.map { displayWidth($0[column]) }.max() ?? 0)
        }

        func line(_ cells: [String]) -> (String, [NSRange]) {
            var text = "|"
            var ranges: [NSRange] = []
            for (column, cell) in cells.enumerated() {
                let padding = widths[column] - displayWidth(cell)
                let (left, right): (Int, Int) = switch alignments[column] {
                case .right: (padding, 0)
                case .center: (padding / 2, padding - padding / 2)
                case .left, .none: (0, padding)
                }
                text += " " + String(repeating: " ", count: left)
                ranges.append(NSRange(location: (text as NSString).length, length: (cell as NSString).length))
                text += cell + String(repeating: " ", count: right) + " |"
            }
            return (text, ranges)
        }

        let delimiter = "|" + widths.indices.map { column -> String in
            let width = widths[column]
            let dashes: String = switch alignments[column] {
            case .none: String(repeating: "-", count: width)
            case .left: ":" + String(repeating: "-", count: width - 1)
            case .right: String(repeating: "-", count: width - 1) + ":"
            case .center: ":" + String(repeating: "-", count: width - 2) + ":"
            }
            return " \(dashes) |"
        }.joined()

        let headerLine = line(header)
        var lines = [headerLine.0, delimiter]
        var cells = [headerLine.1, []]
        for row in rows {
            let body = line(row)
            lines.append(body.0)
            cells.append(body.1)
        }
        return Formatted(lines: lines, cells: cells)
    }
}

/// Columns a string occupies in a monospaced font: East Asian wide characters
/// and emoji take two, so tables containing them still line up.
public func displayWidth(_ text: String) -> Int {
    text.reduce(0) { width, character in
        guard let scalar = character.unicodeScalars.first else { return width }
        return width + (isWide(scalar.value) || character.unicodeScalars.count > 1 && scalar.properties.isEmojiPresentation ? 2 : 1)
    }
}

private func isWide(_ value: UInt32) -> Bool {
    switch value {
    case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
         0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
         0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
        true
    default:
        false
    }
}
