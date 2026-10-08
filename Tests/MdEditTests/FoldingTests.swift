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
