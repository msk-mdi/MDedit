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

    init(storage: MarkdownTextStorage, textView: NSTextView) {
        self.storage = storage
        self.textView = textView
    }

    func selectionChanged() {
        guard let textView else { return }
        let selection = textView.selectedRange()
        let firstLine = storage.line(at: selection.location)
        let lastLine = selection.length > 0
            ? storage.line(at: NSMaxRange(selection))
            : firstLine

        storage.revealedLines = firstLine...lastLine

        if let manager = textView.layoutManager as? MarkdownLayoutManager {
            manager.focusRange = focusMode ? storage.characterRange(forLines: firstLine...lastLine) : nil
            if focusMode {
                manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: storage.length))
            }
        }

        if typewriterMode {
            centreCaret(animated: true)
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
