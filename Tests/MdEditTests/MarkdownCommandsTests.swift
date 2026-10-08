import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

/// The Format menu's commands, and how each lands on the undo stack.
@MainActor
@Suite("Format commands", .serialized)
struct MarkdownCommandsTests {
    private func makeEditor(_ text: String, selection: NSRange, steps: Bool = false) -> (Document, EditorViewController, UndoManager) {
        let document = Document(text: text, theme: .light)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        _ = editor.view
        editor.textView.setSelectedRange(selection)
        // Groups close at the end of each event in the app; in an undo test
        // each `act` closes its own.
        document.undoManager.groupsByEvent = !steps
        return (document, editor, document.undoManager)
    }

    /// One user action: what an event's undo group would hold.
    private func act(_ undo: UndoManager, _ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    private func selected(_ editor: EditorViewController) -> String {
        (editor.textView.string as NSString).substring(with: editor.textView.selectedRange())
    }

    // MARK: - Inline

    @Test("Bold wraps the selection and keeps it selected")
    func boldWraps() {
        let (document, editor, _) = makeEditor("make this bold\n", selection: NSRange(location: 5, length: 4))
        editor.toggleInline("**")
        #expect(document.text == "make **this** bold\n")
        #expect(selected(editor) == "this")
    }

    @Test("Bold with no selection wraps the word around the caret")
    func boldWord() {
        let (document, editor, _) = makeEditor("make this bold\n", selection: NSRange(location: 7, length: 0))
        editor.toggleInline("**")
        #expect(document.text == "make **this** bold\n")
    }

    @Test("Toggling again unwraps, with the markers inside or outside the selection")
    func unwrap() {
        let (document, editor, _) = makeEditor("make **this** bold\n", selection: NSRange(location: 7, length: 4))
        editor.toggleInline("**")
        #expect(document.text == "make this bold\n")
        #expect(selected(editor) == "this")

        let (inside, insideEditor, _) = makeEditor("make **this** bold\n", selection: NSRange(location: 5, length: 8))
        insideEditor.toggleInline("**")
        #expect(inside.text == "make this bold\n")
    }

    @Test("Link uses a URL on the clipboard and selects it")
    func linkFromClipboard() {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        pasteboard.clearContents()
        pasteboard.setString("https://example.com", forType: .string)

        let (document, editor, _) = makeEditor("see docs here\n", selection: NSRange(location: 4, length: 4))
        editor.insertLink()
        #expect(document.text == "see [docs](https://example.com) here\n")
        #expect(selected(editor) == "https://example.com")

        pasteboard.clearContents()
        pasteboard.setString("not a url", forType: .string)
        let (plain, plainEditor, _) = makeEditor("see docs\n", selection: NSRange(location: 4, length: 4))
        plainEditor.insertLink()
        #expect(plain.text == "see [docs]()\n")
        #expect(plainEditor.textView.selectedRange() == NSRange(location: 11, length: 0))
    }

    // MARK: - Lines

    @Test("Heading level is set, changed and cleared on every selected line")
    func headings() {
        let (document, editor, _) = makeEditor("one\ntwo\n", selection: NSRange(location: 0, length: 5))
        editor.setHeading(level: 2)
        #expect(document.text == "## one\n## two\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        editor.setHeading(level: 1)
        #expect(document.text == "# one\n## two\n")
        editor.setHeading(level: 0)
        #expect(document.text == "one\n## two\n")
    }

    @Test("Lists toggle on and off, numbered in order")
    func lists() {
        let (document, editor, _) = makeEditor("a\nb\nc\n", selection: NSRange(location: 0, length: 5))
        editor.toggleList(ordered: true)
        #expect(document.text == "1. a\n2. b\n3. c\n")
        editor.textView.setSelectedRange(NSRange(location: 0, length: (document.text as NSString).length - 1))
        editor.toggleList(ordered: true)
        #expect(document.text == "a\nb\nc\n")
    }

    @Test("A task list adds unchecked boxes")
    func tasks() {
        let (document, editor, _) = makeEditor("a\n", selection: NSRange(location: 0, length: 0))
        editor.toggleList(ordered: false, task: true)
        #expect(document.text.hasSuffix("[ ] a\n"))
    }

    @Test("Quote adds and removes the marker")
    func quote() {
        let (document, editor, _) = makeEditor("said\n", selection: NSRange(location: 0, length: 0))
        editor.toggleQuote()
        #expect(document.text == "> said\n")
        editor.toggleQuote()
        #expect(document.text == "said\n")
    }

    @Test("Code block fences the selected lines")
    func codeBlock() {
        let (document, editor, _) = makeEditor("let x = 1\n", selection: NSRange(location: 2, length: 0))
        editor.insertCodeBlock()
        #expect(document.text == "```\nlet x = 1\n```\n")
        #expect(editor.textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    // MARK: - Undo

    @Test("A command after typing is its own undo step, named for the command")
    func commandAfterTyping() throws {
        let (document, editor, undo) = makeEditor("", selection: NSRange(location: 0, length: 0), steps: true)
        act(undo) { editor.textView.insertText("hello", replacementRange: editor.textView.selectedRange()) }
        act(undo) {
            editor.textView.setSelectedRange(NSRange(location: 0, length: 5))
            editor.toggleInline("**")
        }
        #expect(document.text == "**hello**")
        #expect(undo.undoActionName == "Bold")
        undo.undo()
        #expect(document.text == "hello")
        undo.undo()
        #expect(document.text == "")
    }

    @Test("Typing after a command does not join the command's undo step")
    func typingAfterCommand() throws {
        let (document, editor, undo) = makeEditor("word", selection: NSRange(location: 0, length: 4), steps: true)
        act(undo) { editor.toggleInline("*") }
        act(undo) {
            editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
            editor.textView.insertText("!", replacementRange: editor.textView.selectedRange())
        }
        #expect(document.text == "*word*!")
        undo.undo()
        #expect(document.text == "*word*")
        undo.undo()
        #expect(document.text == "word")
    }

    @Test("Every line command is one undo step with its menu's name")
    func lineCommandNames() {
        let (document, editor, undo) = makeEditor("a\nb\n", selection: NSRange(location: 0, length: 3), steps: true)
        let commands: [(String, () -> Void)] = [
            ("Heading 2", { editor.setHeading(level: 2) }),
            ("Paragraph", { editor.setHeading(level: 0) }),
            ("Bulleted List", { editor.toggleList(ordered: false) }),
            ("Blockquote", { editor.toggleQuote() }),
        ]
        var texts = [document.text]
        for (name, command) in commands {
            act(undo) { command() }
            #expect(undo.undoActionName == name)
            texts.append(document.text)
        }
        for expected in texts.dropLast().reversed() {
            undo.undo()
            #expect(document.text == expected)
        }
    }

    @Test("Checking a task box is a step of its own")
    func taskBoxUndo() throws {
        let (document, editor, undo) = makeEditor("- [ ] item\n", selection: NSRange(location: 10, length: 0), steps: true)
        editor.textView.revealLine(nil)
        act(undo) { editor.textView.insertText("s", replacementRange: editor.textView.selectedRange()) }
        act(undo) { _ = editor.textView.toggleTaskBox(at: 3) }
        #expect(document.text == "- [x] items\n")
        #expect(undo.undoActionName == "Check Task")
        undo.undo()
        #expect(document.text == "- [ ] items\n")
    }

    @Test("Each document keeps its own undo history")
    func undoPerDocument() {
        let (first, firstEditor, firstUndo) = makeEditor("", selection: NSRange(location: 0, length: 0), steps: true)
        let (second, secondEditor, secondUndo) = makeEditor("", selection: NSRange(location: 0, length: 0), steps: true)
        #expect(firstEditor.textView.undoManager === firstUndo)
        #expect(secondEditor.textView.undoManager === secondUndo)
        act(firstUndo) { firstEditor.textView.insertText("one", replacementRange: NSRange(location: 0, length: 0)) }
        act(secondUndo) { secondEditor.textView.insertText("two", replacementRange: NSRange(location: 0, length: 0)) }
        firstUndo.undo()
        #expect(first.text == "")
        #expect(second.text == "two")
    }

    @Test("Return continuing a list undoes together with its newline")
    func listContinuationUndo() {
        let (document, editor, undo) = makeEditor("- one", selection: NSRange(location: 5, length: 0), steps: true)
        act(undo) { editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
        #expect(document.text == "- one\n- ")
        undo.undo()
        #expect(document.text == "- one")
    }

    @Test("Edits the input handler makes are recorded once, so undo restores the text")
    func inputHandlerUndo() {
        // Each of these used to register its change twice, so undo replayed it twice.
        let cases: [(String, NSRange, (MarkdownTextView) -> Void, String)] = [
            ("- one\n", NSRange(location: 2, length: 0), { $0.doCommand(by: #selector(NSResponder.insertTab(_:))) }, "  - one\n"),
            ("x", NSRange(location: 0, length: 1), { $0.insertText("*", replacementRange: $0.selectedRange()) }, "*x*"),
            ("```\ncode", NSRange(location: 8, length: 0), { $0.doCommand(by: #selector(NSResponder.insertNewline(_:))) }, "```\ncode\n"),
        ]
        for (text, selection, action, edited) in cases {
            let (document, editor, undo) = makeEditor(text, selection: selection, steps: true)
            act(undo) { action(editor.textView) }
            #expect(document.text == edited)
            undo.undo()
            #expect(document.text == text)
        }
    }
}

private extension MarkdownTextView {
    /// Stands in for the caret having been elsewhere, so markers are concealed.
    func revealLine(_ line: Int?) {
        (textStorage as? MarkdownTextStorage)?.revealedLines = line.map { $0...$0 }
    }
}
