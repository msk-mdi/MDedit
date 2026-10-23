import AppKit
import MarkdownKit

/// The single window: a transparent titlebar carrying the glass tab strip, an
/// opaque canvas below it, and a floating status pill.
@MainActor
final class MainWindowController: NSWindowController {
    private(set) var documents: [Document] = []
    /// Made the first time a tab is shown: restoring a session would
    /// otherwise build, lay out and scroll an editor for every tab.
    private var editors: [ObjectIdentifier: EditorViewController] = [:]
    /// Caret and modes for tabs restored but not shown yet.
    private var pendingTabs: [ObjectIdentifier: Session.Tab] = [:]
    /// How many tabs have an editor yet.
    var editorCount: Int { editors.count }
    private var selection = 0
    /// Files whose tabs were closed, most recent last, for Reopen Closed Tab.
    private var closedTabURLs: [URL] = []

    private let tabBar = TabBarView()
    private let statusBar = StatusBarView()
    private let sidebar = SidebarView()
    /// Slides the sidebar in from the window's edge, or out past it; the
    /// editor rides along on its trailing edge.
    private lazy var sidebarLeading = sidebar.leadingAnchor.constraint(
        equalTo: canvas.leadingAnchor,
        constant: isSidebarVisible ? 0 : -Metrics.sidebarWidth
    )
    private var isSidebarVisible = UserDefaults.standard.bool(forKey: "showSidebar")
    private var pendingOutlineRefresh: DispatchWorkItem?
    /// Typing changes the text and the selection, and each asks for the
    /// status; one refresh per run-loop turn answers both.
    private var isStatusRefreshScheduled = false
    /// Recounting a long document on every keystroke makes typing lag, so
    /// the count waits for a pause.
    private var pendingStatisticsRefresh: DispatchWorkItem?
    private(set) var workspace: Workspace?
    private var directoryWatcher: DirectoryWatcher?
    private lazy var quickOpenPanel: QuickOpenController = {
        let controller = QuickOpenController()
        controller.onOpen = { [weak self] url in self?.open(url: url) }
        return controller
    }()
    private let canvas = NSView()
    /// Owns the editors as real child view controllers, so their lifecycle runs
    /// and the responder chain reaches this controller.
    private let contentController = NSViewController()
    private(set) var currentEditor: EditorViewController?
    private var theme: Theme = .current(for: NSApp.effectiveAppearance)
    private var appearanceObservation: NSKeyValueObservation?

    /// Where unsaved text is snapshotted; a scratch store in tests.
    var recovery = RecoveryStore.standard

    // Hooks to the app, which owns every window.
    /// Something worth recording in the session changed.
    var onSessionChange: (() -> Void)?
    /// The window closed for good.
    var onClose: ((MainWindowController) -> Void)?
    /// Brings a file forward if another window has it open.
    var focusElsewhere: ((URL) -> Bool)?
    /// Asked to give a document a window of its own.
    var onMoveToNewWindow: ((Document) -> Void)?

    /// What to do with a document's unsaved changes before it goes.
    enum UnsavedAnswer {
        case save, discard, cancel
    }

    /// Asks about a document's unsaved changes; a sheet on the window unless
    /// something else (a test) answers instead.
    lazy var askAboutUnsaved: (Document, @escaping (UnsavedAnswer) -> Void) -> Void = { [weak self] document, answer in
        self?.presentUnsavedAlert(for: document, answer: answer)
    }
    /// Asks whether to drop unsaved edits for the file's changed contents;
    /// a sheet unless a test answers instead.
    lazy var askAboutExternalChange: (Document, @escaping (Bool) -> Void) -> Void = { [weak self] document, answer in
        self?.presentExternalChangeAlert(for: document, answer: answer)
    }
    /// Asks whether to save a document as UTF-8 when its text no longer fits
    /// the encoding it was read in; a sheet unless a test answers instead.
    lazy var askToConvertToUTF8: (Document, @escaping (Bool) -> Void) -> Void = { [weak self] document, answer in
        self?.presentConvertAlert(for: document, answer: answer)
    }
    /// Asks whether to save over changes another app made to the file since
    /// it was read; a sheet unless a test answers instead.
    lazy var askToOverwriteChangesOnDisk: (Document, @escaping (Bool) -> Void) -> Void = { [weak self] document, answer in
        self?.presentOverwriteAlert(for: document, answer: answer)
    }
    /// Shows an error; a sheet unless a test listens instead.
    lazy var showError: (Error) -> Void = { [weak self] error in
        guard let window = self?.window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
    /// Tells which of the last session's files could not be reopened; a
    /// sheet unless a test listens instead.
    lazy var tellAboutUnreopened: ([URL]) -> Void = { [weak self] urls in
        self?.presentUnreopenedAlert(for: urls)
    }
    private var pendingSnapshot: DispatchWorkItem?
    /// Set once the user has answered for every unsaved document, so closing
    /// the window and the quit that follows do not ask twice.
    private var changesReviewed = false

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = false
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("MdEditMainWindow")
        window.tabbingMode = .disallowed
        self.init(window: window)
        configure()
    }

    private func configure() {
        guard let window else { return }
        window.delegate = self

        // A window's content view is positioned by the window, not by constraints.
        canvas.autoresizingMask = [.width, .height]
        // Assigning a content view controller resizes the window to its view,
        // so the view carries the size we want before it is installed.
        canvas.frame = NSRect(origin: .zero, size: window.frame.size)
        contentController.view = canvas
        window.contentViewController = contentController
        window.setFrameUsingName("MdEditMainWindow")
        // Guard against a saved frame smaller than the window is usable at.
        if window.frame.width < 640 || window.frame.height < 480 {
            window.setContentSize(NSSize(width: 960, height: 700))
            window.center()
        }

        // A unified toolbar holding only the sidebar button puts the document
        // title at the leading edge, beside the traffic lights, and gives the
        // tab strip a row of its own.
        let toolbar = NSToolbar(identifier: "MdEditToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // The tab strip rides in the titlebar rather than stealing canvas height.
        tabBar.delegate = self
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = tabBar
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)

        canvas.addSubview(statusBar)
        statusBar.onShowStatistics = { [weak self] anchor in self?.showStatistics(from: anchor) }
        canvas.addSubview(sidebar)
        sidebar.isHidden = !isSidebarVisible
        sidebar.show(SidebarView.Pane(rawValue: UserDefaults.standard.integer(forKey: "sidebarPane")) ?? .outline)
        sidebar.onPaneChange = { [weak self] pane in self?.sidebarPaneChanged(pane) }
        sidebar.outline.onSelectHeading = { [weak self] heading in
            guard let self, let document = activeDocument else { return }
            moveCaret(toLine: heading.line, in: document)
        }
        sidebar.files.onOpenFile = { [weak self] url in self?.open(url: url) }
        sidebar.files.onChooseFolder = { [weak self] in self?.openFolder(nil) }
        sidebar.search.searchScope = { [weak self] in
            self?.searchScope() ?? (nil, [], [:])
        }
        sidebar.search.onOpenMatch = { [weak self] url, match in self?.openMatch(url, match) }
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),

