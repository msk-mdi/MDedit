import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Export")
struct ExportTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditExport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test("The stylesheet carries the chosen theme in both appearances, or one")
    func stylesheet() {
        let css = Exporter.stylesheet(themeName: "Solarized")
        #expect(css.contains("--canvas: #fdf6e3;"))
        #expect(css.contains("--canvas: #002b36;"))
        #expect(css.contains(".tok-keyword { color: var(--tok-keyword); }"))
        let light = Exporter.stylesheet(themeName: "Solarized", includeDark: false)
        #expect(!light.contains("#002b36"))
        #expect(light.contains("color-scheme: light;"))
    }

    @Test("Without a stylesheet the page has no style element")
    func noStylesheet() {
        var options = ExportOptions()
        options.includeStylesheet = false
        let page = Exporter.html(markdown: "hi", title: "t", baseURL: nil, options: options)
        #expect(!page.contains("<style>"))
        #expect(page.contains("<p>hi</p>"))
    }

    @Test("A table of contents goes after front matter")
    func tocPlacement() {
        #expect(Exporter.withTableOfContents("# A") == "[TOC]\n\n# A")
        #expect(Exporter.withTableOfContents("---\ntitle: x\n---\n# A") == "---\ntitle: x\n---\n[TOC]\n\n# A")
        var options = ExportOptions()
        options.tableOfContents = true
        let page = Exporter.html(markdown: "---\ntitle: x\n---\n# A\n## B", title: "t", baseURL: nil, options: options)
        #expect(page.contains("<nav class=\"toc\">"))
        #expect(!page.contains("title: x"))
    }

    @Test("Bundled KaTeX and Mermaid are inlined, fonts and all")
    func offlineScripts() throws {
        let bundleURL = try temporaryDirectory().appendingPathComponent("Fake.bundle")
        let vendor = bundleURL.appendingPathComponent("Contents/Resources/vendor")
        try FileManager.default.createDirectory(at: vendor.appendingPathComponent("katex/contrib"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendor.appendingPathComponent("katex/fonts"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vendor.appendingPathComponent("mermaid"), withIntermediateDirectories: true)
        try "@font-face{src:url(fonts/KaTeX_Main.woff2)}".write(to: vendor.appendingPathComponent("katex/katex.min.css"), atomically: true, encoding: .utf8)
        try "var katex='</script>';".write(to: vendor.appendingPathComponent("katex/katex.min.js"), atomically: true, encoding: .utf8)
        try "function renderMathInElement(){}".write(to: vendor.appendingPathComponent("katex/contrib/auto-render.min.js"), atomically: true, encoding: .utf8)
        try Data([0, 1]).write(to: vendor.appendingPathComponent("katex/fonts/KaTeX_Main.woff2"))
        try "var mermaid={};".write(to: vendor.appendingPathComponent("mermaid/mermaid.min.js"), atomically: true, encoding: .utf8)
        try #"<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>test.fake</string></dict></plist>"#
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)

        let bundle = try #require(Bundle(url: bundleURL))
        let scripts = try #require(Exporter.bundledScripts(in: bundle))
        #expect(scripts.katexCSS == "@font-face{src:url(data:font/woff2;base64,AAE=)}")
        var renderer = HTMLRenderer()
        renderer.scripts = scripts
        let page = renderer.renderDocument(markdown: "$x$\n\n```mermaid\ngraph TD\n```", title: "t", css: "")
        #expect(!page.contains("cdn.jsdelivr"))
        #expect(page.contains("var katex='<\\/script>';"))
        #expect(page.contains("var mermaid={};"))
        #expect(page.contains("DOMContentLoaded"))
    }

    @Test("Rich formats come from the rendered HTML")
    func richFormats() throws {
        let text = try #require(Exporter.attributedString(markdown: "# Title\n\nSome **bold** text", title: "t", baseURL: nil, options: ExportOptions()))
        #expect(text.string.contains("Title"))
        #expect(text.string.contains("Some bold text"))
        let boldIndex = (text.string as NSString).range(of: "bold").location
        let font = try #require(text.attribute(.font, at: boldIndex, effectiveRange: nil) as? NSFont)
        #expect(font.fontDescriptor.symbolicTraits.contains(.bold))
        let rtf = try Exporter.data(for: .richText, from: text)
        #expect(String(decoding: rtf.prefix(5), as: UTF8.self) == "{\\rtf")
        let docx = try Exporter.data(for: .word, from: text)
        #expect(docx.prefix(2) == Data("PK".utf8))
        #expect(String(decoding: try Exporter.data(for: .plainText, from: text), as: UTF8.self).contains("Some bold text"))
    }

    @Test("PDF layout uses the paper's width and breaks onto pages")
    func printLayout() throws {
        var options = ExportOptions()
        options.paper = .a5
        options.margins = .narrow
        let info = Exporter.printInfo(for: options)
        let markdown = (1...120).map { "Paragraph \($0) with **bold** text." }.joined(separator: "\n\n")
        let printable = PrintableDocument(markdown: markdown, title: "Long", baseURL: nil, options: options, printInfo: info)
        // AppKit snaps paper to its exact size: A5 is 419.53 points wide.
        #expect(abs(printable.textView.frame.width - (info.paperSize.width - 72)) < 0.01)
        #expect(abs(info.paperSize.width - 420) < 1)
        #expect(printable.pageCount > 3)
        // Markers are concealed on paper: no line is revealed.
        #expect(printable.storage.revealedLines == nil)

        let url = try temporaryDirectory().appendingPathComponent("out.pdf")
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let operation = printable.operation()
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        #expect(operation.run())
        let data = try Data(contentsOf: url)
        #expect(data.prefix(4) == Data("%PDF".utf8))
    }

    @Test("Export options survive a round trip")
    func optionsRoundTrip() throws {
        let suite = "MdEditExportTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var options = ExportOptions()
        options.paper = .legal
        options.themeName = "Nord"
        options.embedImages = true
        options.save(to: defaults)
        #expect(ExportOptions.load(from: defaults) == options)
    }

    @Test("Pandoc is driven with the chosen writer and the document's folder")
    func pandocArguments() {
        let format = Pandoc.formats.first { $0.writer == "epub" }!
        let arguments = Pandoc.arguments(for: format, output: URL(fileURLWithPath: "/tmp/out.epub"), resourceDirectory: URL(fileURLWithPath: "/docs"), tableOfContents: true)
        #expect(arguments == ["--from", "markdown", "--to", "epub", "--standalone", "--output", "/tmp/out.epub", "--resource-path", "/docs", "--toc"])
    }

    @Test("The command line takes a file or stdin, an output and page options")
    func commandLine() throws {
        #expect(try CommandLineRenderer.parse([]) == .init())
        #expect(try CommandLineRenderer.parse(["-"]) == .init())
        let full = try CommandLineRenderer.parse(["a.md", "-o", "a.html", "--standalone", "--theme", "Nord", "--toc", "--embed-images"])
        #expect(full == .init(input: "a.md", output: "a.html", standalone: true, themeName: "Nord", tableOfContents: true, numberHeadings: false, embedImages: true))
        #expect(throws: CommandLineRenderer.Failure.self) { try CommandLineRenderer.parse(["--output"]) }
        #expect(throws: CommandLineRenderer.Failure.self) { try CommandLineRenderer.parse(["a.md", "b.md"]) }

        let body = CommandLineRenderer.render("# Hi", invocation: .init(), baseURL: nil)
        #expect(body == "<h1 id=\"hi\">Hi</h1>\n")
        let page = CommandLineRenderer.render("# Hi", invocation: .init(standalone: true, themeName: "Nord"), baseURL: nil)
        #expect(page.hasPrefix("<!DOCTYPE html>"))
        #expect(page.contains("--canvas: #eceff4;"))
    }
}
