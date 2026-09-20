import Foundation
import Testing
@testable import MarkdownKit

/// Renders a line's tokens as `kind:text` pairs, so tests read like the code
/// they check.
private func highlight(_ code: String, _ languageName: String) -> [String] {
    guard let language = Language.named(languageName) else {
        Issue.record("unknown language \(languageName)")
        return []
    }
    var state = CodeState.start
    var result: [String] = []
    for line in code.components(separatedBy: "\n") {
        let units = Array(line.utf16)
        for token in SyntaxHighlighter.tokens(line: units, language: language, state: &state) {
            let text = String(decoding: units[token.range.location..<NSMaxRange(token.range)], as: UTF16.self)
            result.append("\(token.kind):\(text)")
        }
    }
    return result
}

@Suite("SyntaxHighlighter")
struct SyntaxHighlighterTests {
    @Test("Language names and aliases resolve")
    func languageLookup() {
        #expect(Language.named("swift")?.id == "swift")
        #expect(Language.named("py")?.id == "python")
        #expect(Language.named("sh")?.id == "bash")
        #expect(Language.named("zsh")?.id == "bash")
        #expect(Language.named("c++")?.id == "cpp")
        #expect(Language.named("ts")?.id == "typescript")
        #expect(Language.named("golang")?.id == "go")
        // An info string may carry more than the language.
        #expect(Language.named("swift showLineNumbers")?.id == "swift")
        #expect(Language.named("SWIFT")?.id == "swift")
        #expect(Language.named("") == nil)
        #expect(Language.named("nonsense-lang") == nil)
    }

    @Test("Swift")
    func swiftCode() {
        #expect(highlight("let x = 1  // note", "swift") == [
            "keyword:let", "number:1", "comment:// note",
        ])
        #expect(highlight("func greet(name: String) -> Bool { true }", "swift") == [
            "keyword:func", "function:greet", "type:String", "type:Bool", "constant:true",
        ])
    }

    @Test("Python, including triple-quoted strings across lines")
    func python() {
        #expect(highlight("def f(x): return None  # done", "python") == [
            "keyword:def", "function:f", "keyword:return", "constant:None", "comment:# done",
        ])
        #expect(highlight("s = \"\"\"one\ntwo\"\"\"\nx = 1", "python") == [
            "string:\"\"\"one", "string:two\"\"\"", "number:1",
        ])
    }

    @Test("Bash variables and commands")
    func bash() {
        #expect(highlight("for f in *.md; do echo \"$f\"; done", "bash") == [
            "keyword:for", "keyword:in", "keyword:do", "type:echo", "string:\"$f\"", "keyword:done",
        ])
        #expect(highlight("VAR=${HOME}/bin  # path", "bash") == [
            "variable:${HOME}", "comment:# path",
        ])
    }

    @Test("C preprocessor and block comments spanning lines")
    func c() {
        #expect(highlight("#include <stdio.h>", "c") == ["keyword:#include"])
        #expect(highlight("int main(void) { return 0; }", "c") == [
            "type:int", "function:main", "type:void", "keyword:return", "number:0",
        ])
        // The comment keeps going until it closes, and code after it resumes.
        #expect(highlight("/* open\nstill\nclosed */ int x;", "c") == [
            "comment:/* open", "comment:still", "comment:closed */", "type:int",
        ])
    }

    @Test("JSON and YAML keys")
    func dataFormats() {
        #expect(highlight("{\"name\": \"md\", \"n\": 3, \"ok\": true}", "json") == [
            "attribute:\"name\"", "string:\"md\"", "attribute:\"n\"", "number:3",
            "attribute:\"ok\"", "constant:true",
        ])
        #expect(highlight("name: mdedit  # comment", "yaml") == [
            "attribute:name", "comment:# comment",
        ])
    }

    @Test("HTML tags and attributes")
    func markup() {
        #expect(highlight("<a href=\"x\">hi</a>", "html") == [
            "tag:<a", "attribute:href", "string:\"x\"", "tag:>", "tag:</a", "tag:>",
        ])
    }

    @Test("Diffs colour whole lines")
    func diff() {
        #expect(highlight("--- a/x\n+++ b/x\n@@ -1 +1 @@\n-old\n+new\n same", "diff") == [
            "keyword:--- a/x", "keyword:+++ b/x", "type:@@ -1 +1 @@", "deleted:-old", "inserted:+new",
        ])
    }

    @Test("Strings swallow the markup inside them")
    func stringsWin() {
        #expect(highlight("let s = \"// not a comment\"", "swift") == [
            "keyword:let", "string:\"// not a comment\"",
        ])
        #expect(highlight("x = \"a \\\" b\" + 1", "javascript") == [
            "string:\"a \\\" b\"", "number:1",
        ])
    }

    @Test("Numbers in their several spellings")
    func numbers() {
        #expect(highlight("a = 0xFF + 1_000 + 3.14e-2", "swift") == [
            "number:0xFF", "number:1_000", "number:3.14e-2",
        ])
    }
}

@Suite("Highlighting through the block parser")
struct HighlightedCodeBlockTests {
    @Test("Tokens attach to fenced lines and stop at the fence")
    func tokensOnCodeLines() {
        let markdown = "```swift\nlet x = 1\n```\nlet y = 2\n"
        let structure = BlockStructure(text: markdown as NSString)
        #expect(structure.lines[0].tokens.isEmpty)
        #expect(structure.lines[1].tokens.map(\.kind) == [.keyword, .number])
        #expect(structure.lines[2].tokens.isEmpty)
        // Outside the fence it is prose, not code.
        #expect(structure.lines[3].tokens.isEmpty)
    }

    @Test("An unknown language leaves code unhighlighted")
    func unknownLanguage() {
        let structure = BlockStructure(text: "```nonsense\nlet x = 1\n```" as NSString)
        #expect(structure.lines[1].tokens.isEmpty)
    }

    @Test("Token offsets account for a blockquote prefix")
    func quotedCode() {
        let structure = BlockStructure(text: "> ```swift\n> let x = 1\n> ```" as NSString)
        let tokens = structure.lines[1].tokens
        #expect(tokens.count == 2)
        // `> ` is two characters, so `let` starts at offset 2.
        #expect(tokens.first?.range == NSRange(location: 2, length: 3))
    }

    @Test("Export wraps tokens in spans")
    func htmlSpans() {
        let html = HTMLRenderer().render(markdown: "```python\nx = None  # hi\n```")
        #expect(html.contains("<span class=\"tok-constant\">None</span>"))
        #expect(html.contains("<span class=\"tok-comment\"># hi</span>"))
        #expect(html.contains("class=\"language-python\""))
    }
}
