import AppKit

/// ⌘P: a floating search over the workspace's files, open tabs and recent
/// documents. Type to narrow, arrows to choose, Return to open, Escape to close.
@MainActor
final class QuickOpenController: NSObject {
    var onOpen: ((URL) -> Void)?

    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var candidates: [Candidate] = [] {
        didSet { lastFilter = nil }
    }
    private var shown: [Candidate] = []
    private var loadTask: Task<Void, Never>?
    /// The workspace's files, shared with Find in Folder.
    var fileList = WorkspaceFileList()
    /// Counts showings, so a load left over from an earlier one is ignored.
    private var loadGeneration = 0
    /// The last query and which candidates it matched: a query that only
    /// adds letters can match nothing outside them.
    private var lastFilter: (needle: [Character], matches: [Int])?

    private struct Candidate: Sendable {
        var url: URL
        /// What the query is matched against and shown under the name.
        var display: String
        let prepared: FuzzyMatcher.Prepared?

        init(url: URL, display: String) {
            self.url = url
            self.display = display
            prepared = FuzzyMatcher.Prepared(display)
        }
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

        field.placeholderString = String(localized: "Open file…")
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
        loadGeneration += 1
        if let workspace {
            let listed = seen
            let generation = loadGeneration
            let fileList = fileList
            loadTask = Task { [weak self] in
                let files = await fileList.files(of: workspace)
                guard !Task.isCancelled else { return }
                // Preparing thousands of names for matching is done away
                // from the main thread too.
                let found = await Task.detached(priority: .userInitiated) {
                    files.filter { !listed.contains($0.standardizedFileURL.path) }
                        .map { Candidate(url: $0, display: workspace.relativePath(of: $0)) }
                }.value
                // A load from an earlier showing, finishing after this
                // one began, would add its files a second time.
                guard !Task.isCancelled, let self, self.loadGeneration == generation else { return }
                self.candidates += found
                self.filter()
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
        let needle = FuzzyMatcher.needle(field.stringValue)
        if needle.isEmpty {
            lastFilter = nil
            shown = Array(candidates.prefix(Self.resultLimit))
        } else {
            let pool = lastFilter.flatMap { last in needle.starts(with: last.needle) ? last.matches : nil }
                ?? Array(candidates.indices)
            var scored: [(index: Int, score: Int)] = []
            for index in pool {
                guard let prepared = candidates[index].prepared,
                      let score = FuzzyMatcher.score(needle, in: prepared) else { continue }
                scored.append((index, score))
            }
            lastFilter = (needle, scored.map(\.index).sorted())
            // Equal scores keep the candidates' order, as before.
            shown = scored
                .sorted { $0.score != $1.score ? $0.score > $1.score : $0.index < $1.index }
                .prefix(Self.resultLimit)
                .map { candidates[$0.index] }
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
