import AppKit
import Testing
@testable import MdEdit

/// Layout kept up to date edit by edit must match laying the document out
/// afresh. Restyling reaches past the edited line (fences, folds, reveals),
/// and each line it restyles has to be invalidated for layout, or the
/// editor shows stale line heights.
///
/// Non-contiguous layout is not an option as things stand: with markers
/// hidden as zero-width glyphs, a heading laid out from its own line comes
/// out taller than one reached from above, so lines would jump as layout
/// filled in.
@MainActor
@Suite("Layout")
struct LayoutTests {
    /// A deterministic generator, so a failure replays.
    private struct Generator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state ^ (state >> 33)
        }
    }

    private func layoutManager(contiguous: Bool, for storage: MarkdownTextStorage) -> (MarkdownLayoutManager, NSTextContainer) {
        let manager = MarkdownLayoutManager()
        manager.allowsNonContiguousLayout = !contiguous
        let container = NSTextContainer(size: CGSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (manager, container)
    }

    /// Every line fragment, in order.
    private func fragments(_ manager: NSLayoutManager, _ container: NSTextContainer) -> [CGRect] {
        manager.ensureLayout(for: container)
        var rects: [CGRect] = []
        manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, _, _, _, _ in
            rects.append(rect)
        }
        return rects
    }

    @Test("Layout kept up through edits matches laying it all out", arguments: [1, 2])
    func onDemandMatchesFull(seed: UInt64) throws {
        var random = Generator(state: seed)
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: PerformanceTests.document(lines: 600))
        let (lazy, lazyContainer) = layoutManager(contiguous: true, for: storage)
        lazy.ensureLayout(forCharacterRange: NSRange(location: storage.length / 2, length: 3_000))

        let snippets = ["x", "\n", "```\n", "$$\n", "# Heading\n", "**", "| a | b |\n", "> ", "- ", "\n\n", "Term\n: definition\n", "![i](missing.png)\n"]
        for step in 0..<300 {
            let length = storage.length
            switch Int.random(in: 0..<10, using: &random) {
            case 0...4:
                let snippet = snippets.randomElement(using: &random)!
                storage.replaceCharacters(in: NSRange(location: Int.random(in: 0...length, using: &random), length: 0), with: snippet)
            case 5, 6:
                let location = Int.random(in: 0..<max(1, length), using: &random)
                storage.replaceCharacters(in: NSRange(location: location, length: min(Int.random(in: 0...40, using: &random), length - location)), with: "")
            case 7:
                let line = Int.random(in: 0..<storage.structure.lineCount, using: &random)
                storage.revealedLines = line...min(storage.structure.lineCount - 1, line + Int.random(in: 0...5, using: &random))
            case 8:
                let line = Int.random(in: 0..<storage.structure.lineCount, using: &random)
                if storage.foldableRange(forHeadingLine: line) != nil {
                    storage.setFolded(!storage.foldedHeadings.contains(line), headingLine: line)
                } else {
                    storage.unfoldAll()
                }
            default:
                // Something on screen somewhere asks for layout.
                let location = Int.random(in: 0..<max(1, storage.length), using: &random)
                lazy.ensureLayout(forCharacterRange: NSRange(location: location, length: min(2_000, storage.length - location)))
            }
            if step % 100 == 99 {
                let (full, fullContainer) = layoutManager(contiguous: true, for: storage)
                let expected = fragments(full, fullContainer)
                let actual = fragments(lazy, lazyContainer)
                storage.removeLayoutManager(full)
                #expect(actual.count == expected.count, "step \(step)")
                // Laid out in a different order, positions sum up differently in the last bits.
                func same(_ a: CGRect, _ b: CGRect) -> Bool {
                    abs(a.minX - b.minX) < 0.01 && abs(a.minY - b.minY) < 0.01 && abs(a.width - b.width) < 0.01 && abs(a.height - b.height) < 0.01
                }
                let first = zip(actual, expected).enumerated().first { !same($0.element.0, $0.element.1) }
                #expect(first == nil, "step \(step): fragment \(first?.offset ?? -1) is \(String(describing: first?.element.0)), not \(String(describing: first?.element.1))")
            }
        }
    }

    /// A line opening with hidden backticks has their null glyph laid out at
    /// the end of the line above. Restyling the line below laid the line out
    /// again from its own start, taking the glyph back: the line drew lower,
    /// leaving its code backgrounds behind and the caret off its text.
    @Test("Moving the caret past a line opening with code leaves its glyphs where they were")
    func revealBelowLeadingCode() {
        let text = "Every claim gets a citation and a\n`Sources:` list, and a `url → [n]` mapping\nso the numbers come from retrieval\never emits small integers.\n"
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        let (manager, container) = layoutManager(contiguous: true, for: storage)

        /// The characters on each line fragment.
        func lines(_ manager: NSLayoutManager, _ container: NSTextContainer) -> [NSRange] {
            manager.ensureLayout(for: container)
            var ranges: [NSRange] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { _, _, _, glyphs, _ in
                ranges.append(manager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil))
            }
            return ranges
        }

        _ = lines(manager, container)
        for line in [1, 2, 3, 2, 1, 0] {
            storage.revealedLines = line...line
            let fresh = MarkdownTextStorage(theme: .light)
            fresh.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            fresh.revealedLines = line...line
            let (freshManager, freshContainer) = layoutManager(contiguous: true, for: fresh)
            #expect(lines(manager, container) == lines(freshManager, freshContainer), "caret on line \(line)")
        }
    }

    /// Concealed markup opening a line stays on it as a glyph of no width,
    /// but a line hidden whole, a link definition, is null glyphs that go
    /// with the line before. Laid out again from among them, they made a
    /// line of their own and gave a blank line after them their height.
    /// Edited and moved through anyhow, a document lays out as afresh.
    @Test("Lines laid out again beside hidden ones lay out as laying it all out")
    func hiddenLinesLayOutAsFresh() {
        var generator = SeededGenerator(seed: 1)
        let blocks = [
            "> quote `code`\n> `more` quote", "`code` opening a line", "# Heading", "- item\n- [x] task",
            "[ref]: /u\n[x]: /v", "[one]: /w", "Prose with [ref] and **bold**.", "```\nlet x = 1\n```", ">\n> after a blank quote line",
        ]

        func lines(_ manager: NSLayoutManager, _ container: NSTextContainer) -> [CGRect] {
            manager.ensureLayout(for: container)
            var rects: [CGRect] = []
            manager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs)) { rect, used, _, _, _ in
                rects.append(rect.union(used))
            }
            return rects
        }

        for _ in 0..<60 {
            let text = (0..<Int.random(in: 3...7, using: &generator)).map { _ in blocks.randomElement(using: &generator)! }
                .joined(separator: "\n\n")
            let storage = MarkdownTextStorage(theme: .light)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            let (manager, container) = layoutManager(contiguous: true, for: storage)
            _ = lines(manager, container)
            var steps: [String] = []
            for _ in 0..<6 {
                let line = Int.random(in: 0..<storage.structure.lineCount, using: &generator)
                steps.append("caret \(line)")
                storage.revealedLines = line...line
                let range = storage.characterRange(forLines: line...line)
                let content = (storage.string as NSString).substring(with: range)
                // Not in or beside a definition, whose links restyle once typing pauses.
                if Bool.random(using: &generator), !content.hasPrefix("["), content.trimmingCharacters(in: .whitespacesAndNewlines).count > 0 {
                    storage.replaceCharacters(in: NSRange(location: range.location + 1, length: 0), with: "x")
                    steps.append("type")
                }
                let fresh = MarkdownTextStorage(theme: .light)
                fresh.replaceCharacters(in: NSRange(location: 0, length: 0), with: storage.string)
                fresh.revealedLines = storage.revealedLines
                let (freshManager, freshContainer) = layoutManager(contiguous: true, for: fresh)
                // Within a hundredth of a point: sums of line heights differ
                // in their last bits by the order they were added in.
                let edited = lines(manager, container), laidOut = lines(freshManager, freshContainer)
                let first = zip(edited, laidOut).first { !$0.isClose(to: $1) }.map { "\($0) vs \($1)" }
                #expect(edited.count == laidOut.count && first == nil, "\(text.debugDescription) \(steps): \(first ?? "\(edited.count) lines vs \(laidOut.count)")")
            }
        }
    }

    /// Counts the times AppKit is asked to place the caret again.
    private final class CaretCountingTextView: NSTextView {
        var caretPlacements = 0
        override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
            caretPlacements += 1
            super.updateInsertionPointStateAndRestartTimer(restartFlag)
        }
    }

    /// The caret is an indicator view placed when the selection changes,
    /// before the reveal that follows moves the text: it stayed between lines.
    /// Placed from inside the selection change, it showed at the line's start.
    @Test("A reveal places the caret again, on the text it moved, once AppKit is done")
    func revealPlacesCaret() async throws {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "---\ntitle: x\n---\n\n# Heading\n\nText.\n")
        let (manager, container) = layoutManager(contiguous: true, for: storage)
        let textView = CaretCountingTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), textContainer: container)
        manager.ensureLayout(for: container)

        textView.caretPlacements = 0
        storage.revealedLines = 0...0
        storage.revealedLines = 4...4
        #expect(textView.caretPlacements == 0)
        for _ in 0..<50 where textView.caretPlacements == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(textView.caretPlacements > 0)
    }

    /// The caret on an empty document is sized from the typing attributes
    /// alone; without the paragraph style those carry, it came out shorter
    /// than the caret on the first typed line.
    @Test("The caret is the same height before and after the first character")
    func caretHeightOnEmptyDocument() throws {
        let document = Document(theme: .light)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        editor.view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        let textView = editor.textView
        let manager = try #require(textView.layoutManager)
        let container = try #require(textView.textContainer)

        manager.ensureLayout(for: container)
        let empty = manager.extraLineFragmentRect.height

        textView.insertText("e", replacementRange: NSRange(location: 0, length: 0))
        manager.ensureLayout(for: container)
        let typed = manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil).height

        #expect(abs(empty - typed) < 0.01, "empty \(empty), typed \(typed)")
    }

    @Test("Revealing a heading or quote leaves the lines below in place; a quote's marker hangs")
    func revealHangsMarkers() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Intro.\n\n## Try it here\n\n> Quoted\n\nAfter.\n")
        let (manager, container) = layoutManager(contiguous: true, for: storage)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), textContainer: container)
        textView.textContainerInset = NSSize(width: 100, height: 0)

        /// Where the first glyph of some text sits, and where the last line starts.
        func positions(of text: String) -> (x: CGFloat, after: CGFloat) {
            manager.ensureLayout(for: container)
            let index = (storage.string as NSString).range(of: text).location
            let glyph = manager.glyphIndexForCharacter(at: index)
            let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let last = manager.lineFragmentRect(forGlyphAt: manager.numberOfGlyphs - 1, effectiveRange: nil)
            return (fragment.minX + manager.location(forGlyphAt: glyph).x, last.minY)
        }

        let heading = positions(of: "Try it here")
        let quote = positions(of: "Quoted")
        storage.revealedLines = 2...2
        let revealedHeading = positions(of: "Try it here")
        // A heading's `## ` makes room (the text glides over), but the
        // heading keeps its height, so nothing below it moves.
        #expect(revealedHeading.x > heading.x + 1)
        #expect(abs(revealedHeading.after - heading.after) < 0.5)
        storage.revealedLines = 4...4
        let revealedQuote = positions(of: "Quoted")
        #expect(abs(revealedQuote.x - quote.x) < 0.5)
        #expect(abs(revealedQuote.after - quote.after) < 0.5)
    }

    @Test("A reveal glides: its first frame draws every word where it was, its markers unseen")
    func revealMotionStartsFromOldLayout() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "Intro.\n\nSome **bold** words here.\n")
        let (manager, container) = layoutManager(contiguous: true, for: storage)
        manager.ensureLayout(for: container)
        let text = storage.string as NSString
        func x(of word: String) -> CGFloat {
            let glyph = manager.glyphIndexForCharacter(at: text.range(of: word).location)
            return manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX + manager.location(forGlyphAt: glyph).x
        }
        let before = x(of: "words")

        let moved = manager.animateReveal(across: [storage.characterRange(forLines: 2...2)]) { storage.revealedLines = 2...2 }
        #expect(moved)
        let motion = try! #require(manager.revealMotion)
        let wordsGlyph = manager.glyphIndexForCharacter(at: text.range(of: "words").location)
        // At the start, layout plus the motion's offset is the old place.
        #expect(abs(x(of: "words") + motion.offset(forGlyph: wordsGlyph, progress: 0).dx - before) < 0.5)
        #expect(motion.offset(forGlyph: wordsGlyph, progress: 1) == .zero)
        // The markers that appeared fade in rather than slide.
        let marker = manager.glyphIndexForCharacter(at: text.range(of: "**").location)
        #expect(motion.segment(containing: marker)?.fadesIn == true)
        #expect(motion.progress(at: motion.start) == 0)
        #expect(motion.progress(at: motion.start + motion.duration) == 1)
    }

    @Test("Coloured text and highlights draw")
    func coloredTextDraws() throws {
        for theme in [Theme.light, Theme.dark] {
            let storage = MarkdownTextStorage(theme: theme)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a <span style=\"color: #E5484D\">red</span> <mark style=\"background: #FFF3A3\">hi</mark> <mark>x</mark>\n\nnext\n")
            let (manager, container) = layoutManager(contiguous: true, for: storage)
            let glyphs = manager.glyphRange(for: container)
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: 200, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            manager.drawBackground(forGlyphRange: glyphs, at: .zero)
            manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// Drawing a code block's card walked every line of the block, twice
    /// over, on each redraw: a tenth of a second for a long one.
    @Test("Drawing part of a long code block fills its card past both edges, at a cost that does not grow with the block")
    func codeCardDrawsOnlyWhatShows() throws {
        func drawMiddle(of lines: Int) throws -> (milliseconds: Double, edges: [NSColor], card: NSColor) {
            let storage = MarkdownTextStorage(theme: .light)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "```\n" + String(repeating: "let x = 1\n", count: lines) + "```\n\nafter\n")
            let (manager, container) = layoutManager(contiguous: true, for: storage)
            let middle = NSRange(location: storage.length / 2, length: 600)
            manager.ensureLayout(forCharacterRange: middle)
            let glyphs = manager.glyphRange(forCharacterRange: middle, actualCharacterRange: nil)
            let bounds = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: Int(bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            var best = Double.infinity
            for _ in 0..<3 {
                let start = Date()
                manager.drawBackground(forGlyphRange: glyphs, at: NSPoint(x: 0, y: -bounds.minY))
                best = min(best, Date().timeIntervalSince(start) * 1000)
            }
            NSGraphicsContext.restoreGraphicsState()
            // The corners: where a card ending in view would round off.
            let edges = [rep.colorAt(x: 1, y: 0), rep.colorAt(x: 1, y: rep.pixelsHigh - 1)].compactMap { $0 }
            return (best, edges, try #require(storage.theme.codeBackground.usingColorSpace(.deviceRGB)))
        }
        func close(_ a: NSColor, _ b: NSColor) -> Bool {
            guard let a = a.usingColorSpace(.deviceRGB) else { return false }
            return abs(a.redComponent - b.redComponent) < 0.03 && abs(a.greenComponent - b.greenComponent) < 0.03
                && abs(a.blueComponent - b.blueComponent) < 0.03
        }

        let short = try drawMiddle(of: 1_000)
        let long = try drawMiddle(of: 20_000)
        #expect(long.edges.count == 2 && long.edges.allSatisfy { close($0, long.card) }, "\(long.edges)")
        // Twenty times the lines: about the same time, not twenty times it.
        #expect(long.milliseconds < max(5, short.milliseconds * 4), "\(short.milliseconds) ms, then \(long.milliseconds) ms")
    }

    /// Two fenced blocks one blank line apart were filled as one card, the
    /// blank line between them inside it, while one of their fences showed.
    @Test("Code blocks a blank line apart get a card each; an indented block's blank lines stay in its card")
    func codeCardsStopAtBlankLines() throws {
        func blankLineIsCard(_ text: String, revealing revealed: ClosedRange<Int>?, blankLine: Int) throws -> Bool {
            let storage = MarkdownTextStorage(theme: .light)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            storage.revealedLines = revealed
            let (manager, container) = layoutManager(contiguous: true, for: storage)
            manager.ensureLayout(for: container)
            let used = manager.usedRect(for: container)
            let rep = try #require(NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: 600, pixelsHigh: Int(used.maxY) + 20, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            ))
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            manager.drawBackground(forGlyphRange: NSRange(location: 0, length: manager.numberOfGlyphs), at: .zero)
            NSGraphicsContext.restoreGraphicsState()
            let glyph = manager.glyphIndexForCharacter(at: storage.characterRange(forLines: blankLine...blankLine).location)
            let line = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            // Drawn unflipped, so the rows run from the bottom.
            let pixel = try #require(rep.colorAt(x: 300, y: rep.pixelsHigh - 1 - Int(line.midY))?.usingColorSpace(.deviceRGB))
            let card = try #require(storage.theme.codeBackground.usingColorSpace(.deviceRGB))
            return pixel.alphaComponent > 0.5 && abs(pixel.redComponent - card.redComponent) < 0.03
                && abs(pixel.greenComponent - card.greenComponent) < 0.03 && abs(pixel.blueComponent - card.blueComponent) < 0.03
        }

        let fenced = "```\na\nb\n```\n\n```bash\ntest\n```\n"
        for revealed in [nil, 0...0, 3...3, 5...5, 6...6] as [ClosedRange<Int>?] {
            #expect(try !blankLineIsCard(fenced, revealing: revealed, blankLine: 4), "revealing \(String(describing: revealed))")
        }
        #expect(try blankLineIsCard("Intro.\n\n    a\n\n    b\n\nAfter.\n", revealing: nil, blankLine: 3))
    }

    /// A table too wide for the column wraps its cells side by side, each
    /// cell's lines going down from the top of the row.
    @Test("A wrapping table's cells sit side by side, and points and rects find them")
    func wrappingTable() throws {
        let storage = MarkdownTextStorage(theme: .light)
        let long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau"
        let text = "Before\n\n| Ref | Finding | Remedy |\n| --- | --- | --- |\n| M-01 | \(long) | Fix it soon |\n| M-02 | short | \(long) |\n\nAfter\n"
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.maxImageWidth = 400
        storage.restyleTablesChangingFit()
        let (manager, container) = layoutManager(contiguous: true, for: storage)
        container.size = CGSize(width: 400 + 2 * container.lineFragmentPadding, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)

        let rowStart = (text as NSString).range(of: "| M-01").location
        let row = try #require(manager.wrappedRow(atCharacter: rowStart + 3))
        // The long cell takes several lines; every cell's first line is at the row's top.
        let tops = Dictionary(grouping: row.fragments) { $0.rect.minX }.mapValues { $0.map(\.rect.minY).min() ?? 0 }
        #expect(tops.count == 3)
        #expect(Set(tops.values).count == 1)
        #expect(row.fragments.count > 3)
        let bounds = manager.bounds(of: row)
        #expect(bounds.maxX <= 400 + container.lineFragmentPadding + 0.5)

        // The next row starts below the deepest cell, and the text after below the table.
        let next = try #require(manager.wrappedRow(atCharacter: (text as NSString).range(of: "| M-02").location + 3))
        #expect(manager.bounds(of: next).minY >= bounds.maxY - 0.5)
        let after = manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: (text as NSString).range(of: "After").location), effectiveRange: nil)
        #expect(after.minY >= manager.bounds(of: next).maxY - 0.5)

        // A point on the long cell's second line finds a word of it, not the next row.
        let middle = Dictionary(grouping: row.fragments) { $0.rect.minX }.sorted { $0.key < $1.key }[1].value
        let second = try #require(middle.sorted { $0.rect.minY < $1.rect.minY }.dropFirst().first)
        let point = NSPoint(x: second.rect.minX + 20, y: second.rect.midY)
        let character = manager.characterIndexForGlyph(at: manager.glyphIndex(for: point, in: container))
        #expect(NSLocationInRange(character, NSRange(location: rowStart, length: 6 + (long as NSString).length + 10)))
        #expect(NSLocationInRange(character, manager.characterRange(forGlyphRange: second.glyphs, actualGlyphRange: nil)))
        // Below the short cells' text, a click lands at the end of that cell.
        let third = Dictionary(grouping: row.fragments) { $0.rect.minX }.sorted { $0.key < $1.key }[2].value
        let below = NSPoint(x: third[0].rect.minX + 4, y: bounds.maxY - 2)
        let end = manager.characterIndexForGlyph(at: manager.glyphIndex(for: below, in: container))
        #expect(NSLocationInRange(end, manager.characterRange(forGlyphRange: third.last!.glyphs, actualGlyphRange: nil)))

        // A thin rect across the row's top finds every cell, not just the first.
        let strip = manager.glyphRange(forBoundingRect: NSRect(x: 0, y: bounds.minY + 1, width: 500, height: 2), in: container)
        for fragment in row.fragments { #expect(NSIntersectionRange(strip, fragment.glyphs).length > 0) }
    }

    /// TextKit placed the caret in a wrapping row as for a line it laid out
    /// itself: at the end of a cell's word it sat inside the last letter,
    /// before that letter it went to the start of the cell, and at the start
    /// of a row to the end of the row above.
    @Test("In a wrapping table the caret sits on the edges of the letters")
    func wrappingTableCaret() throws {
        let long = String(repeating: "alpha beta ", count: 12)
        let text = "| Engine | Notes | Verdict |\n| --- | --- | --- |\n| **AetherEngine** (FFmpeg) | \(long)| **chosen** |\n| KSPlayer | paid tier | no |\n"
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.maxImageWidth = 400
        storage.restyleTablesChangingFit()
        let (manager, container) = layoutManager(contiguous: true, for: storage)
        container.size = CGSize(width: 400 + 2 * container.lineFragmentPadding, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let ns = text as NSString

        func caret(_ index: Int) throws -> NSRect {
            var count = 0
            let rects = try #require(manager.rectArray(
                forCharacterRange: NSRange(location: index, length: 0),
                withinSelectedCharacterRange: NSRange(location: index, length: 0), in: container, rectCount: &count
            ))
            #expect(count == 1)
            return rects[0]
        }
        // TextKit's own bounds for a glyph in these rows are as off as its caret was.
        func width(_ index: Int) throws -> CGFloat {
            let font = try #require(storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont)
            return font.advancement(forCGGlyph: manager.cgGlyph(at: manager.glyphIndexForCharacter(at: index))).width
        }
        func lineRect(_ index: Int) -> NSRect {
            manager.lineFragmentRect(forGlyphAt: manager.glyphIndexForCharacter(at: index), effectiveRange: nil)
        }
        func left(_ index: Int) -> CGFloat {
            lineRect(index).minX + manager.location(forGlyphAt: manager.glyphIndexForCharacter(at: index)).x
        }

        for word in ["KSPlayer", "paid", "tier", "AetherEngine", "chosen", "no"] {
            let range = ns.range(of: word, options: .backwards)
            try #require(manager.wrappedRow(atCharacter: range.location) != nil)
            // Before each letter: on its left edge, on its line.
            for index in range.location..<NSMaxRange(range) {
                let rect = try caret(index)
                #expect(abs(rect.minX - left(index)) < 0.5, "before \(ns.substring(with: NSRange(location: index, length: 1))) of \(word)")
                #expect(abs(rect.minY - lineRect(index).minY) < 0.5)
            }
            // After the word: past its last letter, not inside it or in the next cell.
            let last = NSMaxRange(range) - 1
            let end = try caret(NSMaxRange(range))
            let expected = try left(last) + width(last)
            #expect(abs(end.minX - expected) < 0.5, "after \(word)")
            #expect(end.minX <= lineRect(last).maxX)
            #expect(abs(end.minY - lineRect(last).minY) < 0.5)
        }
    }

    /// Clicks in a wrapping table put the caret where the click was. They
    /// landed a letter early after a word; past the last cell's text, after
    /// the row's closing `|`; and low in the header, in the row below it,
    /// past the hidden `| --- |` line between them.
    @Test("A click in a wrapping table puts the caret at the nearest letter edge of its own cell")
    func wrappingTableClicks() throws {
        let text = "| Engine | MKV | HW HEVC | HDR out | Verdict |\n| --- | --- | --- | --- | --- |\n"
            + "| **AetherEngine** (FFmpeg demux → VideoToolbox → AVSampleBufferDisplayLayer) | yes | yes | HDR10/10+/HLG native | **chosen** |\n"
            + "| KSPlayer | paid tier | yes | yes | no |\n"
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.maxImageWidth = 360
        storage.restyleTablesChangingFit()
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 1000))
        let manager = MarkdownLayoutManager()
        let container = try #require(view.textContainer)
        container.replaceLayoutManager(manager)
        manager.replaceTextStorage(storage)
        view.textContainerInset = .zero
        container.size = CGSize(width: 360 + 2 * container.lineFragmentPadding, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let ns = text as NSString
        try #require(manager.wrappedRow(atCharacter: 2) != nil)

        func click(_ dx: CGFloat, from index: Int) throws -> Int {
            let caret = try #require(manager.caretRect(at: index))
            return view.characterIndexForInsertion(at: NSPoint(x: caret.minX + dx, y: caret.midY))
        }
        for word in ["Engine", "MKV", "HW", "HEVC", "Verdict", "chosen", "paid", "tier", "KSPlayer"] {
            let range = ns.range(of: word)
            let end = NSMaxRange(range)
            #expect(try click(3, from: end) == end, "just past \(word)")
            #expect(try click(-1, from: end) == end, "on the right of \(word)'s last letter")
            #expect(try click(1, from: range.location) == range.location, "on the left of \(word)'s first letter")
            #expect(try click(-2, from: range.location) == range.location, "just before \(word)")
        }
    }

    /// A word wider than the whole column, as a line of JSON is, made the
    /// table give up its grid and show as source: it breaks inside instead.
    @Test("A wrapping table breaks a word too long for its column inside the cell")
    func wrappingTableBreaksLongWord() throws {
        let json = #"{"log-opts":{"max-size":"20m","max-file":"5"},"live-restore":true,"no-new-privileges":true,"icc":false}"#
        let text = "| ID | Finding | Fix |\n| --- | --- | --- |\n| M4 | Leftover /var/www/glpi-10.0.17-before-upgrade (258 MB) | Delete it |\n"
            + "| M9 | No /etc/docker/daemon.json: container logs are unbounded | Write \(json) and restart dockerd |\n"
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
        storage.maxImageWidth = 400
        storage.restyleTablesChangingFit()
        let rowStart = (text as NSString).range(of: "| M9").location
        let grid = try #require(storage.attribute(.mdTableRow, at: rowStart, effectiveRange: nil) as? TableGrid)
        #expect(grid.wrapping != nil)
        #expect(grid.indent + (grid.edges.last ?? 0) <= 400 + 0.5)

        let (manager, container) = layoutManager(contiguous: true, for: storage)
        container.size = CGSize(width: 400 + 2 * container.lineFragmentPadding, height: .greatestFiniteMagnitude)
        manager.ensureLayout(for: container)
        let row = try #require(manager.wrappedRow(atCharacter: rowStart + 3))
        // The JSON goes down its cell, every line inside the column.
        let fix = Dictionary(grouping: row.fragments) { $0.rect.minX }.sorted { $0.key < $1.key }[2].value
        #expect(fix.count > 3)
        for fragment in row.fragments {
            #expect(manager.lineFragmentUsedRect(forGlyphAt: fragment.glyphs.location, effectiveRange: nil).maxX <= fragment.rect.maxX + 0.5)
        }
    }

    /// Laid out again from below a wrapping row, TextKit started under the
    /// row's last fragment, the last line of its last cell: when that cell
    /// was shorter than the deepest, what followed drew over the table.
    @Test("Moving the caret below a wrapping table leaves the text after it below the table")
    func revealBelowWrappingTable() {
        let long = "alpha beta gamma delta epsilon zeta eta theta iota kappa lambda mu nu xi omicron pi rho sigma tau"
        let text = "Before\n\n| Ref | Finding | Remedy |\n| --- | --- | --- |\n| H5 | **Stale** \(long) | \(long) |\n"
            + "| H6 | **Images are stale.** \(long) **5 CRITICAL** | Rebuild |\n\n### Medium\n\nOne\n\nTwo\n\nThree\n"
        func storage(revealing line: Int?) -> MarkdownTextStorage {
            let storage = MarkdownTextStorage(theme: .light)
            storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            storage.maxImageWidth = 400
            storage.restyleTablesChangingFit()
            storage.revealedLines = line.map { $0...$0 }
            return storage
        }
        func layout(_ storage: MarkdownTextStorage) -> (MarkdownLayoutManager, NSTextContainer) {
            let (manager, container) = layoutManager(contiguous: true, for: storage)
            container.size = CGSize(width: 400 + 2 * container.lineFragmentPadding, height: .greatestFiniteMagnitude)
            return (manager, container)
        }

        let edited = storage(revealing: nil)
        let (manager, container) = layout(edited)
        _ = fragments(manager, container)
        for line in [5, 6, 7, 9, 11, 5, 9, 4, 13, 2, 0] {
            edited.revealedLines = line...line
            let (freshManager, freshContainer) = layout(storage(revealing: line))
            #expect(fragments(manager, container) == fragments(freshManager, freshContainer), "caret on line \(line)")
        }
    }

    @Test("Zooming keeps the column centred, the page never scrolled sideways")
    func zoomKeepsColumnCentred() {
        let document = Document(text: PerformanceTests.document(lines: 40), theme: .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 600, height: 400))
        editor.view.layoutSubtreeIfNeeded()
        // About a point to the right, as a pinch there would.
        for zoom in [2.5, 1.5, 0.6] {
            editor.scrollView.setMagnification(zoom, centeredAt: NSPoint(x: 400, y: 100))
            editor.view.layoutSubtreeIfNeeded()
            let clip = editor.scrollView.contentView.bounds
            let textView = editor.textView
            #expect(clip.minX == 0)
            #expect(abs(textView.frame.width - clip.width) < 1)
            let left = textView.textContainerInset.width
            let right = textView.frame.width - left - textView.textContainer!.size.width
            #expect(abs(left - right) < 1, "zoom \(zoom): \(left) | \(right)")
        }
        withExtendedLifetime(window) {}
    }

    @Test("A pinch magnifies the text as it is laid out, and wraps it once the fingers lift")
    func pinchWrapsOnLift() throws {
        let document = Document(text: PerformanceTests.document(lines: 400), theme: .light)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 900, height: 600))
        editor.view.layoutSubtreeIfNeeded()
        let textView = editor.textView
        let container = try #require(textView.textContainer)
        let clip = editor.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 3_000))
        let column = container.size.width

        // The line under the fingers, and where it shows.
        let fingers = clip.bounds.minY + 200
        let anchor = textView.characterIndexForInsertion(at: NSPoint(x: clip.bounds.midX, y: fingers))
        func shown() -> CGFloat {
            let manager = textView.layoutManager!
            let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: anchor, length: 1), actualCharacterRange: nil)
            let top = manager.boundingRect(forGlyphRange: glyphs, in: container).minY + textView.textContainerOrigin.y
            return (top - clip.bounds.minY) * editor.scrollView.magnification
        }
        for _ in 0..<8 {
            editor.pinch(by: 0.1, at: NSPoint(x: clip.bounds.midX, y: fingers), ending: false)
            editor.view.layoutSubtreeIfNeeded()
            #expect(container.size.width == column)
            #expect(clip.bounds.minX == 0)
            let left = textView.textContainerInset.width
            let right = textView.frame.width - left - container.size.width
            #expect(abs(left - right) < 1)
        }
        // Lifting the fingers wraps the text; the line under them stays put.
        let before = shown()
        editor.pinch(by: 0, at: NSPoint(x: clip.bounds.midX, y: fingers), ending: true)
        editor.view.layoutSubtreeIfNeeded()
        #expect(container.size.width < column)
        #expect(container.size.width <= clip.bounds.width)
        #expect(abs(shown() - before) < 2, "\(before) → \(shown())")
        withExtendedLifetime(window) {}
    }

    @Test("A large document keeps its column when zoomed, and scrolls sideways once wider than the window")
    func largeDocumentKeepsColumn() throws {
        let document = Document(text: PerformanceTests.document(lines: 25_000), theme: .light)
        #expect(document.storage.length > EditorViewController.rewrapLimit)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        let editor = EditorViewController(textStorage: document.storage, undoManager: document.undoManager)
        // Scroll bars that take room, as with a mouse attached: the column
        // must not change as they come and go.
        editor.scrollView.scrollerStyle = .legacy
        window.contentViewController = editor
        window.setContentSize(NSSize(width: 600, height: 400))
        editor.view.layoutSubtreeIfNeeded()
        let textView = editor.textView
        let container = try #require(textView.textContainer)
        let clip = editor.scrollView.contentView
        let column = container.size.width

        // ⌘+ shows where the lines start.
        let suite = "MdEditZoomTest-\(UUID().uuidString)"
        let settings = Settings(defaults: try #require(UserDefaults(suiteName: suite)))
        defer { settings.defaults.removePersistentDomain(forName: suite) }
        settings.zoom = 2
        editor.applySettings(settings)
        editor.view.layoutSubtreeIfNeeded()
        #expect(container.size.width == column)
        #expect(textView.frame.width > clip.bounds.width)
        #expect(abs(clip.bounds.minX - (textView.textContainerOrigin.x - Metrics.chromeInset)) < 1)
        clip.scroll(to: NSPoint(x: 10_000, y: 0))
        editor.view.layoutSubtreeIfNeeded()
        #expect(clip.bounds.maxX == textView.frame.width)

        editor.scrollView.setMagnification(0.6, centeredAt: NSPoint(x: clip.bounds.midX, y: 0))
        editor.view.layoutSubtreeIfNeeded()
        #expect(container.size.width == column)
        #expect(clip.bounds.minX == 0)
        let left = textView.textContainerInset.width
        let right = textView.frame.width - left - container.size.width
        #expect(abs(left - right) < 1)
        withExtendedLifetime(window) {}
    }
}

/// The same numbers every run, so a failing case can be run again.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        // SplitMix64.
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.01 && abs(minY - other.minY) < 0.01
            && abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }
}
