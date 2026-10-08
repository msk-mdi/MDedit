import Foundation
import Testing
@testable import MarkdownKit

private func html(_ markdown: String, extensions: SyntaxExtensions) -> String {
    HTMLRenderer(extensions: extensions).render(markdown: markdown).trimmingCharacters(in: .whitespacesAndNewlines)
}

@Suite("Syntax extension toggles")
struct SyntaxExtensionsTests {
    @Test("Each extension switched off leaves its characters literal")
    func inlineOff() {
        #expect(html("==mark==", extensions: .all.subtracting(.highlight)) == "<p>==mark==</p>")
        #expect(html("x^2^", extensions: .all.subtracting(.scripts)) == "<p>x^2^</p>")
        #expect(html(":tada:", extensions: .all.subtracting(.emoji)) == "<p>:tada:</p>")
        #expect(html("so $x$ is", extensions: .all.subtracting(.math)) == "<p>so $x$ is</p>")
        #expect(html("see https://a.dev", extensions: .all.subtracting(.bareURLs)) == "<p>see https://a.dev</p>")
        // Without scripts, a single `~` strikes as in GFM.
        #expect(html("H~2~O", extensions: .all.subtracting(.scripts)) == "<p>H<del>2</del>O</p>")
    }

    @Test("The same markup with every extension on")
    func inlineOn() {
        #expect(html("==mark==", extensions: .all) == "<p><mark>mark</mark></p>")
        #expect(html("x^2^", extensions: .all) == "<p>x<sup>2</sup></p>")
        #expect(html("H~2~O", extensions: .all) == "<p>H<sub>2</sub>O</p>")
    }

    @Test("Without math, `$$` is a paragraph in the editor and in export")
    func mathBlocksOff() {
        let structure = BlockStructure(text: "$$\nx\n$$" as NSString, extensions: [])
        #expect(structure.lines.map(\.kind) == [.paragraph, .paragraph, .paragraph])
        #expect(html("$$\nx\n$$", extensions: []) == "<p>$$\nx\n$$</p>")
    }

    @Test("Incremental reparsing keeps the structure's extensions")
    func incremental() {
        let text = NSMutableString(string: "a\n")
        let structure = BlockStructure(text: text, extensions: [])
        text.insert("$$\n", at: 0)
        structure.update(text: text, editedRange: NSRange(location: 0, length: 3), changeInLength: 3)
        #expect(structure.lines.first?.kind == .paragraph)
    }
}

@Suite("Heading numbers and contents")
struct HeadingNumberTests {
    @Test("Numbers count from the shallowest level used")
    func numbering() {
        let structure = BlockStructure(text: "## A\n### B\n### C\n## D\n#### E" as NSString)
        let headings = structure.headings(in: "## A\n### B\n### C\n## D\n#### E" as NSString)
        #expect(HeadingNumberer.numbers(for: headings) == ["1", "1.1", "1.2", "2", "2.0.1"])
    }

    @Test("Export numbers headings when asked")
    func exportNumbers() {
        var renderer = HTMLRenderer()
        renderer.numberHeadings = true
        let out = renderer.render(markdown: "# One\n## Sub\n# Two")
        #expect(out.contains("<h1 id=\"one\"><span class=\"heading-number\">1</span> One</h1>"))
        #expect(out.contains("<span class=\"heading-number\">1.1</span> Sub"))
        #expect(out.contains("<span class=\"heading-number\">2</span> Two"))
    }

    @Test("A `[TOC]` paragraph becomes a nested list of links")
    func tableOfContents() {
        let out = HTMLRenderer().render(markdown: "[TOC]\n\n# One\n## Sub\n# Two")
        #expect(out.hasPrefix("<nav class=\"toc\">\n<ul>\n<li><a href=\"#one\">One</a>\n<ul>\n<li><a href=\"#sub\">Sub</a></li>\n</ul>\n</li>\n<li><a href=\"#two\">Two</a></li>\n</ul>\n</nav>"))
        var off = HTMLRenderer()
        off.tableOfContents = false
        #expect(off.render(markdown: "[TOC]").contains("<p>[TOC]</p>"))
    }
}

@Suite("Self-contained export")
struct EmbeddedImageTests {
    @Test("Local images become data URIs; web images keep their address")
    func embed() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditEmbed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: directory.appendingPathComponent("a.png"))
        var renderer = HTMLRenderer(baseURL: directory.appendingPathComponent("doc.md"))
        renderer.embedImages = true
        let out = renderer.render(markdown: "![x](a.png) ![y](https://e.com/b.png) ![z](missing.png)")
        #expect(out.contains("src=\"data:image/png;base64,AQID\""))
        #expect(out.contains("src=\"https://e.com/b.png\""))
        #expect(out.contains("missing.png\""))
    }
}
