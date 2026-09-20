import Foundation
import Testing
@testable import MarkdownKit

private func html(_ markdown: String) -> String {
    HTMLRenderer().render(markdown: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("HTMLRenderer")
struct HTMLRendererTests {
    @Test("Headings, paragraphs and rules")
    func basics() {
        #expect(html("# Title") == "<h1>Title</h1>")
        #expect(html("## Title ##") == "<h2>Title</h2>")
        #expect(html("Title\n===") == "<h1>Title</h1>")
        #expect(html("one\ntwo") == "<p>one\ntwo</p>")
        #expect(html("one\n\ntwo") == "<p>one</p>\n<p>two</p>")
        #expect(html("***") == "<hr />")
    }

    @Test("Inline markup")
    func inlines() {
        #expect(html("*a* **b** ~~c~~") == "<p><em>a</em> <strong>b</strong> <del>c</del></p>")
        #expect(html("`a < b`") == "<p><code>a &lt; b</code></p>")
        #expect(html("[t](u)") == "<p><a href=\"u\">t</a></p>")
        #expect(html("![a](p.png)") == "<p><img src=\"p.png\" alt=\"a\" /></p>")
        #expect(html("<https://x.dev>") == "<p><a href=\"https://x.dev\">https://x.dev</a></p>")
        #expect(html("a \\* b") == "<p>a * b</p>")
    }

    @Test("HTML special characters are escaped")
    func escaping() {
        #expect(html("a & b < c") == "<p>a &amp; b &lt; c</p>")
        #expect(html("```\n<script>\n```") == "<pre><code>&lt;script&gt;\n</code></pre>")
    }

    @Test("Code blocks keep their language")
    func code() {
        // A known language is highlighted; see SyntaxHighlighterTests for the spans.
        #expect(html("```swift\nlet x = 1\n```").hasPrefix("<pre><code class=\"language-swift\">"))
        #expect(html("```unknownlang\nlet x = 1\n```")
            == "<pre><code class=\"language-unknownlang\">let x = 1\n</code></pre>")
        #expect(html("    indented") == "<pre><code>indented\n</code></pre>")
    }

    @Test("Lists, nesting and task boxes")
    func lists() {
        #expect(html("- a\n- b") == "<ul>\n<li>a</li>\n<li>b</li>\n</ul>")
        #expect(html("1. a") == "<ol>\n<li>a</li>\n</ol>")
        #expect(html("- a\n  - b") == "<ul>\n<li>a</li>\n<ul>\n<li>b</li>\n</ul>\n</ul>")
        #expect(html("- [x] done").contains("checked"))
    }

    @Test("Blockquotes")
    func quotes() {
        #expect(html("> a") == "<blockquote>\n<p>a</p>\n</blockquote>")
        #expect(html("> a\n\nb") == "<blockquote>\n<p>a</p>\n</blockquote>\n<p>b</p>")
    }

    @Test("Tables carry alignment")
    func tables() {
        let out = html("| a | b |\n| :-- | --: |\n| 1 | 2 |")
        #expect(out.hasPrefix("<table>"))
        #expect(out.contains("<th style=\"text-align:left\">a</th>"))
        #expect(out.contains("<td style=\"text-align:right\">2</td>"))
        #expect(out.hasSuffix("</table>"))
    }

    @Test("Relative image paths resolve against the document")
    func relativePaths() {
        var renderer = HTMLRenderer()
        renderer.baseURL = URL(fileURLWithPath: "/tmp/notes/doc.md")
        let out = renderer.render(markdown: "![a](pic.png) and [b](https://x.dev)")
        #expect(out.contains("/tmp/notes/pic.png"))
        #expect(out.contains("https://x.dev"))
    }
}
