import Foundation

/// How a document's lines are read.
public enum DocumentSyntax: Equatable, Sendable {
    case markdown
    /// A file that is not markdown, as JSON or a property list: every line
    /// is code, coloured as the language when the highlighter knows it.
    case code(Language?)

    /// The syntax a file's name calls for: markdown for markdown and plain
    /// text, code for anything else.
    public static func forFile(named name: String) -> DocumentSyntax {
        let fileExtension = (name as NSString).pathExtension.lowercased()
        if markdownExtensions.contains(fileExtension) { return .markdown }
        // A bare name says more than nothing: `Makefile`, `Dockerfile`, `.zshrc`.
        var key = fileExtension
        if key.isEmpty {
            key = (name as NSString).lastPathComponent.lowercased()
            if key.hasPrefix(".") { key.removeFirst() }
        }
        guard !key.isEmpty, !key.contains(" ") else { return .code(nil) }
        return .code(Language.named(fileAliases[key] ?? key))
    }

    /// Read as markdown. Plain text is too: notes are often kept as `.txt`.
    public static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn", "txt", "text"]

    /// Extensions whose language goes by another name.
    private static let fileAliases: [String: String] = [
        "plist": "xml", "mobileconfig": "xml", "entitlements": "xml", "xib": "xml", "storyboard": "xml",
        "xcscheme": "xml", "xcprivacy": "xml", "xsd": "xml", "xsl": "xml", "xslt": "xml", "rss": "xml",
        "atom": "xml", "opml": "xml", "csproj": "xml", "resx": "xml", "htm": "html",
        "geojson": "json", "jsonl": "json", "ndjson": "json", "har": "json", "webmanifest": "json",
        "code-workspace": "json", "bash_profile": "bash", "bashrc": "bash", "zshrc": "bash", "profile": "bash",
        "env": "bash", "command": "bash", "properties": "toml", "editorconfig": "toml", "gitconfig": "toml",
        "pyw": "python", "pyi": "python", "gradle": "kotlin", "cs": "java", "scala": "java",
    ]
}

/// The parsed block structure of a whole document, kept up to date one edit at
/// a time.
///
/// The incremental rule: reparse from the first changed line, and stop at the
/// first line past the edit whose carry state matches what the previous parse
/// recorded — from there nothing downstream can differ.
public final class BlockStructure {
    public private(set) var index: LineIndex
    public private(set) var lines: [LineInfo]
    /// The extended syntax this structure was parsed with.
    public let extensions: SyntaxExtensions
    /// Markdown, or a file read as code.
    public let syntax: DocumentSyntax

    public init(text: NSString, extensions: SyntaxExtensions = .all, syntax: DocumentSyntax = .markdown) {
        self.extensions = extensions
        self.syntax = syntax
        index = LineIndex(text: text)
        lines = []
        lines.reserveCapacity(index.count)
        (hasFrontMatter, frontMatterDecidedThrough) = frontMatter(text)
        var carry = startCarry()
        for line in 0..<index.count {
            let info = BlockParser.parse(line: Self.characters(of: text, index: index, line: line), carry: carry)
            lines.append(info)
            carry = info.state
        }
    }

    public var lineCount: Int { index.count }

    /// Whether the document opens with front matter that reads as YAML.
    /// Without looking ahead, any document starting with `---` had its
    /// first lines shown as front matter, while export showed a rule and
    /// the text below it.
    public private(set) var hasFrontMatter = false

    /// Front matter longer than this is taken for ordinary text: deciding
    /// looks at every line of it, on every edit.
    static let frontMatterLookahead = 1_000

    /// The last line the front matter decision looked at: an edit below it
    /// leaves the answer as it was.
    private var frontMatterDecidedThrough = 0

    static func opensFrontMatter(_ text: NSString, index: LineIndex) -> Bool {
        frontMatter(text, index: index).opens
    }

    /// Whether the document opens with front matter, and the last line that
    /// took looking at to know.
    static func frontMatter(_ text: NSString, index: LineIndex) -> (opens: Bool, through: Int) {
        guard index.count > 1, isFrontMatterOpening(characters(of: text, index: index, line: 0)) else { return (false, 0) }
        var hasContent = false
        let end = min(index.count, frontMatterLookahead)
        for line in 1..<end {
            let characters = characters(of: text, index: index, line: line)
            if isFrontMatterClosing(characters) { return (hasContent, line) }
            guard isYAMLFrontMatterLine(String(decoding: characters, as: UTF16.self)) else { return (false, line) }
            if !isBlank(characters, from: 0) { hasContent = true }
        }
        return (false, end - 1)
    }

    /// Code has no front matter: nothing to look ahead for, before or after an edit.
    private func frontMatter(_ text: NSString) -> (opens: Bool, through: Int) {
        guard syntax == .markdown else { return (false, -1) }
        return Self.frontMatter(text, index: index)
    }

