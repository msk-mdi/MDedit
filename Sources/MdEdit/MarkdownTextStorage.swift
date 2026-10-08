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
        didSet {
            if abs(maxImageWidth - oldValue) > 1, !requestedImages.isEmpty || !requestedTypesetting.isEmpty { restyleAll() }
        }
    }

    /// Which extended syntax to recognise; changing it reparses everything.
    var extensions: SyntaxExtensions = .all {
        didSet {
            guard extensions != oldValue else { return }
            structure = BlockStructure(text: text, extensions: extensions)
            blockLookup = nil
            references = .collect(from: structure, requireDefinitions: false, extensions: extensions)
            headingNumberCache = nil
            cachedHeadings = nil
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
    private var cachedHeadings: [Heading]?

    /// Every heading, in order; kept until the structure next changes, since
    /// folds ask for it once per folded section on every edit.
    var headings: [Heading] {
        if let cachedHeadings { return cachedHeadings }
        let headings = structure.headings(in: text)
        cachedHeadings = headings
        return headings
    }

    // MARK: - Folding

    /// Heading lines whose sections are folded away.
    private(set) var foldedHeadings: Set<Int> = []
    /// Lines hidden by folds, worked out when folds or text change.
    private var hiddenLines: IndexSet = []

    /// The lines a heading's section covers below it: up to the next heading
    /// of the same or a higher level. Nil when the line is not a heading or
    /// its section is empty.
    func foldableRange(forHeadingLine line: Int) -> ClosedRange<Int>? {
        let headings = self.headings
        guard let index = headings.firstIndex(where: { $0.line == line }) else { return nil }
        let heading = headings[index]
        // A setext heading's underline stays with its title.
        let isSetext = structure.info(forLine: line).map { if case .atxHeading = $0.kind { false } else { true } } ?? false
        let first = line + (isSetext ? 2 : 1)
        let next = headings[(index + 1)...].first { $0.level <= heading.level }?.line ?? structure.lineCount
        var last = next - 1
        // The blank lines before the next heading stay, so it keeps its space.
        while last >= first, structure.info(forLine: last)?.kind == .blank { last -= 1 }
        return first <= last ? first...last : nil
    }

    /// The innermost heading whose section holds a line, or which is on it.
    func enclosingHeading(ofLine line: Int) -> Int? {
        let headings = self.headings
        for index in headings.indices.reversed() where headings[index].line <= line {
            let heading = headings[index]
            let next = headings[(index + 1)...].first { $0.level <= heading.level }?.line ?? structure.lineCount
            if line < next { return heading.line }
        }
        return nil
    }

    func isHidden(line: Int) -> Bool {
        hiddenLines.contains(line)
    }

    /// Folds or unfolds a heading's section. Returns false when there is
    /// nothing to fold.
    @discardableResult
    func setFolded(_ folded: Bool, headingLine line: Int) -> Bool {
        guard folded != foldedHeadings.contains(line) else { return true }
        guard let range = foldableRange(forHeadingLine: line) else { return false }
        if folded { foldedHeadings.insert(line) } else { foldedHeadings.remove(line) }
        refreshFolds(restyling: range)
        return true
    }

    func unfoldAll() {
        guard !foldedHeadings.isEmpty else { return }
        foldedHeadings.removeAll()
        let previous = hiddenLines
        hiddenLines = []
        if let first = previous.first, let last = previous.last { restyle(lines: max(0, first - 1)...last) }
    }

    /// Unfolds whatever hides a line, so the caret or a search match can land there.
    func reveal(line: Int) {
        guard hiddenLines.contains(line) else { return }
        for heading in foldedHeadings.sorted(by: >) {
            if let range = foldableRange(forHeadingLine: heading), range.contains(line) {
                setFolded(false, headingLine: heading)
            }
        }
    }

    private func refreshFolds(restyling range: ClosedRange<Int>?) {
        var hidden = IndexSet()
        for heading in foldedHeadings {
            if let section = foldableRange(forHeadingLine: heading) {
                hidden.insert(integersIn: section)
            }
        }
        hiddenLines = hidden
        if let range { restyle(lines: max(0, range.lowerBound - 1)...range.upperBound) }
    }

    /// Restyles lines and has the layout follow.
    private func restyle(lines: ClosedRange<Int>) {
        guard let lines = clampedLineRange(lines).map(expandedToTypesetBlocks) else { return }
        beginEditing()
        applyStyles(lineRange: lines)
        edited(.editedAttributes, range: characterRange(forLines: lines), changeInLength: 0)
        endEditing()
        pendingInvalidation = characterRange(forLines: lines)
        flushPendingInvalidation()
    }

    /// Where each fold sat before an edit, in characters: its heading's start
    /// and the end of its section.
    private func foldExtents() -> [Int: (start: Int, end: Int)] {
        var extents: [Int: (Int, Int)] = [:]
        for heading in foldedHeadings {
            guard let section = foldableRange(forHeadingLine: heading) else { continue }
            extents[heading] = (structure.index.range(ofLine: heading).location, NSMaxRange(structure.index.range(ofLine: section.upperBound)))
        }
        return extents
    }

    /// Keeps folds on their headings through an edit: folds below the edit
    /// shift with it, folds above it stay, and a fold the edit touches opens.
    private func adjustFolds(extents: [Int: (start: Int, end: Int)], lineDelta: Int) {
        let location = editedRange.location
        let oldEnd = location + editedRange.length - changeInLength
        let inserted = (text).substring(with: editedRange)
        var adjusted: Set<Int> = []
        for (heading, extent) in extents {
            if oldEnd < extent.start || (oldEnd == extent.start && (inserted.hasSuffix("\n") || inserted.isEmpty && location < oldEnd)) {
                adjusted.insert(heading + lineDelta)
            } else if location >= extent.end {
                adjusted.insert(heading)
            }
        }
        foldedHeadings = adjusted.filter { foldableRange(forHeadingLine: $0) != nil }
        refreshFolds(restyling: nil)
    }

    /// The outline number of the heading on a line, if it is one.
    func headingNumber(forLine line: Int) -> String? {
        if headingNumberCache == nil {
            let headings = self.headings
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
    /// Formulas and diagrams this document has asked to be typeset.
    private(set) var requestedTypesetting: Set<Typesetter.Request> = []
    /// The last preview each open block showed, by its first line, so the
    /// preview holds still while the next one is typeset.
    private var lastPreviews: [Int: InlineImage] = [:]
    /// The typeset block found for a run of lines, so styling a block line by
    /// line looks for it once.
    private var blockLookup: (lines: ClosedRange<Int>, block: TypesetBlock?)?
    /// Inline formulas found while styling a line, drawn once its markers are set.
    private var pendingInlineMath: [(range: NSRange, rendering: Typesetter.Rendering)] = []

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
        NotificationCenter.default.addObserver(self, selector: #selector(typesettingDidRender(_:)), name: Typesetter.didRender, object: nil)
        if !text.isEmpty {
            backing.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)
            structure = BlockStructure(text: self.text)
            references = .collect(from: structure, requireDefinitions: false)
            applyStyles(lineRange: 0...max(0, structure.lineCount - 1))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func imageDidLoad(_ notification: Notification) {
        guard let url = notification.object as? URL, requestedImages.contains(url) else { return }
        // Images tend to arrive in a burst; one restyle covers them all.
        guard !isImageRestyleScheduled else { return }
        isImageRestyleScheduled = true
        perform(#selector(restyleForImages), with: nil, afterDelay: 0)
    }

    @objc private func typesettingDidRender(_ notification: Notification) {
        guard let request = notification.userInfo?["request"] as? Typesetter.Request,
              requestedTypesetting.contains(request),
              !isImageRestyleScheduled
        else { return }
        isImageRestyleScheduled = true
        perform(#selector(restyleForImages), with: nil, afterDelay: 0)
    }

    private var isImageRestyleScheduled = false

    @objc private func restyleForImages() {
        isImageRestyleScheduled = false
        restyleAll()
    }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) is not used")
    }

    // MARK: - NSTextStorage

    /// Bridging the backing's mutable string to `String` copies the whole
    /// document, and AppKit asks for `string` constantly during layout — once
    /// per line break — so the copy is kept until the next edit.
    private var cachedString: String?

    /// Counts edits to the characters, so callers can cache what they derive.
    private(set) var editGeneration = 0

    override var string: String {
        if let cachedString { return cachedString }
        let copy = backing.string
        cachedString = copy
        return copy
    }

    /// The text, without the copy: valid until the next edit.
    private var text: NSString { backing.mutableString }

    /// Answered from the backing directly; the inherited version goes through
    /// `attributes(at:)`, bridging a whole dictionary to read one value.
    override func attribute(
        _ attrName: NSAttributedString.Key,
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> Any? {
        backing.attribute(attrName, at: location, effectiveRange: range)
    }

    /// The inherited version walks runs one call at a time; attribute fixing
    /// asks this on every edit.
    override func attribute(
        _ attrName: NSAttributedString.Key,
        at location: Int,
        longestEffectiveRange range: NSRangePointer?,
        in rangeLimit: NSRange
    ) -> Any? {
        backing.attribute(attrName, at: location, longestEffectiveRange: range, in: rangeLimit)
    }

    override func attributes(
        at location: Int,
        longestEffectiveRange range: NSRangePointer?,
        in rangeLimit: NSRange
    ) -> [NSAttributedString.Key: Any] {
        guard backing.length > 0 else { return [:] }
        return backing.attributes(at: location, longestEffectiveRange: range, in: rangeLimit)
    }

    override func attributes(
        at location: Int,
        effectiveRange range: NSRangePointer?
    ) -> [NSAttributedString.Key: Any] {
        guard backing.length > 0 else { return [:] }
        return backing.attributes(at: location, effectiveRange: range)
    }

    override func replaceCharacters(in range: NSRange, with str: String) {
        beginEditing()
        cachedString = nil
        editGeneration += 1
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
            let text = self.text
            let extents = foldedHeadings.isEmpty ? [:] : foldExtents()
            let oldLineCount = structure.lineCount
            let previouslyHidden = hiddenLines
            let updated = structure.update(
                text: text,
                editedRange: editedRange,
                changeInLength: changeInLength
            )
            blockLookup = nil
            if structure.touchedDefinitions {
                references = .collect(from: structure, requireDefinitions: false, extensions: extensions)
            }
            headingNumberCache = nil
            cachedHeadings = nil
            if !extents.isEmpty {
                adjustFolds(extents: extents, lineDelta: structure.lineCount - oldLineCount)
            }
            // The line above takes its spacing from whether this one is blank.
            var lineRange = max(0, updated.lowerBound - 1)...updated.upperBound
            // Lines a fold hid or now hides restyle too; old lines past the
            // end are clamped away.
            let touchedFolds = hiddenLines.union(previouslyHidden)
            if let first = touchedFolds.first, let last = touchedFolds.last {
                lineRange = min(lineRange.lowerBound, first)...max(lineRange.upperBound, last)
            }
            lineRange = clampedLineRange(lineRange) ?? lineRange
            // A formula or diagram is one image: editing a line of it redraws it all.
            lineRange = expandedToTypesetBlocks(lineRange)
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
        // A block that shows as an image opens and closes as a whole.
        let touched = [old, new].compactMap { $0 }.compactMap(clampedLineRange).map(expandedToTypesetBlocks)
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
        let text = self.text
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
        if hiddenLines.contains(line) {
            // Folded away: no glyphs, and a line too short to see.
            backing.setAttributes([
                .font: theme.body,
                .foregroundColor: theme.text,
                .paragraphStyle: Self.hiddenStyle,
                .mdConcealed: true,
                .mdFolded: true,
            ], range: range)
            return
        }
        let characters = structure.characters(of: text, line: line)
        var revealed = sourceMode || (revealedLines?.contains(line) ?? false)

        // Display math and diagrams show as their image, unless being edited;
        // then the source shows with the image as a preview below it.
        var preview: InlineImage?
        var typesetError: String?
        if !sourceMode, let block = typesetBlock(containing: line) {
            let request = typesetRequest(for: block, text: text)
            let (rendering, error) = MainActor.assumeIsolated {
                (Typesetter.shared.rendering(for: request), Typesetter.shared.error(for: request))
            }
            typesetError = error
            if let revealedLines, revealedLines.overlaps(block.lines) {
                revealed = true
                if line == block.lines.upperBound {
                    if let rendering {
                        preview = fittedImage(rendering, centered: true, below: true)
                        lastPreviews[block.lines.lowerBound] = preview
                    } else if typesetError == nil {
                        preview = lastPreviews[block.lines.lowerBound]
                    }
                }
            } else if let rendering {
                styleTypesetBlock(line: line, block: block, info: info, range: range, image: fittedImage(rendering, centered: true))
                return
            }
        }
        pendingInlineMath.removeAll()

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
        let definitionRole = headingLevel == nil && !isTableHeader ? definitionRole(ofLine: line, info: info, text: text) : nil
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
        } else if definitionRole == .term {
            NSFontManager.shared.convert(theme.body, toHaveTrait: .boldFontMask)
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
                // A definition sits one step in from its term.
                listDepth: info.listDepth + (definitionRole == .definition ? 1 : 0),
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
        if let typesetError {
            attributes[.toolTip] = typesetError
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
            let captionHeight = Self.lineHeightManager.defaultLineHeight(for: captionFont) * max(1, spaced.lineHeightMultiple)
            spaced.minimumLineHeight = inlineImage.size.height + Metrics.imageSpacing * 2 + captionHeight
            attributes[.paragraphStyle] = spaced
            attributes[.mdImage] = inlineImage
        }
        // The preview hangs below the block's last line, in space after it.
        if let preview, let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
            let spaced = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
            spaced.paragraphSpacing = preview.size.height + Metrics.imageSpacing * 3
            attributes[.paragraphStyle] = spaced
            attributes[.mdImage] = preview
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
        styleKeys(in: nodes, characters: characters, lineStart: range.location, revealed: revealed, baseFont: baseFont)
        if definitionRole == .definition, let start = definitionStart(Array(characters[info.contentStart...])) {
            // The `: ` gives way to the indent.
            let marker = Marker(range: NSRange(location: info.contentStart, length: start), kind: .conceal)
            applyMarker(marker, lineStart: range.location, revealed: revealed, baseFont: baseFont)
        }

        if !pendingInlineMath.isEmpty, !isTableLine {
            applyInlineMath(lineRange: range)
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

    private nonisolated(unsafe) static let hiddenStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        // Zero would mean "no limit"; this is as close as layout allows.
        style.minimumLineHeight = 0.001
        style.maximumLineHeight = 0.001
        style.lineHeightMultiple = 0
        return style
    }()

    /// Only asked for line heights; making one per image line is wasteful.
    private nonisolated(unsafe) static let lineHeightManager = NSLayoutManager()

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

    /// `<kbd>⌘</kbd>` draws as a key: the tags hide and the label sits on a chip.
    private func styleKeys(in nodes: [InlineNode], characters: [UInt16], lineStart: Int, revealed: Bool, baseFont: NSFont) {
        func tag(_ node: InlineNode) -> String? {
            guard case let .rawHTML(range) = node else { return nil }
            return String(utf16CodeUnits: Array(characters[range.location..<NSMaxRange(range)]), count: range.length).lowercased()
        }
        var open: NSRange?
        for node in nodes {
            switch tag(node) {
            case "<kbd>"?:
                open = node.range
            case "</kbd>"?:
                guard let opening = open else { continue }
                open = nil
                let label = NSRange(location: lineStart + NSMaxRange(opening), length: node.range.location - NSMaxRange(opening))
                guard label.length > 0 else { continue }
                backing.addAttributes([
                    .font: NSFontManager.shared.convert(baseFont, toSize: baseFont.pointSize * 0.85),
                    .mdInlineCode: true,
                ], range: label)
                for marker in [opening, node.range] {
                    applyMarker(Marker(range: marker, kind: .conceal), lineStart: lineStart, revealed: revealed, baseFont: baseFont)
                }
            default:
                continue
            }
        }
    }

    // MARK: - Definition lists

    enum DefinitionRole {
        case term, definition
    }

    /// Whether a paragraph line is a term or a definition in a definition list.
    private func definitionRole(ofLine line: Int, info: LineInfo, text: NSString) -> DefinitionRole? {
        guard extensions.contains(.definitionLists), info.kind == .paragraph else { return nil }
        func continues(_ other: Int) -> Bool {
            guard let next = structure.info(forLine: other) else { return false }
            return next.kind == .paragraph && next.quoteDepth == info.quoteDepth && next.listDepth == info.listDepth
        }
        // Only a paragraph with a `: ` line in it can be one; most have none.
        var first = line, last = line
        while first > 0, continues(first - 1) { first -= 1 }
        while continues(last + 1) { last += 1 }
        guard first < last else { return nil }
        var lines: [String] = []
        var isDefinition = false
        for paragraphLine in first...last {
            guard let lineInfo = structure.info(forLine: paragraphLine) else { return nil }
            let characters = structure.characters(of: text, line: paragraphLine)
            let start = min(lineInfo.contentStart, characters.count)
            let body = Array(characters[start...])
            if paragraphLine == line { isDefinition = definitionStart(body) != nil }
            lines.append(String(utf16CodeUnits: body, count: body.count))
        }
        guard DefinitionList(lines: lines) != nil else { return nil }
        return isDefinition ? .definition : .term
    }

    // MARK: - Typeset math and diagrams

    /// A `$$` display math block or a Mermaid fence: lines that show as one image.
    struct TypesetBlock: Equatable {
        var lines: ClosedRange<Int>
        var kind: Typesetter.Kind
    }

    /// The closed display math block or Mermaid fence holding a line.
    func typesetBlock(containing line: Int) -> TypesetBlock? {
        if let blockLookup, blockLookup.lines.contains(line) { return blockLookup.block }
        guard let info = structure.info(forLine: line) else { return nil }
        let found: (lines: ClosedRange<Int>, block: TypesetBlock?)?
        switch info.kind {
        case .mathLine where !info.state.inMathBlock:
            // `$$ … $$` on a line of its own.
            found = (line...line, TypesetBlock(lines: line...line, kind: .displayMath))
        case .mathDelimiter, .mathLine:
            found = mathBlock(around: line)
        case .fenceStart, .codeLine, .fenceEnd:
            found = fencedBlock(around: line)
        default:
            found = nil
        }
        guard let found else { return nil }
        blockLookup = found
        return found.block
    }

    private func mathBlock(around line: Int) -> (lines: ClosedRange<Int>, block: TypesetBlock?)? {
        func isOpening(_ info: LineInfo) -> Bool { info.kind == .mathDelimiter && info.state.inMathBlock }
        func isInside(_ info: LineInfo) -> Bool { info.kind == .mathLine && info.state.inMathBlock }
        var start = line
        if let info = structure.info(forLine: line), info.kind == .mathDelimiter, !info.state.inMathBlock {
            start -= 1
        }
        while start >= 0, let info = structure.info(forLine: start), isInside(info) { start -= 1 }
        guard start >= 0, let opening = structure.info(forLine: start), isOpening(opening) else { return nil }
        var end = start + 1
        while let info = structure.info(forLine: end), isInside(info) { end += 1 }
        guard let closing = structure.info(forLine: end), closing.kind == .mathDelimiter, !closing.state.inMathBlock else {
            // Unclosed: TeX to the end of the document, shown as written.
            return (start...max(start, end - 1), nil)
        }
        return (start...end, TypesetBlock(lines: start...end, kind: .displayMath))
    }

    private func fencedBlock(around line: Int) -> (lines: ClosedRange<Int>, block: TypesetBlock?)? {
        var start = line
        if structure.info(forLine: line)?.kind == .fenceEnd { start -= 1 }
        while start >= 0, structure.info(forLine: start)?.kind == .codeLine { start -= 1 }
        guard start >= 0, case let .fenceStart(language)? = structure.info(forLine: start)?.kind else { return nil }
        var end = start + 1
        while structure.info(forLine: end)?.kind == .codeLine { end += 1 }
        let isClosed = structure.info(forLine: end)?.kind == .fenceEnd
        let lines = start...(isClosed ? end : max(start, end - 1))
        guard isClosed, language.lowercased() == "mermaid" else { return (lines, nil) }
        return (lines, TypesetBlock(lines: lines, kind: .diagram))
    }

    /// Widens a line range to whole typeset blocks at either end.
    private func expandedToTypesetBlocks(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
        guard !sourceMode else { return range }
        let lower = typesetBlock(containing: range.lowerBound)?.lines.lowerBound ?? range.lowerBound
        let upper = typesetBlock(containing: range.upperBound)?.lines.upperBound ?? range.upperBound
        return min(lower, range.lowerBound)...max(upper, range.upperBound)
    }

    /// What to typeset for a block: the TeX between the `$$`s, or the diagram
    /// between the fences.
    private func typesetRequest(for block: TypesetBlock, text: NSString) -> Typesetter.Request {
        var lines: [String] = []
        for line in block.lines {
            guard let info = structure.info(forLine: line) else { continue }
            let characters = structure.characters(of: text, line: line)
            switch info.kind {
            case .mathLine where !info.state.inMathBlock:
                // Between the `$$` markers.
                let fences = info.markers.filter { $0.kind == .fence }
                guard fences.count == 2 else { continue }
                let start = NSMaxRange(fences[0].range), end = fences[1].range.location
                lines.append(String(utf16CodeUnits: Array(characters[start..<max(start, end)]), count: max(0, end - start)))
            case .mathLine, .codeLine:
                let start = min(info.contentStart, characters.count)
                lines.append(String(utf16CodeUnits: Array(characters[start...]), count: characters.count - start))
            default:
                continue
            }
        }
        let request = Typesetter.Request(
            kind: block.kind,
            source: lines.joined(separator: "\n"),
            fontSize: theme.bodyFontSize,
            color: theme.text.cssString,
            dark: theme.isDark,
            // Laid out at the standard column and scaled to fit, so resizing
            // the window does not redraw every diagram.
            width: block.kind == .diagram ? Metrics.defaultLineWidth : 0
        )
        requestedTypesetting.insert(request)
        return request
    }

    /// A typeset image, scaled down to fit the column.
    private func fittedImage(_ rendering: Typesetter.Rendering, centered: Bool, below: Bool = false) -> InlineImage {
        var size = rendering.size
        let maxWidth = max(80, maxImageWidth)
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        if size.height > Metrics.maxDiagramHeight {
            size = CGSize(width: size.width * Metrics.maxDiagramHeight / size.height, height: Metrics.maxDiagramHeight)
        }
        return InlineImage(image: rendering.image, size: size, centered: centered, below: below)
    }

    /// A block shown as its image: the first line makes room and draws it,
    /// and the rest fold away to nothing.
    private func styleTypesetBlock(line: Int, block: TypesetBlock, info: LineInfo, range: NSRange, image: InlineImage) {
        guard line == block.lines.lowerBound else {
            backing.setAttributes([
                .font: theme.body,
                .foregroundColor: theme.text,
                .paragraphStyle: Self.hiddenStyle,
                .mdConcealed: true,
            ], range: range)
            return
        }
        let endsBlock = structure.info(forLine: block.lines.upperBound + 1)?.kind == .blank
        let base = styles.style(
            listDepth: info.listDepth,
            quoteDepth: info.quoteDepth,
            isCode: false,
            isHeading: false,
            hangingIndent: 0,
            endsBlock: endsBlock,
            theme: theme
        )
        let style = base.mutableCopy() as! NSMutableParagraphStyle
        let height = image.size.height + Metrics.imageSpacing * 2
        style.lineHeightMultiple = 0
        style.minimumLineHeight = height
        style.maximumLineHeight = height
        var attributes: [NSAttributedString.Key: Any] = [
            .font: theme.body,
            .foregroundColor: theme.text,
            .paragraphStyle: style,
            .mdConcealed: true,
            .mdImage: image,
        ]
        if info.quoteDepth > 0 { attributes[.mdQuoteDepth] = info.quoteDepth }
        backing.setAttributes(attributes, range: range)
        // A line with no glyph at all gets no line fragment of its own, so
        // one stays, invisible, to hold the room.
        if range.length > 0 {
            let anchor = NSRange(location: range.location, length: 1)
            backing.removeAttribute(.mdConcealed, range: anchor)
            backing.addAttribute(.foregroundColor, value: NSColor.clear, range: anchor)
        }
    }

    /// Each inline formula keeps one glyph, its opening `$`, invisible and
    /// kerned to the formula's width; the layout manager draws the image
    /// there. The rest of its source is concealed.
    private func applyInlineMath(lineRange: NSRange) {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        for (range, rendering) in pendingInlineMath {
            guard range.length > 1, NSMaxRange(range) <= backing.length else { continue }
            let anchor = NSRange(location: range.location, length: 1)
            let font = backing.attribute(.font, at: anchor.location, effectiveRange: nil) as? NSFont ?? theme.body
            let advance = ("$" as NSString).size(withAttributes: [.font: font]).width
            backing.addAttribute(.mdConcealed, value: true, range: NSRange(location: range.location + 1, length: range.length - 1))
            backing.removeAttribute(.mdConcealed, range: anchor)
            backing.addAttributes([
                .foregroundColor: NSColor.clear,
                .kern: rendering.size.width - advance,
                .mdMath: InlineImage(image: rendering.image, size: rendering.size, descent: rendering.descent),
            ], range: anchor)
            ascent = max(ascent, rendering.size.height - rendering.descent)
            descent = max(descent, rendering.descent)
        }
        pendingInlineMath.removeAll()

        // A tall formula — a fraction, a sum with limits — makes its line taller.
        guard let font = backing.attribute(.font, at: lineRange.location, effectiveRange: nil) as? NSFont,
              let paragraphStyle = backing.attribute(.paragraphStyle, at: lineRange.location, effectiveRange: nil) as? NSParagraphStyle
        else { return }
        let natural = Self.lineHeightManager.defaultLineHeight(for: font) * max(1, paragraphStyle.lineHeightMultiple)
        let extraAscent = max(0, ascent - font.ascender)
        let extraDescent = max(0, descent + font.descender)
        guard extraAscent + extraDescent > 0 else { return }
        let taller = paragraphStyle.mutableCopy() as! NSMutableParagraphStyle
        taller.minimumLineHeight = max(paragraphStyle.minimumLineHeight, natural + extraAscent + extraDescent)
        // The line grows from the top; what hangs below the baseline needs room after it.
        taller.paragraphSpacing += extraDescent
        backing.addAttribute(.paragraphStyle, value: taller, range: lineRange)
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

            case let .math(_, _, content, display):
                // TeX stays as written, set apart in the code face, while
                // it is being edited or until it has been typeset.
                let contentRange = NSRange(location: lineStart + content.location, length: content.length)
                if !revealed {
                    let color = backing.attribute(.foregroundColor, at: absolute.location, effectiveRange: nil) as? NSColor ?? theme.text
                    let request = Typesetter.Request(
                        kind: display ? .displayMath : .inlineMath,
                        source: text.substring(with: contentRange),
                        fontSize: baseFont.pointSize,
                        color: color.cssString,
                        dark: theme.isDark,
                        width: 0
                    )
                    requestedTypesetting.insert(request)
                    if let rendering = MainActor.assumeIsolated({ Typesetter.shared.rendering(for: request) }) {
                        pendingInlineMath.append((absolute, rendering))
                        continue
                    }
                }
                backing.addAttributes([
                    .font: theme.mono,
                    .foregroundColor: theme.syntax.function,
                ], range: contentRange)

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
