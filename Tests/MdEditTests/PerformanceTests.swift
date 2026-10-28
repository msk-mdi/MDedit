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
        var restyle = 0.0
        var keystroke = 0.0
        var newline = 0.0
        var fence = 0.0
        var layoutScreen = 0.0
        var drawScreen = 0.0

        var description: String {
            String(format: "%.1f MB: load %.0f ms, restyle %.0f ms, keystroke %.2f ms, return %.2f ms, open fence %.0f ms, lay out a screen %.1f ms, draw a screen %.1f ms",
                   Double(bytes) / 1_000_000, load, restyle, keystroke, newline, fence, layoutScreen, drawScreen)
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
        // A theme change restyles every line over runs that already exist.
        timings.restyle = milliseconds { storage.theme = .dark }
        storage.theme = .light

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

    /// Typing as the text view does it, in a window of several tabs: the
    /// input handler, the dirty check of every tab and the status all run
    /// on each keystroke, and once each copied a whole document.
    @Test("Typing through the text view with several tabs open stays local")
    func typingInWindow() throws {
        let controller = MainWindowController()
        controller.recovery = RecoveryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("MdEditPerformance-\(UUID().uuidString)"))
        let text = Self.document(lines: 10_000)
        for _ in 0..<5 { controller.openCopy(of: text, named: "Large") }
        let textView = try #require(controller.window?.firstResponder as? NSTextView)
        let start = (text as NSString).range(of: "Some prose", options: [], range: NSRange(location: text.utf16.count / 2, length: text.utf16.count / 2)).location
        textView.setSelectedRange(NSRange(location: start, length: 0))
        let typing = Int(ProcessInfo.processInfo.environment["MDEDIT_TYPING"] ?? "") ?? 20
        // The fastest of a few rounds: a busy CI runner only ever adds time,
        // and whole-document work would show in every round.
        let keystroke = (0..<3).map { _ in
            Self.milliseconds {
                for _ in 0..<typing {
                    textView.insertText("x", replacementRange: textView.selectedRange())
                }
                for _ in 0..<typing {
                    textView.deleteBackward(nil)
                }
            } / Double(2 * typing)
        }.min()!
        print("benchmark keystroke in a window of 5 tabs", String(format: "%.2f ms", keystroke))
        #expect(controller.documents.count == 5)
        #expect(keystroke < 25, "\(keystroke) ms")
        controller.documents.forEach { $0.storage.replaceCharacters(in: NSRange(location: 0, length: $0.storage.length), with: "") }
        controller.window?.close()
    }

    /// A fold once made every keystroke restyle from the edit down to the
    /// last folded line.
    @Test("Typing above a fold stays local")
    func typingAboveFold() throws {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: Self.document(lines: 10_000))
        let last = try #require(storage.headings.last?.line)
        storage.setFolded(true, headingLine: last)
        let start = (storage.string as NSString).range(of: "Some prose").location
        let keystroke = Self.milliseconds {
            for offset in 0..<20 {
                storage.replaceCharacters(in: NSRange(location: start + offset, length: 0), with: "x")
            }
        } / 20
        print("benchmark keystroke above a fold", String(format: "%.2f ms", keystroke))
        #expect(storage.foldedHeadings.count == 1)
        #expect(keystroke < 25, "\(keystroke) ms")
    }

    /// Opening a document, switching appearance and changing any setting all
    /// restyle every line. Done over the runs already there, that once grew
    /// with the square of the document: 42 s rather than 3 s at 4.5 MB.
    @Test("Restyling everything costs about what loading does")
    func restyleIsLinear() {
        let storage = MarkdownTextStorage(theme: .light)
        let text = Self.document(lines: 30_000)
        let load = Self.milliseconds {
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        }
        let restyle = Self.milliseconds { storage.theme = .dark }
        print("benchmark restyle", String(format: "load %.0f ms, restyle %.0f ms", load, restyle))
        #expect(restyle < 1.5 * load, "load \(load) ms, restyle \(restyle) ms")
    }

    /// Configuring the text view once it showed the document laid all of
    /// it out, for a view not on screen yet: 9.6 s at 4.5 MB.
    @Test("Opening an editor lays out only what it shows")
    func editorSetupIsLazy() {
        // In the theme the editor will pick, as the app makes documents: a
        // dark Mac would otherwise time restyling the whole document too.
        let document = Document(text: Self.document(lines: 30_000), theme: .current(for: NSApplication.shared.effectiveAppearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        let setup = Self.milliseconds {
            window.contentViewController = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
            window.displayIfNeeded()
        }
        print("benchmark editor setup", String(format: "%.0f ms", setup))
        #expect(setup < 500, "\(setup) ms")
        withExtendedLifetime(window) {}
    }

    /// Zoom magnifies the page rather than restyling it at a larger size,
    /// which took seconds a step at 4.5 MB. What is left is wrapping the
    /// text to the column, which narrows in the page's own units as the
    /// zoom grows past what the window has room for.
    @Test("Zooming does not restyle the document")
    func zoomIsCheap() {
        let document = Document(text: Self.document(lines: 20_000), theme: .current(for: NSApplication.shared.effectiveAppearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        window.contentViewController = editor
        // The editor's view comes without a size, and the window takes it.
        window.setContentSize(NSSize(width: 600, height: 700))
        editor.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(document.storage.length <= EditorViewController.rewrapLimit)
        let column = editor.textView.textContainer!.size.width
        let zoom = Self.milliseconds {
            for step in 1...10 {
                editor.scrollView.setMagnification(1 + 0.2 * CGFloat(step), centeredAt: .zero)
                editor.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        print("benchmark zoom", String(format: "%.0f ms", zoom))
        #expect(editor.textView.textContainer!.size.width < column / 2)
        #expect(zoom < 1_500, "\(zoom) ms")
        withExtendedLifetime(window) {}
    }

    /// Each step of a pinch only magnifies: wrapping the text afresh laid
    /// the document out again from the top at every step.
    @Test("Pinching deep in a long document stays cheap")
    func pinchIsCheap() {
        let document = Document(text: Self.document(lines: 30_000), theme: .current(for: NSApplication.shared.effectiveAppearance))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: true)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 900, height: 700))
        editor.view.layoutSubtreeIfNeeded()
        let middle = NSRange(location: document.storage.length / 2, length: 0)
        editor.textView.scrollRangeToVisible(middle)
        window.displayIfNeeded()
        let fingers = NSPoint(x: editor.scrollView.contentView.bounds.midX, y: editor.scrollView.contentView.bounds.midY)
        let pinch = Self.milliseconds {
            for _ in 0..<20 {
                editor.pinch(by: 0.05, at: fingers, ending: false)
                editor.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
            }
        }
        print("benchmark pinch", String(format: "%.0f ms", pinch))
        #expect(pinch < 300, "\(pinch) ms")
        withExtendedLifetime(window) {}
    }

    @Test("5 MB, 100k lines", .enabled(if: ProcessInfo.processInfo.environment["MDEDIT_BENCHMARKS"] == "1"))
    func largeFile() {
        let timings = Self.measure(lines: 100_000)
        print("benchmark", timings)
        #expect(timings.keystroke < 25, "\(timings)")
    }
}
