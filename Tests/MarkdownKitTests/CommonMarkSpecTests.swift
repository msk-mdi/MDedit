import Foundation
import Testing
@testable import MarkdownKit

/// Runs the CommonMark spec's examples through the renderer.
///
/// The parser is line-based and incremental by design, which trades some
/// edge cases (lazy continuation, list items holding several blocks) for
/// restyling one line per keystroke. So this does not demand 100%: it checks
/// the pass count never drops below the recorded baseline, and prints where
/// things stand per section.
@Suite("CommonMark spec")
struct CommonMarkSpecTests {
    private struct Example: Decodable {
        var markdown: String
        var html: String
        var example: Int
        var section: String
    }

    /// Raise this when conformance improves; the test fails if it drops.
    /// Recorded 2026-10-08 against spec 0.31.2: 650 of 652. The two left are
    /// bare `https://` text, which GFM-style autolinking deliberately links.
    static let baseline = 650

    private static func examples() throws -> [Example] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/commonmark-spec-0.31.2.json")
        return try JSONDecoder().decode([Example].self, from: Data(contentsOf: url))
    }

    /// Takes out what the renderer adds on purpose — heading ids, syntax
    /// highlighting spans — and whitespace between tags, which HTML ignores.
    static func normalize(_ html: String) -> String {
        var result = html
        let replacements: [(String, String)] = [
            (#"(<h[1-6]) id="[^"]*""#, "$1"),
            // Highlighting spans never nest, so each closes at the next </span>.
            (#"<span class="tok-[a-z]+">((?:(?!</span>)[\s\S])*)</span>"#, "$1"),
            (#">\s+<"#, "><"),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test("Pass rate holds at or above the baseline")
    func conformance() throws {
        let examples = try Self.examples()
        #expect(examples.count == 652)

        var passed: [String: Int] = [:]
        var total: [String: Int] = [:]
        var sections: [String] = []
        var failures = ""
        for example in examples {
            if total[example.section] == nil { sections.append(example.section) }
            total[example.section, default: 0] += 1
            let rendered = HTMLRenderer().render(markdown: example.markdown)
            if Self.normalize(rendered) == Self.normalize(example.html) {
                passed[example.section, default: 0] += 1
            } else {
                failures += "## \(example.example) \(example.section)\n--- markdown\n\(example.markdown)--- expected\n\(example.html)--- actual\n\(rendered)\n"
            }
        }
        // Set COMMONMARK_FAILURES to a path to get every failing example, for working on conformance.
        if let path = ProcessInfo.processInfo.environment["COMMONMARK_FAILURES"] {
            try failures.write(toFile: path, atomically: true, encoding: .utf8)
        }

        let passCount = passed.values.reduce(0, +)
        var report = "CommonMark 0.31.2: \(passCount)/\(examples.count) examples pass\n"
        for section in sections {
            report += "  \(section): \(passed[section, default: 0])/\(total[section, default: 0])\n"
        }
        print(report)
        #expect(passCount >= Self.baseline, "\(report)")
    }
}
