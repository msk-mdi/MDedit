import AppKit

/// The workspace folder as a tree of folders and markdown files.
final class FileTreeView: NSView {
    /// Asked to open a markdown file.
    var onOpenFile: ((URL) -> Void)?
    /// Asked to pick a folder, from the button shown when there is none.
    var onChooseFolder: (() -> Void)?

    private let scrollView = NSScrollView()
    let outline = NSOutlineView()
    private let emptyButton = NSButton(title: String(localized: "Open Folder…"), target: nil, action: nil)
    private var root: FileNode?
    private var theme: Theme = .light
    /// Set when the folders changed while the tree was out of sight.
    private var needsReload = false
    /// Lists a folder's markdown files and subfolders. Called off the main
    /// thread, as a folder on a slow or remote volume can take a while.
    var listFolder: @Sendable (URL) -> [FileNode.Entry] = FileNode.list
    /// Listings under way, by when they started.
    private var listings: [Int: Task<Void, Never>] = [:]
    private var nextListing = 0
    /// The file a reveal is waiting to show, once its folders are listed.
    private var pendingReveal: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 26
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.menu = contextMenu()

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyButton.bezelStyle = .push
        emptyButton.target = self
        emptyButton.action = #selector(chooseFolder)
        emptyButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(emptyButton)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyButton.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setRoot(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        outline.reloadData()
    }

    func setRoot(_ url: URL?) {
        root = url.map { FileNode(url: $0, isDirectory: true) }
        emptyButton.isHidden = url != nil
        scrollView.isHidden = url == nil
        outline.reloadData()
    }

    /// Re-reads every folder listed so far, keeping expanded folders expanded.
    @discardableResult
    func reload() -> Task<Void, Never>? {
        guard let root else { return nil }
        needsReload = false
        return list(root.listedFolders) { [weak self] found in
            self?.keepingExpansion {
                for (node, entries) in found { node.takeChildren(entries) }
                self?.outline.reloadData()
            }
        }
    }

    /// Lists folders off the main thread, then hands back the listings still
    /// current: a folder listed again meanwhile keeps only the newer one.
    @discardableResult
    private func list(
        _ nodes: [FileNode],
        then show: @escaping ([(node: FileNode, entries: [FileNode.Entry])]) -> Void
    ) -> Task<Void, Never> {
        let tickets = nodes.map { $0.beginListing() }
        let urls = nodes.map(\.url)
        let listFolder = listFolder
        let id = nextListing
        nextListing += 1
        let task = Task { [weak self] in
            let listings = await Task.detached(priority: .userInitiated) { urls.map(listFolder) }.value
            self?.listings[id] = nil
            let current = zip(nodes, zip(tickets, listings)).compactMap { node, listing in
                node.endListing(listing.0) ? (node: node, entries: listing.1) : nil
            }
            if !current.isEmpty { show(current) }
        }
        listings[id] = task
        return task
    }

    /// Lists a folder the first time it is looked into.
    private func load(_ node: FileNode) {
        guard node.isDirectory, node.listedChildren == nil, !node.isListing else { return }
        list([node]) { [weak self] found in self?.takeIn(found) }
    }

    /// Takes in listings and shows what the folders now hold.
    private func takeIn(_ found: [(node: FileNode, entries: [FileNode.Entry])]) {
        for (node, entries) in found {
            node.takeChildren(entries)
            outline.reloadItem(node === root ? nil : node, reloadChildren: true)
        }
    }

    /// Waits until every folder being listed has been taken in, including
    /// any listed in turn as expanded folders are opened again.
    func finishListing() async {
        while let listing = listings.values.first { await listing.value }
    }

