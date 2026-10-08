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

    /// The block holding a line, if the line is part of one.
    @MainActor
    static func containing(line: Int, in storage: MarkdownTextStorage) -> CodeBlock? {
        let structure = storage.structure
        guard let info = structure.info(forLine: line) else { return nil }
        var open = line
        switch info.kind {
        case .fenceStart:
            break
        case .codeLine, .fenceEnd:
            while open > 0, structure.info(forLine: open)?.kind.isFenceStart == false { open -= 1 }
            guard structure.info(forLine: open)?.kind.isFenceStart == true else { return nil }
        default:
            return nil
        }
        var close: Int?
        var cursor = open + 1
        while let next = structure.info(forLine: cursor) {
            if next.kind == .fenceEnd { close = cursor; break }
            guard next.kind == .codeLine else { break }
            cursor += 1
        }

        // The info string follows the run of backticks or tildes.
        let text = storage.string as NSString
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

    /// The code itself: the lines between the fences, without quote markers.
    @MainActor
    func code(in storage: MarkdownTextStorage) -> String {
        let structure = storage.structure
        let text = storage.string as NSString
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
