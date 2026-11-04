import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Typeset math and diagrams")
struct TypesetTests {
    @Test("Display math blocks and Mermaid fences are found whole, from any of their lines")
    func blocks() {
        let storage = MarkdownTextStorage(theme: .light, text: """
        intro
        $$
        a^2
        b^2
        $$
        ```mermaid
        flowchart LR
          A --> B
        ```
        ```python
        print(1)
        ```
        $$ x $$
        ```mermaid
        unclosed
        """)
        let math = MarkdownTextStorage.TypesetBlock(lines: 1...4, kind: .displayMath)
        for line in 1...4 { #expect(storage.typesetBlock(containing: line) == math) }
        let diagram = MarkdownTextStorage.TypesetBlock(lines: 5...8, kind: .diagram)
        for line in 5...8 { #expect(storage.typesetBlock(containing: line) == diagram) }
        #expect(storage.typesetBlock(containing: 0) == nil)
        #expect(storage.typesetBlock(containing: 10) == nil)
        #expect(storage.typesetBlock(containing: 12) == .init(lines: 12...12, kind: .displayMath))
        #expect(storage.typesetBlock(containing: 14) == nil)
    }

    @Test("Definition terms are bold and definitions indent with their `: ` hidden")
    func definitionList() throws {
        let storage = MarkdownTextStorage(theme: .light, text: "Term\n: The definition.\n\nplain\n")
        let term = try #require(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        #expect(term.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(storage.attribute(.mdConcealed, at: 5, effectiveRange: nil) != nil)
        let style = try #require(storage.attribute(.paragraphStyle, at: 7, effectiveRange: nil) as? NSParagraphStyle)
        #expect(style.firstLineHeadIndent > 0)
        let plain = try #require(storage.attribute(.font, at: storage.length - 3, effectiveRange: nil) as? NSFont)
        #expect(!plain.fontDescriptor.symbolicTraits.contains(.bold))
    }

    @Test("`<kbd>` tags hide around a key chip")
    func keys() {
        let storage = MarkdownTextStorage(theme: .light, text: "Press <kbd>Ctrl</kbd> now")
        #expect(storage.attribute(.mdConcealed, at: 6, effectiveRange: nil) != nil)
        #expect(storage.attribute(.mdInlineCode, at: 11, effectiveRange: nil) != nil)
        #expect(storage.attribute(.mdConcealed, at: 15, effectiveRange: nil) != nil)
    }

    @Test("Colour tags hide and colour what they hold")
    func colors() throws {
        let text = "a <span style=\"color: #E5484D\">red</span> <mark style=\"background: #FFF3A3\">hi</mark> <span>plain</span> b"
        let storage = MarkdownTextStorage(theme: .light, text: text)
        let ns = text as NSString
        let red = ns.range(of: "red").location
        #expect(storage.attribute(.mdConcealed, at: 2, effectiveRange: nil) != nil)
        #expect(storage.attribute(.mdConcealed, at: red + 3, effectiveRange: nil) != nil)
        let foreground = try #require(storage.attribute(.foregroundColor, at: red, effectiveRange: nil) as? NSColor)
        #expect(foreground == ColorMarkup.color("#E5484D"))
        let highlighted = ns.range(of: ">hi<").location + 1
        #expect(storage.attribute(.backgroundColor, at: highlighted, effectiveRange: nil) as? NSColor == ColorMarkup.color("#FFF3A3"))
        // A span with no colour is left as written.
        #expect(storage.attribute(.mdConcealed, at: ns.range(of: "<span>").location, effectiveRange: nil) == nil)
    }

    @Test("On a dark page a pale highlight keeps its hue, as a translucent wash")
    func darkHighlights() throws {
        let text = "<mark style=\"background: #FFD6D6\">hi</mark> <mark style=\"background: #E8E8EA\">grey</mark>"
        let storage = MarkdownTextStorage(theme: .dark, text: text)
        let red = try #require((storage.attribute(.backgroundColor, at: (text as NSString).range(of: "hi").location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        #expect(red.saturationComponent > 0.6)
        #expect(abs(red.hueComponent - 0) < 0.02 || abs(red.hueComponent - 1) < 0.02)
        #expect(red.alphaComponent < 0.5)
        let grey = try #require((storage.attribute(.backgroundColor, at: (text as NSString).range(of: "grey").location, effectiveRange: nil) as? NSColor)?.usingColorSpace(.sRGB))
        #expect(grey.saturationComponent < 0.05)
    }

    @Test("CSS colours are read in their common forms")
    func cssColors() {
        #expect(ColorMarkup.color("#f00") == NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorMarkup.color(" #00FF00 ") == NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1))
        #expect(ColorMarkup.color("rgb(0, 0, 255)") == NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        #expect(ColorMarkup.color("Red") == NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        #expect(ColorMarkup.color("nonsense") == nil)
        #expect(ColorMarkup.tag("<font color=\"blue\">")?.foreground == NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        #expect(ColorMarkup.tag("<span style='background-color: red; color: #fff'>")?.background != nil)
        #expect(ColorMarkup.tag("</SPAN>")?.isClosing == true)
        #expect(ColorMarkup.tag("<div>") == nil)
    }
}
