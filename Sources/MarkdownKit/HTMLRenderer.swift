import Foundation

/// Renders markdown to HTML for export and "Copy as HTML".
///
/// Export parses with `DocumentParser`, the spec's full container algorithm,
/// rather than the editor's line-at-a-time `BlockParser`: what you export is
/// CommonMark, while the editor stays fast. Inline markup comes from the same
/// `InlineParser` the editor styles with.
public struct HTMLRenderer {
    /// Resolves relative image and link paths, when the document has a location.
    public var baseURL: URL?
    /// Which extended syntax to recognise.
    public var extensions: SyntaxExtensions = .all
    /// Prefixes headings with outline numbers: `1`, `1.1`, `1.2`.
    public var numberHeadings = false
    /// Turns a paragraph of just `[TOC]` into a table of contents.
    public var tableOfContents = true
    /// Reads local images into `data:` URIs, so the page stands alone.
    public var embedImages = false
    /// What a page loads to draw math and diagrams. Nil uses the CDN.
    public var scripts: ScriptAssets?

    /// KaTeX and Mermaid inlined into the page, so it works offline.
    public struct ScriptAssets: Sendable {
        public var katexCSS: String
        public var katexJS: String
        public var autoRenderJS: String
        public var mermaidJS: String

        public init(katexCSS: String, katexJS: String, autoRenderJS: String, mermaidJS: String) {
            self.katexCSS = katexCSS
            self.katexJS = katexJS
            self.autoRenderJS = autoRenderJS
            self.mermaidJS = mermaidJS
        }
    }

    public init(baseURL: URL? = nil, extensions: SyntaxExtensions = .all) {
        self.baseURL = baseURL
        self.extensions = extensions
    }

    public func render(markdown: String) -> String {
        renderBody(markdown).html
    }

    /// A full standalone page, for Export as HTML.
    public func renderDocument(markdown: String, title: String, css: String) -> String {
        let (body, context) = renderBody(markdown)
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escape(title))</title>
        \(css.isEmpty ? "" : "<style>\n\(css)\n</style>\n")\(headExtras(context))</head>
        <body>
        \(body)
        </body>
        </html>

