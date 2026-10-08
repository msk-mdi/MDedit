import AppKit
import MarkdownKit

/// The document's headings as a sidebar pane: indented by level, the section
/// the caret is in highlighted, and a click jumps there.
final class OutlineView: NSView {
    /// Asked to move the caret to a heading's line.
    var onSelectHeading: ((Heading) -> Void)?

    private let scrollView = NSScrollView()
    private let table = NSTableView()
    private let emptyLabel = NSTextField(labelWithString: "No headings")
    private var headings: [Heading] = []
    private var theme: Theme = .light
    /// Set while the highlight follows the caret, so it is not taken as a click.
    private var isFollowingCaret = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: .init("heading"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.style = .sourceList
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)

        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        addSubview(scrollView)
        addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        emptyLabel.textColor = theme.secondaryText
        table.reloadData()
    }

    /// Replaces the list; skips the reload when nothing a reader sees changed.
    func setHeadings(_ newHeadings: [Heading]) {
        let changed = newHeadings.map { [$0.level, $0.title] as [AnyHashable] } != headings.map { [$0.level, $0.title] as [AnyHashable] }
        headings = newHeadings
        emptyLabel.isHidden = !headings.isEmpty
        if changed { table.reloadData() }
    }

    /// Highlights the section containing a line: the last heading at or above it.
    func highlightSection(containing line: Int) {
        let row = headings.lastIndex(where: { $0.line <= line }) ?? -1
        guard row != table.selectedRow else { return }
        isFollowingCaret = true
        if row >= 0 {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            table.scrollRowToVisible(row)
        } else {
            table.deselectAll(nil)
        }
        isFollowingCaret = false
    }

    @objc private func rowClicked() {
        let row = table.clickedRow
        guard headings.indices.contains(row) else { return }
        onSelectHeading?(headings[row])
    }
}

extension OutlineView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        headings.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("OutlineCell")
        let cell = tableView.makeView(withIdentifier: identifier, owner: nil) as? OutlineCell ?? OutlineCell()
        cell.identifier = identifier
        let heading = headings[row]
        cell.configure(title: heading.title.isEmpty ? "Untitled" : heading.title, level: heading.level, theme: theme)
        return cell
    }

    /// Keyboard selection moves the caret too; following the caret does not.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isFollowingCaret, NSApp.currentEvent?.type == .keyDown else { return }
        let row = table.selectedRow
        guard headings.indices.contains(row) else { return }
        onSelectHeading?(headings[row])
    }
}

private final class OutlineCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!

    init() {
        super.init(frame: .zero)
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        textField = label
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, level: Int, theme: Theme) {
        label.stringValue = title
        label.toolTip = title
        label.font = level == 1 ? .systemFont(ofSize: 13, weight: .semibold) : .systemFont(ofSize: 12.5)
        label.textColor = level <= 2 ? theme.text : theme.secondaryText
        leading.constant = 6 + CGFloat(max(0, level - 1)) * 12
    }
}