    /// Follows changes on disk. Only folders the tree has listed are read
    /// again; changes in hidden and dependency folders, which a build, a
    /// checkout or an install make by the thousand, are not in the tree at
    /// all. Out of sight, the tree only notes that it is stale.
    func folderContentsChanged(_ change: DirectoryWatcher.Change) {
        guard let root else { return }
        guard window != nil, !isHiddenOrHasHiddenAncestor else {
            needsReload = true
            return
        }
        guard case let .folders(paths, _) = change else {
            reload()
            return
        }
        // The root's real path is found once, not once a folder: a build or
        // an install in the folder reports thousands at a time.
        let bases = [realPath(root.path), root.path]
        let nodes = Set(paths).compactMap { listedNode(atReportedPath: $0, under: root, bases: bases) }
        guard !nodes.isEmpty else { return }
        list(nodes) { [weak self] found in
            guard let self else { return }
            keepingExpansion { self.takeIn(found) }
        }
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        if needsReload { reload() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if needsReload, window != nil, !isHiddenOrHasHiddenAncestor { reload() }
    }

    /// The listed folder a path from FSEvents names, if the tree shows it.
    private func listedNode(atReportedPath reported: String, under root: FileNode, bases: [String]) -> FileNode? {
        var path = reported
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        // FSEvents reports paths with symlinks resolved: /private/tmp, not /tmp.
        let relative = bases.lazy.compactMap { base -> Substring? in
            if path == base { return "" }
            return path.hasPrefix(base + "/") ? path.dropFirst(base.count + 1) : nil
        }.first
        guard let relative else { return nil }
        var node = root
        for name in relative.split(separator: "/") {
            guard !name.hasPrefix("."), !Workspace.skippedFolders.contains(String(name)),
                  let child = node.listedChildren?.first(where: { $0.isDirectory && $0.url.lastPathComponent == name })
            else { return nil }
            node = child
        }
        return node.listedChildren == nil ? nil : node
    }

    /// Runs a reload, then expands what was expanded and selects what was selected.
    private func keepingExpansion(_ reload: () -> Void) {
        guard let root else { return }
        let expanded = expandedURLs()
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        reload()
        restoreExpansion(expanded, under: root)
        if let selected { reveal(selected, expanding: false) }
    }

    /// Selects a file's row, expanding its folders when asked. Folders not
    /// listed yet are listed first, and the reveal carries on once they are.
    func reveal(_ url: URL, expanding: Bool = true) {
        if expanding { pendingReveal = nil }
        guard let root else { return }
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(root.url.standardizedFileURL.path + "/") else {
            outline.deselectAll(nil)
            return
        }
        var node = root
        while true {
            if node.listedChildren == nil, expanding {
                pendingReveal = url
                list([node]) { [weak self] found in
                    guard let self else { return }
                    takeIn(found)
                    // Unless another reveal came since.
                    if pendingReveal == url { reveal(url) }
                }
                return
            }
            guard let next = node.children.first(where: { target == $0.path || target.hasPrefix($0.path + "/") }) else { break }
            if next.path == target {
                let row = outline.row(forItem: next)
                if row >= 0 {
                    outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    outline.scrollRowToVisible(row)
                }
                return
            }
            guard expanding || outline.isItemExpanded(next) else { return }
            outline.expandItem(next)
            node = next
        }
    }

    private func expandedURLs() -> Set<String> {
        var paths: Set<String> = []
        for row in 0..<outline.numberOfRows {
            if let node = outline.item(atRow: row) as? FileNode, outline.isItemExpanded(node) { paths.insert(node.path) }
        }
        return paths
    }

    private func restoreExpansion(_ paths: Set<String>, under node: FileNode) {
        for child in node.children where child.isDirectory && paths.contains(child.path) {
            outline.expandItem(child)
            restoreExpansion(paths, under: child)
        }
    }

    @objc private func rowClicked() {
        guard let node = outline.item(atRow: outline.clickedRow) as? FileNode else { return }
        if node.isDirectory {
            // Through the animator, so a click on the name slides the rows
            // open or shut as a click on the disclosure triangle does.
            let tree = Motion.isEnabled ? outline.animator() : outline
            outline.isItemExpanded(node) ? tree.collapseItem(node) : tree.expandItem(node)
        } else {
            onOpenFile?(node.url)
        }
    }

    @objc private func chooseFolder() {
        onChooseFolder?()
    }

    // MARK: - Context menu

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "New Markdown File"), action: #selector(newFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Reveal in Finder"), action: #selector(revealInFinder), keyEquivalent: "").target = self
        return menu
    }

    /// The node a context menu is about: the clicked row, or the root.
    private var contextNode: FileNode? {
        (outline.item(atRow: outline.clickedRow) as? FileNode) ?? root
    }

    @objc private func newFile() {
        guard let node = contextNode else { return }
        let folder = node.isDirectory ? node.url : node.url.deletingLastPathComponent()
        var target = folder.appendingPathComponent("Untitled.md")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("Untitled \(counter).md")
            counter += 1
        }
        do {
            try Data().write(to: target, options: .withoutOverwriting)
            let reloading = reload()
            Task { [weak self] in
                await reloading?.value
                self?.reveal(target)
            }
            onOpenFile?(target)
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }

    @objc private func revealInFinder() {
        guard let node = contextNode else { return }
        NSWorkspace.shared.activateFileViewerSelecting([node.url])
    }
}

