import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Rich editing")
struct RichEditingTests {
    /// A small PNG on disk, so image loading has something real to read.
    private func writeImage(width: Int, height: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let url = directory.appendingPathComponent("pic.png")
        try #require(rep.representation(using: .png, properties: [:])).write(to: url)
        return url
    }

    @Test("A line holding only an image reserves room for it once loaded")
    func imageReservesSpace() async throws {
        let image = try writeImage(width: 200, height: 100)
        let storage = MarkdownTextStorage(theme: .light)
        storage.baseURL = image.deletingLastPathComponent().appendingPathComponent("doc.md")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "intro\n\n![alt](pic.png)\n")

        // Loading is asynchronous; give it a moment.
        for _ in 0..<50 where storage.attribute(.mdImage, at: 7, effectiveRange: nil) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let inline = try #require(storage.attribute(.mdImage, at: 7, effectiveRange: nil) as? InlineImage)
        #expect(inline.size == CGSize(width: 200, height: 100))
        let style = try #require(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.minimumLineHeight >= 100)
        // And layout honours it: the image line's fragment is tall enough.
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 600, height: 10_000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.ensureLayout(for: container)
        let glyph = layoutManager.glyphIndexForCharacter(at: 9)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        #expect(fragment.height >= 100, "fragment: \(fragment)")
        // Text beside an image keeps it inline.
        #expect(storage.attribute(.mdImage, at: 0, effectiveRange: nil) == nil)
    }

    @Test("An image wrapped in a link still shows as an image")
    func linkedImage() async throws {
        let image = try writeImage(width: 120, height: 30)
        let storage = MarkdownTextStorage(theme: .light)
        storage.baseURL = image.deletingLastPathComponent().appendingPathComponent("doc.md")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "[![badge](pic.png)](https://example.com)\n")

        for _ in 0..<50 where storage.attribute(.mdImage, at: 0, effectiveRange: nil) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let inline = try #require(storage.attribute(.mdImage, at: 0, effectiveRange: nil) as? InlineImage)
        #expect(inline.size == CGSize(width: 120, height: 30))
    }

    @Test("A reference definition hides until the caret is on it")
    func referenceDefinitionHides() throws {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "See [it][a].\n\n[a]: https://example.com \"Title\"\n")
        let definition = (storage.string as NSString).range(of: "[a]:").location
        #expect(storage.attribute(.mdConcealed, at: definition, effectiveRange: nil) != nil)
        // The reference still resolves.
        #expect(storage.attribute(.mdConcealed, at: 0, effectiveRange: nil) == nil)

        storage.revealedLines = 2...2
        #expect(storage.attribute(.mdConcealed, at: definition, effectiveRange: nil) == nil)
    }

    @Test("A hidden definition between blank lines leaves a single gap")
    func referenceDefinitionGap() throws {
        let storage = MarkdownTextStorage(theme: .light)
        // Lines: 0 text, 1 blank, 2 definition, 3 blank, 4 text.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "One.\n\n[a]: https://example.com\n\nTwo.\n")
        func hidden(_ line: Int) -> Bool {
            let start = storage.string.components(separatedBy: "\n")[..<line].reduce(0) { $0 + ($1 as NSString).length + 1 }
            return storage.attribute(.mdConcealed, at: start, effectiveRange: nil) != nil
        }
        #expect(hidden(1) && hidden(2) && !hidden(3))

        // With the caret on the definition, both blanks come back.
        storage.revealedLines = 2...2
        #expect(!hidden(1) && !hidden(2))

        // Text right below the definition needs the blank above it.
        storage.revealedLines = 0...0
        storage.replaceCharacters(in: NSRange(location: (storage.string as NSString).length - 6, length: 1), with: "")
        #expect(storage.string == "One.\n\n[a]: https://example.com\nTwo.\n")
        #expect(!hidden(1))
    }

    @Test("Clicking a task box toggles it in the source")
    func toggleTask() throws {
        let storage = MarkdownTextStorage(theme: .light)
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "- [ ] one\n- [x] two")
        #expect(textView.toggleTaskBox(at: 3))
        #expect(storage.string == "- [x] one\n- [x] two")
        #expect(textView.toggleTaskBox(at: 13))
        #expect(storage.string == "- [x] one\n- [ ] two")
        // Anywhere else, a click is just a click.
        #expect(!textView.toggleTaskBox(at: 7))
    }
}

