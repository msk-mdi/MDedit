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

/// The open tabs, restored at the next launch.
struct Session: Codable, Equatable {
    struct Tab: Codable, Equatable {
        var url: URL
        var selectedLocation: Int
    }

    var tabs: [Tab]
    /// Index into `tabs`.
    var selectedIndex: Int

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
