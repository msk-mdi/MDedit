import Foundation

/// Snapshots of unsaved documents, written periodically so a crash or a forced
/// quit loses at most a few seconds of typing. A clean quit clears them.
///
/// Each snapshot is one JSON file named after the document's id, in
/// `~/Library/Application Support/MdEdit/Recovery`.
struct RecoveryStore {
    struct Snapshot: Codable, Equatable {
        var id: UUID
        /// The file the text belongs to, or nil for an untitled document.
        var url: URL?
        var text: String
    }

    let directory: URL

    static let standard = RecoveryStore(
        directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MdEdit/Recovery", isDirectory: true)
    )

    private func file(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    func write(_ snapshot: Snapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: file(for: snapshot.id), options: .atomic)
    }

    func remove(id: UUID) {
        try? FileManager.default.removeItem(at: file(for: id))
    }

    /// Every snapshot on disk; unreadable files are skipped.
    func snapshots() -> [Snapshot] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { modificationDate($0) < modificationDate($1) }
            .compactMap { try? JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: $0)) }
    }

    func removeAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private func modificationDate(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}

/// The open windows and their tabs, restored at the next launch.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: URL
        var selectedLocation: Int
        /// View modes; absent in sessions saved before they were remembered.
        var sourceMode: Bool?
        var typewriterMode: Bool?
        var focusMode: Bool?
    }

    struct Window: Codable, Equatable {
        var tabs: [Tab]
        /// Index into `tabs`.
        var selectedIndex: Int
        /// The folder open in this window's sidebar.
        var workspace: URL?
        /// `NSWindow.frameDescriptor`, so windows come back where they were.
        var frame: String?

        init(tabs: [Tab], selectedIndex: Int, workspace: URL? = nil, frame: String? = nil) {
            self.tabs = tabs
            self.selectedIndex = selectedIndex
            self.workspace = workspace
            self.frame = frame
        }
    }

    var windows: [Window]

    init(windows: [Window]) {
        self.windows = windows
    }

    private enum CodingKeys: String, CodingKey {
        case windows
        // The single-window format written before there could be more than one.
        case tabs, selectedIndex
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let windows = try container.decodeIfPresent([Window].self, forKey: .windows) {
            self.windows = windows
        } else {
            windows = [Window(
                tabs: try container.decode([Tab].self, forKey: .tabs),
                selectedIndex: try container.decode(Int.self, forKey: .selectedIndex)
            )]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windows, forKey: .windows)
    }

    private static let key = "MdEditSession"

    static func load(from defaults: UserDefaults = .standard) -> Session? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Session.self, from: data)
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) {
            defaults.set(data, forKey: Self.key)
        }
    }
}
