import AppKit

/// Text gliding from where it sat to where a reveal put it.
///
/// Showing a line's markdown moves its words: `**` appears between them, a
/// long line rewraps, the lines below shift. Layout itself cannot animate,
/// so the layout manager lays out the new state at once and draws each
/// moved stretch of glyphs offset back towards its old place, the offset
/// springing to nothing; markers that appear fade in where they land.
struct RevealMotion {
    struct Segment {
        var glyphs: NSRange
        /// From the glyphs' new place back to their old one.
        var offset: CGVector
        /// Glyphs that were not shown before, which fade in instead of moving.
        var fadesIn: Bool
        /// Whole lines below a reveal, which take their decoration with them.
        var isWholeLines = false

        /// Words that rewrapped onto another line: rather than cut diagonally
        /// across the text, they fade out where they were and in where they land.
        var changesLine: Bool { !isWholeLines && !fadesIn && abs(offset.dy) > 0.25 }
    }

    /// Sorted by glyph and not overlapping.
    var segments: [Segment]
    var start: CFTimeInterval
    var duration: CFTimeInterval = Motion.reveal

    /// How far along, from 0 to 1, on a critically damped spring: quick off
    /// the mark, settling without overshoot.
    func progress(at time: CFTimeInterval = CACurrentMediaTime()) -> CGFloat {
        // Compared before subtracting: with a large start (the time since
        // boot), `(start + duration) - start` can round to just under
        // `duration`, and the last frame then fell short of the end.
        guard time < start + duration else { return 1 }
        let t = max(0, time - start)
        let omega = 16 / duration
        return CGFloat(1 - (1 + omega * t) * exp(-omega * t))
    }

    var isFinished: Bool { progress() >= 1 }

    /// The offset still to travel for a glyph, for drawing it and for
    /// starting a new motion from wherever this one has got to.
    func offset(forGlyph glyph: Int, progress: CGFloat) -> CGVector {
        guard let segment = segment(containing: glyph), !segment.fadesIn, !segment.changesLine else { return .zero }
        return CGVector(dx: segment.offset.dx * (1 - progress), dy: segment.offset.dy * (1 - progress))
    }

    func segment(containing glyph: Int) -> Segment? {
        var low = 0, high = segments.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = segments[middle].glyphs
            if glyph < range.location { high = middle - 1 } else if glyph >= NSMaxRange(range) { low = middle + 1 } else { return segments[middle] }
        }
        return nil
    }
}

extension MarkdownLayoutManager {
    /// Where a character was drawn: its glyph's left edge and its line's top.
    private struct Spot {
        var x: CGFloat
        var lineY: CGFloat
        var visible: Bool
    }

    /// Makes a change to which markers show, then sets up the motion from
    /// the old layout to the new one across these character ranges (the
    /// lines revealed before and after). Returns whether anything moves.
    @discardableResult
    func animateReveal(across ranges: [NSRange], change: () -> Void) -> Bool {
        guard let storage = textStorage else { change(); return false }
        let ranges = Self.merged(ranges.map { NSIntersectionRange($0, NSRange(location: 0, length: storage.length)) })
        guard !ranges.isEmpty else { change(); return false }

        // Where everything is now, counting any motion still under way.
        let progress = revealMotion?.progress() ?? 1
        for range in ranges { ensureLayout(forCharacterRange: range) }
        let before = ranges.map { spots(in: $0, progress: progress) }
        let gapsBefore = ranges.map { lineTop(atCharacter: NSMaxRange($0), progress: progress) }

        revealMotion = nil
        change()

        var segments: [RevealMotion.Segment] = []
        for (index, range) in ranges.enumerated() {
            ensureLayout(forCharacterRange: range)
            let after = spots(in: range, progress: 1)
            segments += lineSegments(range, before: before[index], after: after)
            // The lines down to the next revealed range move as one, by as
            // much as these lines grew or shrank.
            let gapStart = NSMaxRange(range)
            let gapEnd = index + 1 < ranges.count ? ranges[index + 1].location : storage.length
            if gapEnd > gapStart, let old = gapsBefore[index], let new = lineTop(atCharacter: gapStart, progress: 1), abs(old - new) > 0.25 {
                let glyphs = glyphRange(forCharacterRange: NSRange(location: gapStart, length: gapEnd - gapStart), actualCharacterRange: nil)
                segments.append(.init(glyphs: glyphs, offset: CGVector(dx: 0, dy: old - new), fadesIn: false, isWholeLines: true))
            }
        }
        guard !segments.isEmpty else { return false }
        revealMotion = RevealMotion(segments: segments.sorted { $0.glyphs.location < $1.glyphs.location }, start: CACurrentMediaTime())
        return true
    }

    /// Stretches of a range that moved together, and the glyphs newly shown.
    private func lineSegments(_ range: NSRange, before: [Spot], after: [Spot]) -> [RevealMotion.Segment] {
        var segments: [RevealMotion.Segment] = []
        func add(_ character: Int, offset: CGVector, fadesIn: Bool) {
            let glyph = glyphIndexForCharacter(at: character)
            if var last = segments.last, NSMaxRange(last.glyphs) == glyph, last.fadesIn == fadesIn,
               abs(last.offset.dx - offset.dx) < 0.25, abs(last.offset.dy - offset.dy) < 0.25 {
                last.glyphs.length += 1
                segments[segments.count - 1] = last
            } else {
                segments.append(.init(glyphs: NSRange(location: glyph, length: 1), offset: offset, fadesIn: fadesIn))
            }
        }
        for offset in 0..<range.length {
            let old = before[offset], new = after[offset]
            guard new.visible else { continue }
            if !old.visible {
                add(range.location + offset, offset: .zero, fadesIn: true)
            } else {
                let delta = CGVector(dx: old.x - new.x, dy: old.lineY - new.lineY)
                guard abs(delta.dx) > 0.25 || abs(delta.dy) > 0.25 else { continue }
                add(range.location + offset, offset: delta, fadesIn: false)
            }
        }
        return segments
    }

