import Foundation
import Testing
@testable import MarkdownKit

@Suite("MarkdownTable")
struct TableTests {
    @Test("Cells split on unescaped pipes, with optional outer pipes")
    func cells() {
        #expect(MarkdownTable.cells(of: "| a | b |") == ["a", "b"])
        #expect(MarkdownTable.cells(of: "a | b") == ["a", "b"])
        #expect(MarkdownTable.cells(of: "| a \\| b | c |") == ["a \\| b", "c"])
        #expect(MarkdownTable.cells(of: "|  | x |") == ["", "x"])
        #expect(MarkdownTable.cells(of: "| a \\|") == ["a \\|"])
    }

    @Test("Parsing pads ragged rows; formatting aligns every column")
    func format() throws {
        let table = try #require(MarkdownTable(lines: [
            "| Name | Qty |",
            "|:-|-:|",
            "| apple | 3 |",
            "| kiwi |",
            "| fig | 12 | extra |",
        ]))
        #expect(table.columnCount == 3)
        #expect(table.rows[1] == ["kiwi", "", ""])
        // The third column was created by the long row, so its header is empty.
        #expect(table.formatted().lines == [
            "| Name  | Qty |       |",
            "| :---- | --: | ----- |",
            "| apple |   3 |       |",
            "| kiwi  |     |       |",
            "| fig   |  12 | extra |",
        ])
        #expect(MarkdownTable(lines: ["a", "not a delimiter"]) == nil)
    }

    @Test("Centred columns split their padding, and cell ranges point at the text")
    func centred() throws {
        var table = try #require(MarkdownTable(lines: ["| a | b |", "| - | - |", "| xy | z |"]))
        table.setAlignment(.center, column: 0)
        let formatted = table.formatted()
        #expect(formatted.lines == ["|  a  | b   |", "| :-: | --- |", "| xy  | z   |"])
        let header = formatted.lines[0] as NSString
        #expect(header.substring(with: formatted.cells[0][0]) == "a")
        #expect(header.substring(with: formatted.cells[0][1]) == "b")
        #expect(formatted.cells[1].isEmpty)
        #expect((formatted.lines[2] as NSString).substring(with: formatted.cells[2][0]) == "xy")
    }

    @Test("Rows and columns are inserted and removed; one column always stays")
    func editing() throws {
        var table = try #require(MarkdownTable(lines: ["| a | b |", "| - | - |", "| 1 | 2 |"]))
        table.insertRow(at: 0)
        #expect(table.rows == [["", ""], ["1", "2"]])
        table.removeRow(at: 0)
        table.insertColumn(at: 1)
        #expect(table.header == ["a", "", "b"])
        #expect(table.rows == [["1", "", "2"]])
        table.removeColumn(at: 0)
        table.removeColumn(at: 0)
        table.removeColumn(at: 0)
        #expect(table.header == ["b"])
    }

    @Test("Wide characters count double so columns still line up")
    func wide() throws {
        #expect(displayWidth("日本") == 4)
        #expect(displayWidth("abc") == 3)
        let table = try #require(MarkdownTable(lines: ["| 名前 | x |", "| - | - |"]))
        #expect(table.formatted().lines[1] == "| ---- | --- |")
    }
}
