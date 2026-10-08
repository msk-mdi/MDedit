import Foundation

/// Counts for the status bar and the statistics popover.
///
/// A word is a run of non-space characters holding at least one letter or
/// digit, so a list's `-`, a heading's `#` or a rule's `***` are not words.
public struct TextStatistics: Equatable, Sendable {
    public var words = 0
    public var characters = 0
    public var charactersExcludingSpaces = 0
    /// Runs of non-blank lines.
    public var paragraphs = 0
    public var sentences = 0
    public var lines = 0

    public init(_ text: String) {
        var inWord = false
        var wordHasContent = false
        var lineHasContent = false
        var inParagraph = false
        var sentencePending = false
        lines = text.isEmpty ? 0 : 1

        func endWord() {
            if inWord, wordHasContent { words += 1 }
            inWord = false
            wordHasContent = false
        }

        // One pass. ASCII, nearly all of a markdown file, is classified
        // inline; `CharacterSet` lookups are kept for the rest.
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if value == 0x0A {
                endWord()
                if lineHasContent {
                    if !inParagraph { paragraphs += 1 }
                    inParagraph = true
                } else {
                    inParagraph = false
                }
                lineHasContent = false
                lines += 1
                continue
            }
            let isWhitespace: Bool
            let isAlphanumeric: Bool
            if value < 0x80 {
                isWhitespace = value == 0x20 || value == 0x09
                isAlphanumeric = (value >= 0x30 && value <= 0x39) || ((value | 0x20) >= 0x61 && (value | 0x20) <= 0x7A)
                if !isWhitespace, value != 0x0B, value != 0x0C, value != 0x0D { charactersExcludingSpaces += 1 }
            } else {
                isWhitespace = CharacterSet.whitespaces.contains(scalar)
                isAlphanumeric = !isWhitespace && CharacterSet.alphanumerics.contains(scalar)
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { charactersExcludingSpaces += 1 }
            }
            if isWhitespace {
                endWord()
                continue
            }
            lineHasContent = true
            inWord = true
            if isAlphanumeric {
                wordHasContent = true
                sentencePending = true
            } else if Self.sentenceEnds.contains(value), sentencePending {
                sentences += 1
                sentencePending = false
            }
        }
        endWord()
        if lineHasContent, !inParagraph { paragraphs += 1 }
        // Text that trails off without a full stop is still a sentence.
        if sentencePending { sentences += 1 }
        characters = text.count
    }

    /// `.!?。！？`
    private static let sentenceEnds: Set<UInt32> = [0x2E, 0x21, 0x3F, 0x3002, 0xFF01, 0xFF1F]

    /// At 230 words a minute, rounded up.
    public var readingMinutes: Int { minutes(atWordsPerMinute: 230) }
    /// At 150 words a minute, rounded up.
    public var speakingMinutes: Int { minutes(atWordsPerMinute: 150) }

    private func minutes(atWordsPerMinute rate: Double) -> Int {
        words == 0 ? 0 : max(1, Int((Double(words) / rate).rounded(.up)))
    }
}
