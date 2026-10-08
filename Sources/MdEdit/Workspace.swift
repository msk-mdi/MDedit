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

    /// Every markdown file below the root, skipping hidden and dependency folders.
    func markdownFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator {
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
    /// A score, higher is better, or nil when the query is not a subsequence.
    static func score(_ query: String, in candidate: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(candidate)
        let lowered = Array(candidate.lowercased())
        guard lowered.count == haystack.count else { return nil }
        let nameStart = (candidate.lastIndex(of: "/").map { candidate.distance(from: candidate.startIndex, to: $0) + 1 }) ?? 0

        // Matching greedily from the left can spend letters on folder names;
        // matching within the file name alone often scores better.
        let fromPath = score(needle, haystack, lowered, from: 0, nameStart: nameStart)
        let fromName = nameStart > 0 ? score(needle, haystack, lowered, from: nameStart, nameStart: nameStart) : nil
        guard let best = [fromPath, fromName].compactMap({ $0 }).max() else { return nil }
        // Prefer shorter paths among equal matches.
        return best * 100 - haystack.count
    }

    private static func score(
        _ needle: [Character],
        _ haystack: [Character],
        _ lowered: [Character],
        from start: Int,
        nameStart: Int
    ) -> Int? {
        var score = 0
        var index = start
        var previousMatch = -2
        for character in needle {
            guard let found = lowered[index...].firstIndex(of: character) else { return nil }
            score += 1
            if found == previousMatch + 1 { score += 6 }  // runs together
            if found == 0 || isBoundary(haystack[found - 1], before: haystack[found]) { score += 8 }  // starts a word
            if found >= nameStart { score += 4 }  // in the file name
            previousMatch = found
            index = found + 1
        }
        return score
    }

    private static func isBoundary(_ previous: Character, before current: Character) -> Bool {
        "/-_ .".contains(previous) || (previous.isLowercase && current.isUppercase)
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
