import Foundation

/// Renders markdown to HTML for export and "Copy as HTML".
///
/// Walks the same `BlockStructure` and `InlineParser` the editor styles with,
/// so what you export is what the editor understood.
public struct HTMLRenderer {
    /// Resolves relative image and link paths, when the document has a location.
    public var baseURL: URL?

    public init(baseURL: URL? = nil) {
        self.baseURL = baseURL
    }

    public func render(markdown: String) -> String {
        let text = markdown as NSString
        let structure = BlockStructure(text: text)
        var out = ""
        var state = RenderState()
        let context = Context(references: .collect(from: structure, requireDefinitions: true))

        var line = 0
        while line < structure.lineCount {
            guard let info = structure.info(forLine: line) else { break }
            let characters = structure.characters(of: text, line: line)
            let next = structure.info(forLine: line + 1)

            adjustQuotes(to: info.quoteDepth, state: &state, out: &out)

            // Paragraph lines straight after a footnote definition continue it.
            if let footnote = state.currentFootnote {
                if info.kind == .paragraph {
                    context.footnoteBodies[footnote, default: ""] += "\n" + inlineHTML(characters, from: info.contentStart, to: characters.count, context)
                    line += 1
                    continue
                }
                state.currentFootnote = nil
            }

            switch info.kind {
            case .blank:
                closeParagraph(&state, &out)
                closeTable(&state, &out)
                closeLists(to: 0, state: &state, out: &out)

            case let .atxHeading(level):
                closeParagraph(&state, &out)
                out += "<h\(level)>\(inlineHTML(characters, from: info.contentStart, to: headingEnd(info, characters), context))</h\(level)>\n"

            case .setextUnderline:
                break  // consumed by the paragraph above

            case .thematicBreak:
                closeParagraph(&state, &out)
                out += "<hr />\n"

            case let .fenceStart(language):
                closeParagraph(&state, &out)
                let attribute = language.isEmpty ? "" : " class=\"language-\(escape(language.components(separatedBy: " ")[0]))\""
                out += "<pre><code\(attribute)>"
                state.inCodeBlock = true
                state.codeLanguage = info.state.fence?.language

            case .fenceEnd:
                out += "</code></pre>\n"
                state.inCodeBlock = false
                state.codeLanguage = nil

            case .codeLine:
                if state.codeLanguage != nil, !info.tokens.isEmpty {
                    out += highlighted(characters, from: info.contentStart, tokens: info.tokens) + "\n"
                } else {
                    out += escape(string(characters, from: info.contentStart, to: characters.count)) + "\n"
                }

            case .indentedCode:
                if !state.inIndentedCode {
                    closeParagraph(&state, &out)
                    out += "<pre><code>"
                    state.inIndentedCode = true
                }
                out += escape(string(characters, from: min(4, characters.count), to: characters.count)) + "\n"
                if next?.kind != .indentedCode {
                    out += "</code></pre>\n"
                    state.inIndentedCode = false
                }

            case let .listItem(ordered, task):
                closeParagraph(&state, &out)
                openLists(to: info.listDepth, ordered: ordered, state: &state, out: &out)
                let box = switch task {
                case .unchecked: "<input type=\"checkbox\" disabled /> "
                case .checked: "<input type=\"checkbox\" checked disabled /> "
                case nil: ""
                }
                out += "<li>\(box)\(inlineHTML(characters, from: info.contentStart, to: characters.count, context))</li>\n"

            case .paragraph:
                // A paragraph followed by `===` or `---` is a heading.
                if case let .setextUnderline(level)? = next?.kind {
                    closeParagraph(&state, &out)
                    out += "<h\(level)>\(inlineHTML(characters, from: info.contentStart, to: characters.count, context))</h\(level)>\n"
                    break
                }
                // A paragraph followed by `| --- |` is a table header.
                if case let .tableDelimiter(alignments)? = next?.kind {
                    closeParagraph(&state, &out)
                    out += "<table>\n<thead>\n"
                    out += row(characters, from: info.contentStart, alignments: alignments, cell: "th", context)
                    out += "</thead>\n<tbody>\n"
                    state.tableAlignments = alignments
                    state.inTable = true
                    break
                }
                closeLists(to: 0, state: &state, out: &out)
                if !state.inParagraph {
                    out += "<p>"
                    state.inParagraph = true
                } else {
                    out += state.pendingHardBreak ? "<br />\n" : "\n"
                }
                // A line ending in two spaces or a backslash breaks before the next.
                let continues = next?.kind == .paragraph
                let (end, hardBreak) = paragraphLineEnd(characters, from: info.contentStart, continues: continues)
                out += inlineHTML(characters, from: info.contentStart, to: end, context)
                state.pendingHardBreak = hardBreak

            case .tableDelimiter:
                break  // consumed by the header row

            case .tableRow:
                out += row(characters, from: info.contentStart, alignments: state.tableAlignments, cell: "td", context)

            case .frontMatterDelimiter, .frontMatter, .linkReferenceDefinition:
                // Metadata and definitions shape the output but are not part of it.
                closeParagraph(&state, &out)

            case .htmlBlock:
                closeParagraph(&state, &out)
                closeTable(&state, &out)
                closeLists(to: 0, state: &state, out: &out)
                out += string(characters, from: info.contentStart, to: characters.count) + "\n"

            case let .footnoteDefinition(label):
                closeParagraph(&state, &out)
                let key = normalizeLabel(label)
                // The first definition of a label wins, as with links.
                guard context.footnoteBodies[key] == nil else { break }
                context.footnoteBodies[key] = inlineHTML(characters, from: info.contentStart, to: characters.count, context)
                state.currentFootnote = key
            }

            line += 1
        }

        closeParagraph(&state, &out)
        closeTable(&state, &out)
        closeLists(to: 0, state: &state, out: &out)
        adjustQuotes(to: 0, state: &state, out: &out)
        if state.inCodeBlock || state.inIndentedCode { out += "</code></pre>\n" }
        out += footnoteSection(context)
        return out
    }