        """
    }

    /// The body, and what the page around it must load to show it.
    private func renderBody(_ markdown: String) -> (html: String, context: Context) {
        let parser = DocumentParser(extensions: extensions)
        let document = parser.parse(stripFrontMatter(markdown))
        let context = Context(references: parser.references)
        if numberHeadings || tableOfContents {
            context.headingLevels = headingLevels(in: document)
            context.numberer = HeadingNumberer(topLevel: context.headingLevels.map(\.level).min() ?? 1)
        }
        var writer = Writer()
        render(document, into: &writer, context)
        writer.out += footnoteSection(context)
        return (writer.out, context)
    }

    /// YAML front matter is metadata, not content: a `---` first line through
    /// the next `---` or `...` line is left out — when what is between reads
    /// as YAML. Otherwise `---` is a rule or a setext underline, as usual.
    private func stripFrontMatter(_ markdown: String) -> String {
        guard markdown.hasPrefix("---") else { return markdown }
        var lines = markdown.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return markdown }
        for index in lines.indices.dropFirst() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line == "---" || line == "..." else { continue }
            let body = lines[1..<index]
            guard body.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
                  body.allSatisfy(isYAMLLine)
            else { return markdown }
            lines.removeSubrange(0...index)
            return lines.joined(separator: "\n")
        }
        return markdown
    }

    /// `key: value`, `- item`, a comment, an indented continuation, or blank.
    private func isYAMLLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("- ") || trimmed == "-" { return true }
        if line.first == " " || line.first == "\t" { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let key = trimmed[..<colon]
        return !key.isEmpty && !key.contains(" ") || key.hasPrefix("\"") || key.hasPrefix("'")
    }

    // MARK: - Context

    /// State shared across the whole render, including inline rendering.
    private final class Context {
        let references: LinkReferences
        /// Footnote labels in order of first reference; the index is the number.
        var footnoteOrder: [String] = []
        var footnoteReferenceCounts: [String: Int] = [:]
        var footnoteBodies: [String: String] = [:]
        /// Heading ids, matching `BlockStructure.headings` so `#anchors` agree.
        var slugs = SlugGenerator()
        /// Whether the page needs KaTeX or Mermaid.
        var usesMath = false
        var usesMermaid = false
        /// Every heading, for numbering and `[TOC]`: level, text, id.
        var headingLevels: [(level: Int, title: String, id: String)] = []
        var numberer = HeadingNumberer(topLevel: 1)

        init(references: LinkReferences) {
            self.references = references
        }

        /// The footnote's number, and this reference's id.
        func reference(to label: String) -> (number: Int, id: String) {
            let key = normalizeLabel(label)
            if !footnoteOrder.contains(key) { footnoteOrder.append(key) }
            let number = footnoteOrder.firstIndex(of: key)! + 1
            let count = footnoteReferenceCounts[key, default: 0] + 1
            footnoteReferenceCounts[key] = count
            return (number, count == 1 ? "fnref-\(number)" : "fnref-\(number)-\(count)")
        }
    }

    /// Output with the reference renderer's newline rule: `cr()` starts a new
    /// line only if one is not already started.
    private struct Writer {
        var out = ""

        mutating func cr() {
            if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        }

        mutating func write(_ text: String) {
            out += text
        }
    }

    // MARK: - Blocks

    private func render(_ block: Block, into writer: inout Writer, _ context: Context) {
        switch block.kind {
        case .document:
            renderChildren(block, into: &writer, context)

        case .paragraph:
            let tight = block.parent.map(isInTightList) ?? false
            var content = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            if tableOfContents, content.uppercased() == "[TOC]" {
                writer.cr()
                writer.write(tableOfContentsHTML(context))
                writer.cr()
                break
            }
            if extensions.contains(.definitionLists),
               let list = DefinitionList(lines: content.components(separatedBy: "\n")) {
                writer.cr()
                writer.write("<dl>")
                for item in list.items {
                    writer.write("\n<dt>\(inlineHTML(item.term, context))</dt>")
                    for definition in item.definitions {
                        writer.write("\n<dd>\(inlineHTML(definition, context))</dd>")
                    }
                }
                writer.write("\n</dl>")
                writer.cr()
                break
            }
            var checkbox = ""
            // GFM task items: `[ ]` or `[x]` opening the item's first paragraph.
            if let parent = block.parent, case .item = parent.kind, parent.children.first === block,
               let box = taskBox(content) {
                checkbox = box.html
                content = box.rest
            }
            if !tight {
                writer.cr()
                writer.write("<p>")
            }
            writer.write(checkbox + inlineHTML(content, context))
            if !tight {
                writer.write("</p>")
                writer.cr()
            }

        case let .heading(level):
            let content = block.content.trimmingCharacters(in: .whitespacesAndNewlines)
            let characters = Array(content.utf16)
            let id = context.slugs.slug(for: plainText(characters, from: 0, to: characters.count))
            let number = numberHeadings
                ? "<span class=\"heading-number\">\(context.numberer.number(forLevel: level))</span> "
                : ""
            writer.cr()
            writer.write("<h\(level) id=\"\(escape(id))\">\(number)\(inlineHTML(content, context))</h\(level)>")
            writer.cr()

        case .thematicBreak:
            writer.cr()
            writer.write("<hr />")
            writer.cr()

        case let .codeBlock(fence):
            let info = fence?.info ?? ""
            let language = info.split(separator: " ").first.map(String.init) ?? ""
            writer.cr()
            if language.lowercased() == "mermaid" {
                // Left as source for Mermaid to draw in the browser.
                writer.write("<pre class=\"mermaid\">\(escape(block.content))</pre>")
                context.usesMermaid = true
            } else {
                let attribute = language.isEmpty ? "" : " class=\"language-\(escape(language))\""
                writer.write("<pre><code\(attribute)>\(highlightedCode(block.content, info: info))</code></pre>")
            }
            writer.cr()

        case .htmlBlock:
            writer.cr()
            var content = block.content
            if content.hasSuffix("\n") { content.removeLast() }
            writer.write(content)
            writer.cr()

        case .mathBlock:
            // KaTeX finds `\[ … \]` and typesets what is between.
            writer.cr()
            writer.write("<div class=\"math display\">\\[\n\(escape(block.content))\\]</div>")
            writer.cr()
            context.usesMath = true

        case .blockQuote:
            writer.cr()
            writer.write("<blockquote>")
            writer.cr()
            renderChildren(block, into: &writer, context)
            writer.cr()
            writer.write("</blockquote>")
            writer.cr()

        case let .list(data):
            let tag = data.ordered ? "ol" : "ul"
            let start = data.ordered && data.start != 1 ? " start=\"\(data.start)\"" : ""
            writer.cr()
            writer.write("<\(tag)\(start)>")
            writer.cr()
            renderChildren(block, into: &writer, context)
            writer.cr()
            writer.write("</\(tag)>")
            writer.cr()

        case .item:
            writer.write("<li>")
            renderChildren(block, into: &writer, context)
            writer.write("</li>")
            writer.cr()

        case let .footnote(label):
            // Collected now, written in a section at the end.
            let key = normalizeLabel(label)
            guard context.footnoteBodies[key] == nil else { break }
            var body = Writer()
            renderChildren(block, into: &body, context)
            context.footnoteBodies[key] = body.out

        case let .table(alignments):
            writer.cr()
            writer.write(table(block.rows, alignments: alignments, context))
            writer.cr()
        }
    }

    private func renderChildren(_ block: Block, into writer: inout Writer, _ context: Context) {
        for child in block.children { render(child, into: &writer, context) }
    }

    /// Paragraphs directly in an item of a tight list render without `<p>`.
    private func isInTightList(_ parent: Block) -> Bool {
        guard case .item = parent.kind, let list = parent.parent, case let .list(data) = list.kind else { return false }
        return data.tight
    }

    private func taskBox(_ content: String) -> (html: String, rest: String)? {
        for (prefix, checked) in [("[ ]", false), ("[x]", true), ("[X]", true)] where content.hasPrefix(prefix) {
            let rest = content.dropFirst(3)
            guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
            let html = checked ? "<input type=\"checkbox\" checked disabled /> " : "<input type=\"checkbox\" disabled /> "
            return (html, String(rest.drop(while: { $0 == " " || $0 == "\t" })))
        }
        return nil
    }

    private func table(_ rows: [String], alignments: [ColumnAlignment], _ context: Context) -> String {
        func row(_ line: String, cell: String) -> String {
            var cells = MarkdownTable.cells(of: line)
            // A row has as many cells as the header: extra ones go, missing ones are empty.
            if cells.count > alignments.count { cells = Array(cells.prefix(alignments.count)) }
            cells += Array(repeating: "", count: max(0, alignments.count - cells.count))
            var out = "<tr>\n"
            for (column, text) in cells.enumerated() {
                let style = switch alignments[column] {
                case .none: ""
                case .left: " style=\"text-align:left\""
                case .center: " style=\"text-align:center\""
                case .right: " style=\"text-align:right\""
                }
                // An escaped pipe is part of the cell, not a boundary.
                out += "<\(cell)\(style)>\(inlineHTML(text.replacingOccurrences(of: "\\|", with: "|"), context))</\(cell)>\n"
            }
            return out + "</tr>\n"
        }
        guard let header = rows.first else { return "" }
        var out = "<table>\n<thead>\n" + row(header, cell: "th") + "</thead>\n"
        if rows.count > 1 {
            out += "<tbody>\n" + rows.dropFirst().map { row($0, cell: "td") }.joined() + "</tbody>\n"
        }
        return out + "</table>"
    }

    /// Numbered in order of first reference; unreferenced footnotes are dropped.
    private func footnoteSection(_ context: Context) -> String {
        guard !context.footnoteOrder.isEmpty else { return "" }
        var out = "<section class=\"footnotes\">\n<ol>\n"
        for (offset, label) in context.footnoteOrder.enumerated() {
            let number = offset + 1
            var body = (context.footnoteBodies[label] ?? "").trimmingCharacters(in: .newlines)
            let backref = " <a href=\"#fnref-\(number)\" class=\"footnote-backref\">↩</a>"
            // The way back sits at the end of the note's last paragraph.
            if body.hasSuffix("</p>") {
                body.insert(contentsOf: backref, at: body.index(body.endIndex, offsetBy: -4))
            } else {
                body += backref
            }
            out += "<li id=\"fn-\(number)\">\(body)</li>\n"
        }
        return out + "</ol>\n</section>\n"
    }

    /// Math and diagrams are drawn in the browser, by KaTeX and Mermaid
    /// loaded from a CDN, and only when the document has any.
    private func headExtras(_ context: Context) -> String {
        if let scripts { return inlineHeadExtras(context, scripts) }
        var out = ""
        if context.usesMath {
            out += """
            <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.css" />
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/katex.min.js"></script>
            <script defer src="https://cdn.jsdelivr.net/npm/katex@0.16.11/dist/contrib/auto-render.min.js"
              onload="\(Self.renderMathCall)"></script>

