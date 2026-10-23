import Foundation
import MarkdownKit

/// Converts pasted HTML — from browsers, Google Docs, Notion, Coda and the
/// like — into markdown, so formatted text pastes as formatting rather than
/// as plain words or raw tags.
enum HTMLToMarkdown {
    /// Tags whose presence makes HTML worth converting. Editors such as VS
    /// Code put coloured `<span>`s on the pasteboard for plain code; those
    /// should paste as the plain text beside them.
    private static let meaningfulTags: Set<String> = [
        "h1", "h2", "h3", "h4", "h5", "h6", "strong", "b", "em", "i", "a", "ul", "ol", "li",
        "table", "img", "blockquote", "pre", "code", "hr", "del", "s", "strike", "mark", "sup", "sub",
    ]

    /// Markdown for the HTML, or nil when it has no formatting worth keeping.
    static func convert(_ html: String) -> String? {
        // Parsing and converting both recurse once per level: markup nested
        // past any real page's depth overflowed the stack. It pastes as text.
        guard nestingDepth(of: html) <= maxNesting else { return nil }
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]),
              let root = document.rootElement()
        else { return nil }
        let body = root.elements(forName: "body").first ?? root
        guard containsMeaningfulTag(body) else { return nil }
        let markdown = Converter().blocks(of: body).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown.isEmpty ? nil : markdown
    }

    static let maxNesting = 1000

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr",
    ]

    /// How deeply the tags nest, roughly: opening tags less closing ones,
    /// leaving out those that never close.
    static func nestingDepth(of html: String) -> Int {
        let bytes = Array(html.utf8)
        var depth = 0, deepest = 0, index = 0
        // The first `>` at or after where the last search began. Searched
        // afresh for every tag, a run of `<a` with none closed scanned to
        // the end each time.
        var nextClose = -1
        while index < bytes.count {
            defer { index += 1 }
            guard bytes[index] == UInt8(ascii: "<"), index + 1 < bytes.count else { continue }
            let next = bytes[index + 1]
            if next == UInt8(ascii: "/") {
                depth = max(0, depth - 1)
                continue
            }
            guard (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(next | 0x20) else { continue }
            var end = index + 1
            while end < bytes.count, (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(bytes[end] | 0x20) || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]) {
                end += 1
            }
            let name = String(decoding: bytes[(index + 1)..<end], as: UTF8.self).lowercased()
            guard !voidTags.contains(name) else { continue }
            if nextClose < end {
                nextClose = end
                while nextClose < bytes.count, bytes[nextClose] != UInt8(ascii: ">") { nextClose += 1 }
            }
            let close = nextClose
            if close > 0, close < bytes.count, bytes[close - 1] == UInt8(ascii: "/") { continue }
            depth += 1
            deepest = max(deepest, depth)
        }
        return deepest
    }

    private static func containsMeaningfulTag(_ element: XMLElement) -> Bool {
        if let name = element.name?.lowercased(), meaningfulTags.contains(name), !isPlainWrapper(element) { return true }
        if hasFormattingStyle(element) || headingLevel(of: element) != nil { return true }
        return element.children?.contains { ($0 as? XMLElement).map(containsMeaningfulTag) ?? false } ?? false
    }

    /// The element's inline style, lowercased and without spaces.
    fileprivate static func style(of element: XMLElement) -> String {
        element.attribute(forName: "style")?.stringValue?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
    }

    fileprivate static func isBold(_ style: String) -> Bool {
        style.range(of: #"font-weight:(bold|bolder|[6-9]00)"#, options: .regularExpression) != nil
    }

    fileprivate static func isItalic(_ style: String) -> Bool {
        style.contains("font-style:italic") || style.contains("font-style:oblique")
    }

    fileprivate static func isStruck(_ style: String) -> Bool {
        style.contains("text-decoration:line-through") || style.contains("text-decoration-line:line-through")
    }

    /// Bold, italic or struck-through by inline style, as Google Docs and Coda do it.
    fileprivate static func hasFormattingStyle(_ element: XMLElement) -> Bool {
        let style = style(of: element)
        return isBold(style) || isItalic(style) || isStruck(style)
    }

    /// Google Docs wraps a whole paste in `<b style="font-weight:normal">`.
    fileprivate static func isPlainWrapper(_ element: XMLElement) -> Bool {
        guard let name = element.name?.lowercased(), name == "b" || name == "strong" else { return false }
        let style = style(of: element)
        return style.contains("font-weight:normal") || style.contains("font-weight:400")
    }

    /// An `<h1>`–`<h6>`, or anything marked up as a heading for assistive
    /// technology, as some web editors do instead.
    fileprivate static func headingLevel(of element: XMLElement) -> Int? {
        guard let name = element.name?.lowercased() else { return nil }
        if name.count == 2, name.first == "h", let level = Int(name.dropFirst()), (1...6).contains(level) { return level }
        guard element.attribute(forName: "role")?.stringValue?.lowercased() == "heading" else { return nil }
        let level = Int(element.attribute(forName: "aria-level")?.stringValue ?? "") ?? 2
        return min(max(level, 1), 6)
    }
}

