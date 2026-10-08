import Foundation
import Testing
@testable import MarkdownKit

private func kinds(_ markdown: String) -> [BlockKind] {
    BlockStructure(text: markdown as NSString).lines.map(\.kind)
}

private func html(_ markdown: String) -> String {
    HTMLRenderer().render(markdown: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
}

private func inline(_ markdown: String, references: LinkReferences = .lenient) -> [InlineNode] {
    InlineParser.parse(Array(markdown.utf16), references: references)
}

@Suite("Front matter")
struct FrontMatterTests {
    @Test("Only `---` on the first line opens front matter")
    func blocks() {
        #expect(kinds("---\ntitle: x\n---\nbody") == [
            .frontMatterDelimiter, .frontMatter, .frontMatterDelimiter, .paragraph,
        ])
        #expect(kinds("---\na: 1\n...") == [.frontMatterDelimiter, .frontMatter, .frontMatterDelimiter])
        // Anywhere else, `---` is a rule as before.
        #expect(kinds("\n---") == [.blank, .thematicBreak])
        #expect(kinds("text\n\n---\na: 1\n---") == [.paragraph, .blank, .thematicBreak, .paragraph, .setextUnderline(level: 2)])
    }

    @Test("Front matter is left out of export")
    func export() {
        #expect(html("---\ntitle: x\n---\n# Hi") == "<h1 id=\"hi\">Hi</h1>")
    }
}

@Suite("HTML blocks")
struct HTMLBlockTests {
    @Test("Block tags run to a blank line")
    func blankLineEnded() {
        #expect(kinds("<div>\n*x*\n</div>\n\ntext") == [.htmlBlock, .htmlBlock, .htmlBlock, .blank, .paragraph])
        #expect(html("<div>\n*x*\n</div>") == "<div>\n*x*\n</div>")
    }

    @Test("Comments and raw-text tags run to their terminator, across blank lines")
    func terminated() {
        #expect(kinds("<!--\n\nhidden\n-->\nafter") == [.htmlBlock, .htmlBlock, .htmlBlock, .htmlBlock, .paragraph])
        #expect(kinds("<!-- one line -->\nafter") == [.htmlBlock, .paragraph])
        #expect(kinds("<script>\n\nlet a\n</script>\nx") == [.htmlBlock, .htmlBlock, .htmlBlock, .htmlBlock, .paragraph])
    }

    @Test("An arbitrary tag cannot interrupt a paragraph; a block tag can")
    func interruption() {
        #expect(kinds("para\n<span>") == [.paragraph, .paragraph])
        #expect(kinds("<span>\n") == [.htmlBlock, .blank])
        #expect(kinds("para\n<div>") == [.paragraph, .htmlBlock])
        // Inline HTML in a sentence stays inline.
        #expect(html("a <b>bold</b> word") == "<p>a <b>bold</b> word</p>")
    }

    @Test("Inside a fence, HTML is still code")
    func fenced() {
        #expect(kinds("```\n<div>\n```") == [.fenceStart(language: ""), .codeLine, .fenceEnd])
    }
}

@Suite("Reference links")
struct ReferenceLinkTests {
    @Test("Definitions are recognised and render as nothing")
    func definitions() {
        #expect(kinds("[Foo Bar]: https://x.dev \"T\"") == [
            .linkReferenceDefinition(label: "Foo Bar", definition: LinkDefinition(destination: "https://x.dev", title: "T")),
        ])
        #expect(kinds("[a]: <with space>") == [
            .linkReferenceDefinition(label: "a", definition: LinkDefinition(destination: "with space")),
        ])
        // Not definitions: no destination, junk after the title, or interrupting a paragraph.
        #expect(kinds("[a]:") == [.paragraph])
        #expect(kinds("[a]: /u \"t\" junk") == [.paragraph])
        #expect(kinds("para\n[a]: /u") == [.paragraph, .paragraph])
        #expect(html("[a]: /u") == "")
    }

    @Test("Full, collapsed and shortcut references resolve, case-insensitively")
    func resolve() {
        let defs = "\n\n[foo bar]: /url \"Title\""
        #expect(html("[text][Foo  Bar]" + defs) == "<p><a href=\"/url\" title=\"Title\">text</a></p>")
        #expect(html("[Foo Bar][]" + defs) == "<p><a href=\"/url\" title=\"Title\">Foo Bar</a></p>")
        #expect(html("[foo bar]" + defs) == "<p><a href=\"/url\" title=\"Title\">foo bar</a></p>")
        #expect(html("![alt][foo bar]" + defs) == "<p><img src=\"/url\" alt=\"alt\" /></p>")
        // A definition later in the document still counts; the first of a label wins.
        #expect(html("[x]\n\n[x]: /one\n[x]: /two") == "<p><a href=\"/one\">x</a></p>")
    }

    @Test("Undefined references stay text in export")
    func undefined() {
        #expect(html("[text][nope]") == "<p>[text][nope]</p>")
        #expect(html("[aside]") == "<p>[aside]</p>")
    }

    @Test("The editor styles full references even before they are defined, but not shortcuts")
    func lenient() {
        guard case let .link(_, markers, destination, _, _)? = inline("[t][later]").first else {
            Issue.record("expected a link")
            return
        }
        #expect(destination == "")
        #expect(markers.map(\.range) == [NSRange(location: 0, length: 1), NSRange(location: 2, length: 8)])
        #expect(inline("[aside]").count == 1)
        if case .link? = inline("[aside]").first { Issue.record("a bare [aside] is not a link") }

        let known = LinkReferences(links: ["aside": LinkDefinition(destination: "/a")])
        guard case let .link(_, _, resolved, _, _)? = inline("[Aside]", references: known).first else {
            Issue.record("a defined shortcut is a link")
            return
        }
        #expect(resolved == "/a")
    }

    @Test("An inline link still wins over a reference")
    func inlineFirst() {
        #expect(html("[t](/inline)\n\n[t]: /ref") == "<p><a href=\"/inline\">t</a></p>")
    }
}

