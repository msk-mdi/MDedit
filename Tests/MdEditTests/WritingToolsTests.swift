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

    /// Carets far apart are edited apart, so the lines between are left
    /// alone; undone as one edit, they were all restyled after all.
    @Test("Typing at carets far apart is one step to undo and to redo")
    func undoFarCarets() throws {
        let line = "Some *prose* with `code` in it.\n"
        let text = String(repeating: line, count: 200)
        #expect((text as NSString).length > 2 * MarkdownTextView.editGap)
        let (document, editor) = makeEditor(text)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = editor.view
        let textView = editor.textView
        let length = (text as NSString).length
        // Two close together at the top, one at the bottom.
        textView.setSelectedRange(NSRange(location: 4, length: 0))
        textView.additionalCarets = [10, length - 1]
        textView.insertText("X", replacementRange: NSRange(location: NSNotFound, length: 0))
        let typed = NSMutableString(string: text)
        for location in [length - 1, 10, 4] { typed.insert("X", at: location) }
        #expect(document.text == typed as String)
        #expect(textView.additionalCarets == [12, length + 2])

        let undo = try #require(textView.undoManager)
        undo.undo()
        #expect(document.text == text)
        #expect(!undo.canUndo)
        undo.redo()
        #expect(document.text == typed as String)
        undo.undo()
        #expect(document.text == text)
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

    /// Each blink redrew the view, and drawing found where every extra caret
    /// sat, laying out the whole document for thousands of them.
    @Test("Drawing looks only at the carets in the dirty rectangle")
    func visibleCarets() throws {
        let lines = 5000
        let (_, editor) = makeEditor(String(repeating: "word\n", count: lines))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = editor.view
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.additionalCarets = Array(stride(from: 5 * lines, to: 0, by: -5))
        #expect(textView.additionalCarets.first == 5)
        let layoutManager = try #require(textView.layoutManager), container = try #require(textView.textContainer)
        let top = NSRect(x: 0, y: 0, width: textView.bounds.width, height: 200)
        layoutManager.ensureLayout(forBoundingRect: top, in: container)
        let visible = textView.visibleCarets(in: top)
        #expect(!visible.isEmpty && visible.count < 50)
        #expect(visible.first == 5)
        // Every caret drawn in that rectangle is among them.
        let drawn = textView.additionalCarets.filter { textView.caretRect(at: $0)?.intersects(top) == true }
        #expect(Set(drawn).isSubset(of: Set(visible)))
        // The caret after the last line sits on the extra line fragment.
        layoutManager.ensureLayout(for: container)
        let end = try #require(textView.caretRect(at: 5 * lines))
        #expect(textView.visibleCarets(in: end.insetBy(dx: -2, dy: -2)).last == 5 * lines)
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

    @Test("Select All Occurrences stops short of too many carets")
    func occurrenceCap() {
        let limit = MarkdownTextView.maxOccurrences
        let (_, editor) = makeEditor(String(repeating: "e ", count: limit + 1))
        let textView = editor.textView
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        editor.selectAllOccurrences()
        #expect(textView.selectedRanges == [NSValue(range: NSRange(location: 0, length: 1))])
        #expect(textView.additionalCarets.isEmpty)

        textView.string = String(repeating: "e ", count: limit)
        textView.setSelectedRange(NSRange(location: 0, length: 1))
        editor.selectAllOccurrences()
        #expect(textView.selectedRanges.count == limit)
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

    @Test("Pruning drops old copies and the history of files that have gone, keeping recent ones")
    func pruneByAge() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditHistory-\(UUID().uuidString)")
        let history = VersionHistory(root: scratch.appendingPathComponent("History"))
        let folder = scratch.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 100_000_000)
        func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 24 * 60 * 60) }

        let kept = folder.appendingPathComponent("kept.md")
        try "".write(to: kept, atomically: true, encoding: .utf8)
        for (days, text) in [(200.0, "ancient"), (100, "old"), (50, "recent"), (1, "new")] {
            try history.record(text, for: kept, at: daysAgo(days))
        }
        // Deleted a while ago, deleted just now, and on a folder that is not
        // there (a volume not mounted), where only age decides.
        let deleted = folder.appendingPathComponent("deleted.md")
        let justDeleted = folder.appendingPathComponent("just-deleted.md")
        let unmounted = URL(fileURLWithPath: "/Volumes/MdEditNotMounted-\(UUID().uuidString)/x.md")
        try history.record("gone", for: deleted, at: daysAgo(40))
        try history.record("gone too", for: justDeleted, at: daysAgo(1))
        try history.record("away old", for: unmounted, at: daysAgo(120))
        try history.record("away", for: unmounted, at: daysAgo(40))

        history.prune(now: now)
        #expect(try history.versions(for: kept).map { try String(contentsOf: $0.url, encoding: .utf8) } == ["new", "recent"])
        #expect(!FileManager.default.fileExists(atPath: history.directory(for: deleted).path))
        #expect(history.versions(for: justDeleted).count == 1)
        #expect(history.versions(for: unmounted).count == 1)

        // However old, the newest copy of a file still there stays.
        history.prune(now: now.addingTimeInterval(1000 * 24 * 60 * 60))
        #expect(history.versions(for: kept).count == 1)
    }

    @Test("Pruning keeps the history within its size, oldest copies first")
    func pruneBySize() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditHistory-\(UUID().uuidString)")
        var history = VersionHistory(root: scratch.appendingPathComponent("History"))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let a = scratch.appendingPathComponent("a.md"), b = scratch.appendingPathComponent("b.md")
        for file in [a, b] { try "".write(to: file, atomically: true, encoding: .utf8) }
        let now = Date(timeIntervalSince1970: 100_000_000)
        let block = String(repeating: "x", count: 1000)
        for index in 0..<5 {
            try history.record("a\(index)" + block, for: a, at: now.addingTimeInterval(Double(index * 2)))
            try history.record("b\(index)" + block, for: b, at: now.addingTimeInterval(Double(index * 2 + 1)))
        }
        history.totalLimit = 5000
        history.prune(now: now)
        let left = (history.versions(for: a) + history.versions(for: b)).map(\.date).sorted()
        #expect(left == (6..<10).map { now.addingTimeInterval(Double($0)) })

        // The newest of each stays even when the two alone are over.
        history.totalLimit = 10
        history.prune(now: now)
        #expect(history.versions(for: a).count == 1)
        #expect(history.versions(for: b).count == 1)
    }

    @Test("A save prunes the history, without waiting for the next launch")
    func pruneAfterSave() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditHistory-\(UUID().uuidString)")
        var history = VersionHistory(root: scratch.appendingPathComponent("History"))
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("a.md")
        try "".write(to: file, atomically: true, encoding: .utf8)
        let now = Date(timeIntervalSince1970: 100_000_000)
        let block = String(repeating: "x", count: 1000)
        history.totalLimit = 2500
        history.pruneInterval = 60
        for index in 0..<5 {
            history.recordLater("\(index)" + block, for: file, at: now.addingTimeInterval(Double(index)))
        }
        history.finishPending()
        // Pruned by the first save only: the rest came within the interval.
        #expect(history.versions(for: file).count == 5)
        history.recordLater("5" + block, for: file, at: now.addingTimeInterval(120))
        history.finishPending()
        #expect(history.versions(for: file).map(\.date) == [120, 4].map { now.addingTimeInterval($0) })
    }

    @Test("Files in the temporary folder keep no history")
    func temporary() {
        #expect(!VersionHistory.isWorthKeeping(FileManager.default.temporaryDirectory.appendingPathComponent("x.md")))
        #expect(VersionHistory.isWorthKeeping(URL(fileURLWithPath: "/Users/someone/x.md")))
    }
}
