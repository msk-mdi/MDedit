import AppKit
import MarkdownKit

/// Table editing on top of plain pipe-table source: moving between cells,
/// adding and removing rows and columns, and keeping the columns aligned.
///
/// Every change rewrites the whole table as one undoable edit, then puts the
/// caret back in the cell it belongs in.
@MainActor
struct TableEditor {
    let storage: MarkdownTextStorage
    let textView: NSTextView

    /// Where the caret is, in table terms.
    struct Position {
        /// Document lines the table spans.
        var lines: ClosedRange<Int>
        var range: NSRange
        var table: MarkdownTable
        /// 0 is the header, 1 the delimiter, 2 and on are body rows.
        var line: Int
        var column: Int

        /// The body row index, or nil on the header and delimiter.
        var bodyRow: Int? { line >= 2 ? line - 2 : nil }
    }

    /// Whether the caret is in a table.
    var isInTable: Bool { position() != nil }

    func position() -> Position? {
        let selection = textView.selectedRange()
        let structure = storage.structure
        let caretLine = storage.line(at: selection.location)
        guard let info = structure.info(forLine: caretLine), info.quoteDepth == 0 else { return nil }

        // Find the delimiter row: the caret is on the header, the delimiter, or a body row.
        var delimiter: Int
        switch info.kind {
        case .tableDelimiter:
            delimiter = caretLine
        case .tableRow:
            delimiter = caretLine
            while delimiter > 0, structure.info(forLine: delimiter)?.kind == .tableRow { delimiter -= 1 }
        case .paragraph where isDelimiter(structure.info(forLine: caretLine + 1)?.kind):
            delimiter = caretLine + 1
        default:
            return nil
        }
        guard isDelimiter(structure.info(forLine: delimiter)?.kind), delimiter >= 1 else { return nil }
        let header = delimiter - 1
        var last = delimiter
        while structure.info(forLine: last + 1)?.kind == .tableRow { last += 1 }

        let text = storage.string as NSString
        let lineTexts = (header...last).map { line in
            text.substring(with: structure.index.contentRange(ofLine: line, in: text))
        }
        guard let table = MarkdownTable(lines: lineTexts) else { return nil }

        let start = structure.index.range(ofLine: header).location
        let end = NSMaxRange(structure.index.contentRange(ofLine: last, in: text))
        let lineStart = structure.index.range(ofLine: caretLine).location
        let column = columnIndex(in: lineTexts[caretLine - header], at: selection.location - lineStart)
        return Position(
            lines: header...last,
            range: NSRange(location: start, length: end - start),
            table: table,
            line: caretLine - header,
            column: min(column, table.columnCount - 1)
        )
    }

    private func isDelimiter(_ kind: BlockKind?) -> Bool {
        if case .tableDelimiter? = kind { return true }
        return false
    }

    /// The cell a line offset falls in: count the unescaped pipes before it,
    /// not counting a leading one.
    private func columnIndex(in line: String, at offset: Int) -> Int {
        var pipes = 0
        var escaped = false
        for unit in line.utf16.prefix(offset) {
            if escaped {
                escaped = false
            } else if unit == 0x5C /* backslash */ {
                escaped = true
            } else if unit == 0x7C /* pipe */ {
                pipes += 1
            }
        }
        let leadingPipe = line.trimmingCharacters(in: .whitespaces).hasPrefix("|")
        return max(0, pipes - (leadingPipe ? 1 : 0))
    }

    // MARK: - Moving between cells

    /// Tab: the next cell, wrapping to the next row; past the last cell, a new row.
    func moveToNextCell() -> Bool {
        guard var position = position() else { return false }
        var line = position.line == 1 ? 2 : position.line
        var column = position.column + 1
        if position.line == 1 { column = 0 }
        if column >= position.table.columnCount {
            column = 0
            line = line == 0 ? 2 : line + 1
        }
        if line - 2 >= position.table.rows.count {
            position.table.insertRow(at: position.table.rows.count)
        }
        apply(position.table, replacing: position, caretLine: line, column: column, selectCell: true)
        return true
    }

    /// Shift-Tab: the previous cell, wrapping to the previous row.
    func moveToPreviousCell() -> Bool {
        guard let position = position() else { return false }
        var line = position.line == 1 ? 0 : position.line
        var column = position.column - 1
        if column < 0 {
            guard line > 0 else { return true }  // already in the first cell
            line = line == 2 ? 0 : line - 1
            column = position.table.columnCount - 1
        }
        apply(position.table, replacing: position, caretLine: line, column: column, selectCell: true)
        return true
    }

    /// Return: a new row below this one. On an empty last row, leave the table.
    func insertNewline() -> Bool {
        guard var position = position() else { return false }
        if let row = position.bodyRow, row == position.table.rows.count - 1,
           position.table.rows[row].allSatisfy(\.isEmpty) {
            position.table.removeRow(at: row)
            exitTable(position)
            return true
        }
        let row = (position.bodyRow ?? -1) + 1
        position.table.insertRow(at: row)
        apply(position.table, replacing: position, caretLine: row + 2, column: 0, selectCell: false)
        return true
    }

