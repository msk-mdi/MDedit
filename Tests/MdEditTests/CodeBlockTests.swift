import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Code blocks")
struct CodeBlockTests {
    private func makeTextView(_ text: String, caret: Int) -> (MarkdownTextView, MarkdownTextStorage, MarkdownInputHandler) {
        let storage = MarkdownTextStorage(theme: .light)
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        return (textView, storage, MarkdownInputHandler(storage: storage))
    }

    private func pressReturn(_ textView: NSTextView, _ input: MarkdownInputHandler) {
        if !input.handleCommand(#selector(NSResponder.insertNewline(_:)), in: textView) {
            textView.insertText("\n", replacementRange: textView.selectedRange())
        }
    }

    @Test("A block is found from any of its lines, with its language and code")
    func locate() throws {
        let (_, storage, _) = makeTextView("intro\n\n> ```swift title\n> let a = 1\n>   b\n> ```\nafter", caret: 0)
        for line in 2...5 {
            let block = try #require(CodeBlock.containing(line: line, in: storage))
            #expect(block.openLine == 2)
            #expect(block.closeLine == 5)
        }
        let block = try #require(CodeBlock.containing(line: 3, in: storage))
        #expect(block.info == "swift title")
        #expect((storage.string as NSString).substring(with: block.infoRange) == "swift title")
        #expect(block.code(in: storage) == "let a = 1\n  b")
        #expect(CodeBlock.containing(line: 0, in: storage) == nil)
        #expect(CodeBlock.containing(line: 6, in: storage) == nil)
    }

    @Test("Return after an unclosed fence closes it; a closed one is left alone")
    func autoClose() {
        let (textView, _, input) = makeTextView("```js", caret: 5)
        pressReturn(textView, input)
        #expect(textView.string == "```js\n\n```")
        #expect(textView.selectedRange().location == 6)

        let (closed, _, closedInput) = makeTextView("```js\nx\n```", caret: 5)
        pressReturn(closed, closedInput)
        #expect(closed.string == "```js\n\nx\n```")
    }

    @Test("Return in code keeps the line's indentation and quote")
    func indentation() {
        let (textView, _, input) = makeTextView("```\n    if x {\n```", caret: 14)
        pressReturn(textView, input)
        #expect(textView.string == "```\n    if x {\n    \n```")

        let (quoted, _, quotedInput) = makeTextView("> ```\n>   a\n> ```", caret: 11)
        pressReturn(quoted, quotedInput)
        #expect(quoted.string == "> ```\n>   a\n>   \n> ```")
    }

    @Test("An indented block is found across its blank lines, and its code loses four columns")
    func indentedBlock() throws {
        let (_, storage, _) = makeTextView("intro\n\n    a\n\n\tb\n      c\n\nafter", caret: 0)
        for line in [2, 4, 5] {
            let block = try #require(CodeBlock.containing(line: line, in: storage))
            #expect(block.isIndented)
            #expect(block.openLine == 2)
            #expect(block.closeLine == 5)
            #expect(block.info.isEmpty)
        }
        let block = try #require(CodeBlock.containing(line: 2, in: storage))
        #expect(block.code(in: storage) == "a\n\nb\n  c")
        #expect(CodeBlock.containing(line: 6, in: storage) == nil)

        // Inside a list, the indentation is the item's too: left alone.
        let (_, nested, _) = makeTextView("- item\n\n          code", caret: 0)
        #expect(CodeBlock.containing(line: 2, in: nested) == nil)
    }

    @Test("An indented block ending the document leaves room below its card for the last line")
    func indentedBlockAtEnd() {
        func spacing(_ text: String, line: Int) -> CGFloat {
            let (_, storage, _) = makeTextView(text, caret: 0)
            let location = storage.structure.index.range(ofLine: line).location
            return (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? -1
        }
        #expect(spacing("    a\n    b\n", line: 1) >= Metrics.codeCardPadding)
        #expect(spacing("    a\n    b\n", line: 0) == 0)
        #expect(spacing("    a\n    b", line: 1) == 0)
        #expect(spacing("    a\n    b\nafter", line: 1) == 0)
    }

    @Test("Choosing a language fences an indented block, keeping the caret on its code; undo restores it")
    func fenceIndented() {
        let document = Document(theme: .light)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let textView = editor.textView
        let original = "intro\n\n    a\n\n      b\n"
        textView.string = original
        // Before the `b`, after its six spaces.
        textView.setSelectedRange(NSRange(location: 20, length: 0))

        editor.setCodeLanguage("")
        #expect(textView.string == original)

        editor.setCodeLanguage("python")
        #expect(textView.string == "intro\n\n```python\na\n\n  b\n```\n")
        #expect((textView.string as NSString).substring(from: textView.selectedRange().location) == "b\n```\n")

        document.undoManager.undo()
        #expect(textView.string == original)
    }

    @Test("A code block opening the document starts its first line below its card's padding")
    func blockOpeningDocument() throws {
        let document = Document(theme: .light)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let textView = editor.textView
        let manager = try #require(textView.layoutManager)
        textView.insertText("    code\n\nprose", replacementRange: NSRange(location: 0, length: 0))
        manager.ensureLayout(for: try #require(textView.textContainer))
        #expect(manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY == Metrics.codeCardPadding)

        textView.string = "prose\n\n    code"
        manager.ensureLayout(for: try #require(textView.textContainer))
        #expect(manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).minY == 0)
    }

    @Test("Indented code pasted on a line of its own becomes a fenced block")
    func pasteIndentedCode() {
        #expect(MarkdownTextView.fencedCode(fromIndented: "    • a\n    • b\n") == "```\n• a\n• b\n```\n")
        #expect(MarkdownTextView.fencedCode(fromIndented: "\tif x {\n\n\t    y()\n\t}") == "```\nif x {\n\n    y()\n}\n```")
        #expect(MarkdownTextView.fencedCode(fromIndented: "    ```\n    a") == "````\n```\na\n````")
        #expect(MarkdownTextView.fencedCode(fromIndented: "    a\nb") == nil)
        #expect(MarkdownTextView.fencedCode(fromIndented: "  a") == nil)

        func paste(_ text: String, into document: String, at location: Int) -> String {
            let (textView, _, _) = makeTextView(document, caret: location)
            let board = NSPasteboard(name: .init("mdedit.tests.paste"))
            board.clearContents()
            board.setString(text, forType: .string)
            if !textView.pasteAsMarkdown(from: board) { textView.insertText(text, replacementRange: textView.selectedRange()) }
            return textView.string
        }
        #expect(paste("    • a\n", into: "", at: 0) == "```\n• a\n```\n")
        #expect(paste("    • a", into: "intro\n\n", at: 7) == "intro\n\n```\n• a\n```")
        // Mid-line, or inside a code block, the text goes in as it is.
        #expect(paste("    x", into: "ab", at: 1) == "a    xb")
        #expect(paste("    x", into: "```\n\n```", at: 4) == "```\n    x\n```")
    }
}
