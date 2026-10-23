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
    private func openEdited(_ name: String, in controller: MainWindowController) async throws -> Document {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent(name)
        try "saved\n".write(to: url, atomically: true, encoding: .utf8)
        await controller.open(url: url)?.value
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
    func closeTab() async throws {
        let controller = makeWindow()
        controller.newDocument()
        let document = try await openEdited("close.md", in: controller)
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

    /// Closing any tab used to show the one at its index afterwards, so
    /// closing a tab in the background switched away from the one in front.
    @Test("Closing a background tab leaves the front tab in front")
    func closeBackgroundTab() {
        let controller = makeWindow()
        for _ in 0..<4 { controller.newDocument() }
        let front = controller.documents[3]
        controller.select(index: 3)
        controller.closeDocument(at: 0)
        #expect(controller.activeDocument === front)
    }

    @Test("Save in the prompt writes the file before the tab goes")
    func saveOnClose() async throws {
        let controller = makeWindow()
        controller.newDocument()
        let document = try await openEdited("save.md", in: controller)
        _ = script(controller, [.save])
        controller.closeDocument(at: try #require(controller.documents.firstIndex { $0 === document }))
        #expect(!controller.documents.contains { $0 === document })
        #expect(try String(contentsOf: document.url!, encoding: .utf8) == "edited saved\n")
    }

    @Test("Quitting reviews every window in turn and stops at the first Cancel")
    func quitReview() async throws {
        let first = makeWindow(), second = makeWindow()
        _ = try await openEdited("one.md", in: first)
        _ = try await openEdited("two.md", in: second)
        let clean = makeWindow()
        clean.newDocument()

        let askedFirst = script(first, [.discard])
        let askedSecond = script(second, [.cancel])
        var result: Bool?
        MainWindowController.reviewUnsavedChanges(in: [first, clean, second]) { result = $0 }
        #expect(result == false)
        #expect(askedFirst() == ["one.md"])
        #expect(askedSecond() == ["two.md"])
        // The quit is off, so the answer given for it no longer stands:
        // both windows still hold unsaved text and ask again.
        #expect(first.hasUnreviewedChanges)
        #expect(second.hasUnreviewedChanges)

        let askedFirstAgain = script(first, [.discard])
        let askedSecondAgain = script(second, [.discard])
        MainWindowController.reviewUnsavedChanges(in: [first, clean, second]) { result = $0 }
        #expect(result == true)
        #expect(askedFirstAgain() == ["one.md"])
        #expect(askedSecondAgain() == ["two.md"])
    }

    /// "Don't Save" in one window, Cancel in the next: closing the first
    /// window later skipped its prompt and dropped its recovery snapshot.
    @Test("After a cancelled quit, closing a window still asks about its unsaved text")
    func cancelledQuitThenClose() async throws {
        let first = makeWindow(), second = makeWindow()
        _ = try await openEdited("kept.md", in: first)
        _ = try await openEdited("other.md", in: second)
        _ = script(first, [.discard])
        _ = script(second, [.cancel])
        MainWindowController.reviewUnsavedChanges(in: [first, second]) { _ in }

        let asked = script(first, [.cancel])
        #expect(first.windowShouldClose(first.window!) == false)
        #expect(asked() == ["kept.md"])
    }

    /// A crash, then a sync or a pull changes the file, then a relaunch: the
    /// recovered edits were laid over the new text as if made to it, and
    /// saving them undid the change unseen.
    @Test("Recovered edits to a file changed since ask before standing in for it")
    func recoveryOverChangedFile() async throws {
        let crashed = makeWindow()
        let document = try await openEdited("synced.md", in: crashed)
        crashed.askAboutExternalChange = { _, answer in answer(false) }
        crashed.writeRecoverySnapshots(rewriting: true)
        let snapshots = crashed.recovery.snapshots().filter { $0.id == document.id }
        #expect(snapshots.count == 1)

        // Unchanged since: the edits come back, nothing to ask.
        let quiet = makeWindow()
        var quietAsked = 0
        quiet.askAboutExternalChange = { _, answer in quietAsked += 1; answer(false) }
        await quiet.restore(snapshots: snapshots)
        #expect(quietAsked == 0)
        #expect(quiet.documents.contains { $0.text == "edited saved\n" })

        // A count of its own: the window above still watches the file, and
        // may ask about the write below whenever its watcher reports it.
        var asked = 0
        try "pulled\n".write(to: document.url!, atomically: true, encoding: .utf8)
        let relaunched = makeWindow()
        relaunched.askAboutExternalChange = { _, answer in asked += 1; answer(true) }
        await relaunched.restore(snapshots: snapshots)
        await relaunched.finishReading()
        #expect(asked == 1)
        let restored = try #require(relaunched.documents.first { $0.url == document.url })
        #expect(restored.text == "pulled\n")
        #expect(!restored.isDirty)
    }

    /// The file's own encoding cannot hold an emoji; without a way out,
    /// every save and Save As failed and the text could never be saved.
    /// Each change to a file under unsaved edits put up another sheet.
    @Test("Changes on disk while the question is up ask it once")
    func externalChangesCoalesce() async throws {
        let controller = makeWindow()
        let document = try await openEdited("changing.md", in: controller)
        var answers: [(Bool) -> Void] = []
        controller.askAboutExternalChange = { _, answer in answers.append(answer) }
        for _ in 0..<3 { document.onExternalChange?() }
        #expect(answers.count == 1)
        answers[0](false)
        #expect(document.isDirty)
        // Answered: the next change asks again.
        document.onExternalChange?()
        #expect(answers.count == 2)
    }

    @Test("Text a legacy encoding cannot hold is saved as UTF-8 once agreed to")
    func saveAsUTF8() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("latin.md")
        try #require("café\n".data(using: .isoLatin1)).write(to: url)
        let controller = makeWindow()
        await controller.open(url: url)?.value
        let document = try #require(controller.documents.first { $0.url == url })
        #expect(document.format.encoding != .utf8)
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "😀 ")

        var answers = [false, true]
        controller.askToConvertToUTF8 = { _, answer in answer(answers.removeFirst()) }
        var saved: Bool?
        controller.save(document: document) { saved = $0 }
        #expect(saved == false)
        #expect(document.isDirty)
        #expect(try Data(contentsOf: url) == "café\n".data(using: .isoLatin1))

        controller.save(document: document) { saved = $0 }
        #expect(saved == true)
        #expect(!document.isDirty)
        #expect(document.format.encoding == .utf8)
        #expect(try String(contentsOf: url, encoding: .utf8) == "😀 café\n")
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
    func tearOff() async throws {
        let source = makeWindow()
        source.newDocument()
        let document = try await openEdited("moving.md", in: source)
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
    func tearOffLoneTab() async throws {
        let controller = makeWindow()
        _ = try await openEdited("alone.md", in: controller)
        var moved = false
        controller.onMoveToNewWindow = { _ in moved = true }
        controller.moveTabToNewWindow(nil)
        #expect(!moved)
        #expect(controller.documents.count == 1)
    }

    @Test("Recovery writes only documents changed since their last snapshot")
    func recoveryWritesChanges() async throws {
        let controller = makeWindow()
        let document = try await openEdited("recover.md", in: controller)
        let snapshot = scratch.appendingPathComponent("Recovery/\(document.id.uuidString).json")
        func recorded() -> String? { controller.recovery.snapshots().first { $0.id == document.id }?.text }

        controller.writeRecoverySnapshots()
        #expect(recorded() == "edited saved\n")

        // Unchanged since: not written again, so a snapshot removed behind its back stays gone.
        try FileManager.default.removeItem(at: snapshot)
        controller.writeRecoverySnapshots()
        #expect(recorded() == nil)
        // Unless every snapshot is being rewritten, after the store was cleared.
        controller.writeRecoverySnapshots(rewriting: true)
        #expect(recorded() == "edited saved\n")

        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "more ")
        controller.writeRecoverySnapshots()
        #expect(recorded() == "more edited saved\n")

        // Saved: nothing left to recover.
        controller.save(document: document)
        #expect(recorded() == nil)
        #expect(!FileManager.default.fileExists(atPath: snapshot.path))
    }

    @Test("Saving over a change on disk asks first; Cancel leaves the file as the other app wrote it")
    func saveAsksOverExternalChange() async throws {
        let controller = makeWindow()
        let document = try await openEdited("conflict.md", in: controller)
        let url = try #require(document.url)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        var answers = [false, true]
        var asked = 0
        controller.askToOverwriteChangesOnDisk = { _, answer in asked += 1; answer(answers.removeFirst()) }

        var saved: Bool?
        controller.save(document: document) { saved = $0 }
        #expect(saved == false)
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")
        #expect(document.isDirty)

        controller.save(document: document) { saved = $0 }
        #expect(saved == true)
        #expect(asked == 2)
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited saved\n")
    }

    @Test("Keeping my changes over a change on disk saves them without asking again")
    func keepChangesThenSave() async throws {
        let controller = makeWindow()
        let document = try await openEdited("kept.md", in: controller)
        let url = try #require(document.url)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        controller.askAboutExternalChange = { _, answer in answer(false) }
        var asked = 0
        controller.askToOverwriteChangesOnDisk = { _, answer in asked += 1; answer(false) }

        document.onExternalChange?()
        var saved: Bool?
        controller.save(document: document) { saved = $0 }
        #expect(saved == true)
        #expect(asked == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == "edited saved\n")
    }

    /// A reload that failed was taken for one that worked: the tab kept the
    /// old text as if it were the file's, and the next save wrote it over.
    @Test("A file that can no longer be read says so once, and saving then asks first")
    func failedReload() async throws {
        let controller = makeWindow()
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("unreadable.md")
        try "saved\n".write(to: url, atomically: true, encoding: .utf8)
        await controller.open(url: url)?.value
        let document = try #require(controller.documents.first { $0.url == url })
        var errors = 0
        controller.showError = { _ in errors += 1 }
        controller.readFile = { _ in throw CocoaError(.fileReadNoPermission) }
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)

        for _ in 0..<2 {
            document.onExternalChange?()
            await controller.finishReading()
        }
        #expect(errors == 1)
        #expect(document.text == "saved\n")

        var asked = 0
        controller.askToOverwriteChangesOnDisk = { _, answer in asked += 1; answer(false) }
        document.storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "edited ")
        controller.save(document: document)
        #expect(asked == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "theirs\n")
    }

    /// Revert to Saved read the file on the main thread, and left the old
    /// saved text in place, so a file changed on disk since showed as
    /// edited right after it was reverted to.
    @Test("Revert to Saved reads the file off the main thread and leaves the tab saved")
    func revertToSaved() async throws {
        let controller = makeWindow()
        let document = try await openEdited("revert.md", in: controller)
        let url = try #require(document.url)
        try "theirs\n".write(to: url, atomically: true, encoding: .utf8)
        let gate = SlowGate()
        controller.readFile = { url in
            gate.pass()
            return try Data(contentsOf: url)
        }
        controller.revertToSaved(nil)
        try await gate.waitForReads()
        gate.open()
        await controller.finishReading()
        #expect(document.text == "theirs\n")
        #expect(!document.isDirty)
        #expect(!gate.ranOnMainThread)
        // Undoable, and undone it is unsaved again.
        document.undoManager.undo()
        #expect(document.text == "edited saved\n")
        #expect(document.isDirty)
    }

    /// Every keystroke put the snapshot off again, so steady typing was
    /// never snapshotted and a crash lost all of it.
    @Test("Steady typing is still snapshotted, after the longest wait")
    func recoveryDuringSteadyTyping() async throws {
        let controller = makeWindow()
        let document = try await openEdited("typing.md", in: controller)
        controller.recoveryTiming = .init(pause: 0.3, longest: 0.6)
        let textView = try #require(controller.currentEditor?.textView)
        func recorded() -> String? { controller.recovery.snapshots().first { $0.id == document.id }?.text }

        let start = Date()
        while recorded() == nil, Date().timeIntervalSince(start) < 3 {
            textView.insertText("x", replacementRange: NSRange(location: 0, length: 0))
            try await Task.sleep(for: .milliseconds(50))
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(recorded()?.hasSuffix("edited saved\n") == true)
        #expect(elapsed < 2)
    }

    @Test("⌘1…⌘8 pick a tab by position and ⌘9 the last; a tab number past the end does nothing")
    func selectTabByNumber() throws {
        let controller = makeWindow()
        for _ in 0..<4 { controller.newDocument() }
        func press(_ tag: Int) {
            let item = NSMenuItem()
            item.tag = tag
            controller.selectDocumentTab(item)
        }
        press(2)
        #expect(controller.activeDocument === controller.documents[1])
        press(9)
        #expect(controller.activeDocument === controller.documents.last)
        press(1)
        press(6)
        #expect(controller.activeDocument === controller.documents[0])
    }

    @Test("Reopen Closed Tab brings back the most recently closed file")
    func reopenClosedTab() async throws {
        let controller = makeWindow()
        let first = try await openEdited("first.md", in: controller)
        let second = try await openEdited("second.md", in: controller)
        script(controller, [.discard, .discard])()
        let urls = [first.url, second.url]
        controller.closeDocument(at: controller.documents.firstIndex { $0 === first }!)
        controller.closeDocument(at: controller.documents.firstIndex { $0 === second }!)
        #expect(controller.documents.allSatisfy { !urls.contains($0.url) })

        controller.reopenClosedTab(nil)
        await controller.finishReading()
        #expect(controller.activeDocument?.url == second.url)
        controller.reopenClosedTab(nil)
        await controller.finishReading()
        #expect(controller.activeDocument?.url == first.url)
    }

    /// Opening read the file on the main thread, so one still in iCloud or
    /// on a slow volume froze the window until it arrived.
    @Test("Opening a slow file leaves the window free, and asking twice opens it once")
    func openOffMainThread() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let url = scratch.appendingPathComponent("slow.md")
        try "slow\n".write(to: url, atomically: true, encoding: .utf8)
        let controller = makeWindow()
        let gate = SlowGate()
        controller.readFile = { url in
            gate.pass()
            return try Data(contentsOf: url)
        }

        let first = try #require(controller.open(url: url))
        #expect(controller.open(url: url) == first)
        #expect(!controller.contains(url))
        try await gate.waitForReads()

        gate.open()
        await first.value
        #expect(controller.documents.filter { $0.url == url }.count == 1)
        #expect(controller.activeDocument?.text == "slow\n")
        // Open now: brought forward, not read again.
        #expect(controller.open(url: url) == nil)
        #expect(gate.calls == 1)
        #expect(!gate.ranOnMainThread)
        #expect(!gate.gaveUp)
    }

    /// Restoring read every tab's file in turn on the main thread, so the
    /// app sat frozen at launch until the slowest had arrived.
    @Test("Restoring reads files off the main thread and keeps their order and selection")
    func restoreOffMainThread() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let tabs = try (0..<3).map { index -> Session.Tab in
            let url = scratch.appendingPathComponent("slow\(index).md")
            try "file \(index)\n".write(to: url, atomically: true, encoding: .utf8)
            return Session.Tab(url: url, selectedLocation: 0, sourceMode: nil, typewriterMode: nil, focusMode: nil)
        }
        let window = Session.Window(tabs: tabs, selectedIndex: 1, workspace: nil, frame: nil)
        func slowWindow() -> (MainWindowController, SlowGate) {
            let controller = makeWindow()
            let gate = SlowGate()
            controller.readFile = { url in
                gate.pass()
                return try Data(contentsOf: url)
            }
            return (controller, gate)
        }

        let (controller, gate) = slowWindow()
        let restoring = Task { await controller.restore(window) }
        try await gate.waitForReads(3)
        #expect(!controller.documents.contains { $0.url != nil })
        gate.open()
        await restoring.value
        #expect(controller.documents.map(\.url) == tabs.map(\.url))
        #expect(controller.activeDocument?.url == tabs[1].url)
        #expect(gate.calls == 3)
        #expect(!gate.ranOnMainThread)
        #expect(!gate.gaveUp)

        // Opened again while the session is still being read: one tab, not two.
        let (other, otherGate) = slowWindow()
        let restoringOther = Task { await other.restore(window) }
        try await otherGate.waitForReads(3)
        let opening = other.open(url: tabs[0].url)
        otherGate.open()
        await restoringOther.value
        await opening?.value
        #expect(other.documents.map(\.url) == tabs.map(\.url))
        #expect(!otherGate.gaveUp)
    }

    @Test("Restoring a session makes an editor only for the tab it shows, and keeps the rest as saved")
    func restoreIsLazy() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let tabs = try (0..<3).map { index -> Session.Tab in
            let url = scratch.appendingPathComponent("restored\(index).md")
            try String(repeating: "line\n", count: 50).write(to: url, atomically: true, encoding: .utf8)
            return Session.Tab(url: url, selectedLocation: 10 * (index + 1), sourceMode: index == 2, typewriterMode: nil, focusMode: nil)
        }
        let controller = makeWindow()
        await controller.restore(Session.Window(tabs: tabs, selectedIndex: 1, workspace: nil, frame: nil))
        #expect(controller.documents.map(\.url) == tabs.map(\.url))
        #expect(controller.activeDocument?.url == tabs[1].url)
        #expect(controller.editorCount == 1)
        // Tabs not shown yet go back into the session as they came.
        let session = controller.windowSession()
        #expect(session.selectedIndex == 1)
        #expect(session.tabs.map(\.selectedLocation) == [10, 20, 30])
        #expect(session.tabs[2].sourceMode == true)

        controller.select(index: 2)
        #expect(controller.editorCount == 2)
        #expect(controller.windowSession().tabs[2].selectedLocation == 30)
        #expect(controller.windowSession().tabs[2].sourceMode == true)
    }

    /// Tabs whose files had gone were dropped without a word.
    @Test("Files from the last session that could not be reopened are named, unless recovered text brought them back")
    func unreopenedFiles() async throws {
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let present = scratch.appendingPathComponent("present.md")
        try "here\n".write(to: present, atomically: true, encoding: .utf8)
        let gone = scratch.appendingPathComponent("gone.md")
        let recovered = scratch.appendingPathComponent("recovered.md")
        let tabs = [present, gone, recovered].map {
            Session.Tab(url: $0, selectedLocation: 0, sourceMode: nil, typewriterMode: nil, focusMode: nil)
        }
        let controller = makeWindow()
        var told: [[URL]] = []
        controller.tellAboutUnreopened = { told.append($0) }
        let unreopened = await controller.restore(Session.Window(tabs: tabs, selectedIndex: 0))
        #expect(unreopened == [gone, recovered])
        #expect(controller.documents.map(\.url) == [present])

        await controller.restore(snapshots: [.init(id: UUID(), url: recovered, text: "unsaved", base: nil)])
        controller.reportUnreopened(unreopened)
        #expect(told == [[gone]])
        controller.reportUnreopened([recovered])
        #expect(told.count == 1)
    }

    /// A large selection is counted once it settles. Deleting it before
    /// then left the delayed count reading ranges past the end of the text.
    @Test("Deleting a large selection before its count settles does not count the old ranges")
    func largeSelectionDeleted() async throws {
        let controller = makeWindow()
        controller.openCopy(of: String(repeating: "some words on a line\n", count: 20_000), named: "Large")
        let textView = try #require(controller.window?.firstResponder as? NSTextView)
        textView.setSelectedRange(NSRange(location: 0, length: 150_000))
        controller.refreshStatus()
        try await Task.sleep(for: .milliseconds(50))
        // Extending it past the threshold defers the count.
        textView.setSelectedRange(NSRange(location: 0, length: 400_000))
        controller.refreshStatus()
        try await Task.sleep(for: .milliseconds(50))
        textView.insertText("", replacementRange: textView.selectedRange())
        controller.refreshStatus()
        try await Task.sleep(for: .milliseconds(400))
        #expect(textView.string.utf16.count == 20_000 * 21 - 400_000)
        controller.window?.close()
    }
}
