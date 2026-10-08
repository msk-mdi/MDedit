import AppKit
import MarkdownKit

/// The editor's text view: adds clickable task boxes and Command-click links
/// on top of `NSTextView`'s own mouse handling.
final class MarkdownTextView: NSTextView {
    /// Asked to follow a link's destination exactly as written in the markdown.
    var onOpenLink: ((String) -> Void)?

    override func mouseDown(with event: NSEvent) {
        guard let index = characterIndex(under: event) else {
            return super.mouseDown(with: event)
        }
        if event.modifierFlags.contains(.command),
           let destination = textStorage?.attribute(.mdLink, at: index, effectiveRange: nil) as? String {
            if destination.isEmpty {
                NSSound.beep()  // a reference whose definition is missing
            } else {
                onOpenLink?(destination)
            }
            return
        }
        if toggleTaskBox(at: index) { return }
        super.mouseDown(with: event)
    }

    /// The pointing hand over links while Command is held, so they look clickable.
    override func mouseMoved(with event: NSEvent) {
        if event.modifierFlags.contains(.command),
           let index = characterIndex(under: event),
           textStorage?.attribute(.mdLink, at: index, effectiveRange: nil) != nil {
            NSCursor.pointingHand.set()
            return
        }
        super.mouseMoved(with: event)
    }

    /// The character whose glyph is actually under the pointer, not merely
    /// the nearest one, so clicks in empty space keep their usual meaning.
    private func characterIndex(under event: NSEvent) -> Int? {
        guard let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        guard glyph < layoutManager.numberOfGlyphs else { return nil }
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        // A little slack makes the small checkbox easier to hit.
        guard bounds.insetBy(dx: -3, dy: -2).contains(containerPoint) else { return nil }
        let index = layoutManager.characterIndexForGlyph(at: glyph)
        return index < storage.length ? index : nil
    }

    /// Flips `[ ]` and `[x]` as one undoable edit, leaving the caret alone.
    func toggleTaskBox(at index: Int) -> Bool {
        guard let storage = textStorage,
              let raw = storage.attribute(.mdMarker, at: index, effectiveRange: nil) as? Int,
              let kind = MarkerKind(rawValue: raw),
              kind == .taskChecked || kind == .taskUnchecked
        else { return false }

        let range = NSRange(location: index, length: 1)
        let replacement = kind == .taskChecked ? " " : "x"
        guard shouldChangeText(in: range, replacementString: replacement) else { return true }
        let selection = selectedRanges
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        undoManager?.setActionName(kind == .taskChecked ? "Uncheck Task" : "Check Task")
        selectedRanges = selection
        return true
    }
}