            """
        }
        if context.usesMermaid {
            out += """
            <script type="module">
            import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11.4.1/dist/mermaid.esm.min.mjs";
            \(Self.mermaidInitialize)
            </script>

            """
        }
        return out
    }

    private static let renderMathCall = "renderMathInElement(document.body, {delimiters: [{left: '\\\\[', right: '\\\\]', display: true}, {left: '\\\\(', right: '\\\\)', display: false}], ignoredClasses: ['mermaid']})"
    private static let mermaidInitialize = "mermaid.initialize({ startOnLoad: true, theme: matchMedia(\"(prefers-color-scheme: dark)\").matches ? \"dark\" : \"default\" });"

    /// The same, with the libraries' text in the page.
    private func inlineHeadExtras(_ context: Context, _ scripts: ScriptAssets) -> String {
        // Script text must not close its own element early.
        func script(_ source: String) -> String {
            source.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
        }
        var out = ""
        if context.usesMath {
            out += "<style>\n\(scripts.katexCSS)\n</style>\n"
            out += "<script>\n\(script(scripts.katexJS))\n</script>\n"
            out += "<script>\n\(script(scripts.autoRenderJS))\n</script>\n"
            out += "<script>\ndocument.addEventListener(\"DOMContentLoaded\", () => \(Self.renderMathCall));\n</script>\n"
        }
        if context.usesMermaid {
            out += "<script>\n\(script(scripts.mermaidJS))\n</script>\n"
            out += "<script>\n\(Self.mermaidInitialize)\n</script>\n"
        }
        return out
    }

    // MARK: - Table of contents

    /// Headings in document order, with the ids rendering will give them.
    private func headingLevels(in document: Block) -> [(level: Int, title: String, id: String)] {
        var slugs = SlugGenerator()
        var result: [(Int, String, String)] = []
        func walk(_ block: Block) {
            if case let .heading(level) = block.kind {
                let characters = Array(block.content.trimmingCharacters(in: .whitespacesAndNewlines).utf16)
                let title = plainText(characters, from: 0, to: characters.count)
                result.append((level, title, slugs.slug(for: title)))
            }
            block.children.forEach(walk)
        }
        walk(document)
        return result
    }

    /// A nested list of links to every heading.
    private func tableOfContentsHTML(_ context: Context) -> String {
        guard !context.headingLevels.isEmpty else { return "" }
        var numberer = HeadingNumberer(topLevel: context.headingLevels.map(\.level).min() ?? 1)
        let top = context.headingLevels.map(\.level).min() ?? 1
        var out = "<nav class=\"toc\">\n<ul>\n"
        var depth = 0
        var first = true
        for heading in context.headingLevels {
            let target = heading.level - top
            if first {
                // A first heading deeper than the top still opens at depth 0.
                first = false
            } else if target > depth {
                for _ in depth..<target { out += "\n<ul>\n" }
                depth = target
            } else {
                out += "</li>\n"
                while depth > max(target, 0) {
                    out += "</ul>\n</li>\n"
                    depth -= 1
                }
            }
            let number = numberHeadings ? "<span class=\"heading-number\">\(numberer.number(forLevel: heading.level))</span> " : ""
            out += "<li><a href=\"#\(escape(heading.id))\">\(number)\(escape(heading.title))</a>"
        }
        out += "</li>\n"
        while depth > 0 {
            out += "</ul>\n</li>\n"
            depth -= 1
        }
        return out + "</ul>\n</nav>"
    }

    // MARK: - Code

    /// Wraps each token in a span so exported code carries the same colours
    /// the editor shows.
    private func highlightedCode(_ code: String, info: String) -> String {
        guard let language = Language.named(info), !code.isEmpty else { return escape(code) }
        let lines = code.components(separatedBy: "\n")
        let tokens = SyntaxHighlighter.tokens(code: code, language: language)
        return zip(lines, tokens).map { line, lineTokens in
            highlighted(Array(line.utf16), tokens: lineTokens)
        }.joined(separator: "\n")
    }

    private func highlighted(_ characters: [UInt16], tokens: [Token]) -> String {
        var out = ""
        var cursor = 0
        for token in tokens.sorted(by: { $0.range.location < $1.range.location }) {
            guard token.range.location >= cursor else { continue }
            if token.range.location > cursor {
                out += escape(string(characters, from: cursor, to: token.range.location))
            }
            let text = escape(string(characters, from: token.range.location, to: NSMaxRange(token.range)))
            out += "<span class=\"tok-\(cssClass(for: token.kind))\">\(text)</span>"
            cursor = NSMaxRange(token.range)
        }
        if cursor < characters.count {
            out += escape(string(characters, from: cursor, to: characters.count))
        }
        return out
    }

    private func cssClass(for kind: TokenKind) -> String {
        switch kind {
        case .keyword: "keyword"
        case .type: "type"
        case .constant: "constant"
        case .string: "string"
        case .number: "number"
        case .comment: "comment"
        case .function: "function"
        case .variable: "variable"
        case .attribute: "attribute"
        case .tag: "tag"
        case .inserted: "inserted"
        case .deleted: "deleted"
        }
    }

    // MARK: - Inlines

    private func inlineHTML(_ content: String, _ context: Context) -> String {
        let characters = Array(content.utf16)
        guard !characters.isEmpty else { return "" }
        return nodesHTML(InlineParser.parse(characters, references: context.references), characters, context)
    }

    private func nodesHTML(_ nodes: [InlineNode], _ characters: [UInt16], _ context: Context) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case let .text(range):
                out += escape(text(characters, range))
            case let .code(_, content, _):
                out += "<code>\(escape(codeSpanText(text(characters, content))))</code>"
            case let .emphasis(_, _, children):
                out += "<em>\(nodesHTML(children, characters, context))</em>"
            case let .strong(_, _, children):
                out += "<strong>\(nodesHTML(children, characters, context))</strong>"
            case let .strikethrough(_, _, children):
                out += "<del>\(nodesHTML(children, characters, context))</del>"
            case let .highlight(_, _, children):
                out += "<mark>\(nodesHTML(children, characters, context))</mark>"
            case let .math(_, _, content, display):
                let tex = escape(text(characters, content))
                out += display ? "<span class=\"math display\">\\[\(tex)\\]</span>" : "<span class=\"math inline\">\\(\(tex)\\)</span>"
                context.usesMath = true
            case let .superscript(_, _, children):
                out += "<sup>\(nodesHTML(children, characters, context))</sup>"
            case let .subscript(_, _, children):
                out += "<sub>\(nodesHTML(children, characters, context))</sub>"
            case let .emoji(_, _, shortcode, emoji):
                out += "<span class=\"emoji\" title=\":\(escape(shortcode)):\">\(emoji)</span>"
            case let .footnoteReference(_, _, label):
                let reference = context.reference(to: label)
                out += "<sup class=\"footnote-ref\"><a href=\"#fn-\(reference.number)\" id=\"\(reference.id)\">\(reference.number)</a></sup>"
            case let .link(_, _, destination, title, children):
                let titleAttribute = title.map { " title=\"\(escape($0))\"" } ?? ""
                out += "<a href=\"\(escape(normalizeURL(resolve(destination))))\"\(titleAttribute)>\(nodesHTML(children, characters, context))</a>"
            case let .image(_, _, source, alt, title):
                let titleAttribute = title.map { " title=\"\(escape($0))\"" } ?? ""
                let src = (embedImages ? dataURI(forImage: source) : nil) ?? normalizeURL(resolve(source))
                out += "<img src=\"\(escape(src))\" alt=\"\(escape(alt))\"\(titleAttribute) />"
            case let .autolink(range, markers, url):
                // Shown as written: `www.x.dev`, or the address without `mailto:`.
                let shown = markers.count == 2
                    ? NSRange(location: range.location + 1, length: range.length - 2)
                    : range
                out += "<a href=\"\(escape(normalizeURL(url)))\">\(escape(text(characters, shown)))</a>"
            case let .escape(_, _, character):
                out += escape(text(characters, character))
            case let .entity(_, decoded):
                out += escape(decoded)
            case let .lineBreak(_, hard):
                out += hard ? "<br />\n" : "\n"
            case let .rawHTML(range):
                out += text(characters, range)
            }
        }
        return out
    }

    private func text(_ characters: [UInt16], _ range: NSRange) -> String {
        string(characters, from: range.location, to: NSMaxRange(range))
    }

    /// Relative paths only resolve when the document has been saved somewhere.
    private func resolve(_ destination: String) -> String {
        guard let baseURL,
              !destination.isEmpty,
              URL(string: destination)?.scheme == nil,
              !destination.hasPrefix("#"),
              !destination.hasPrefix("/")
        else { return destination }
        return URL(fileURLWithPath: destination, relativeTo: baseURL.deletingLastPathComponent()).absoluteString
    }

    /// A local image's bytes as a `data:` URI; nil for web images and
    /// files that cannot be read, which keep their address.
    private func dataURI(forImage source: String) -> String? {
        let file: URL
        if let url = URL(string: source), let scheme = url.scheme {
            guard scheme == "file" else { return nil }
            file = url
        } else {
            let path = ((source.removingPercentEncoding ?? source) as NSString).expandingTildeInPath
            if path.hasPrefix("/") {
                file = URL(fileURLWithPath: path)
            } else if let baseURL {
                file = URL(fileURLWithPath: path, relativeTo: baseURL.deletingLastPathComponent())
            } else {
                return nil
            }
        }
        let types = [
            "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
            "svg": "image/svg+xml", "webp": "image/webp", "heic": "image/heic", "bmp": "image/bmp",
            "tif": "image/tiff", "tiff": "image/tiff", "avif": "image/avif",
        ]
        guard let type = types[file.pathExtension.lowercased()], let data = try? Data(contentsOf: file) else { return nil }
        return "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// Percent-encodes what a URL may not contain, leaving existing `%XX`
    /// escapes and URL punctuation alone, as the reference renderer does.
    private func normalizeURL(_ url: String) -> String {
        let safe = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789;/?:@&=+$,-_.!~*'()#".utf8)
        let bytes = Array(url.utf8)
        var out = ""
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "%"), index + 2 < bytes.count,
               isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                out += String(decoding: bytes[index...(index + 2)], as: UTF8.self)
                index += 3
                continue
            }
            if safe.contains(byte) {
                out.append(Character(Unicode.Scalar(byte)))
            } else {
                out += String(format: "%%%02X", byte)
            }
            index += 1
        }
        return out
    }

    private func isHex(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    private func escape(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }
}
