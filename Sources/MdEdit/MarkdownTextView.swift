import AppKit
import MarkdownKit

/// The editor's text view: adds clickable task boxes and Command-click links
/// on top of `NSTextView`'s own mouse handling.
final class MarkdownTextView: NSTextView {
    /// Asked to follow a link's destination exactly as written in the markdown.
    var onOpenLink: ((String) -> Void)?
    /// The document's file, for placing and linking pasted images.
    var documentURL: () -> URL? = { nil }
    /// Asked to open markdown files dropped onto the text.
    var onOpenFiles: (([URL]) -> Void)?

    // MARK: - Paste and drop

    /// Images paste as markdown; a URL pasted over a selection makes a link.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if insertImages(from: pasteboard, at: selectedRange()) { return }
        if pasteLinkOverSelection(from: pasteboard) { return }
        super.paste(sender)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        // Markdown files dropped in open as tabs rather than pasting their paths.
        let files = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        let markdown = files.filter(Workspace.isMarkdown)
        if !markdown.isEmpty, markdown.count == files.count {
            onOpenFiles?(markdown)
            return true
        }
        let point = convert(sender.draggingLocation, from: nil)
        let location = characterIndexForInsertion(at: point)
        if insertImages(from: sender.draggingPasteboard, at: NSRange(location: location, length: 0)) {
            window?.makeFirstResponder(self)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func insertImages(from pasteboard: NSPasteboard, at range: NSRange) -> Bool {
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
            .filter(ImageImporter.isImageFile)
        var markdown: [String] = []
        if !files.isEmpty {
            markdown = files.map { ImageImporter.markdown(forImageAt: $0, documentURL: documentURL()) }
        } else if pasteboard.string(forType: .string) == nil,
                  let image = NSImage(pasteboard: pasteboard) {
            // Raw image data, as from a screenshot: it needs a file of its own.
            do {
                let saved = try ImageImporter.save(image, besideDocument: documentURL())
                markdown = [ImageImporter.markdown(forImageAt: saved, documentURL: documentURL())]
            } catch {
                if let window { NSAlert(error: error).beginSheetModal(for: window) }
                return true
            }
        }
        guard !markdown.isEmpty else { return false }

        let insertion = markdown.joined(separator: "\n")
        guard shouldChangeText(in: range, replacementString: insertion) else { return true }
        insertText(insertion, replacementRange: range)
        return true
    }

    private func pasteLinkOverSelection(from pasteboard: NSPasteboard) -> Bool {
        let selection = selectedRange()
        guard selection.length > 0,
              let pasted = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pasted.contains(where: \.isWhitespace),
              let url = URL(string: pasted), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme),
              let storage = textStorage
        else { return false }
        let selected = (storage.string as NSString).substring(with: selection)
        guard !selected.contains("\n") else { return false }
        let link = "[\(selected)](\(pasted))"
        guard shouldChangeText(in: selection, replacementString: link) else { return true }
        insertText(link, replacementRange: selection)
        return true
    }

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
