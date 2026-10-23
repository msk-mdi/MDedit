import Foundation
import Testing
@testable import MarkdownKit

/// Inputs that once took time growing with the square of their length:
/// a paragraph of them froze export and Quick Look for seconds or minutes.
/// Each runs at a size the old code took seconds over in a release build;
/// the budgets are generous for a debug build and still far below that.
@Suite("Pathological input")
struct PathologicalInputTests {
    private static func seconds(_ markdown: String) -> Double {
        let elapsed = ContinuousClock().measure { _ = HTMLRenderer().render(markdown: markdown) }
        return Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
    }

    @Test("Unclosed comments, processing instructions and CDATA", arguments: ["a <!-- ", "a <? ", "a <![CDATA[ ", "a <!X "])
    func unclosedRawHTML(_ opener: String) {
        let time = Self.seconds(String(repeating: opener, count: 10_000))
        #expect(time < 1, "\(time) s")
    }

    @Test("Unclosed math")
    func unclosedMath() {
        let time = Self.seconds(String(repeating: "$1 ", count: 20_000))
        #expect(time < 1, "\(time) s")
    }

    /// A backslash in the search for a closer kept it from being
    /// remembered, so every `$` searched to the end again.
    @Test("Unclosed math with escapes in it")
    func unclosedMathWithEscapes() {
        let time = Self.seconds(String(repeating: "$\\x ", count: 20_000))
        #expect(time < 1, "\(time) s")
        #expect(HTMLRenderer().render(markdown: "$\\x $a\\$b$").contains("class=\"math"))
    }

    /// Each backtick run with no closer of its length searched to the end
    /// of the paragraph; runs of many distinct lengths each did.
    @Test("Unclosed code spans of many lengths")
    func unclosedCodeSpans() {
        let markdown = (1...1000).map { String(repeating: "`", count: $0) + "a" }.joined()
        let time = Self.seconds(markdown)
        #expect(time < 1, "\(time) s")
        // Still closed by a later run of the same length, past others.
        #expect(HTMLRenderer().render(markdown: "`a ``b `c`` d") == "<p><code>a ``b </code>c`` d</p>\n")
        #expect(HTMLRenderer().render(markdown: "``` a ``b` c`") == "<p>``` a ``b<code> c</code></p>\n")
    }

    /// Each delimiter row under a paragraph split the whole paragraph to
    /// find its last line, even when the cell counts could not match.
    @Test("Delimiter rows that never match the line above")
    func unmatchedTableDelimiters() {
        // 20,000 lines; with the rest of the suite running beside it, a
        // debug build has taken over a second.
        let time = Self.seconds(String(repeating: "|-|\n|-|-|\n", count: 10_000))
        #expect(time < 2, "\(time) s")
        #expect(HTMLRenderer().render(markdown: "Intro\nline\na | b\n-|-\n1 | 2\n").hasPrefix("<p>Intro\nline</p>\n<table>"))
    }

    @Test("Long runs of emphasis", arguments: ["*a* ", "*a", "_a_ "])
    func emphasis(_ unit: String) {
        let time = Self.seconds(String(repeating: unit, count: 50_000))
        #expect(time < 2, "\(time) s")
    }

    @Test("Nested and unclosed brackets")
    func brackets() {
        let nested = Self.seconds(String(repeating: "[", count: 20_000) + String(repeating: "]", count: 20_000))
        let links = Self.seconds(String(repeating: "[", count: 20_000) + String(repeating: "[a](b) ", count: 20_000))
        #expect(nested < 1, "\(nested) s")
        #expect(links < 2, "\(links) s")
    }

    /// Each trailing `)` of a bare URL recounted the parentheses before it.
    @Test("Bare URL followed by a run of closing parentheses")
    func bareURLParentheses() {
        let time = Self.seconds("https://x.com/" + String(repeating: ")", count: 40_000))
        #expect(time < 1, "\(time) s")
        #expect(HTMLRenderer().render(markdown: "https://x.com/(a))") == "<p><a href=\"https://x.com/(a)\">https://x.com/(a)</a>)</p>\n")
    }

    /// Nesting past any real document's once overflowed the stack: the
    /// tree is built, torn down and rendered recursively.
    @Test("Deeply nested emphasis, quotes and lists")
    func deepNesting() {
        let emphasis = Self.seconds(String(repeating: "**a ", count: 50_000) + String(repeating: " a**", count: 50_000))
        let quotes = Self.seconds(String(repeating: ">", count: 50_000) + " a")
        let lists = Self.seconds(String(repeating: "- ", count: 50_000) + "a")
        #expect(emphasis < 2, "\(emphasis) s")
        #expect(quotes < 1, "\(quotes) s")
        #expect(lists < 1, "\(lists) s")
        _ = InlineParser.parse(Array((String(repeating: "*a ", count: 50_000) + String(repeating: " a*", count: 50_000)).utf16))
    }