            sidebarLeading,
            // Below the titlebar and tab strip: under the glass, the list
            // would be refracted into the chrome.
            sidebar.topAnchor.constraint(equalTo: (window.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? canvas.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.applyTheme(.current(for: app.effectiveAppearance))
            }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsDidChange), name: Settings.didChange, object: nil)
        applyTheme(theme)

        if documents.isEmpty {
            addDocument(Document(theme: theme))
        }
    }

    private func applyTheme(_ theme: Theme) {
        self.theme = theme
        window?.backgroundColor = theme.canvas
        tabBar.applyTheme(theme)
        statusBar.applyTheme(theme)
        sidebar.applyTheme(theme)
        for editor in editors.values { editor.applyTheme(theme) }
    }

    @objc private func settingsDidChange() {
        applyTheme(.current(for: NSApp.effectiveAppearance))
        let settings = Settings()
        for editor in editors.values { editor.applySettings(settings) }
    }

    // MARK: - Documents

    var activeDocument: Document? {
        documents.indices.contains(selection) ? documents[selection] : nil
    }

    func addDocument(_ document: Document, selecting: Bool = true) {
        document.onExternalChange = { [weak self, weak document] in
            guard let self, let document else { return }
            handleExternalChange(of: document)
        }
        document.onMove = { [weak self, weak document] in
            guard let self, let document else { return }
            if activeDocument === document {
                window?.title = document.displayName
                window?.representedURL = document.url
            }
            refreshTabs()
            onSessionChange?()
        }
        documents.append(document)
        if selecting { select(index: documents.count - 1) }
        refreshTabs()
    }

    /// The document's editor, made now if its tab has not been shown yet.
    private func editor(for document: Document) -> EditorViewController {
        if let editor = editors[ObjectIdentifier(document)] { return editor }
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        editor.applyTheme(theme)
        editor.onSelectionChange = { [weak self] in
            self?.refreshStatus()
            self?.followCaretInOutline()
        }
        editor.textView.documentURL = { [weak document] in document?.url }
        editor.textView.onOpenFiles = { [weak self] urls in urls.forEach { self?.open(url: $0) } }
        editor.onOpenLink = { [weak self, weak document] destination in
            guard let self, let document else { return }
            openLink(destination, from: document)
        }
        editor.onTextChange = { [weak self] in
            self?.changesReviewed = false
            self?.refreshTabs()
            self?.refreshStatus()
            self?.scheduleRecoverySnapshot()
            self?.scheduleOutlineRefresh()
        }
        editors[ObjectIdentifier(document)] = editor
        if let tab = pendingTabs.removeValue(forKey: ObjectIdentifier(document)) {
            restore(tab, in: editor, of: document)
        }
        return editor
    }

    /// Brings an already-open file forward instead of opening it twice.
    func focusDocument(at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        guard let index = documents.firstIndex(where: { $0.url?.standardizedFileURL.path == path }) else { return false }
        select(index: index)
        window?.makeKeyAndOrderFront(nil)
        return true
    }

    var openDocumentCount: Int { documents.count }

    func select(index: Int) {
        guard documents.indices.contains(index) else { return }
        selection = index
        let document = documents[index]
        let editor = editor(for: document)

        if currentEditor !== editor {
            let isSwitch = currentEditor != nil
            currentEditor?.view.removeFromSuperview()
            currentEditor?.removeFromParent()
            install(editor)
            currentEditor = editor
            if isSwitch { fadeIn(editor.view) }
        }
        window?.makeFirstResponder(editor.textView)
        window?.title = document.displayName
        window?.representedURL = document.url
        refreshTabs()
        refreshStatus()
        refreshSidebar()
    }

    /// The incoming tab's page fades up as the thumb slides to it.
    private func fadeIn(_ view: NSView) {
        guard window?.isVisible == true, Motion.isEnabled else { return }
        view.alphaValue = 0
        Motion.animate(Motion.standard) { view.animator().alphaValue = 1 }
    }

    private func install(_ editor: EditorViewController) {
        contentController.addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(editor.view, positioned: .below, relativeTo: statusBar)
        NSLayoutConstraint.activate([
            editor.view.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            // Below the titlebar, which stays an opaque band of canvas colour
            // rather than showing the text scrolled beneath it.
            editor.view.topAnchor.constraint(equalTo: (window?.contentLayoutGuide as? NSLayoutGuide)?.topAnchor ?? canvas.topAnchor),
            editor.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
    }

    func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        let document = documents[index]
        guard document.isDirty else {
            remove(document)
            recovery.remove(id: document.id)
            rememberClosed(document)
            return
        }
        confirmDiscard(document) { [weak self] discard in
            guard discard, let self else { return }
            remove(document)
            recovery.remove(id: document.id)
            rememberClosed(document)
        }
    }

    /// Takes a document out of this window without asking about changes;
    /// the window closes once it has nothing left. Keeping the selection
    /// leaves the tab shown alone when another goes.
    private func remove(_ document: Document) {
        // Looked up afresh: tabs may have moved while a sheet was up.
        guard let index = documents.firstIndex(where: { $0 === document }) else { return }
        if let editor = editors.removeValue(forKey: ObjectIdentifier(document)) {
            if editor === currentEditor {
                editor.view.removeFromSuperview()
                editor.removeFromParent()
                currentEditor = nil
            }
            editor.detachFromStorage()
        }
        pendingTabs.removeValue(forKey: ObjectIdentifier(document))
        let shown = activeDocument
        documents.remove(at: index)
        if documents.isEmpty {
            window?.close()
        } else if let shown, shown !== document, let kept = documents.firstIndex(where: { $0 === shown }) {
            // A tab closed in the background leaves the one in front there.
            selection = kept
            refreshTabs()
        } else {
            select(index: min(index, documents.count - 1))
        }
        // The session forgets the tab now, and the access to its file a
        // sandboxed app started goes with it.
        onSessionChange?()
    }

    private func rememberClosed(_ document: Document) {
        guard let url = document.url else { return }
        closedTabURLs.removeAll { $0 == url }
        closedTabURLs.append(url)
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        // Skips files that have since gone or are open again.
        while let url = closedTabURLs.popLast() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            open(url: url)
            return
        }
        NSSound.beep()
    }

    // MARK: - Moving tabs between windows

    @objc func moveTabToNewWindow(_ sender: Any?) {
        moveToNewWindow(at: selection)
    }

    private func moveToNewWindow(at index: Int) {
        // A lone tab already has a window of its own.
        guard documents.count > 1, documents.indices.contains(index) else {
            NSSound.beep()
            return
        }
        let document = documents[index]
        remove(document)
        onMoveToNewWindow?(document)
    }

    /// Takes in a document from another window, unsaved changes and all.
    func adopt(_ document: Document) {
        addReplacingPlaceholder(document)
        onSessionChange?()
    }

    private func confirmDiscard(_ document: Document, completion: @escaping (Bool) -> Void) {
        askAboutUnsaved(document) { [weak self] answer in
            switch answer {
            case .save:
                guard let self else { return completion(false) }
                save(document: document) { saved in completion(saved) }
            case .discard:
                completion(true)
            case .cancel:
                completion(false)
            }
        }
    }

    private func presentUnsavedAlert(for document: Document, answer: @escaping (UnsavedAnswer) -> Void) {
        guard let window else { return answer(.discard) }
        let alert = NSAlert()
        alert.messageText = String(localized: "Save changes to “\(document.displayName)” before closing?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: answer(.save)
            case .alertThirdButtonReturn: answer(.discard)
            default: answer(.cancel)
            }
        }
    }

    func refreshTabs() {
        tabBar.setTabs(
            documents.map { TabDescriptor(id: $0.id, title: $0.displayName, isDirty: $0.isDirty) },
            selected: selection
        )
    }

    func refreshStatus() {
        guard !isStatusRefreshScheduled else { return }
        isStatusRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            isStatusRefreshScheduled = false
            updateStatus()
        }
    }

    private func updateStatus() {
        guard let document = activeDocument, let editor = currentEditor else { return }
        let statistics: TextStatistics
        if document.hasCurrentStatistics || (document.latestStatistics == nil && document.storage.length < Self.countInPlace) {
            statistics = document.statistics()
        } else if let latest = document.latestStatistics {
            statistics = latest
            scheduleStatisticsRefresh()
        } else {
            // A large document shown for the first time: counted straight
            // away, but not on the main thread.
            statistics = TextStatistics("")
            scheduleStatisticsRefresh(after: 0)
        }
        let selection = selectionStatistics()
        let (line, column) = editor.caretPosition()
        statusBar.update(statistics: statistics, selection: selection, goal: document.wordGoal, line: line, column: column)
        if statisticsPopover.isShown {
            statisticsController.show(selection ?? statistics, isSelection: selection != nil, goal: document.wordGoal)
        }
    }

    /// UTF-16 units under which a document never yet counted is counted
    /// at once, on the main thread: a few milliseconds at most.
    private static let countInPlace = 200_000

    /// Recounts once typing pauses, away from the main thread; an edit
    /// during the count schedules another.
    private func scheduleStatisticsRefresh(after delay: TimeInterval = 0.3) {
        pendingStatisticsRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let document = activeDocument else { return }
            Task { [weak self] in
                guard await document.countStatistics() != nil, let self, activeDocument === document else { return }
                updateStatus()
            }
        }
        pendingStatisticsRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Counts for the selected text, if any.
    ///
    /// Every selection change asks. The whole text has the document's own
    /// counts, the same selection is counted once, and while a large one is
    /// being extended the last count stands until the selection settles.
    private func selectionStatistics() -> TextStatistics? {
        guard let editor = currentEditor, let document = activeDocument else { return nil }
        // A count waiting for an older selection would read ranges that an
        // edit since may have left past the end of the text.
        pendingSelectionCount?.cancel()
        pendingSelectionCount = nil
        let ranges = editor.textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return nil }
        let generation = editor.storage.editGeneration
        let cached = selectionCount.flatMap { $0.editor == ObjectIdentifier(editor) ? $0 : nil }
        if let cached, cached.ranges == ranges, cached.generation == generation { return cached.value }
        if ranges.count == 1, ranges[0].length == editor.storage.length { return document.statistics() }

        let length = ranges.reduce(0) { $0 + $1.length }
        if length > Self.largeSelection, let stale = cached?.value {
            let work = DispatchWorkItem { [weak self] in
                guard let self, currentEditor === editor, editor.storage.editGeneration == generation else { return }
                selectionCount = (ObjectIdentifier(editor), ranges, generation, countSelection(ranges, in: editor))
                updateStatus()
            }
            pendingSelectionCount = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
            return stale
        }
        let value = countSelection(ranges, in: editor)
        selectionCount = (ObjectIdentifier(editor), ranges, generation, value)
        return value
    }

    private func countSelection(_ ranges: [NSRange], in editor: EditorViewController) -> TextStatistics {
        let text = editor.storage.text
        return TextStatistics(ranges.map { text.substring(with: $0) }.joined(separator: "\n"))
    }

    /// UTF-16 units past which a selection is counted once it settles.
    private static let largeSelection = 100_000
    private var selectionCount: (editor: ObjectIdentifier, ranges: [NSRange], generation: Int, value: TextStatistics)?
    private var pendingSelectionCount: DispatchWorkItem?

    private lazy var statisticsController: StatisticsViewController = {
        let controller = StatisticsViewController()
        controller.onSetGoal = { [weak self] goal in
            self?.activeDocument?.wordGoal = goal
            self?.refreshStatus()
        }
        return controller
    }()

    private lazy var statisticsPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = statisticsController
        return popover
    }()

    private func showStatistics(from anchor: NSView) {
        guard let document = activeDocument else { return }
        if statisticsPopover.isShown { return statisticsPopover.performClose(nil) }
        let selection = selectionStatistics()
        statisticsController.show(selection ?? document.statistics(), isSelection: selection != nil, goal: document.wordGoal)
        statisticsPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
    }

    @objc func showDocumentStatistics(_ sender: Any?) {
        showStatistics(from: statusBar.statisticsAnchor)
    }

    // MARK: - File commands

    func newDocument() {
        addDocument(Document(theme: theme))
    }

    /// Opens bundled text as an untitled tab of its own: a copy to play
    /// with, not the bundle's file, and not unsaved until changed.
    func openCopy(of text: String, named name: String) {
        let document = Document(text: text, theme: theme)
        document.untitledName = name
        addReplacingPlaceholder(document)
    }

    /// Opens a file in a tab of its own, read off the main thread. The task
    /// ends once the tab is there or the error shown; there is none when
    /// the file was already open and has been brought forward instead.
    @discardableResult
    func open(url: URL) -> Task<Void, Never>? {
        if focusDocument(at: url) { return nil }
        if focusElsewhere?(url) == true { return nil }
        let path = url.standardizedFileURL.path
        // Asked again while it is still being read: one tab, not two.
        if let opening = openings[path] { return opening }
        let readFile = readFile
        let opening = Task { [weak self] in
            do {
                let read = try await FileFormat.read(url, using: readFile)
                guard let self else { return }
                openings[path] = nil
                // Opened some other way while it was being read.
                if focusDocument(at: url) || focusElsewhere?(url) == true { return }
                addReplacingPlaceholder(Document.open(url, read: read, theme: theme))
            } catch {
                self?.openings[path] = nil
                self?.show(error: error)
            }
        }
        openings[path] = opening
        return opening
    }

    /// Files being read for tabs, by path.
    private var openings: [String: Task<Void, Never>] = [:]
    /// Reads a file's bytes; called off the main thread. A test stands in
    /// a file that is slow to arrive.
    var readFile: @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }

    /// Files being read again for their tabs, by when they started.
    private var reloads: [Int: Task<Void, Never>] = [:]
    private var nextReload = 0

    /// Waits until every file being opened has its tab, or its error shown,
    /// and every file being read again has been taken in.
    func finishReading() async {
        while let reading = openings.values.first ?? reloads.values.first { await reading.value }
    }

    /// Reads several files side by side, off the main thread; nil for any
    /// that could not be read.
    private func read(_ urls: [URL]) async -> [(text: String, format: FileFormat)?] {
        let readFile = readFile
        return await withTaskGroup(of: (Int, (text: String, format: FileFormat)?).self) { group in
            for (index, url) in urls.enumerated() {
                group.addTask { (index, try? await FileFormat.read(url, using: readFile)) }
            }
            var found = [(text: String, format: FileFormat)?](repeating: nil, count: urls.count)
            for await (index, read) in group { found[index] = read }
            return found
        }
    }

    /// Adds a document; an untouched empty tab is replaced rather than left behind.
    private func addReplacingPlaceholder(_ document: Document) {
        addDocument(document)
        if let index = documents.firstIndex(where: { $0 !== document && $0.url == nil && !$0.isDirty && $0.storage.length == 0 }) {
            closeDocument(at: index)
            if let added = documents.firstIndex(where: { $0 === document }) { select(index: added) }
        }
    }

    func save(document: Document, completion: ((Bool) -> Void)? = nil) {
        if document.url == nil {
            saveAs(document: document, completion: completion)
            return
        }
        write(document) { [weak self] saved in
            if saved {
                self?.refreshTabs()
                self?.writeRecoverySnapshots()
            }
            completion?(saved)
        }
    }

    /// Saves, offering UTF-8 when the text no longer fits the file's own
    /// encoding: without that, every save and Save As would fail alike.
    private func write(
        _ document: Document, to target: URL? = nil, overwritingChanges: Bool = false,
        completion: @escaping (Bool) -> Void
    ) {
        do {
            try document.save(to: target, overwritingChanges: overwritingChanges)
            completion(true)
        } catch is Document.ChangedOnDiskError {
            // Another app wrote the file since it was read: saving blindly
            // would throw its changes away unseen.
            askToOverwriteChangesOnDisk(document) { [weak self] overwrite in
                guard overwrite, let self else { return completion(false) }
                write(document, to: target, overwritingChanges: true, completion: completion)
            }
        } catch let error as CocoaError where error.code == .fileWriteInapplicableStringEncoding && document.format.encoding != .utf8 {
            askToConvertToUTF8(document) { [weak self] convert in
                guard convert, let self else { return completion(false) }
                document.format.encoding = .utf8
                write(document, to: target, overwritingChanges: overwritingChanges, completion: completion)
            }
        } catch {
            show(error: error)
            completion(false)
        }
    }

    private func presentConvertAlert(for document: Document, answer: @escaping (Bool) -> Void) {
        guard let window else { return answer(false) }
        let encoding = String.localizedName(of: document.format.encoding)
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(document.displayName)” can’t be saved as \(encoding).")
        alert.informativeText = String(localized: "Some of its text has no \(encoding) form. Saving it as UTF-8 keeps all of it.")
        alert.addButton(withTitle: String(localized: "Save as UTF-8"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    private func presentOverwriteAlert(for document: Document, answer: @escaping (Bool) -> Void) {
        guard let window else { return answer(false) }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(document.displayName)” was changed by another application.")
        alert.informativeText = String(localized: "Saving now replaces those changes with yours.")
        alert.addButton(withTitle: String(localized: "Save Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.beginSheetModal(for: window) { answer($0 == .alertFirstButtonReturn) }
    }

    func saveAs(document: Document, completion: ((Bool) -> Void)? = nil) {
        guard let window else { return completion?(false) ?? () }
        let panel = NSSavePanel()
        // The first type supplies the default extension.
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"]
            .compactMap { .init(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? document.displayName + ".md"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return completion?(false) ?? () }
            write(document, to: url) { [weak self] saved in
                if saved {
                    self?.window?.title = document.displayName
                    self?.window?.representedURL = url
                    self?.refreshTabs()
                    self?.writeRecoverySnapshots()
                }
                completion?(saved)
            }
        }
    }

    /// A file changed on disk: reload quietly when there is nothing to lose,
    /// ask when there is.
    private func handleExternalChange(of document: Document) {
        guard window != nil, documents.contains(where: { $0 === document }) else { return }
        if let url = document.url, !FileManager.default.fileExists(atPath: url.path) {
            // A save-by-replace can leave the path empty for a moment; look again.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self, weak document] in
                guard let self, let document else { return }
                if FileManager.default.fileExists(atPath: url.path) {
                    document.beginWatching()
                    handleExternalChange(of: document)
                } else {
                    // Deleted or moved: the editor now holds the only copy.
                    document.markMissingOnDisk()
                    refreshTabs()
                    scheduleRecoverySnapshot()
                }
            }
            return
        }
        guard document.isDirty else { return reloadFromDisk(document) }
        askWhetherToReload(document)
    }

    /// Documents with a "changed on disk" question still unanswered.
    private var askingAboutExternalChange: Set<ObjectIdentifier> = []

    /// Asks whether to reload over unsaved edits, once however many changes
    /// arrive before the answer: a file rewritten again and again (a sync,
    /// a build) would otherwise stack a sheet for each. Reload reads the
    /// file as it is by then.
    private func askWhetherToReload(_ document: Document) {
        let key = ObjectIdentifier(document)
        guard askingAboutExternalChange.insert(key).inserted else { return }
        askAboutExternalChange(document) { [weak self] reload in
            self?.askingAboutExternalChange.remove(key)
            guard reload else { return document.keepEditsOverChangeOnDisk() }
            self?.reloadFromDisk(document)
        }
    }

    /// Reads a document's file again, off the main thread. Edits typed while
    /// it was read are not thrown away: they are asked about like any others.
    private func reloadFromDisk(_ document: Document) {
        let readFile = readFile
        let id = nextReload
        nextReload += 1
        reloads[id] = Task { [weak self, weak document] in
            defer { self?.reloads[id] = nil }
            guard let document else { return }
            do {
                if try await document.revert(using: readFile) == false {
                    self?.handleExternalChange(of: document)
                    return
                }
            } catch {
                // The editor still holds the old text, which no longer is
                // what the file holds: say so rather than pass it off as
                // current. Saving it asks before writing over the file.
                // Once, however often a file that stays unreadable changes.
                guard let self, documents.contains(where: { $0 === document }),
                      unreadableOnDisk.insert(ObjectIdentifier(document)).inserted
                else { return }
                show(error: error)
                return
            }
            self?.unreadableOnDisk.remove(ObjectIdentifier(document))
            self?.refreshTabs()
            self?.refreshStatus()
        }
    }

    /// Documents whose file could not be read again, already told about.
    private var unreadableOnDisk: Set<ObjectIdentifier> = []

    private func presentExternalChangeAlert(for document: Document, answer: @escaping (Bool) -> Void) {
        guard let window else { return answer(false) }
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(document.displayName)” changed on disk.")
        alert.informativeText = String(localized: "You have unsaved changes here. Reloading discards them.")
        alert.addButton(withTitle: String(localized: "Keep My Changes"))
        alert.addButton(withTitle: String(localized: "Reload"))
        alert.beginSheetModal(for: window) { answer($0 == .alertSecondButtonReturn) }
    }

    // MARK: - Links

    /// Follows a link: web addresses go to the browser, `#anchors` jump to a
    /// heading, markdown files open in a tab, anything else in its own app —
    /// except other URL schemes, which ask first, and programs and scripts,
    /// which are shown in Finder rather than run (`LinkPolicy`).
    func openLink(_ destination: String, from document: Document) {
        if destination.hasPrefix("#") {
            jumpToHeading(slug: String(destination.dropFirst()), in: document)
            return
        }
        if let url = URL(string: destination), let scheme = url.scheme, scheme.lowercased() != "file" {
            switch LinkPolicy.action(forScheme: scheme) {
            case .open: NSWorkspace.shared.open(url)
            case .confirm, .reveal: confirmOpening(url)
            }
            return
        }
        guard let target = fileURL(for: destination, relativeTo: document.url) else {
            NSSound.beep()
            return
        }
        guard FileManager.default.fileExists(atPath: target.path) else {
            show(error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: target.path]))
            return
        }
        if ["md", "markdown", "mdown", "mkd"].contains(target.pathExtension.lowercased()) {
            open(url: target)
        } else if LinkPolicy.action(forFile: target) == .reveal {
            NSWorkspace.shared.activateFileViewerSelecting([target])
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// An address another app handles, opened once the user has seen it.
    private func confirmOpening(_ url: URL) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Open this link in another app?")
        alert.informativeText = url.absoluteString
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Open"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            NSWorkspace.shared.open(url)
        }
    }

    /// A local link's file, without any `#fragment`. Relative paths need the
    /// document to have been saved somewhere.
    private func fileURL(for destination: String, relativeTo base: URL?) -> URL? {
        let path = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard !path.isEmpty else { return nil }
        if let url = URL(string: path), url.scheme == "file" { return url }
        let decoded = path.removingPercentEncoding ?? path
        let expanded = (decoded as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return URL(fileURLWithPath: expanded) }
        guard let base else { return nil }
        return URL(fileURLWithPath: expanded, relativeTo: base.deletingLastPathComponent()).standardizedFileURL
    }

    private func jumpToHeading(slug: String, in document: Document) {
        let text = document.storage.text
        let wanted = (slug.removingPercentEncoding ?? slug).lowercased()
        guard let heading = document.storage.structure.headings(in: text).first(where: { $0.slug == wanted }) else {
            NSSound.beep()
            return
        }
        moveCaret(toLine: heading.line, in: document)
    }

    /// Puts the caret at the start of a line and brings it into view.
    private func moveCaret(toLine line: Int, in document: Document) {
        guard line < document.storage.structure.lineCount else { return }
        let editor = editor(for: document)
        let range = NSRange(location: document.storage.structure.index.range(ofLine: line).location, length: 0)
        editor.textView.setSelectedRange(range)
        editor.textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(editor.textView)
    }

    // MARK: - Sidebar

    @objc func toggleFiles(_ sender: Any?) { toggleSidebar(showing: .files) }
    /// Shows or hides the sidebar on whichever pane it last showed.
    @objc func toggleSidebarVisibility(_ sender: Any?) { setSidebarVisible(!isSidebarVisible) }
    @objc func toggleOutline(_ sender: Any?) { toggleSidebar(showing: .outline) }

    /// Shows the sidebar on a pane, or hides it if it is already showing that pane.
    private func toggleSidebar(showing pane: SidebarView.Pane) {
        if isSidebarVisible, sidebar.pane == pane {
            setSidebarVisible(false)
        } else {
            sidebar.show(pane)
            sidebarPaneChanged(pane)
            setSidebarVisible(true)
        }
    }

    private func setSidebarVisible(_ visible: Bool) {
        isSidebarVisible = visible
        UserDefaults.standard.set(visible, forKey: "showSidebar")
        if visible { sidebar.isHidden = false }
        let animated = window?.isVisible == true && Motion.isEnabled
        canvas.layoutSubtreeIfNeeded()
        let editor = currentEditor
        let before = editor.map { (x: $0.view.frame.minX, inset: $0.textView.textContainerInset.width) }
        sidebarLeading.constant = visible ? 0 : -Metrics.sidebarWidth
        if animated {
            Motion.animate(Motion.slow) {
                sidebar.animator().alphaValue = visible ? 1 : 0
                canvas.layoutSubtreeIfNeeded()
            } completion: { [weak self] in
                // A quick second toggle may have brought it back meanwhile.
                guard let self, !isSidebarVisible else { return }
                sidebar.isHidden = true
            }
            if let editor, let before { slide(editor, from: before.x, inset: before.inset) }
        } else {
            sidebar.alphaValue = visible ? 1 : 0
            sidebar.isHidden = !visible
        }
        refreshSidebar()
    }

    /// The editor keeps pace with the sliding sidebar. A scroll view takes its
    /// new frame at once rather than animating to it, and its text column
    /// re-centres in one step, so both are drawn gliding to where they now are
    /// from where they were, on the sidebar's curve.
    private func slide(_ editor: EditorViewController, from x: CGFloat, inset: CGFloat) {
        editor.view.layoutSubtreeIfNeeded()
        let shifts = [
            (editor.view, x - editor.view.frame.minX),
            // The column moves half as far as the editor's edge: it is centred.
            (editor.textView as NSView, inset - editor.textView.textContainerInset.width),
        ]
        for (view, shift) in shifts where abs(shift) > 0.5 {
            let glide = CABasicAnimation(keyPath: "transform.translation.x")
            glide.fromValue = shift
            glide.toValue = 0
            glide.isAdditive = true
            glide.duration = Motion.slow
            glide.timingFunction = Motion.curve
            view.layer?.add(glide, forKey: "sidebarGlide")
        }
    }

    private func sidebarPaneChanged(_ pane: SidebarView.Pane) {
        UserDefaults.standard.set(pane.rawValue, forKey: "sidebarPane")
        refreshSidebar()
        if pane == .search { window?.makeFirstResponder(sidebar.search.field) }
    }

    private func refreshSidebar() {
        guard isSidebarVisible else { return }
        switch sidebar.pane {
        case .outline: refreshOutline()
        case .files: if let url = activeDocument?.url { sidebar.files.reveal(url) }
        case .search: break
        }
    }

    /// Headings are cheap to find but typing is frequent, so wait for a pause.
    private func scheduleOutlineRefresh() {
        guard isSidebarVisible, sidebar.pane == .outline else { return }
        pendingOutlineRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshOutline() }
        pendingOutlineRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func refreshOutline() {
        guard isSidebarVisible, sidebar.pane == .outline, let document = activeDocument else { return }
        let storage = document.storage
        sidebar.outline.setHeadings(storage.headings)
        followCaretInOutline()
    }

    private func followCaretInOutline() {
        guard isSidebarVisible, sidebar.pane == .outline, let document = activeDocument, let editor = currentEditor else { return }
        sidebar.outline.highlightSection(containing: document.storage.line(at: editor.textView.selectedRange().location))
    }

    // MARK: - Workspace

    @objc func openFolder(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = String(localized: "Open Folder")
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            setWorkspace(Workspace(root: url))
            sidebar.show(.files)
            sidebarPaneChanged(.files)
            if !isSidebarVisible { setSidebarVisible(true) }
        }
    }

    func setWorkspace(_ newWorkspace: Workspace?) {
        workspace = newWorkspace
        newWorkspace?.save()
        if let root = newWorkspace?.root { FileAccess.remember(root) }
        sidebar.files.setRoot(newWorkspace?.root)
        window?.subtitle = newWorkspace?.root.lastPathComponent ?? ""
        directoryWatcher = newWorkspace.flatMap { workspace in
            DirectoryWatcher(url: workspace.root) { [weak self] change in
                self?.sidebar.files.folderContentsChanged(change)
                self?.sidebar.search.workspaceContentsChanged()
            }
        }
        onSessionChange?()
    }

    @objc func quickOpen(_ sender: Any?) {
        quickOpenPanel.show(over: window, workspace: workspace, openDocuments: documents.compactMap(\.url))
    }

    @objc func findInFolder(_ sender: Any?) {
        sidebar.show(.search)
        sidebarPaneChanged(.search)
        if !isSidebarVisible { setSidebarVisible(true) }
        // Seed the query with the selection, as Find does.
        if let editor = currentEditor, editor.textView.selectedRange().length > 0 {
            let selected = (editor.storage.text).substring(with: editor.textView.selectedRange())
            if !selected.contains("\n") {
                sidebar.search.field.stringValue = selected
                sidebar.search.search()
            }
        }
        window?.makeFirstResponder(sidebar.search.field)
    }

    /// What Find in Folder reads: the workspace, open files, and unsaved text.
    private func searchScope() -> (workspace: Workspace?, openFiles: [URL], overrides: [URL: String]) {
        var overrides: [URL: String] = [:]
        for document in documents where document.isDirty {
            if let url = document.url { overrides[url] = document.text }
        }
        return (workspace, documents.compactMap(\.url), overrides)
    }

    /// Opens a search result's file and selects the match.
    private func openMatch(_ url: URL, _ match: WorkspaceSearch.Match) {
        guard let opening = open(url: url) else { return select(match, in: url) }
        Task { [weak self] in
            await opening.value
            self?.select(match, in: url)
        }
    }

    private func select(_ match: WorkspaceSearch.Match, in url: URL) {
        guard let document = activeDocument, document.url?.standardizedFileURL == url.standardizedFileURL,
              let editor = currentEditor, match.line < document.storage.structure.lineCount
        else { return }
        let lineStart = document.storage.structure.index.range(ofLine: match.line).location
        let range = NSRange(location: lineStart + match.range.location, length: match.range.length)
        guard NSMaxRange(range) <= document.storage.length else { return }
        editor.textView.setSelectedRange(range)
        editor.textView.scrollRangeToVisible(range)
        editor.textView.showFindIndicator(for: range)
        window?.makeFirstResponder(editor.textView)
    }

    // MARK: - Unsaved changes

    /// Whether quitting needs to ask about unsaved documents first.
    var hasUnreviewedChanges: Bool {
        !changesReviewed && documents.contains(where: \.isDirty)
    }

    /// Reviews several windows in turn, bringing each forward; Cancel in any
    /// of them stops the review. This is what quitting does.
    static func reviewUnsavedChanges(in controllers: [MainWindowController], completion: @escaping (Bool) -> Void) {
        var remaining = controllers.filter(\.hasUnreviewedChanges).makeIterator()
        func next() {
            guard let controller = remaining.next() else { return completion(true) }
            controller.window?.makeKeyAndOrderFront(nil)
            controller.reviewUnsavedChanges { proceed in
                if proceed { return next() }
                // The quit is off, so a "Don't Save" given for it no longer
                // stands: closing those windows later must ask again.
                for controller in controllers { controller.changesReviewed = false }
                completion(false)
            }
        }
        next()
    }

    /// Asks about each unsaved document in turn. Completes with false as soon
    /// as the user cancels, true once every document has an answer.
    func reviewUnsavedChanges(completion: @escaping (Bool) -> Void) {
        let dirty = documents.filter(\.isDirty)
        var remaining = dirty.makeIterator()
        func next() {
            guard let document = remaining.next() else {
                changesReviewed = true
                return completion(true)
            }
            guard documents.contains(where: { $0 === document }), document.isDirty else { return next() }
            if let index = documents.firstIndex(where: { $0 === document }) { select(index: index) }
            confirmDiscard(document) { proceed in
                proceed ? next() : completion(false)
            }
        }
        next()
    }

    // MARK: - Recovery and session

    var recoveryTiming = RecoveryStore.Timing()
    /// When the oldest change not yet in a snapshot was made.
    private var unsnapshottedSince: Date?

    private func scheduleRecoverySnapshot() {
        let now = Date()
        let firstChange = unsnapshottedSince ?? now
        unsnapshottedSince = firstChange
        pendingSnapshot?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeRecoverySnapshots() }
        pendingSnapshot = work
        let delay = recoveryTiming.delay(sinceFirstChange: now.timeIntervalSince(firstChange))
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Writes a snapshot for every unsaved document changed since its last
    /// one and drops those of saved documents, then records the open tabs so
    /// a crash can be recovered from too. `rewriting` writes them all again,
    /// after the snapshots on disk were cleared.
    func writeRecoverySnapshots(rewriting: Bool = false) {
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
        unsnapshottedSince = nil
        for document in documents {
            let state = Document.SnapshotState(generation: document.storage.editGeneration, url: document.url)
            if document.isDirty {
                guard rewriting || document.snapshotState != state else { continue }
                recovery.writeLater(.init(
                    id: document.id, url: document.url, text: document.text,
                    base: document.url == nil ? nil : document.savedDigest
                ))
                document.snapshotState = state
            } else if rewriting || document.snapshotState != nil {
                recovery.remove(id: document.id)
                document.snapshotState = nil
            }
        }
        onSessionChange?()
    }

    /// Stops pending snapshot writes, for a clean quit.
    func cancelPendingWork() {
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
        unsnapshottedSince = nil
    }

    /// Whether this window has a file or unsaved snapshot for a URL.
    func contains(_ url: URL) -> Bool {
        document(at: url) != nil
    }

    /// The tab holding a file, if this window has one.
    private func document(at url: URL) -> Document? {
        let path = url.standardizedFileURL.path
        return documents.first { $0.url?.standardizedFileURL.path == path }
    }

    /// This window's tabs, folder and position, for the session.
    func windowSession() -> Session.Window {
        var tabs: [Session.Tab] = []
        var selectedIndex = 0
        for (index, document) in documents.enumerated() {
            guard let url = document.url else { continue }
            if index == selection { selectedIndex = tabs.count }
            guard let editor = editors[ObjectIdentifier(document)] else {
                // Never shown this session: as it was restored.
                var tab = pendingTabs[ObjectIdentifier(document)] ?? .init(url: url, selectedLocation: 0)
                tab.url = url
                tabs.append(tab)
                continue
            }
            tabs.append(.init(
                url: url,
                selectedLocation: editor.textView.selectedRange().location,
                sourceMode: editor.sourceMode,
                typewriterMode: editor.activeLine.typewriterMode,
                focusMode: editor.activeLine.focusMode
            ))
        }
        return Session.Window(
            tabs: tabs,
            selectedIndex: selectedIndex,
            workspace: workspace?.root,
            frame: window?.frameDescriptor
        )
    }

    /// Reopens a window's files from the previous session, skipping any
    /// that have gone, and its folder and position. The files are read side
    /// by side, off the main thread, and come back in their saved order.
    /// Returns the files that could not be read.
    @discardableResult
    func restore(_ saved: Session.Window) async -> [URL] {
        if let frame = saved.frame { window?.setFrame(from: frame) }
        if let root = saved.workspace, FileManager.default.fileExists(atPath: root.path) {
            setWorkspace(Workspace(root: root))
        }
        // An untouched empty tab gives way, once another is showing: closed
        // first, it would show the next tab, and make its editor, on the way.
        let placeholder = documents.first { $0.url == nil && !$0.isDirty && $0.storage.length == 0 }
        let unopened = saved.tabs.indices.filter { !contains(saved.tabs[$0].url) }
        let reads = await read(unopened.map { saved.tabs[$0].url })
        var found: [Int: (text: String, format: FileFormat)] = [:]
        for (index, read) in zip(unopened, reads) { found[index] = read }
        var selected: Document?
        var restoredLast: Document?
        var unreopened: [URL] = []
        for (index, tab) in saved.tabs.enumerated() {
            // Looked up after the reads: a file opened meanwhile has its tab.
            let document = document(at: tab.url)
                ?? found[index].map { read in
                    let opened = Document.open(tab.url, read: read, theme: theme)
                    addDocument(opened, selecting: false)
                    return opened
                }
            guard let document else {
                unreopened.append(tab.url)
                continue
            }
            if index == saved.selectedIndex { selected = document }
            restoredLast = document
            // Applied when the tab is first shown, or now if it already has been.
            if let editor = editors[ObjectIdentifier(document)] {
                restore(tab, in: editor, of: document)
            } else {
                pendingTabs[ObjectIdentifier(document)] = tab
            }
        }
        // The saved tab, or the last one restored if that has gone.
        if let selected = selected ?? restoredLast, let index = documents.firstIndex(where: { $0 === selected }) {
            select(index: index)
        }
        if let placeholder, restoredLast != nil, documents.contains(where: { $0 === placeholder }), !placeholder.isDirty {
            remove(placeholder)
            recovery.remove(id: placeholder.id)
        }
        refreshTabs()
        return unreopened
    }

    /// Says which files from the last session did not come back, once
    /// recovered text has had its say: a file it reopened is left out.
    func reportUnreopened(_ urls: [URL]) {
        let missing = urls.filter { !contains($0) }
        guard !missing.isEmpty else { return }
        tellAboutUnreopened(missing)
    }

    private func presentUnreopenedAlert(for urls: [URL]) {
        guard let window else { return }
        let shown = 10
        var paths = urls.prefix(shown).map { ($0.path as NSString).abbreviatingWithTildeInPath }
        if urls.count > shown { paths.append(String(localized: "and \(urls.count - shown) more")) }
        let alert = NSAlert()
        alert.messageText = urls.count == 1
            ? String(localized: "“\(urls[0].lastPathComponent)” couldn’t be reopened.")
            : String(localized: "\(urls.count) files from your last session couldn’t be reopened.")
        alert.informativeText = String(localized: "They may have been moved, renamed or deleted, or MdEdit may no longer be allowed to read them.")
            + "\n\n" + paths.joined(separator: "\n")
        alert.beginSheetModal(for: window)
    }

    /// Lays recovered unsaved text over the files it belongs to, or into new
    /// tabs for untitled documents and files that have gone. The files are
    /// read side by side, off the main thread.
    func restore(snapshots: [RecoveryStore.Snapshot]) async {
        let unopened = snapshots.indices.filter { snapshots[$0].url.map { !contains($0) } ?? false }
        let reads = await read(unopened.compactMap { snapshots[$0].url })
        var found: [Int: (text: String, format: FileFormat)] = [:]
        for (index, read) in zip(unopened, reads) { found[index] = read }

        for (index, snapshot) in snapshots.enumerated() {
            if let url = snapshot.url {
                if let open = document(at: url) {
                    let changed = snapshot.base.map { $0 != open.savedDigest } ?? false
                    open.restoreUnsavedText(snapshot.text)
                    if changed { recoveredOverChangedFile(open) }
                } else if let read = found[index] {
                    let opened = Document.open(url, read: read, theme: theme)
                    let changed = snapshot.base.map { $0 != opened.savedDigest } ?? false
                    opened.restoreUnsavedText(snapshot.text)
                    addReplacingPlaceholder(opened)
                    if changed { recoveredOverChangedFile(opened) }
                } else {
                    let missing = Document(url: url, theme: theme)
                    missing.restoreUnsavedText(snapshot.text)
                    missing.markMissingOnDisk()
                    addReplacingPlaceholder(missing)
                }
            } else {
                let untitled = Document(id: snapshot.id, theme: theme)
                untitled.restoreUnsavedText(snapshot.text)
                addReplacingPlaceholder(untitled)
            }
        }

        refreshTabs()
    }

    /// The file changed after the recovered edits were made (a sync, a
    /// pull): saving them as they are would undo that change unseen, so
    /// the choice is put as for any change on disk under unsaved edits.
    private func recoveredOverChangedFile(_ document: Document) {
        if let index = documents.firstIndex(where: { $0 === document }) { select(index: index) }
        askWhetherToReload(document)
    }

    private func restore(_ tab: Session.Tab, in editor: EditorViewController, of document: Document) {
        if let source = tab.sourceMode { editor.sourceMode = source }
        if let typewriter = tab.typewriterMode { editor.activeLine.typewriterMode = typewriter }
        if let focus = tab.focusMode { editor.activeLine.focusMode = focus }
        let range = NSRange(location: min(tab.selectedLocation, document.storage.length), length: 0)
        editor.textView.setSelectedRange(range)
        // Wait for layout so the scroll lands on the caret's real position.
        DispatchQueue.main.async { editor.textView.scrollRangeToVisible(range) }
    }

    // MARK: - Menu commands

    @objc func closeActiveTab(_ sender: Any?) {
        closeDocument(at: selection)
    }

    // Named to avoid `selectNextTab:`/`selectPreviousTab:`, which NSWindow
    // implements for native window tabbing and disables when a window has no
    // tab group — it sits earlier in the responder chain and would win.
    @objc func selectNextDocumentTab(_ sender: Any?) {
        guard !documents.isEmpty else { return }
        select(index: (selection + 1) % documents.count)
    }

    @objc func selectPreviousDocumentTab(_ sender: Any?) {
        guard !documents.isEmpty else { return }
        select(index: (selection - 1 + documents.count) % documents.count)
    }

    /// ⌘1…⌘8 pick a tab by position; ⌘9 (tag 9) is always the last tab.
    @objc func selectDocumentTab(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag, !documents.isEmpty else { return }
        let index = tag == 9 ? documents.count - 1 : tag - 1
        guard documents.indices.contains(index) else { return NSSound.beep() }
        select(index: index)
    }

    // MARK: - Format and export commands

    @objc func toggleBold(_ sender: Any?) { currentEditor?.toggleInline("**") }
    @objc func toggleItalic(_ sender: Any?) { currentEditor?.toggleInline("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { currentEditor?.toggleInline("~~") }
    @objc func toggleCode(_ sender: Any?) { currentEditor?.toggleInline("`") }
    @objc func insertLink(_ sender: Any?) { currentEditor?.insertLink() }
    @objc func insertCodeBlock(_ sender: Any?) { currentEditor?.insertCodeBlock() }
    @objc func toggleQuote(_ sender: Any?) { currentEditor?.toggleQuote() }
    @objc func toggleBulletList(_ sender: Any?) { currentEditor?.toggleList(ordered: false) }
    @objc func toggleNumberedList(_ sender: Any?) { currentEditor?.toggleList(ordered: true) }
    @objc func toggleTaskList(_ sender: Any?) { currentEditor?.toggleList(ordered: false, task: true) }

    @objc func insertTable(_ sender: Any?) { currentEditor?.table.insertTable() }
    @objc func tableRowAbove(_ sender: Any?) { currentEditor?.table.perform(.rowAbove) }
    @objc func tableRowBelow(_ sender: Any?) { currentEditor?.table.perform(.rowBelow) }
    @objc func tableDeleteRow(_ sender: Any?) { currentEditor?.table.perform(.deleteRow) }
    @objc func tableColumnBefore(_ sender: Any?) { currentEditor?.table.perform(.columnBefore) }
    @objc func tableColumnAfter(_ sender: Any?) { currentEditor?.table.perform(.columnAfter) }
    @objc func tableDeleteColumn(_ sender: Any?) { currentEditor?.table.perform(.deleteColumn) }
    @objc func tableFormat(_ sender: Any?) { currentEditor?.table.perform(.format) }

    @objc func tableAlign(_ sender: Any?) {
        let alignment: ColumnAlignment = switch (sender as? NSMenuItem)?.tag {
        case 1: .left
        case 2: .center
        case 3: .right
        default: .none
        }
        currentEditor?.table.perform(.align(alignment))
    }

    @objc func setHeadingLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 0
        currentEditor?.setHeading(level: level)
    }

    @objc func toggleSourceMode(_ sender: Any?) {
        guard let editor = currentEditor else { return }
        editor.sourceMode.toggle()
        onSessionChange?()
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        guard let editor = currentEditor else { return }
        editor.activeLine.typewriterMode.toggle()
        (sender as? NSMenuItem)?.state = editor.activeLine.typewriterMode ? .on : .off
        onSessionChange?()
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        guard let editor = currentEditor else { return }
        editor.activeLine.focusMode.toggle()
        (sender as? NSMenuItem)?.state = editor.activeLine.focusMode ? .on : .off
        onSessionChange?()
    }

    @objc func addNextOccurrence(_ sender: Any?) { currentEditor?.addNextOccurrence() }
    @objc func selectAllOccurrences(_ sender: Any?) { currentEditor?.selectAllOccurrences() }
    @objc func addCaretAbove(_ sender: Any?) { currentEditor?.addCaret(below: false) }
    @objc func addCaretBelow(_ sender: Any?) { currentEditor?.addCaret(below: true) }
    @objc func insertTableOfContents(_ sender: Any?) { currentEditor?.insertTableOfContents() }

    @objc func foldSection(_ sender: Any?) { currentEditor?.foldSection() }
    @objc func unfoldSection(_ sender: Any?) { currentEditor?.unfoldSection() }
    @objc func foldAllSections(_ sender: Any?) { currentEditor?.foldAll() }
    @objc func unfoldAllSections(_ sender: Any?) { currentEditor?.unfoldAll() }

    // MARK: - Zoom

    /// Zoom is app-wide, like the font size it multiplies.
    @objc func zoomIn(_ sender: Any?) { stepZoom(by: 1) }
    @objc func zoomOut(_ sender: Any?) { stepZoom(by: -1) }

    @objc func resetZoom(_ sender: Any?) {
        Settings().zoom = 1
        Settings.notifyChanged()
    }

    private func stepZoom(by direction: Int) {
        let settings = Settings()
        let steps = Settings.zoomSteps
        let current = settings.zoom
        let next = direction > 0
            ? steps.first { $0 > current + 0.001 }
            : steps.last { $0 < current - 0.001 }
        guard let next else { return NSSound.beep() }
        settings.zoom = next
        Settings.notifyChanged()
    }

    @objc func exportHTML(_ sender: Any?) {
        guard let document = activeDocument else { return }
        Exporter.exportHTML(document: document, in: window) { [weak self] error in self?.show(error: error) }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let document = activeDocument else { return }
        Exporter.exportPDF(document: document, in: window) { [weak self] error in self?.show(error: error) }
    }

    // MARK: - Versions

    private var versionBrowser: VersionBrowserController?

    @objc func browseVersions(_ sender: Any?) {
        guard window != nil, versionBrowser == nil, let document = activeDocument, let url = document.url else { return NSSound.beep() }
        // Asking macOS for its versions can take a while, for iCloud files most.
        let history = document.history
        Task { [weak self, weak document] in
            let versions = await Task.detached { history.allVersions(for: url) }.value
            guard let self, let document, versionBrowser == nil else { return }
            showVersions(versions, of: document)
        }
    }

    private func showVersions(_ versions: [VersionHistory.Version], of document: Document) {
        guard let window else { return }
        let browser = VersionBrowserController(versions: versions, title: document.displayName)
        browser.onFinish = { [weak self, weak document] text in
            self?.versionBrowser = nil
            guard let self, let document, let text else { return }
            replaceText(of: document, with: text, actionName: String(localized: "Restore Version"))
        }
        versionBrowser = browser
        if let sheet = browser.window { window.beginSheet(sheet) }
    }

    /// Puts back the file as it is on disk, as an edit that can be undone.
    /// Puts back the file's text as an undoable edit. The file is read off
    /// the main thread, like any other: one in iCloud or on a slow volume
    /// froze the app until it arrived.
    @objc func revertToSaved(_ sender: Any?) {
        guard let document = activeDocument, document.url != nil else { return NSSound.beep() }
        let readFile = readFile
        let id = nextReload
        nextReload += 1
        reloads[id] = Task { [weak self, weak document] in
            defer { self?.reloads[id] = nil }
            guard let document else { return }
            do {
                guard let contents = try await document.readFromDisk(using: readFile),
                      let self, documents.contains(where: { $0 === document }),
                      replaceText(of: document, with: contents.text, actionName: String(localized: "Revert to Saved"))
                else { return }
                document.adoptSaved(contents)
                refreshTabs()
                refreshStatus()
            } catch {
                self?.show(error: error)
            }
        }
    }

    @discardableResult
    private func replaceText(of document: Document, with text: String, actionName: String) -> Bool {
        let textView = editor(for: document).textView
        let all = NSRange(location: 0, length: document.storage.length)
        document.storage.unfoldAll()
        guard textView.replaceAsUndoStep(all, with: text, actionName: actionName) else { return false }
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        return true
    }

    @objc func exportWord(_ sender: Any?) { exportRich(.word) }
    @objc func exportRichText(_ sender: Any?) { exportRich(.richText) }
    @objc func exportPlainText(_ sender: Any?) { exportRich(.plainText) }

    private func exportRich(_ format: RichFormat) {
        guard let document = activeDocument else { return }
        Exporter.export(document: document, as: format, in: window) { [weak self] error in self?.show(error: error) }
    }

    @objc func exportWithPandoc(_ sender: Any?) {
        guard let document = activeDocument else { return }
        Exporter.exportWithPandoc(document: document, in: window) { [weak self] error in self?.show(error: error) }
    }

    /// Named apart from `print(_:)`, which the text view answers first by
    /// printing itself as it appears on screen.
    @objc func printDocument(_ sender: Any?) {
        guard let document = activeDocument else { return }
        Exporter.print(document: document, in: window)
    }

    /// The selection, or the whole document when nothing is selected.
    private func markdownToCopy() -> (markdown: String, baseURL: URL?)? {
        guard let document = activeDocument else { return nil }
        let selection = currentEditor?.textView.selectedRange() ?? NSRange(location: 0, length: 0)
        let text = selection.length > 0 ? (document.text as NSString).substring(with: selection) : document.text
        return (text, document.url)
    }

    @objc func copyAsHTML(_ sender: Any?) {
        guard let (markdown, baseURL) = markdownToCopy() else { return }
        Exporter.copyHTML(markdown: markdown, baseURL: baseURL)
    }

    @objc func copyAsRichText(_ sender: Any?) {
        guard let (markdown, baseURL) = markdownToCopy() else { return }
        Exporter.copyRichText(markdown: markdown, baseURL: baseURL)
    }

    private func show(error: Error) {
        showError(error)
    }
}

extension MainWindowController: NSMenuItemValidation {
    /// View modes belong to each tab, so their check marks follow the tab.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let editor = currentEditor
        switch item.action {
        case #selector(moveTabToNewWindow(_:)):
            return documents.count > 1
        case #selector(reopenClosedTab(_:)):
            return !closedTabURLs.isEmpty
        case #selector(exportWithPandoc(_:)):
            let installed = Pandoc.executable != nil
            item.title = installed ? String(localized: "With Pandoc…") : String(localized: "With Pandoc (not installed)")
            return installed
        case #selector(toggleOutline(_:)):
            item.title = isSidebarVisible && sidebar.pane == .outline ? String(localized: "Hide Outline") : String(localized: "Show Outline")
        case #selector(toggleFiles(_:)):
            item.title = isSidebarVisible && sidebar.pane == .files ? String(localized: "Hide Files") : String(localized: "Show Files")
        case #selector(toggleSidebarVisibility(_:)):
            item.title = isSidebarVisible ? String(localized: "Hide Sidebar") : String(localized: "Show Sidebar")
        case #selector(tableRowAbove(_:)), #selector(tableRowBelow(_:)), #selector(tableDeleteRow(_:)),
             #selector(tableColumnBefore(_:)), #selector(tableColumnAfter(_:)), #selector(tableDeleteColumn(_:)),
             #selector(tableAlign(_:)), #selector(tableFormat(_:)):
            return editor?.table.isInTable ?? false
        case #selector(toggleSourceMode(_:)):
            item.state = editor?.sourceMode == true ? .on : .off
        case #selector(toggleTypewriterMode(_:)):
            item.state = editor?.activeLine.typewriterMode == true ? .on : .off
        case #selector(toggleFocusMode(_:)):
            item.state = editor?.activeLine.focusMode == true ? .on : .off
        case #selector(browseVersions(_:)):
            return activeDocument?.url != nil
        case #selector(revertToSaved(_:)):
            return activeDocument?.url != nil && activeDocument?.isDirty == true
        case #selector(unfoldAllSections(_:)):
            return !(editor?.storage.foldedHeadings.isEmpty ?? true)
        case #selector(zoomIn(_:)):
            return Settings().zoom < Settings.zoomRange.upperBound - 0.001
        case #selector(zoomOut(_:)):
            return Settings().zoom > Settings.zoomRange.lowerBound + 0.001
        case #selector(resetZoom(_:)):
            return abs(Settings().zoom - 1) > 0.001
        default:
            break
        }
        return true
    }
}

