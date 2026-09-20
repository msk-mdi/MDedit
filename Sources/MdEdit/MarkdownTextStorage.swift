import AppKit
import MarkdownKit

/// The text storage that makes the editor WYSIWYG: every edit reparses the
/// lines it touched and restyles exactly those.
final class MarkdownTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    private(set) var structure: BlockStructure
    private var styles = ParagraphStyleCache()

    /// Range of lines whose markers are revealed because the caret is in them.
    var revealedLines: ClosedRange<Int>? {
        didSet {
            guard revealedLines != oldValue else { return }
            // Moving the caret is how AppKit responds to an edit, so this can
            // fire from inside `processEditing`. Editing attributes re-entrantly
            // there is not allowed, so it waits until the edit has finished.
            if isProcessingEdit {
                if !hasDeferredReveal {
                    deferredRevealOld = oldValue
                    hasDeferredReveal = true
                }
                return
            }
            restyleRevealChange(from: oldValue, to: revealedLines)
        }
    }

    private var isProcessingEdit = false
    private var hasDeferredReveal = false
    private var deferredRevealOld: ClosedRange<Int>?

    var theme: Theme {
        didSet {
            styles.removeAll()
            restyleAll()
        }
    }

    init(theme: Theme, text: String = "") {
        self.theme = theme
        structure = BlockStructure(text: text as NSString)
        super.init()
        if !text.isEmpty {
            backing.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            structure = BlockStructure(text: backing.string as NSString)
            applyStyles(lineRange: 0...max(0, structure.lineCount - 1))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) is not used")
    }

    // MARK: - NSTextStorage

    override var string: String { backing.string }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        guard backing.length > 0 else { return [:] }
        return backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        backing.replaceCharacters(in: range, with: str)
        edited(.editedCharacters, range: range, changeInLength: (str as NSString).length - range.length)
        endEditing()
    }

    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        beginEditing()
        backing.setAttributes(attrs, range: range)
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
    }

    override func processEditing() {
        isProcessingEdit = true
        if editedMask.contains(.editedCharacters) {
            let text = backing.string as NSString
            let lineRange = structure.update(
                text: text,
                editedRange: editedRange,
                changeInLength: changeInLength
            )
            applyStyles(lineRange: lineRange)
            pendingInvalidation = characterRange(forLines: lineRange)
        }
        super.processEditing()
        isProcessingEdit = false
        flushPendingInvalidation()

        if hasDeferredReveal {
            hasDeferredReveal = false
            let old = deferredRevealOld
            deferredRevealOld = nil
            restyleRevealChange(from: old, to: revealedLines)
        }
    }

    /// Restyling can reach past the edited range — opening a fence restyles
    /// everything below it — so the layout managers are told separately.
    private var pendingInvalidation: NSRange?

    private func flushPendingInvalidation() {
        guard let range = pendingInvalidation else { return }
        pendingInvalidation = nil
        for manager in layoutManagers {
            manager.invalidateGlyphs(forCharacterRange: range, changeInLength: 0, actualCharacterRange: nil)
            manager.invalidateLayout(forCharacterRange: range, actualCharacterRange: nil)
            manager.invalidateDisplay(forCharacterRange: range)
        }
    }

    // MARK: - Styling

    func restyleAll() {
        guard structure.lineCount > 0 else { return }
        beginEditing()
        applyStyles(lineRange: 0...(structure.lineCount - 1))
        edited(.editedAttributes, range: NSRange(location: 0, length: backing.length), changeInLength: 0)
        endEditing()
    }

    func line(at location: Int) -> Int {
        structure.index.line(at: min(max(0, location), backing.length))
    }

    func characterRange(forLines lines: ClosedRange<Int>) -> NSRange {
        let lower = min(lines.lowerBound, structure.lineCount - 1)
        let upper = min(lines.upperBound, structure.lineCount - 1)
        guard lower >= 0, upper >= lower else { return NSRange(location: 0, length: 0) }
        let start = structure.index.range(ofLine: lower).location
        let end = NSMaxRange(structure.index.range(ofLine: upper))
        return NSRange(location: start, length: end - start)
    }

    /// Clamps a line range to the document as it stands now.
    ///
    /// The range being clamped is often stale — the caret's previous line after
    /// the document shrank under it — so the bounds must be ordered *before* a
    /// `ClosedRange` is formed: `5...2` traps at construction, it does not
    /// produce an empty range.
    func clampedLineRange(_ range: ClosedRange<Int>) -> ClosedRange<Int>? {
        let last = structure.lineCount - 1
        guard last >= 0 else { return nil }
        let lower = min(max(0, range.lowerBound), last)
        let upper = min(max(range.upperBound, lower), last)
        return lower...upper
    }

    /// Reveals the newly active block and re-hides the one left behind.
    private func restyleRevealChange(from old: ClosedRange<Int>?, to new: ClosedRange<Int>?) {
        let touched = [old, new].compactMap { $0 }.compactMap(clampedLineRange)
        guard !touched.isEmpty else { return }

        beginEditing()
        for range in touched {
            applyStyles(lineRange: range)
            edited(.editedAttributes, range: characterRange(forLines: range), changeInLength: 0)
        }
        endEditing()

        for range in touched {
            pendingInvalidation = characterRange(forLines: range)
            flushPendingInvalidation()
        }
    }

    private func applyStyles(lineRange: ClosedRange<Int>) {
        let text = backing.string as NSString
        let lower = max(0, lineRange.lowerBound)
        let upper = min(lineRange.upperBound, structure.lineCount - 1)
        guard lower <= upper else { return }

        for line in lower...upper {
            guard let info = structure.info(forLine: line) else { continue }
            let lineRange = structure.index.range(ofLine: line)
            guard lineRange.length > 0 || lineRange.location < text.length else { continue }
            style(line: line, info: info, range: lineRange, text: text)
        }
    }

    private func style(line: Int, info: LineInfo, range: NSRange, text: NSString) {
        let characters = structure.characters(of: text, line: line)
        let revealed = revealedLines?.contains(line) ?? false

        // A paragraph underlined by `===` is really a heading.
        var headingLevel: Int?
        if case let .atxHeading(level) = info.kind {
            headingLevel = level
        } else if info.kind == .paragraph,
                  case let .setextUnderline(level)? = structure.info(forLine: line + 1)?.kind {
            headingLevel = level
        }

        let isCode = info.kind.isCode
        let baseFont: NSFont = if let headingLevel {
            theme.headingFont(level: headingLevel)
        } else if isCode {
            theme.mono
        } else {
            theme.body
        }

        let hangingIndent: CGFloat = switch info.kind {
        case .listItem: theme.bodyFontSize * 1.4
        default: 0
        }
        let isListItem = if case .listItem = info.kind { true } else { false }

        var attributes: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: headingLevel != nil ? theme.heading : theme.text,
            .paragraphStyle: styles.style(
                listDepth: info.listDepth,
                quoteDepth: info.quoteDepth,
                isCode: isCode,
                isHeading: headingLevel != nil,
                isListItem: isListItem,
                hangingIndent: hangingIndent,
                theme: theme
            ),
        ]
        if isCode {
            attributes[.foregroundColor] = theme.codeText
            attributes[.mdCodeBlock] = true
        }
        if info.quoteDepth > 0 {
            attributes[.foregroundColor] = headingLevel != nil ? theme.heading : theme.quoteText
            attributes[.mdQuoteDepth] = info.quoteDepth
        }
        if info.kind == .thematicBreak {
            attributes[.mdThematicBreak] = true
            attributes[.foregroundColor] = theme.rule
        }
        let isTableHeader = info.kind == .paragraph
            && isTableDelimiter(structure.info(forLine: line + 1)?.kind ?? .blank)
        if info.kind == .tableRow || isTableDelimiter(info.kind) || isTableHeader {
            attributes[.mdTableRow] = true
            attributes[.font] = theme.mono
        }

        backing.setAttributes(attributes, range: range)

        // Syntax colouring for fenced code, from tokens the parser produced.
        for token in info.tokens {
            let tokenRange = NSRange(location: range.location + token.range.location, length: token.range.length)
            guard tokenRange.length > 0, NSMaxRange(tokenRange) <= backing.length else { continue }
            var tokenAttributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: theme.syntax.color(for: token.kind),
            ]
            if token.kind == .comment {
                tokenAttributes[.font] = NSFontManager.shared.convert(theme.mono, toHaveTrait: .italicFontMask)
            }
            backing.addAttributes(tokenAttributes, range: tokenRange)
        }

        // Inline markup, then markers on top of it.
        if info.kind.hasInlineContent, info.contentStart < characters.count {
            let nodes = InlineParser.parse(characters, from: info.contentStart, to: characters.count)
            applyInline(
                nodes,
                characters: characters,
                lineStart: range.location,
                baseFont: baseFont,
                style: InlineStyle(),
                revealed: revealed
            )
        }

        for marker in info.markers {
            applyMarker(marker, lineStart: range.location, revealed: revealed, baseFont: baseFont)
        }
    }

    private func isTableDelimiter(_ kind: BlockKind) -> Bool {
        if case .tableDelimiter = kind { return true }
        return false
    }

    private func applyInline(
        _ nodes: [InlineNode],
        characters: [UInt16],
        lineStart: Int,
        baseFont: NSFont,
        style: InlineStyle,
        revealed: Bool
    ) {
        for node in nodes {
            let absolute = NSRange(location: lineStart + node.range.location, length: node.range.length)
            var childStyle = style

            switch node {
            case .text:
                continue

            case let .code(_, content, _):
                let contentRange = NSRange(location: lineStart + content.location, length: content.length)
                backing.addAttributes([
                    .font: theme.mono,
                    .foregroundColor: theme.codeText,
                    .mdInlineCode: true,
                ], range: contentRange)

            case .emphasis:
                childStyle.italic = true
                backing.addAttribute(.font, value: childStyle.font(base: baseFont), range: absolute)

            case .strong:
                childStyle.bold = true
                backing.addAttribute(.font, value: childStyle.font(base: baseFont), range: absolute)

            case .strikethrough:
                childStyle.strikethrough = true
                backing.addAttributes([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: theme.secondaryText,
                ], range: absolute)

            case let .link(_, _, destination, _, _):
                backing.addAttributes([
                    .foregroundColor: theme.link,
                    .mdLink: destination,
                ], range: absolute)

            case let .image(_, _, source, _):
                backing.addAttributes([
                    .foregroundColor: theme.link,
                    .mdLink: source,
                ], range: absolute)

            case let .autolink(_, _, url):
                backing.addAttributes([
                    .foregroundColor: theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .mdLink: url,
                ], range: absolute)

            case .escape, .rawHTML:
                break
            }

            applyInline(
                node.children,
                characters: characters,
                lineStart: lineStart,
                baseFont: baseFont,
                style: childStyle,
                revealed: revealed
            )

            for marker in node.markers {
                applyMarker(marker, lineStart: lineStart, revealed: revealed, baseFont: baseFont)
            }
        }
    }

    private func applyMarker(_ marker: Marker, lineStart: Int, revealed: Bool, baseFont: NSFont) {
        let range = NSRange(location: lineStart + marker.range.location, length: marker.range.length)
        guard range.length > 0, NSMaxRange(range) <= backing.length else { return }

        var attributes: [NSAttributedString.Key: Any] = [
            .mdMarker: marker.kind.rawValue,
            .foregroundColor: theme.marker,
        ]
        switch marker.kind {
        case .listBullet, .listNumber:
            // Bullets and numbers stay visible; the bullet character itself is
            // swapped for `•` at glyph generation.
            attributes[.foregroundColor] = theme.accent
            attributes[.font] = baseFont
        case .fence:
            attributes[.font] = theme.mono
            if !revealed { attributes[.mdConcealed] = true }
        case .taskChecked, .taskUnchecked:
            attributes[.foregroundColor] = marker.kind == .taskChecked ? theme.accent : theme.secondaryText
            attributes[.font] = baseFont
        case .quote, .conceal:
            // Hidden unless the caret is on this line, which is the whole point.
            if !revealed { attributes[.mdConcealed] = true }
        }
        backing.addAttributes(attributes, range: range)
    }
}
