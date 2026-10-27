import AppKit
import MarkdownKit

/// The editing canvas: one scroll view + text view per document.
///
/// Built on TextKit 1 on purpose. Concealing syntax markers means nulling glyphs
/// and painting block backgrounds, and both are direct overrides on
/// `NSLayoutManager`.
final class EditorViewController: NSViewController {
    let textView: MarkdownTextView
    let scrollView = NSScrollView()

    let storage: MarkdownTextStorage
    /// The document's undo history, which the text view records into.
    let documentUndoManager: UndoManager
    private let layoutManager = MarkdownLayoutManager()
    private let textContainer: NSTextContainer
    private(set) var activeLine: ActiveLineController!
    private var input: MarkdownInputHandler!
    private let codeAccessory = CodeBlockAccessory()
    /// The commands typing `/` offers.
    let slashMenu = SlashMenu()
    private var scrollObserver: NSObjectProtocol?

    private(set) var theme: Theme = .current(for: NSApp.effectiveAppearance)

    /// The clipboard that link commands read and Copy Code writes; a private
    /// one in tests, which the system's is shared with every other process.
    var pasteboard: NSPasteboard = .general

    /// Called when the caret moves, so the window can refresh the status pill.
    var onSelectionChange: (() -> Void)?
    /// Called after every edit, so the window can refresh tab dirty state.
    var onTextChange: (() -> Void)?
    /// Called on Command-click with a link's destination as written.
    var onOpenLink: ((String) -> Void)? {
        get { textView.onOpenLink }
        set { textView.onOpenLink = newValue }
    }

    /// Unhooks this editor's layout from the document, so the document can
    /// move to another window's editor without being laid out twice.
    func detachFromStorage() {
        storage.removeLayoutManager(layoutManager)
    }

    var table: TableEditor { TableEditor(storage: storage, textView: textView) }

    var sourceMode: Bool {
        get { storage.sourceMode }
        set { storage.sourceMode = newValue }
    }

    /// Width of the centred text column.
    var lineWidth: CGFloat = Metrics.defaultLineWidth {
        didSet { view.needsLayout = true }
    }

