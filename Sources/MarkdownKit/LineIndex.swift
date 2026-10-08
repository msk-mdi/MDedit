import Foundation

/// Line starts over a text, in UTF-16 offsets to match `NSTextStorage`.
///
/// Rebuilt incrementally: an edit rescans only the lines it touched and shifts
/// the offsets after them, so a keystroke costs a line, not a document.
public struct LineIndex: Equatable {
    /// UTF-16 offset of the first character of each line. Always starts with 0.
    public private(set) var starts: [Int]
    /// Total length of the text in UTF-16 units.
    public private(set) var length: Int

    public init(text: NSString) {
        starts = [0]
        length = text.length
        // Read in chunks: a message per character is slow on long documents.
        let chunk = 16_384
        var buffer = [UInt16](repeating: 0, count: chunk)
        var offset = 0
        while offset < length {
            let count = min(chunk, length - offset)
            buffer.withUnsafeMutableBufferPointer { pointer in
                text.getCharacters(pointer.baseAddress!, range: NSRange(location: offset, length: count))
                for index in 0..<count where pointer[index] == 0x0A {  // \n
                    starts.append(offset + index + 1)
                }
            }
            offset += count
        }
    }

    public var count: Int { starts.count }

    /// Range of the line including its trailing newline, if any.
    public func range(ofLine line: Int) -> NSRange {
        let start = starts[line]
        let end = line + 1 < starts.count ? starts[line + 1] : length
        return NSRange(location: start, length: end - start)
    }

    /// Range of the line's characters, excluding the trailing newline.
    public func contentRange(ofLine line: Int, in text: NSString) -> NSRange {
        var range = self.range(ofLine: line)
        if range.length > 0, text.character(at: NSMaxRange(range) - 1) == 0x0A {
            range.length -= 1
        }
        return range
    }

    /// Index of the line containing `offset`.
    public func line(at offset: Int) -> Int {
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// Updates the index after an edit, returning the range of lines whose
    /// contents changed.
    ///
    /// - Parameters:
    ///   - editedRange: the range of the *new* text that was replaced into place.
    ///   - delta: change in total length.
    ///   - text: the text after the edit.
    @discardableResult
    public mutating func update(
        editedRange: NSRange,
        changeInLength delta: Int,
        text: NSString
    ) -> ClosedRange<Int> {
        let firstLine = line(at: editedRange.location)

        // The last line affected, expressed in pre-edit offsets.
        let oldEnd = NSMaxRange(editedRange) - delta
        let lastOldLine = line(at: max(oldEnd, starts[firstLine]))

        // Rescan from the start of the first affected line through the end of
        // the line the edit now ends on.
        let scanStart = starts[firstLine]
        var scanEnd = NSMaxRange(editedRange)
        while scanEnd < text.length, scanEnd > 0, text.character(at: scanEnd - 1) != 0x0A {
            scanEnd += 1
        }

        var replacement: [Int] = []
        var index = scanStart
        while index < scanEnd {
            if text.character(at: index) == 0x0A, index + 1 <= text.length {
                replacement.append(index + 1)
            }
            index += 1
        }

        // Lines after the rescanned region keep their identity, shifted by
        // delta, in place rather than through copies of the whole array.
        var tailStart = min(lastOldLine + 1, starts.count)
        for line in tailStart..<starts.count { starts[line] += delta }
        // Drop any shifted starts that the rescan already produced (the tail
        // is sorted, so they lead it). A newline ending the rescanned region
        // yields a start equal to the first tail entry, so that one goes too.
        while tailStart < starts.count, starts[tailStart] < scanEnd { tailStart += 1 }
        if let lastRescanned = replacement.last, tailStart < starts.count, starts[tailStart] == lastRescanned {
            tailStart += 1
        }
        starts.replaceSubrange((firstLine + 1)..<max(firstLine + 1, tailStart), with: replacement)
        length = text.length

        // The rescanned region ends at a line boundary when its last newline is
        // the final character, in which case the line starting there was not
        // itself rescanned and is unchanged.
        var lastNewLine = firstLine + replacement.count
        if replacement.last == scanEnd { lastNewLine -= 1 }
        return firstLine...max(firstLine, min(lastNewLine, starts.count - 1))
    }
}