    private func spots(in range: NSRange, progress: CGFloat) -> [Spot] {
        guard let storage = textStorage else { return [] }
        let text = storage.mutableString
        return (range.location..<NSMaxRange(range)).map { character in
            let glyph = glyphIndexForCharacter(at: character)
            guard glyph < numberOfGlyphs else { return Spot(x: 0, lineY: 0, visible: false) }
            let fragment = lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil, withoutAdditionalLayout: true)
            let shift = revealMotion?.offset(forGlyph: glyph, progress: progress) ?? .zero
            let unit = text.character(at: character)
            let visible = !propertyForGlyph(at: glyph).contains(.null) && unit != 0x0A && unit != 0x0D
            return Spot(x: fragment.minX + location(forGlyphAt: glyph).x + shift.dx, lineY: fragment.minY + shift.dy, visible: visible)
        }
    }

    private func lineTop(atCharacter character: Int, progress: CGFloat) -> CGFloat? {
        guard let storage = textStorage, character < storage.length else { return nil }
        let glyph = glyphIndexForCharacter(at: character)
        guard glyph < numberOfGlyphs else { return nil }
        let shift = revealMotion?.offset(forGlyph: glyph, progress: progress) ?? .zero
        return lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + shift.dy
    }

    private static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, range.location <= NSMaxRange(last) {
                result[result.count - 1] = NSUnionRange(last, range)
            } else {
                result.append(range)
            }
        }
        return result
    }

    /// Draws a glyph range through the motion: moved stretches at their
    /// offset, appearing markers faded, the rest as laid out.
    func drawThroughMotion(_ glyphsToShow: NSRange, at origin: NSPoint, draw: (NSRange, NSPoint) -> Void) {
        guard let motion = revealMotion else { return draw(glyphsToShow, origin) }
        let progress = motion.progress()
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for segment in motion.segments where NSMaxRange(segment.glyphs) > cursor {
            guard segment.glyphs.location < end else { break }
            if segment.glyphs.location > cursor {
                draw(NSRange(location: cursor, length: segment.glyphs.location - cursor), origin)
                cursor = segment.glyphs.location
            }
            let piece = NSRange(location: cursor, length: min(end, NSMaxRange(segment.glyphs)) - cursor)
            if segment.fadesIn {
                drawFaded(alpha: progress) { draw(piece, origin) }
            } else if segment.changesLine {
                let old = NSPoint(x: origin.x + segment.offset.dx, y: origin.y + segment.offset.dy)
                drawFaded(alpha: 1 - progress) { draw(piece, old) }
                drawFaded(alpha: progress) { draw(piece, origin) }
            } else {
                let shift = motion.offset(forGlyph: piece.location, progress: progress)
                draw(piece, NSPoint(x: origin.x + shift.dx, y: origin.y + shift.dy))
            }
            cursor = NSMaxRange(piece)
        }
        if cursor < end { draw(NSRange(location: cursor, length: end - cursor), origin) }
    }

    private func drawFaded(alpha: CGFloat, _ draw: () -> Void) {
        guard alpha > 0.01 else { return }
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        context?.setAlpha(alpha)
        draw()
        context?.restoreGState()
    }

    /// Backgrounds move only with whole lines sliding below a reveal; within
    /// a revealed line the decoration stays put under its sliding words.
    func drawBackgroundThroughMotion(_ glyphsToShow: NSRange, at origin: NSPoint, draw: (NSRange, NSPoint) -> Void) {
        guard let motion = revealMotion else { return draw(glyphsToShow, origin) }
        let progress = motion.progress()
        var cursor = glyphsToShow.location
        let end = NSMaxRange(glyphsToShow)
        for segment in motion.segments where segment.isWholeLines && NSMaxRange(segment.glyphs) > cursor {
            guard segment.glyphs.location < end else { break }
            if segment.glyphs.location > cursor {
                draw(NSRange(location: cursor, length: segment.glyphs.location - cursor), origin)
                cursor = segment.glyphs.location
            }
            let piece = NSRange(location: cursor, length: min(end, NSMaxRange(segment.glyphs)) - cursor)
            draw(piece, NSPoint(x: origin.x, y: origin.y + segment.offset.dy * (1 - progress)))
            cursor = NSMaxRange(piece)
        }
        if cursor < end { draw(NSRange(location: cursor, length: end - cursor), origin) }
    }
}

/// Redraws the text view every frame while a reveal motion plays.
@MainActor
final class RevealTicker: NSObject {
    private weak var textView: NSTextView?
    private var link: CADisplayLink?

    init(textView: NSTextView) {
        self.textView = textView
    }

    func start() {
        guard link == nil, let textView else { return }
        let link = textView.displayLink(target: self, selector: #selector(tick))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick() {
        guard let textView, let manager = textView.layoutManager as? MarkdownLayoutManager else { return stop() }
        if manager.revealMotion?.isFinished ?? true {
            manager.revealMotion = nil
            stop()
        }
        textView.setNeedsDisplay(textView.visibleRect)
    }
}
