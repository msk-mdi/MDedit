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
