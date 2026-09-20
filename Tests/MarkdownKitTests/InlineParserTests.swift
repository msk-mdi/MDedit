import Foundation
import Testing
@testable import MarkdownKit

private func parse(_ markdown: String) -> [InlineNode] {
    InlineParser.parse(Array(markdown.utf16))
}

/// A compact shape description, so tests read as the markup they check.
private func shape(_ nodes: [InlineNode]) -> String {
    nodes.map { node in
        switch node {
        case let .text(range): "text(\(range.location),\(range.length))"
        case .code: "code"
        case let .emphasis(_, _, children): "em[\(shape(children))]"
        case let .strong(_, _, children): "strong[\(shape(children))]"
        case let .strikethrough(_, _, children): "strike[\(shape(children))]"
        case let .link(_, _, destination, _, children): "link(\(destination))[\(shape(children))]"
        case let .image(_, _, source, alt): "image(\(source),\(alt))"
        case let .autolink(_, _, url): "auto(\(url))"
        case .escape: "escape"
        case .rawHTML: "html"
        }
    }.joined(separator: "+")
}

@Suite("InlineParser")
struct InlineParserTests {
    @Test("Emphasis and strong, including the triple case")
    func emphasis() {
        #expect(shape(parse("*a*")) == "em[text(1,1)]")
        #expect(shape(parse("**a**")) == "strong[text(2,1)]")
        // CommonMark nests a triple run as em(strong(...)).
        #expect(shape(parse("***a***")) == "em[strong[text(3,1)]]")
        #expect(shape(parse("_a_")) == "em[text(1,1)]")
        #expect(shape(parse("~~a~~")) == "strike[text(2,1)]")
    }

    @Test("Emphasis needs content next to its delimiters")
    func flanking() {
        #expect(shape(parse("* a *")) == "text(0,5)")
        #expect(shape(parse("a * b")) == "text(0,5)")
        // Underscores do not split words, asterisks do.
        #expect(shape(parse("snake_case_name")) == "text(0,15)")
        #expect(shape(parse("in*ter*nal")) == "text(0,2)+em[text(3,3)]+text(7,3)")
    }

    @Test("Code spans win over the markup inside them")
    func codeSpans() {
        #expect(shape(parse("`*not em*`")) == "code")
        #expect(shape(parse("``a ` b``")) == "code")
        // An unmatched backtick is literal text.
        #expect(shape(parse("a ` b")) == "text(0,5)")
        // A code span cannot close emphasis opened outside it.
        #expect(shape(parse("*a `*` b*")) == "em[text(1,2)+code+text(6,2)]")
    }

    @Test("Escapes defuse markup")
    func escapes() {
        #expect(shape(parse("\\*a\\*")) == "escape+text(2,1)+escape")
        #expect(shape(parse("\\a")) == "text(0,2)")
    }

    @Test("Links and images")
    func links() {
        #expect(shape(parse("[text](url)")) == "link(url)[text(1,4)]")
        #expect(shape(parse("[**bold**](url)")) == "link(url)[strong[text(3,4)]]")
        #expect(shape(parse("![alt](pic.png)")) == "image(pic.png,alt)")
        #expect(shape(parse("[a](<sp ace.md> \"t\")")) == "link(sp ace.md)[text(1,1)]")
        // Brackets with no destination stay as text.
        #expect(shape(parse("[not a link]")) == "text(0,12)")
        // Nested brackets in the text are tolerated.
        #expect(shape(parse("[a [b] c](u)")) == "link(u)[text(1,7)]")
        #expect(shape(parse("<https://example.com>")) == "auto(https://example.com)")
        #expect(shape(parse("<a@b.com>")) == "auto(mailto:a@b.com)")
    }

    @Test("Markers cover exactly the syntax characters")
    func markerRanges() {
        guard case let .strong(range, markers, _) = parse("x **bold** y")[1] else {
            Issue.record("expected a strong node")
            return
        }
        #expect(range == NSRange(location: 2, length: 8))
        #expect(markers.map(\.range) == [NSRange(location: 2, length: 2), NSRange(location: 8, length: 2)])

        guard case let .link(_, markers2, _, _, _) = parse("[hi](u)")[0] else {
            Issue.record("expected a link node")
            return
        }
        // `[` before the text, then `](u)` after it.
        #expect(markers2.map(\.range) == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 4)])
    }

    @Test("Ranges tile the input exactly once")
    func rangesTile() {
        for markdown in ["plain", "*a* b `c` [d](e)", "**x** ~~y~~ <https://z.dev>", "a\\*b ![i](p) *`q`*"] {
            var covered = 0
            for node in parse(markdown) {
                #expect(node.range.location == covered, "gap or overlap in \(markdown.debugDescription)")
                covered = NSMaxRange(node.range)
            }
            #expect(covered == markdown.utf16.count, "short coverage of \(markdown.debugDescription)")
        }
    }
}