@MainActor
@Suite("Typing and pasting")
struct TypingTests {
    private func makeTextView(_ text: String) -> (MarkdownTextView, MarkdownInputHandler) {
        let storage = MarkdownTextStorage(theme: .light)
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 400, height: 1000))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 400), textContainer: container)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return (textView, MarkdownInputHandler(storage: storage))
    }

    /// Types one character the way the editor does: the handler first, then plain insertion.
    private func type(_ character: String, _ textView: MarkdownTextView, _ input: MarkdownInputHandler) {
        let range = textView.selectedRange()
        if !input.handleInsertion(of: character, in: textView, range: range) {
            textView.insertText(character, replacementRange: range)
        }
    }

    @Test("Brackets close themselves and are typed over")
    func autoPair() {
        UserDefaults.standard.removeObject(forKey: MarkdownInputHandler.autoPairDefaultsKey)
        let (textView, input) = makeTextView("")
        for character in ["(", "a", ")"] { type(character, textView, input) }
        #expect(textView.string == "(a)")
        #expect(textView.selectedRange().location == 3)

        // A task box types naturally.
        let (task, taskInput) = makeTextView("- ")
        task.setSelectedRange(NSRange(location: 2, length: 0))
        for character in ["[", " ", "]", " "] { type(character, task, taskInput) }
        #expect(task.string == "- [ ] ")

        // Three backticks make a fence, not three pairs.
        let (fence, fenceInput) = makeTextView("")
        for _ in 0..<3 { type("`", fence, fenceInput) }
        #expect(fence.string == "```")

        // No pairing right before a word.
        let (word, wordInput) = makeTextView("word")
        word.setSelectedRange(NSRange(location: 0, length: 0))
        type("(", word, wordInput)
        #expect(word.string == "(word")
    }

    @Test("Backspace inside an empty pair removes both halves")
    func deletePair() {
        let (textView, input) = makeTextView("x()")
        textView.setSelectedRange(NSRange(location: 2, length: 0))
        #expect(input.handleCommand(#selector(NSResponder.deleteBackward(_:)), in: textView))
        #expect(textView.string == "x")
    }

    @Test("Pasted images link relative to the document, saved data goes in assets")
    func imageImport() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditImport-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let document = folder.appendingPathComponent("notes.md")

        #expect(ImageImporter.markdown(forImageAt: folder.appendingPathComponent("img/a b.png"), documentURL: document)
            == "![a b](<img/a b.png>)")
        #expect(ImageImporter.destination(for: URL(fileURLWithPath: "/elsewhere/x.png"), documentURL: document)
            == "/elsewhere/x.png")

        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        let date = Date(timeIntervalSince1970: 0)
        let first = try ImageImporter.save(image, besideDocument: document, date: date)
        let second = try ImageImporter.save(image, besideDocument: document, date: date)
        #expect(first.deletingLastPathComponent().lastPathComponent == "assets")
        #expect(first != second)
        #expect(FileManager.default.fileExists(atPath: second.path))
        #expect(throws: ImageImporter.ImportError.self) { try ImageImporter.save(image, besideDocument: nil) }
    }

    @Test("Source mode shows every marker and drops the bullet substitution")
    func sourceMode() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Title\n- item **bold**")
        storage.revealedLines = nil
        #expect(storage.attribute(.mdConcealed, at: 0, effectiveRange: nil) != nil)
        #expect(storage.attribute(.mdMarker, at: 8, effectiveRange: nil) != nil)
        storage.sourceMode = true
        #expect(storage.attribute(.mdConcealed, at: 0, effectiveRange: nil) == nil)
        #expect(storage.attribute(.mdConcealed, at: 15, effectiveRange: nil) == nil)
        #expect(storage.attribute(.mdMarker, at: 8, effectiveRange: nil) == nil)
    }
}
