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
    /// Enough for every tab and folder of a session, with room to spare.
    static let limit = 300

    static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    private static var options: (create: URL.BookmarkCreationOptions, resolve: URL.BookmarkResolutionOptions) {
        isSandboxed ? (.withSecurityScope, [.withSecurityScope, .withoutUI]) : ([], .withoutUI)
    }

    /// Records a bookmark for a file or folder the app can reach right now.
    static func remember(_ url: URL, in defaults: UserDefaults = .standard) {
        guard url.isFileURL, let data = try? url.bookmarkData(options: options.create) else { return }
        var bookmarks = load(from: defaults)
        bookmarks.removeAll { $0.path == url.standardizedFileURL.path }
        bookmarks.append(Entry(path: url.standardizedFileURL.path, data: data))
        // The oldest go first.
        if bookmarks.count > limit { bookmarks.removeFirst(bookmarks.count - limit) }
        save(bookmarks, to: defaults)
    }

    /// Where a remembered file is now, with access to it started. A file
    /// with no bookmark, or one that no longer resolves, comes back as given.
    static func resolve(_ url: URL, in defaults: UserDefaults = .standard) -> URL {
        let path = url.standardizedFileURL.path
        guard let entry = load(from: defaults).last(where: { $0.path == path }) else { return url }
        var isStale = false
        guard let resolved = try? URL(resolvingBookmarkData: entry.data, options: options.resolve, bookmarkDataIsStale: &isStale) else {
            return url
        }
        // Held for the rest of the run: the tab or folder stays open.
        if isSandboxed { _ = resolved.startAccessingSecurityScopedResource() }
        if isStale || resolved.standardizedFileURL.path != path { remember(resolved, in: defaults) }
        return resolved
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