    /// Numbered in order of first reference; unreferenced footnotes are dropped.
    private func footnoteSection(_ context: Context) -> String {
        guard !context.footnoteOrder.isEmpty else { return "" }
        var out = "<section class=\"footnotes\">\n<ol>\n"
        for (offset, label) in context.footnoteOrder.enumerated() {
            let number = offset + 1
            let body = context.footnoteBodies[label] ?? ""
            out += "<li id=\"fn-\(number)\"><p>\(body) <a href=\"#fnref-\(number)\" class=\"footnote-backref\">↩</a></p></li>\n"
        }
        return out + "</ol>\n</section>\n"
    }

    /// Where a paragraph line's text ends, and whether it ends in a hard break.
    private func paragraphLineEnd(_ characters: [UInt16], from start: Int, continues: Bool) -> (Int, Bool) {
        var end = characters.count
        var spaces = 0
        while end > start, characters[end - 1] == UInt16(ascii: " ") {
            end -= 1
            spaces += 1
        }
        guard continues else { return (end, false) }
        if spaces >= 2 { return (end, true) }
        var backslashes = 0
        while end - backslashes > start, characters[end - backslashes - 1] == UInt16(ascii: "\\") { backslashes += 1 }
        if spaces == 0, backslashes % 2 == 1 { return (end - 1, true) }
        return (end, false)
    }

