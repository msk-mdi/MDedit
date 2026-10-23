import AppKit
import MarkdownKit
import TextStorageBase

/// The text storage that makes the editor WYSIWYG: every edit reparses the
/// lines it touched and restyles exactly those.
final class MarkdownTextStorage: MDBackedTextStorage {
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

    /// Images are scaled down to fit the text column, and tables too wide
    /// for it show as source.
    var maxImageWidth: CGFloat = Metrics.defaultLineWidth {
        didSet {
            guard abs(maxImageWidth - oldValue) > 1 else { return }
            // Once the width settles: a view's first layouts pass through
            // passing widths that would flip every table twice, and dragging
            // a window's edge rescaled every image and formula at each point
            // of the drag. A delayed perform runs in the default run loop
            // mode, which a live resize leaves for its own until the drag ends.
            if !requestedImages.isEmpty || !requestedTypesetting.isEmpty {
                NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(restyleImagesForWidth), object: nil)
                perform(#selector(restyleImagesForWidth), with: nil, afterDelay: 0)
            }
            NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(restyleTablesChangingFit), object: nil)
            perform(#selector(restyleTablesChangingFit), with: nil, afterDelay: 0)
        }
    }

    /// Rescales the images and formulas to the column, once its width settles.
    @objc func restyleImagesForWidth() {
        restyleLines(carrying: [.mdImage, .mdMath, .mdAwaiting])
    }

    /// Restyles the tables a new column width makes fit or no longer fit.
    @objc func restyleTablesChangingFit() {
        var lines = IndexSet()
        backing.enumerateAttribute(.mdTableRow, in: NSRange(location: 0, length: backing.length), options: .longestEffectiveRangeNotRequired) { value, range, _ in
            let changes = if let grid = value as? TableGrid {
                // Too wide now, or wrapping to a column that has changed.
                grid.indent + (grid.edges.last ?? 0) > maxImageWidth || grid.wrapping != nil
            } else if let needed = value as? CGFloat {
                needed <= maxImageWidth
            } else {
                false
            }
            if changes, range.length > 0 {
                lines.insert(integersIn: line(at: range.location)...line(at: NSMaxRange(range) - 1))
            }
        }
        restyle(lines: lines)
    }

