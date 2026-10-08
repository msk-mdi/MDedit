import AppKit
import MarkdownKit

/// The single window: a transparent titlebar carrying the glass tab strip, an
/// opaque canvas below it, and a floating status pill.
@MainActor
final class MainWindowController: NSWindowController {
    private var documents: [Document] = []
    private var editors: [ObjectIdentifier: EditorViewController] = [:]
    private var selection = 0

    private let tabBar = TabBarView()
    private let statusBar = StatusBarView()
    private let sidebar = SidebarView()
    /// Pins the current editor's leading edge to the window or the sidebar.
    private var editorLeading: NSLayoutConstraint?
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
    private var currentEditor: EditorViewController?
    private var theme: Theme = .current(for: NSApp.effectiveAppearance)
    private var appearanceObservation: NSKeyValueObservation?

    private let recovery = RecoveryStore.standard

    // Hooks to the app, which owns every window.
    /// Something worth recording in the session changed.
    var onSessionChange: (() -> Void)?
    /// The window closed for good.
    var onClose: ((MainWindowController) -> Void)?
    /// Brings a file forward if another window has it open.
    var focusElsewhere: ((URL) -> Bool)?
    /// Asked to give a document a window of its own.
    var onMoveToNewWindow: ((Document) -> Void)?
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

        // An empty unified toolbar puts the document title at the leading edge,
        // beside the traffic lights, and gives the tab strip a row of its own.
        let toolbar = NSToolbar(identifier: "MdEditToolbar")
        toolbar.showsBaselineSeparator = false
        toolbar.displayMode = .iconOnly
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

            sidebar.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
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

    func addDocument(_ document: Document) {
        document.onExternalChange = { [weak self, weak document] in
            guard let self, let document else { return }
            handleExternalChange(of: document)
        }
        documents.append(document)
        let editor = EditorViewController(textStorage: document.storage)
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
        select(index: documents.count - 1)
        refreshTabs()
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
        guard let editor = editors[ObjectIdentifier(document)] else { return }

        if currentEditor !== editor {
            currentEditor?.view.removeFromSuperview()
            currentEditor?.removeFromParent()
            install(editor)
            currentEditor = editor
        }
        window?.makeFirstResponder(editor.textView)
        window?.title = document.displayName
        window?.representedURL = document.url
        refreshTabs()
        refreshStatus()
        refreshSidebar()
    }

    private func install(_ editor: EditorViewController) {
        contentController.addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(editor.view, positioned: .below, relativeTo: statusBar)
        let leading = editor.view.leadingAnchor.constraint(
            equalTo: isSidebarVisible ? sidebar.trailingAnchor : canvas.leadingAnchor
        )
        editorLeading = leading
        NSLayoutConstraint.activate([
            leading,
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
            return
        }
        confirmDiscard(document) { [weak self] discard in
            guard discard, let self else { return }
            remove(document)
            recovery.remove(id: document.id)
        }
    }

    /// Takes a document out of this window without asking about changes;
    /// the window closes once it has nothing left.
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
        documents.remove(at: index)
        if documents.isEmpty {
            window?.close()
        } else {
            select(index: min(index, documents.count - 1))
        }
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
        guard let window else { return completion(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to “\(document.displayName)” before closing?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        alert.beginSheetModal(for: window) { [weak self] response in
            switch response {
            case .alertFirstButtonReturn:
                self?.save(document: document) { saved in completion(saved) }
            case .alertThirdButtonReturn:
                completion(true)
            default:
                completion(false)
            }
        }
    }

    func refreshTabs() {
        tabBar.setTabs(
            documents.map { TabDescriptor(title: $0.displayName, isDirty: $0.isDirty) },
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
        if !document.hasCurrentStatistics, let latest = document.latestStatistics {
            statistics = latest
            scheduleStatisticsRefresh()
        } else {
            statistics = document.statistics()
        }
        let selection = selectionStatistics()
        let (line, column) = editor.caretPosition()
        statusBar.update(statistics: statistics, selection: selection, goal: document.wordGoal, line: line, column: column)
        if statisticsPopover.isShown {
            statisticsController.show(selection ?? statistics, isSelection: selection != nil, goal: document.wordGoal)
        }
    }

    private func scheduleStatisticsRefresh() {
        pendingStatisticsRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let document = activeDocument else { return }
            _ = document.statistics()
            updateStatus()
        }
        pendingStatisticsRefresh = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    /// Counts for the selected text, if any.
    private func selectionStatistics() -> TextStatistics? {
        guard let editor = currentEditor else { return nil }
        let ranges = editor.textView.selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        guard !ranges.isEmpty else { return nil }
        let text = editor.storage.string as NSString
        return TextStatistics(ranges.map { text.substring(with: $0) }.joined(separator: "\n"))
    }

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

    func open(url: URL) {
        if focusDocument(at: url) { return }
        if focusElsewhere?(url) == true { return }
        do {
            addReplacingPlaceholder(try Document.open(contentsOf: url, theme: theme))
        } catch {
            show(error: error)
        }
    }

    /// Adds a document; an untouched empty tab is replaced rather than left behind.
    private func addReplacingPlaceholder(_ document: Document) {
        addDocument(document)
        if let index = documents.firstIndex(where: { $0 !== document && $0.url == nil && !$0.isDirty && $0.text.isEmpty }) {
            closeDocument(at: index)
            if let added = documents.firstIndex(where: { $0 === document }) { select(index: added) }
        }
    }

    func save(document: Document, completion: ((Bool) -> Void)? = nil) {
        if document.url == nil {
            saveAs(document: document, completion: completion)
            return
        }
        do {
            try document.save()
            refreshTabs()
            writeRecoverySnapshots()
            completion?(true)
        } catch {
            show(error: error)
            completion?(false)
        }
    }

    func saveAs(document: Document, completion: ((Bool) -> Void)? = nil) {
        guard let window else { return completion?(false) ?? () }
        let panel = NSSavePanel()
        // The first type supplies the default extension.
        panel.allowedContentTypes = ["md", "markdown", "mdown", "mkd", "txt"]
            .compactMap { .init(filenameExtension: $0) }
        panel.allowsOtherFileTypes = true
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "Untitled.md"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return completion?(false) ?? () }
            do {
                try document.save(to: url)
                self?.window?.title = document.displayName
                self?.window?.representedURL = url
                self?.refreshTabs()
                self?.writeRecoverySnapshots()
                completion?(true)
            } catch {
                self?.show(error: error)
                completion?(false)
            }
        }
    }

    /// A file changed on disk: reload quietly when there is nothing to lose,
    /// ask when there is.
    private func handleExternalChange(of document: Document) {
        guard let window, documents.contains(where: { $0 === document }) else { return }
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
        guard document.isDirty else {
            try? document.revert()
            refreshTabs()
            refreshStatus()
            return
        }

        let alert = NSAlert()
        alert.messageText = "“\(document.displayName)” changed on disk."
        alert.informativeText = "You have unsaved changes here. Reloading discards them."
        alert.addButton(withTitle: "Keep My Changes")
        alert.addButton(withTitle: "Reload")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn else { return }
            try? document.revert()
            self?.refreshTabs()
            self?.refreshStatus()
        }
    }

