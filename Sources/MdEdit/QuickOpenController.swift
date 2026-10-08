import AppKit

/// ⌘P: a floating search over the workspace's files, open tabs and recent
/// documents. Type to narrow, arrows to choose, Return to open, Escape to close.
@MainActor
final class QuickOpenController: NSObject {
    var onOpen: ((URL) -> Void)?

    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var candidates: [Candidate] = []
    private var shown: [Candidate] = []
    private var loadTask: Task<Void, Never>?

    private struct Candidate {
        var url: URL
        /// What the query is matched against and shown under the name.
        var display: String
    }

    static let resultLimit = 50

    override init() {
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 340),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        buildContent()
    }

    private func buildContent() {
        let content = NSVisualEffectView()
        content.material = .popover
        content.state = .active

        field.placeholderString = "Open file…"
        field.font = .systemFont(ofSize: 16)
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("file"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.style = .inset
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(openSelection)
        table.action = #selector(openSelection)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(field)
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            field.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -6),
        ])
        panel.contentView = content
    }

    /// Shows the panel over a window, gathering candidates in the background.
    func show(over window: NSWindow?, workspace: Workspace?, openDocuments: [URL]) {
        let recent = NSDocumentController.shared.recentDocumentURLs
        var seen: Set<String> = []
        func display(_ url: URL) -> String {
            if let workspace, url.path.hasPrefix(workspace.root.path + "/") { return workspace.relativePath(of: url) }
            return (url.path as NSString).abbreviatingWithTildeInPath
        }
        candidates = (openDocuments + recent).compactMap { url in
            guard seen.insert(url.standardizedFileURL.path).inserted else { return nil }
            return Candidate(url: url, display: display(url))
        }
        field.stringValue = ""
        filter()

        loadTask?.cancel()
        if let workspace {
            let listed = seen
            loadTask = Task.detached(priority: .userInitiated) { [weak self] in
                let files = workspace.markdownFiles()
                    .filter { !listed.contains($0.standardizedFileURL.path) }
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self else { return }
                    self.candidates += files.map { Candidate(url: $0, display: workspace.relativePath(of: $0)) }
                    self.filter()
                }
            }
        }

        if let window {
            let frame = window.frame
            panel.setFrameTopLeftPoint(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - 90))
            window.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    func close() {
        loadTask?.cancel()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func filter() {
        let query = field.stringValue
        if query.isEmpty {
            shown = Array(candidates.prefix(Self.resultLimit))
        } else {
            shown = candidates
                .compactMap { candidate in FuzzyMatcher.score(query, in: candidate.display).map { (candidate, $0) } }
                .sorted { $0.1 > $1.1 }
                .prefix(Self.resultLimit)
                .map(\.0)
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    @objc private func openSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard shown.indices.contains(row) else { return }
        let url = shown[row].url
        close()
        onOpen?(url)
    }

    private func moveSelection(by delta: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(0, table.selectedRow + delta), shown.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }
}

extension QuickOpenController: NSSearchFieldDelegate, NSWindowDelegate {
    func controlTextDidChange(_ notification: Notification) {
        filter()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)): openSelection()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    /// Clicking back into the editor dismisses the panel.
    func windowDidResignKey(_ notification: Notification) {
        close()
    }
}

extension QuickOpenController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        shown.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let candidate = shown[row]
        let name = NSTextField(labelWithString: candidate.url.lastPathComponent)
        name.font = .systemFont(ofSize: 13, weight: .medium)
        let path = NSTextField(labelWithString: (candidate.display as NSString).deletingLastPathComponent)
        path.font = .systemFont(ofSize: 11)
        path.textColor = .secondaryLabelColor
        path.lineBreakMode = .byTruncatingMiddle
        let stack = NSStackView(views: [name, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
        return stack
    }
}
