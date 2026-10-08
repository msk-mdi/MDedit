import AppKit
import MarkdownKit

/// The text storage that makes the editor WYSIWYG: every edit reparses the
/// lines it touched and restyles exactly those.
final class MarkdownTextStorage: NSTextStorage {
    private let backing = NSMutableAttributedString()
    private(set) var structure: BlockStructure
    /// The document's link and footnote definitions, so `[label]` links resolve.
    private(set) var references = LinkReferences.lenient
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

    /// Shows the markdown as written: every marker visible, one monospaced
    /// font, no image previews. Colours still mark the structure.
    var sourceMode = false {
        didSet { if sourceMode != oldValue { restyleAll() } }
    }

    /// The document's location, for resolving relative image paths.
    var baseURL: URL? {
        didSet { if baseURL != oldValue, !requestedImages.isEmpty { restyleAll() } }
    }

    /// Images are scaled down to fit the text column.
    var maxImageWidth: CGFloat = Metrics.defaultLineWidth {
        didSet { if abs(maxImageWidth - oldValue) > 1, !requestedImages.isEmpty { restyleAll() } }
    }

    /// Which extended syntax to recognise; changing it reparses everything.
    var extensions: SyntaxExtensions = .all {
        didSet {
            guard extensions != oldValue else { return }
            structure = BlockStructure(text: backing.string as NSString, extensions: extensions)
            references = .collect(from: structure, requireDefinitions: false, extensions: extensions)
            headingNumberCache = nil
            restyleAll()
        }
    }