    /// Writes the table without its empty last row and puts the caret on a
    /// fresh line after it.
    private func exitTable(_ position: Position) {
        let formatted = position.table.formatted()
        let replacement = formatted.text + "\n\n"
        let text = storage.string as NSString
        // Swallow the newline that ended the table, if any, so lines don't pile up.
        var range = position.range
        if NSMaxRange(range) < text.length { range.length += 1 }
        guard textView.replaceAsUndoStep(range, with: replacement, actionName: nil) else { return }
        textView.setSelectedRange(NSRange(location: range.location + (replacement as NSString).length, length: 0))
    }

    // MARK: - Commands

    enum Command {
        case rowAbove, rowBelow, deleteRow, columnBefore, columnAfter, deleteColumn, format
        case align(ColumnAlignment)
    }

    func perform(_ command: Command) {
        guard var position = position() else {
            NSSound.beep()
            return
        }
        var line = position.line
        var column = position.column
        switch command {
        case .rowAbove:
            let row = position.bodyRow ?? 0
            position.table.insertRow(at: row)
            line = row + 2
        case .rowBelow:
            let row = (position.bodyRow ?? -1) + 1
            position.table.insertRow(at: row)
            line = row + 2
        case .deleteRow:
            guard let row = position.bodyRow else {
                NSSound.beep()  // the header row cannot go
                return
            }
            position.table.removeRow(at: row)
            line = position.table.rows.isEmpty ? 0 : min(row, position.table.rows.count - 1) + 2
        case .columnBefore:
            position.table.insertColumn(at: column)
        case .columnAfter:
            position.table.insertColumn(at: column + 1)
            column += 1
        case .deleteColumn:
            position.table.removeColumn(at: column)
            column = min(column, position.table.columnCount - 1)
        case let .align(alignment):
            position.table.setAlignment(alignment, column: column)
        case .format:
            break
        }
        let actionName = switch command {
        case .rowAbove, .rowBelow: String(localized: "Add Row")
        case .deleteRow: String(localized: "Delete Row")
        case .columnBefore, .columnAfter: String(localized: "Add Column")
        case .deleteColumn: String(localized: "Delete Column")
        case .align: String(localized: "Align Column")
        case .format: String(localized: "Format Table")
        }
        apply(position.table, replacing: position, caretLine: line == 1 ? 0 : line, column: column, selectCell: false, actionName: actionName)
    }

    /// Inserts a three-column table on its own lines, header cell selected.
    func insertTable() {
        let table = MarkdownTable(
            header: ["Column 1", "Column 2", "Column 3"],
            alignments: [.none, .none, .none],
            rows: [["", "", ""]]
        )
        let formatted = table.formatted()
        let text = storage.string as NSString
        let selection = textView.selectedRange()
        let caretLine = storage.line(at: selection.location)
        let lineRange = storage.structure.index.contentRange(ofLine: caretLine, in: text)

        // A table needs blank lines around it, or it joins the paragraph above.
        let lineIsBlank = text.substring(with: lineRange).trimmingCharacters(in: .whitespaces).isEmpty
        let insertAt = lineIsBlank ? lineRange.location : NSMaxRange(lineRange)
        var prefix = lineIsBlank ? "" : "\n\n"
        if lineIsBlank, caretLine > 0,
           storage.structure.info(forLine: caretLine - 1)?.kind != .blank {
            prefix = "\n"
        }
        let replaceRange = NSRange(location: insertAt, length: lineIsBlank ? lineRange.length : 0)
        let followsText = NSMaxRange(replaceRange) < text.length
            && storage.structure.info(forLine: caretLine + 1).map { $0.kind != .blank } ?? false
        let replacement = prefix + formatted.text + (followsText ? "\n" : "")
        guard textView.replaceAsUndoStep(replaceRange, with: replacement, actionName: String(localized: "Insert Table")) else { return }

        let cell = formatted.cells[0][0]
        textView.setSelectedRange(NSRange(location: insertAt + (prefix as NSString).length + cell.location, length: cell.length))
    }

    /// Rewrites the table aligned, then places the caret in a cell — selecting
    /// its text when moving by Tab, so typing replaces it.
    private func apply(
        _ table: MarkdownTable,
        replacing position: Position,
        caretLine: Int,
        column: Int,
        selectCell: Bool,
        actionName: String? = nil
    ) {
        let formatted = table.formatted()
        let replacement = formatted.text
        let current = (storage.string as NSString).substring(with: position.range)
        if replacement != current {
            guard textView.replaceAsUndoStep(position.range, with: replacement, actionName: actionName) else { return }
        }

        let line = min(caretLine, formatted.lines.count - 1)
        guard formatted.cells.indices.contains(line), formatted.cells[line].indices.contains(column) else { return }
        let lineOffset = formatted.lines[..<line].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let cell = formatted.cells[line][column]
        let location = position.range.location + lineOffset + cell.location
        textView.setSelectedRange(NSRange(location: location, length: selectCell ? cell.length : 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}
