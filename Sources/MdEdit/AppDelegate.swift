import AppKit

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Every open window, oldest first.
    private var controllers: [MainWindowController] = []
    /// Set once launch restoration is done, so early saves don't clobber the session.
    private var hasRestored = false

    static func main() {
        // A headless render path, so export can be checked without a GUI.
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
            CommandLineRenderer.run(path: arguments[index + 1])
            return
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        MainMenu.install(into: app)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        restoreSession()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Asks about unsaved documents window by window; Cancel anywhere stops the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let pending = controllers.filter(\.hasUnreviewedChanges)
        guard !pending.isEmpty else { return .terminateNow }
        var remaining = pending.makeIterator()
        func next() {
            guard let controller = remaining.next() else {
                return sender.reply(toApplicationShouldTerminate: true)
            }
            controller.window?.makeKeyAndOrderFront(nil)
            controller.reviewUnsavedChanges { proceed in
                proceed ? next() : sender.reply(toApplicationShouldTerminate: false)
            }
        }
        next()
        return .terminateLater
    }

    /// A clean quit: every unsaved document has an answer, so the recovery
    /// snapshots go; the windows are remembered for next time.
    func applicationWillTerminate(_ notification: Notification) {
        controllers.forEach { $0.cancelPendingWork() }
        saveSession()
        RecoveryStore.standard.removeAll()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where !focusExisting(url) {
            frontController().open(url: url)
        }
    }

    // MARK: - Windows

    /// The window commands act on: the key window's, else the main window's,
    /// else the newest, else a new one.
    private func frontController() -> MainWindowController {
        if let controller = NSApp.keyWindow?.windowController as? MainWindowController { return controller }
        if let controller = NSApp.mainWindow?.windowController as? MainWindowController { return controller }
        if let controller = controllers.last {
            controller.showWindow(nil)
            return controller
        }
        return makeWindow()
    }

    /// Opens a window, offset from the newest one unless its frame is about
    /// to be restored from the session.
    @discardableResult
    private func makeWindow(restoringFrame: Bool = false) -> MainWindowController {
        let controller = MainWindowController()
        controller.onSessionChange = { [weak self] in self?.saveSession() }
        controller.onClose = { [weak self] closed in self?.windowClosed(closed) }
        controller.focusElsewhere = { [weak self, weak controller] url in
            self?.focusExisting(url, excluding: controller) ?? false
        }
        controller.onMoveToNewWindow = { [weak self] document in
            self?.makeWindow().adopt(document)
        }
        if !restoringFrame, let window = controller.window {
            if let previous = controllers.last?.window {
                window.setFrameTopLeftPoint(window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY)))
            } else {
                window.center()
            }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return controller
    }

    /// Forgets a closed window. The last one stays in the session, because
    /// closing it quits the app and it should come back next launch.
    private func windowClosed(_ controller: MainWindowController) {
        guard controllers.count > 1 else { return }
        controllers.removeAll { $0 === controller }
        saveSession()
    }

    /// Brings forward the window and tab holding a file, if any window has it.
    @discardableResult
    private func focusExisting(_ url: URL, excluding excluded: MainWindowController? = nil) -> Bool {
        for controller in controllers where controller !== excluded {
            if controller.focusDocument(at: url) { return true }
        }
        return false
    }

    // MARK: - Session

    /// Reopens the last session's windows, then puts recovered unsaved text
    /// into whichever window holds its file — or the first, for the rest.
    private func restoreSession() {
        let saved = Session.load()?.windows ?? []
        let snapshots = RecoveryStore.standard.snapshots()

        if saved.isEmpty {
            let controller = controllers.first ?? makeWindow()
            // Before sessions remembered folders, the last folder was kept here.
            if let workspace = Workspace.load() { controller.setWorkspace(workspace) }
        }
        for (index, window) in saved.enumerated() {
            // A window may already exist for files opened at launch; reuse it first.
            let controller = index < controllers.count ? controllers[index] : makeWindow(restoringFrame: true)
            controller.restore(window)
        }

        var leftovers: [RecoveryStore.Snapshot] = []
        for snapshot in snapshots {
            if let url = snapshot.url, let owner = controllers.first(where: { $0.contains(url) }) {
                owner.restore(snapshots: [snapshot])
            } else {
                leftovers.append(snapshot)
            }
        }
        if !leftovers.isEmpty { (controllers.first ?? makeWindow()).restore(snapshots: leftovers) }

        hasRestored = true
        // Snapshots were keyed by the old documents' ids; rewrite them under the new ones.
        RecoveryStore.standard.removeAll()
        controllers.forEach { $0.writeRecoverySnapshots() }
        saveSession()
    }

    private func saveSession() {
        guard hasRestored else { return }
        Session(windows: controllers.map { $0.windowSession() }).save()
    }

    // MARK: - Menu actions

    @objc func newWindow(_ sender: Any?) {
        makeWindow()
    }

    @objc func newDocument(_ sender: Any?) {
        frontController().newDocument()
    }

    @objc func openDocument(_ sender: Any?) {
        let controller = frontController()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"]
            .compactMap { .init(filenameExtension: $0) }
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            for url in panel.urls where self?.focusExisting(url) != true {
                controller.open(url: url)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) {
        let controller = frontController()
        guard let document = controller.activeDocument else { return }
        controller.save(document: document)
    }

    @objc func showPreferences(_ sender: Any?) {
        PreferencesWindowController.shared.showWindow(nil)
    }

    @objc func showHelp(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/msk-mdi/MDedit#readme")!)
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let controller = frontController()
        guard let document = controller.activeDocument else { return }
        controller.saveAs(document: document)
    }
}
