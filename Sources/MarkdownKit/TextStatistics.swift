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

        for scalar in text.unicodeScalars {
            if scalar == "\n" {
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
            if CharacterSet.whitespaces.contains(scalar) {
                endWord()
                continue
            }
            lineHasContent = true
            inWord = true
            if CharacterSet.alphanumerics.contains(scalar) {
                wordHasContent = true
                sentencePending = true
            } else if ".!?。！？".unicodeScalars.contains(scalar), sentencePending {
                sentences += 1
                sentencePending = false
            }
        }
        endWord()
        if lineHasContent, !inParagraph { paragraphs += 1 }
        // Text that trails off without a full stop is still a sentence.
        if sentencePending { sentences += 1 }
        characters = text.count
        charactersExcludingSpaces = text.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.count
    }

    /// At 230 words a minute, rounded up.
    public var readingMinutes: Int { minutes(atWordsPerMinute: 230) }
    /// At 150 words a minute, rounded up.
    public var speakingMinutes: Int { minutes(atWordsPerMinute: 150) }

    private func minutes(atWordsPerMinute rate: Double) -> Int {
        words == 0 ? 0 : max(1, Int((Double(words) / rate).rounded(.up)))
    }
}
