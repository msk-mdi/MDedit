import Foundation
import Testing
@testable import MarkdownKit

private func kinds(_ markdown: String) -> [BlockKind] {
    BlockStructure(text: markdown as NSString).lines.map(\.kind)
}

private func html(_ markdown: String) -> String {
    HTMLRenderer().render(markdown: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Math")
struct MathTests {
    @Test("`$$` blocks hold TeX until they close; `$$ … $$` is one line of display math")
    func blocks() {
        #expect(kinds("$$\na_1 = *b*\n\n$$\nafter") == [.mathDelimiter, .mathLine, .mathLine, .mathDelimiter, .paragraph])
        #expect(kinds("$$ E = mc^2 $$") == [.mathLine])
        #expect(kinds("$$") == [.mathDelimiter])
        #expect(kinds("```\n$$\n```") == [.fenceStart(language: ""), .codeLine, .fenceEnd])
        #expect(html("$$\nx < y\n$$") == "<div class=\"math display\">\\[\nx &lt; y\n\\]</div>")
        #expect(html("$$ a+b $$") == "<div class=\"math display\">\\[\n a+b \n\\]</div>")
    }

    @Test("Inline math hugs its content and leaves prices alone")
    func inline() {
        #expect(html("so $x^2$ is") == "<p>so <span class=\"math inline\">\\(x^2\\)</span> is</p>")
        #expect(html("$$a$$ here") == "<p><span class=\"math display\">\\[a\\]</span> here</p>")
        #expect(html("costs $5 and $10") == "<p>costs $5 and $10</p>")
        #expect(html("$ x$") == "<p>$ x$</p>")
        #expect(html("$x $") == "<p>$x $</p>")
        #expect(html("$a$1") == "<p>$a$1</p>")
        // Markup inside math is TeX, not emphasis.
        #expect(html("$a*b*c$") == "<p><span class=\"math inline\">\\(a*b*c\\)</span></p>")
    }

    @Test("Pages load KaTeX and Mermaid only when they need them")
    func headScripts() {
        let renderer = HTMLRenderer()
        #expect(!renderer.renderDocument(markdown: "plain", title: "t", css: "").contains("katex"))
        #expect(renderer.renderDocument(markdown: "$x$", title: "t", css: "").contains("katex@0.16.11"))
        let mermaid = renderer.renderDocument(markdown: "```mermaid\ngraph TD; A-->B\n```", title: "t", css: "")
        #expect(mermaid.contains("<pre class=\"mermaid\">graph TD; A--&gt;B\n</pre>"))
        #expect(mermaid.contains("mermaid@11.4.1"))
        #expect(!mermaid.contains("katex"))
    }
}

@Suite("Superscript, subscript and emoji")
struct ExtrasTests {
    @Test("^Super^ and ~sub~ take single words; ~spaced words~ still strike through")
    func scripts() {
        #expect(html("x^2^ and H~2~O") == "<p>x<sup>2</sup> and H<sub>2</sub>O</p>")
        #expect(html("~struck out~") == "<p><del>struck out</del></p>")
        #expect(html("~~both~~") == "<p><del>both</del></p>")
        #expect(html("a ^ b ^ c") == "<p>a ^ b ^ c</p>")
        // A footnote's caret is not a superscript.
        #expect(html("x[^1]\n\n[^1]: note").contains("footnote-ref"))
    }

    @Test(":shortcodes: become emoji; unknown names and times stay text")
    func emoji() {
        #expect(html("Ship it :rocket: :+1:") == "<p>Ship it <span class=\"emoji\" title=\":rocket:\">🚀</span> <span class=\"emoji\" title=\":+1:\">👍</span></p>")
        #expect(html(":not_an_emoji:") == "<p>:not_an_emoji:</p>")
        #expect(html("at 10:30:00") == "<p>at 10:30:00</p>")
        #expect(html("a:smile:") == "<p>a:smile:</p>")
        let headings = BlockStructure(text: "# Done :tada:" as NSString).headings(in: "# Done :tada:" as NSString)
        #expect(headings.first?.title == "Done 🎉")
    }
}
