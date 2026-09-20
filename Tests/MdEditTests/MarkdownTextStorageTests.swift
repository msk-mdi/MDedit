import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("MarkdownTextStorage")
struct MarkdownTextStorageTests {
    private func storage(_ text: String) -> MarkdownTextStorage {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return storage
    }

    /// The crash this test exists for: type a line, press Return, press
    /// Backspace. The caret's revealed line is then one past the end of a
    /// document that just shrank, and forming that range traps.
    @Test("A revealed line left past the end of a shrunken document is clamped")
    func revealedLineSurvivesShrinking() {
        let storage = storage("hello\n")
        #expect(storage.structure.lineCount == 2)

        storage.revealedLines = 1...1
        // Delete the newline: the document is now one line, and 1...1 is stale.
        storage.replaceCharacters(in: NSRange(location: 5, length: 1), with: "")
        #expect(storage.structure.lineCount == 1)

        storage.revealedLines = 0...0
        #expect(storage.revealedLines == 0...0)
    }

    @Test("Clamping orders its bounds before forming a range")
    func clamping() {
        let storage = storage("one\ntwo\nthree")
        #expect(storage.clampedLineRange(0...0) == 0...0)
        #expect(storage.clampedLineRange(1...2) == 1...2)
        // Entirely past the end collapses onto the last line. This is the case
        // that used to trap: the old code clamped only the upper bound, forming
        // `9...2`.
        #expect(storage.clampedLineRange(9...9) == 2...2)
        #expect(storage.clampedLineRange(1...9) == 1...2)
        #expect(storage.clampedLineRange(-3...1) == 0...1)
    }

    @Test("Deleting the whole document leaves styling intact")
    func deleteEverything() {
        let storage = storage("# title\n\n- a\n- b\n")
        storage.revealedLines = 3...3
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        storage.revealedLines = 0...0
        #expect(storage.length == 0)
        #expect(storage.structure.lineCount == 1)
    }

    @Test("Opening a fence restyles the lines below it")
    func fenceRestyle() {
        let storage = storage("text\nmore\n")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```bash\n")
        #expect(storage.structure.info(forLine: 1)?.kind == .codeLine)
    }

    /// Typing a fence's language one character at a time, which is how the bug
    /// was reported.
    @Test("Typing ```bash character by character")
    func typingAFence() {
        let storage = storage("")
        for character in "```bash" {
            storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: String(character))
            storage.revealedLines = 0...0
        }
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n")
        storage.revealedLines = 1...1
        storage.replaceCharacters(in: NSRange(location: storage.length - 1, length: 1), with: "")
        storage.revealedLines = 0...0
        #expect(storage.string == "```bash")
    }
}
