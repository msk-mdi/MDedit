import AppKit
import CryptoKit
import MarkdownKit

/// How a file's text was stored on disk, so saving writes it back the same way.
struct FileFormat: Equatable {
    var encoding: String.Encoding = .utf8
    var hasByteOrderMark = false
    /// The editor always works in `\n`; this is what a save turns it back into.
    var lineEnding = "\n"

    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Decodes file contents into editor text (always `\n` line endings).
    static func decode(_ data: Data) throws -> (text: String, format: FileFormat) {
        var format = FileFormat()
        var raw: String
        if data.starts(with: utf8BOM), let utf8 = String(data: data.dropFirst(utf8BOM.count), encoding: .utf8) {
            raw = utf8
            format.hasByteOrderMark = true
        } else if let utf8 = String(data: data, encoding: .utf8) {
            raw = utf8
        } else {
            // Only an encoding that reads every byte: a lossy guess shows
            // stand-ins for what it could not read, and the next save writes
            // them over the original bytes for good.
            var probed: NSString?
            var lossy: ObjCBool = false
            let detected = NSString.stringEncoding(
                for: data, encodingOptions: [.allowLossyKey: false], convertedString: &probed, usedLossyConversion: &lossy
            )
            guard let probed, detected != 0, !lossy.boolValue else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            raw = probed as String
            format.encoding = String.Encoding(rawValue: detected)
        }
        if raw.contains("\r\n") {
            format.lineEnding = "\r\n"
            raw = raw.replacingOccurrences(of: "\r\n", with: "\n")
        } else if raw.contains("\r") {
            // Classic Mac line endings: the parser and the text view would
            // otherwise disagree about where lines break.
            format.lineEnding = "\r"
        }
        // Any lone `\r` left, in a file that mixes endings, breaks a line too.
        if raw.contains("\r") { raw = raw.replacingOccurrences(of: "\r", with: "\n") }
        return (raw, format)
    }

    /// Reads and decodes a file away from the main thread: a file still
    /// downloading from iCloud, or on a slow or remote volume, would
    /// otherwise stall the whole app until it arrived.
    static func read(
        _ url: URL,
        using load: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) async throws -> (text: String, format: FileFormat) {
        try await Task.detached(priority: .userInitiated) {
            try checkReadable(url)
            return try decode(load(url))
        }.value
    }

    /// Past this, a file is not opened: read whole, copied as it is decoded
    /// and styled on the main thread, a log of hundreds of megabytes hung the
    /// app for minutes or ran it out of memory. 4.5 MB takes seconds.
    static let maxBytes = 32 * 1024 * 1024

    /// Refuses what reading would hang on or drown in: a named pipe blocks
    /// until something writes to it, and a huge file is read whole.
    static func checkReadable(_ url: URL) throws {
        // A symlink's own values say it is a link; what it points to counts.
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else { return }
        if values.isRegularFile == false { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        if let size = values.fileSize, size > maxBytes { throw CocoaError(.fileReadTooLarge, userInfo: [NSFilePathErrorKey: url.path]) }
    }

    /// Encodes editor text the way it was read. Throws rather than silently
    /// changing encoding when the text no longer fits the original one.
    func encode(_ text: String) throws -> Data {
        let contents = lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
        guard let body = contents.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return hasByteOrderMark && encoding == .utf8 ? Data(Self.utf8BOM) + body : body
    }
}

/// What a file's modification date and size were, to tell whether anyone
/// has written to it since.
struct FileStamp: Equatable {
    var modified: Date
    var size: Int

    init?(of url: URL) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attributes[.modificationDate] as? Date,
              let size = (attributes[.size] as? NSNumber)?.intValue
        else { return nil }
        self.modified = modified
        self.size = size
    }
}

/// One open markdown file.
///
/// Deliberately not an `NSDocument`: tabs live inside a single window and are
/// owned by `MainWindowController`, so the document is just model state.
@MainActor
final class Document {
    /// Stable identity for autosave recovery files.
    let id: UUID
    private(set) var url: URL? {
        didSet { storage.baseURL = url }
    }
    let storage: MarkdownTextStorage
    /// This document's own undo history: tabs share a window, not a history,
    /// and the history goes with the tab to another window.
    let undoManager = UndoManager()
    var format = FileFormat()

