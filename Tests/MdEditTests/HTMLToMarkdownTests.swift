import Testing
@testable import MdEdit

// On the main thread, where the editor pastes. Converting recurses once per
// level of nesting, and 500 levels overflowed the half-megabyte stack of the
// threads other tests run on, crashing the test process with a bus error.
@MainActor
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

    /// Counting on from Int.max trapped; markdown allows nine digits anyway.
    @Test("A list's start number is kept within what markdown allows")
    func hugeListStart() {
        #expect(md("<ol start=\"9223372036854775807\"><li>a</li><li>b</li></ol>") == "999999999. a\n1000000000. b")
        #expect(md("<ol start=\"-3\"><li>a</li></ol>") == "0. a")
        #expect(md("<ol start=\"4\"><li>a</li></ol>") == "4. a")
    }

    @Test("Links that run script lose their link, however the scheme is written")
    func scriptLinks() {
        for href in ["javascript:alert(1)", " JavaScript:alert(1)", "VBScript:x", "data:text/html,x"] {
            #expect(md("<p><a href=\"\(href)\">click</a></p>") == "click", "\(href)")
        }
        #expect(md("<p><a href=\"https://x.dev\">site</a></p>") == "[site](https://x.dev)")
    }

    /// Parsing nested markup recurses once per level: a page nested deep
    /// enough overflowed the stack and took the app down.
    @Test("Markup nested past any real page's depth pastes as text instead")
    func deepNesting() {
        let wrap = { (depth: Int) in String(repeating: "<span>", count: depth) + "<p>deep</p>" + String(repeating: "</span>", count: depth) + "<p><b>bold</b></p>" }
        #expect(md(wrap(500))?.contains("deep") == true)
        #expect(md(wrap(100_000)) == nil)
        // Tags that never close do not count.
        #expect(HTMLToMarkdown.nestingDepth(of: String(repeating: "a<br>b<img src=x><hr/>", count: 5000)) == 0)
        #expect(HTMLToMarkdown.nestingDepth(of: "<ul><li><b>x</b></li><li>y</li></ul>") == 3)
        #expect(HTMLToMarkdown.nestingDepth(of: "<b>a<br/>c<i x='1'>d</i></b><p/>") == 2)
        // Opening tags with no `>` after them searched to the end each time.
        let unclosed = String(repeating: "<a ", count: 200_000)
        let start = ContinuousClock.now
        #expect(HTMLToMarkdown.nestingDepth(of: unclosed) == 200_000)
        #expect(ContinuousClock.now - start < .seconds(1))
    }

    @Test("Notion: one list per item joins up, to-dos keep their boxes")
    func notion() {
        #expect(md("<ul><li>one</li></ul><ul><li>two</li></ul><p>after</p><ol><li>a</li></ol><ol start=\"2\"><li>b</li></ol>")
            == "- one\n- two\n\nafter\n\n1. a\n2. b")
        #expect(md("<ul class=\"to-do-list\"><li><div class=\"checkbox checkbox-on\"></div> <span>done</span></li></ul>") == "- [x] done")
        #expect(md("<ul><li><div class=\"checkbox checkbox-off\"></div>todo</li></ul>") == "- [ ] todo")
        #expect(md("<ul><li>[x] typed</li><li>[ ] open</li></ul>") == "- [x] typed\n- [ ] open")
        #expect(md("<details><summary><b>Toggle</b></summary><p>inside</p></details>") == "**Toggle**\n\ninside")
    }

    /// As Coda copies a checklist: blocks led by a checkbox, in a list with
    /// no items.
    @Test("Coda: checkbox blocks become a to-do list")
    func coda() {
        let html = "<h2><span>Validation</span></h2><ul style=\"margin-block: 1em;\">"
            + "<div><input type=\"checkbox\" readonly=\"\" style=\"width: 2em;\"><span>Ping de l’adresse IP.</span></div>"
            + "<div><input type=\"checkbox\" checked=\"\" readonly=\"\"><span>Impression d’une page.</span></div></ul><p>after</p>"
        #expect(md(html) == "## Validation\n\n- [ ] Ping de l’adresse IP.\n- [x] Impression d’une page.\n\nafter")
    }

    @Test("ProseMirror and ARIA to-dos, headings by role")
    func editorMarkup() {
        #expect(md("<ul data-type=\"taskList\"><li data-checked=\"true\"><p>a</p></li><li data-checked=\"false\"><p>b</p></li></ul>")
            == "- [x] a\n- [ ] b")
        #expect(md("<ul><li><div role=\"checkbox\" aria-checked=\"true\"></div>c</li></ul>") == "- [x] c")
        #expect(md("<div role=\"heading\" aria-level=\"3\">Section</div><p><b>x</b></p>") == "### Section\n\n**x**")
        // A heading is bold already.
        #expect(md("<h2><strong>Title</strong></h2>") == "## Title")
    }

    @Test("Google Docs: lists nested straight in lists, empty lines, numeric weights")
    func googleDocs() {
        #expect(md("<ul><li>one</li><ul><li>inner</li></ul><li>two</li></ul>") == "- one\n  - inner\n- two")
        #expect(md("<p><span style=\"font-weight: 800\">heavy</span></p><p><br></p><p><i>next</i><br></p>") == "**heavy**\n\n*next*")
    }

    @Test("Side-by-side runs of the same formatting become one")
    func adjacentRuns() {
        #expect(md("<p><b>bo</b><b>ld</b> and <span style=\"font-style:italic\">it</span><span style=\"font-style:italic\">al</span></p>")
            == "**bold** and *ital*")
        #expect(md("<p><b>bold&nbsp;</b>word</p>") == "**bold** word")
    }

    @Test("Text that would start markup on its line is escaped")
    func lineStarts() {
        #expect(md("<p><b>x</b></p><p># not a heading</p><p>- not a list</p><p>1. not a list</p><p>&gt; nor a quote</p>")
            == "**x**\n\n\\# not a heading\n\n\\- not a list\n\n1\\. not a list\n\n\\> nor a quote")
        #expect(md("<p><b>x</b> a &lt;div&gt; tag, ~~not struck~~, 2 &lt; 3</p>")
            == "**x** a \\<div> tag, \\~\\~not struck\\~\\~, 2 < 3")
        // Plain numbers and dashes inside a line are left alone.
        #expect(md("<p><b>x</b> 1999. A - B</p>") == "**x** 1999. A - B")
    }

    @Test("Code broken into lines with <br> keeps its lines")
    func codeLines() {
        #expect(md("<pre data-language=\"Python\">def f():<br>&nbsp;&nbsp;return 1</pre>") == "```python\ndef f():\n  return 1\n```")
    }

    @Test("Paragraphs in table cells run on in the row")
    func tableCells() {
        #expect(md("<table><tr><td><p>A</p></td><td><p>B</p><p>more</p></td></tr><tr><td>1</td><td>2</td></tr></table>")
            == "| A   | B more |\n| --- | ------ |\n| 1   | 2      |")
    }
}
