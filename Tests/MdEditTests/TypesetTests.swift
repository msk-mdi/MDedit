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
}
