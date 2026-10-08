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

    /// Insertion points besides the selection, for typing in several places.
    var additionalCarets: [Int] = [] {
        didSet { if additionalCarets != oldValue { needsDisplay = true } }
    }
    /// Set while an edit at several places runs, so the selection it leaves
    /// behind does not clear the extra carets, and the delegate stays out.
    private(set) var isEditingAtCarets = false

    func setEditingAtCarets(_ editing: Bool) {
        isEditingAtCarets = editing
    }

    /// Set while a command replaces text, so the delegate does not take a
    /// one-character replacement for a typed delimiter.
    fileprivate(set) var isReplacingAsCommand = false

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isEditingAtCarets, !additionalCarets.isEmpty { additionalCarets = [] }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }

    // MARK: - Accessibility

    /// VoiceOver reads what is drawn: no hidden `**` or `#`, bullets as
    /// bullets, ticked boxes as "checked".
    override func accessibilityString(for range: NSRange) -> String? {
        guard let textStorage else { return super.accessibilityString(for: range) }
        return SpokenText.string(of: textStorage, in: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let textStorage else { return super.accessibilityAttributedString(for: range) }
        return SpokenText.attributedString(of: textStorage, in: range)
    }

    // MARK: - Paste and drop

    /// Images paste as markdown; a URL pasted over a selection makes a link.
    override func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if insertImages(from: pasteboard, at: selectedRange()) { return }
        if pasteLinkOverSelection(from: pasteboard) { return }
        if pasteHTMLAsMarkdown(from: pasteboard) { return }
        super.paste(sender)
    }

    /// Formatted text from a browser or document pastes as markdown. Inside a
    /// code block, and for HTML with no real formatting, the plain text wins.
    private func pasteHTMLAsMarkdown(from pasteboard: NSPasteboard) -> Bool {
        guard let html = pasteboard.string(forType: .html), !isInCodeBlock(),
              let markdown = HTMLToMarkdown.convert(html)
        else { return false }
        let range = selectedRange()
        if replaceAsUndoStep(range, with: markdown, actionName: String(localized: "Paste")) {
            setSelectedRange(NSRange(location: range.location + (markdown as NSString).length, length: 0))
        }
        return true
    }

    private func isInCodeBlock() -> Bool {
        guard let storage = textStorage as? MarkdownTextStorage else { return false }
        let line = storage.line(at: selectedRange().location)
        return storage.structure.info(forLine: line)?.kind.isCode ?? false
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
        if replaceAsUndoStep(range, with: insertion, actionName: String(localized: "Insert Image")) {
            setSelectedRange(NSRange(location: range.location + (insertion as NSString).length, length: 0))
        }
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
        if replaceAsUndoStep(selection, with: link, actionName: String(localized: "Paste Link")) {
            setSelectedRange(NSRange(location: selection.location + (link as NSString).length, length: 0))
        }
        return true
    }

    override func mouseDown(with event: NSEvent) {
        if unfoldIndicator(at: event) { return }
        // ⌥-click adds a caret; ⌥-drag still makes a column selection.
        if event.modifierFlags.contains(.option), !event.modifierFlags.contains(.command) {
            let before = editTargets
            super.mouseDown(with: event)
            if selectedRanges.count == 1, selectedRange().length == 0, before.allSatisfy({ $0.length == 0 }) {
                let caret = selectedRange().location
                additionalCarets = Array(Set(before.map(\.location)).subtracting([caret])).sorted()
            }
            return
        }
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

    /// A click on a folded heading's ⋯ chip unfolds it.
    private func unfoldIndicator(at event: NSEvent) -> Bool {
        guard let storage = textStorage as? MarkdownTextStorage, !storage.foldedHeadings.isEmpty,
              let layoutManager = layoutManager as? MarkdownLayoutManager
        else { return false }
        let point = convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for heading in storage.foldedHeadings {
            if let chip = layoutManager.foldIndicatorRect(forHeadingLine: heading), chip.insetBy(dx: -3, dy: -3).contains(containerPoint) {
                storage.setFolded(false, headingLine: heading)
                return true
            }
        }
        return false
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
        let selection = selectedRanges
        let name = kind == .taskChecked ? String(localized: "Uncheck Task") : String(localized: "Check Task")
        guard replaceAsUndoStep(range, with: replacement, actionName: name) else { return true }
        selectedRanges = selection
        return true
    }
}

extension NSTextView {
    /// Replaces text as an undo step of its own, under a name for the Edit
    /// menu: not folded into the typing before it, and not extended by the
    /// typing after. (`insertText` counts as typing, and coalesces.)
    @discardableResult
    func replaceAsUndoStep(_ range: NSRange, with replacement: String, actionName: String?) -> Bool {
        guard let textStorage else { return false }
        let markdownView = self as? MarkdownTextView
        markdownView?.isReplacingAsCommand = true
        defer { markdownView?.isReplacingAsCommand = false }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement) else { return false }
        textStorage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        breakUndoCoalescing()
        if let actionName { undoManager?.setActionName(actionName) }
        return true
    }
}