    /// Outline numbers drawn beside headings.
    var numberHeadings = false {
        didSet {
            guard numberHeadings != oldValue else { return }
            for manager in layoutManagers {
                manager.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: length))
            }
        }
    }

    private var headingNumberCache: [Int: String]?

    /// The outline number of the heading on a line, if it is one.
    func headingNumber(forLine line: Int) -> String? {
        if headingNumberCache == nil {
            let headings = structure.headings(in: backing.string as NSString)
            headingNumberCache = Dictionary(
                zip(headings.map(\.line), HeadingNumberer.numbers(for: headings)),
                uniquingKeysWith: { first, _ in first }
            )
        }
        return headingNumberCache?[line]
    }

    /// Images this document has asked the cache for, so it knows which
    /// arrivals are its own.
    private var requestedImages: Set<URL> = []

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
        // Posted on the main thread, where all styling happens.
        NotificationCenter.default.addObserver(self, selector: #selector(imageDidLoad(_:)), name: ImageCache.didLoad, object: nil)
        if !text.isEmpty {
            backing.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            structure = BlockStructure(text: backing.string as NSString)
            references = .collect(from: structure, requireDefinitions: false)
            applyStyles(lineRange: 0...max(0, structure.lineCount - 1))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func imageDidLoad(_ notification: Notification) {
        guard let url = notification.object as? URL, requestedImages.contains(url) else { return }
        restyleAll()
    }

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

    /// Font fixing swaps Apple Color Emoji off a shortcode's closing colon,
    /// since that font has no colon glyph; the emoji drawn there needs it back.
    override func fixAttributes(in range: NSRange) {
        super.fixAttributes(in: range)
        backing.enumerateAttribute(.mdEmoji, in: range) { value, emojiRange, _ in
            guard value != nil,
                  let size = (backing.attribute(.font, at: emojiRange.location, effectiveRange: nil) as? NSFont)?.pointSize,
                  let emojiFont = NSFont(name: "AppleColorEmoji", size: size)
            else { return }
            backing.addAttribute(.font, value: emojiFont, range: emojiRange)
        }
    }

    override func processEditing() {
        isProcessingEdit = true
        if editedMask.contains(.editedCharacters) {
            let text = backing.string as NSString
            let updated = structure.update(
                text: text,
                editedRange: editedRange,
                changeInLength: changeInLength
            )
            references = .collect(from: structure, requireDefinitions: false, extensions: extensions)
            headingNumberCache = nil
            // The line above takes its spacing from whether this one is blank.
            let lineRange = max(0, updated.lowerBound - 1)...updated.upperBound
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
        let revealed = sourceMode || (revealedLines?.contains(line) ?? false)

        // A paragraph underlined by `===` is really a heading.
        var headingLevel: Int?
        if case let .atxHeading(level) = info.kind {
            headingLevel = level
        } else if info.kind == .paragraph,
                  case let .setextUnderline(level)? = structure.info(forLine: line + 1)?.kind {
            headingLevel = level
        }

        let isCode = info.kind.isCode
        // Tables are monospaced, so aligned source reads as a grid; the header is bold.
        let isTableHeader = info.kind == .paragraph
            && isTableDelimiter(structure.info(forLine: line + 1)?.kind ?? .blank)
        let isTableLine = info.kind == .tableRow || isTableDelimiter(info.kind) || isTableHeader
        let baseFont: NSFont = if isTableHeader {
            NSFontManager.shared.convert(theme.mono, toHaveTrait: .boldFontMask)
        } else if isTableLine {
            theme.mono
        } else if sourceMode {
            headingLevel != nil ? NSFontManager.shared.convert(theme.mono, toHaveTrait: .boldFontMask) : theme.mono
        } else if let headingLevel {
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
        // Space after a block goes on its last line: the one before a blank.
        let endsBlock = !isCode && info.kind != .blank && structure.info(forLine: line + 1)?.kind == .blank

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
                endsBlock: endsBlock,
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
        switch info.kind {
        case .thematicBreak:
            attributes[.mdThematicBreak] = true
            attributes[.foregroundColor] = theme.rule
        case .htmlBlock:
            attributes[.font] = theme.mono
            attributes[.foregroundColor] = theme.syntax.tag
        case .linkReferenceDefinition:
            // Definitions are bookkeeping, not prose: present but quiet.
            attributes[.foregroundColor] = theme.secondaryText
        case .frontMatter, .frontMatterDelimiter:
            attributes[.foregroundColor] = theme.secondaryText
        default:
            break
        }
        if isTableLine {
            attributes[.mdTableRow] = true
            if isTableHeader { attributes[.foregroundColor] = theme.heading }
            // The delimiter row is hidden off the caret's line; a rule stands in for it.
            if isTableDelimiter(info.kind), !revealed,
               let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
                attributes[.mdThematicBreak] = true
                // Just tall enough for the rule, rather than a blank line.
                let thin = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
                thin.lineHeightMultiple = 0
                thin.minimumLineHeight = Metrics.tableRuleHeight
                thin.maximumLineHeight = Metrics.tableRuleHeight
                attributes[.paragraphStyle] = thin
            }
        }

        // A line holding nothing but an image shows the image above it, in a
        // line made tall enough for both; the alt text becomes a caption.
        // (`paragraphSpacingBefore` would be simpler, but TextKit 1 drops it
        // when a paragraph's first glyphs are concealed, as `![` is.)
        let nodes = info.kind.hasInlineContent && info.contentStart < characters.count
            ? InlineParser.parse(characters, from: info.contentStart, to: characters.count, references: references)
            : []
        let inlineImage = !sourceMode && info.kind == .paragraph && headingLevel == nil && !isTableHeader
            ? soleImage(in: nodes, characters: characters)
            : nil
        if let inlineImage, let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
            let spaced = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            let captionHeight = NSLayoutManager().defaultLineHeight(for: captionFont) * max(1, spaced.lineHeightMultiple)
            spaced.minimumLineHeight = inlineImage.size.height + Metrics.imageSpacing * 2 + captionHeight
            attributes[.paragraphStyle] = spaced
            attributes[.mdImage] = inlineImage
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
        if !nodes.isEmpty {
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

        // Pipes are scaffolding: drawn faintly so the cells read first.
        // Concealing markup inside a cell would pull its row's pipes out of
        // line, so in tables hidden markers keep their width and turn invisible.
        if isTableLine, !isTableDelimiter(info.kind) {
            backing.enumerateAttribute(.mdConcealed, in: range) { value, concealed, _ in
                guard value != nil else { return }
                backing.removeAttribute(.mdConcealed, range: concealed)
                backing.addAttribute(.foregroundColor, value: NSColor.clear, range: concealed)
            }
        }

        if isTableLine, !isTableDelimiter(info.kind) {
            var escaped = false
            for (offset, unit) in characters.enumerated() {
                if escaped {
                    escaped = false
                } else if unit == 0x5C /* backslash */ {
                    escaped = true
                } else if unit == 0x7C /* pipe */ {
                    backing.addAttribute(.foregroundColor, value: theme.rule, range: NSRange(location: range.location + offset, length: 1))
                }
            }
        }

        if inlineImage != nil {
            let caption = NSRange(location: range.location + info.contentStart, length: characters.count - info.contentStart)
            backing.addAttributes([.foregroundColor: theme.secondaryText, .font: captionFont], range: caption)
        }
    }

    private var captionFont: NSFont {
        NSFontManager.shared.convert(theme.body, toSize: theme.bodyFontSize * 0.85)
    }

    /// The image, sized to fit, when a line's only content is one image that
    /// has loaded. Starts the load otherwise.
    private func soleImage(in nodes: [InlineNode], characters: [UInt16]) -> InlineImage? {
        var source: String?
        for node in nodes {
            switch node {
            case let .image(_, _, imageSource, _, _) where source == nil:
                source = imageSource
            case let .text(range):
                let text = (String(utf16CodeUnits: Array(characters[range.location..<NSMaxRange(range)]), count: range.length))
                guard text.allSatisfy(\.isWhitespace) else { return nil }
            default:
                return nil
            }
        }
        guard let source, let url = imageURL(for: source) else { return nil }
        requestedImages.insert(url)
        guard let image = MainActor.assumeIsolated({ ImageCache.shared.image(for: url) }) else { return nil }

        var size = image.size
        let maxWidth = max(80, maxImageWidth)
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        if size.height > Metrics.maxImageHeight {
            size = CGSize(width: size.width * Metrics.maxImageHeight / size.height, height: Metrics.maxImageHeight)
        }
        return InlineImage(image: image, size: size)
    }

    /// Web and file URLs as written; other paths relative to the document.
    private func imageURL(for source: String) -> URL? {
        guard !source.isEmpty else { return nil }
        if let url = URL(string: source), let scheme = url.scheme?.lowercased() {
            return ["http", "https", "file"].contains(scheme) ? url : nil
        }
        let path = ((source.removingPercentEncoding ?? source) as NSString).expandingTildeInPath
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        guard let baseURL else { return nil }
        return URL(fileURLWithPath: path, relativeTo: baseURL.deletingLastPathComponent()).standardizedFileURL
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

            case .highlight:
                backing.addAttribute(.backgroundColor, value: theme.highlight, range: absolute)

            case let .math(_, _, content, _):
                // TeX stays as written, set apart in the code face.
                backing.addAttributes([
                    .font: theme.mono,
                    .foregroundColor: theme.syntax.function,
                ], range: NSRange(location: lineStart + content.location, length: content.length))

            case .superscript, .subscript:
                let isSuper = if case .superscript = node { true } else { false }
                backing.addAttributes([
                    .font: NSFontManager.shared.convert(childStyle.font(base: baseFont), toSize: baseFont.pointSize * 0.75),
                    .baselineOffset: baseFont.pointSize * (isSuper ? 0.35 : -0.15),
                ], range: absolute)

            case let .emoji(_, _, _, emoji):
                // The closing colon is drawn as the emoji; the rest is concealed.
                if !revealed, let emojiFont = NSFont(name: "AppleColorEmoji", size: baseFont.pointSize) {
                    backing.addAttributes([
                        .font: emojiFont,
                        .mdEmoji: emoji,
                    ], range: NSRange(location: NSMaxRange(absolute) - 1, length: 1))
                }

            case .footnoteReference:
                // A small raised label, like the superscript it exports as.
                let size = baseFont.pointSize * 0.75
                backing.addAttributes([
                    .font: NSFontManager.shared.convert(baseFont, toSize: size),
                    .baselineOffset: baseFont.pointSize * 0.35,
                    .foregroundColor: theme.accent,
                ], range: absolute)

            case let .link(_, _, destination, _, _):
                backing.addAttributes([
                    .foregroundColor: theme.link,
                    .mdLink: destination,
                    .toolTip: linkToolTip(destination),
                ], range: absolute)

            case let .image(_, _, source, _, _):
                backing.addAttributes([
                    .foregroundColor: theme.link,
                    .mdLink: source,
                    .toolTip: linkToolTip(source),
                ], range: absolute)

            case let .autolink(_, _, url):
                backing.addAttributes([
                    .foregroundColor: theme.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .mdLink: url,
                    .toolTip: linkToolTip(url),
                ], range: absolute)

            case .escape, .rawHTML, .entity, .lineBreak:
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

    private func linkToolTip(_ destination: String) -> String {
        destination.isEmpty ? "Undefined reference" : "\(destination)\n⌘-click to open"
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
        case .label:
            attributes[.foregroundColor] = theme.accent
            attributes[.font] = baseFont
        case .taskChecked, .taskUnchecked:
            attributes[.foregroundColor] = marker.kind == .taskChecked ? theme.accent : theme.secondaryText
            attributes[.font] = baseFont
        case .quote, .conceal:
            // Hidden unless the caret is on this line, which is the whole point.
            if !revealed { attributes[.mdConcealed] = true }
        }
        // Source mode keeps markers as typed: no bullets, boxes or clicks.
        if sourceMode { attributes[.mdMarker] = nil }
        backing.addAttributes(attributes, range: range)
    }
}