    /// Which extended syntax to recognise; changing it reparses everything.
    var extensions: SyntaxExtensions = .all {
        didSet {
            guard extensions != oldValue else { return }
            structure = BlockStructure(text: text, extensions: extensions)
            blockLookup = nil
            tableLookup = nil
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

    /// The headings from before an edit, when it neither touched a heading
    /// nor made one: those below it just move. Nil when they must be found
    /// again, which means parsing every heading.
    private func headingsKept(_ old: [Heading], reparsed: ClosedRange<Int>, lineDelta: Int) -> [Heading]? {
        // A setext heading's title is the paragraph above its underline, so
        // the lines either side of the edit count too, and an edited
        // paragraph counts when an underline ends it further down.
        let low = reparsed.lowerBound - 1
        let oldHigh = max(reparsed.lowerBound, reparsed.upperBound - lineDelta) + 1
        if old.contains(where: { $0.line >= low && $0.line <= oldHigh }) { return nil }
        let newHigh = min(structure.lineCount - 1, reparsed.upperBound + 1)
        if max(0, low) <= newHigh {
            for line in max(0, low)...newHigh {
                switch structure.info(forLine: line)?.kind {
                case .atxHeading?, .setextUnderline?: return nil
                default: continue
                }
            }
        }
        var below = newHigh + 1
        while below < structure.lineCount, structure.info(forLine: below)?.kind == .paragraph { below += 1 }
        if below > newHigh + 1 || structure.info(forLine: newHigh)?.kind == .paragraph,
           case .setextUnderline? = structure.info(forLine: below)?.kind {
            return nil
        }
        guard lineDelta != 0 else { return old }
        return old.map { heading in
            var heading = heading
            if heading.line > reparsed.lowerBound { heading.line += lineDelta }
            return heading
        }
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
    /// preview holds still while the next one is typeset. Kept only while
    /// the block is open, and moved with the lines around it.
    private(set) var lastPreviews: [Int: InlineImage] = [:]
    /// The typeset block found for a run of lines, so styling a block line by
    /// line looks for it once.
    private var blockLookup: (lines: ClosedRange<Int>, block: TypesetBlock?)?
    /// Likewise the last table found, so styling one row by row finds it once.
    private var tableLookup: ClosedRange<Int>?
    /// Set while restyling a table too wide for the column as aligned source.
    private var stylingTableAsSource = false
    /// A block's request while styling it line by line: built from all its
    /// lines, so building it for each one was quadratic in a long block.
    private var typesetLookup: (lines: ClosedRange<Int>, request: Typesetter.Request)?
    /// The source each block last asked for, by its first line, so an edit
    /// withdraws the one it replaces. Moved with the lines around it, so a
    /// block that moves onto another's old line does not withdraw that one's.
    private(set) var blockRequests: [Int: Typesetter.Request] = [:]
    /// Inline formulas found while styling a line, drawn once its markers are set.
    private var pendingInlineMath: [(range: NSRange, rendering: Typesetter.Rendering)] = []

    /// Text an input method is still composing, and the look the view marks
    /// it with: styling sets each line's attributes afresh, which took that
    /// look off and left nothing to show what was still to be committed.
    private var composing: (range: NSRange, attributes: [NSAttributedString.Key: Any])?

    /// Told by the view after each change to the text being composed, and
    /// with nil once it is committed or abandoned.
    func markComposing(_ range: NSRange?, attributes: [NSAttributedString.Key: Any]) {
        let previous = composing?.range
        composing = range.flatMap { $0.length > 0 && NSMaxRange($0) <= backing.length ? ($0, attributes) : nil }
        if let composing {
            beginEditing()
            backing.addAttributes(composing.attributes, range: composing.range)
            edited(.editedAttributes, range: composing.range, changeInLength: 0)
            endEditing()
        } else if let previous, NSMaxRange(previous) <= backing.length {
            // Abandoned in place: its lines take their own look back.
            restyle(lines: IndexSet(integersIn: line(at: previous.location)...lastLine(of: previous)))
        }
    }

    private var isProcessingEdit = false
    private var hasDeferredReveal = false
    private var deferredRevealOld: ClosedRange<Int>?

    var theme: Theme {
        didSet {
            // Every editor is handed the theme again on open, on appearance
            // changes and on any setting; restyle only when it differs.
            guard theme != oldValue else { return }
            styles.removeAll()
            markerAttributes.removeAll()
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
            fixAttributes(in: NSRange(location: 0, length: backing.length))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func imageDidLoad(_ notification: Notification) {
        guard let url = notification.object as? URL else { return }
        arrived(.image(url))
    }

    @objc private func typesettingDidRender(_ notification: Notification) {
        guard let request = notification.userInfo?["request"] as? Typesetter.Request else { return }
        arrived(.typesetting(request))
    }

    /// Notes an image or formula that lines here wait for. Opening a
    /// math-heavy document or switching theme has hundreds arrive one by
    /// one, a few milliseconds apart; gathering them for a moment restyles
    /// each waiting line about once instead of once per arrival.
    private func arrived(_ item: AwaitedItem) {
        guard linesAwaiting[item] != nil else { return }
        arrivals.insert(item)
        guard !isArrivalRestyleScheduled else { return }
        isArrivalRestyleScheduled = true
        perform(#selector(restyleForArrivals), with: nil, afterDelay: 0.05)
    }

    private var isArrivalRestyleScheduled = false
    /// Images and formulas that arrived since the last restyle for them.
    private var arrivals: Set<AwaitedItem> = []
    private var isReferenceRestyleScheduled = false
    /// Labels whose definition came, went or changed since the last restyle.
    private var pendingReferenceLabels: Set<String> = []

    private static func labelsChanged(from old: LinkReferences, to new: LinkReferences) -> Set<String> {
        var labels = Set(old.links.keys).symmetricDifference(new.links.keys)
        for (label, definition) in new.links where old.links[label].map({ $0 != definition }) ?? false { labels.insert(label) }
        return labels.union(old.footnotes.symmetricDifference(new.footnotes))
    }

    /// Restyles the lines that mention a label: a `[label]` with no
    /// definition is plain text, so no attribute marks where they are.
    @objc private func restyleForReferences() {
        isReferenceRestyleScheduled = false
        let labels = pendingReferenceLabels
        pendingReferenceLabels = []
        let text = self.text
        var lines = IndexSet()
        for label in labels where !label.isEmpty {
            var searched = NSRange(location: 0, length: text.length)
            while searched.length > 0 {
                let found = text.range(of: label, options: [.caseInsensitive, .literal], range: searched)
                guard found.location != NSNotFound else { break }
                lines.insert(line(at: found.location))
                searched = NSRange(location: NSMaxRange(found), length: text.length - NSMaxRange(found))
            }
        }
        restyle(lines: lines)
    }

    /// Restyles the lines that wait for what arrived, and only those: every
    /// line still waiting was restyled on each arrival, so N images or
    /// formulas cost N times N restyles.
    @objc func restyleForArrivals() {
        isArrivalRestyleScheduled = false
        var lines = IndexSet()
        for item in arrivals {
            if let waiting = linesAwaiting[item] { lines.formUnion(waiting) }
        }
        arrivals = []
        restyle(lines: lines)
    }

    /// Something a line shows once it is ready.
    enum AwaitedItem: Hashable {
        case image(URL)
        case typesetting(Typesetter.Request)
    }

    /// What the line being styled asked for that is not ready yet.
    private var lineAwaits: Set<AwaitedItem> = []
    /// The lines waiting for each image or formula, so an arrival restyles
    /// its own lines without a scan of the document.
    private(set) var linesAwaiting: [AwaitedItem: IndexSet] = [:]
    /// The same, by line, so restyling a line drops what it waited for.
    private var awaitedByLine: [Int: Set<AwaitedItem>] = [:]

    /// Records what a line just styled waits for, in place of what it waited
    /// for before.
    private func noteAwaits(line: Int, range: NSRange) {
        if let previous = awaitedByLine.removeValue(forKey: line) {
            for item in previous where !lineAwaits.contains(item) {
                linesAwaiting[item]?.remove(line)
                if linesAwaiting[item]?.isEmpty == true { linesAwaiting[item] = nil }
            }
        }
        guard !lineAwaits.isEmpty else { return }
        backing.addAttribute(.mdAwaiting, value: true, range: range)
        awaitedByLine[line] = lineAwaits
        for item in lineAwaits { linesAwaiting[item, default: IndexSet()].insert(line) }
    }

    /// Moves the waiting lines with an edit: lines it replaced are dropped,
    /// to be styled again, and the lines after it shift. True when any of
    /// the replaced lines was waiting.
    private func shiftAwaits(dropping replaced: ClosedRange<Int>, by delta: Int) -> Bool {
        guard !awaitedByLine.isEmpty else { return false }
        var byLine: [Int: Set<AwaitedItem>] = [:]
        var dropped = false
        for (line, items) in awaitedByLine {
            if replaced.contains(line) {
                dropped = true
            } else {
                byLine[line > replaced.upperBound ? line + delta : line] = items
            }
        }
        awaitedByLine = byLine
        for (item, var lines) in linesAwaiting {
            lines.remove(integersIn: replaced.lowerBound..<(replaced.upperBound + 1))
            lines.shift(startingAt: replaced.upperBound + 1, by: delta)
            linesAwaiting[item] = lines.isEmpty ? nil : lines
        }
        return dropped
    }

    /// Moves what is kept by a block's first line with an edit, as
    /// `shiftAwaits` moves the waiting lines. A block that started on a
    /// replaced line keeps its place while it is still among the edited
    /// lines, to be checked once they are styled; past them it is gone.
    private func shiftBlocks(dropping replaced: ClosedRange<Int>, keepingUpTo editEnd: Int, by delta: Int) {
        guard !blockRequests.isEmpty || !lastPreviews.isEmpty else { return }
        func shifted(_ line: Int) -> Int? {
            if line > replaced.upperBound { return line + delta }
            return line < replaced.lowerBound || line <= editEnd ? line : nil
        }
        var requests: [Int: Typesetter.Request] = [:]
        var dropped: [Typesetter.Request] = []
        for (line, request) in blockRequests {
            if let moved = shifted(line) { requests[moved] = request } else { dropped.append(request) }
        }
        blockRequests = requests
        withdraw(dropped)
        var previews: [Int: InlineImage] = [:]
        for (line, preview) in lastPreviews {
            if let moved = shifted(line) { previews[moved] = preview }
        }
        lastPreviews = previews
    }

    /// Forgets the blocks that no longer start where they were kept, once
    /// the lines an edit touched are styled.
    private func pruneBlocks(in lines: ClosedRange<Int>) {
        var dropped: [Typesetter.Request] = []
        for (line, request) in blockRequests where lines.contains(line) && typesetBlock(containing: line)?.lines.lowerBound != line {
            blockRequests[line] = nil
            dropped.append(request)
        }
        withdraw(dropped)
        for line in lastPreviews.keys where lines.contains(line) && typesetBlock(containing: line)?.lines.lowerBound != line {
            lastPreviews[line] = nil
        }
    }

    /// Withdraws sources no block asks for any more; the same formula in
    /// another block keeps its own.
    private func withdraw(_ requests: [Typesetter.Request]) {
        guard !requests.isEmpty else { return }
        let inUse = Set(blockRequests.values)
        for request in requests where !inUse.contains(request) {
            MainActor.assumeIsolated { Typesetter.shared.cancel(request) }
            requestedTypesetting.remove(request)
        }
    }

    /// Restyles just the lines with any of these attributes: a scan of the
    /// runs, where restyling everything would rebuild them all.
    private func restyleLines(carrying keys: [NSAttributedString.Key]) {
        var lines = IndexSet()
        let whole = NSRange(location: 0, length: backing.length)
        for key in keys {
            backing.enumerateAttribute(key, in: whole, options: .longestEffectiveRangeNotRequired) { value, range, _ in
                guard value != nil, range.length > 0 else { return }
                lines.insert(integersIn: line(at: range.location)...line(at: NSMaxRange(range) - 1))
            }
        }
        restyle(lines: lines)
    }

    private func restyle(lines: IndexSet) {
        // What arrived, or the width or definitions that changed, can change
        // how wide a cell is without changing its text.
        rowWidths.removeAll()
        rowMinimumWidths.removeAll()
        restyle(ranges: lines.rangeView.compactMap { clampedLineRange($0.lowerBound...($0.upperBound - 1)) }.map(expandedToTypesetBlocks))
    }

    /// Restyles each range as an edit of its own. Edits reported together
    /// are merged into one range from the first to the last, so a caret
    /// jumping from the top of a long document to the bottom had every line
    /// between refixed and laid out again: seconds, for two lines.
    /// `widening` widens each range as typing does, table rows aside.
    private func restyle(ranges: [ClosedRange<Int>], widening: Bool = false) {
        for range in ranges {
            beginEditing()
            let styled = widening ? styleWidened(range, linesKept: true) : range
            if !widening { applyStyles(lineRange: range) }
            edited(.editedAttributes, range: characterRange(forLines: styled), changeInLength: 0)
            endEditing()
            pendingInvalidation = characterRange(forLines: styled)
            flushPendingInvalidation()
        }
    }

    @available(*, unavailable)
    required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType) {
        fatalError("init(pasteboardPropertyList:ofType:) is not used")
    }

    // MARK: - NSTextStorage

    /// Counts edits to the characters, so callers can cache what they derive.
    private(set) var editGeneration = 0

    /// The text without the copy that bridging `string` to Swift makes:
    /// live, so read it and let it go before the next edit.
    var text: NSString { backing.mutableString }

    // Length, the string and attribute access, which TextKit calls run by
    // run, are answered by `MDBackedTextStorage` without crossing into Swift.

    override func replaceCharacters(in range: NSRange, with str: String) {
        editGeneration += 1
        super.replaceCharacters(in: range, with: str)
    }

    /// Font fixing swaps Apple Color Emoji off a shortcode's closing colon,
    /// since that font has no colon glyph; the emoji drawn there needs it back.
    override func fixAttributes(in range: NSRange) {
        super.fixAttributes(in: range)
        restoreEmojiFonts(in: range)
    }

    /// Fixes attributes in the backing string alone, outside `edited`: run
    /// during an edit, fixing through the storage widens the edited range,
    /// and the layout manager then moves a caret at the edit to its end,
    /// past whatever the fixing touched.
    private func fixBackingAttributes(in range: NSRange) {
        backing.fixAttributes(in: range)
        restoreEmojiFonts(in: range)
    }

    private func restoreEmojiFonts(in range: NSRange) {
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
            // The range no longer holds; the view marks the new one after.
            composing = nil
            let text = self.text
            let extents = foldedHeadings.isEmpty ? [:] : foldExtents()
            let oldLineCount = structure.lineCount
            let previouslyHidden = hiddenLines
            let updated = structure.update(
                text: text,
                editedRange: editedRange,
                changeInLength: changeInLength
            )
            let lineDelta = structure.lineCount - oldLineCount
            // The lines the edit now spans; those it replaced were numbered
            // up to `editEnd - lineDelta` before it.
            let editEnd = max(updated.lowerBound, line(at: NSMaxRange(editedRange)))
            let replacedAwaiting = lineDelta != 0
                && shiftAwaits(dropping: updated.lowerBound...max(updated.lowerBound, editEnd - lineDelta), by: lineDelta)
            if lineDelta != 0 {
                shiftBlocks(dropping: updated.lowerBound...max(updated.lowerBound, editEnd - lineDelta), keepingUpTo: editEnd, by: lineDelta)
            }
            blockLookup = nil
            tableLookup = nil
            if structure.touchedDefinitions {
                let previous = references
                references = .collect(from: structure, requireDefinitions: false, extensions: extensions)
                // Links elsewhere that use a definition just added, changed or
                // removed would keep the destination they had until edited.
                if references != previous {
                    pendingReferenceLabels.formUnion(Self.labelsChanged(from: previous, to: references))
                    if !isReferenceRestyleScheduled {
                        isReferenceRestyleScheduled = true
                        perform(#selector(restyleForReferences), with: nil, afterDelay: 0)
                    }
                }
            }
            headingNumberCache = nil
            cachedHeadings = cachedHeadings.flatMap { headingsKept($0, reparsed: updated, lineDelta: lineDelta) }
            if !extents.isEmpty {
                adjustFolds(extents: extents, lineDelta: lineDelta)
            }
            // The line above takes its spacing from whether this one is blank.
            var lineRange = max(0, updated.lowerBound - 1)...updated.upperBound
            // A waiting line the edit ended on may have moved down intact,
            // outside what was reparsed; styling it again says what it waits for.
            if replacedAwaiting {
                lineRange = lineRange.lowerBound...max(lineRange.upperBound, editEnd)
            }
            // Lines a fold hid or now hides restyle too; old lines past the
            // end are clamped away. Hidden lines below the edit moved with
            // it, styling and all, so only lines whose state changed count:
            // every hidden line made each keystroke restyle up to the last fold.
            if !hiddenLines.isEmpty || !previouslyHidden.isEmpty {
                // Where the old lines after the edit went.
                let editStart = updated.lowerBound
                var shifted = previouslyHidden
                shifted.shift(startingAt: editEnd - lineDelta + 1, by: lineDelta)
                var changed = hiddenLines.symmetricDifference(shifted)
                changed.insert(integersIn: editStart...editEnd)
                if let first = changed.first, let last = changed.last {
                    lineRange = min(lineRange.lowerBound, first)...max(lineRange.upperBound, last)
                }
            }
            lineRange = clampedLineRange(lineRange) ?? lineRange
            // A formula or diagram is one image: editing a line of it redraws it all.
            lineRange = styleWidened(lineRange, linesKept: lineDelta == 0)
            pruneBlocks(in: min(lineRange.lowerBound, updated.lowerBound)...max(lineRange.upperBound, editEnd))
            let restyled = characterRange(forLines: lineRange)
            // Styling sets each line's font afresh, taking emoji and CJK off
            // the fallback fonts that draw them; AppKit puts those back only
            // in the edited range, so the rest of these lines would show
            // nothing where they were. The invalidation below covers them.
            let edited = editedRange
            let before = min(edited.location, NSMaxRange(restyled))
            if before > restyled.location {
                fixBackingAttributes(in: NSRange(location: restyled.location, length: before - restyled.location))
            }
            if NSMaxRange(restyled) > NSMaxRange(edited) {
                let after = max(NSMaxRange(edited), restyled.location)
                fixBackingAttributes(in: NSRange(location: after, length: NSMaxRange(restyled) - after))
            }
            pendingInvalidation = restyled
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
        // One run first, so each line's styles split the tail of the run array
        // instead of reshaping it in the middle: Foundation keeps runs in a flat
        // array, and restyling over existing runs memmoves the rest of the
        // document per line (42 s rather than 3 s at 4.5 MB).
        backing.setAttributes([.font: theme.body], range: NSRange(location: 0, length: backing.length))
        // Every line says again what it waits for, and how wide its cells are.
        rowWidths.removeAll()
        rowMinimumWidths.removeAll()
        linesAwaiting = [:]
        awaitedByLine = [:]
        applyStyles(lineRange: 0...(structure.lineCount - 1))
        edited(.editedAttributes, range: NSRange(location: 0, length: backing.length), changeInLength: 0)
        endEditing()
    }

    func line(at location: Int) -> Int {
        structure.index.line(at: min(max(0, location), backing.length))
    }

    /// The last line a selection touches. One ending at the start of a line,
    /// as a triple-click's does, ends on the line before: the next is not
    /// part of it.
    func lastLine(of range: NSRange) -> Int {
        line(at: range.length > 0 ? NSMaxRange(range) - 1 : range.location)
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
        // Only lines that were revealed and are not, or the other way round:
        // a selection growing by a line restyles that line, not all of it.
        func lines(_ range: ClosedRange<Int>?) -> IndexSet {
            range.flatMap(clampedLineRange).map { IndexSet(integersIn: $0) } ?? IndexSet()
        }
        let changed = lines(old).symmetricDifference(lines(new))
        // A block that shows as an image opens and closes as a whole.
        restyle(ranges: changed.rangeView.map { $0.lowerBound...($0.upperBound - 1) }, widening: true)
    }

    /// Styles lines. With `rowsAlone`, the lines are rows of one grid table
    /// and only they are laid out; false, then, when the table's columns
    /// changed or it no longer fits, and the whole table must be styled.
    @discardableResult
    private func applyStyles(lineRange: ClosedRange<Int>, rowsAlone: Bool = false) -> Bool {
        let text = self.text
        let lower = max(0, lineRange.lowerBound)
        let upper = min(lineRange.upperBound, structure.lineCount - 1)
        guard lower <= upper else { return true }
        definitionLookup = nil
        typesetLookup = nil
        defer {
            definitionLookup = nil
            typesetLookup = nil
            if let composing {
                let marked = NSIntersectionRange(composing.range, characterRange(forLines: lower...upper))
                if marked.length > 0 { backing.addAttributes(composing.attributes, range: marked) }
            }
        }

        for line in lower...upper {
            guard let info = structure.info(forLine: line) else { continue }
            let lineRange = structure.index.range(ofLine: line)
            guard lineRange.length > 0 || lineRange.location < text.length else { continue }
            lineAwaits = []
            style(line: line, info: info, range: lineRange, text: text)
            noteAwaits(line: line, range: lineRange)
        }

        // A table's columns are as wide as their widest cell, so its rows are
        // laid out together once each is styled. Callers widen the range to
        // whole tables, unless only some rows changed.
        guard !sourceMode else { return true }
        var line = lower
        while line <= upper {
            guard let table = gridTable(containing: line) else {
                line += 1
                continue
            }
            let needed: CGFloat
            switch layOutTable(table, text: text, only: rowsAlone ? lower...upper : nil) {
            case .laidOut:
                line = table.upperBound + 1
                continue
            case .columnsChanged:
                return false
            case let .tooWide(width):
                if rowsAlone { return false }
                needed = width
            }
            // Too wide for the column: aligned source scrolls no worse than prose wraps.
            stylingTableAsSource = true
            for row in table {
                guard let info = structure.info(forLine: row) else { continue }
                lineAwaits = []
                let range = structure.index.range(ofLine: row)
                style(line: row, info: info, range: range, text: text)
                noteAwaits(line: row, range: range)
                // The width it needs, so a wider column shows it as a grid again.
                backing.addAttribute(.mdTableRow, value: needed, range: range)
            }
            stylingTableAsSource = false
            line = table.upperBound + 1
        }
        return true
    }

    /// Styles lines, widened to the whole formulas, diagrams and tables they
    /// touch — except rows of a table changed in a way that leaves its
    /// columns as they were, when only those rows are styled: every row of a
    /// long table was laid out again on each keystroke. `linesKept` says no
    /// lines came or went. Returns the lines styled.
    private func styleWidened(_ lines: ClosedRange<Int>, linesKept: Bool) -> ClosedRange<Int> {
        if linesKept, isRowsAlone(lines), applyStyles(lineRange: lines, rowsAlone: true) { return lines }
        let widened = expandedToDefinitionGaps(expandedToTypesetBlocks(lines))
        applyStyles(lineRange: widened)
        return widened
    }

    /// Whether lines are body rows of one grid table with other rows to
    /// compare columns with, and not its delimiter, which aligns them all.
    private func isRowsAlone(_ lines: ClosedRange<Int>) -> Bool {
        guard !sourceMode, let table = gridTable(containing: lines.lowerBound), table.contains(lines.upperBound) else { return false }
        return !lines.contains(table.lowerBound + 1) && table.count - lines.count >= 2
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

        // `[label]: url` is bookkeeping, not prose: it folds away, as it is
        // missing from rendered output, until the caret comes to edit it.
        // So does the blank line above it, when one below already keeps the
        // paragraphs apart, or the hidden line would leave a double gap.
        if isHiddenDefinition(line) || (!revealed && hidesDefinitionGap(line)) {
            backing.setAttributes([
                .font: theme.body,
                .foregroundColor: theme.secondaryText,
                .paragraphStyle: Self.hiddenStyle,
                .mdConcealed: true,
            ], range: range)
            return
        }

        // Display math and diagrams show as their image, unless being edited;
        // then the source shows with the image as a preview below it.
        var preview: InlineImage?
        var typesetError: String?
        if !sourceMode, let block = typesetBlock(containing: line) {
            let request: Typesetter.Request
            if let typesetLookup, typesetLookup.lines == block.lines {
                request = typesetLookup.request
            } else {
                request = typesetRequest(for: block, text: text)
                typesetLookup = (block.lines, request)
                if let previous = blockRequests.updateValue(request, forKey: block.lines.lowerBound), previous != request {
                    MainActor.assumeIsolated { Typesetter.shared.cancel(previous) }
                    requestedTypesetting.remove(previous)
                }
            }
            let (rendering, error) = MainActor.assumeIsolated {
                (Typesetter.shared.rendering(for: request), Typesetter.shared.error(for: request))
            }
            typesetError = error
            if rendering == nil, error == nil { lineAwaits.insert(.typesetting(request)) }
            if let revealedLines, revealedLines.overlaps(block.lines) {
                revealed = true
                if line == block.lines.upperBound {
                    if let rendering {
                        preview = fittedImage(rendering, centered: true, below: true, label: request.spokenLabel)
                        lastPreviews[block.lines.lowerBound] = preview
                    } else if typesetError == nil {
                        preview = lastPreviews[block.lines.lowerBound]
                    }
                }
            } else {
                // Closed: the preview it held, a diagram's bitmap, goes with it.
                lastPreviews[block.lines.lowerBound] = nil
                if let rendering {
                    styleTypesetBlock(line: line, block: block, info: info, range: range, image: fittedImage(rendering, centered: true, label: request.spokenLabel))
                    return
                }
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
        // Out of source mode a table is drawn as a grid, in the body font.
        let isGrid = isTableLine && !stylingTableAsSource && gridTable(containing: line) != nil
        if isGrid, isTableDelimiter(info.kind), !revealed {
            // The grid draws the line under the header in its place.
            backing.setAttributes([
                .font: theme.body,
                .foregroundColor: theme.text,
                .paragraphStyle: Self.hiddenStyle,
                .mdConcealed: true,
            ], range: range)
            return
        }
        let definitionRole = headingLevel == nil && !isTableHeader ? definitionRole(ofLine: line, info: info, text: text) : nil
        let baseFont: NSFont = if isGrid, isTableHeader {
            NSFontManager.shared.convert(theme.body, toHaveTrait: .boldFontMask)
        } else if isGrid, !isTableDelimiter(info.kind) {
            theme.body
        } else if isTableHeader {
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

        if !pendingInlineMath.isEmpty, !isTableLine || isGrid {
            applyInlineMath(lineRange: range)
        }

        // Pipes are scaffolding: drawn faintly so the cells read first.
        // Concealing markup inside a cell would pull its row's pipes out of
        // line, so in tables hidden markers keep their width and turn invisible.
        // (A grid lays its cells out afterwards, with markup concealed.)
        if isTableLine, !isGrid, !isTableDelimiter(info.kind) {
            backing.enumerateAttribute(.mdConcealed, in: range) { value, concealed, _ in
                guard value != nil else { return }
                backing.removeAttribute(.mdConcealed, range: concealed)
                backing.addAttribute(.foregroundColor, value: NSColor.clear, range: concealed)
            }
        }

        if isTableLine, !isGrid, !isTableDelimiter(info.kind) {
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
            // A linked image, `[![alt](image)](target)`, is still just an image.
            case let .link(_, _, _, _, children) where source == nil:
                guard children.count == 1, case let .image(_, _, imageSource, _, _) = children[0] else { return nil }
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
        guard let image = MainActor.assumeIsolated({ ImageCache.shared.image(for: url) }) else {
            // One that failed will not arrive: waiting for it restyled the
            // line on every other image and formula that did.
            if !MainActor.assumeIsolated({ ImageCache.shared.hasFailed(url) }) { lineAwaits.insert(.image(url)) }
            return nil
        }

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
        func body(_ paragraphLine: Int) -> [UInt16]? {
            guard let lineInfo = structure.info(forLine: paragraphLine) else { return nil }
            let characters = structure.characters(of: text, line: paragraphLine)
            return Array(characters[min(lineInfo.contentStart, characters.count)...])
        }
        func isDefinition(_ paragraphLine: Int) -> Bool {
            body(paragraphLine).map { definitionStart($0) != nil } ?? false
        }
        // The paragraph is looked at once per styling pass, not once a line:
        // a long hard-wrapped one was quadratic. And not to its ends either:
        // a list has no two lines in a row without `: ` (every term has a
        // definition), so the first such pair settles it, usually right
        // beside this line. Walking all of a long paragraph cost every
        // keystroke in it time in proportion to its length.
        if definitionLookup?.lines.contains(line) != true {
            definitionLookup = {
                var first = line, last = line
                var firstIsDefinition = isDefinition(line), lastIsDefinition = firstIsDefinition
                while first > 0, continues(first - 1) {
                    let above = isDefinition(first - 1)
                    if !above, !firstIsDefinition { return ((first - 1)...last, false) }
                    first -= 1
                    firstIsDefinition = above
                }
                while continues(last + 1) {
                    let below = isDefinition(last + 1)
                    if !below, !lastIsDefinition { return (first...(last + 1), false) }
                    last += 1
                    lastIsDefinition = below
                }
                // Opening with a term and closing with a definition, as DefinitionList requires.
                return (first...last, first < last && !firstIsDefinition && lastIsDefinition)
            }()
        }
        guard definitionLookup?.isList == true, let characters = body(line) else { return nil }
        return definitionStart(characters) != nil ? .definition : .term
    }

    /// The paragraph found for a run of lines while styling, and whether it
    /// is a definition list.
    private var definitionLookup: (lines: ClosedRange<Int>, isList: Bool)?

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
    /// A `[label]: url` line the caret is away from, so it folds away.
    private func isHiddenDefinition(_ line: Int) -> Bool {
        guard !sourceMode, case .linkReferenceDefinition? = structure.info(forLine: line)?.kind else { return false }
        return !(revealedLines?.contains(line) ?? false)
    }

    /// A blank line before hidden definitions that are themselves followed by
    /// a blank line or the end: one of the two blanks is enough.
    private func hidesDefinitionGap(_ line: Int) -> Bool {
        guard structure.info(forLine: line)?.kind == .blank, isHiddenDefinition(line + 1) else { return false }
        var next = line + 1
        while isHiddenDefinition(next) { next += 1 }
        return next >= structure.lineCount || structure.info(forLine: next)?.kind == .blank
    }

    /// Whether a definition hides depends on the lines below it, so
    /// restyling a line reaches up over definitions to the blank above them.
    private func expandedToDefinitionGaps(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
        guard !sourceMode else { return range }
        var lower = range.lowerBound
        while lower > 0, case .linkReferenceDefinition? = structure.info(forLine: lower - 1)?.kind { lower -= 1 }
        if lower > 0, structure.info(forLine: lower - 1)?.kind == .blank { lower -= 1 }
        return lower...range.upperBound
    }

    /// Tables count as blocks here: a cell's width moves its whole column.
    private func expandedToTypesetBlocks(_ range: ClosedRange<Int>) -> ClosedRange<Int> {
        guard !sourceMode else { return range }
        let lower = typesetBlock(containing: range.lowerBound)?.lines.lowerBound
            ?? gridTable(containing: range.lowerBound)?.lowerBound ?? range.lowerBound
        let upper = typesetBlock(containing: range.upperBound)?.lines.upperBound
            ?? gridTable(containing: range.upperBound)?.upperBound ?? range.upperBound
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
    private func fittedImage(_ rendering: Typesetter.Rendering, centered: Bool, below: Bool = false, label: String) -> InlineImage {
        var size = rendering.size
        let maxWidth = max(80, maxImageWidth)
        if size.width > maxWidth {
            size = CGSize(width: maxWidth, height: size.height * maxWidth / size.width)
        }
        if size.height > Metrics.maxDiagramHeight {
            size = CGSize(width: size.width * Metrics.maxDiagramHeight / size.height, height: Metrics.maxDiagramHeight)
        }
        return InlineImage(image: rendering.image, size: size, centered: centered, below: below, label: label)
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
                .mdMath: InlineImage(
                    image: rendering.image, size: rendering.size, descent: rendering.descent,
                    label: text.substring(with: range).trimmingCharacters(in: CharacterSet(charactersIn: "$"))
                ),
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

    // MARK: - Tables

    /// Longer tables show as aligned source: each keystroke in a grid lays
    /// out the whole table again.
    private static let maxGridTableRows = 300

    /// The lines of the table holding a line, header to last row, when it is
    /// drawn as a grid.
    private func gridTable(containing line: Int) -> ClosedRange<Int>? {
        guard !sourceMode, let info = structure.info(forLine: line) else { return nil }
        if let tableLookup, tableLookup.contains(line) { return tableLookup }
        var delimiter: Int
        switch info.kind {
        case .tableDelimiter:
            delimiter = line
        case .tableRow:
            delimiter = line - 1
            while structure.info(forLine: delimiter)?.kind == .tableRow {
                delimiter -= 1
                if line - delimiter > Self.maxGridTableRows { return nil }
            }
        case .paragraph:
            delimiter = line + 1
        default:
            return nil
        }
        guard delimiter >= 1, isTableDelimiter(structure.info(forLine: delimiter)?.kind ?? .blank) else { return nil }
        var end = delimiter
        while structure.info(forLine: end + 1)?.kind == .tableRow {
            end += 1
            if end - delimiter > Self.maxGridTableRows { return nil }
        }
        tableLookup = (delimiter - 1)...end
        return tableLookup
    }

    /// Lays a styled table's rows into columns. Each cell's padding is
    /// concealed and the invisible pipe before it kerned, so the cell starts
    /// where its column does; the layout manager draws the lines between.
    /// When the table is too wide, changes nothing and returns the width it needs.
    private enum TableLayout {
        case laidOut
        /// Too wide for the column, needing this much.
        case tooWide(CGFloat)
        /// Laying out only some rows, the columns came out otherwise than the
        /// other rows have them.
        case columnsChanged
    }

    /// The width of each cell of a row, by what decides it: its text, and
    /// whether it shows its markup or is the bold header.
    private struct RowKey: Hashable {
        var text: [UInt16]
        var revealed: Bool
        var header: Bool
    }

    /// Cell widths measured before: measuring every cell of a long table
    /// again was a large part of each keystroke in it. Cleared whenever
    /// something other than a row's own text may change them.
    private var rowWidths: [RowKey: [CGFloat]] = [:]

    /// The narrowest each cell of a row can wrap to: its longest word. Only
    /// measured for tables too wide for the column.
    private var rowMinimumWidths: [RowKey: [CGFloat]] = [:]

    /// Lays out a table's rows as a grid. One too wide for the column wraps
    /// its cells, columns sharing the room as a browser shares it, unless a
    /// word is wider than the room it would get.
    private func layOutTable(_ table: ClosedRange<Int>, text: NSString, only: ClosedRange<Int>? = nil) -> TableLayout {
        let delimiterLine = table.lowerBound + 1
        guard case let .tableDelimiter(alignments)? = structure.info(forLine: delimiterLine)?.kind else { return .tooWide(.infinity) }
        if rowWidths.count > 20_000 { rowWidths.removeAll() }
        if rowMinimumWidths.count > 20_000 { rowMinimumWidths.removeAll() }
        let showsDelimiter = revealedLines?.contains(delimiterLine) ?? false

        struct Row {
            var line: Int
            var range: NSRange
            var split: TableRowSplit
            var widths: [CGFloat]
            var key: RowKey
        }
        var rows: [Row] = []
        var widths = [CGFloat](repeating: 0, count: alignments.count)
        for line in table where line != delimiterLine || showsDelimiter {
            guard let info = structure.info(forLine: line) else { continue }
            let range = structure.index.range(ofLine: line)
            let characters = structure.characters(of: text, line: line)
            // The delimiter's dashes are concealed text, shown as written.
            let split = line == delimiterLine
                ? TableRowSplit(pipes: [], cells: [], leadingPipe: false)
                : TableRowSplit(characters, from: info.contentStart)
            let key = RowKey(text: characters, revealed: revealedLines?.contains(line) ?? false, header: line == table.lowerBound)
            let cellWidths = line == delimiterLine ? [] : rowWidths[key] ?? {
                let measured = split.cells.map { visibleWidth(NSRange(location: range.location + $0.location, length: $0.length)) }
                rowWidths[key] = measured
                return measured
            }()
            for (column, width) in cellWidths.enumerated() {
                if column < widths.count { widths[column] = max(widths[column], width) } else { widths.append(width) }
            }
            rows.append(Row(line: line, range: range, split: split, widths: cellWidths, key: key))
        }
        guard let first = rows.first,
              let base = backing.attribute(.paragraphStyle, at: first.range.location, effectiveRange: nil) as? NSParagraphStyle
        else { return .tooWide(.infinity) }

        let padding = (theme.bodyFontSize * 0.75).rounded()
        let indent = base.firstLineHeadIndent
        let naturalWidth = indent + widths.reduce(0) { $0 + ceil($1) + 2 * padding }
        // Too wide for the column, cells wrap: each column gets at least its
        // longest word, and the room left goes to the columns with most text.
        var columns = widths.map { ceil($0) }
        let wraps = naturalWidth > maxImageWidth
        if wraps {
            var minimums = [CGFloat](repeating: 0, count: widths.count)
            for row in rows where row.line != delimiterLine {
                let rowMinimums = rowMinimumWidths[row.key] ?? {
                    let measured = row.split.cells.map { longestWordWidth(NSRange(location: row.range.location + $0.location, length: $0.length)) }
                    rowMinimumWidths[row.key] = measured
                    return measured
                }()
                for (column, width) in rowMinimums.enumerated() where column < minimums.count {
                    minimums[column] = max(minimums[column], ceil(width) + 1)
                }
            }
            let room = maxImageWidth - indent - CGFloat(widths.count) * 2 * padding
            let least = minimums.reduce(0, +)
            guard least <= room else { return .tooWide(indent + least + CGFloat(widths.count) * 2 * padding) }
            let spare = columns.reduce(0, +) - least
            let share = spare > 0 ? (room - least) / spare : 0
            columns = zip(minimums, columns).map { minimum, natural in
                (minimum + max(0, natural - minimum) * min(1, share)).rounded(.down)
            }
        }
        var edges: [CGFloat] = [0]
        for width in columns { edges.append(edges[edges.count - 1] + width + 2 * padding) }
        if let only {
            // The rows left as they are must have their columns where these go.
            guard let other = rows.first(where: { !only.contains($0.line) && $0.line != delimiterLine }),
                  let grid = backing.attribute(.mdTableRow, at: other.range.location, effectiveRange: nil) as? TableGrid,
                  grid.edges == edges, grid.indent == indent
            else { return .columnsChanged }
        }

        let verticalPadding = (theme.bodyFontSize * 0.45).rounded()
        let lineHeight = ceil(Self.lineHeightManager.defaultLineHeight(for: theme.body))
        let height = lineHeight + 2 * verticalPadding
        let alignment = (0..<columns.count).map { column -> CGFloat in
            switch column < alignments.count ? alignments[column] : .none {
            case .center: 0.5
            case .right: 1
            case .none, .left: 0
            }
        }
        for row in rows where only?.contains(row.line) ?? true {
            let isDelimiter = row.line == delimiterLine
            // A wrapping table's delimiter, revealed, is too long for any
            // column: it shows as written, outside the grid.
            if wraps, isDelimiter {
                backing.addAttribute(.mdTableRow, value: true, range: row.range)
                continue
            }

            // Whitespace around cells goes; the pipes stay, invisible, to be
            // kerned, or are concealed as well when the cells wrap.
            // A run of it at a time: one attribute change per character was
            // much of what a keystroke in a long table cost.
            var outside = IndexSet(integersIn: 0..<(isDelimiter ? 0 : row.range.length))
            for cell in row.split.cells { outside.remove(integersIn: cell.location..<NSMaxRange(cell)) }
            for span in outside.rangeView {
                var offset = span.lowerBound
                while offset < span.upperBound {
                    guard Self.isSpaceOrTab(text.character(at: row.range.location + offset)) else {
                        offset += 1
                        continue
                    }
                    var end = offset + 1
                    while end < span.upperBound, Self.isSpaceOrTab(text.character(at: row.range.location + end)) { end += 1 }
                    backing.addAttribute(.mdConcealed, value: true, range: NSRange(location: row.range.location + offset, length: end - offset))
                    offset = end
                }
            }

            let style = (backing.attribute(.paragraphStyle, at: row.range.location, effectiveRange: nil) as? NSParagraphStyle ?? base)
                .mutableCopy() as! NSMutableParagraphStyle
            style.lineHeightMultiple = 1
            style.paragraphSpacingBefore = 0
            let isHeader = row.line == table.lowerBound
            let isLast = row.line == rows[rows.count - 1].line

            if wraps {
                // `TableTypesetter` lays the cells out in their columns.
                for pipe in row.split.pipes {
                    backing.addAttribute(.mdConcealed, value: true, range: NSRange(location: row.range.location + pipe, length: 1))
                }
                style.minimumLineHeight = lineHeight
                style.maximumLineHeight = lineHeight
                style.firstLineHeadIndent = indent
                style.headIndent = indent
                let grid = TableGrid(
                    edges: edges, indent: indent, height: height, isHeader: isHeader, isLast: isLast, isDelimiter: false,
                    naturalWidth: naturalWidth,
                    wrapping: TableGrid.Wrapping(
                        cells: row.split.cells, padding: padding, verticalPadding: verticalPadding,
                        lineHeight: lineHeight, baseline: ceil(Self.lineHeightManager.defaultBaselineOffset(for: theme.body)),
                        alignment: alignment
                    )
                )
                backing.addAttributes([.paragraphStyle: style, .mdTableRow: grid], range: row.range)
                continue
            }

            // Where each cell starts: in its column, as the delimiter aligns it.
            let starts = row.widths.enumerated().map { column, width in
                let slack = columns[column] - width
                return edges[column] + padding + slack * alignment[column]
            }
            var firstIndent: CGFloat = isDelimiter ? padding : 0
            for (column, start) in starts.enumerated() {
                let previousEnd = column == 0 ? 0 : starts[column - 1] + row.widths[column - 1]
                let pipeIndex = row.split.leadingPipe ? column : column - 1
                guard pipeIndex >= 0, pipeIndex < row.split.pipes.count else {
                    firstIndent = start
                    continue
                }
                let pipe = NSRange(location: row.range.location + row.split.pipes[pipeIndex], length: 1)
                let font = backing.attribute(.font, at: pipe.location, effectiveRange: nil) as? NSFont ?? theme.body
                let advance = pipeAdvance(in: font)
                backing.addAttribute(.kern, value: start - previousEnd - advance, range: pipe)
            }
            for pipe in row.split.pipes {
                backing.addAttribute(.foregroundColor, value: NSColor.clear, range: NSRange(location: row.range.location + pipe, length: 1))
            }

            style.minimumLineHeight = height
            style.maximumLineHeight = height
            style.firstLineHeadIndent = indent + firstIndent
            style.headIndent = indent + firstIndent
            let grid = TableGrid(
                edges: edges,
                indent: indent,
                height: height,
                isHeader: isHeader,
                isLast: isLast,
                isDelimiter: isDelimiter
            )
            backing.addAttributes([
                .paragraphStyle: style,
                .mdTableRow: grid,
                // The line's extra height goes above the text; this centres it.
                .baselineOffset: verticalPadding,
            ], range: row.range)
        }
        return .laidOut
    }

    private static func isSpaceOrTab(_ unit: unichar) -> Bool { unit == 0x20 || unit == 0x09 }

    /// How wide `|` is in each font, measured once: every pipe of every row
    /// measured it again on each keystroke.
    private var pipeAdvances: [NSFont: CGFloat] = [:]

    private func pipeAdvance(in font: NSFont) -> CGFloat {
        if let advance = pipeAdvances[font] { return advance }
        let advance = ("|" as NSString).size(withAttributes: [.font: font]).width
        pipeAdvances[font] = advance
        return advance
    }

    /// How wide a range draws: its glyphs less the concealed ones.
    private func visibleWidth(_ range: NSRange) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let visible = NSMutableAttributedString()
        backing.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.mdConcealed] == nil else { return }
            if let emoji = attributes[.mdEmoji] as? String, let font = attributes[.font] as? NSFont,
               let emojiFont = NSFont(name: "AppleColorEmoji", size: font.pointSize) {
                // Drawn as the emoji, in the font `fixAttributes` will give it.
                visible.append(NSAttributedString(string: emoji, attributes: [.font: emojiFont]))
            } else {
                visible.append(backing.attributedSubstring(from: run))
            }
        }
        return visible.size().width
    }

    /// How wide a range's longest word draws, its concealed glyphs left out:
    /// the narrowest a wrapping cell can be.
    private func longestWordWidth(_ range: NSRange) -> CGFloat {
        guard range.length > 0 else { return 0 }
        let visible = NSMutableAttributedString()
        backing.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.mdConcealed] == nil else { return }
            visible.append(backing.attributedSubstring(from: run))
        }
        // Lines break at spaces; a run without one cannot break.
        let string = visible.string as NSString
        var widest: CGFloat = 0
        var start = 0
        for index in 0...string.length where index == string.length || Self.isSpaceOrTab(string.character(at: index)) {
            if index > start {
                widest = max(widest, visible.attributedSubstring(from: NSRange(location: start, length: index - start)).size().width)
            }
            start = index + 1
        }
        return widest
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
                    if MainActor.assumeIsolated({ Typesetter.shared.error(for: request) }) == nil { lineAwaits.insert(.typesetting(request)) }
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

    /// What a marker's attributes depend on, besides the theme.
    private struct MarkerStyle: Hashable {
        var kind: MarkerKind
        var revealed: Bool
        var font: NSFont
        var sourceMode: Bool
    }

    /// Markers' attributes, built once each as a plain dictionary: markers
    /// are most of the attribute runs in a document, and handed a Swift
    /// dictionary, Foundation bridges and hashes every key it looks up,
    /// several times over. Cleared when the theme changes.
    private var markerAttributes: [MarkerStyle: NSDictionary] = [:]

    private func applyMarker(_ marker: Marker, lineStart: Int, revealed: Bool, baseFont: NSFont) {
        let range = NSRange(location: lineStart + marker.range.location, length: marker.range.length)
        guard range.length > 0, NSMaxRange(range) <= backing.length else { return }
        let key = MarkerStyle(kind: marker.kind, revealed: revealed, font: baseFont, sourceMode: sourceMode)
        if let cached = markerAttributes[key] {
            addBackingAttributes(cached, range: range)
            return
        }

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
        let built = NSDictionary(dictionary: attributes)
        markerAttributes[key] = built
        addBackingAttributes(built, range: range)
    }
}

/// A table row's unescaped pipes and its cells' text without the spaces
/// around it, as offsets in the line.
struct TableRowSplit: Equatable {
    var pipes: [Int]
    var cells: [NSRange]
    var leadingPipe: Bool

    init(pipes: [Int], cells: [NSRange], leadingPipe: Bool) {
        self.pipes = pipes
        self.cells = cells
        self.leadingPipe = leadingPipe
    }

    init(_ characters: [UInt16], from start: Int) {
        func isSpace(_ unit: UInt16) -> Bool { unit == 0x20 || unit == 0x09 }
        var pipes: [Int] = []
        var escaped = false
        for offset in start..<max(start, characters.count) {
            if escaped {
                escaped = false
            } else if characters[offset] == 0x5C /* backslash */ {
                escaped = true
            } else if characters[offset] == 0x7C /* pipe */ {
                pipes.append(offset)
            }
        }
        let firstText = characters[min(start, characters.count)...].firstIndex { !isSpace($0) }
        let leadingPipe = firstText.map { pipes.first == $0 } ?? false

        // The stretches between pipes, and before the first and after the last.
        var bounds: [(Int, Int)] = []
        var from = start
        for pipe in pipes {
            if pipe != pipes.first || !leadingPipe { bounds.append((from, pipe)) }
            from = pipe + 1
        }
        let tail = (from, characters.count)
        // Text after the last pipe is a cell; spaces alone are not.
        if pipes.isEmpty || characters[tail.0..<tail.1].contains(where: { !isSpace($0) }) { bounds.append(tail) }

        cells = bounds.map { lower, upper in
            var lower = lower, upper = upper
            while lower < upper, isSpace(characters[lower]) { lower += 1 }
            while upper > lower, isSpace(characters[upper - 1]) { upper -= 1 }
            return NSRange(location: lower, length: upper - lower)
        }
        self.pipes = pipes
        self.leadingPipe = leadingPipe
    }
}