extension FileTreeView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    /// A folder not listed yet shows nothing until its listing comes in.
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = (item as? FileNode) ?? root else { return 0 }
        guard let children = node.listedChildren else {
            load(node)
            return 0
        }
        return children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        let row = SidebarRowView()
        row.theme = theme
        return row
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? FileNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("FileCell")
        let cell = outlineView.makeView(withIdentifier: identifier, owner: nil) as? NSTableCellView ?? makeCell(identifier)
        cell.textField?.stringValue = node.isDirectory ? node.url.lastPathComponent : node.url.deletingPathExtension().lastPathComponent
        cell.textField?.textColor = node.isDirectory ? theme.secondaryText : theme.text
        cell.textField?.toolTip = node.url.lastPathComponent
        cell.imageView?.image = NSImage(
            systemSymbolName: node.isDirectory ? "folder" : "doc.text",
            accessibilityDescription: nil
        )
        cell.imageView?.contentTintColor = theme.secondaryText
        return cell
    }

    private func makeCell(_ identifier: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = identifier
        let icon = NSImageView()
        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5)
        label.lineBreakMode = .byTruncatingMiddle
        for view in [icon, label] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
        }
        cell.imageView = icon
        cell.textField = label
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

/// A path with every symlink resolved, as FSEvents reports it. Unlike
/// `URL.resolvingSymlinksInPath()`, which drops a leading `/private`.
func realPath(_ path: String) -> String {
    guard let resolved = realpath(path, nil) else { return path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// A folder or file in the tree. Folders are listed on first use, by the tree.
@MainActor
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    let path: String
    private var loadedChildren: [FileNode]?
    /// Counts listings asked for, so only the latest one is taken in.
    private var listingTicket = 0
    private(set) var isListing = false

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        path = url.standardizedFileURL.path
    }

    /// What listing a folder finds, made off the main thread.
    struct Entry: Sendable {
        let url: URL
        let isDirectory: Bool
    }

    /// Folders first, then markdown files, each in Finder order. Hidden and
    /// dependency folders are left out.
    nonisolated static func list(_ url: URL) -> [Entry] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let entries = contents.compactMap { child -> Entry? in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if isFolder { return Workspace.skippedFolders.contains(child.lastPathComponent) ? nil : Entry(url: child, isDirectory: true) }
            return Workspace.isMarkdown(child) ? Entry(url: child, isDirectory: false) : nil
        }
        return entries.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
    }

    /// The children as last listed; none before the first listing.
    var children: [FileNode] { loadedChildren ?? [] }

    /// The children, if this folder has been listed.
    var listedChildren: [FileNode]? { loadedChildren }

    /// This folder and every folder listed below it, each before those inside it.
    var listedFolders: [FileNode] {
        guard isDirectory else { return [] }
        return [self] + children.flatMap(\.listedFolders).filter { $0.listedChildren != nil }
    }

    func beginListing() -> Int {
        listingTicket += 1
        isListing = true
        return listingTicket
    }

    /// Whether a listing is the latest asked for, and so to be taken in.
    func endListing(_ ticket: Int) -> Bool {
        guard ticket == listingTicket else { return false }
        isListing = false
        return true
    }

    /// Takes in a listing, keeping the nodes of children still there, so
    /// what was listed below them stays listed.
    func takeChildren(_ entries: [Entry]) {
        let kept = Dictionary((loadedChildren ?? []).map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        loadedChildren = entries.map { entry in
            let fresh = FileNode(url: entry.url, isDirectory: entry.isDirectory)
            return kept[fresh.path].flatMap { $0.isDirectory == fresh.isDirectory ? $0 : nil } ?? fresh
        }
    }
}