private struct Converter {
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure", "figcaption",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "table", "hr", "dl", "dt", "dd",
        "details", "summary",
    ]
    /// Links that run code rather than go somewhere. Browsers ignore case,
    /// surrounding spaces and tabs or newlines inside the scheme, and so
    /// does this.
    static func runsScript(_ href: String) -> Bool {
        let scheme = href.unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0) }
            .prefix(12)
        let lowered = String(String.UnicodeScalarView(scheme)).lowercased()
        return ["javascript:", "vbscript:", "data:"].contains { lowered.hasPrefix($0) }
    }

    private static let skippedTags: Set<String> = ["script", "style", "head", "meta", "title", "noscript", "template"]

    /// Stands for a `<br>` until whitespace has collapsed around it.
    private static let lineBreak = "\u{1}"

    // MARK: - Blocks

    /// The markdown blocks of an element's children: runs of inline content
    /// become paragraphs, block elements become their own blocks.
    func blocks(of element: XMLElement) -> [String] {
        var result: [String] = []
        var inline: [XMLNode] = []
        // Notion puts each list item in a list of its own; side by side they
        // are one list, not several separated by blank lines.
        var lastList: String?

        func flush() {
            let text = paragraph(inlineText(inline))
            if !text.isEmpty {
                result.append(text)
                lastList = nil
            }
            inline = []
        }

        for child in element.children ?? [] {
            guard let child = child as? XMLElement, let name = child.name?.lowercased() else {
                inline.append(child)
                continue
            }
            if Self.skippedTags.contains(name) { continue }
            if Self.blockTags.contains(name) || HTMLToMarkdown.headingLevel(of: child) != nil
                || (isWrapper(name) && containsBlock(child)) {
                flush()
                // Coda draws a to-do as a block led by a checkbox, not a list
                // item, and tidying turns the list around them into a block too.
                if let checked = leadingCheckbox(of: child) {
                    var text = blocks(of: child).joined(separator: "\n")
                    text = text.split(separator: "\n", omittingEmptySubsequences: false)
                        .enumerated().map { $0.offset == 0 ? String($0.element) : (($0.element.isEmpty ? "" : "      ") + $0.element) }
                        .joined(separator: "\n")
                    let item = (checked ? "- [x] " : "- [ ] ") + text
                    if lastList == "ul", let last = result.indices.last {
                        result[last] += "\n" + item
                    } else {
                        result.append(item)
                        lastList = "ul"
                    }
                    continue
                }
                let blocks = block(child, name: name)
                if name == "ul" || name == "ol", let list = blocks.first, lastList == name, let last = result.indices.last {
                    result[last] += "\n" + list
                } else {
                    result += blocks
                    lastList = blocks.isEmpty ? lastList : (name == "ul" || name == "ol" ? name : nil)
                }
            } else {
                inline.append(child)
            }
        }
        flush()
        return result
    }

    /// Whether a block starts with a checkbox, before any text: ticked or not.
    private func leadingCheckbox(of element: XMLElement) -> Bool? {
        guard !["ul", "ol", "li", "table", "pre"].contains(element.name?.lowercased() ?? "") else { return nil }
        for node in element.children ?? [] {
            if node.kind == .text {
                guard (node.stringValue ?? "").allSatisfy(\.isWhitespace) else { return nil }
                continue
            }
            guard let child = node as? XMLElement else { continue }
            if child.name?.lowercased() == "input" {
                guard child.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox" else { return nil }
                return child.attribute(forName: "checked") != nil
            }
            return nil
        }
        return nil
    }

    private func isWrapper(_ name: String) -> Bool {
        ["span", "b", "strong", "font", "body", "html", "label"].contains(name)
    }

    private func containsBlock(_ element: XMLElement) -> Bool {
        element.children?.contains { node in
            guard let child = node as? XMLElement, let name = child.name?.lowercased() else { return false }
            return Self.blockTags.contains(name) || containsBlock(child)
        } ?? false
    }

    private func block(_ element: XMLElement, name: String) -> [String] {
        if let level = HTMLToMarkdown.headingLevel(of: element) {
            var text = inlineText(element.children ?? [])
                .replacingOccurrences(of: Self.lineBreak, with: " ")
                .trimmingCharacters(in: .whitespaces)
            // A heading is bold already: editors that bold its text as well
            // would put `**` around the whole of it.
            if text.count > 4, text.hasPrefix("**"), text.hasSuffix("**"), !text.dropFirst(2).dropLast(2).contains("**") {
                text = String(text.dropFirst(2).dropLast(2))
            }
            return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
        }
        switch name {
        case "hr":
            return ["---"]
        case "ul", "ol":
            let list = self.list(element, ordered: name == "ol")
            return list.isEmpty ? [] : [list]
        case "blockquote":
            let inner = blocks(of: element).joined(separator: "\n\n")
            return inner.isEmpty ? [] : [inner.split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")]
        case "pre":
            return [codeBlock(element)]
        case "table":
            return table(element).map { [$0] } ?? []
        default:
            // Paragraph-like containers, and wrappers that hold blocks.
            return blocks(of: element)
        }
    }

    private func list(_ element: XMLElement, ordered: Bool) -> String {
        // CommonMark list numbers have at most nine digits; a page's `start`
        // can be anything, and counting on from Int.max would trap.
        let start = Int(element.attribute(forName: "start")?.stringValue?.trimmingCharacters(in: .whitespaces) ?? "") ?? 1
        var number = min(max(start, 0), 999_999_999)
        var lines: [String] = []
        var indent = ""
        for case let child as XMLElement in element.children ?? [] {
            let name = child.name?.lowercased()
            // Google Docs nests a list straight inside its list, not inside an
            // item, and tidying puts it in an unmarked item of its own: either
            // way it belongs to the item before it.
            if let nested = strayList(child) {
                lines += list(nested, ordered: nested.name?.lowercased() == "ol")
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .map { $0.isEmpty ? "" : indent + $0 }
                continue
            }
            guard name == "li" else { continue }
            let marker = ordered ? "\(number). " : "- "
            number += 1
            indent = String(repeating: " ", count: marker.count)
            var content = blocks(of: child).joined(separator: "\n")
            var prefix = ""
            if let checked = taskState(of: child) {
                prefix = checked ? "[x] " : "[ ] "
            } else if let typed = ["\\[ \\] ": "[ ] ", "\\[x\\] ": "[x] ", "\\[X\\] ": "[x] "].first(where: { content.hasPrefix($0.key) }) {
                // A to-do copied as text, its box typed out as brackets.
                prefix = typed.value
                content.removeFirst(typed.key.count)
            }
            let itemLines = (prefix + content).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in itemLines.enumerated() {
                lines.append(index == 0 ? marker + line : (line.isEmpty ? "" : indent + line))
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A list in a list with no item of its own around it.
    private func strayList(_ element: XMLElement) -> XMLElement? {
        let name = element.name?.lowercased()
        if name == "ul" || name == "ol" { return element }
        guard name == "li", HTMLToMarkdown.style(of: element).contains("list-style:none") else { return nil }
        let children = (element.children ?? []).filter {
            !($0.kind == .text && ($0.stringValue ?? "").allSatisfy(\.isWhitespace))
        }
        guard children.count == 1, let only = children.first as? XMLElement,
              ["ul", "ol"].contains(only.name?.lowercased() ?? "")
        else { return nil }
        return only
    }

    /// Whether a list item is a ticked or unticked to-do, however the page
    /// draws its box: a checkbox input, `data-checked` as ProseMirror-based
    /// editors write it, an ARIA checkbox, or Notion's `checkbox-on` class.
    private func taskState(of item: XMLElement) -> Bool? {
        if let checked = item.attribute(forName: "data-checked")?.stringValue?.lowercased() {
            return checked == "true"
        }
        func search(_ element: XMLElement) -> Bool? {
            for case let child as XMLElement in element.children ?? [] {
                let name = child.name?.lowercased() ?? ""
                if name == "ul" || name == "ol" { continue }  // a nested item's box is its own
                if name == "input", child.attribute(forName: "type")?.stringValue?.lowercased() == "checkbox" {
                    return child.attribute(forName: "checked") != nil
                }
                if child.attribute(forName: "role")?.stringValue?.lowercased() == "checkbox" {
                    return child.attribute(forName: "aria-checked")?.stringValue?.lowercased() == "true"
                }
                let classes = (child.attribute(forName: "class")?.stringValue ?? "").split(separator: " ")
                if classes.contains("checkbox-on") { return true }
                if classes.contains("checkbox-off") { return false }
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(item)
    }

    private func codeBlock(_ element: XMLElement) -> String {
        let code = element.elements(forName: "code").first
        let named = [element, code].lazy.compactMap { $0?.attribute(forName: "data-language")?.stringValue }.first
        let classes = [element, code].compactMap { $0?.attribute(forName: "class")?.stringValue }.joined(separator: " ")
        let language = (named ?? classes.split(separator: " ")
            .first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
            .map { String($0.split(separator: "-", maxSplits: 1).last ?? "") } ?? "")
            .lowercased().filter { !$0.isWhitespace && $0 != "`" }
        var text = codeText(code ?? element)
        while text.hasSuffix("\n") { text.removeLast() }
        // A fence longer than any backtick run inside keeps the code intact.
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    /// A code block's text. Some editors break its lines with `<br>` rather
    /// than keeping the newlines, and indent with no-break spaces.
    private func codeText(_ node: XMLNode) -> String {
        guard let element = node as? XMLElement, let name = element.name?.lowercased() else {
            return node.kind == .text ? (node.stringValue ?? "").replacingOccurrences(of: "\u{a0}", with: " ") : ""
        }
        return name == "br" ? "\n" : (element.children ?? []).map(codeText).joined()
    }

    private func table(_ element: XMLElement) -> String? {
        let rows = rowElements(of: element).map { row in
            (row.children ?? []).compactMap { $0 as? XMLElement }
                .filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                .map { cell in
                    // Notion and Coda put paragraphs in cells; a table row is
                    // one line, so they run on.
                    blocks(of: cell).joined(separator: " ")
                        .replacingOccurrences(of: #"\\?\n"#, with: " ", options: .regularExpression)
                        .replacingOccurrences(of: "|", with: "\\|")
                        .trimmingCharacters(in: .whitespaces)
                }
        }.filter { !$0.isEmpty }
        guard let header = rows.first else { return nil }
        let table = MarkdownTable(header: header, alignments: [], rows: Array(rows.dropFirst()))
        return table.formatted().text
    }

    private func rowElements(of element: XMLElement) -> [XMLElement] {
        (element.children ?? []).compactMap { $0 as? XMLElement }.flatMap { child -> [XMLElement] in
            switch child.name?.lowercased() {
            case "tr": [child]
            case "thead", "tbody", "tfoot": rowElements(of: child)
            default: []
            }
        }
    }

    /// A paragraph from inline text: line breaks at its ends dropped, as
    /// editors leave them on empty lines, and lines kept from starting
    /// markup they do not mean.
    private func paragraph(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: CharacterSet(charactersIn: " " + Self.lineBreak))
        guard !trimmed.isEmpty else { return "" }
        return trimmed
            // Two breaks in a row leave an empty line: a new paragraph.
            .replacingOccurrences(of: Self.lineBreak + "{2,}", with: "\n\n", options: .regularExpression)
            .replacingOccurrences(of: Self.lineBreak, with: "\\\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { escapeLineStart(String($0)) }
            .joined(separator: "\n")
    }

    /// Text at the start of a line that would make it a heading, quote,
    /// list item or rule.
    private func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        let rest = line.dropFirst()
        switch first {
        case "#", ">":
            return "\\" + line
        case "-", "+", "=":
            let isMarker = rest.first.map { $0 == " " } ?? true
            return isMarker || line.allSatisfy({ $0 == first || $0 == " " }) ? "\\" + line : line
        case "0"..."9":
            let digits = line.prefix { $0.isASCII && $0.isNumber }
            guard digits.count <= 9 else { return line }
            let after = line.dropFirst(digits.count)
            guard let delimiter = after.first, delimiter == "." || delimiter == ")",
                  after.dropFirst().first.map({ $0 == " " }) ?? true
            else { return line }
            return String(digits) + "\\" + after
        default:
            return line
        }
    }

    // MARK: - Inlines

    /// Inline content as one line of markdown, with `lineBreak` where `<br>`s were.
    func inlineText(_ nodes: [XMLNode]) -> String {
        inlines(nodes)
            // HTML whitespace collapses; a hard break survives as its own marker.
            .replacingOccurrences(of: #"[ \t\n\r]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: " ?\(Self.lineBreak) ?", with: Self.lineBreak, options: .regularExpression)
    }

    /// The markdown for a run of inline nodes. Side-by-side elements with the
    /// same formatting, as editors leave behind where a styled word was
    /// edited, are formatted as one, since `**a****b**` is not bold.
    private func inlines(_ nodes: [XMLNode]) -> String {
        var out = ""
        var index = nodes.startIndex
        while index < nodes.endIndex {
            guard let element = nodes[index] as? XMLElement, let key = formatting(of: element) else {
                out += inline(nodes[index])
                index += 1
                continue
            }
            var children: [XMLNode] = []
            while index < nodes.endIndex, let next = nodes[index] as? XMLElement, formatting(of: next) == key {
                children += next.children ?? []
                index += 1
            }
            out += inline(element, inner: inlines(children))
        }
        return out
    }

    /// What formatting an element adds, for telling when neighbours match.
    private func formatting(of element: XMLElement) -> String? {
        switch element.name?.lowercased() {
        case "strong", "b": HTMLToMarkdown.isPlainWrapper(element) ? styleKey(element) : "**"
        case "em", "i": "*"
        case "del", "s", "strike": "~~"
        case "mark": "=="
        case "span", "font": styleKey(element)
        default: nil
        }
    }

    private func styleKey(_ element: XMLElement) -> String? {
        let style = HTMLToMarkdown.style(of: element)
        let key = (HTMLToMarkdown.isItalic(style) ? "*" : "") + (HTMLToMarkdown.isBold(style) ? "**" : "")
            + (HTMLToMarkdown.isStruck(style) ? "~~" : "")
        return key.isEmpty ? nil : key
    }

    private func inline(_ node: XMLNode) -> String {
        guard let element = node as? XMLElement else {
            return node.kind == .text ? escape((node.stringValue ?? "").replacingOccurrences(of: "\u{a0}", with: " ")) : ""
        }
        return inline(element, inner: inlines(element.children ?? []))
    }

    private func inline(_ element: XMLElement, inner: @autoclosure () -> String) -> String {
        guard let name = element.name?.lowercased() else { return "" }
        if Self.skippedTags.contains(name) { return "" }
        switch name {
        case "br":
            return Self.lineBreak  // a hard line break, swapped in after whitespace collapses
        case "strong", "b":
            return HTMLToMarkdown.isPlainWrapper(element) ? styled(element, inner()) : wrap(inner(), "**")
        case "em", "i":
            return wrap(inner(), "*")
        case "del", "s", "strike":
            return wrap(inner(), "~~")
        case "mark":
            return wrap(inner(), "==")
        case "code", "kbd", "samp", "tt":
            let text = (element.stringValue ?? "").replacingOccurrences(of: "\u{a0}", with: " ")
            let fence = text.contains("`") ? "``" : "`"
            return text.isEmpty ? "" : fence + (fence == "``" ? " \(text) " : text) + fence
        case "a":
            let text = inner().trimmingCharacters(in: .whitespaces)
            guard let href = element.attribute(forName: "href")?.stringValue, !href.isEmpty, !Self.runsScript(href)
            else { return text }
            return text.isEmpty ? "" : "[\(text)](\(destination(href)))"
        case "img":
            guard let source = element.attribute(forName: "src")?.stringValue, !source.isEmpty else { return "" }
            let alt = element.attribute(forName: "alt")?.stringValue ?? ""
            return "![\(escape(alt))](\(destination(source)))"
        case "input":
            return ""  // task checkboxes are handled by their list item
        case "span", "font":
            return styled(element, inner())
        default:
            return inner()
        }
    }

    /// Google Docs and others mark bold and italic with inline styles.
    private func styled(_ element: XMLElement, _ text: String) -> String {
        let style = HTMLToMarkdown.style(of: element)
        var result = text
        if HTMLToMarkdown.isItalic(style) { result = wrap(result, "*") }
        if HTMLToMarkdown.isBold(style) { result = wrap(result, "**") }
        if HTMLToMarkdown.isStruck(style) { result = wrap(result, "~~") }
        return result
    }

    /// Wraps text in a delimiter, keeping surrounding spaces and line breaks
    /// outside it, since `** bold**` is not bold.
    private func wrap(_ text: String, _ delimiter: String) -> String {
        let outside: (Character) -> Bool = { $0 == " " || $0 == "\n" || $0 == "\t" || String($0) == Self.lineBreak }
        guard let first = text.firstIndex(where: { !outside($0) }), let last = text.lastIndex(where: { !outside($0) })
        else { return text }
        return String(text[..<first]) + delimiter + text[first...last] + delimiter + text[text.index(after: last)...]
    }

    private func destination(_ url: String) -> String {
        url.contains(" ") || url.contains(")") ? "<\(url)>" : url
    }

    /// Escapes characters that would otherwise start markup: emphasis, code
    /// and links, raw HTML, and the doubled `~~` and `==` of strikethrough and
    /// highlight.
    private func escape(_ text: String) -> String {
        let characters = Array(text)
        var out = ""
        for (index, character) in characters.enumerated() {
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            let previous = index > 0 ? characters[index - 1] : nil
            switch character {
            case "`", "*", "_", "[", "]":
                out.append("\\")
            case "\\" where next.map({ $0.isASCII && ($0.isPunctuation || $0.isSymbol) }) ?? false:
                out.append("\\")
            case "<" where next.map({ $0.isLetter || $0 == "/" || $0 == "!" || $0 == "?" }) ?? false:
                out.append("\\")
            case "~" where next == "~" || previous == "~", "=" where next == "=" || previous == "=":
                out.append("\\")
            default:
                break
            }
            out.append(character)
        }
        return out
    }
}
