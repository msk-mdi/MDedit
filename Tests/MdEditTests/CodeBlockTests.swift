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
}
