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

    /// AppKit asks for `string` during layout. A Swift override answered it
    /// with a bridged copy of the whole document after every keystroke: 10 MB
    /// copied per key in a 5 MB file.
    @Test("AppKit reads the live text, not a copy made after each edit")
    func stringIsNotCopied() throws {
        let storage = storage("Some *text* here.\n")
        let getter = #selector(getter: NSAttributedString.string)
        let before = try #require(storage.perform(getter)?.takeUnretainedValue() as? NSString)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "More ")
        let after = try #require(storage.perform(getter)?.takeUnretainedValue() as? NSString)
        #expect(before === after)
        #expect(after as String == "More Some *text* here.\n")
        #expect(storage.string == "More Some *text* here.\n")
    }

    /// Restyles of far-apart lines were reported as one edit, merged from
    /// the first to the last, so a caret jumping from the top of a long
    /// document to its bottom had every line between refixed and laid out.
    @Test("Revealing a far-off line reprocesses only the lines that change")
    func farRevealStaysLocal() {
        let storage = storage(String(repeating: "Some *text* here.\n\n", count: 2000))
        storage.revealedLines = 0...0
        final class Processed: NSObject, NSTextStorageDelegate {
            var ranges: [NSRange] = []
            func textStorage(
                _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                range editedRange: NSRange, changeInLength delta: Int
            ) {
                ranges.append(editedRange)
            }
        }
        let processed = Processed()
        storage.delegate = processed

        storage.revealedLines = (storage.structure.lineCount - 2)...(storage.structure.lineCount - 2)
        #expect(!processed.ranges.isEmpty)
        #expect(processed.ranges.allSatisfy { $0.length < 200 })
    }

    /// Styling resets each line's font, taking emoji and CJK off the
    /// fallback fonts that draw them; only the typed character got its
    /// fallback back, so the rest of the line went blank as you typed.
    @Test("Typing on a line keeps its emoji and CJK drawable, and the line above's too")
    func fallbackFontsSurviveTyping() {
        let storage = storage("Hello 😀 日本\nnext 🎉 中文\n")
        func drawable(_ location: Int) -> Bool {
            let font = storage.attribute(.font, at: location, effectiveRange: nil) as! NSFont
            let range = storage.text.rangeOfComposedCharacterSequence(at: location)
            var characters = Array(repeating: UniChar(0), count: range.length)
            storage.text.getCharacters(&characters, range: range)
            var glyphs = Array(repeating: CGGlyph(0), count: range.length)
            return CTFontGetGlyphsForCharacters(font, characters, &glyphs, range.length)
        }
        let emoji = storage.text.range(of: "😀").location
        let kanji = storage.text.range(of: "日").location
        #expect(drawable(emoji) && drawable(kanji))

        // At the end of the first line, then at the start of the second.
        storage.replaceCharacters(in: NSRange(location: storage.text.range(of: "\n").location, length: 0), with: "!")
        #expect(drawable(emoji))
        #expect(drawable(kanji))
        storage.replaceCharacters(in: NSRange(location: storage.text.range(of: "next").location, length: 0), with: "x")
        #expect(drawable(emoji) && drawable(kanji))
        #expect(drawable(storage.text.range(of: "🎉").location) && drawable(storage.text.range(of: "中").location))
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

    @Test("Restyling for a new theme matches styling from scratch")
    func restyleMatchesFreshStyling() {
        let text = PerformanceTests.document(lines: 500)
        let restyled = MarkdownTextStorage(theme: .dark)
        restyled.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        restyled.theme = .light
        let fresh = storage(text)
        let whole = NSRange(location: 0, length: fresh.length)
        #expect(restyled.attributedSubstring(from: whole).isEqual(to: fresh.attributedSubstring(from: whole)))
    }

    @Test("Handing the editor the theme it already has does not restyle")
    func sameThemeIsFree() {
        let storage = storage("# Title\n\nSome **bold** text.\n")
        var edits = 0
        let observer = NotificationCenter.default.addObserver(
            forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
        ) { _ in edits += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        storage.theme = .light
        #expect(edits == 0)
        storage.theme = .dark
        #expect(edits == 1)
    }

    @Test("Moving a revealed range restyles to the same result as starting there")
    func revealChangesMatchFreshStyling() {
        let text = PerformanceTests.document(lines: 300) + "Term\n: definition\n\n$$\nx^2\n$$\n"
        let moved = storage(text)
        let last = moved.structure.lineCount - 1
        // Grow, shrink, jump, overlap and clear, as selections do.
        let steps: [ClosedRange<Int>?] = [5...5, 5...9, 5...40, 30...60, 2...3, 200...last, last...last, 150...250, nil, 0...last, 7...7]
        for step in steps {
            moved.revealedLines = step
            let fresh = storage(text)
            fresh.revealedLines = step
            let whole = NSRange(location: 0, length: fresh.length)
            #expect(moved.attributedSubstring(from: whole).isEqual(to: fresh.attributedSubstring(from: whole)), "after \(String(describing: step))")
        }
    }

    /// Every keystroke in a table laid out all its rows again, measuring
    /// every cell: tens of milliseconds in a long one.
    @Test("Typing in a table cell restyles only its row while the columns stay put, and ends as a full restyle would")
    func tableRowAlone() {
        let rows = (0..<40).map { "| row \($0) | two |" }.joined(separator: "\n")
        let storage = storage("| a much wider header cell | b |\n|---|---|\n" + rows + "\n\nafter\n")
        let probe = NSAttributedString.Key("probe")
        func far() -> NSRange { storage.characterRange(forLines: 32...32) }
        storage.addAttribute(probe, value: true, range: far())
        func matchesFresh() -> Bool {
            storage.removeAttribute(probe, range: NSRange(location: 0, length: storage.length))
            let fresh = self.storage(storage.string)
            let whole = NSRange(location: 0, length: fresh.length)
            return storage.attributedSubstring(from: whole).isEqual(to: fresh.attributedSubstring(from: whole))
        }

        let cell = (storage.string as NSString).range(of: "row 5 ").location + 5
        storage.replaceCharacters(in: NSRange(location: cell, length: 0), with: "x")
        #expect(storage.attribute(probe, at: far().location, effectiveRange: nil) != nil)
        #expect(matchesFresh())

        // Wider than the header, the cell moves the column: every row follows.
        storage.addAttribute(probe, value: true, range: far())
        storage.replaceCharacters(in: NSRange(location: cell, length: 0), with: String(repeating: "w", count: 40))
        #expect(storage.attribute(probe, at: far().location, effectiveRange: nil) == nil)
        #expect(matchesFresh())
    }

    /// Whether a paragraph is a definition list was decided by walking all
    /// of it on each keystroke; now the lines beside the edit usually settle
    /// it. Either way the answer must be the parser's.
    @Test("A paragraph is styled as a definition list exactly when it reads as one")
    func definitionListDecision() throws {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<300 {
            let count = Int.random(in: 1...6, using: &generator)
            let lines = (0..<count).map { index in Bool.random(using: &generator) ? ": d\(index)" : "t\(index)" }
            let storage = storage("before\n\n" + lines.joined(separator: "\n") + "\n\nafter\n")
            let isList = DefinitionList(lines: lines) != nil
            // Each line asked in turn, as the caret moving through it would.
            for line in 2..<(2 + count) {
                storage.revealedLines = line...line
                storage.revealedLines = nil
            }
            let first = (storage.string as NSString).range(of: lines[0]).location
            let font = try #require(storage.attribute(.font, at: first, effectiveRange: nil) as? NSFont)
            let isTerm = font.fontDescriptor.symbolicTraits.contains(.bold)
            #expect(isTerm == (isList && !lines[0].hasPrefix(":")), "\(lines)")
        }
    }

    @Test("Every entry of a long definition list is styled as one, and long prose is not")
    func longDefinitionList() throws {
        let entries = (0..<200).map { "Term \($0)\n: Its definition." }.joined(separator: "\n")
        let prose = (0..<200).map { "Line \($0) of prose, wrapped by hand." }.joined(separator: "\n")
        let storage = storage(entries + "\n\n" + prose + "\n")
        let text = storage.string as NSString
        for term in ["Term 0", "Term 199"] {
            let font = try #require(storage.attribute(.font, at: text.range(of: term).location, effectiveRange: nil) as? NSFont)
            #expect(font.fontDescriptor.symbolicTraits.contains(.bold), "\(term)")
        }
        let lastMarker = text.range(of: ": Its", options: .backwards).location
        #expect(storage.attribute(.mdConcealed, at: lastMarker, effectiveRange: nil) != nil)
        let line = try #require(storage.attribute(.font, at: text.range(of: "Line 150").location, effectiveRange: nil) as? NSFont)
        #expect(!line.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("Putting a document in an editor keeps its styling")
    func editorKeepsStyling() throws {
        // In the theme the editor will pick, light or dark as the Mac is.
        let document = Document(text: "Intro.\n\nSome **bold** and `code`.\n", theme: .current(for: NSApplication.shared.effectiveAppearance))
        let storage = document.storage
        let whole = NSRange(location: 0, length: storage.length)
        let styled = storage.attributedSubstring(from: whole)
        let editor = EditorViewController(textStorage: storage, undoManager: document.undoManager)
        _ = editor.view
        // The caret sits on the first line, which shows as written; the rest is as styled.
        let rest = NSRange(location: 7, length: storage.length - 7)
        #expect(storage.attributedSubstring(from: rest).isEqual(to: styled.attributedSubstring(from: rest)))
        let bold = try #require(storage.attribute(.font, at: (storage.string as NSString).range(of: "bold").location, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        let code = try #require(storage.attribute(.font, at: (storage.string as NSString).range(of: "code").location, effectiveRange: nil) as? NSFont)
        #expect(code.isFixedPitch)
        _ = whole
    }

    @Test("Markers styled from the cache match styling from scratch through mode and theme changes")
    func markerCacheFollowsModeAndTheme() {
        let text = PerformanceTests.document(lines: 200)
        let changed = storage(text)
        changed.revealedLines = 3...8
        changed.sourceMode = true
        changed.theme = .dark
        changed.sourceMode = false
        let fresh = MarkdownTextStorage(theme: .dark)
        fresh.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        fresh.revealedLines = 3...8
        let whole = NSRange(location: 0, length: fresh.length)
        #expect(changed.attributedSubstring(from: whole).isEqual(to: fresh.attributedSubstring(from: whole)))
    }

    @Test("Asking an empty document for an attribute answers nothing rather than raising")
    func emptyAttributeLookup() {
        let storage = storage("")
        var range = NSRange(location: 5, length: 5)
        #expect(storage.attribute(.font, at: 0, effectiveRange: &range) == nil)
        #expect(range == NSRange(location: 0, length: 0))
        #expect(storage.attribute(.font, at: 0, longestEffectiveRange: &range, in: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("A row splits into cells at unescaped pipes, without their spaces")
    func tableRowSplit() {
        let split = TableRowSplit(Array("| a | b\\|c |  |".utf16), from: 0)
        #expect(split.leadingPipe)
        #expect(split.pipes == [0, 4, 11, 14])
        #expect(split.cells == [NSRange(location: 2, length: 1), NSRange(location: 6, length: 4), NSRange(location: 14, length: 0)])

        let bare = TableRowSplit(Array("a | b".utf16), from: 0)
        #expect(!bare.leadingPipe)
        #expect(bare.cells == [NSRange(location: 0, length: 1), NSRange(location: 4, length: 1)])
    }

    @Test("A table is drawn as a grid of shared columns, wrapping when too wide, or as source when far too wide or in source mode")
    func tableGrid() throws {
        let storage = storage("| A | Longer header |\n| --- | --- |\n| wide cell | x |\n")
        let header = try #require(storage.attribute(.mdTableRow, at: 0, effectiveRange: nil) as? TableGrid)
        let row = try #require(storage.attribute(.mdTableRow, at: storage.structure.index.range(ofLine: 2).location, effectiveRange: nil) as? TableGrid)
        #expect(header.isHeader && !header.isLast)
        #expect(row.isLast && !row.isHeader)
        #expect(header.edges == row.edges)
        #expect(header.edges.count == 3)
        // The delimiter row folds away, and the cells' padding is concealed.
        #expect(storage.attribute(.mdConcealed, at: storage.structure.index.range(ofLine: 1).location, effectiveRange: nil) != nil)
        #expect(storage.attribute(.mdConcealed, at: 1, effectiveRange: nil) != nil)

        // Too wide for the column, the cells wrap: a narrower grid, the same font.
        let natural = header.indent + (header.edges.last ?? 0)
        let fullSize = try #require(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont).pointSize
        storage.maxImageWidth = natural * 0.85
        storage.restyleTablesChangingFit()
        let wrapped = try #require(storage.attribute(.mdTableRow, at: 0, effectiveRange: nil) as? TableGrid)
        #expect(wrapped.wrapping != nil)
        #expect(wrapped.indent + (wrapped.edges.last ?? 0) <= natural * 0.85)
        #expect(abs(wrapped.naturalWidth - natural) < 0.5)
        #expect(try #require(storage.attribute(.font, at: 2, effectiveRange: nil) as? NSFont).pointSize == fullSize)
        // Given room again, it stops wrapping.
        storage.maxImageWidth = 720
        storage.restyleTablesChangingFit()
        #expect(try #require(storage.attribute(.mdTableRow, at: 0, effectiveRange: nil) as? TableGrid).wrapping == nil)

        // Narrower than its longest word, it shows as source.
        storage.maxImageWidth = 40
        storage.restyleTablesChangingFit()
        #expect(storage.attribute(.mdTableRow, at: 0, effectiveRange: nil) is CGFloat)
        storage.maxImageWidth = 720
        storage.restyleTablesChangingFit()
        #expect(storage.attribute(.mdTableRow, at: 0, effectiveRange: nil) is TableGrid)
        storage.sourceMode = true
        #expect(storage.attribute(.mdTableRow, at: 0, effectiveRange: nil) as? Bool == true)
    }
}
