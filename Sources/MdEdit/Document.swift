import AppKit

/// One open markdown file.
///
/// Deliberately not an `NSDocument`: tabs live inside a single window and are
/// owned by `MainWindowController`, so the document is just model state.
@MainActor
final class Document {
    private(set) var url: URL?
    let storage: MarkdownTextStorage
    var encoding: String.Encoding = .utf8

    /// Contents as last read from or written to disk, used to detect dirtiness.
    private var savedText: String

    /// Called when the file changes underneath us.
    var onExternalChange: (() -> Void)?
    private var watcher: FileWatcher?
    /// Set while we write, so our own save does not look like someone else's.
    private var isSavingSelf = false

    init(url: URL? = nil, text: String = "", theme: Theme) {
        self.url = url
        storage = MarkdownTextStorage(theme: theme)
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
        let text = try String(contentsOf: url, encoding: encoding)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        savedText = text
    }

    var isDirty: Bool { storage.string != savedText }

    var displayName: String {
        url?.lastPathComponent ?? "Untitled"
    }

    static func open(contentsOf url: URL, theme: Theme) throws -> Document {
        let data = try Data(contentsOf: url)
        var encoding = String.Encoding.utf8
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else {
            var probed: NSString?
            _ = NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &probed, usedLossyConversion: nil)
            guard let probed else {
                throw CocoaError(.fileReadInapplicableStringEncoding)
            }
            text = probed as String
            encoding = .utf8  // normalise on save
        }
        let document = Document(url: url, text: text, theme: theme)
        document.encoding = encoding
        document.beginWatching()
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        return document
    }

    func save(to target: URL? = nil) throws {
        guard let destination = target ?? url else { return }
        let contents = storage.string
        guard let data = contents.data(using: encoding) ?? contents.data(using: .utf8) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        isSavingSelf = true
        defer {
            // Atomic writes land as a rename, which the watcher sees moments later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.isSavingSelf = false
            }
        }
        try data.write(to: destination, options: .atomic)
        let isNewLocation = url != destination
        url = destination
        savedText = contents
        if isNewLocation { beginWatching() }
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