    private func startCarry() -> CarryState {
        var carry = CarryState.start(extensions: extensions)
        carry.opensFrontMatter = hasFrontMatter
        if case let .code(language) = syntax {
            carry.fence = Fence(character: 0, count: 0, info: "", language: language, isWholeFile: true)
        }
        return carry
    }

    /// Whether the last update added, removed or changed a link or footnote
    /// definition, so references need collecting again.
    public private(set) var touchedDefinitions = false

    public func info(forLine line: Int) -> LineInfo? {
        lines.indices.contains(line) ? lines[line] : nil
    }

    /// Reparses what the edit could have changed.
    ///
    /// - Returns: the range of lines whose styling must be reapplied.
    @discardableResult
    public func update(
        text: NSString,
        editedRange: NSRange,
        changeInLength changeDelta: Int
    ) -> ClosedRange<Int> {
        let oldLineCount = lines.count
        let touched = index.update(editedRange: editedRange, changeInLength: changeDelta, text: text)
        let lineDelta = index.count - oldLineCount

        var first = touched.lowerBound
        // An edit anywhere in the first lines can make them front matter or
        // stop them being it: then they all parse again. Below the lines the
        // answer was read from, it cannot, and up to a thousand lines are
        // not read again at every keystroke.
        if first <= frontMatterDecidedThrough {
            let (opens, through) = frontMatter(text)
            frontMatterDecidedThrough = through
            if opens != hasFrontMatter {
                hasFrontMatter = opens
                first = 0
            }
        }
        let lastTouched = touched.upperBound

        // Only the reparsed run is rebuilt; lines either side stay in place.
        let prefix = min(first, oldLineCount)
        var fresh: [LineInfo] = []
        // A shrinking document can leave `first` past the end of the old array.
        while prefix + fresh.count < first {
            fresh.append(lines.last ?? BlockParser.parse(line: [], carry: startCarry()))
        }

        var carry = if first == 0 {
            startCarry()
        } else if first - 1 < prefix {
            lines[first - 1].state
        } else {
            fresh[first - 1 - prefix].state
        }
        var line = first
        // The last line whose styling actually has to change. Lines parsed
        // beyond the edit only to confirm the state matched are not restyled.
        var lastChanged = first
        // The first old line kept as it was, once the parse caught up.
        var resumeOld = oldLineCount

        while line < index.count {
            let info = BlockParser.parse(line: Self.characters(of: text, index: index, line: line), carry: carry)
            fresh.append(info)
            carry = info.state

            if line <= lastTouched {
                lastChanged = line
            } else {
                let oldLine = line - lineDelta
                let unchanged = oldLine >= 0 && oldLine < oldLineCount && lines[oldLine] == info
                if !unchanged { lastChanged = line }
                if oldLine >= 0, oldLine < oldLineCount, lines[oldLine].state == info.state {
                    resumeOld = oldLine + 1
                    break
                }
            }
            line += 1
        }

        let replaced = prefix..<max(prefix, resumeOld)
        touchedDefinitions = lines[replaced].contains(where: \.kind.isDefinition) || fresh.contains(where: \.kind.isDefinition)
        lines.replaceSubrange(replaced, with: fresh)
        if lines.count != index.count {
            // A safety net: structure and index must agree, so fall back to a
            // full parse rather than style against a stale array.
            rebuild(text: text)
            touchedDefinitions = true
            return 0...max(0, index.count - 1)
        }
        return first...max(first, min(lastChanged, index.count - 1))
    }

    private func rebuild(text: NSString) {
        index = LineIndex(text: text)
        lines = []
        lines.reserveCapacity(index.count)
        (hasFrontMatter, frontMatterDecidedThrough) = frontMatter(text)
        var carry = startCarry()
        for line in 0..<index.count {
            let info = BlockParser.parse(line: Self.characters(of: text, index: index, line: line), carry: carry)
            lines.append(info)
            carry = info.state
        }
    }

    /// UTF-16 units of one line, without its newline.
    static func characters(of text: NSString, index: LineIndex, line: Int) -> [UInt16] {
        let range = index.contentRange(ofLine: line, in: text)
        guard range.length > 0 else { return [] }
        var buffer = [UInt16](repeating: 0, count: range.length)
        buffer.withUnsafeMutableBufferPointer { pointer in
            text.getCharacters(pointer.baseAddress!, range: range)
        }
        return buffer
    }

    /// Characters of a line in this structure's current text.
    public func characters(of text: NSString, line: Int) -> [UInt16] {
        Self.characters(of: text, index: index, line: line)
    }
}

extension BlockKind {
    /// Link reference and footnote definitions, which other lines resolve against.
    var isDefinition: Bool {
        switch self {
        case .linkReferenceDefinition, .footnoteDefinition: true
        default: false
        }
    }
}
