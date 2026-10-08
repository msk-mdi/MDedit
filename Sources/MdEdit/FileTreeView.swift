import AppKit

/// The workspace folder as a tree of folders and markdown files.
final class FileTreeView: NSView {
    /// Asked to open a markdown file.
    var onOpenFile: ((URL) -> Void)?
    /// Asked to pick a folder, from the button shown when there is none.
    var onChooseFolder: (() -> Void)?

    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()
    private let emptyButton = NSButton(title: "Open Folder…", target: nil, action: nil)
    private var root: FileNode?
    private var theme: Theme = .light

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 22
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

    /// Re-reads the folders on disk, keeping expanded folders expanded.
    func reload() {
        guard let root else { return }
        let expanded = expandedURLs()
        let selected = (outline.item(atRow: outline.selectedRow) as? FileNode)?.url
        root.invalidate()
        outline.reloadData()
        restoreExpansion(expanded, under: root)
        if let selected { reveal(selected, expanding: false) }
    }

    /// Selects a file's row, expanding its folders when asked.
    func reveal(_ url: URL, expanding: Bool = true) {
        guard let root else { return }
        let target = url.standardizedFileURL.path
        guard target.hasPrefix(root.url.standardizedFileURL.path + "/") else {
            outline.deselectAll(nil)
            return
        }
        var node = root
        while true {
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
            outline.isItemExpanded(node) ? outline.collapseItem(node) : outline.expandItem(node)
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
        menu.addItem(withTitle: "New Markdown File", action: #selector(newFile), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Reveal in Finder", action: #selector(revealInFinder), keyEquivalent: "").target = self
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
            reload()
            reveal(target)
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
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root)!.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? FileNode)?.isDirectory ?? false
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

/// A folder or file in the tree. Folders list their children on first use.
final class FileNode: NSObject {
    let url: URL
    let isDirectory: Bool
    let path: String
    private var loadedChildren: [FileNode]?

    init(url: URL, isDirectory: Bool) {
        self.url = url
        self.isDirectory = isDirectory
        path = url.standardizedFileURL.path
    }

    /// Folders first, then markdown files, each in Finder order. Hidden and
    /// dependency folders are left out.
    var children: [FileNode] {
        if let loadedChildren { return loadedChildren }
        guard isDirectory else { return [] }
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let nodes = contents.compactMap { child -> FileNode? in
            let values = try? child.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = (values?.isDirectory ?? false) && !(values?.isPackage ?? false)
            if isFolder { return Workspace.skippedFolders.contains(child.lastPathComponent) ? nil : FileNode(url: child, isDirectory: true) }
            return Workspace.isMarkdown(child) ? FileNode(url: child, isDirectory: false) : nil
        }
        let sorted = nodes.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.url.lastPathComponent.localizedStandardCompare(rhs.url.lastPathComponent) == .orderedAscending
        }
        loadedChildren = sorted
        return sorted
    }

    /// Forgets loaded children everywhere below, so the next look re-reads disk.
    func invalidate() {
        loadedChildren?.forEach { $0.invalidate() }
        loadedChildren = nil
    }
}
