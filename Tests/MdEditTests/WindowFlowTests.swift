import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

/// Window-level flows: reviewing unsaved tabs before closing or quitting,
/// and tearing a tab off into a window of its own.
@MainActor
@Suite("Window flows", .serialized)
struct WindowFlowTests {
    private let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditWindowFlows-\(UUID().uuidString)")

    private func makeWindow() -> MainWindowController {
        let controller = MainWindowController()
        controller.recovery = RecoveryStore(directory: scratch.appendingPathComponent("Recovery"))
        return controller
    }

    /// A saved file with unsaved edits, open in a window.
    private func openEdited(_ name: String, in controller: MainWindowController) throws -> Document {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent(name)
        try "saved\n".write(to: url, atomically: true, encoding: .utf8)
        controller.open(url: url)
        let document = try #require(controller.documents.first { $0.url == url })
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        #expect(document.isDirty)
        return document
    }

    /// Answers each save prompt in turn, recording which document was asked about.
    private func script(_ controller: MainWindowController, _ answers: [MainWindowController.UnsavedAnswer]) -> () -> [String] {
        var remaining = answers
        var asked: [String] = []
        controller.askAboutUnsaved = { document, answer in
            asked.append(document.displayName)
            answer(remaining.isEmpty ? .cancel : remaining.removeFirst())
        }
        return { asked }
    }

    @Test("Closing an unsaved tab asks; Cancel keeps it, Don’t Save closes it")
    func closeTab() throws {
        let controller = makeWindow()
        controller.newDocument()
        let document = try openEdited("close.md", in: controller)
        let count = controller.documents.count
        let index = try #require(controller.documents.firstIndex { $0 === document })

        let asked = script(controller, [.cancel, .discard])
        controller.closeDocument(at: index)
        #expect(controller.documents.count == count)
        controller.closeDocument(at: index)
        #expect(controller.documents.count == count - 1)
        #expect(asked() == ["close.md", "close.md"])
        // Not saved: the file still holds the old text.
        #expect(try String(contentsOf: document.url!, encoding: .utf8) == "saved\n")
    }

    @Test("Save in the prompt writes the file before the tab goes")
    func saveOnClose() throws {
        let controller = makeWindow()
        controller.newDocument()
        let document = try openEdited("save.md", in: controller)
        _ = script(controller, [.save])
        controller.closeDocument(at: try #require(controller.documents.firstIndex { $0 === document }))
        #expect(!controller.documents.contains { $0 === document })
        #expect(try String(contentsOf: document.url!, encoding: .utf8) == "edited saved\n")
    }

    @Test("Quitting reviews every window in turn and stops at the first Cancel")
    func quitReview() throws {
        let first = makeWindow(), second = makeWindow()
        _ = try openEdited("one.md", in: first)
        _ = try openEdited("two.md", in: second)
        let clean = makeWindow()
        clean.newDocument()

        let askedFirst = script(first, [.discard])
        let askedSecond = script(second, [.cancel])
        var result: Bool?
        MainWindowController.reviewUnsavedChanges(in: [first, clean, second]) { result = $0 }
        #expect(result == false)
        #expect(askedFirst() == ["one.md"])
        #expect(askedSecond() == ["two.md"])
        // The window that was answered for is not asked again; the cancelled one is.
        #expect(!first.hasUnreviewedChanges)
        #expect(second.hasUnreviewedChanges)

        let askedAgain = script(second, [.discard])
        MainWindowController.reviewUnsavedChanges(in: [first, clean, second]) { result = $0 }
        #expect(result == true)
        #expect(askedAgain() == ["two.md"])
    }

    @Test("Quitting with nothing unsaved asks nothing")
    func quitClean() {
        let controller = makeWindow()
        controller.newDocument()
        let asked = script(controller, [])
        var result: Bool?
        MainWindowController.reviewUnsavedChanges(in: [controller]) { result = $0 }
        #expect(result == true)
        #expect(asked().isEmpty)
    }

    @Test("A torn-off tab keeps its unsaved text and its undo history")
    func tearOff() throws {
        let source = makeWindow()
        source.newDocument()
        let document = try openEdited("moving.md", in: source)
        document.undoManager.groupsByEvent = false
        document.undoManager.beginUndoGrouping()
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        editor.textView.insertText("more ", replacementRange: NSRange(location: 0, length: 0))
        document.undoManager.endUndoGrouping()
        editor.detachFromStorage()

        var target: MainWindowController?
        source.onMoveToNewWindow = { moved in
            let window = makeWindow()
            window.adopt(moved)
            target = window
        }
        source.select(index: try #require(source.documents.firstIndex { $0 === document }))
        source.moveTabToNewWindow(nil)

        let destination = try #require(target)
        #expect(!source.documents.contains { $0 === document })
        #expect(destination.documents.contains { $0 === document })
        #expect(document.isDirty)
        #expect(document.text == "more edited saved\n")
        #expect(destination.activeDocument === document)
        document.undoManager.undo()
        #expect(document.text == "edited saved\n")
    }

    @Test("A lone tab is not torn off: it already has its window")
    func tearOffLoneTab() throws {
        let controller = makeWindow()
        _ = try openEdited("alone.md", in: controller)
        var moved = false
        controller.onMoveToNewWindow = { _ in moved = true }
        controller.moveTabToNewWindow(nil)
        #expect(!moved)
        #expect(controller.documents.count == 1)
    }
}
