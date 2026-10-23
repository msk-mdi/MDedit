import AppKit
import MarkdownKit
import UniformTypeIdentifiers

/// One entry in the menu that typing `/` opens: a block to turn the line
/// into, or one to insert.
struct SlashCommand: Equatable {
    enum Action: Equatable {
        case heading(Int)
        case bulletList, numberedList, taskList, quote
        case codeBlock, mermaid, mathBlock, table, divider
        case link, image, footnote, tableOfContents
    }

    let action: Action
    let title: String
    /// Other words that find it.
    let keywords: [String]
    let symbol: String
    /// The markdown it writes, shown beside the title.
    let hint: String

    /// Every command, in menu order. Math is left out when it is turned off.
    static func all(extensions: SyntaxExtensions) -> [SlashCommand] {
        var commands = [
            SlashCommand(action: .heading(1), title: String(localized: "Heading 1"), keywords: ["h1", "title"], symbol: "1.square", hint: "#"),
            SlashCommand(action: .heading(2), title: String(localized: "Heading 2"), keywords: ["h2", "subtitle"], symbol: "2.square", hint: "##"),
            SlashCommand(action: .heading(3), title: String(localized: "Heading 3"), keywords: ["h3"], symbol: "3.square", hint: "###"),
            SlashCommand(action: .bulletList, title: String(localized: "Bulleted List"), keywords: ["ul", "unordered", "bullet"], symbol: "list.bullet", hint: "-"),
            SlashCommand(action: .numberedList, title: String(localized: "Numbered List"), keywords: ["ol", "ordered"], symbol: "list.number", hint: "1."),
            SlashCommand(action: .taskList, title: String(localized: "Task List"), keywords: ["todo", "checkbox", "checklist"], symbol: "checklist", hint: "- [ ]"),
            SlashCommand(action: .quote, title: String(localized: "Blockquote"), keywords: ["quote"], symbol: "text.quote", hint: ">"),
            SlashCommand(action: .codeBlock, title: String(localized: "Code Block"), keywords: ["code", "fence", "pre"], symbol: "chevron.left.forwardslash.chevron.right", hint: "```"),
            SlashCommand(action: .table, title: String(localized: "Table"), keywords: ["grid"], symbol: "tablecells", hint: "| |"),
            SlashCommand(action: .divider, title: String(localized: "Divider"), keywords: ["hr", "horizontal rule", "line", "separator"], symbol: "minus", hint: "---"),
            SlashCommand(action: .link, title: String(localized: "Link"), keywords: ["url"], symbol: "link", hint: "[]()"),
            SlashCommand(action: .image, title: String(localized: "Image…"), keywords: ["picture", "photo", "img"], symbol: "photo", hint: "![]()"),
            SlashCommand(action: .mathBlock, title: String(localized: "Math Block"), keywords: ["equation", "latex", "tex", "katex"], symbol: "function", hint: "$$"),
            SlashCommand(action: .mermaid, title: String(localized: "Mermaid Diagram"), keywords: ["diagram", "chart", "flowchart", "graph"], symbol: "point.3.connected.trianglepath.dotted", hint: "```mermaid"),
            SlashCommand(action: .footnote, title: String(localized: "Footnote"), keywords: ["note", "reference"], symbol: "text.append", hint: "[^1]"),
            SlashCommand(action: .tableOfContents, title: String(localized: "Table of Contents"), keywords: ["toc", "outline"], symbol: "list.bullet.indent", hint: "toc"),
        ]
        for level in 4...6 {
            commands.append(SlashCommand(
                action: .heading(level), title: String(localized: "Heading \(level)"), keywords: ["h\(level)"],
                symbol: "\(level).square", hint: String(repeating: "#", count: level)
            ))
        }
        if !extensions.contains(.math) { commands.removeAll { $0.action == .mathBlock } }
        return commands
    }