    /// The editor parses lines with its own block parser, which counted each
    /// `>`'s column from the start of the line, with no depth limit.
    @Test("A line of nested quotes in the editor's parser")
    func deepQuotesInEditor() {
        let line = Array((String(repeating: ">", count: 50_000) + " a").utf16)
        var info: LineInfo?
        let elapsed = ContinuousClock().measure { info = BlockParser.parse(line: line, carry: .start) }
        let time = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        #expect(time < 1, "\(time) s")
        #expect(info?.quoteDepth == BlockParser.maxQuoteDepth)
        // Short of the limit, tabs and spaces between `>`s still count as before.
        #expect(BlockParser.parse(line: Array("> >\t> a".utf16), carry: .start).quoteDepth == 3)
        #expect(BlockParser.parse(line: Array(">\t\t> a".utf16), carry: .start).quoteDepth == 1)
        #expect(BlockParser.parse(line: Array(">  > > a".utf16), carry: .start).quoteDepth == 3)
    }

    /// Each open list rescanned the line's indentation.
    @Test("Lines indented under many nested lists")
    func indentedNestedLists() {
        let time = Self.seconds((0..<1_500).map { String(repeating: "  ", count: $0) + "- a" }.joined(separator: "\n"))
        #expect(time < 2, "\(time) s")
    }

    /// A wide header over many one-cell rows filled every row in.
    /// The editor's table model padded every row to the widest: one row of
    /// 20,000 pipes under 5,000 rows made a hundred million empty cells.
    @Test("A table editor table padded past its limit is left as text")
    func editorTablePadding() {
        let lines = ["| a | b |", "| - | - |"] + Array(repeating: "| 1 | 2 |", count: 5_000) + [String(repeating: "|", count: 20_000)]
        var table: MarkdownTable?
        let elapsed = ContinuousClock().measure { table = MarkdownTable(lines: lines) }
        #expect(table == nil)
        #expect(elapsed < .seconds(1), "\(elapsed)")
        // A single wide row is still a table, and formats in time with its length.
        let wide = MarkdownTable(lines: ["|" + String(repeating: " a |", count: 20_000), "|" + String(repeating: " - |", count: 20_000)])
        let formatting = ContinuousClock().measure { _ = wide?.formatted() }
        #expect(wide?.columnCount == 20_000)
        #expect(formatting < .seconds(1), "\(formatting)")
    }

    /// Each image's alt holds the alt of the image inside it.
    @Test("Nested images")
    func nestedImages() {
        let time = Self.seconds(String(repeating: "![a", count: 20_000) + String(repeating: "](b)", count: 20_000))
        #expect(time < 1, "\(time) s")
        #expect(HTMLRenderer().render(markdown: "![a ![b](c) d](e)") == "<p><img src=\"e\" alt=\"a b d\" /></p>\n")
    }

    @Test("Table rows padded to a wide header")
    func tablePadding() {
        let markdown = "|" + String(repeating: " a |", count: 3_000) + "\n|" + String(repeating: " - |", count: 3_000) + "\n" + String(repeating: "a\n", count: 3_000)
        var html = ""
        let elapsed = ContinuousClock().measure { html = HTMLRenderer().render(markdown: markdown) }
        #expect(html.utf8.count < 2_000_000, "\(html.utf8.count) bytes")
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }

    @Test("Many setext headings, definitions and footnotes")
    func manyBlocks() {
        let setext = Self.seconds(String(repeating: "a\n=\n", count: 40_000))
        let definitions = Self.seconds((0..<40_000).map { "[l\($0)]: /u" }.joined(separator: "\n"))
        let footnotes = Self.seconds(
            (0..<20_000).map { "a[^\($0)]" }.joined(separator: " ") + "\n\n" + (0..<20_000).map { "[^\($0)]: x" }.joined(separator: "\n")
        )
        // About 1 s each on a Mac, 4–5 on a CI runner: the limit is there to catch
        // quadratic slowdowns, not to time the machine.
        #expect(setext < 10, "\(setext) s")
        #expect(definitions < 10, "\(definitions) s")
        #expect(footnotes < 10, "\(footnotes) s")
    }

    /// A floor on where openers are searched for was kept as an index into
    /// pieces that each match then spliced, so it drifted past real openers.
    @Test("Emphasis after an earlier match still finds its opener")
    func openerFloorSurvivesMatches() {
        #expect(HTMLRenderer().render(markdown: "_a*_*a*") == "<p><em>a*</em><em>a</em></p>\n")
        #expect(HTMLRenderer().render(markdown: "*a_*_*_") == "<p><em>a_</em><em>*</em></p>\n")
    }
}
