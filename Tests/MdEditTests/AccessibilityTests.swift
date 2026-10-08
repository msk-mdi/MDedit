import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Accessibility")
struct AccessibilityTests {
    private func storage(_ markdown: String) -> MarkdownTextStorage {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: markdown)
        storage.revealedLines = nil
        return storage
    }

    private func spoken(_ storage: NSAttributedString) -> String {
        SpokenText.string(of: storage, in: NSRange(location: 0, length: storage.length))
    }

    @Test("Concealed markers are not read")
    func concealedMarkers() {
        let text = storage("# Title\n\nSome **bold** and `code` and [a link](https://example.com).\n")
        #expect(spoken(text) == "Title\n\nSome bold and code and a link.\n")
    }

    @Test("Bullets and task boxes read as drawn")
    func substitutions() {
        let text = storage("- one\n- [x] done\n- [ ] todo\n")
        let result = spoken(text)
        #expect(result.contains("• one"))
        #expect(result.contains("checked"))
        #expect(result.contains("unchecked"))
        #expect(!result.contains("[x]"))
        #expect(!result.contains("- "))
    }

    @Test("An emoji shortcode reads as its emoji")
    func emoji() {
        let text = storage("Nice :smile: work\n")
        #expect(spoken(text) == "Nice 😄 work\n")
    }

    @Test("The caret's line reads its markers, as they are shown")
    func revealedLine() {
        let text = storage("**bold**\n")
        text.revealedLines = 0...0
        #expect(spoken(text).contains("**bold**"))
    }

    @Test("A partial range reads only its part")
    func partialRange() {
        let text = storage("Some **bold** text\n")
        #expect(SpokenText.string(of: text, in: NSRange(location: 5, length: 8)) == "bold")
    }

    @Test("Links keep their destination for VoiceOver")
    func links() {
        let text = storage("[a link](https://example.com)\n")
        let attributed = SpokenText.attributedString(of: text, in: NSRange(location: 0, length: text.length))
        let link = attributed.attribute(.link, at: 0, effectiveRange: nil) as? URL
        #expect(link?.absoluteString == "https://example.com")
    }

    @Test("Tab segments are radio-button tabs with the title, dirty state and a close action")
    func tabSegments() {
        let segment = TabSegment(index: 0)
        segment.apply(TabDescriptor(title: "notes.md", isDirty: true), isSelected: true, theme: .light)
        #expect(segment.isAccessibilityElement())
        #expect(segment.accessibilityRole() == .radioButton)
        #expect(segment.accessibilityLabel() == "notes.md, edited")
        #expect(segment.isAccessibilitySelected())
        var closed = false
        segment.onClose = { _ in closed = true }
        let action = segment.accessibilityCustomActions()?.first
        #expect(action?.name == "Close Tab")
        _ = action?.handler?()
        #expect(closed)
    }
}
