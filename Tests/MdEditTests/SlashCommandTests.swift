import AppKit
import Carbon.HIToolbox
import Testing
@testable import MarkdownKit
@testable import MdEdit

/// The menu that typing `/` opens, driven by key events as a person would.
@MainActor
@Suite("Slash commands", .serialized)
struct SlashCommandTests {
    @MainActor
    private struct Harness {
        let window: NSWindow
        let document: Document
        let editor: EditorViewController

        init(_ text: String = "", caret: Int? = nil) {
            document = Document(text: text, theme: .light)
            editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentViewController = editor
            window.makeFirstResponder(editor.textView)
            editor.textView.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
        }

        var menu: SlashMenu { editor.slashMenu }
        var titles: [String] { menu.commands.map(\.title) }
        var caret: Int { editor.textView.selectedRange().location }

        func key(_ characters: String, code: Int) {
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                let event = NSEvent.keyEvent(
                    with: type, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, characters: characters,
                    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code)
                )!
                window.sendEvent(event)
            }
        }

        func type(_ text: String) {
            for character in text { key(String(character), code: 0) }
        }

        func returnKey() { key("\r", code: kVK_Return) }
        func escape() { key("\u{1b}", code: kVK_Escape) }
        func down() { key(String(UnicodeScalar(NSDownArrowFunctionKey)!), code: kVK_DownArrow) }
        func backspace() { key(String(UnicodeScalar(NSDeleteCharacter)!), code: kVK_Delete) }
        func left() { key(String(UnicodeScalar(NSLeftArrowFunctionKey)!), code: kVK_LeftArrow) }
        func up() { key(String(UnicodeScalar(NSUpArrowFunctionKey)!), code: kVK_UpArrow) }
    }

    @Test("A slash at the start of a line opens the menu with every command")
    func opens() {
        let harness = Harness()
        harness.type("/")
        #expect(harness.menu.isActive)
        #expect(harness.titles.first == "Heading 1")
        #expect(harness.titles.contains("Table"))
        #expect(harness.titles.contains("Code Block"))
    }

    @Test("A slash inside a word, or in code, is only a slash")
    func notInWords() {
        let harness = Harness("and")
        harness.type("/or")
        #expect(!harness.menu.isActive)
        #expect(harness.document.text == "and/or")

        let code = Harness("```\nx\n```\n", caret: 5)
        code.type(" /")
        #expect(!code.menu.isActive)
    }

    @Test("Typing narrows the list; with nothing matching, Return is a plain Return")
    func narrows() {
        let harness = Harness()
        harness.type("/tab")
        #expect(harness.titles == ["Table", "Table of Contents"])
        harness.type("x")
        #expect(harness.titles.isEmpty)
        harness.returnKey()
        #expect(harness.document.text == "/tabx\n")
        #expect(!harness.menu.isActive)
    }

    @Test("Keywords find commands by other names")
    func keywords() {
        let harness = Harness()
        harness.type("/h2")
        #expect(harness.titles == ["Heading 2"])
    }

    @Test("Return turns the line into a heading, keeping the text after it")
    func heading() {
        let harness = Harness("Title")
        harness.editor.textView.setSelectedRange(NSRange(location: 0, length: 0))
        harness.type("/h1")
        harness.returnKey()
        #expect(harness.document.text == "# Title")

        let line = Harness("Title ")
        line.type("/h2")
        line.returnKey()
        #expect(line.document.text == "## Title ")
        #expect(line.caret == 9)
    }

    @Test("A heading on an empty line leaves the caret after the marker")
    func headingOnEmptyLine() {
        let harness = Harness()
        harness.type("/heading 1")
        #expect(harness.titles == ["Heading 1"])

        let empty = Harness()
        empty.type("/h3")
        empty.returnKey()
        empty.type("Hi")
        #expect(empty.document.text == "### Hi")
    }

    @Test("Arrows move through the list and Return runs the chosen one")
    func arrows() {
        let harness = Harness()
        harness.type("/list")
        #expect(harness.titles == ["Bulleted List", "Numbered List", "Task List"])
        harness.down()
        harness.down()
        harness.returnKey()
        harness.type("buy milk")
        #expect(harness.document.text == "- [ ] buy milk")
        #expect(!harness.menu.isActive)
    }

    @Test("Up from the first command wraps to the last")
    func wraps() {
        let harness = Harness()
        harness.type("/list")
        harness.up()
        #expect(harness.menu.selectedIndex == 2)
    }

    @Test("Escape closes the menu and keeps what was typed")
    func escapeKeeps() {
        let harness = Harness()
        harness.type("/tab")
        harness.escape()
        #expect(!harness.menu.isActive)
        #expect(harness.document.text == "/tab")
        harness.returnKey()
        #expect(harness.document.text == "/tab\n")
    }

    @Test("A code block lands with the caret inside it, set off from the text above")
    func codeBlock() {
        let harness = Harness("Intro\n")
        harness.type("/code")
        harness.returnKey()
        #expect(harness.document.text == "Intro\n\n```\n\n```")
        harness.type("let x = 1")
        #expect(harness.document.text == "Intro\n\n```\nlet x = 1\n```")
    }

    @Test("A block typed after text goes below the line")
    func blockAfterText() {
        let harness = Harness("Intro ")
        harness.type("/divider")
        harness.returnKey()
        #expect(harness.document.text == "Intro \n\n---\n")
        #expect(harness.caret == harness.document.text.utf16.count)
    }

    @Test("Inline styles type an empty pair with the caret inside")
    func inlineStyles() {
        let harness = Harness("Say ")
        harness.type("/bold")
        harness.returnKey()
        #expect(harness.document.text == "Say ****")
        harness.type("hi** and ")
        #expect(harness.document.text == "Say **hi** and ")
        harness.type("/italic")
        harness.returnKey()
        harness.type("there")
        #expect(harness.document.text == "Say **hi** and *there*")

        for (query, text) in [("/strike", "~~x~~"), ("/highlight", "==x=="), ("/inline code", "`x`"), ("/bold italic", "***x***")] {
            let harness = Harness()
            harness.type(query)
            harness.returnKey()
            harness.type("x")
            #expect(harness.document.text == text, "\(query)")
        }
    }

    @Test("Colours type tags with the caret inside, and recolour or come off")
    func colors() {
        let harness = Harness("Say ")
        harness.type("/red")
        #expect(harness.titles.prefix(2) == ["Red Text", "Red Highlight"])
        harness.returnKey()
        harness.type("hot")
        #expect(harness.document.text == "Say <span style=\"color: #E5484D\">hot</span>")

        // The word at the caret changes colour, then loses it.
        harness.editor.applyColor(.blue, to: .text)
        #expect(harness.document.text == "Say <span style=\"color: #3E8EF7\">hot</span>")
        harness.editor.applyColor(nil, to: .text)
        #expect(harness.document.text == "Say hot")

        // A selection is highlighted, and the highlight comes off whole.
        harness.editor.textView.setSelectedRange(NSRange(location: 4, length: 3))
        harness.editor.applyColor(.yellow, to: .highlight)
        #expect(harness.document.text == "Say <mark style=\"background: #FFF3A3\">hot</mark>")
        harness.editor.textView.setSelectedRange(NSRange(location: 4, length: (harness.document.text as NSString).length - 4))
        harness.editor.applyColor(nil, to: .highlight)
        #expect(harness.document.text == "Say hot")
    }

    @Test("Colouring several lines colours each line's text")
    func colorsSeveralLines() {
        let harness = Harness("Say hello world\n\nnext\n")
        harness.editor.textView.selectAll(nil)
        harness.editor.applyColor(.red, to: .text)
        let red = "<span style=\"color: #E5484D\">"
        #expect(harness.document.text == "\(red)Say hello world</span>\n\n\(red)next</span>\n")
        // Again, in another colour: recoloured, not nested; then taken off.
        harness.editor.applyColor(.blue, to: .text)
        #expect(harness.document.text == "<span style=\"color: #3E8EF7\">Say hello world</span>\n\n<span style=\"color: #3E8EF7\">next</span>\n")
        harness.editor.applyColor(nil, to: .text)
        #expect(harness.document.text == "Say hello world\n\nnext\n")

        // Markers stay outside: a heading and a list item keep working.
        let marked = Harness("# Title\n- item\n")
        marked.editor.textView.selectAll(nil)
        marked.editor.applyColor(.green, to: .highlight)
        let green = "<mark style=\"background: #D3F5DC\">"
        #expect(marked.document.text == "# \(green)Title</mark>\n- \(green)item</mark>\n")
    }

    /// `setTextColor:` was the action at first: the text view, ahead of the
    /// window in the responder chain, took the menu item for a colour and
    /// crashed drawing it.
    @Test("The colour menus' actions are not ones the text view answers")
    func colorActionsReachTheWindow() {
        for action in [#selector(MainWindowController.applyTextColor(_:)), #selector(MainWindowController.applyHighlightColor(_:))] {
            #expect(!MarkdownTextView.instancesRespond(to: action), "\(action)")
            #expect(!EditorViewController.instancesRespond(to: action), "\(action)")
        }
    }

    @Test("A table comes with its header cell selected")
    func table() {
        let harness = Harness()
        harness.type("/table")
        harness.returnKey()
        #expect(harness.document.text.hasPrefix("| Column 1 |"))
        let selected = (harness.document.text as NSString).substring(with: harness.editor.textView.selectedRange())
        #expect(selected == "Column 1")
    }

    @Test("A footnote takes the next free number and starts its definition at the end")
    func footnote() {
        let harness = Harness("One[^1] two ", caret: 12)
        harness.type("/foot")
        harness.returnKey()
        harness.type("Source")
        #expect(harness.document.text == "One[^1] two [^2]\n\n[^2]: Source")
    }

    @Test("Math is offered only when math is turned on")
    func mathFollowsSettings() {
        #expect(SlashCommand.all(extensions: .all).contains { $0.action == .mathBlock })
        #expect(!SlashCommand.all(extensions: []).contains { $0.action == .mathBlock })
    }

    @Test("A list command on a line that is already that list leaves it alone")
    func listIdempotent() {
        let harness = Harness("- item ")
        harness.type("/bullet")
        harness.returnKey()
        #expect(harness.document.text == "- item ")
    }

    @Test("Undo brings back the typed command, in one step")
    func undo() {
        let harness = Harness()
        let undo = harness.document.undoManager
        // Groups close at the end of each event in the app; here each step closes its own.
        undo.groupsByEvent = false
        func act(_ body: () -> Void) {
            undo.beginUndoGrouping()
            body()
            undo.endUndoGrouping()
        }
        act { harness.type("/h1") }
        act { harness.returnKey() }
        #expect(harness.document.text == "# ")
        undo.undo()
        #expect(harness.document.text == "/h1")
    }

    @Test("Backspace in the query keeps the menu open and widens it")
    func backspaceKeepsMenu() {
        let harness = Harness()
        harness.type("/headin")
        harness.backspace()
        #expect(harness.menu.isActive)
        #expect(harness.titles.first == "Heading 1")
        // A letter that matches nothing hides the list; deleting it brings it back.
        harness.type("x")
        #expect(harness.titles.isEmpty)
        harness.backspace()
        #expect(harness.titles.first == "Heading 1")
    }

    /// Lets the checks deferred to the end of an event run.
    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    @Test("Moving the caret away closes the menu")
    func caretMoveCloses() {
        let harness = Harness()
        harness.type("/hea")
        settle()
        #expect(harness.menu.isActive)
        harness.left()
        settle()
        #expect(!harness.menu.isActive)
    }

    @Test("The best match comes first: the title, then its words, then keywords")
    func ranking() {
        let titles = SlashCommand.matching("t", extensions: .all).map(\.title)
        #expect(Array(titles.prefix(3)) == ["Task List", "Table", "Table of Contents"])
        // Heading 1 by its keyword, "title".
        #expect(titles.firstIndex(of: "Heading 1")! > titles.firstIndex(of: "Table of Contents")!)
    }

    @Test("The menu is as tall as its rows, a lone one included")
    func panelFitsRows() {
        let harness = Harness()
        harness.window.orderFront(nil)
        harness.type("/task")
        #expect(harness.titles == ["Task List"])
        let panel = harness.menu.panel
        #expect(panel.isVisible)
        let table = panel.contentView!.subviews.compactMap { $0 as? NSScrollView }.first!.documentView as! NSTableView
        let row = table.convert(table.rect(ofRow: 0), to: nil)
        #expect(panel.contentView!.bounds.contains(row))
        #expect(table.enclosingScrollView!.contentView.bounds.contains(table.rect(ofRow: 0)))
        harness.window.orderOut(nil)
    }

    @Test("A space that matches nothing hides the menu; deleting it shows it again")
    func spaceThenBackspace() {
        let harness = Harness()
        harness.type("/headi ")
        #expect(harness.menu.isActive)
        #expect(harness.titles.isEmpty)
        harness.backspace()
        #expect(harness.titles.first == "Heading 1")
        harness.returnKey()
        #expect(harness.document.text == "# ")
    }

    @Test("A slash and a space is prose: the menu closes")
    func slashSpace() {
        let harness = Harness()
        harness.type("/ and")
        #expect(!harness.menu.isActive)
        #expect(harness.document.text == "/ and")
    }
}
