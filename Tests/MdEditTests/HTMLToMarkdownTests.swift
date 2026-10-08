import Testing
@testable import MdEdit

@Suite("HTMLToMarkdown")
struct HTMLToMarkdownTests {
    private func md(_ html: String) -> String? {
        HTMLToMarkdown.convert("<html><body>\(html)</body></html>")
    }

    @Test("Headings, emphasis, links and images")
    func basics() {
        #expect(md("<h2>Title</h2><p>Some <b>bold</b>, <em>italic</em> and <a href=\"https://x.dev\">a link</a>.</p>")
            == "## Title\n\nSome **bold**, *italic* and [a link](https://x.dev).")
        #expect(md("<p><img src=\"a.png\" alt=\"pic\"> <code>x()</code> <del>gone</del></p>") == "![pic](a.png) `x()` ~~gone~~")
        // Spaces stay outside the delimiters, or the emphasis would not parse.
        #expect(md("<p>a<strong> b </strong>c</p>") == "a **b** c")
    }

    @Test("Nested and ordered lists, tasks, quotes and rules")
    func blocks() {
        #expect(md("<ul><li>one<ul><li>inner</li></ul></li><li>two</li></ul>") == "- one\n  - inner\n- two")
        #expect(md("<ol start=\"3\"><li>c</li><li>d</li></ol>") == "3. c\n4. d")
        #expect(md("<ul><li><input type=\"checkbox\" checked> done</li></ul>") == "- [x] done")
        #expect(md("<blockquote><p>quoted</p><p>more</p></blockquote><hr>") == "> quoted\n>\n> more\n\n---")
    }

    @Test("Code blocks keep their text and language; tables become pipe tables")
    func codeAndTables() {
        #expect(md("<pre><code class=\"language-swift\">let a = 1 * 2\n  b</code></pre>") == "```swift\nlet a = 1 * 2\n  b\n```")
        #expect(md("<table><tr><th>A</th><th>B</th></tr><tr><td>1</td><td>x|y</td></tr></table>")
            == "| A   | B    |\n| --- | ---- |\n| 1   | x\\|y |")
    }

    @Test("Text is escaped, whitespace collapses, line breaks survive")
    func text() {
        #expect(md("<p><b>Note</b> 2 * 3 = [six]</p>") == "**Note** 2 \\* 3 = \\[six\\]")
        #expect(md("<p><i>one</i>\n   two<br>three</p>") == "*one* two\\\nthree")
        // With no formatting at all, plain paste is better than a conversion.
        #expect(md("<p>just words</p>") == nil)
    }

    @Test("Google Docs styling becomes markup; plain coloured spans are left alone")
    func styles() {
        let docs = "<b style=\"font-weight:normal;\" id=\"docs-internal-guid-1\"><p><span style=\"font-weight:700\">Bold</span> and <span style=\"font-style:italic\">it</span></p></b>"
        #expect(md(docs) == "**Bold** and *it*")
        // An editor's syntax-coloured code has nothing worth converting.
        #expect(md("<div><span style=\"color:#f00\">let</span> x = 1</div>") == nil)
    }
}