    /// Contents as last read from or written to disk, used to detect dirtiness.
    private var savedText: String {
        didSet {
            savedLength = (savedText as NSString).length
            cachedDirtiness = nil
        }
    }
    /// Comparing lengths first keeps the dirty check off the whole text
    /// for almost every keystroke.
    private var savedLength = 0
    /// The file vanished from disk; the editor holds the only copy.
    private(set) var isMissingOnDisk = false

    /// Called when the file changes underneath us.
    var onExternalChange: (() -> Void)?
    /// Called once the document follows its file to a new name or folder.
    var onMove: (() -> Void)?
    private var watcher: FileWatcher?
    /// The file as last read or written here, so the watcher's news of our
    /// own save is not taken for someone else's, and a save does not write
    /// over a change it has not seen: a file left otherwise, however soon
    /// after, was changed by someone else.
    private var diskStamp: FileStamp?

    /// The file changed on disk since it was last read or written here, so
    /// saving would replace someone else's changes.
    struct ChangedOnDiskError: Error {}

    init(id: UUID = UUID(), url: URL? = nil, text: String = "", theme: Theme) {
        self.id = id
        self.url = url
        storage = MarkdownTextStorage(theme: theme)
        storage.extensions = Settings().extensions
        storage.baseURL = url
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        savedText = text
        savedLength = (text as NSString).length
    }

    var text: String { storage.string }