    init(textStorage: MarkdownTextStorage, undoManager: UndoManager = UndoManager()) {
        storage = textStorage
        documentUndoManager = undoManager
        textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        textView = MarkdownTextView(frame: .zero, textContainer: textContainer)
        super.init(nibName: nil, bundle: nil)
        // Setting up a text view asks it to redraw, and a redraw lays out what
        // it shows. So it goes in its scroll view first (outside one, all of
        // a view sized to fit the text shows) and meets the document last.
        // Otherwise the whole document was laid out here, 9.6 s at 4.5 MB,
        // for a view not yet on screen.
        scrollView.documentView = textView
        configureTextView()
        storage.addLayoutManager(layoutManager)
        input = MarkdownInputHandler(storage: textStorage)
        activeLine = ActiveLineController(storage: textStorage, textView: textView)
        textView.delegate = self
        applySettings(Settings())
        activeLine.typewriterMode = Settings().typewriterDefault
        activeLine.focusMode = Settings().focusDefault
        activeLine.selectionChanged()

        codeAccessory.isHidden = true
        codeAccessory.onChooseLanguage = { [weak self] name in self?.setCodeLanguage(name) }
        codeAccessory.onCopy = { [weak self] in self?.copyCodeBlock() }
        textView.addSubview(codeAccessory)

        slashMenu.onChoose = { [weak self] command in self?.runSlashCommand(command) }
        textView.onLoseFocus = { [weak self] in self?.slashMenu.close() }
        // The menu follows the `/` when the text scrolls under it.
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.slashMenuDidScroll()
            }
        }
    }

    isolated deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        slashMenu.close()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.autohidesScrollers = true
        // The editor starts below the titlebar, so there is nothing to inset for.
        scrollView.automaticallyAdjustsContentInsets = false
        view = scrollView
        applyTheme(theme)
    }

    private func configureTextView() {
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        // Created with a zero frame, the view would otherwise cap its height
        // there and stop scrolling short of the end of a long document.
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.textContainerInset = CGSize(width: 0, height: 28)
        textView.drawsBackground = true

        // Free find bar: Cmd-F, Cmd-G, Cmd-Opt-F replace.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        // Markdown is plain text; smart substitutions corrupt it.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.insertionPointColor = theme.accent
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        // Centre the text column by padding the container, not the text view,
        // so clicks either side of the column still place the caret.
        let available = scrollView.contentSize.width
        let column = min(lineWidth, available - 2 * Metrics.chromeInset)
        let inset = max(Metrics.chromeInset, (available - column) / 2)
        if abs(textView.textContainerInset.width - inset) > 0.5 {
            textView.textContainerInset = CGSize(width: inset, height: textView.textContainerInset.height)
        }
        storage.maxImageWidth = column - 2 * textContainer.lineFragmentPadding
        updateCodeAccessory()
    }

    /// Everything but colours and fonts, which come with the theme.
    func applySettings(_ settings: Settings) {
        lineWidth = settings.lineWidth
        let padding = settings.padding
        if abs(textView.textContainerInset.height - padding) > 0.5 {
            textView.textContainerInset = CGSize(width: textView.textContainerInset.width, height: padding)
        }
        // Markdown is plain text, so substitutions are opt-in; dashes go
        // with quotes because both rewrite what was typed.
        smartQuotes = settings.smartQuotes
        updateSubstitutions()
        textView.isContinuousSpellCheckingEnabled = settings.spellCheck
        pendingExtensions = settings.extensions
        if isOnScreen { applyPendingRestyles() }
        storage.numberHeadings = settings.numberHeadings
    }

    /// A theme and syntax extensions restyle the whole document, so for a
    /// tab not on screen they wait until it shows: an appearance or settings
    /// change restyled every open tab at once, seconds each for a large one.
    private var pendingTheme: Theme?
    private var pendingExtensions: SyntaxExtensions?

    private var isOnScreen: Bool { isViewLoaded && view.window != nil }

    private func applyPendingRestyles() {
        if let extensions = pendingExtensions {
            pendingExtensions = nil
            storage.extensions = extensions
        }
        if let theme = pendingTheme {
            pendingTheme = nil
            storage.theme = theme
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyPendingRestyles()
    }

    private var smartQuotes = false

    /// Smart quotes stay out of code, where `"` must stay `"`.
    private func updateSubstitutions() {
        var enabled = smartQuotes
        if enabled {
            let location = textView.selectedRange().location
            let inBlock = storage.structure.info(forLine: storage.line(at: location))?.kind.isCode ?? false
            let inSpan = location > 0 && location <= storage.length
                && storage.attribute(.mdInlineCode, at: location - 1, effectiveRange: nil) != nil
            enabled = !inBlock && !inSpan
        }
        textView.isAutomaticQuoteSubstitutionEnabled = enabled
        textView.isAutomaticDashSubstitutionEnabled = enabled
    }

    /// `viewDidChangeEffectiveAppearance` is an `NSView` hook, not a controller
    /// one, so the app's appearance is observed directly instead.
    private var appearanceObservation: NSKeyValueObservation?

    override func viewDidAppear() {
        super.viewDidAppear()
        applyPendingRestyles()
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.applyTheme(.current(for: app.effectiveAppearance))
            }
        }
    }

    /// Line and column of the insertion point, both 1-based.
    func caretPosition() -> (line: Int, column: Int) {
        let location = min(textView.selectedRange().location, storage.length)
        let line = storage.line(at: location)
        let lineStart = storage.structure.index.range(ofLine: line).location
        return (line + 1, location - lineStart + 1)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        layoutManager.theme = theme
        scrollView.backgroundColor = theme.canvas
        textView.backgroundColor = theme.canvas
        textView.insertionPointColor = theme.accent
        // What typing starts with, before the storage styles it. Not the text
        // view's font and text colour: in a plain-text view those rewrite
        // every run of the document, wiping the styling (and taking half a
        // minute at 4.5 MB).
        // The paragraph style goes in too: the caret on an empty document, and
        // on the empty last line, is sized from the typing attributes alone, so
        // without it the caret is shorter there than on a styled line.
        let typingStyle = NSMutableParagraphStyle()
        typingStyle.lineHeightMultiple = theme.lineHeight
        typingStyle.tighteningFactorForTruncation = 0
        textView.typingAttributes = [
            .font: theme.body,
            .foregroundColor: theme.text,
            .paragraphStyle: typingStyle.copy() as! NSParagraphStyle,
        ]
        pendingTheme = theme
        if isOnScreen { applyPendingRestyles() }
        textView.selectedTextAttributes = [
            .backgroundColor: theme.accent.withAlphaComponent(0.25),
        ]
        codeAccessory.applyTheme(theme)
    }

    // MARK: - Code block accessory

    /// The block the caret is in, if any.
    private var currentCodeBlock: CodeBlock? {
        CodeBlock.containing(line: storage.line(at: textView.selectedRange().location), in: storage)
    }

    /// Pins the accessory to the top-right of the caret's code block, or hides it.
    func updateCodeAccessory() {
        guard let block = currentCodeBlock else {
            codeAccessory.isHidden = true
            return
        }
        // The opening fence's newline is never concealed, so its glyph sits
        // on the fence's own line fragment.
        var lineRange = storage.structure.index.range(ofLine: block.openLine)
        // A concealed fence sits above the card, which starts at the code:
        // pinned to the fence, the bar would stick out over the card's top.
        if !block.isIndented, lineRange.length > 0, block.openLine + 1 < (block.closeLine ?? storage.structure.lineCount),
           layoutManager.propertyForGlyph(at: layoutManager.glyphIndexForCharacter(at: lineRange.location)).contains(.null) {
            lineRange = storage.structure.index.range(ofLine: block.openLine + 1)
        }
        let anchor = max(lineRange.location, NSMaxRange(lineRange) - 1)
        guard anchor < storage.length else {
            codeAccessory.isHidden = true
            return
        }
        codeAccessory.show(language: block.info)
        let glyph = layoutManager.glyphIndexForCharacter(at: anchor)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let size = codeAccessory.fittingSize
        let origin = textView.textContainerOrigin
        codeAccessory.frame = NSRect(
            x: origin.x + textContainer.size.width - textContainer.lineFragmentPadding - size.width - 4,
            y: origin.y + fragment.minY + max(0, (fragment.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
        codeAccessory.isHidden = false
    }

    func setCodeLanguage(_ name: String) {
        guard let block = currentCodeBlock else { return }
        let selection = textView.selectedRange()
        if block.isIndented {
            fenceIndentedBlock(block, language: name, selection: selection)
            return
        }
        guard textView.replaceAsUndoStep(block.infoRange, with: name, actionName: String(localized: "Set Language")) else { return }
        // Keep the caret where it was, shifted by however much the fence line changed.
        let delta = (name as NSString).length - block.infoRange.length
        let location = selection.location >= NSMaxRange(block.infoRange) ? selection.location + delta : selection.location
        textView.setSelectedRange(NSRange(location: max(0, location), length: selection.length))
        updateCodeAccessory()
    }

    /// An indented block has nowhere to name its language, so choosing one
    /// fences it: its lines lose their indentation and sit between fences.
    private func fenceIndentedBlock(_ block: CodeBlock, language: String, selection: NSRange) {
        guard !language.isEmpty, let closeLine = block.closeLine else { return }
        let structure = storage.structure
        let text = storage.text
        let start = structure.index.range(ofLine: block.openLine).location
        let end = NSMaxRange(structure.index.contentRange(ofLine: closeLine, in: text))
        let opening = "```" + language + "\n"
        var code: [String] = []
        // Where the caret goes: the same place in its line, less the indentation.
        var caret = selection.location
        var offset = (opening as NSString).length
        for line in block.openLine...closeLine {
            let content = structure.index.contentRange(ofLine: line, in: text)
            let (dedented, removed) = CodeBlock.dedented(Substring(text.substring(with: content)))
            if selection.location >= content.location, selection.location <= NSMaxRange(content) {
                caret = start + offset + max(0, selection.location - content.location - removed)
            }
            code.append(String(dedented))
            offset += (String(dedented) as NSString).length + 1
        }
        let fenced = opening + code.joined(separator: "\n") + "\n```"
        guard textView.replaceAsUndoStep(NSRange(location: start, length: end - start), with: fenced, actionName: String(localized: "Set Language")) else { return }
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        updateCodeAccessory()
    }

    private func copyCodeBlock() {
        guard let block = currentCodeBlock else { return }
        pasteboard.clearContents()
        pasteboard.setString(block.code(in: storage), forType: .string)
    }
}


extension EditorViewController: NSTextViewDelegate {
    func undoManager(for view: NSTextView) -> UndoManager? {
        documentUndoManager
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if handleSlashMenuKey(commandSelector) { return true }
        // Several carets type plainly: no list continuation or pairing.
        if self.textView.hasMultipleTargets { return false }
        return input.handleCommand(commandSelector, in: textView)
    }

    /// Typing a delimiter with text selected wraps it instead of replacing it.
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        // Pasted or dropped text keeps its own line endings; the editor's
        // lines break at `\n` alone, as the parser counts them.
        if let replacementString, replacementString.contains("\r"), !self.textView.isEditingAtCarets {
            let normalized = replacementString
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            textView.insertText(normalized, replacementRange: affectedCharRange)
            return false
        }
        // Composed text, and the character that ends a composition, replace
        // the marked text: pairing or wrapping it would double it.
        guard let replacementString, !self.textView.isEditingAtCarets, !self.textView.isReplacingAsCommand,
              !self.textView.hasMultipleTargets, !self.textView.isSettingMarkedText, !self.textView.hasMarkedText()
        else { return true }
        if replacementString == "/", affectedCharRange.length == 0, canStartSlashCommand(at: affectedCharRange.location) {
            slashMenu.pendingStart = affectedCharRange.location
        }
        return !input.handleInsertion(of: replacementString, in: textView, range: affectedCharRange)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        activeLine.selectionChanged()
        updateSubstitutions()
        onSelectionChange?()
        updateCodeAccessory()
        slashMenuSelectionDidChange()
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?()
        updateCodeAccessory()
        slashMenuTextDidChange()
    }
}
