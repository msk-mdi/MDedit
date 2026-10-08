import Foundation

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

    public init(text: NSString, extensions: SyntaxExtensions = .all) {
        self.extensions = extensions
        index = LineIndex(text: text)
        lines = []
        lines.reserveCapacity(index.count)
        var carry = CarryState.start(extensions: extensions)
        for line in 0..<index.count {
            let info = BlockParser.parse(line: Self.characters(of: text, index: index, line: line), carry: carry)
            lines.append(info)
            carry = info.state
        }
    }

    public var lineCount: Int { index.count }

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

        let first = touched.lowerBound
        let lastTouched = touched.upperBound

        // Only the reparsed run is rebuilt; lines either side stay in place.
        let prefix = min(first, oldLineCount)
        var fresh: [LineInfo] = []
        // A shrinking document can leave `first` past the end of the old array.
        while prefix + fresh.count < first {
            fresh.append(lines.last ?? BlockParser.parse(line: [], carry: .start(extensions: extensions)))
        }

        var carry = if first == 0 {
            CarryState.start(extensions: extensions)
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
        var carry = CarryState.start(extensions: extensions)
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