    // MARK: - Links

    /// Follows a link: web addresses go to the browser, `#anchors` jump to a
    /// heading, markdown files open in a tab, anything else in its own app.
    func openLink(_ destination: String, from document: Document) {
        if destination.hasPrefix("#") {
            jumpToHeading(slug: String(destination.dropFirst()), in: document)
            return
        }
        if let url = URL(string: destination), let scheme = url.scheme, scheme != "file" {
            NSWorkspace.shared.open(url)
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
        } else {
            NSWorkspace.shared.open(target)
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
        let text = document.storage.string as NSString
        let wanted = (slug.removingPercentEncoding ?? slug).lowercased()
        guard let heading = document.storage.structure.headings(in: text).first(where: { $0.slug == wanted }) else {
            NSSound.beep()
            return
        }
        moveCaret(toLine: heading.line, in: document)
    }

    /// Puts the caret at the start of a line and brings it into view.
    private func moveCaret(toLine line: Int, in document: Document) {
        guard let editor = editors[ObjectIdentifier(document)], line < document.storage.structure.lineCount else { return }
        let range = NSRange(location: document.storage.structure.index.range(ofLine: line).location, length: 0)
        editor.textView.setSelectedRange(range)
        editor.textView.scrollRangeToVisible(range)
        window?.makeFirstResponder(editor.textView)
    }

    // MARK: - Sidebar

    @objc func toggleFiles(_ sender: Any?) { toggleSidebar(showing: .files) }
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
        sidebar.isHidden = !visible
        if let editor = currentEditor {
            editorLeading?.isActive = false
            editorLeading = editor.view.leadingAnchor.constraint(
                equalTo: visible ? sidebar.trailingAnchor : canvas.leadingAnchor
            )
            editorLeading?.isActive = true
        }
        refreshSidebar()
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
        panel.prompt = "Open Folder"
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
        sidebar.files.setRoot(newWorkspace?.root)
        window?.subtitle = newWorkspace?.root.lastPathComponent ?? ""
        directoryWatcher = newWorkspace.flatMap { workspace in
            DirectoryWatcher(url: workspace.root) { [weak self] in self?.sidebar.files.reload() }
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
            let selected = (editor.storage.string as NSString).substring(with: editor.textView.selectedRange())
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
        open(url: url)
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

    private func scheduleRecoverySnapshot() {
        pendingSnapshot?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.writeRecoverySnapshots() }
        pendingSnapshot = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes a snapshot for every unsaved document and drops the rest, then
    /// records the open tabs so a crash can be recovered from too.
    func writeRecoverySnapshots() {
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
        for document in documents {
            if document.isDirty {
                try? recovery.write(.init(id: document.id, url: document.url, text: document.text))
            } else {
                recovery.remove(id: document.id)
            }
        }
        onSessionChange?()
    }

    /// Stops pending snapshot writes, for a clean quit.
    func cancelPendingWork() {
        pendingSnapshot?.cancel()
        pendingSnapshot = nil
    }

    /// Whether this window has a file or unsaved snapshot for a URL.
    func contains(_ url: URL) -> Bool {
        documents.contains { $0.url?.standardizedFileURL.path == url.standardizedFileURL.path }
    }

    /// This window's tabs, folder and position, for the session.
    func windowSession() -> Session.Window {
        var tabs: [Session.Tab] = []
        var selectedIndex = 0
        for (index, document) in documents.enumerated() {
            guard let url = document.url else { continue }
            if index == selection { selectedIndex = tabs.count }
            let editor = editors[ObjectIdentifier(document)]
            tabs.append(.init(
                url: url,
                selectedLocation: editor?.textView.selectedRange().location ?? 0,
                sourceMode: editor?.sourceMode,
                typewriterMode: editor?.activeLine.typewriterMode,
                focusMode: editor?.activeLine.focusMode
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
    /// that have gone, and its folder and position.
    func restore(_ saved: Session.Window) {
        if let frame = saved.frame { window?.setFrame(from: frame) }
        if let root = saved.workspace, FileManager.default.fileExists(atPath: root.path) {
            setWorkspace(Workspace(root: root))
        }
        var selected: Document?
        for (index, tab) in saved.tabs.enumerated() {
            let document = documents.first(where: { $0.url == tab.url })
                ?? (try? Document.open(contentsOf: tab.url, theme: theme)).map { opened in
                    addReplacingPlaceholder(opened)
                    return opened
                }
            guard let document else { continue }
            if index == saved.selectedIndex { selected = document }
            restoreCaret(of: document, to: tab.selectedLocation)
            if let editor = editors[ObjectIdentifier(document)] {
                if let source = tab.sourceMode { editor.sourceMode = source }
                if let typewriter = tab.typewriterMode { editor.activeLine.typewriterMode = typewriter }
                if let focus = tab.focusMode { editor.activeLine.focusMode = focus }
            }
        }
        if let selected, let index = documents.firstIndex(where: { $0 === selected }) {
            select(index: index)
        }
        refreshTabs()
    }

    /// Lays recovered unsaved text over the files it belongs to, or into new
    /// tabs for untitled documents and files that have gone.
    func restore(snapshots: [RecoveryStore.Snapshot]) {
        for snapshot in snapshots {
            if let url = snapshot.url {
                if let open = documents.first(where: { $0.url == url }) {
                    open.restoreUnsavedText(snapshot.text)
                } else if let opened = try? Document.open(contentsOf: url, theme: theme) {
                    opened.restoreUnsavedText(snapshot.text)
                    addReplacingPlaceholder(opened)
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

    private func restoreCaret(of document: Document, to location: Int) {
        guard let editor = editors[ObjectIdentifier(document)] else { return }
        let range = NSRange(location: min(location, document.storage.length), length: 0)
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
        guard let window, let document = activeDocument, let url = document.url else { return NSSound.beep() }
        let browser = VersionBrowserController(versions: document.history.allVersions(for: url), title: document.displayName)
        browser.onFinish = { [weak self, weak document] text in
            self?.versionBrowser = nil
            guard let self, let document, let text else { return }
            replaceText(of: document, with: text, actionName: "Restore Version")
        }
        versionBrowser = browser
        if let sheet = browser.window { window.beginSheet(sheet) }
    }

    /// Puts back the file as it is on disk, as an edit that can be undone.
    @objc func revertToSaved(_ sender: Any?) {
        guard let document = activeDocument, let url = document.url else { return NSSound.beep() }
        do {
            let text = try FileFormat.decode(Data(contentsOf: url)).text
            replaceText(of: document, with: text, actionName: "Revert to Saved")
        } catch {
            show(error: error)
        }
    }

    private func replaceText(of document: Document, with text: String, actionName: String) {
        guard let editor = editors[ObjectIdentifier(document)] else { return }
        let textView = editor.textView
        let all = NSRange(location: 0, length: document.storage.length)
        document.storage.unfoldAll()
        guard textView.shouldChangeText(in: all, replacementString: text) else { return }
        textView.insertText(text, replacementRange: all)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        textView.undoManager?.setActionName(actionName)
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
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
    }
}

extension MainWindowController: NSMenuItemValidation {
    /// View modes belong to each tab, so their check marks follow the tab.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let editor = currentEditor
        switch item.action {
        case #selector(moveTabToNewWindow(_:)):
            return documents.count > 1
        case #selector(exportWithPandoc(_:)):
            let installed = Pandoc.executable != nil
            item.title = installed ? "With Pandoc…" : "With Pandoc (not installed)"
            return installed
        case #selector(toggleOutline(_:)):
            item.title = isSidebarVisible && sidebar.pane == .outline ? "Hide Outline" : "Show Outline"
        case #selector(toggleFiles(_:)):
            item.title = isSidebarVisible && sidebar.pane == .files ? "Hide Files" : "Show Files"
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
