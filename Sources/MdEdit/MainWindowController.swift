import AppKit

/// The single window: a transparent titlebar carrying the glass tab strip, an
/// opaque canvas that scrolls beneath it, and a floating status pill.
@MainActor
final class MainWindowController: NSWindowController {
    private var documents: [Document] = []
    private var editors: [ObjectIdentifier: EditorViewController] = [:]
    private var selection = 0

    private let tabBar = TabBarView()
    private let statusBar = StatusBarView()
    private let canvas = NSView()
    /// Owns the editors as real child view controllers, so their lifecycle runs
    /// and the responder chain reaches this controller.
    private let contentController = NSViewController()
    private var currentEditor: EditorViewController?
    private var theme: Theme = .current(for: NSApp.effectiveAppearance)
    private var appearanceObservation: NSKeyValueObservation?

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
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: canvas.bottomAnchor),
        ])

        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.applyTheme(.current(for: app.effectiveAppearance))
            }
        }
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
        for editor in editors.values { editor.applyTheme(theme) }
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
        editor.onSelectionChange = { [weak self] in self?.refreshStatus() }
        editor.onTextChange = { [weak self] in
            self?.refreshTabs()
            self?.refreshStatus()
        }
        editors[ObjectIdentifier(document)] = editor
        select(index: documents.count - 1)
        refreshTabs()
    }

    /// Brings an already-open file forward instead of opening it twice.
    func focusDocument(at url: URL) -> Bool {
        guard let index = documents.firstIndex(where: { $0.url == url }) else { return false }
        select(index: index)
        return true
    }

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
    }

    private func install(_ editor: EditorViewController) {
        contentController.addChild(editor)
        editor.view.translatesAutoresizingMaskIntoConstraints = false
        canvas.addSubview(editor.view, positioned: .below, relativeTo: statusBar)
        NSLayoutConstraint.activate([
            editor.view.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            editor.view.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            editor.view.topAnchor.constraint(equalTo: canvas.topAnchor),
            editor.view.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
        ])
    }

    func closeDocument(at index: Int) {
        guard documents.indices.contains(index) else { return }
        let document = documents[index]

        let finish = { [weak self] in
            guard let self else { return }
            if let editor = editors.removeValue(forKey: ObjectIdentifier(document)) {
                if editor === currentEditor {
                    editor.view.removeFromSuperview()
                    editor.removeFromParent()
                    currentEditor = nil
                }
            }
            documents.remove(at: index)
            if documents.isEmpty {
                window?.close()
            } else {
                select(index: min(index, documents.count - 1))
            }
        }

        guard document.isDirty else {
            finish()
            return
        }
        confirmDiscard(document) { discard in
            if discard { finish() }
        }
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
        guard let document = activeDocument, let editor = currentEditor else { return }
        let counts = document.counts()
        let (line, column) = editor.caretPosition()
        statusBar.update(
            words: counts.words,
            characters: counts.characters,
            lines: editor.storage.structure.lineCount,
            line: line,
            column: column
        )
    }

    // MARK: - File commands

    func newDocument() {
        addDocument(Document(theme: theme))
    }

    func open(url: URL) {
        if focusDocument(at: url) { return }
        do {
            let document = try Document.open(contentsOf: url, theme: theme)
            // An untouched empty tab is replaced rather than left behind.
            if documents.count == 1, let only = documents.first, only.url == nil, !only.isDirty, only.text.isEmpty {
                closeDocument(at: 0)
            }
            addDocument(document)
        } catch {
            show(error: error)
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
            completion?(true)
        } catch {
            show(error: error)
            completion?(false)
        }
    }

    func saveAs(document: Document, completion: ((Bool) -> Void)? = nil) {
        guard let window else { return completion?(false) ?? () }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = document.url?.lastPathComponent ?? "Untitled.md"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return completion?(false) ?? () }
            do {
                try document.save(to: url)
                self?.window?.title = document.displayName
                self?.window?.representedURL = url
                self?.refreshTabs()
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

    @objc func setHeadingLevel(_ sender: Any?) {
        let level = (sender as? NSMenuItem)?.tag ?? 0
        currentEditor?.setHeading(level: level)
    }

    @objc func toggleTypewriterMode(_ sender: Any?) {
        guard let editor = currentEditor else { return }
        editor.activeLine.typewriterMode.toggle()
        (sender as? NSMenuItem)?.state = editor.activeLine.typewriterMode ? .on : .off
    }

    @objc func toggleFocusMode(_ sender: Any?) {
        guard let editor = currentEditor else { return }
        editor.activeLine.focusMode.toggle()
        (sender as? NSMenuItem)?.state = editor.activeLine.focusMode ? .on : .off
    }

    @objc func exportHTML(_ sender: Any?) {
        guard let document = activeDocument else { return }
        Exporter.exportHTML(document: document, theme: theme, in: window) { [weak self] error in
            self?.show(error: error)
        }
    }

    @objc func exportPDF(_ sender: Any?) {
        guard let document = activeDocument, let editor = currentEditor else { return }
        Exporter.exportPDF(from: editor, document: document, in: window) { [weak self] error in
            self?.show(error: error)
        }
    }

    @objc func copyAsHTML(_ sender: Any?) {
        guard let document = activeDocument else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Exporter.htmlFragment(for: document), forType: .string)
    }

    private func show(error: Error) {
        guard let window else { return }
        NSAlert(error: error).beginSheetModal(for: window)
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
}
