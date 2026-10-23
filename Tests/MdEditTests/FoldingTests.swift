import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Folding")
struct FoldingTests {
    private func makeStorage(_ text: String) -> (MarkdownTextStorage, MarkdownLayoutManager, NSTextContainer) {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 500, height: 100_000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return (storage, layoutManager, container)
    }

    private let document = "# One\nalpha\n\n## Sub\nbeta\n\n# Two\ngamma\n"

    @Test("A section runs to the next heading of its level, without trailing blanks")
    func sections() {
        let (storage, _, _) = makeStorage(document)
        #expect(storage.foldableRange(forHeadingLine: 0) == 1...4)
        #expect(storage.foldableRange(forHeadingLine: 3) == 4...4)
        #expect(storage.foldableRange(forHeadingLine: 6) == 7...7)
        #expect(storage.foldableRange(forHeadingLine: 1) == nil)
        #expect(storage.enclosingHeading(ofLine: 4) == 3)
        #expect(storage.enclosingHeading(ofLine: 2) == 0)
        #expect(storage.enclosingHeading(ofLine: 7) == 6)
    }

    /// Sections were found one heading at a time, each walking the headings
    /// after it, and Fold All restyled once per heading.
    @Test("Every section at once matches each found alone, and folding them all is quick")
    func allSections() {
        let levels = [1, 2, 3, 3, 2, 1, 2, 4, 3, 1]
        let text = (0..<1_000).map { index in
            String(repeating: "#", count: levels[index % levels.count]) + " Heading \(index)\n" + (index % 7 == 0 ? "" : "body\n\n")
        }.joined() + "Setext\n===\ntail\n"
        let (storage, _, _) = makeStorage(text)
        let sections = storage.foldableRanges()
        for heading in storage.headings {
            #expect(sections[heading.line] == storage.foldableRange(forHeadingLine: heading.line))
        }

        let start = ContinuousClock.now
        storage.fold(headingLines: storage.headings.map(\.line))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .seconds(1), "\(elapsed)")
        #expect(storage.foldedHeadings == Set(sections.compactMap { $0.value == nil ? nil : $0.key }))
        let separately = makeStorage(text).0
        for heading in sections.keys where sections[heading]! != nil { separately.setFolded(true, headingLine: heading) }
        #expect((0..<storage.structure.lineCount).filter(storage.isHidden) == (0..<separately.structure.lineCount).filter(separately.isHidden))
    }

    @Test("Folded lines take no room and draw nothing")
    func layout() {
        let (storage, layoutManager, container) = makeStorage(document)
        layoutManager.ensureLayout(for: container)
        let before = layoutManager.usedRect(for: container).height
        #expect(storage.setFolded(true, headingLine: 0))
        layoutManager.ensureLayout(for: container)
        let after = layoutManager.usedRect(for: container).height
        // Four lines of body text and a heading's worth of space are gone.
        #expect(after < before - 60)
        #expect(storage.attribute(.mdFolded, at: 6, effectiveRange: nil) != nil)
        #expect(layoutManager.foldIndicatorRect(forHeadingLine: 0) != nil)
        storage.setFolded(false, headingLine: 0)
        layoutManager.ensureLayout(for: container)
        #expect(abs(layoutManager.usedRect(for: container).height - before) < 0.5)
        #expect(storage.attribute(.mdFolded, at: 6, effectiveRange: nil) == nil)
    }

    @Test("Edits above a fold move it; edits inside it open it; edits below leave it")
    func edits() {
        let (storage, _, _) = makeStorage(document)
        storage.setFolded(true, headingLine: 6)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "intro\n\n")
        #expect(storage.foldedHeadings == [8])
        #expect(storage.isHidden(line: 9))

        storage.setFolded(true, headingLine: 2)
        // Typing below the folds keeps both.
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "end")
        #expect(storage.foldedHeadings == [2, 8])
        // Typing inside the first section opens it.
        let alpha = (storage.string as NSString).range(of: "alpha")
        storage.replaceCharacters(in: NSRange(location: alpha.location, length: 0), with: "x")
        #expect(storage.foldedHeadings == [8])
        #expect(!storage.isHidden(line: 3))
    }

    /// Edits restyle only the lines whose folded state changed, and keep
    /// the headings when they touch none. Through any edits, a line is
    /// styled folded exactly when it is hidden, and the headings are the
    /// ones a fresh look finds.
    @Test("Folds and headings kept through edits stay true", arguments: [3, 4, 5])
    func randomEdits(seed: UInt64) {
        var random = SeededGenerator(state: seed)
        let section = "# Top\nalpha **bold**\n\n## Sub\nbeta\n\nSetext\n---\ngamma\n\n"
        let (storage, _, _) = makeStorage(String(repeating: section, count: 12))
        let snippets = ["x", "\n", "# ", "## Head\n", "\n\n", "---\n", "**", "text\n"]
        for step in 0..<300 {
            // Keep a few sections folded as the text changes under them.
            if step % 10 == 0 {
                for heading in storage.headings.map(\.line) where Bool.random(using: &random) {
                    storage.setFolded(true, headingLine: heading)
                }
            }
            let length = storage.length
            if Int.random(in: 0..<3, using: &random) == 0, length > 0 {
                let location = Int.random(in: 0..<length, using: &random)
                storage.replaceCharacters(in: NSRange(location: location, length: min(Int.random(in: 1...6, using: &random), length - location)), with: "")
            } else {
                let snippet = snippets.randomElement(using: &random)!
                storage.replaceCharacters(in: NSRange(location: Int.random(in: 0...length, using: &random), length: 0), with: snippet)
            }

            #expect(storage.headings == storage.structure.headings(in: storage.string as NSString), "step \(step)")
            for line in 0..<storage.structure.lineCount {
                let range = storage.structure.index.range(ofLine: line)
                guard range.length > 0 else { continue }
                let folded = storage.attribute(.mdFolded, at: range.location, effectiveRange: nil) != nil
                guard folded == storage.isHidden(line: line) else {
                    Issue.record("line \(line) folded \(folded), hidden \(storage.isHidden(line: line)), step \(step)")
                    return
                }
            }
        }
    }

    @Test("A heading that stops being one loses its fold")
    func headingRemoved() {
        let (storage, _, _) = makeStorage(document)
        storage.setFolded(true, headingLine: 6)
        let two = (storage.string as NSString).range(of: "# Two")
        storage.replaceCharacters(in: NSRange(location: two.location, length: 2), with: "")
        #expect(storage.foldedHeadings.isEmpty)
        #expect(storage.attribute(.mdFolded, at: storage.length - 2, effectiveRange: nil) == nil)
    }

    @Test("Moving the caret into a fold opens it; commands fold around the caret")
    func caretAndCommands() {
        let document = Document(text: self.document, theme: .light)
        let editor = EditorViewController(textStorage: document.storage)
        _ = editor.view
        let beta = (document.text as NSString).range(of: "beta").location
        editor.textView.setSelectedRange(NSRange(location: beta, length: 0))
        editor.foldSection()
        #expect(document.storage.foldedHeadings == [3])
        // The caret moved to the heading so the fold could close.
        #expect(document.storage.line(at: editor.textView.selectedRange().location) == 3)

        editor.textView.setSelectedRange(NSRange(location: beta, length: 0))
        #expect(document.storage.foldedHeadings.isEmpty)

        editor.foldAll()
        #expect(document.storage.foldedHeadings == [0, 3, 6])
        #expect(document.storage.line(at: editor.textView.selectedRange().location) == 0)
        editor.unfoldAll()
        #expect(document.storage.foldedHeadings.isEmpty)
    }
}

/// A deterministic generator, so a failure replays.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state ^ (state >> 33)
    }
}
