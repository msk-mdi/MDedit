import AppKit

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
            var probed: NSString?
            let detected = NSString.stringEncoding(
                for: data, encodingOptions: nil, convertedString: &probed, usedLossyConversion: nil
            )
            guard let probed, detected != 0 else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            raw = probed as String
            format.encoding = String.Encoding(rawValue: detected)
        }
        if raw.contains("\r\n") {
            format.lineEnding = "\r\n"
            raw = raw.replacingOccurrences(of: "\r\n", with: "\n")
        }
        return (raw, format)
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
    var format = FileFormat()

    /// Contents as last read from or written to disk, used to detect dirtiness.
    private var savedText: String
    /// The file vanished from disk; the editor holds the only copy.
    private(set) var isMissingOnDisk = false

    /// Called when the file changes underneath us.
    var onExternalChange: (() -> Void)?
    private var watcher: FileWatcher?
    /// Set while we write, so our own save does not look like someone else's.
    private var isSavingSelf = false

    init(id: UUID = UUID(), url: URL? = nil, text: String = "", theme: Theme) {
        self.id = id
        self.url = url
        storage = MarkdownTextStorage(theme: theme)
        storage.baseURL = url
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        savedText = text
    }

    var text: String { storage.string }

    /// Starts watching the file on disk, if there is one.
    func beginWatching() {
        watcher = nil
        guard let url else { return }
        watcher = FileWatcher(url: url) { [weak self] in
            guard let self, !isSavingSelf else { return }
            onExternalChange?()
        }
    }

    /// Re-reads the file, discarding whatever is in the editor.
    func revert() throws {
        guard let url else { return }
        let (text, format) = try FileFormat.decode(Data(contentsOf: url))
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        savedText = text
        self.format = format
        isMissingOnDisk = false
    }

    /// Replaces the editor contents without touching what counts as saved,
    /// so recovered text shows as unsaved changes.
    func restoreUnsavedText(_ text: String) {
        guard text != storage.string else { return }
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
    }

    func markMissingOnDisk() {
        isMissingOnDisk = true
    }

    var isDirty: Bool { isMissingOnDisk || storage.string != savedText }

    var displayName: String {
        url?.lastPathComponent ?? "Untitled"
    }

    static func open(contentsOf url: URL, theme: Theme) throws -> Document {
        let (text, format) = try FileFormat.decode(Data(contentsOf: url))
        let document = Document(url: url, text: text, theme: theme)
        document.format = format
        document.beginWatching()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return document
    }

    func save(to target: URL? = nil) throws {
        guard let destination = target ?? url else { return }
        let contents = storage.string
        let data = try format.encode(contents)
        isSavingSelf = true
        defer {
            // Atomic writes land as a rename, which the watcher sees moments later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isSavingSelf = false
            }
        }
        try data.write(to: destination, options: .atomic)
        let needsWatcher = url != destination || isMissingOnDisk
        url = destination
        savedText = contents
        isMissingOnDisk = false
        if needsWatcher { beginWatching() }
        NSDocumentController.shared.noteNewRecentDocumentURL(destination)
    }

    /// Word and character counts for the status pill.
    func counts() -> (words: Int, characters: Int) {
        let string = storage.string
        var words = 0
        var inWord = false
        for scalar in string.unicodeScalars {
            let isSeparator = CharacterSet.whitespacesAndNewlines.contains(scalar)
            if isSeparator {
                inWord = false
            } else if !inWord {
                inWord = true
                words += 1
            }
        }
        return (words, string.count)
    }
}
