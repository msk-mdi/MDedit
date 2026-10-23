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

    /// Every edit the storage makes, by character range.
    private final class EditRecorder: NSObject, NSTextStorageDelegate {
        var ranges: [NSRange] = []

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            ranges.append(editedRange)
        }
    }

    @Test("An arriving image restyles its own line, wherever edits moved it")
    func imageArrivalIsLocal() async throws {
        let image = try writeImage(width: 200, height: 100)
        let storage = MarkdownTextStorage(theme: .light)
        storage.baseURL = image.deletingLastPathComponent().appendingPathComponent("doc.md")
        let filler = String(repeating: "A paragraph of filler text.\n\n", count: 200)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "intro\n\n![alt](pic.png)\n\n" + filler)
        // Lines arrive above the image before it does.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new\nlines\n")
        let line = (storage.string as NSString).range(of: "![alt]")
        #expect(storage.attribute(.mdAwaiting, at: line.location, effectiveRange: nil) != nil)

        let edits = EditRecorder()
        storage.delegate = edits
        for _ in 0..<50 where storage.attribute(.mdImage, at: line.location, effectiveRange: nil) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(storage.attribute(.mdImage, at: line.location, effectiveRange: nil) is InlineImage)
        #expect(storage.attribute(.mdAwaiting, at: line.location, effectiveRange: nil) == nil)
        #expect(!edits.ranges.isEmpty)
        for range in edits.ranges {
            #expect(range.length < 100, "restyled \(range) of \(storage.length)")
        }
    }

    /// A triple-click selects a line and its newline, so the selection ends
    /// at the start of the next line, which was revealed too.
    @Test("Selecting a whole line reveals that line, not the one after")
    func tripleClickRevealsOneLine() {
        let document = Document(text: "# One\n# Two\n", theme: .light)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 6))
        #expect(document.storage.revealedLines == 0...0)
        editor.textView.setSelectedRange(NSRange(location: 0, length: 7))
        #expect(document.storage.revealedLines == 0...1)
    }

    /// Lines showing images that are never read, so nothing arrives but
    /// what the test posts.
    private func storageAwaitingImages(_ names: [String]) -> (MarkdownTextStorage, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditAwaiting-\(UUID().uuidString)")
        let storage = MarkdownTextStorage(theme: .light)
        storage.baseURL = folder.appendingPathComponent("doc.md")
        let filler = String(repeating: "A paragraph of filler text.\n\n", count: 50)
        let text = names.map { "![\($0)](\($0).png)\n\n" + filler }.joined()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        return (storage, folder)
    }

    /// Each arrival restyled every line still waiting for anything, so N
    /// images or formulas arriving one by one cost N times N restyles.
    @Test("An arrival restyles only the lines waiting for it, gathered over a moment")
    func arrivalRestylesOwnLines() async throws {
        let (storage, folder) = storageAwaitingImages(["a", "b", "c", "d"])
        let text = storage.string as NSString
        for name in ["a", "b", "c", "d"] {
            let location = text.range(of: "![\(name)]").location
            #expect(storage.linesAwaiting[.image(folder.appendingPathComponent("\(name).png"))] == IndexSet(integer: storage.line(at: location)))
        }

        let edits = EditRecorder()
        storage.delegate = edits
        NotificationCenter.default.post(name: ImageCache.didLoad, object: folder.appendingPathComponent("b.png"))
        NotificationCenter.default.post(name: ImageCache.didLoad, object: folder.appendingPathComponent("d.png"))
        // Arrivals in a burst wait to be restyled together.
        #expect(edits.ranges.isEmpty)
        for _ in 0..<50 where edits.ranges.count < 2 {
            try await Task.sleep(for: .milliseconds(20))
        }
        let restyled = edits.ranges.map { text.substring(with: $0) }.sorted()
        #expect(restyled == ["![b](b.png)\n", "![d](d.png)\n"])
    }

    @Test("Lines waiting for an image are found after edits move them")
    func awaitedLinesFollowEdits() async throws {
        let (storage, folder) = storageAwaitingImages(["a", "b", "c"])
        // Lines added above, and a paragraph between the images removed.
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "new\nlines\n\n")
        let paragraph = (storage.string as NSString).range(of: "A paragraph of filler text.\n\n")
        storage.replaceCharacters(in: paragraph, with: "")
        let text = storage.string as NSString
        for name in ["a", "b", "c"] {
            let location = text.range(of: "![\(name)]").location
            #expect(storage.linesAwaiting[.image(folder.appendingPathComponent("\(name).png"))] == IndexSet(integer: storage.line(at: location)))
        }

        let edits = EditRecorder()
        storage.delegate = edits
        NotificationCenter.default.post(name: ImageCache.didLoad, object: folder.appendingPathComponent("c.png"))
        storage.restyleForArrivals()
        #expect(edits.ranges.map { text.substring(with: $0) } == ["![c](c.png)\n"])
    }

    @Test("A new column width rescales images without restyling the rest")
    func resizeIsLocal() async throws {
        let image = try writeImage(width: 600, height: 300)
        let storage = MarkdownTextStorage(theme: .light)
        storage.baseURL = image.deletingLastPathComponent().appendingPathComponent("doc.md")
        let filler = String(repeating: "A paragraph of filler text.\n\n", count: 200)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: filler + "![alt](pic.png)\n")
        let line = (storage.string as NSString).range(of: "![alt]")
        for _ in 0..<50 where storage.attribute(.mdImage, at: line.location, effectiveRange: nil) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }

        let edits = EditRecorder()
        storage.delegate = edits
        // A live resize passes through every width on the way; the restyle
        // waits for it to settle.
        storage.maxImageWidth = 400
        storage.maxImageWidth = 300
        #expect(edits.ranges.isEmpty)
        storage.restyleImagesForWidth()
        let inline = try #require(storage.attribute(.mdImage, at: line.location, effectiveRange: nil) as? InlineImage)
        #expect(inline.size == CGSize(width: 300, height: 150))
        #expect(edits.ranges.count == 1)
        for range in edits.ranges {
            #expect(range.location >= line.location - 1 && range.length < 100, "restyled \(range) of \(storage.length)")
        }
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

    @Test("Typing before an emoji or CJK on the line keeps the caret after what was typed")
    func caretBeforeFallbackFont() {
        for line in ["a 😀", "a 漢字"] {
            let (textView, input) = makeTextView(line)
            textView.setSelectedRange(NSRange(location: 1, length: 0))
            type("x", textView, input)
            #expect(textView.selectedRange() == NSRange(location: 2, length: 0), "\(line)")
        }
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

    /// A line whose image could not be read waited for it forever, and was
    /// restyled each time any other image or formula arrived.
    @Test("A line whose image failed to load stops waiting for it")
    func failedImageStopsWaiting() async throws {
        let storage = MarkdownTextStorage(theme: .light)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditMissing-\(UUID().uuidString)")
        storage.baseURL = folder.appendingPathComponent("doc.md")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "![alt](missing.png)\n")
        let url = folder.appendingPathComponent("missing.png")
        for _ in 0..<100 where !ImageCache.shared.hasFailed(url) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ImageCache.shared.hasFailed(url))
        // Another image arriving restyles the lines still waiting.
        NotificationCenter.default.post(name: ImageCache.didLoad, object: url)
        for _ in 0..<50 where storage.attribute(.mdAwaiting, at: 0, effectiveRange: nil) != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(storage.attribute(.mdAwaiting, at: 0, effectiveRange: nil) == nil)
    }

    /// Each keystroke in a formula block queued its new source behind every
    /// earlier one, so the preview fell further behind the typing.
    @Test("Editing a formula block withdraws the source it replaces")
    func editedBlockWithdrawsOldSource() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "$$\na + b\n$$\n")
        let sources = { storage.requestedTypesetting.filter { $0.kind == .displayMath }.map(\.source) }
        #expect(sources() == ["a + b"])
        storage.replaceCharacters(in: NSRange(location: 8, length: 0), with: " + c")
        #expect(sources() == ["a + b + c"])
        let old = Typesetter.Request(kind: .displayMath, source: "a + b", fontSize: storage.theme.bodyFontSize,
                                     color: storage.theme.text.cssString, dark: storage.theme.isDark, width: 0)
        #expect(!Typesetter.shared.isQueued(old))
    }

    /// Blocks were remembered by the line they started on and never moved,
    /// so a line added above left them under another block's old number.
    @Test("A block's typeset source moves with the lines above it")
    func blockRequestsShiftWithEdits() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "$$\na\n$$\n\n$$\nb\n$$\n")
        #expect(Set(storage.blockRequests.keys) == [0, 4])
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x\n")
        #expect(Set(storage.blockRequests.keys) == [1, 5])
        #expect(storage.blockRequests[5]?.source == "b")
        // Deleting the first block forgets it and withdraws its source.
        storage.replaceCharacters(in: NSRange(location: 2, length: 9), with: "")
        #expect(Set(storage.blockRequests.keys) == [1])
        #expect(storage.blockRequests[1]?.source == "b")
        #expect(storage.requestedTypesetting.filter { $0.kind == .displayMath }.map(\.source) == ["b"])
    }

    /// The preview an open block holds still was kept after it closed, a
    /// diagram's bitmap with it, for as long as the document was open.
    @Test("A closed block lets go of its preview")
    func closedBlockDropsPreview() async throws {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Text\n\n$$\na^2\n$$\n")
        let request = try #require(storage.blockRequests[2])
        for _ in 0..<250 where Typesetter.shared.rendering(for: request) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(Typesetter.shared.rendering(for: request) != nil, "KaTeX did not typeset in time")
        storage.revealedLines = 2...4
        #expect(storage.lastPreviews[2] != nil)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "x\n")
        #expect(storage.lastPreviews[3] != nil && storage.lastPreviews[2] == nil)
        storage.revealedLines = 0...0
        #expect(storage.lastPreviews.isEmpty)
    }

    /// A definition added below left an earlier `[foo]` with no
    /// destination until its own line was edited.
    @Test("Adding a reference definition updates the links that use it")
    func definitionUpdatesLinks() async throws {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "See [foo] here.\n\nMore.\n")
        let location = 5
        #expect((storage.attribute(.mdLink, at: location, effectiveRange: nil) as? String)?.isEmpty != false)
        storage.replaceCharacters(in: NSRange(location: storage.length, length: 0), with: "\n[foo]: https://x.dev\n")
        for _ in 0..<50 where storage.attribute(.mdLink, at: location, effectiveRange: nil) as? String != "https://x.dev" {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(storage.attribute(.mdLink, at: location, effectiveRange: nil) as? String == "https://x.dev")
    }

    /// Typing a definition's destination changed it at every key, and each
    /// key restyled every line containing its label: with a label like `1`,
    /// nearly every line of the document.
    @Test("Typing a definition's destination restyles only the links that use it, once")
    func definitionTypingStaysLocal() async throws {
        let storage = MarkdownTextStorage(theme: .light)
        let filler = String(repeating: "Item 1 of a list with a 1 in it.\n\n", count: 1_000)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "See [it][1] here.\n\n" + filler + "[1]: https://x.dev\n")
        try await Task.sleep(for: .milliseconds(500))

        final class Processed: NSObject, NSTextStorageDelegate {
            var lines = 0
            func textStorage(
                _ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                range editedRange: NSRange, changeInLength delta: Int
            ) {
                guard !editedMask.contains(.editedCharacters) else { return }
                lines += (textStorage.string as NSString).substring(with: editedRange).components(separatedBy: "\n").count
            }
        }
        let processed = Processed()
        storage.delegate = processed
        let end = storage.length - 1
        for (offset, letter) in "/page".enumerated() {
            storage.replaceCharacters(in: NSRange(location: end + offset, length: 0), with: String(letter))
        }
        for _ in 0..<100 where storage.attribute(.mdLink, at: 5, effectiveRange: nil) as? String != "https://x.dev/page" {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(storage.attribute(.mdLink, at: 5, effectiveRange: nil) as? String == "https://x.dev/page")
        #expect(processed.lines < 20, "\(processed.lines) lines restyled")
    }

    /// Finished formulas and diagrams were let go only past a thousand of
    /// them, however large: diagrams are Retina bitmaps, so editing one for a
    /// while could hold gigabytes.
    @Test("Finished renderings are let go by weight as well as by number")
    func typesetCacheWeight() {
        let small = 64 << 10
        #expect(Typesetter.oldestToDrop(Array(repeating: small, count: 900)) == 0)
        #expect(Typesetter.oldestToDrop(Array(repeating: small, count: 1001)) == 1001 - 750)
        // A few dozen large diagrams are over the limit long before a thousand.
        let large = 8 << 20
        let dropped = Typesetter.oldestToDrop(Array(repeating: large, count: 40))
        #expect(dropped > 0)
        #expect((40 - dropped) * large <= Typesetter.finishedByteLimit * 3 / 4)
        // The newest stays, however much it weighs.
        #expect(Typesetter.oldestToDrop([small, Typesetter.finishedByteLimit * 2]) == 1)
    }
}
