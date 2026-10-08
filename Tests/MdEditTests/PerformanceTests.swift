import AppKit
import Foundation
import Testing
@testable import MarkdownKit
@testable import MdEdit

/// Large-file timings: loading, typing and drawing a ~5 MB, 100k-line
/// document. The full-size runs only print their timings, and only when
/// `MDEDIT_BENCHMARKS=1` (they take a while in a debug build); a smaller
/// document always runs, with generous budgets, to catch a keystroke that
/// starts costing time proportional to the whole document.
@MainActor
@Suite("Performance", .serialized)
struct PerformanceTests {
    /// A realistic mix: headings, prose with inline markup, lists, tasks,
    /// quotes, code, tables. About 45 bytes a line, so 100k lines is close to 5 MB.
    static func document(lines target: Int) -> String {
        let section = [
            "## Section heading",
            "",
            "Some prose with **bold**, *italic*, `code`, a [link](https://example.com) and ==mark==, then more words to make a long line.",
            "A second line of the same paragraph, plain this time, a little longer than the first, and wrapping in a normal window width.",
            "A third line with a footnote[^1], ~~struck~~ text, an autolink https://example.org/page and some _underscored emphasis_ too.",
            "",
            "- a bullet item that runs on for a while, like a real one does when someone writes notes",
            "- [x] a finished task",
            "  - a nested item with `code` and a [reference link][ref] that goes nowhere in particular",
            "1. an ordered item with **strong** text, written out at about the length of a sentence",
            "",
            "> a quoted line with *emphasis*, long enough that it also wraps onto a second visual line",
            "",
            "```swift",
            "let value = compute(42, scale: 3.5, label: \"a string argument\") // a comment explaining the call",
            "print(\"done\")",
            "```",
            "",
            "| Name | Value |",
            "| :--- | ---: |",
            "| one, with a longer description in its first cell | 1 |",
            "",
        ]
        var lines: [String] = []
        lines.reserveCapacity(target + section.count)
        while lines.count < target { lines += section }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func milliseconds(_ body: () -> Void) -> Double {
        let clock = ContinuousClock()
        let elapsed = clock.measure(body)
        return Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
    }

    struct Timings: CustomStringConvertible {
        var bytes = 0
        var load = 0.0
        var keystroke = 0.0
        var newline = 0.0
        var fence = 0.0
        var layoutScreen = 0.0
        var drawScreen = 0.0

        var description: String {
            String(format: "%.1f MB: load %.0f ms, keystroke %.2f ms, return %.2f ms, open fence %.0f ms, lay out a screen %.1f ms, draw a screen %.1f ms",
                   Double(bytes) / 1_000_000, load, keystroke, newline, fence, layoutScreen, drawScreen)
        }
    }

    static func measure(lines: Int) -> Timings {
        var timings = Timings()
        let text = document(lines: lines)
        timings.bytes = text.utf8.count
        let storage = MarkdownTextStorage(theme: .light)
        timings.load = milliseconds {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }

        // A keystroke in a paragraph in the middle, with the caret's line revealed.
        let middle = (storage.string as NSString).range(of: "Some prose", options: [], range: NSRange(location: storage.length / 2, length: storage.length / 2))
        let line = storage.line(at: middle.location)
        storage.revealedLines = line...line
        let typing = Int(ProcessInfo.processInfo.environment["MDEDIT_TYPING"] ?? "") ?? 20
        timings.keystroke = milliseconds {
            for offset in 0..<typing {
                storage.replaceCharacters(in: NSRange(location: middle.location + offset, length: 0), with: "x")
            }
        } / Double(typing)
        timings.newline = milliseconds {
            storage.replaceCharacters(in: NSRange(location: middle.location, length: 0), with: "\n")
        }
        // Opening a fence restyles everything below it, by design; closing it again restores.
        timings.fence = milliseconds {
            storage.replaceCharacters(in: NSRange(location: middle.location, length: 0), with: "```\n")
            storage.replaceCharacters(in: NSRange(location: middle.location, length: 4), with: "")
        }

        // Layout and drawing of one screenful around the edit.
        let layoutManager = MarkdownLayoutManager()
        let container = NSTextContainer(size: CGSize(width: 720, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        let screen = NSRange(location: middle.location, length: min(4_000, storage.length - middle.location))
        timings.layoutScreen = milliseconds {
            layoutManager.ensureLayout(forCharacterRange: screen)
        }
        let glyphs = layoutManager.glyphRange(forCharacterRange: screen, actualCharacterRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
        let image = NSImage(size: NSSize(width: 720, height: max(1, min(bounds.height, 2_000))))
        image.lockFocusFlipped(true)
        timings.drawScreen = milliseconds {
            layoutManager.drawBackground(forGlyphRange: glyphs, at: NSPoint(x: 0, y: -bounds.minY))
            layoutManager.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: 0, y: -bounds.minY))
        }
        image.unlockFocus()
        storage.removeLayoutManager(layoutManager)
        return timings
    }

    @Test("Typing stays local in a 10k-line document")
    func typingIsLocal() {
        let timings = Self.measure(lines: 10_000)
        print("benchmark", timings)
        // Generous, debug-build budgets: these catch whole-document work per
        // keystroke, not small regressions.
        #expect(timings.keystroke < 25, "\(timings)")
        #expect(timings.newline < 50, "\(timings)")
        #expect(timings.drawScreen < 250, "\(timings)")
    }

    @Test("5 MB, 100k lines", .enabled(if: ProcessInfo.processInfo.environment["MDEDIT_BENCHMARKS"] == "1"))
    func largeFile() {
        let timings = Self.measure(lines: 100_000)
        print("benchmark", timings)
        #expect(timings.keystroke < 25, "\(timings)")
    }
}
