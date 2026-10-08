import AppKit

/// Find in Folder: a search field over results grouped by file.
final class SearchPaneView: NSView {
    /// Asked to show a match: open the file and select the range on that line.
    var onOpenMatch: ((URL, WorkspaceSearch.Match) -> Void)?
    /// What to search: the workspace (enumerated in the background), open
    /// files outside it, and the unsaved text of open documents.
    var searchScope: (() -> (workspace: Workspace?, openFiles: [URL], overrides: [URL: String]))?

    let field = NSSearchField()
    private let scrollView = NSScrollView()
    private let outline = NSOutlineView()
    private let status = NSTextField(labelWithString: "")
    private var results: [FileGroup] = []
    private var theme: Theme = .light
    private var searchTask: Task<Void, Never>?
    private var workspace: Workspace?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        field.placeholderString = String(localized: "Find in folder")
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = false
        field.target = self
        field.action = #selector(search)
        field.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("result"))
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.backgroundColor = .clear
        outline.indentationPerLevel = 8
        outline.usesAutomaticRowHeights = true
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)

        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        status.font = .systemFont(ofSize: 11)
        status.translatesAutoresizingMaskIntoConstraints = false

        addSubview(field)
        addSubview(status)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            status.trailingAnchor.constraint(lessThanOrEqualTo: field.trailingAnchor),
            status.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: status.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        status.textColor = theme.secondaryText
        outline.reloadData()
    }

    /// Runs the field's query in the background, replacing any search in flight.
    @objc func search() {
        searchTask?.cancel()
        let query = field.stringValue
        guard !query.isEmpty, let scope = searchScope?() else {
            show([], query: query)
            return
        }
        workspace = scope.workspace
        status.stringValue = String(localized: "Searching…")
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            var files = scope.workspace?.markdownFiles() ?? []
            let known = Set(files.map(\.standardizedFileURL.path))
            files += scope.openFiles.filter { !known.contains($0.standardizedFileURL.path) }
            let found = WorkspaceSearch.search(query, in: files, overrides: scope.overrides) { Task.isCancelled }
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.show(found, query: query) }
        }
    }

    private func show(_ found: [WorkspaceSearch.FileResult], query: String) {
        results = found.map { FileGroup(result: $0) }
        let count = found.reduce(0) { $0 + $1.matches.count }
        let summary = count == 1 ? String(localized: "1 result in 1 file")
            : found.count == 1 ? String(localized: "\(count) results in 1 file")
            : String(localized: "\(count) results in \(found.count) files")
        status.stringValue = query.isEmpty ? "" : count == 0 ? String(localized: "No results")
            : summary
            + (count >= WorkspaceSearch.matchLimit ? String(localized: " (first \(WorkspaceSearch.matchLimit))") : "")
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
    }

    @objc private func rowClicked() {
        let item = outline.item(atRow: outline.clickedRow)
        if let match = item as? MatchItem {
            onOpenMatch?(match.url, match.match)
        } else if let group = item as? FileGroup {
            outline.isItemExpanded(group) ? outline.collapseItem(group) : outline.expandItem(group)
        }
    }

    // MARK: - Items

    private final class FileGroup: NSObject {
        let url: URL
        let matches: [MatchItem]
        init(result: WorkspaceSearch.FileResult) {
            url = result.url
            matches = result.matches.map { MatchItem(url: result.url, match: $0) }
        }
    }

    private final class MatchItem: NSObject {
        let url: URL
        let match: WorkspaceSearch.Match
        init(url: URL, match: WorkspaceSearch.Match) {
            self.url = url
            self.match = match
        }
    }
}

extension SearchPaneView: NSOutlineViewDataSource, NSOutlineViewDelegate {
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if let group = item as? FileGroup { return group.matches.count }
        return item == nil ? results.count : 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let group = item as? FileGroup { return group.matches[index] }
        return results[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is FileGroup
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let label = NSTextField(labelWithString: "")
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        if let group = item as? FileGroup {
            let name = group.url.lastPathComponent
            let folder = workspace.map { ($0.relativePath(of: group.url) as NSString).deletingLastPathComponent } ?? ""
            let text = NSMutableAttributedString(string: name, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: theme.text,
            ])
            if !folder.isEmpty {
                text.append(NSAttributedString(string: "  \(folder)", attributes: [
                    .font: NSFont.systemFont(ofSize: 11), .foregroundColor: theme.secondaryText,
                ]))
            }
            label.attributedStringValue = text
        } else if let item = item as? MatchItem {
            label.attributedStringValue = snippet(item.match)
            label.toolTip = item.match.lineText
        }
        let cell = NSTableCellView()
        cell.addSubview(label)
        cell.textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            label.topAnchor.constraint(equalTo: cell.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: cell.bottomAnchor, constant: -3),
        ])
        return cell
    }

    /// The line around the match, trimmed so the match is visible, match in bold.
    private func snippet(_ match: WorkspaceSearch.Match) -> NSAttributedString {
        let line = match.lineText as NSString
        let lead = max(0, match.range.location - 24)
        var start = lead
        // Skip leading whitespace so indented lines still show their match.
        while start < match.range.location, CharacterSet.whitespaces.contains(Unicode.Scalar(line.character(at: start)) ?? " ") { start += 1 }
        let shown = line.substring(from: start)
        let text = NSMutableAttributedString(string: (lead > 0 ? "…" : "") + shown, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: theme.secondaryText,
        ])
        let offset = (lead > 0 ? 1 : 0) + match.range.location - start
        text.addAttributes(
            [.foregroundColor: theme.text, .font: NSFont.systemFont(ofSize: 12, weight: .semibold)],
            range: NSRange(location: offset, length: match.range.length)
        )
        return text
    }
}
