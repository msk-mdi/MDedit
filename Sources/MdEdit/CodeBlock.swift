import Foundation
import MarkdownKit

/// A fenced code block located in a document, for the language picker, the
/// Copy button and fence-aware typing.
struct CodeBlock: Equatable {
    /// The opening fence's line.
    var openLine: Int
    /// The closing fence's line, or nil while the block is unclosed.
    var closeLine: Int?
    /// The info string after the opening fence, e.g. `swift`.
    var info: String
    /// Where the info string sits in the document, for replacing it.
    var infoRange: NSRange
    /// An indented block: it has no fences, so `openLine` and `closeLine`
    /// are its first and last code lines, and a language is given to it by
    /// fencing it.
    var isIndented = false

    /// The block holding a line, if the line is part of one.
    @MainActor
    static func containing(line: Int, in storage: MarkdownTextStorage) -> CodeBlock? {
        let structure = storage.structure
        if let indented = indented(containing: line, in: structure) { return indented }
        // Asked on every keystroke and caret move, and a long block has many
        // lines to walk: reading each line's kind in place, not copying its
        // whole description, keeps that cheap.
        let found: (open: Int, close: Int?)? = structure.lines.withUnsafeBufferPointer { lines in
            guard lines.indices.contains(line) else { return nil }
            var open = line
            switch lines[line].kind {
            case .fenceStart:
                break
            case .codeLine, .fenceEnd:
                while open > 0, !lines[open].kind.isFenceStart { open -= 1 }
                guard lines[open].kind.isFenceStart else { return nil }
            default:
                return nil
            }
            var cursor = open + 1
            while cursor < lines.count {
                switch lines[cursor].kind {
                case .fenceEnd: return (open, cursor)
                case .codeLine: cursor += 1
                default: return (open, nil)
                }
            }
            return (open, nil)
        }
        guard let (open, close) = found else { return nil }

        // The info string follows the run of backticks or tildes.
        let text = storage.text
        let characters = structure.characters(of: text, line: open)
        var start = 0
        while start < characters.count, characters[start] == 0x20 || characters[start] == 0x3E { start += 1 }  // spaces, `>`
        let fenceCharacter = start < characters.count ? characters[start] : 0
        while start < characters.count, characters[start] == fenceCharacter { start += 1 }
        let lineStart = structure.index.range(ofLine: open).location
        let infoRange = NSRange(location: lineStart + start, length: characters.count - start)
        let infoString = text.substring(with: infoRange).trimmingCharacters(in: .whitespaces)
        return CodeBlock(openLine: open, closeLine: close, info: infoString, infoRange: infoRange)
    }

    /// A top-level indented block holding a line. Blank lines between its
    /// chunks belong to it; nested ones, inside a list or quote, are left
    /// alone, as their indentation is not the block's own to remove.
    private static func indented(containing line: Int, in structure: BlockStructure) -> CodeBlock? {
        func isCode(_ line: Int) -> Bool {
            guard let info = structure.info(forLine: line) else { return false }
            return info.kind == .indentedCode && info.quoteDepth == 0 && info.listDepth == 0
        }
        func isBlank(_ line: Int) -> Bool { structure.info(forLine: line)?.kind == .blank }
        guard isCode(line) else { return nil }
        var open = line
        while true {
            var above = open - 1
            while isBlank(above) { above -= 1 }
            guard isCode(above) else { break }
            open = above
        }
        var close = line
        while true {
            var below = close + 1
            while isBlank(below) { below += 1 }
            guard isCode(below) else { break }
            close = below
        }
        let start = structure.index.range(ofLine: open).location
        return CodeBlock(openLine: open, closeLine: close, info: "", infoRange: NSRange(location: start, length: 0), isIndented: true)
    }

    /// An indented line without its four columns of indentation, and how
    /// many characters that took.
    static func dedented(_ line: Substring) -> (code: Substring, removed: Int) {
        var column = 0
        var index = line.startIndex
        while column < 4, index < line.endIndex, line[index] == " " || line[index] == "\t" {
            column = line[index] == "\t" ? (column / 4 + 1) * 4 : column + 1
            index = line.index(after: index)
        }
        return (line[index...], line.distance(from: line.startIndex, to: index))
    }

    /// The code itself: the lines between the fences, without quote markers.
    @MainActor
    func code(in storage: MarkdownTextStorage) -> String {
        let structure = storage.structure
        let text = storage.text
        if isIndented, let closeLine {
            return (openLine...closeLine).map { line in
                let content = text.substring(with: structure.index.contentRange(ofLine: line, in: text))
                return String(Self.dedented(Substring(content)).code)
            }.joined(separator: "\n")
        }
        let last = (closeLine ?? structure.lineCount) - 1
        guard last > openLine else { return "" }
        return ((openLine + 1)...last).compactMap { line -> String? in
            guard let info = structure.info(forLine: line) else { return nil }
            let characters = structure.characters(of: text, line: line)
            return String(utf16CodeUnits: Array(characters[min(info.contentStart, characters.count)...]),
                          count: characters.count - min(info.contentStart, characters.count))
        }.joined(separator: "\n")
    }
}

extension BlockKind {
    var isFenceStart: Bool {
        if case .fenceStart = self { return true }
        return false
    }
}