    /// How well what was typed after the `/` matches: 0 when it starts the
    /// title, 1 when it starts one of its words, 2 for a keyword, nil for none.
    func rank(_ query: String) -> Int? {
        let query = query.lowercased()
        guard !query.isEmpty else { return 0 }
        let title = title.lowercased()
        if title.hasPrefix(query) || title.replacingOccurrences(of: " ", with: "").hasPrefix(query) { return 0 }
        if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 1 }
        if keywords.contains(where: { $0.hasPrefix(query) }) { return 2 }
        return nil
    }

    /// The commands a query finds, best first, in menu order within a rank.
    static func matching(_ query: String, extensions: SyntaxExtensions) -> [SlashCommand] {
        all(extensions: extensions).enumerated()
            .compactMap { index, command in command.rank(query).map { (rank: $0, index: index, command: command) } }
            .sorted { ($0.rank, $0.index) < ($1.rank, $1.index) }
            .map(\.command)
    }
}

// MARK: - The menu

/// The list of commands under the caret. It never takes the keyboard: the
/// editor keeps typing the query, and hands over the arrows, Return, Tab
/// and Escape while it shows.
@MainActor
final class SlashMenu: NSObject {
    var onChoose: ((SlashCommand) -> Void)?

    /// Where the `/` is, while the menu is open.
    var start: Int?
    /// Where a `/` is being typed, until the edit lands and the menu opens.
    var pendingStart: Int?
    /// Where typing left the caret. Moving it anywhere else closes the menu.
    var caret = 0
    private(set) var commands: [SlashCommand] = []
    private(set) var selectedIndex = 0

    var isActive: Bool { start != nil }
    var isShowing: Bool { panel.isVisible }

    private static let rowHeight: CGFloat = 36
    private static let width: CGFloat = 300
    private static let visibleRows = 8
    private static let margin: CGFloat = 6

    let panel: NSPanel
    private let table = HoverTable()
    private var height: CGFloat = 0
    private weak var observedWindow: NSWindow?