@Suite("Footnotes")
struct FootnoteTests {
    @Test("Definitions keep their label visible and their text inline")
    func definitions() {
        let line = BlockStructure(text: "[^note]: Some *text*" as NSString).lines[0]
        #expect(line.kind == .footnoteDefinition(label: "note"))
        #expect(line.contentStart == 9)
        #expect(line.markers == [Marker(range: NSRange(location: 0, length: 8), kind: .label)])
        // Consecutive definitions need no blank line between them.
        #expect(kinds("[^a]: one\n[^b]: two") == [.footnoteDefinition(label: "a"), .footnoteDefinition(label: "b")])
    }

    @Test("References are numbered in order of use and linked both ways")
    func export() {
        let markdown = """
        Second[^b] and first[^a], again[^b].

        [^a]: Alpha.
        [^b]: Beta
        continues.
        [^unused]: Never cited.
        """
        let out = html(markdown)
        #expect(out.contains("Second<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1\">1</a></sup>"))
        #expect(out.contains("first<sup class=\"footnote-ref\"><a href=\"#fn-2\" id=\"fnref-2\">2</a></sup>"))
        #expect(out.contains("again<sup class=\"footnote-ref\"><a href=\"#fn-1\" id=\"fnref-1-2\">1</a></sup>"))
        #expect(out.contains("<li id=\"fn-1\"><p>Beta\ncontinues. <a href=\"#fnref-1\""))
        #expect(out.contains("<li id=\"fn-2\"><p>Alpha. <a href=\"#fnref-2\""))
        #expect(!out.contains("Never cited"))
    }

    @Test("An undefined footnote stays text in export")
    func undefined() {
        #expect(html("x[^missing]") == "<p>x[^missing]</p>")
    }
}

@Suite("Highlight, bare URLs and hard breaks")
struct InlineExtensionTests {
    @Test("==Marked== text")
    func highlight() {
        #expect(html("a ==b *c*== d") == "<p>a <mark>b <em>c</em></mark> d</p>")
        // Comparisons are not highlights.
        #expect(html("a == b == c") == "<p>a == b == c</p>")
        #expect(html("===x===") == "<p>===x===</p>")
    }

    @Test("Bare URLs link, leaving trailing punctuation outside")
    func bareURLs() {
        #expect(html("see https://x.dev/a.") == "<p>see <a href=\"https://x.dev/a\">https://x.dev/a</a>.</p>")
        #expect(html("(www.x.dev)") == "<p>(<a href=\"http://www.x.dev\">www.x.dev</a>)</p>")
        #expect(html("https://en.wikipedia.org/wiki/Swift_(language)") ==
            "<p><a href=\"https://en.wikipedia.org/wiki/Swift_(language)\">https://en.wikipedia.org/wiki/Swift_(language)</a></p>")
        // Mid-word, or already inside a link, it is plain text.
        #expect(html("xhttps://x.dev") == "<p>xhttps://x.dev</p>")
        #expect(html("[https://x.dev](https://y.dev)") == "<p><a href=\"https://y.dev\">https://x.dev</a></p>")
        #expect(html("<a@b.dev>") == "<p><a href=\"mailto:a@b.dev\">a@b.dev</a></p>")
    }

    @Test("Two trailing spaces or a backslash break the line")
    func hardBreaks() {
        #expect(html("one  \ntwo") == "<p>one<br />\ntwo</p>")
        #expect(html("one\\\ntwo") == "<p>one<br />\ntwo</p>")
        #expect(html("one\ntwo") == "<p>one\ntwo</p>")
        // At the end of a paragraph there is nothing to break before.
        #expect(html("one  ") == "<p>one</p>")
        // An escaped backslash is not a break.
        #expect(html("one\\\\\ntwo") == "<p>one\\\ntwo</p>")
    }
}

@Suite("Headings")
struct HeadingTests {
    @Test("Headings flatten their markup and get unique GitHub-style slugs")
    func headings() {
        let text = "# Hello *World*!\n\nIntro\n\n## `code` & [link](x)\nSetext\n---\n# Hello World" as NSString
        let headings = BlockStructure(text: text).headings(in: text)
        #expect(headings.map(\.title) == ["Hello World!", "code & link", "Setext", "Hello World"])
        #expect(headings.map(\.slug) == ["hello-world", "code--link", "setext", "hello-world-1"])
        #expect(headings.map(\.level) == [1, 2, 2, 1])
        #expect(headings.map(\.line) == [0, 4, 5, 7])
    }

    @Test("Export ids match the editor's slugs")
    func exportIDs() {
        #expect(html("# A b\n# A b") == "<h1 id=\"a-b\">A b</h1>\n<h1 id=\"a-b-1\">A b</h1>")
    }
}
