import AppKit
import Carbon.HIToolbox
import Testing
@testable import MarkdownKit
@testable import MdEdit

/// Typing as the keyboard does it: key-down events sent through a window, so
/// they take AppKit's whole route — key equivalents, the input manager,
/// `insertText` and `doCommand(by:)` — to the editor's handlers.
@MainActor
@Suite("Keyboard input", .serialized)
struct KeyboardInputTests {
    @MainActor
    private struct Harness {
        let window: NSWindow
        let document: Document
        let editor: EditorViewController

        init(_ text: String = "") {
            document = Document(text: text, theme: .light)
            editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = editor
            window.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        }

        func key(_ characters: String, code: Int, modifiers: NSEvent.ModifierFlags = []) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
                )!
                if type == .keyDown, !modifiers.intersection([.command, .control]).isEmpty,
                   window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true {
                    continue
                }
                window.sendEvent(event)
            }
        }

        func type(_ text: String) {
            for character in text {
                key(String(character), code: 0)
            }
        }

        func returnKey() { key("\r", code: kVK_Return) }
        func tab(shift: Bool = false) {
            key(shift ? String(UnicodeScalar(NSBackTabCharacter)!) : "\t", code: kVK_Tab, modifiers: shift ? .shift : [])
        }
        // The Delete key sends DEL, not backspace.
        func backspace() { key(String(UnicodeScalar(NSDeleteCharacter)!), code: kVK_Delete) }
    }

    @Test("↑ and ↓ leave a wrapping table row from a cell's first and last lines")
    func arrowsInWrappingTable() throws {
        let long = String(repeating: "alpha beta gamma delta ", count: 12)
        let text = "Intro\n\n| Ref | Finding |\n| --- | --- |\n| M-01 | \(long)|\n| M-02 | next |\n\nEnd\n"
        let harness = Harness(text)
        let view = harness.editor.textView
        harness.editor.view.setFrameSize(NSSize(width: 600, height: 400))
        harness.editor.view.layoutSubtreeIfNeeded()
        (view.textStorage as? MarkdownTextStorage)?.restyleTablesChangingFit()
        view.layoutManager?.ensureLayout(for: view.textContainer!)
        let ns = text as NSString
        let first = ns.range(of: "| M-01").location, second = ns.range(of: "| M-02").location
        let manager = try #require(view.layoutManager as? MarkdownLayoutManager)
        #expect(manager.wrappedRow(atCharacter: first + 3) != nil)

        // From the one-line Ref cell, ↓ goes to the next row, not back into this one.
        view.setSelectedRange(NSRange(location: ns.range(of: "M-01").location + 2, length: 0))
        view.moveDown(nil)
        #expect(view.selectedRange().location >= second)

        // From the long cell's first line, ↓ stays in the cell, on a later line.
        let start = ns.range(of: "alpha").location + 2
        view.setSelectedRange(NSRange(location: start, length: 0))
        view.moveDown(nil)
        #expect(view.selectedRange().location > start && view.selectedRange().location < second)
        // And ↑ from the next row's cell comes back into this row.
        view.setSelectedRange(NSRange(location: ns.range(of: "next").location + 1, length: 0))
        view.moveUp(nil)
        #expect(view.selectedRange().location > first && view.selectedRange().location < second)
    }

    @Test("Typing a list and pressing Return continues it; Return on an empty item ends it")
    func listByKeyboard() {
        let harness = Harness()
        harness.type("- one")
        harness.returnKey()
        harness.type("two")
        harness.returnKey()
        #expect(harness.document.text == "- one\n- two\n- ")
        harness.returnKey()
        #expect(harness.document.text == "- one\n- two\n")
    }

    @Test("Numbered items count up as you go")
    func numberedByKeyboard() {
        let harness = Harness()
        harness.type("1. a")
        harness.returnKey()
        harness.type("b")
        #expect(harness.document.text == "1. a\n2. b")
    }

    @Test("Tab and Shift-Tab indent and outdent a list item")
    func indentByKeyboard() {
        let harness = Harness("- a\n- b")
        harness.tab()
        #expect(harness.document.text == "- a\n  - b")
        harness.tab(shift: true)
        #expect(harness.document.text == "- a\n- b")
    }

    /// The selection kept its old length as the lines grew, so the second
    /// Tab missed the last item and the third replaced the lot with a tab.
    @Test("Tab and Shift-Tab over several items move them all, again and again")
    func indentSelectionByKeyboard() {
        let text = "- top\n- a\n- b\n- c"
        let harness = Harness(text)
        let textView = harness.editor.textView
        let items = NSRange(location: 6, length: (text as NSString).length - 6)
        textView.setSelectedRange(items)
        harness.tab()
        harness.tab()
        #expect(harness.document.text == "- top\n    - a\n    - b\n    - c")
        #expect(textView.selectedRange() == NSRange(location: 10, length: (harness.document.text as NSString).length - 10))
        harness.tab(shift: true)
        harness.tab(shift: true)
        #expect(harness.document.text == text)
        #expect(textView.selectedRange() == items)
    }

    @Test("Shift-Tab on an item with one leading space moves the caret back by one")
    func outdentOneSpace() {
        let harness = Harness(" - a")
        harness.tab(shift: true)
        #expect(harness.document.text == "- a")
        #expect(harness.editor.textView.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test("An opening bracket closes itself, and Backspace removes the pair")
    func pairsByKeyboard() {
        let harness = Harness("call ")
        harness.type("(")
        #expect(harness.document.text == "call ()")
        harness.type("x)")
        #expect(harness.document.text == "call (x)")
        harness.backspace()
        harness.backspace()
        #expect(harness.document.text == "call (")
        harness.type("(")
        #expect(harness.document.text == "call (()")
        harness.backspace()
        #expect(harness.document.text == "call (")
    }

    @Test("A delimiter typed over a selection wraps it")
    func wrapByKeyboard() {
        let harness = Harness("make bold")
        harness.editor.textView.setSelectedRange(NSRange(location: 5, length: 4))
        harness.type("*")
        #expect(harness.document.text == "make *bold*")
    }

    @Test("Tab moves between table cells, formatting the table")
    func tableByKeyboard() {
        let harness = Harness("| a | b |\n|-|-|\n| 1 | 2 |")
        harness.editor.textView.setSelectedRange(NSRange(location: 2, length: 0))
        harness.tab()
        #expect(harness.document.text.hasPrefix("| a   | b   |\n"))
        #expect((harness.document.text as NSString).substring(with: harness.editor.textView.selectedRange()) == "b")
    }

    @Test("Return after an opening fence closes the block with the caret inside")
    func fenceByKeyboard() {
        let harness = Harness()
        harness.type("```swift")
        harness.returnKey()
        harness.type("let x = 1")
        #expect(harness.document.text == "```swift\nlet x = 1\n```")
    }

    /// ⌥` starts a dead key showing a marked backtick, which was paired, and
    /// over a selection wrapped it; the composed character then doubled up.
    @Test("Composing a character with a dead key neither pairs nor wraps")
    func deadKeyComposition() {
        let harness = Harness("word here")
        let view = harness.editor.textView
        view.setSelectedRange(NSRange(location: 0, length: 4))
        view.setMarkedText("`", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.document.text == "` here")
        view.insertText("è", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.document.text == "è here")
        #expect(!view.hasMarkedText())

        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.setMarkedText("`", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.document.text == "è` here")
    }

    /// Restyling the line took off the highlight an input method marks the
    /// text it is composing with, so nothing showed what was still to commit.
    @Test("Text being composed keeps its marked look")
    func markedTextKeepsHighlight() throws {
        let harness = Harness("# Title\n")
        let view = harness.editor.textView
        let highlight = try #require(view.markedTextAttributes?[.backgroundColor] as? NSColor)
        view.setSelectedRange(NSRange(location: 7, length: 0))
        view.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.markedRange() == NSRange(location: 7, length: 2))
        #expect(view.textStorage?.attribute(.backgroundColor, at: 8, effectiveRange: nil) as? NSColor == highlight)
        // A restyle of the line while composing, as a caret move or an
        // arriving image makes, keeps it too.
        harness.document.storage.restyleAll()
        #expect(view.textStorage?.attribute(.backgroundColor, at: 8, effectiveRange: nil) as? NSColor == highlight)
        view.insertText("日本", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.document.text == "# Title日本\n")
        #expect(view.textStorage?.attribute(.backgroundColor, at: 8, effectiveRange: nil) == nil)
    }

    /// Composing cleared the extra carets, so an input method typed in one
    /// place only.
    @Test("Composed text goes in at every caret")
    func compositionAtCarets() {
        let harness = Harness("ab\ncd\nef")
        let view = harness.editor.textView
        view.setSelectedRange(NSRange(location: 1, length: 0))
        view.addCaret(below: true)
        view.addCaret(below: true)
        #expect(view.additionalCarets == [4, 7])
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.additionalCarets == [5, 8])
        view.insertText("家", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(harness.document.text == "a家b\nc家d\ne家f")
        #expect(view.editTargets.map(\.location) == [2, 6, 10])
        view.undoManager?.undo()
        #expect(harness.document.text == "ab\ncd\nef")
    }

    @Test("A line selected by triple-click is the only one a line command changes")
    func tripleClickedLine() {
        let harness = Harness("first\nsecond\n")
        harness.editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
        harness.editor.setHeading(level: 1)
        #expect(harness.document.text == "# first\nsecond\n")
    }

    @Test("Pasted line endings become the editor's own")
    func pastedCarriageReturns() {
        let harness = Harness("")
        harness.editor.textView.insertText("x\r\ny\rz", replacementRange: NSRange(location: 0, length: 0))
        #expect(harness.document.text == "x\ny\nz")
    }

    /// The closing fence went in with the quote's `>`, the line between
    /// without it, which ended the quote under the caret.
    @Test("Closing a fence in a quote keeps the line inside the quote")
    func fenceInQuote() {
        let harness = Harness("> ```")
        harness.editor.textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(harness.document.text == "> ```\n> \n> ```")
        #expect(harness.editor.textView.selectedRange() == NSRange(location: 8, length: 0))
    }

    @Test("A caret added above lands beside an emoji, not inside it")
    func caretBesideEmoji() {
        let harness = Harness("😀ab\nxy")
        harness.editor.textView.setSelectedRange(NSRange(location: 6, length: 0))
        harness.editor.textView.addCaret(below: false)
        #expect(harness.editor.textView.additionalCarets == [0])
    }
}
