import Foundation
import Testing
@testable import MarkdownKit

@Suite("LineIndex")
struct LineIndexTests {
    @Test("Line starts and ranges")
    func basics() {
        let text = "one\ntwo\n\nfour" as NSString
        let index = LineIndex(text: text)
        #expect(index.starts == [0, 4, 8, 9])
        #expect(index.range(ofLine: 0) == NSRange(location: 0, length: 4))
        #expect(index.contentRange(ofLine: 0, in: text) == NSRange(location: 0, length: 3))
        #expect(index.contentRange(ofLine: 2, in: text) == NSRange(location: 8, length: 0))
        #expect(index.range(ofLine: 3) == NSRange(location: 9, length: 4))
        #expect(index.line(at: 0) == 0)
        #expect(index.line(at: 3) == 0)
        #expect(index.line(at: 4) == 1)
        #expect(index.line(at: 12) == 3)
    }

    @Test("Trailing newline makes a final empty line")
    func trailingNewline() {
        let text = "a\n" as NSString
        let index = LineIndex(text: text)
        #expect(index.starts == [0, 2])
        #expect(index.count == 2)
        #expect(index.range(ofLine: 1) == NSRange(location: 2, length: 0))
    }

    /// The property that matters: after any edit, the incrementally updated
    /// index must equal one built from scratch.
    @Test("Incremental update matches a full rebuild")
    func incrementalMatchesFullRebuild() {
        var generator = SystemRandomNumberGenerator()
        let fragments = ["a", "\n", "hello", "\n\n", "# head\n", "", "x\ny\nz", "  "]

        for _ in 0..<400 {
            var text = "# title\n\nsome *body* text\n\n- one\n- two\n"
            var index = LineIndex(text: text as NSString)

            for _ in 0..<6 {
                let ns = text as NSString
                let location = Int.random(in: 0...ns.length, using: &generator)
                let maxLength = min(5, ns.length - location)
                let length = maxLength > 0 ? Int.random(in: 0...maxLength, using: &generator) : 0
                let replacement = fragments.randomElement(using: &generator)!
                let editedRange = NSRange(location: location, length: replacement.utf16.count)
                let delta = replacement.utf16.count - length

                let updated = ns.replacingCharacters(in: NSRange(location: location, length: length), with: replacement)
                text = updated
                index.update(editedRange: editedRange, changeInLength: delta, text: text as NSString)

                let fresh = LineIndex(text: text as NSString)
                #expect(index.starts == fresh.starts, "text: \(text.debugDescription)")
                #expect(index.length == fresh.length)
            }
        }
    }
}
