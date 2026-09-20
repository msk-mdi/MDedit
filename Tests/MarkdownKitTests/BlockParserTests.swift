import Foundation
import Testing
@testable import MarkdownKit

private func parseAll(_ markdown: String) -> [LineInfo] {
    BlockStructure(text: markdown as NSString).lines
}

private func kinds(_ markdown: String) -> [BlockKind] {
    parseAll(markdown).map(\.kind)
}

@Suite("BlockParser")
struct BlockParserTests {
    @Test("ATX headings")
    func headings() {
        #expect(kinds("# one") == [.atxHeading(level: 1)])
        #expect(kinds("###### six") == [.atxHeading(level: 6)])
        // Seven hashes is not a heading.
        #expect(kinds("####### seven") == [.paragraph])
        // A marker needs a space after it.
        #expect(kinds("#nospace") == [.paragraph])
        #expect(kinds("#") == [.atxHeading(level: 1)])

        let info = parseAll("## Title ##")[0]
        #expect(info.contentStart == 3)
        #expect(info.markers.count == 2)
        #expect(info.markers[0].range == NSRange(location: 0, length: 3))
        #expect(info.markers[1].range == NSRange(location: 8, length: 3))
    }

    @Test("Setext underlines beat thematic breaks under a paragraph")
    func setext() {
        #expect(kinds("Title\n===") == [.paragraph, .setextUnderline(level: 1)])
        #expect(kinds("Title\n---") == [.paragraph, .setextUnderline(level: 2)])
        // With no paragraph above, the same characters are a rule.
        #expect(kinds("\n---") == [.blank, .thematicBreak])
        #expect(kinds("***") == [.thematicBreak])
        #expect(kinds("- - -") == [.thematicBreak])
    }

    @Test("Fenced code swallows everything until it closes")
    func fences() {
        let markdown = "```swift\n# not a heading\n- not a list\n```\nafter"
        #expect(kinds(markdown) == [
            .fenceStart(language: "swift"),
            .codeLine,
            .codeLine,
            .fenceEnd,
            .paragraph,
        ])

        // A shorter run does not close a longer fence.
        #expect(kinds("````\n```\n````") == [.fenceStart(language: ""), .codeLine, .fenceEnd])
        // An unclosed fence runs to the end of the document.
        #expect(kinds("```\na\nb") == [.fenceStart(language: ""), .codeLine, .codeLine])
        // Tildes work too, and may hold backticks.
        #expect(kinds("~~~\n```\n~~~") == [.fenceStart(language: ""), .codeLine, .fenceEnd])
    }

    @Test("Lists, nesting, and task boxes")
    func lists() {
        #expect(kinds("- one") == [.listItem(ordered: false, task: nil)])
        #expect(kinds("1. one") == [.listItem(ordered: true, task: nil)])
        #expect(kinds("1) one") == [.listItem(ordered: true, task: nil)])
        // A bullet needs a space; `-x` is a paragraph.
        #expect(kinds("-x") == [.paragraph])
        #expect(kinds("- [ ] todo") == [.listItem(ordered: false, task: .unchecked)])
        #expect(kinds("- [x] done") == [.listItem(ordered: false, task: .checked)])

        let nested = parseAll("- one\n  - two\n    - three\n- back")
        #expect(nested.map(\.listDepth) == [1, 2, 3, 1])

        let task = parseAll("- [x] done")[0]
        #expect(task.contentStart == 6)
        #expect(task.markers.map(\.kind) == [.listBullet, .conceal, .taskChecked, .conceal])
    }

    @Test("Blockquotes nest and carry their markers")
    func quotes() {
        let info = parseAll("> > quoted")[0]
        #expect(info.quoteDepth == 2)
        #expect(info.kind == .paragraph)
        #expect(info.contentStart == 4)
        #expect(info.markers.allSatisfy { $0.kind == .quote })

        // A fence inside a quote still opens.
        #expect(kinds("> ```\n> code\n> ```") == [
            .fenceStart(language: ""),
            .codeLine,
            .fenceEnd,
        ])
    }

    @Test("Indented code, but not inside a paragraph")
    func indentedCode() {
        #expect(kinds("    code") == [.indentedCode])
        // A lazy continuation line of a paragraph is still the paragraph.
        #expect(kinds("text\n    more") == [.paragraph, .paragraph])
        #expect(kinds("\n    code") == [.blank, .indentedCode])
    }

    @Test("GFM tables")
    func tables() {
        let markdown = "| a | b |\n| --- | ---: |\n| 1 | 2 |\n\nafter"
        #expect(kinds(markdown) == [
            .paragraph,
            .tableDelimiter(alignments: [.none, .right]),
            .tableRow,
            .blank,
            .paragraph,
        ])
        // A delimiter row needs a header line above it.
        #expect(kinds("\n| --- |") == [.blank, .paragraph])
    }
}

@Suite("BlockStructure incremental parsing")
struct BlockStructureTests {
    /// The property that matters: an incremental reparse must produce exactly
    /// what a parse from scratch would.
    @Test("Incremental reparse matches a full parse")
    func incrementalMatchesFull() {
        var generator = SystemRandomNumberGenerator()
        let fragments = ["`", "```", "\n", "# ", "- ", "> ", "x", "**", "\n\n", "", "|", "---"]

        for _ in 0..<300 {
            var text = """
            # Title

            Some *body* text with `code`.

            - one
            - two

            ```swift
            let x = 1
            ```

            > quoted
            """
            let structure = BlockStructure(text: text as NSString)

            for _ in 0..<8 {
                let ns = text as NSString
                let location = Int.random(in: 0...ns.length, using: &generator)
                let maxLength = min(6, ns.length - location)
                let length = maxLength > 0 ? Int.random(in: 0...maxLength, using: &generator) : 0
                let replacement = fragments.randomElement(using: &generator)!

                text = ns.replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
                structure.update(
                    text: text as NSString,
                    editedRange: NSRange(location: location, length: replacement.utf16.count),
                    changeInLength: replacement.utf16.count - length
                )

                let fresh = BlockStructure(text: text as NSString)
                #expect(structure.lines == fresh.lines, "text: \(text.debugDescription)")
            }
        }
    }

    @Test("A keystroke reparses only its own line")
    func reparseIsLocal() {
        let text = Array(repeating: "paragraph text here\n", count: 500).joined()
        let structure = BlockStructure(text: text as NSString)
        let target = (text as NSString).length / 2

        let updated = (text as NSString).replacingCharacters(in: NSRange(location: target, length: 0), with: "x")
        let touched = structure.update(
            text: updated as NSString,
            editedRange: NSRange(location: target, length: 1),
            changeInLength: 1
        )
        #expect(touched.count == 1)
    }

    @Test("Opening a fence restyles the rest of the document")
    func fenceRestylesDownstream() {
        let text = "a\n\nb\n\nc\n"
        let structure = BlockStructure(text: text as NSString)
        let updated = "```\n" + text
        let touched = structure.update(
            text: updated as NSString,
            editedRange: NSRange(location: 0, length: 4),
            changeInLength: 4
        )
        #expect(touched.count > 1)
        #expect(structure.lines[2].kind == .codeLine)
    }
}
