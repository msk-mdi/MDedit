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
}
