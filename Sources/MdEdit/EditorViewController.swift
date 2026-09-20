import AppKit

/// The editing canvas: one scroll view + text view per document.
///
/// Built on TextKit 1 on purpose. Concealing syntax markers means nulling glyphs
/// and painting block backgrounds, and both are direct overrides on
/// `NSLayoutManager`.
final class EditorViewController: NSViewController {
    let textView: NSTextView
    let scrollView = NSScrollView()

    let storage: MarkdownTextStorage
    private let layoutManager = MarkdownLayoutManager()
    private let textContainer: NSTextContainer
    private(set) var activeLine: ActiveLineController!
    private var input: MarkdownInputHandler!

    private(set) var theme: Theme = .current(for: NSApp.effectiveAppearance)

    /// Called when the caret moves, so the window can refresh the status pill.
    var onSelectionChange: (() -> Void)?
    /// Called after every edit, so the window can refresh tab dirty state.
    var onTextChange: (() -> Void)?

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

        textView = NSTextView(frame: .zero, textContainer: textContainer)
        super.init(nibName: nil, bundle: nil)
        configureTextView()
        input = MarkdownInputHandler(storage: textStorage)
        activeLine = ActiveLineController(storage: textStorage, textView: textView)
        textView.delegate = self
        activeLine.selectionChanged()
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
        textView.isContinuousSpellCheckingEnabled = true
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
    }
}


extension EditorViewController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        input.handleCommand(commandSelector, in: textView)
    }

    /// Typing a delimiter with text selected wraps it instead of replacing it.
    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard let replacementString, affectedCharRange.length > 0 else { return true }
        return !input.handleInsertion(of: replacementString, in: textView, range: affectedCharRange)
    }

    /// Command-click opens a link; a plain click just places the caret.
    func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        menu
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        activeLine.selectionChanged()
        onSelectionChange?()
    }

    func textDidChange(_ notification: Notification) {
        onTextChange?()
    }
}
