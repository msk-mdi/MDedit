import Foundation
import MarkdownKit

/// Converts pasted HTML — from browsers, Google Docs, Notion and the like —
/// into markdown, so formatted text pastes as formatting rather than as
/// plain words or raw tags.
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
        guard let document = try? XMLDocument(xmlString: html, options: [.documentTidyHTML]),
              let root = document.rootElement()
        else { return nil }
        let body = root.elements(forName: "body").first ?? root
        guard containsMeaningfulTag(body) else { return nil }
        let markdown = Converter().blocks(of: body).joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return markdown.isEmpty ? nil : markdown
    }

    private static func containsMeaningfulTag(_ element: XMLElement) -> Bool {
        if let name = element.name?.lowercased(), meaningfulTags.contains(name), !isPlainWrapper(element) { return true }
        if hasFormattingStyle(element) { return true }
        return element.children?.contains { ($0 as? XMLElement).map(containsMeaningfulTag) ?? false } ?? false
    }

    /// Bold, italic or struck-through by inline style, as Google Docs does it.
    fileprivate static func hasFormattingStyle(_ element: XMLElement) -> Bool {
        let style = element.attribute(forName: "style")?.stringValue?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
        return style.contains("font-style:italic") || style.contains("font-weight:bold")
            || style.contains("font-weight:700") || style.contains("font-weight:600")
            || style.contains("line-through")
    }

    /// Google Docs wraps a whole paste in `<b style="font-weight:normal">`.
    fileprivate static func isPlainWrapper(_ element: XMLElement) -> Bool {
        guard let name = element.name?.lowercased(), name == "b" || name == "strong" else { return false }
        let style = element.attribute(forName: "style")?.stringValue?.replacingOccurrences(of: " ", with: "") ?? ""
        return style.contains("font-weight:normal") || style.contains("font-weight:400")
    }
}

private struct Converter {
    private static let blockTags: Set<String> = [
        "p", "div", "section", "article", "header", "footer", "main", "aside", "nav", "figure", "figcaption",
        "h1", "h2", "h3", "h4", "h5", "h6", "ul", "ol", "li", "blockquote", "pre", "table", "hr", "dl", "dt", "dd",
    ]
    private static let skippedTags: Set<String> = ["script", "style", "head", "meta", "title", "noscript", "template"]

    // MARK: - Blocks

    /// The markdown blocks of an element's children: runs of inline content
    /// become paragraphs, block elements become their own blocks.
    func blocks(of element: XMLElement) -> [String] {
        var result: [String] = []
        var inline: [XMLNode] = []

        func flush() {
            let text = inlineText(inline).trimmingCharacters(in: .whitespaces)
            if !text.isEmpty { result.append(text) }
            inline = []
        }

        for child in element.children ?? [] {
            guard let child = child as? XMLElement, let name = child.name?.lowercased() else {
                inline.append(child)
                continue
            }
            if Self.skippedTags.contains(name) { continue }
            if Self.blockTags.contains(name) || (isWrapper(name) && containsBlock(child)) {
                flush()
                result += block(child, name: name)
            } else {
                inline.append(child)
            }
        }
        flush()
        return result
    }

    private func isWrapper(_ name: String) -> Bool {
        ["span", "b", "strong", "font", "body", "html"].contains(name)
    }

    private func containsBlock(_ element: XMLElement) -> Bool {
        element.children?.contains { node in
            guard let child = node as? XMLElement, let name = child.name?.lowercased() else { return false }
            return Self.blockTags.contains(name) || containsBlock(child)
        } ?? false
    }

    private func block(_ element: XMLElement, name: String) -> [String] {
        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            let text = inlineText(element.children ?? []).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? [] : [String(repeating: "#", count: level) + " " + text]
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
        var number = Int(element.attribute(forName: "start")?.stringValue ?? "") ?? 1
        var lines: [String] = []
        for case let item as XMLElement in element.children ?? [] where item.name?.lowercased() == "li" {
            let marker = ordered ? "\(number). " : "- "
            number += 1
            let indent = String(repeating: " ", count: marker.count)
            // A checkbox makes it a task item.
            var prefix = ""
            if let box = item.elements(forName: "input").first, box.attribute(forName: "type")?.stringValue == "checkbox" {
                prefix = box.attribute(forName: "checked") != nil ? "[x] " : "[ ] "
            }
            let content = blocks(of: item).joined(separator: "\n")
            let itemLines = (prefix + content).split(separator: "\n", omittingEmptySubsequences: false)
            for (index, line) in itemLines.enumerated() {
                lines.append(index == 0 ? marker + line : (line.isEmpty ? "" : indent + line))
            }
        }
        return lines.joined(separator: "\n")
    }