    /// A full standalone page, for Export as HTML.
    public func renderDocument(markdown: String, title: String, css: String) -> String {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>\(escape(title))</title>
        <style>
        \(css)
        </style>
        </head>
        <body>
        \(render(markdown: markdown))
        </body>
        </html>

        """
    }

    // MARK: - Blocks

    /// State shared across the whole render, including inline rendering.
    private final class Context {
        let references: LinkReferences
        /// Footnote labels in order of first reference; the index is the number.
        var footnoteOrder: [String] = []
        var footnoteReferenceCounts: [String: Int] = [:]
        var footnoteBodies: [String: String] = [:]

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

    private struct RenderState {
        var pendingHardBreak = false
        var currentFootnote: String?
        var inParagraph = false
        var inCodeBlock = false
        var inIndentedCode = false
        var inTable = false
        var codeLanguage: Language?
        var tableAlignments: [ColumnAlignment] = []
        var listStack: [Bool] = []  // true = ordered
        var quoteDepth = 0
    }

    private func closeParagraph(_ state: inout RenderState, _ out: inout String) {
        if state.inParagraph {
            out += "</p>\n"
            state.inParagraph = false
        }
        state.pendingHardBreak = false
    }

    private func closeTable(_ state: inout RenderState, _ out: inout String) {
        if state.inTable {
            out += "</tbody>\n</table>\n"
            state.inTable = false
            state.tableAlignments = []
        }
    }

    private func openLists(to depth: Int, ordered: Bool, state: inout RenderState, out: inout String) {
        while state.listStack.count > depth {
            out += state.listStack.removeLast() ? "</ol>\n" : "</ul>\n"
        }
        while state.listStack.count < depth {
            out += ordered ? "<ol>\n" : "<ul>\n"
            state.listStack.append(ordered)
        }
        // A bullet list following a numbered one at the same depth restarts.
        if let top = state.listStack.last, top != ordered {
            out += top ? "</ol>\n" : "</ul>\n"
            out += ordered ? "<ol>\n" : "<ul>\n"
            state.listStack[state.listStack.count - 1] = ordered
        }
    }

    private func closeLists(to depth: Int, state: inout RenderState, out: inout String) {
        while state.listStack.count > depth {
            out += state.listStack.removeLast() ? "</ol>\n" : "</ul>\n"
        }
    }

    private func adjustQuotes(to depth: Int, state: inout RenderState, out: inout String) {
        while state.quoteDepth > depth {
            closeParagraph(&state, &out)
            closeLists(to: 0, state: &state, out: &out)
            out += "</blockquote>\n"
            state.quoteDepth -= 1
        }
        while state.quoteDepth < depth {
            closeParagraph(&state, &out)
            out += "<blockquote>\n"
            state.quoteDepth += 1
        }
    }

    /// The end of a heading's text, excluding any closing `###`.
    private func headingEnd(_ info: LineInfo, _ characters: [UInt16]) -> Int {
        if let closing = info.markers.last, closing.kind == .conceal, closing.range.location > info.contentStart,
           NSMaxRange(closing.range) == characters.count, info.markers.count > 1 {
            return closing.range.location
        }
        return characters.count
    }

    private func row(_ characters: [UInt16], from start: Int, alignments: [ColumnAlignment], cell: String, _ context: Context) -> String {
        var out = "<tr>\n"
        for (column, field) in cells(characters, from: start).enumerated() {
            let alignment = column < alignments.count ? alignments[column] : ColumnAlignment.none
            let style = switch alignment {
            case .none: ""
            case .left: " style=\"text-align:left\""
            case .center: " style=\"text-align:center\""
            case .right: " style=\"text-align:right\""
            }
            out += "<\(cell)\(style)>\(inlineHTML(field, from: 0, to: field.count, context))</\(cell)>\n"
        }
        return out + "</tr>\n"
    }

    /// Splits a table row on unescaped pipes, dropping the optional outer ones.
    private func cells(_ characters: [UInt16], from start: Int) -> [[UInt16]] {
        var fields: [[UInt16]] = []
        var current: [UInt16] = []
        var cursor = start
        if cursor < characters.count, characters[cursor] == UInt16(ascii: "|") { cursor += 1 }
        while cursor < characters.count {
            let character = characters[cursor]
            if character == UInt16(ascii: "\\"), cursor + 1 < characters.count {
                current.append(character)
                current.append(characters[cursor + 1])
                cursor += 2
                continue
            }
            if character == UInt16(ascii: "|") {
                fields.append(trim(current))
                current = []
            } else {
                current.append(character)
            }
            cursor += 1
        }
        let last = trim(current)
        if !last.isEmpty { fields.append(last) }
        return fields
    }

    private func trim(_ characters: [UInt16]) -> [UInt16] {
        var low = 0
        var high = characters.count
        while low < high, isSpaceOrTab(characters[low]) { low += 1 }
        while high > low, isSpaceOrTab(characters[high - 1]) { high -= 1 }
        return Array(characters[low..<high])
    }

    /// Wraps each token in a span so exported code carries the same colours the
    /// editor shows.
    private func highlighted(_ characters: [UInt16], from start: Int, tokens: [Token]) -> String {
        var out = ""
        var cursor = start
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

    private func inlineHTML(_ characters: [UInt16], from low: Int, to high: Int, _ context: Context) -> String {
        guard low < high else { return "" }
        return nodesHTML(InlineParser.parse(characters, from: low, to: high, references: context.references), characters, context)
    }

    private func nodesHTML(_ nodes: [InlineNode], _ characters: [UInt16], _ context: Context) -> String {
        var out = ""
        for node in nodes {
            switch node {
            case let .text(range):
                out += escape(text(characters, range))
            case let .code(_, content, _):
                out += "<code>\(escape(text(characters, content)))</code>"
            case let .emphasis(_, _, children):
                out += "<em>\(nodesHTML(children, characters, context))</em>"
            case let .strong(_, _, children):
                out += "<strong>\(nodesHTML(children, characters, context))</strong>"
            case let .strikethrough(_, _, children):
                out += "<del>\(nodesHTML(children, characters, context))</del>"
            case let .link(_, _, destination, title, children):
                let titleAttribute = title.map { " title=\"\(escape($0))\"" } ?? ""
                out += "<a href=\"\(escape(resolve(destination)))\"\(titleAttribute)>\(nodesHTML(children, characters, context))</a>"
            case let .image(_, _, source, alt):
                out += "<img src=\"\(escape(resolve(source)))\" alt=\"\(escape(alt))\" />"
            case let .highlight(_, _, children):
                out += "<mark>\(nodesHTML(children, characters, context))</mark>"
            case let .footnoteReference(_, _, label):
                let reference = context.reference(to: label)
                out += "<sup class=\"footnote-ref\"><a href=\"#fn-\(reference.number)\" id=\"\(reference.id)\">\(reference.number)</a></sup>"
            case let .autolink(range, markers, url):
                // Shown as written: `www.x.dev`, or the address without `mailto:`.
                let shown = markers.count == 2
                    ? NSRange(location: range.location + 1, length: range.length - 2)
                    : range
                out += "<a href=\"\(escape(url))\">\(escape(text(characters, shown)))</a>"
            case let .escape(_, _, character):
                out += escape(text(characters, character))
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