    /// A panel that never becomes key, so the caret stays in the editor.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    override init() {
        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.panel = panel
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        buildContent()
    }

    private func buildContent() {
        let content = NSVisualEffectView()
        content.material = .menu
        content.state = .active
        // A mask rather than a layer's corner radius, so the window's shadow
        // follows the rounded corners.
        content.maskImage = Self.roundedMask(radius: 12)

        table.addTableColumn(NSTableColumn(identifier: .init("command")))
        table.headerView = nil
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        // Plain: the inset style pads the rows with space of its own, which
        // the panel's height does not count, and cut off a lone row.
        table.style = .plain
        table.backgroundColor = .clear
        table.onHover = { [weak self] row in self?.hover(row) }
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel(String(localized: "Insert"))

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsetsZero
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: Self.margin),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Self.margin),
        ])
        panel.contentView = content
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = 2 * radius + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    /// Shows these commands next to the `/`, a screen rectangle, keeping the
    /// chosen one when it is still listed.
    func update(_ commands: [SlashCommand], at anchor: NSRect?, in window: NSWindow?) {
        let chosen = self.commands.indices.contains(selectedIndex) ? self.commands[selectedIndex] : nil
        self.commands = commands
        selectedIndex = chosen.flatMap { commands.firstIndex(of: $0) } ?? 0
        table.reloadData()
        selectRow()

        guard !commands.isEmpty else { return hide() }
        height = CGFloat(min(commands.count, Self.visibleRows)) * Self.rowHeight + 2 * Self.margin
        // Without a window (as in tests) there is nowhere to show it.
        guard let window, let anchor else { return }
        place(at: anchor, in: window)

        if panel.parent !== window {
            panel.parent?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
        }
        // Opening, the menu fades up out of the line rather than popping in.
        if !panel.isVisible, Motion.isEnabled {
            panel.alphaValue = 0
            panel.orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.quick
                context.timingFunction = Motion.curve
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
            panel.orderFront(nil)
        }
        panel.invalidateShadow()
        if observedWindow !== window {
            stopObserving()
            observedWindow = window
            NotificationCenter.default.addObserver(self, selector: #selector(windowResigned), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    /// Keeps the menu by the `/` as the text scrolls.
    func move(to anchor: NSRect, in window: NSWindow) {
        guard panel.isVisible else { return }
        place(at: anchor, in: window)
    }

    private func place(at anchor: NSRect, in window: NSWindow) {
        let visible = window.screen?.visibleFrame ?? window.frame
        var origin = NSPoint(x: anchor.minX - 10, y: anchor.minY - 4 - height)
        // Above the line when there is no room below it.
        if origin.y < visible.minY { origin.y = anchor.maxY + 4 }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - Self.width)
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Self.width, height: height)), display: true)
    }

    func close() {
        start = nil
        pendingStart = nil
        commands = []
        selectedIndex = 0
        table.reloadData()
        hide()
    }

    private func hide() {
        stopObserving()
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func moveSelection(by delta: Int) {
        guard !commands.isEmpty else { return }
        // Wraps around, as menus do.
        selectedIndex = (selectedIndex + delta + commands.count) % commands.count
        selectRow()
        NSAccessibility.post(
            element: table,
            notification: .announcementRequested,
            userInfo: [.announcement: commands[selectedIndex].title, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }

    func chooseSelection() {
        guard commands.indices.contains(selectedIndex) else { return }
        onChoose?(commands[selectedIndex])
    }

    private func selectRow() {
        guard commands.indices.contains(selectedIndex) else { return }
        table.selectRowIndexes(IndexSet(integer: selectedIndex), byExtendingSelection: false)
        table.scrollRowToVisible(selectedIndex)
    }

    /// The pointer picks the row it is over, as in a menu.
    private func hover(_ row: Int) {
        guard commands.indices.contains(row), row != selectedIndex else { return }
        selectedIndex = row
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    @objc private func clicked() {
        guard commands.indices.contains(table.clickedRow) else { return }
        selectedIndex = table.clickedRow
        chooseSelection()
    }

    @objc private func windowResigned() {
        close()
    }

    private func stopObserving() {
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: observedWindow)
        }
        observedWindow = nil
    }
}

extension SlashMenu: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        commands.count
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        RowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        Cell(commands[row])
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if table.selectedRow >= 0 { selectedIndex = table.selectedRow }
    }

    /// The chosen row is a soft rounded wash, as in Notion's menus, so its
    /// icon tile and text keep their colours.
    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool {
            get { false }
            set {}
        }

        override func drawSelection(in dirtyRect: NSRect) {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: Metrics.rowInset, dy: 1),
                xRadius: Metrics.rowRadius,
                yRadius: Metrics.rowRadius
            ).fill()
        }
    }

    private final class Cell: NSTableCellView {
        private let hint: NSTextField

        init(_ command: SlashCommand) {
            hint = NSTextField(labelWithString: command.hint)
            super.init(frame: .zero)
            let icon = NSImageView(image: NSImage(systemSymbolName: command.symbol, accessibilityDescription: nil) ?? NSImage())
            icon.symbolConfiguration = .init(pointSize: 13, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            icon.translatesAutoresizingMaskIntoConstraints = false
            // Each command's symbol sits on a small tile, as Notion's blocks do.
            let tile = IconTile()
            tile.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(icon)
            let title = NSTextField(labelWithString: command.title)
            title.font = .systemFont(ofSize: 13, weight: .medium)
            title.lineBreakMode = .byTruncatingTail
            hint.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            hint.textColor = .secondaryLabelColor
            hint.setContentCompressionResistancePriority(.required, for: .horizontal)
            imageView = icon
            textField = title

            let stack = NSStackView(views: [tile, title, NSView(), hint])
            stack.orientation = .horizontal
            stack.spacing = 10
            stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 14)
            stack.translatesAutoresizingMaskIntoConstraints = false
            addSubview(stack)
            NSLayoutConstraint.activate([
                tile.widthAnchor.constraint(equalToConstant: 26),
                tile.heightAnchor.constraint(equalToConstant: 26),
                icon.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                stack.leadingAnchor.constraint(equalTo: leadingAnchor),
                stack.trailingAnchor.constraint(equalTo: trailingAnchor),
                stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setAccessibilityLabel(command.title)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    }

    /// A rounded square behind a command's symbol, raised off the menu.
    private final class IconTile: NSView {
        override var wantsUpdateLayer: Bool { true }

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 0.5
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        // Resolved here so the tile follows light and dark.
        override func updateLayer() {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

/// A table that reports the row under the pointer.
private final class HoverTable: NSTableView {
    var onHover: ((Int) -> Void)?
    private var tracking: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        onHover?(row(at: convert(event.locationInWindow, from: nil)))
    }
}

// MARK: - The editor's side

extension EditorViewController {
    /// A `/` opens the menu where a word could start: at the start of a
    /// line or after a space, and never in code.
    func canStartSlashCommand(at location: Int) -> Bool {
        let text = storage.text
        if location > 0 {
            guard let previous = Unicode.Scalar(text.character(at: location - 1)),
                  CharacterSet.whitespacesAndNewlines.contains(previous) else { return false }
        }
        let line = storage.line(at: location)
        if storage.structure.info(forLine: line)?.kind.isCode ?? false { return false }
        if location > 0, storage.attribute(.mdInlineCode, at: location - 1, effectiveRange: nil) != nil { return false }
        return true
    }

    /// What follows the `/` up to the caret, while it still reads as a
    /// command being typed: a few short words, with the caret at their end.
    private func slashQuery(from start: Int) -> String? {
        let text = storage.text
        let selection = textView.selectedRange()
        guard selection.length == 0, !textView.hasMultipleTargets,
              start < text.length, text.character(at: start) == 0x2F,
              selection.location > start, selection.location - start <= 32
        else { return nil }
        let query = text.substring(with: NSRange(location: start + 1, length: selection.location - start - 1))
        // Spaces may follow, as in "heading 1": a space that matches nothing
        // only hides the menu, so deleting it shows it again. A space right
        // after the `/`, a tab, or a line break was prose.
        guard query.first?.isWhitespace != true,
              !query.contains(where: { ($0.isWhitespace && $0 != " ") || $0.isNewline || $0 == "/" })
        else { return nil }
        return query
    }

    /// Opens, narrows or closes the menu after an edit, once the text and
    /// the caret are both final.
    func slashMenuTextDidChange() {
        if let pending = slashMenu.pendingStart {
            slashMenu.pendingStart = nil
            slashMenu.start = pending
        }
        guard let start = slashMenu.start else { return }
        guard let query = slashQuery(from: start) else { return slashMenu.close() }
        // With nothing matching, the menu hides but waits: Backspace may
        // bring the query back to something it knows.
        let matches = SlashCommand.matching(query, extensions: storage.extensions)
        slashMenu.caret = textView.selectedRange().location
        slashMenu.update(matches, at: slashAnchor(start), in: textView.window)
    }

    /// Closes the menu when the caret goes anywhere typing did not put it:
    /// an arrow key, a click, a selection.
    ///
    /// Checked once the event is over, not as the selection changes: an
    /// edit moves the selection on its way, as Backspace selects the
    /// character it then deletes.
    func slashMenuSelectionDidChange() {
        guard slashMenu.isActive || slashMenu.pendingStart != nil else { return }
        RunLoop.main.perform { [weak self] in
            MainActor.assumeIsolated { self?.checkSlashMenuCaret() }
        }
    }

    private func checkSlashMenuCaret() {
        // A `/` whose edit never landed opens nothing.
        slashMenu.pendingStart = nil
        guard slashMenu.isActive else { return }
        if textView.selectedRange() != NSRange(location: slashMenu.caret, length: 0) || textView.hasMultipleTargets {
            slashMenu.close()
        }
    }

    /// Keeps the menu by its `/` as the text scrolls.
    func slashMenuDidScroll() {
        guard let start = slashMenu.start, let window = textView.window, let anchor = slashAnchor(start) else { return }
        slashMenu.move(to: anchor, in: window)
    }

    /// The `/` on screen.
    private func slashAnchor(_ start: Int) -> NSRect? {
        guard textView.window != nil, start <= storage.length else { return nil }
        return textView.firstRect(forCharacterRange: NSRange(location: start, length: 0), actualRange: nil)
    }

    /// The arrows, Return, Tab and Escape, while the menu shows.
    func handleSlashMenuKey(_ selector: Selector) -> Bool {
        guard slashMenu.isShowing || (slashMenu.isActive && !slashMenu.commands.isEmpty) else { return false }
        switch selector {
        case #selector(NSResponder.moveUp(_:)): slashMenu.moveSelection(by: -1)
        case #selector(NSResponder.moveDown(_:)): slashMenu.moveSelection(by: 1)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): slashMenu.chooseSelection()
        // Escape closes the menu and leaves what was typed.
        case #selector(NSResponder.cancelOperation(_:)): slashMenu.close()
        default: return false
        }
        return true
    }

    /// Removes the typed `/command`, then does what it names. In the app both
    /// fall in the same event, so they undo together.
    func runSlashCommand(_ command: SlashCommand) {
        guard let start = slashMenu.start else { return }
        let caret = textView.selectedRange().location
        slashMenu.close()
        guard caret >= start,
              textView.replaceAsUndoStep(NSRange(location: start, length: caret - start), with: "", actionName: nil)
        else { return }
        textView.setSelectedRange(NSRange(location: start, length: 0))

        switch command.action {
        case let .heading(level):
            keepingCaretFromLineEnd { setHeading(level: level) }
        case .bulletList, .numberedList, .taskList:
            let ordered = command.action == .numberedList
            let task = command.action == .taskList
            // Toggling would take the marker off a line that has it already.
            if case let .listItem(isOrdered, taskState) = caretLineInfo?.kind,
               isOrdered == ordered, (taskState != nil) == task { return }
            keepingCaretFromLineEnd { toggleList(ordered: ordered, task: task) }
        case .quote:
            if (caretLineInfo?.quoteDepth ?? 0) > 0 { return }
            keepingCaretFromLineEnd { toggleQuote() }
        case .codeBlock:
            insertBlock("```\n\n```", caret: 4, actionName: String(localized: "Code Block"))
        case .mermaid:
            insertBlock("```mermaid\n\n```", caret: 11, actionName: String(localized: "Mermaid Diagram"))
        case .mathBlock:
            insertBlock("$$\n\n$$", caret: 3, actionName: String(localized: "Math Block"))
        case .divider:
            insertBlock("---\n", caret: 4, actionName: String(localized: "Divider"))
        case .table:
            table.insertTable()
        case .tableOfContents:
            insertTableOfContents()
        case .link:
            insertEmptyLink()
        case .image:
            chooseImages()
        case .footnote:
            insertFootnote()
        }
    }

    private var caretLineInfo: LineInfo? {
        storage.structure.info(forLine: storage.line(at: textView.selectedRange().location))
    }

    /// Runs a command that rewrites the caret's line, then puts the caret as
    /// far from the end of the line as it was, past any marker it added.
    private func keepingCaretFromLineEnd(_ body: () -> Void) {
        let caret = textView.selectedRange().location
        let line = storage.line(at: caret)
        let fromEnd = NSMaxRange(storage.structure.index.contentRange(ofLine: line, in: storage.text)) - caret
        body()
        let content = storage.structure.index.contentRange(ofLine: line, in: storage.text)
        textView.setSelectedRange(NSRange(location: max(content.location, NSMaxRange(content) - fromEnd), length: 0))
    }

    /// Puts a block on the caret's line when it is empty, or after it, with
    /// blank lines around it so it does not join the text beside it.
    func insertBlock(_ block: String, caret offset: Int, actionName: String) {
        let text = storage.text
        let line = storage.line(at: textView.selectedRange().location)
        let lineRange = storage.structure.index.contentRange(ofLine: line, in: text)
        let info = storage.structure.info(forLine: line)
        // An empty list item or quote counts as empty: the block replaces it.
        let isEmpty = text.substring(with: lineRange).trimmingCharacters(in: .whitespaces).isEmpty
            || (info.map { $0.kind != .blank && $0.contentStart >= lineRange.length } ?? false)

        let replaceRange = isEmpty ? lineRange : NSRange(location: NSMaxRange(lineRange), length: 0)
        var prefix = isEmpty ? "" : "\n\n"
        if isEmpty, line > 0, storage.structure.info(forLine: line - 1)?.kind != .blank {
            prefix = "\n"
        }
        let followsText = NSMaxRange(lineRange) < text.length
            && storage.structure.info(forLine: line + 1).map { $0.kind != .blank } ?? false
        let replacement = prefix + block + (followsText ? "\n" : "")
        replace(
            replaceRange,
            with: replacement,
            select: NSRange(location: replaceRange.location + (prefix as NSString).length + offset, length: 0),
            actionName: actionName
        )
    }

    /// `[]()` with the caret on the text, and the clipboard's URL, if it
    /// holds one, already in place.
    private func insertEmptyLink() {
        let location = textView.selectedRange().location
        let clipboard = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let destination = looksLikeURL(clipboard) ? clipboard : ""
        replace(
            NSRange(location: location, length: 0),
            with: "[](\(destination))",
            select: NSRange(location: location + 1, length: 0),
            actionName: String(localized: "Link")
        )
    }

    /// Asks for image files and links them at the caret, as dropping them would.
    private func chooseImages() {
        guard let window = textView.window else { return }
        let location = textView.selectedRange().location
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.directoryURL = textView.documentURL()?.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, !panel.urls.isEmpty else { return }
            let markdown = panel.urls
                .map { ImageImporter.markdown(forImageAt: $0, documentURL: self.textView.documentURL()) }
                .joined(separator: "\n")
            let at = min(location, storage.length)
            replace(
                NSRange(location: at, length: 0),
                with: markdown,
                select: NSRange(location: at + (markdown as NSString).length, length: 0),
                actionName: String(localized: "Insert Image")
            )
            window.makeFirstResponder(textView)
        }
    }

    /// `[^n]` at the caret, with the lowest number not yet used, and its
    /// definition started at the end of the document, where the caret goes.
    func insertFootnote() {
        let text = storage.string
        let used = Set(text.matches(of: /\[\^(\d+)\]/).compactMap { Int($0.output.1) })
        let number = (1...).first { !used.contains($0) }!
        let reference = "[^\(number)]"
        let location = textView.selectedRange().location
        guard textView.replaceAsUndoStep(NSRange(location: location, length: 0), with: reference, actionName: String(localized: "Footnote")) else { return }

        let updated = storage.string
        let separator = updated.isEmpty || updated.hasSuffix("\n\n") ? "" : updated.hasSuffix("\n") ? "\n" : "\n\n"
        let definition = separator + "\(reference): "
        let end = (updated as NSString).length
        replace(
            NSRange(location: end, length: 0),
            with: definition,
            select: NSRange(location: end + (definition as NSString).length, length: 0),
            actionName: String(localized: "Footnote")
        )
        textView.scrollRangeToVisible(textView.selectedRange())
    }
}
