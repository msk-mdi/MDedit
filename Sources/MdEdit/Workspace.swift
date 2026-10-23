import Foundation

/// A folder of markdown files opened as a workspace: what the file tree
/// shows, what Quick Open searches and what Find in Folder reads.
struct Workspace: Equatable, Sendable {
    let root: URL

    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "txt"]
    /// Folders that hold dependencies or build output, not notes.
    static let skippedFolders: Set<String> = ["node_modules", ".build", "build", "DerivedData", "Pods", "vendor"]
    /// Enough for any notes folder; stops a mistaken pick of `/` from stalling.
    static let fileLimit = 20_000
    /// Entries looked at before giving up. The file limit counts only
    /// markdown files, so a folder of code or a home folder, with few notes
    /// among many other files, was walked to the end however long it took.
    static let visitLimit = 200_000

    private static let defaultsKey = "workspaceRoot"

    static func load(from defaults: UserDefaults = .standard) -> Workspace? {
        guard let path = defaults.string(forKey: defaultsKey) else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return Workspace(root: URL(fileURLWithPath: path, isDirectory: true))
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(root.path, forKey: Self.defaultsKey)
    }

    static func isMarkdown(_ url: URL) -> Bool {
        markdownExtensions.contains(url.pathExtension.lowercased())
    }

    /// Every markdown file below the root, skipping hidden and dependency
    /// folders. Stops early, with what it found so far, once `isCancelled`.
    func markdownFiles(isCancelled: () -> Bool = { false }) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited >= Self.visitLimit || (visited % 256 == 0 && isCancelled()) { break }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDirectory {
                if Self.skippedFolders.contains(url.lastPathComponent) { enumerator.skipDescendants() }
                continue
            }
            if Self.isMarkdown(url) { files.append(url) }
            if files.count >= Self.fileLimit { break }
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Whether a change in these folders can change what `markdownFiles`
    /// finds: not one inside a hidden or skipped folder, which it never
    /// enters — `.git` changes at every commit, a build folder all through
    /// a build. Paths are as FSEvents reports them, symlinks resolved.
    func listingChanged(inFolders folders: [String]) -> Bool {
        let rootPath = root.resolvingSymlinksInPath().path
        return folders.contains { folder in
            let path = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
            guard path.hasPrefix(rootPath + "/") else { return true }
            let components = path.dropFirst(rootPath.count + 1).split(separator: "/")
            return !components.contains { $0.hasPrefix(".") || Self.skippedFolders.contains(String($0)) }
        }
    }

    /// `notes/today.md` for a file below the root, else the full path.
    func relativePath(of url: URL) -> String {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

/// Subsequence matching for Quick Open, scored so that the file people mean
/// comes first: matches in the file name beat matches in folders, and
/// characters that start words or run together beat scattered ones.
enum FuzzyMatcher {
    /// A candidate made ready once, so each keystroke only scores it.
    struct Prepared {
        fileprivate let haystack: [Character]
        fileprivate let lowered: [Character]
        fileprivate let nameStart: Int

        /// Nil when lowercasing changes the length, which never matches.
        init?(_ candidate: String) {
            haystack = Array(candidate)
            lowered = Array(candidate.lowercased())
            guard lowered.count == haystack.count else { return nil }
            nameStart = (haystack.lastIndex(of: "/")).map { $0 + 1 } ?? 0
        }
    }

    /// The query as matched: lowercased, without spaces.
    static func needle(_ query: String) -> [Character] {
        Array(query.lowercased().filter { !$0.isWhitespace })
    }

    /// A score, higher is better, or nil when the query is not a subsequence.
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = needle(query)
        guard !needle.isEmpty else { return 0 }
        return Prepared(candidate).flatMap { score(needle, in: $0) }
    }

    static func score(_ needle: [Character], in candidate: Prepared) -> Int? {
        guard !needle.isEmpty else { return 0 }
        // Matching greedily from the left can spend letters on folder names;
        // matching within the file name alone often scores better.
        guard let fromPath = score(needle, candidate, from: 0) else { return nil }
        let fromName = candidate.nameStart > 0 ? score(needle, candidate, from: candidate.nameStart) : nil
        // Prefer shorter paths among equal matches.
        return max(fromPath, fromName ?? fromPath) * 100 - candidate.haystack.count
    }

    private static func score(_ needle: [Character], _ candidate: Prepared, from start: Int) -> Int? {
        let haystack = candidate.haystack, lowered = candidate.lowered
        var score = 0
        var index = start
        var previousMatch = -2
        for character in needle {
            guard let found = lowered[index...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previousMatch + 1 { score += 6 }  // runs together
            if found == 0 || isBoundary(haystack[found - 1], before: haystack[found]) { score += 8 }  // starts a word
            if found >= candidate.nameStart { score += 4 }  // in the file name
            previousMatch = found
            index = found + 1
        }
        return score
    }

    private static func isBoundary(_ previous: Character, before current: Character) -> Bool {
        "/-_ .".contains(previous) || (previous.isLowercase && current.isUppercase)
    }
}

/// A workspace's markdown files, listed once in the background and kept
/// until a change where the listing looks: Find in Folder walked the whole
/// folder again after any change at all, `.git`'s included, and Quick Open
/// at every ⌘P. One list serves both.
@MainActor
final class WorkspaceFileList {
    private var listed: (root: URL, files: [URL])?
    /// Counts changes, so a list walked before one is not kept.
    private var generation = 0

    func invalidate() {
        listed = nil
        generation += 1
    }

    func files(of workspace: Workspace) async -> [URL] {
        if let listed, listed.root == workspace.root { return listed.files }
        let generation = generation
        let walk = Task.detached(priority: .userInitiated) { workspace.markdownFiles { Task.isCancelled } }
        let files = await withTaskCancellationHandler { await walk.value } onCancel: { walk.cancel() }
        // A walk cut short is not the whole list.
        if !Task.isCancelled, self.generation == generation { listed = (workspace.root, files) }
        return files
    }
}

/// Find in Folder: plain, case-insensitive text search over a set of files.
enum WorkspaceSearch {
    struct Match: Equatable, Sendable {
        /// Zero-based line.
        var line: Int
        /// The match within the line, in UTF-16 units.
        var range: NSRange
        var lineText: String
    }

    struct FileResult: Equatable, Sendable {
        var url: URL
        var matches: [Match]
    }

    static let matchLimit = 2_000
    /// Files past this size are not searched: `.txt` is a note type, but
    /// also a log's, and one of those read whole took the memory of many notes.
    static let maxFileBytes = 8 * 1024 * 1024

    /// - Parameter overrides: text to search instead of the file on disk, for
    ///   documents open with unsaved changes.
    static func search(
        _ query: String,
        in files: [URL],
        overrides: [URL: String] = [:],
        isCancelled: () -> Bool = { false }
    ) -> [FileResult] {
        guard !query.isEmpty else { return [] }
        var results: [FileResult] = []
        var total = 0
        for url in files {
            if isCancelled() || total >= matchLimit { break }
            // Not a named pipe, which a read waits on forever, holding one of
            // the few threads Swift's concurrency runs everything on.
            if overrides[url] == nil, let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
               values.isRegularFile == false || (values.fileSize ?? 0) > maxFileBytes { continue }
            guard let text = overrides[url] ?? (try? String(contentsOf: url, encoding: .utf8)) else { continue }
            var matches: [Match] = []
            var lineNumber = 0
            text.enumerateLines { line, stop in
                let ns = line as NSString
                var searchRange = NSRange(location: 0, length: ns.length)
                while total < matchLimit {
                    let found = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    matches.append(Match(line: lineNumber, range: found, lineText: line))
                    total += 1
                    let next = NSMaxRange(found)
                    searchRange = NSRange(location: next, length: ns.length - next)
                }
                if total >= matchLimit { stop = true }
                lineNumber += 1
            }
            if !matches.isEmpty { results.append(FileResult(url: url, matches: matches)) }
        }
        return results
    }
}
