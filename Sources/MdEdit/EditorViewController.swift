import AppKit

/// The editing canvas: one scroll view + text view per document.
///
/// Built on TextKit 1 on purpose. Concealing syntax markers means nulling glyphs
/// and painting block backgrounds, and both are direct overrides on
/// `NSLayoutManager`.
final class EditorViewController: NSViewController {
    let textView: MarkdownTextView
    let scrollView = NSScrollView()

    let storage: MarkdownTextStorage
    private let layoutManager = MarkdownLayoutManager()
    private let textContainer: NSTextContainer
    private(set) var activeLine: ActiveLineController!
    private var input: MarkdownInputHandler!
    private let codeAccessory = CodeBlockAccessory()

    private(set) var theme: Theme = .current(for: NSApp.effectiveAppearance)

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

    init(textStorage: MarkdownTextStorage) {
        storage = textStorage
        textContainer = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false

        textView = MarkdownTextView(frame: .zero, textContainer: textContainer)
        super.init(nibName: nil, bundle: nil)
        configureTextView()
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.autohidesScrollers = true
        // Lets text scroll under the glass chrome instead of starting below it.
        scrollView.automaticallyAdjustsContentInsets = true
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
        storage.extensions = settings.extensions
        storage.numberHeadings = settings.numberHeadings
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
        guard appearanceObservation == nil else { return }
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] app, _ in
            DispatchQueue.main.async {
                self?.applyTheme(.current(for: app.effectiveAppearance))
            }
        }
    }

    /// Line and column of the insertion point, both 1-based.
    func caretPosition() -> (line: Int, column: Int) {
        let text = textView.string as NSString
        let location = min(textView.selectedRange().location, text.length)
        var line = 1
        var lineStart = 0
        var index = 0
        while index < location {
            let range = text.lineRange(for: NSRange(location: index, length: 0))
            if NSMaxRange(range) > location { lineStart = range.location; break }
            index = NSMaxRange(range)
            lineStart = index
            line += 1
        }
        return (line, location - lineStart + 1)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        layoutManager.theme = theme
        scrollView.backgroundColor = theme.canvas
        textView.backgroundColor = theme.canvas
        textView.insertionPointColor = theme.accent
        textView.font = theme.body
        textView.textColor = theme.text
        storage.theme = theme
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
        let lineRange = storage.structure.index.range(ofLine: block.openLine)
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

    private func setCodeLanguage(_ name: String) {
        guard let block = currentCodeBlock else { return }
        let selection = textView.selectedRange()
        guard textView.shouldChangeText(in: block.infoRange, replacementString: name) else { return }
        textView.insertText(name, replacementRange: block.infoRange)
        // Keep the caret where it was, shifted by however much the fence line changed.
        let delta = (name as NSString).length - block.infoRange.length
        let location = selection.location >= NSMaxRange(block.infoRange) ? selection.location + delta : selection.location
        textView.setSelectedRange(NSRange(location: max(0, location), length: selection.length))
        updateCodeAccessory()
    }

    private func copyCodeBlock() {
        guard let block = currentCodeBlock else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(block.code(in: storage), forType: .string)
    }
}


extension EditorViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
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
        guard let replacementString, !self.textView.isEditingAtCarets, !self.textView.hasMultipleTargets else { return true }
        return !input.handleInsertion(of: replacementString, in: textView, range: affectedCharRange)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        activeLine.selectionChanged()
        updateSubstitutions()
        onSelectionChange?()
        updateCodeAccessory()
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?()
        updateCodeAccessory()
    }
}
