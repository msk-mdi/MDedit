import AppKit
import CryptoKit

/// Copies of each file as it was opened and saved, so an earlier state can
/// be brought back.
///
/// Each file gets a folder in `~/Library/Application Support/MdEdit/History`
/// named from a hash of its path, holding one `.md` per version and a note of
/// the path. Saving the same text twice keeps one copy; the oldest go first
/// past `limit`, and `prune` keeps the whole history to a size and an age.
struct VersionHistory {
    struct Version: Equatable {
        var date: Date
        /// Where the version's text is.
        var url: URL
        /// Kept by macOS (Time Machine, iCloud) rather than by MdEdit.
        var isSystemVersion = false
    }

    let root: URL
    var limit = 100
    /// Past this many bytes in all, the oldest copies go first.
    var totalLimit = 200 * 1024 * 1024
    /// Copies older than this go.
    var maxAge: TimeInterval = 90 * 24 * 60 * 60
    /// The history of a file deleted or renamed goes once its newest copy
    /// is this old.
    var orphanAge: TimeInterval = 30 * 24 * 60 * 60

    static let standard = VersionHistory(
        root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MdEdit/History", isDirectory: true)
    )

    func directory(for file: URL) -> URL {
        let digest = SHA256.hash(data: Data(file.standardizedFileURL.path.utf8))
        let name = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(name, isDirectory: true)
    }

    /// Files in the temporary folder come and go; their history is not kept.
    static func isWorthKeeping(_ file: URL) -> Bool {
        let temporary = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        return !file.resolvingSymlinksInPath().path.hasPrefix(temporary)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss.SSS"
        return formatter
    }()

    /// Where copies are written, one after another and off the main thread:
    /// each reads the newest copy back and writes a whole file.
    private static let queue = DispatchQueue(label: "MdEdit.VersionHistory", qos: .utility)

    /// Records a copy in the background, and prunes now and then: pruned
    /// only at launch, the history of an app left open for weeks grew past
    /// `totalLimit` by a copy of every save, a hundred to a file.
    func recordLater(_ text: String, for file: URL, at date: Date = Date()) {
        Self.queue.async {
            guard (try? record(text, for: file, at: date)) == true else { return }
            if let last = Self.lastPrune[root], date.timeIntervalSince(last) < pruneInterval { return }
            Self.lastPrune[root] = date
            prune(now: date)
        }
    }

    /// The least time between prunes made after a save: a prune looks at
    /// every copy of every file.
    var pruneInterval: TimeInterval = 10 * 60
    /// When each history was last pruned after a save. Only touched on `queue`.
    private nonisolated(unsafe) static var lastPrune: [URL: Date] = [:]

    /// Waits for copies and prunes still to be made, for tests.
    func finishPending() {
        Self.queue.sync {}
    }

    /// Keeps a copy of a file's text, unless it matches the newest copy.
    /// True when a copy was written.
    @discardableResult
    func record(_ text: String, for file: URL, at date: Date = Date()) throws -> Bool {
        let folder = directory(for: file)
        if let newest = versions(for: file).first, (try? String(contentsOf: newest.url, encoding: .utf8)) == text { return false }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = folder.appendingPathComponent("path.txt")
        if !FileManager.default.fileExists(atPath: note.path) {
            try file.standardizedFileURL.path.write(to: note, atomically: true, encoding: .utf8)
        }
        let name = Self.formatter.string(from: date) + ".md"
        try text.write(to: folder.appendingPathComponent(name), atomically: true, encoding: .utf8)
        for old in versions(for: file).dropFirst(limit) {
            try? FileManager.default.removeItem(at: old.url)
        }
        return true
    }

    /// Prunes in the background.
    func pruneLater(now: Date = Date()) {
        Self.queue.async { prune(now: now) }
    }

    /// Keeps the history within `maxAge` and `totalLimit`, and drops that of
    /// files that have gone. The newest copy of every file still there is
    /// always kept, however old or large.
    func prune(now: Date = Date()) {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var removable: [(version: Version, size: Int)] = []
        var total = 0
        for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            let versions = versions(in: folder)
            let original = (try? String(contentsOf: folder.appendingPathComponent("path.txt"), encoding: .utf8))
                .map { URL(fileURLWithPath: $0) }
            if Self.isGone(original), versions.first.map({ now.timeIntervalSince($0.date) > orphanAge }) ?? true {
                try? manager.removeItem(at: folder)
                continue
            }
            for (index, version) in versions.enumerated() {
                let size = (try? version.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                if index > 0, now.timeIntervalSince(version.date) > maxAge {
                    try? manager.removeItem(at: version.url)
                    continue
                }
                total += size
                if index > 0 { removable.append((version, size)) }
            }
        }
        for (version, size) in removable.sorted(by: { $0.version.date < $1.version.date }) where total > totalLimit {
            try? manager.removeItem(at: version.url)
            total -= size
        }
    }

