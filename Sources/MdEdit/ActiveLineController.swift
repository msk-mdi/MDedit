import AppKit

/// Decides which block shows its raw markdown.
///
/// The caret's own line is revealed — that is how you edit syntax you can
/// otherwise no longer see — and everything else stays rendered. Typewriter and
/// focus modes hang off the same selection hook.
@MainActor
final class ActiveLineController {
    weak var textView: NSTextView?
    private let storage: MarkdownTextStorage

    var typewriterMode = false {
        didSet { if typewriterMode { centreCaret(animated: false) } }
    }

    var focusMode = false {
        didSet { selectionChanged() }
    }

    static let maxRevealedLines = 100
    /// The most characters, in the lines showing and hiding their markdown,
    /// whose move is animated.
    static let maxAnimatedCharacters = 20_000

    /// Redraws while the text glides into place after a reveal.
    private let ticker: RevealTicker

    init(storage: MarkdownTextStorage, textView: NSTextView) {
        self.storage = storage
        self.textView = textView
        ticker = RevealTicker(textView: textView)
    }

    func selectionChanged() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let firstLine = storage.line(at: selection.location)
        // A selection ending at the start of a line, as a triple-click's
        // does, does not reach into it: that line keeps its markdown hidden.
        let lastLine = storage.lastLine(of: selection)

        // The caret never sits in a fold: moving into one opens it.
        for line in [firstLine, lastLine] where storage.isHidden(line: line) {
            storage.reveal(line: line)
        }
        // Past a screenful, a selection is for copying, moving or deleting,
        // not for editing its syntax: only the line it ends on shows as
        // written, instead of every line in it restyling and reflowing.
        let revealed = lastLine - firstLine <= Self.maxRevealedLines ? firstLine...lastLine : lastLine...lastLine
        let lines = [storage.revealedLines, revealed].compactMap(\.self).map(storage.characterRange(forLines:))
        // The motion notes where every character of those lines sits, before
        // and after: for a line of a megabyte, an image written into the
        // page, each arrow key onto it or off it took a long moment. Lines
        // that long just change.
        let isShort = lines.reduce(0) { $0 + $1.length } <= Self.maxAnimatedCharacters
        if revealed != storage.revealedLines, isShort, shouldAnimate,
           let manager = textView.layoutManager as? MarkdownLayoutManager {
            // Markers appearing push words along, and a line that rewraps
            // moves the ones below; everything glides there instead.
            if manager.animateReveal(across: lines, change: { storage.revealedLines = revealed }) {
                ticker.start()
            }
        } else {
            storage.revealedLines = revealed
        }

        if let manager = textView.layoutManager as? MarkdownLayoutManager {
            let old = manager.focusRange
            let new = focusMode ? storage.characterRange(forLines: firstLine...lastLine) : nil
            manager.focusRange = new
            switch (old, new) {
            case let (old?, new?) where old != new:
                // Only the lines leaving and entering focus change how they are dimmed.
                for range in [old, new] {
                    let location = min(range.location, storage.length)
                    manager.invalidateDisplay(forCharacterRange: NSRange(location: location, length: min(range.length, storage.length - location)))
                }
            case (nil, _?), (_?, nil):
                manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
            default:
                break
            }
        }

        if typewriterMode {
            centreCaret(animated: true)
        }
    }

    /// Only a move the reader made, by clicking or with the arrow keys,
    /// animates: not typing a new line, and not each step of a drag selection.
    private var shouldAnimate: Bool {
        guard Motion.isEnabled, textView?.window?.isVisible == true, let event = NSApp.currentEvent else { return false }
        switch event.type {
        case .leftMouseDown, .leftMouseUp:
            return true
        case .keyDown:
            let navigation: [NSEvent.SpecialKey] = [.upArrow, .downArrow, .leftArrow, .rightArrow, .pageUp, .pageDown, .home, .end]
            return event.specialKey.map(navigation.contains) ?? false
        default:
            return false
        }
    }

    /// Keeps the caret's line vertically centred, the way a typewriter's platen
    /// keeps the writing line in place.
    private func centreCaret(animated: Bool) {
        guard let textView,
              let scrollView = textView.enclosingScrollView,
              let manager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        let selection = textView.selectedRange()
        let glyphRange = manager.glyphRange(forCharacterRange: selection, actualCharacterRange: nil)
        let caretRect = manager.boundingRect(forGlyphRange: glyphRange, in: container)
        let caretCentre = caretRect.midY + textView.textContainerInset.height

        let visible = scrollView.contentView.bounds
        var target = caretCentre - visible.height / 2
        let maximum = max(0, textView.bounds.height - visible.height)
        target = min(max(0, target), maximum)

        guard abs(target - visible.origin.y) > 1 else { return }
        let point = NSPoint(x: visible.origin.x, y: target)
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                scrollView.contentView.animator().setBoundsOrigin(point)
            }
            scrollView.reflectScrolledClipView(scrollView.contentView)
        } else {
            scrollView.contentView.setBoundsOrigin(point)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }
}
