import Foundation
import Testing
@testable import MarkdownKit

@Suite("DocumentSyntax")
struct DocumentSyntaxTests {
    @Test("Markdown and plain text read as markdown")
    func markdownFiles() {
        for name in ["notes.md", "README.markdown", "todo.txt", "Draft.MD"] {
            #expect(DocumentSyntax.forFile(named: name) == .markdown, "\(name)")
        }
    }

    @Test("Other formats read as code in their language")
    func codeFiles() {
        let expected: [String: String] = [
            "data.json": "json", "Wi-Fi.mobileconfig": "html", "Info.plist": "html", "feed.xml": "html",
            "config.yaml": "yaml", "ci.yml": "yaml", "Cargo.toml": "toml", "build.sh": "bash",
            "main.swift": "swift", "Makefile": "makefile", ".zshrc": "bash", "setup.cfg": "toml",
        ]
        for (name, language) in expected {
            guard case let .code(found) = DocumentSyntax.forFile(named: name) else {
                Issue.record("\(name) read as markdown")
                continue
            }
            #expect(found?.id == language, "\(name)")
        }
    }

    @Test("A format the highlighter does not know is still code, uncoloured")
    func unknownFormat() {
        #expect(DocumentSyntax.forFile(named: "server.log") == .code(nil))
        #expect(DocumentSyntax.forFile(named: "LICENSE") == .code(nil))
    }

    @Test("Every line of a code file is code, with nothing read as markdown")
    func wholeFileIsCode() {
        let json = "# not a heading\n> not a quote\n```\n{\"key\": \"value\", \"n\": 1}\n"
        let structure = BlockStructure(text: json as NSString, syntax: .code(Language.named("json")))
        #expect(structure.lines.allSatisfy { $0.kind == .codeLine })
        #expect(structure.lines.allSatisfy { $0.markers.isEmpty && $0.quoteDepth == 0 })
        #expect(structure.lines[3].tokens.contains { $0.kind == .string })
    }

    @Test("Edits keep a code file code")
    func editsStayCode() {
        let text = NSMutableString(string: "a\nb\nc\n")
        let structure = BlockStructure(text: text, syntax: .code(nil))
        text.replaceCharacters(in: NSRange(location: 0, length: 0), with: "---\n```swift\n")
        structure.update(text: text, editedRange: NSRange(location: 0, length: 13), changeInLength: 13)
        #expect(structure.lines.count == structure.lineCount)
        #expect(structure.lines.allSatisfy { $0.kind == .codeLine })
    }
}
