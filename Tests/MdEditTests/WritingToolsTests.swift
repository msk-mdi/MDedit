import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Several carets")
struct MultiCursorTests {
    private func makeEditor(_ text: String) -> (Document, EditorViewController) {
        let document = Document(text: text, theme: .light)
        let editor = EditorViewController(textStorage: document.storage)
        _ = editor.view
        return (document, editor)
    }

    @Test("Typing goes to every caret as one undoable change")
    func typeAtCarets() throws {
        let (document, editor) = makeEditor("aa\nbb\ncc\n")
        // Undo comes from the window.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = editor.view
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        textView.addCaret(below: true)
        textView.addCaret(below: true)
        #expect(textView.additionalCarets == [4, 7])
        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.text == "aXa\nbXb\ncXc\n")
        #expect(textView.selectedRange() == NSRange(location: 2, length: 0))
        #expect(textView.additionalCarets == [6, 10])
        textView.deleteBackward(nil)
        #expect(document.text == "aa\nbb\ncc\n")
        textView.insertText("YZ", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.text == "aYZa\nbYZb\ncYZc\n")
        let undo = try #require(textView.undoManager)
        undo.undo()
        #expect(document.text == "aa\nbb\ncc\n")
    }

    @Test("Return at several carets inserts plain newlines, not list markers")
    func newlines() {
        let (document, editor) = makeEditor("- a\n- b\n")
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 3, length: 0))
        textView.addCaret(below: true)
        textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(document.text == "- a\n\n- b\n\n")
    }

    @Test("Moving the selection drops the extra carets")
    func moveClears() {
        let (_, editor) = makeEditor("aa\nbb\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.textView.addCaret(below: true)
        #expect(!editor.textView.additionalCarets.isEmpty)
        editor.textView.setSelectedRange(NSRange(location: 1, length: 0))
        #expect(editor.textView.additionalCarets.isEmpty)
    }

    @Test("Next occurrence grows the selection; typing replaces them all")
    func occurrences() {
        let (document, editor) = makeEditor("cat dog cat bird cat")
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.addNextOccurrence()
        #expect(textView.selectedRange() == NSRange(location: 0, length: 3))
        editor.addNextOccurrence()
        #expect(textView.selectedRanges.count == 2)
        textView.insertText("cow", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.text == "cow dog cow bird cat")

        textView.setSelectedRange(NSRange(location: 1, length: 0))
        editor.selectAllOccurrences()
        #expect(textView.selectedRanges.count == 2)
    }

    @Test("A column selection is typed over line by line")
    func columnSelection() {
        let (document, editor) = makeEditor("abc\ndef\n")
        editor.textView.selectedRanges = [NSValue(range: NSRange(location: 1, length: 1)), NSValue(range: NSRange(location: 5, length: 1))]
        editor.textView.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(document.text == "a-c\nd-f\n")
    }

    @Test("Overlapping targets merge; repeated carets collapse")
    func merging() {
        let merged = MarkdownTextView.merged([
            NSRange(location: 5, length: 0), NSRange(location: 0, length: 3), NSRange(location: 2, length: 2), NSRange(location: 5, length: 0),
        ])
        #expect(merged == [NSRange(location: 0, length: 4), NSRange(location: 5, length: 0)])
    }
}

@MainActor
@Suite("Writing tools")
struct WritingToolsTests {
    @Test("Statistics skip markup and count paragraphs and sentences")
    func statistics() {
        let stats = TextStatistics("# Title\n\n- one item. Two!\n- three\n\n***\n")
        #expect(stats.words == 5)
        #expect(stats.paragraphs == 3)
        #expect(stats.sentences == 3)
        #expect(stats.lines == 7)
        #expect(stats.readingMinutes == 1)
        #expect(TextStatistics("").readingMinutes == 0)
        #expect(TextStatistics("a b").charactersExcludingSpaces == 2)
    }

    @Test("Word goals are kept per file, and follow an untitled document's first save")
    func goals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditGoals-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = Document(text: "hello", theme: .light)
        document.wordGoal = 500
        #expect(document.wordGoal == 500)
        let url = directory.appendingPathComponent("goal.md")
        try document.save(to: url)
        #expect(WordGoals.goal(for: url) == 500)
        document.wordGoal = nil
        #expect(WordGoals.goal(for: url) == nil)
    }

    @Test("A table of contents is a nested list of links, escaped and never over-indented")
    func tableOfContents() {
        let text = "### Deep\n# Top [1]\n### Skips a level\n## Sub" as NSString
        let headings = BlockStructure(text: text).headings(in: text)
        #expect(tableOfContentsMarkdown(headings) == """
        - [Deep](#deep)
        - [Top \\[1\\]](#top-1)
          - [Skips a level](#skips-a-level)
          - [Sub](#sub)
        """)
    }

    @Test("Insert Table of Contents puts the list at the caret between blank lines")
    func insertTableOfContents() {
        let document = Document(text: "Intro\n# A\n## B", theme: .light)
        let editor = EditorViewController(textStorage: document.storage)
        _ = editor.view
        editor.textView.setSelectedRange(NSRange(location: 5, length: 0))
        editor.insertTableOfContents()
        #expect(document.text == "Intro\n\n- [A](#a)\n  - [B](#b)\n\n# A\n## B")
    }
}

@Suite("Version history")
struct VersionHistoryTests {
    @Test("Versions are kept newest first, once per distinct text, up to the limit")
    func record() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditHistory-\(UUID().uuidString)")
        var history = VersionHistory(root: root)
        history.limit = 3
        let file = URL(fileURLWithPath: "/Users/someone/notes/a.md")
        let start = Date(timeIntervalSince1970: 1_000_000)
        try history.record("one", for: file, at: start)
        try history.record("one", for: file, at: start.addingTimeInterval(1))
        #expect(history.versions(for: file).count == 1)
        for (offset, text) in ["two", "three", "four"].enumerated() {
            try history.record(text, for: file, at: start.addingTimeInterval(Double(offset + 2)))
        }
        let versions = history.versions(for: file)
        #expect(versions.count == 3)
        #expect(try versions.map { try String(contentsOf: $0.url, encoding: .utf8) } == ["four", "three", "two"])
        #expect(versions.first?.date == start.addingTimeInterval(4))
        // Another file has a history of its own.
        #expect(history.versions(for: URL(fileURLWithPath: "/Users/someone/notes/b.md")).isEmpty)
        let note = try String(contentsOf: history.directory(for: file).appendingPathComponent("path.txt"), encoding: .utf8)
        #expect(note == "/Users/someone/notes/a.md")
    }

    @Test("Files in the temporary folder keep no history")
    func temporary() {
        #expect(!VersionHistory.isWorthKeeping(FileManager.default.temporaryDirectory.appendingPathComponent("x.md")))
        #expect(VersionHistory.isWorthKeeping(URL(fileURLWithPath: "/Users/someone/x.md")))
    }
}