    /// Starts watching the file on disk, if there is one.
    func beginWatching() {
        watcher = nil
        guard let url else { return }
        watcher = FileWatcher(url: url, onChange: { [weak self] in
            guard let self else { return }
            // A writer sends several events for one save; answer the last.
            pendingExternalChange?.cancel()
            let change = DispatchWorkItem { [weak self] in
                guard let self, let url = self.url else { return }
                if let diskStamp, FileStamp(of: url.resolvingSymlinksInPath()) == diskStamp { return }
                onExternalChange?()
            }
            pendingExternalChange = change
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: change)
        }, onMove: { [weak self] newURL in
            self?.follow(to: newURL)
        })
    }

    /// Takes the file's new name or folder for its own. A tab left on the
    /// old path showed the file as missing, and saving wrote a second copy
    /// there. Moved to the Trash, it stays missing: it is as good as gone.
    private func follow(to newURL: URL) {
        guard !Self.isInTrash(newURL) else { return }
        url = newURL
        isMissingOnDisk = false
        FileAccess.remember(newURL)
        // Sandboxed, access started for the old path is let go once no tab
        // is there; this takes it for the new one.
        if FileAccess.isSandboxed { _ = FileAccess.resolve(newURL) }
        beginWatching()
        onMove?()
    }

    private static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    private var pendingExternalChange: DispatchWorkItem?

    /// Re-reads the file, discarding whatever is in the editor. Returns false,
    /// leaving the editor alone, when the text was edited or the document
    /// saved elsewhere while the file was being read.
    @discardableResult
    func revert(
        using load: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) async throws -> Bool {
        guard let url else { return true }
        let generation = storage.editGeneration
        // Taken before reading: a write landing during the read then shows
        // as a change still unseen, never as one already taken in.
        let stamp = FileStamp(of: url.resolvingSymlinksInPath())
        let (text, format) = try await FileFormat.read(url, using: load)
        guard storage.editGeneration == generation, self.url == url else { return false }
        diskStamp = stamp
        // Touched, or rewritten as it was (a sync, a checkout): reloading
        // would restyle the whole document for nothing.
        if text == savedText, !isDirty {
            self.format = format
            isMissingOnDisk = false
            return true
        }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        // The history was of the old text: undoing it here would replay its
        // ranges onto text they no longer fit.
        undoManager.removeAllActions()
        savedText = text
        self.format = format
        isMissingOnDisk = false
        return true
    }

    /// The file as it is on disk now, read away from the main thread, and
    /// what it looked like as it was read.
    struct DiskContents {
        var text: String
        var format: FileFormat
        var stamp: FileStamp?
    }

    func readFromDisk(
        using load: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }
    ) async throws -> DiskContents? {
        guard let url else { return nil }
        let stamp = FileStamp(of: url.resolvingSymlinksInPath())
        let (text, format) = try await FileFormat.read(url, using: load)
        guard self.url == url else { return nil }
        return DiskContents(text: text, format: format, stamp: stamp)
    }

    /// Takes contents just read for what is saved, once the editor shows
    /// them: Revert to Saved left the old saved text in place, so a file
    /// changed on disk since showed as edited the moment it was reverted to.
    func adoptSaved(_ contents: DiskContents) {
        savedText = contents.text
        format = contents.format
        diskStamp = contents.stamp
        isMissingOnDisk = false
    }

    /// Identifies the text last read from or written to disk, for telling
    /// whether a recovery snapshot was made against what the file holds now.
    var savedDigest: String { Self.digest(savedText) }

    static func digest(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Replaces the editor contents without touching what counts as saved,
    /// so recovered text shows as unsaved changes.
    func restoreUnsavedText(_ text: String) {
        guard text != storage.string else { return }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        undoManager.removeAllActions()
    }

    /// Takes the file as it now is for the one these edits are meant to
    /// replace, once the user chose to keep them over a change on disk.
    func keepEditsOverChangeOnDisk() {
        guard let url else { return }
        diskStamp = FileStamp(of: url.resolvingSymlinksInPath())
    }

    func markMissingOnDisk() {
        isMissingOnDisk = true
    }

    /// Every open tab is asked on every keystroke, and an equal length means
    /// comparing the whole text, so the answer is kept until the next edit.
    var isDirty: Bool {
        if isMissingOnDisk || storage.length != savedLength { return true }
        if let cached = cachedDirtiness, cached.generation == storage.editGeneration { return cached.value }
        let value = storage.string != savedText
        cachedDirtiness = (storage.editGeneration, value)
        return value
    }

    private var cachedDirtiness: (generation: Int, value: Bool)?

    /// The tab title of a document with no file yet, when it should not be
    /// "Untitled": the welcome page, the cheat sheet.
    var untitledName: String?

    var displayName: String {
        url?.lastPathComponent ?? untitledName ?? String(localized: "Untitled")
    }

    static func open(contentsOf url: URL, theme: Theme) async throws -> Document {
        open(url, read: try await FileFormat.read(url), theme: theme)
    }

    /// A document for a file whose contents have already been read.
    static func open(_ url: URL, read: (text: String, format: FileFormat), theme: Theme) -> Document {
        let (text, format) = read
        FileAccess.rememberLater(url)
        let document = Document(url: url, text: text, theme: theme)
        document.format = format
        document.diskStamp = FileStamp(of: url.resolvingSymlinksInPath())
        document.beginWatching()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        // The file as found, before any of this session's edits.
        document.recordVersion(text)
        return document
    }

    /// Writes the text to its file, or to `target`. Throws
    /// `ChangedOnDiskError`, writing nothing, when the document's own file
    /// was changed by someone else since it was last read or written, unless
    /// `overwritingChanges`.
    func save(to target: URL? = nil, overwritingChanges: Bool = false) throws {
        guard let destination = target ?? url else { return }
        let contents = storage.string
        let data = try format.encode(contents)
        // Through a symlink to the file it names: an atomic write renames a
        // new file into place, which would replace the link itself and leave
        // the real file as it was.
        let file = destination.resolvingSymlinksInPath()
        // Save As to another file was already agreed to in the save panel.
        if !overwritingChanges, destination == url, let found = FileStamp(of: file), found != diskStamp {
            throw ChangedOnDiskError()
        }
        if Self.linkCount(of: file) > 1 {
            try Self.writeInPlace(data, to: file)
        } else {
            try Self.replace(file, with: data)
        }
        diskStamp = FileStamp(of: file)
        let needsWatcher = url != destination || isMissingOnDisk
        if url != destination { FileAccess.remember(destination) }
        url = destination
        if let goal = untitledGoal {
            WordGoals.set(goal, for: destination)
            untitledGoal = nil
        }
        savedText = contents
        isMissingOnDisk = false
        if needsWatcher { beginWatching() }
        NSDocumentController.shared.noteNewRecentDocumentURL(destination)
        recordVersion(contents)
    }

    private static func linkCount(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.referenceCount] as? NSNumber)?.intValue ?? 0
    }

    /// Writes a new file into place with the old one's metadata: its Finder
    /// tags, other extended attributes, creation date and permissions. An
    /// atomic write renamed a new file over it, which had none of them.
    private static func replace(_ file: URL, with data: Data) throws {
        let manager = FileManager.default
        guard let attributes = try? manager.attributesOfItem(atPath: file.path) else {
            return try data.write(to: file, options: .atomic)
        }
        do {
            let folder = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: file, create: true)
            defer { try? manager.removeItem(at: folder) }
            let staged = folder.appendingPathComponent(file.lastPathComponent)
            try data.write(to: staged)
            if let permissions = attributes[.posixPermissions] {
                try manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: staged.path)
            }
            _ = try manager.replaceItemAt(file, withItemAt: staged)
        } catch {
            // Where a replacement cannot be staged, as on some network
            // volumes, the file is still written whole or not at all.
            try data.write(to: file, options: .atomic)
        }
    }

    /// Writes over a file's own bytes. An atomic write renames a new file
    /// into place, which would split a file with other hard links from them:
    /// they would keep the old text. Should the write fail partway, the old
    /// bytes are put back.
    private static func writeInPlace(_ data: Data, to file: URL) throws {
        let original = try Data(contentsOf: file)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        do {
            try handle.write(contentsOf: data)
            try handle.truncate(atOffset: UInt64(data.count))
            try handle.synchronize()
        } catch {
            try? handle.seek(toOffset: 0)
            try? handle.write(contentsOf: original)
            try? handle.truncate(atOffset: UInt64(original.count))
            throw error
        }
    }

    /// What the last recovery snapshot was written from, so an unchanged
    /// document is not written again; nil when it has none.
    struct SnapshotState: Equatable {
        var generation: Int
        var url: URL?
    }

    var snapshotState: SnapshotState?

    /// Where earlier versions of the file are kept.
    var history = VersionHistory.standard

    private func recordVersion(_ text: String) {
        guard let url, VersionHistory.isWorthKeeping(url) else { return }
        history.recordLater(text, for: url)
    }

    /// Counts for the status bar, kept until the text next changes.
    func statistics() -> TextStatistics {
        if let cached = cachedStatistics, cached.generation == storage.editGeneration { return cached.value }
        let value = TextStatistics(storage.string)
        cachedStatistics = (storage.editGeneration, value)
        return value
    }

    /// Counts away from the main thread, from a copy of the text: the whole
    /// document scanned after every pause in typing hitched a large one.
    /// Kept, and returned, only if the text was not changed meanwhile.
    func countStatistics() async -> TextStatistics? {
        if let cached = cachedStatistics, cached.generation == storage.editGeneration { return cached.value }
        let generation = storage.editGeneration
        let text = storage.string
        let value = await Task.detached(priority: .utility) { TextStatistics(text) }.value
        guard storage.editGeneration == generation else { return nil }
        cachedStatistics = (generation, value)
        return value
    }

    /// The last counts, even if the text has changed since: cheap enough to
    /// show while typing, until the count catches up.
    var latestStatistics: TextStatistics? { cachedStatistics?.value }

    var hasCurrentStatistics: Bool { cachedStatistics?.generation == storage.editGeneration }

    private var cachedStatistics: (generation: Int, value: TextStatistics)?

    /// A target word count, kept per file across launches.
    var wordGoal: Int? {
        get { url.flatMap { WordGoals.goal(for: $0) } ?? untitledGoal }
        set {
            if let url { WordGoals.set(newValue, for: url) } else { untitledGoal = newValue }
        }
    }

    private var untitledGoal: Int?
}

/// Word goals by file path, in user defaults.
enum WordGoals {
    private static let key = "wordGoals"

    static func goal(for url: URL, in defaults: UserDefaults = .standard) -> Int? {
        (defaults.dictionary(forKey: key)?[url.standardizedFileURL.path] as? Int).flatMap { $0 > 0 ? $0 : nil }
    }

    static func set(_ goal: Int?, for url: URL, in defaults: UserDefaults = .standard) {
        var goals = defaults.dictionary(forKey: key) ?? [:]
        goals[url.standardizedFileURL.path] = goal.flatMap { $0 > 0 ? $0 : nil }
        defaults.set(goals, forKey: key)
    }
}
