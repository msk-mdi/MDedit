import Foundation

/// Bookmarks to the files and folders the user opened, so the next launch
/// can reach them again.
///
/// Sandboxed, a path alone grants nothing once the app quits: reopening the
/// session, a workspace folder or a file takes a security-scoped bookmark
/// made while access was granted. Unsandboxed, a bookmark still follows a
/// file renamed or moved between launches.
enum FileAccess {
    private static let defaultsKey = "fileBookmarks"
    private static let pinnedKey = "pinnedFileBookmarks"
    /// Enough for every tab and folder of a session, with room to spare.
    static let limit = 300

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static var options: (create: URL.BookmarkCreationOptions, resolve: URL.BookmarkResolutionOptions) {
        // Without mounting: a bookmark to a server or disk no longer there
        // tried to mount it, holding up launch until that gave up.
        isSandboxed
            ? (.withSecurityScope, [.withSecurityScope, .withoutUI, .withoutMounting])
            : ([], [.withoutUI, .withoutMounting])
    }

    /// Records a bookmark for a file or folder the app can reach right now.
    static func remember(_ url: URL, in defaults: UserDefaults = .standard) {
        guard url.isFileURL, let data = try? url.bookmarkData(options: options.create) else { return }
        // The list is read, changed and written back whole: two at once
        // would each drop the other's.
        lock.lock()
        defer { lock.unlock() }
        var bookmarks = load(from: defaults)
        bookmarks.removeAll { $0.path == url.standardizedFileURL.path }
        bookmarks.append(Entry(path: url.standardizedFileURL.path, data: data))
        // The oldest go first, except those the session still needs: losing
        // the workspace folder's would lose the folder, sandboxed.
        let pinned = Set(defaults.stringArray(forKey: pinnedKey) ?? [])
        var excess = bookmarks.count - limit
        if excess > 0 {
            bookmarks.removeAll { entry in
                guard excess > 0, !pinned.contains(entry.path) else { return false }
                excess -= 1
                return true
            }
        }
        save(bookmarks, to: defaults)
    }

    /// Records a bookmark in the background, as opening a file does: making
    /// one can wait on a network volume, and each rewrote the whole list on
    /// the main thread, once per tab as a session was restored.
    static func rememberLater(_ url: URL) {
        queue.async { remember(url) }
    }

    private static let lock = NSLock()
    private static let queue = DispatchQueue(label: "MdEdit.FileAccess", qos: .utility)

    /// Keeps the bookmarks of these files and folders, the open session's,
    /// however many others are remembered after them.
    static func pin(_ urls: [URL], in defaults: UserDefaults = .standard) {
        defaults.set(urls.map(\.standardizedFileURL.path), forKey: pinnedKey)
    }

    /// Where a remembered file is now, with access to it started. A file
    /// with no bookmark, or one that no longer resolves, comes back as given.
    static func resolve(_ url: URL, in defaults: UserDefaults = .standard) -> URL {
        resolve([url], in: defaults)[0]
    }

    /// Several at once, as a session's tabs are: each one read and decoded
    /// the whole list of bookmarks again.
    static func resolve(_ urls: [URL], in defaults: UserDefaults = .standard) -> [URL] {
        guard !urls.isEmpty else { return [] }
        var byPath: [String: Data] = [:]
        for entry in load(from: defaults) { byPath[entry.path] = entry.data }
        var moved: [URL] = []
        let resolved = urls.map { url -> URL in
            let path = url.standardizedFileURL.path
            guard let data = byPath[path] else { return url }
            var isStale = false
            guard let resolved = try? URL(resolvingBookmarkData: data, options: options.resolve, bookmarkDataIsStale: &isStale) else {
                return url
            }
            // Held while the tab or folder stays open; see `releaseAccess`.
            if isSandboxed, resolved.startAccessingSecurityScopedResource() { access.add(resolved) }
            if isStale || resolved.standardizedFileURL.path != path { moved.append(resolved) }
            return resolved
        }
        for url in moved { remember(url, in: defaults) }
        return resolved
    }

    static let access = ScopedAccess()

    /// Stops the access `resolve` started to files and folders no tab or
    /// workspace uses any more: closed, replaced, or moved, and taken again
    /// at the new path. A folder holding an open file keeps its access, as
    /// the file may have none of its own.
    static func releaseAccess(keeping open: [URL]) {
        access.release(keeping: open)
    }

    private struct Entry: Codable {
        var path: String
        var data: Data
    }

    private static func load(from defaults: UserDefaults) -> [Entry] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [] }
        return (try? PropertyListDecoder().decode([Entry].self, from: data)) ?? []
    }

    private static func save(_ bookmarks: [Entry], to defaults: UserDefaults) {
        if let data = try? PropertyListEncoder().encode(bookmarks) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

/// The files and folders whose security-scoped access was started, by path.
/// Each start holds a sandbox extension in the kernel until it is stopped,
/// and holding one for every tab ever restored leaked them for the run.
final class ScopedAccess: @unchecked Sendable {
    private let lock = NSLock()
    /// Starts are counted: one path can be resolved for two windows, and
    /// each start takes a stop of its own.
    private var started: [String: (url: URL, count: Int)] = [:]
    private let stop: (URL) -> Void

    init(stop: @escaping (URL) -> Void = { $0.stopAccessingSecurityScopedResource() }) {
        self.stop = stop
    }

    var paths: Set<String> {
        lock.withLock { Set(started.keys) }
    }

    func add(_ url: URL) {
        lock.withLock {
            let path = url.standardizedFileURL.path
            started[path] = (url, (started[path]?.count ?? 0) + 1)
        }
    }

    /// Stops access to everything that is neither one of these nor a folder
    /// holding one.
    func release(keeping open: [URL]) {
        let unused: [(url: URL, count: Int)] = lock.withLock {
            guard !started.isEmpty else { return [] }
            let openPaths = open.map(\.standardizedFileURL.path)
            let unused = started.filter { path, _ in
                !openPaths.contains { $0 == path || $0.hasPrefix(path.hasSuffix("/") ? path : path + "/") }
            }
            for path in unused.keys { started[path] = nil }
            return Array(unused.values)
        }
        for entry in unused {
            for _ in 0..<entry.count { stop(entry.url) }
        }
    }
}