    private func codeBlock(_ element: XMLElement) -> String {
        let code = element.elements(forName: "code").first
        let classes = [element, code].compactMap { $0?.attribute(forName: "class")?.stringValue }.joined(separator: " ")
        let language = classes.split(separator: " ")
            .first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
            .map { String($0.split(separator: "-", maxSplits: 1).last ?? "") } ?? ""
        var text = (code ?? element).stringValue ?? ""
        if text.hasSuffix("\n") { text.removeLast() }
        // A fence longer than any backtick run inside keeps the code intact.
        let longestRun = text.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestRun + 1))
        return "\(fence)\(language)\n\(text)\n\(fence)"
    }

    private func table(_ element: XMLElement) -> String? {
        let rows = rowElements(of: element).map { row in
            (row.children ?? []).compactMap { $0 as? XMLElement }
                .filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
                .map { cell in
                    inlineText(cell.children ?? []).trimmingCharacters(in: .whitespaces)
                        .replacingOccurrences(of: "\n", with: " ")
                        .replacingOccurrences(of: "|", with: "\\|")
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

    // MARK: - Inlines

    func inlineText(_ nodes: [XMLNode]) -> String {
        nodes.map(inline).joined()
            // HTML whitespace collapses; a hard break survives as its own marker.
            .replacingOccurrences(of: #"[ \t\n\r]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1}", with: "\\\n")
    }

    private func inline(_ node: XMLNode) -> String {
        guard let element = node as? XMLElement, let name = element.name?.lowercased() else {
            return node.kind == .text ? escape(node.stringValue ?? "") : ""
        }
        if Self.skippedTags.contains(name) { return "" }
        let inner = { (element.children ?? []).map(inline).joined() }
        switch name {
        case "br":
            return "\u{1}"  // a hard line break, swapped in after whitespace collapses
        case "strong", "b":
            return HTMLToMarkdown.isPlainWrapper(element) ? styled(element, inner()) : wrap(inner(), "**")
        case "em", "i":
            return wrap(inner(), "*")
        case "del", "s", "strike":
            return wrap(inner(), "~~")
        case "mark":
            return wrap(inner(), "==")
        case "code", "kbd", "samp", "tt":
            let text = element.stringValue ?? ""
            let fence = text.contains("`") ? "``" : "`"
            return text.isEmpty ? "" : fence + (fence == "``" ? " \(text) " : text) + fence
        case "a":
            let text = inner().trimmingCharacters(in: .whitespaces)
            guard let href = element.attribute(forName: "href")?.stringValue, !href.isEmpty, !href.hasPrefix("javascript:")
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
        let style = element.attribute(forName: "style")?.stringValue?.lowercased().replacingOccurrences(of: " ", with: "") ?? ""
        var result = text
        if style.contains("font-style:italic") { result = wrap(result, "*") }
        if style.contains("font-weight:bold") || style.contains("font-weight:700") || style.contains("font-weight:600") {
            result = wrap(result, "**")
        }
        if style.contains("text-decoration:line-through") || style.contains("text-decoration-line:line-through") {
            result = wrap(result, "~~")
        }
        return result
    }

    /// Wraps text in a delimiter, keeping surrounding spaces outside it, since
    /// `** bold**` is not bold.
    private func wrap(_ text: String, _ delimiter: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return text }
        let leading = text.prefix { $0 == " " }
        let trailing = String(text.reversed().prefix { $0 == " " })
        return leading + delimiter + trimmed + delimiter + trailing
    }

    private func destination(_ url: String) -> String {
        url.contains(" ") || url.contains(")") ? "<\(url)>" : url
    }

    /// Escapes characters that would otherwise start markup.
    private func escape(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\`*_[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