    /// A file deleted or renamed: its folder is there and it is not. When
    /// the folder is missing too, the volume may just not be mounted, and
    /// sandboxed the app cannot look; age alone then decides.
    private static func isGone(_ file: URL?) -> Bool {
        guard let file else { return true }
        guard !FileAccess.isSandboxed else { return false }
        let manager = FileManager.default
        return !manager.fileExists(atPath: file.path) && manager.fileExists(atPath: file.deletingLastPathComponent().path)
    }

    /// MdEdit's copies, newest first.
    func versions(for file: URL) -> [Version] {
        versions(in: directory(for: file))
    }

    private func versions(in folder: URL) -> [Version] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                Self.formatter.date(from: url.deletingPathExtension().lastPathComponent).map { Version(date: $0, url: url) }
            }
            .sorted { $0.date > $1.date }
    }

    /// MdEdit's copies and those macOS keeps, newest first.
    func allVersions(for file: URL) -> [Version] {
        // Copies still being written are listed too.
        Self.queue.sync {}
        let system = (NSFileVersion.otherVersionsOfItem(at: file) ?? []).compactMap { version in
            version.modificationDate.map { Version(date: $0, url: version.url, isSystemVersion: true) }
        }
        return (versions(for: file) + system).sorted { $0.date > $1.date }
    }
}

/// A sheet listing a file's versions beside a preview of the chosen one.
@MainActor
final class VersionBrowserController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let versions: [VersionHistory.Version]
    private let table = NSTableView()
    private let preview = NSTextView()
    private let restoreButton = NSButton(title: String(localized: "Restore"), target: nil, action: nil)
    /// Called with the chosen version's text, or nil on Cancel.
    var onFinish: ((String?) -> Void)?

    init(versions: [VersionHistory.Version], title: String) {
        self.versions = versions
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Versions of “\(title)”")
        window.minSize = NSSize(width: 520, height: 320)
        super.init(window: window)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        guard let window else { return }
        let column = NSTableColumn(identifier: .init("version"))
        column.title = String(localized: "Saved")
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.style = .sourceList
        let tableScroll = NSScrollView()
        tableScroll.documentView = table
        tableScroll.hasVerticalScroller = true

        preview.isEditable = false
        preview.isRichText = false
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        preview.textContainerInset = NSSize(width: 12, height: 12)
        preview.isVerticallyResizable = true
        preview.autoresizingMask = [.width]
        let previewScroll = NSScrollView()
        previewScroll.documentView = preview
        previewScroll.hasVerticalScroller = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.addArrangedSubview(tableScroll)
        split.addArrangedSubview(previewScroll)
        tableScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        restoreButton.keyEquivalent = "\r"
        let note = NSTextField(labelWithString: versions.isEmpty
            ? String(localized: "No versions yet. MdEdit keeps one each time you open or save a file.")
            : String(localized: "Restoring replaces the text in the editor; you can undo it, and nothing is saved until you save."))
        note.textColor = .secondaryLabelColor
        note.font = .systemFont(ofSize: 11)
        note.lineBreakMode = .byTruncatingTail
        note.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [note, cancel, restoreButton])
        buttons.orientation = .horizontal

        let content = NSView()
        for view in [split, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: content.topAnchor),
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: split.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        split.setPosition(240, ofDividerAt: 0)

        if !versions.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        updatePreview()
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    func numberOfRows(in tableView: NSTableView) -> Int { versions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let version = versions[row]
        let title = Self.dateFormatter.string(from: version.date)
        let label = NSTextField(labelWithString: version.isSystemVersion ? String(localized: "\(title) · macOS") : title)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updatePreview()
    }

    private var selectedText: String? {
        guard versions.indices.contains(table.selectedRow) else { return nil }
        let url = versions[table.selectedRow].url
        return (try? Data(contentsOf: url)).flatMap { try? FileFormat.decode($0).text }
    }

    private func updatePreview() {
        let text = selectedText
        preview.string = text ?? ""
        restoreButton.isEnabled = text != nil
    }

    @objc private func cancel(_ sender: Any?) {
        finish(nil)
    }

    @objc private func restore(_ sender: Any?) {
        finish(selectedText)
    }

    private func finish(_ text: String?) {
        if let window, let parent = window.sheetParent {
            parent.endSheet(window)
        }
        onFinish?(text)
        onFinish = nil
    }
}
