import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("TableEditor")
struct TableEditorTests {
    private func makeEditor(_ text: String, caret: Int) -> (MarkdownTextView, TableEditor) {
        let storage = MarkdownTextStorage(theme: .light)
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 600, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        textView.allowsUndo = true
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return (textView, TableEditor(storage: storage, textView: textView))
    }

    private func selected(_ textView: NSTextView) -> String {
        (textView.string as NSString).substring(with: textView.selectedRange())
    }

    private let source = "Intro\n\n| a | b |\n|-|-|\n| 1 | 2 |\n\nAfter"

    @Test("The caret's cell is found from any line of the table")
    func position() throws {
        let (_, editor) = makeEditor(source, caret: 13)  // in "b" of the header
        let position = try #require(editor.position())
        #expect(position.lines == 2...4)
        #expect(position.line == 0)
        #expect(position.column == 1)
        #expect(position.table.rows == [["1", "2"]])

        let (_, outside) = makeEditor(source, caret: 2)
        #expect(outside.position() == nil)
    }

    @Test("Tab aligns the table and walks the cells, adding a row past the end")
    func tab() {
        let (textView, editor) = makeEditor(source, caret: 9)  // in "a"
        #expect(editor.moveToNextCell())
        #expect(textView.string == "Intro\n\n| a   | b   |\n| --- | --- |\n| 1   | 2   |\n\nAfter")
        #expect(selected(textView) == "b")
        #expect(editor.moveToNextCell())
        #expect(selected(textView) == "1")
        #expect(editor.moveToNextCell())
        #expect(selected(textView) == "2")
        #expect(editor.moveToNextCell())
        #expect(textView.string.contains("| 1   | 2   |\n|     |     |\n\nAfter"))
        #expect(editor.moveToPreviousCell())
        #expect(selected(textView) == "2")
    }

    @Test("Return adds a row; Return on an empty last row leaves the table")
    func newline() {
        let (textView, editor) = makeEditor(source, caret: 30)  // in "2"
        #expect(editor.insertNewline())
        #expect(textView.string == "Intro\n\n| a   | b   |\n| --- | --- |\n| 1   | 2   |\n|     |     |\n\nAfter")
        #expect(editor.insertNewline())
        let expected = "Intro\n\n| a   | b   |\n| --- | --- |\n| 1   | 2   |\n\n\nAfter"
        #expect(textView.string == expected)
        // The caret waits on the fresh line after the table.
        #expect(textView.selectedRange().location == ("Intro\n\n| a   | b   |\n| --- | --- |\n| 1   | 2   |\n\n" as NSString).length)
        #expect(editor.position() == nil)
    }

    @Test("Commands add and remove rows and columns and align them")
    func commands() {
        let (textView, editor) = makeEditor(source, caret: 13)  // header, column b
        editor.perform(.columnAfter)
        #expect(textView.string.contains("| a   | b   |     |"))
        editor.perform(.align(.right))
        #expect(textView.string.contains("| --- | --- | --: |"))
        editor.perform(.deleteColumn)
        #expect(textView.string.contains("| a   | b   |\n| --- | --- |"))
        editor.perform(.rowBelow)
        #expect(textView.string.contains("| --- | --- |\n|     |     |\n| 1   | 2   |"))
        editor.perform(.deleteRow)
        #expect(textView.string.contains("| --- | --- |\n| 1   | 2   |\n"))
    }

    @Test("Insert Table makes room around itself and selects the first header")
    func insert() {
        let (textView, editor) = makeEditor("Text", caret: 4)
        editor.insertTable()
        #expect(textView.string == "Text\n\n| Column 1 | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n|          |          |          |")
        #expect(selected(textView) == "Column 1")
        #expect(editor.position()?.table.columnCount == 3)
    }
}