private extension NSToolbarItem.Identifier {
    static let sidebar = Self("sidebar")
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebar] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.sidebar] }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        guard identifier == .sidebar else { return nil }
        // Not the system .toggleSidebar item, which AppKit builds itself and,
        // without a split view, puts at the trailing edge: the sidebar's button
        // belongs beside the traffic lights, ahead of the title.
        let item = NSToolbarItem(itemIdentifier: identifier)
        let label = String(localized: "Sidebar")
        item.label = label
        item.toolTip = String(localized: "Show or hide the sidebar")
        item.image = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: label)
        item.isBordered = true
        item.isNavigational = true
        // Not toggleSidebar(_:): NSWindow answers that itself, ahead of us in
        // the responder chain.
        item.target = self
        item.action = #selector(toggleSidebarVisibility(_:))
        return item
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        cancelPendingWork()
        pendingOutlineRefresh?.cancel()
        // Every unsaved document here was answered for, so none should come
        // back from a crash later.
        for document in documents { recovery.remove(id: document.id) }
        onClose?(self)
    }

    func windowDidMove(_ notification: Notification) { onSessionChange?() }
    func windowDidEndLiveResize(_ notification: Notification) { onSessionChange?() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard hasUnreviewedChanges else { return true }
        reviewUnsavedChanges { [weak self] proceed in
            if proceed { self?.window?.close() }
        }
        return false
    }
}

extension MainWindowController: TabBarViewDelegate {
    func tabBar(_ bar: TabBarView, didSelect index: Int) {
        select(index: index)
    }

    func tabBar(_ bar: TabBarView, didRequestClose index: Int) {
        closeDocument(at: index)
    }

    func tabBarDidRequestNewTab(_ bar: TabBarView) {
        newDocument()
    }

    func tabBar(_ bar: TabBarView, didDragOutTabAt index: Int) {
        moveToNewWindow(at: index)
    }

    func tabBar(_ bar: TabBarView, moveTabAt source: Int, to destination: Int) {
        guard documents.indices.contains(source), documents.indices.contains(destination) else { return }
        // Pressing a tab selects it, so the dragged tab is the selected one.
        documents.insert(documents.remove(at: source), at: destination)
        selection = destination
        refreshTabs()
    }
}
