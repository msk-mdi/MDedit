import AppKit
import MarkdownKit

/// The Settings window: three tabs of controls over `Settings`. Every change
/// is written at once and open editors restyle from `Settings.didChange`.
@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    private let settings = Settings()

    // Appearance
    private let themePopup = NSPopUpButton()
    private let themeWarnings = NSTextField(wrappingLabelWithString: "")
    private let codeThemePopup = NSPopUpButton()
    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let sizeStepper = NSStepper()
    private let monoFontPopup = NSPopUpButton()

    // Editor
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")
    private let lineHeightSlider = NSSlider()
    private let lineHeightLabel = NSTextField(labelWithString: "")
    private let spacingSlider = NSSlider()
    private let spacingLabel = NSTextField(labelWithString: "")
    private let paddingSlider = NSSlider()
    private let paddingLabel = NSTextField(labelWithString: "")
    private let autoPairBox = NSButton(checkboxWithTitle: String(localized: "Close brackets and backticks automatically"), target: nil, action: nil)
    private let smartQuotesBox = NSButton(checkboxWithTitle: String(localized: "Use smart quotes and dashes (never in code)"), target: nil, action: nil)
    private let spellCheckBox = NSButton(checkboxWithTitle: String(localized: "Check spelling while typing"), target: nil, action: nil)
    private let updatesBox = NSButton(checkboxWithTitle: String(localized: "Check for updates once a day"), target: nil, action: nil)
    private let typewriterBox = NSButton(checkboxWithTitle: String(localized: "Typewriter Mode"), target: nil, action: nil)
    private let focusBox = NSButton(checkboxWithTitle: String(localized: "Focus Mode"), target: nil, action: nil)

    // Markdown
    private let extensionBoxes: [(SyntaxExtensions, NSButton)] = [
        (.highlight, NSButton(checkboxWithTitle: String(localized: "==Highlight=="), target: nil, action: nil)),
        (.scripts, NSButton(checkboxWithTitle: String(localized: "^Superscript^ and ~subscript~"), target: nil, action: nil)),
        (.emoji, NSButton(checkboxWithTitle: String(localized: ":emoji: shortcodes"), target: nil, action: nil)),
        (.math, NSButton(checkboxWithTitle: String(localized: "$Math$ and $$display math$$"), target: nil, action: nil)),
        (.bareURLs, NSButton(checkboxWithTitle: String(localized: "Links from bare https:// and www. addresses"), target: nil, action: nil)),
        (.definitionLists, NSButton(checkboxWithTitle: String(localized: "Definition lists (Term, then : definition)"), target: nil, action: nil)),
    ]
    private let bulletPopup = NSPopUpButton()
    private let numberingPopup = NSPopUpButton()
    private let numberHeadingsBox = NSButton(checkboxWithTitle: String(localized: "Number headings (1, 1.1, 1.2…) in the editor and export"), target: nil, action: nil)

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = String(localized: "Settings")
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
    }

    override func showWindow(_ sender: Any?) {
        // Theme files may have come or gone since last time.
        reloadThemes()
        super.showWindow(sender)
        window?.center()
    }

    // MARK: - Layout

    private func buildContent() {
        guard let window else { return }
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab(String(localized: "Appearance"), appearancePane()))
        tabs.addTabViewItem(tab(String(localized: "Editor"), editorPane()))
        tabs.addTabViewItem(tab(String(localized: "Markdown"), markdownPane()))

        let content = NSView()
        content.addSubview(tabs)
        NSLayoutConstraint.activate([
            tabs.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tabs.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            tabs.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            content.widthAnchor.constraint(equalToConstant: 580),
        ])
        window.contentView = content
        loadValues()
    }

    private func tab(_ title: String, _ grid: NSGridView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: title)
        item.label = title
        let view = NSView()
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            grid.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -20),
        ])
        item.view = view
        return item
    }

    private func makeGrid() -> NSGridView {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 10
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        return grid
    }

    private func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private func row(_ views: NSView...) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        return stack
    }

    private func wire(_ control: NSControl) {
        control.target = self
        control.action = #selector(settingChanged)
    }

    private func appearancePane() -> NSGridView {
        let grid = makeGrid()
        wire(themePopup)
        let revealButton = NSButton(title: String(localized: "Theme Folder…"), target: self, action: #selector(revealThemes))
        revealButton.toolTip = String(localized: "Opens the folder for .mdtheme files, with a commented example to start from")
        grid.addRow(with: [label(String(localized: "Theme:")), row(themePopup, revealButton)])
        themeWarnings.textColor = .systemRed
        themeWarnings.font = .systemFont(ofSize: 11)
        themeWarnings.preferredMaxLayoutWidth = 380
        grid.addRow(with: [NSGridCell.emptyContentView, themeWarnings])

        wire(codeThemePopup)
        grid.addRow(with: [label(String(localized: "Code colours:")), codeThemePopup])

        fontPopup.addItem(withTitle: String(localized: "System"))
        fontPopup.menu?.addItem(.separator())
        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        wire(fontPopup)
        grid.addRow(with: [label(String(localized: "Font:")), fontPopup])

        sizeField.formatter = NumberFormatter()
        sizeField.widthAnchor.constraint(equalToConstant: 48).isActive = true
        wire(sizeField)
        sizeStepper.minValue = 9
        sizeStepper.maxValue = 48
        sizeStepper.increment = 1
        sizeStepper.valueWraps = false
        wire(sizeStepper)
        grid.addRow(with: [label(String(localized: "Size:")), row(sizeField, sizeStepper, label(String(localized: "pt  ·  View ▸ Zoom scales it further")))])

        monoFontPopup.addItem(withTitle: "SF Mono")
        monoFontPopup.menu?.addItem(.separator())
        monoFontPopup.addItems(withTitles: Self.monospacedFamilies())
        wire(monoFontPopup)
        grid.addRow(with: [label(String(localized: "Code font:")), monoFontPopup])
        return grid
    }

    private func slider(_ slider: NSSlider, _ range: ClosedRange<Double>, _ valueLabel: NSTextField) -> NSStackView {
        slider.minValue = range.lowerBound
        slider.maxValue = range.upperBound
        slider.widthAnchor.constraint(equalToConstant: 240).isActive = true
        wire(slider)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return row(slider, valueLabel)
    }

    private func editorPane() -> NSGridView {
        let grid = makeGrid()
        grid.addRow(with: [label(String(localized: "Line width:")), slider(widthSlider, 480...1400, widthLabel)])
        grid.addRow(with: [label(String(localized: "Line height:")), slider(lineHeightSlider, 1...2.5, lineHeightLabel)])
        grid.addRow(with: [label(String(localized: "Space after blocks:")), slider(spacingSlider, 0...2, spacingLabel)])
        grid.addRow(with: [label(String(localized: "Top and bottom padding:")), slider(paddingSlider, 0...160, paddingLabel)])
        for box in [autoPairBox, smartQuotesBox, spellCheckBox, typewriterBox, focusBox, updatesBox] { wire(box) }
        grid.addRow(with: [label(String(localized: "Typing:")), autoPairBox])
        grid.addRow(with: [NSGridCell.emptyContentView, smartQuotesBox])
        grid.addRow(with: [NSGridCell.emptyContentView, spellCheckBox])
        grid.addRow(with: [label(String(localized: "New tabs start in:")), typewriterBox])
        grid.addRow(with: [NSGridCell.emptyContentView, focusBox])
        grid.addRow(with: [label(String(localized: "Updates:")), updatesBox])
        return grid
    }

    private func markdownPane() -> NSGridView {
        let grid = makeGrid()
        for (index, (_, box)) in extensionBoxes.enumerated() {
            wire(box)
            grid.addRow(with: [index == 0 ? label(String(localized: "Extended syntax:")) : NSGridCell.emptyContentView, box])
        }
        bulletPopup.addItems(withTitles: [String(localized: "- Hyphen"), String(localized: "* Asterisk"), String(localized: "+ Plus")])
        wire(bulletPopup)
        grid.addRow(with: [label(String(localized: "New bulleted lists:")), bulletPopup])
        numberingPopup.addItems(withTitles: ["1. 2. 3.", "1. 1. 1."])
        wire(numberingPopup)
        grid.addRow(with: [label(String(localized: "New numbered lists:")), numberingPopup])
        wire(numberHeadingsBox)
        grid.addRow(with: [label(String(localized: "Headings:")), numberHeadingsBox])
        return grid
    }

    private static func monospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        let names = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
        let families = Set(names.compactMap { NSFont(name: $0, size: 12)?.familyName })
        return families.filter { !$0.hasPrefix(".") }.sorted()
    }

    // MARK: - Values

    private func reloadThemes() {
        themePopup.removeAllItems()
        let builtIns = ThemeCatalog.builtIns.map(\.name)
        themePopup.addItems(withTitles: builtIns)
        let custom = ThemeCatalog.allNames().filter { !builtIns.contains($0) }
        if !custom.isEmpty {
            themePopup.menu?.addItem(.separator())
            themePopup.addItems(withTitles: custom)
        }
        if themePopup.item(withTitle: settings.themeName) != nil {
            themePopup.selectItem(withTitle: settings.themeName)
        } else {
            themePopup.selectItem(withTitle: ThemeCatalog.defaultName)
        }

        codeThemePopup.removeAllItems()
        codeThemePopup.addItem(withTitle: ThemeCatalog.matchTheme)
        codeThemePopup.menu?.addItem(.separator())
        codeThemePopup.addItems(withTitles: ThemeCatalog.codePalettes.map(\.name))
        codeThemePopup.selectItem(withTitle: settings.codeThemeName)
        if codeThemePopup.selectedItem == nil { codeThemePopup.selectItem(at: 0) }
        updateThemeWarnings()
    }

    private func updateThemeWarnings() {
        let name = settings.themeName
        var warnings: [String] = []
        if !ThemeCatalog.builtIns.contains(where: { $0.name == name }) {
            let file = ThemeCatalog.customDirectory.appendingPathComponent(name).appendingPathExtension(ThemeCatalog.fileExtension)
            if let source = try? String(contentsOf: file, encoding: .utf8) {
                warnings = ThemeFile.parse(source, name: name).warnings
            }
        }
        themeWarnings.stringValue = warnings.prefix(4).joined(separator: "\n")
        themeWarnings.isHidden = warnings.isEmpty
    }

    private func loadValues() {
        reloadThemes()
        fontPopup.selectItem(withTitle: settings.fontName ?? String(localized: "System"))
        if fontPopup.selectedItem == nil { fontPopup.selectItem(at: 0) }
        monoFontPopup.selectItem(withTitle: settings.monoFontName ?? "SF Mono")
        if monoFontPopup.selectedItem == nil { monoFontPopup.selectItem(at: 0) }
        sizeField.doubleValue = settings.fontSize
        sizeStepper.doubleValue = settings.fontSize

        widthSlider.doubleValue = settings.lineWidth
        lineHeightSlider.doubleValue = settings.lineHeight
        spacingSlider.doubleValue = settings.paragraphSpacing
        paddingSlider.doubleValue = settings.padding
        autoPairBox.state = settings.autoPair ? .on : .off
        smartQuotesBox.state = settings.smartQuotes ? .on : .off
        spellCheckBox.state = settings.spellCheck ? .on : .off
        typewriterBox.state = settings.typewriterDefault ? .on : .off
        focusBox.state = settings.focusDefault ? .on : .off
        updatesBox.state = settings.checkForUpdates ? .on : .off

        let extensions = settings.extensions
        for (option, box) in extensionBoxes { box.state = extensions.contains(option) ? .on : .off }
        bulletPopup.selectItem(at: ["-", "*", "+"].firstIndex(of: settings.bulletMarker) ?? 0)
        numberingPopup.selectItem(at: settings.orderedNumbering == .allOnes ? 1 : 0)
        numberHeadingsBox.state = settings.numberHeadings ? .on : .off
        updateLabels()
    }

    private func updateLabels() {
        widthLabel.stringValue = String(localized: "\(Int(widthSlider.doubleValue)) pt")
        lineHeightLabel.stringValue = String(format: "%.2f×", lineHeightSlider.doubleValue)
        spacingLabel.stringValue = spacingSlider.doubleValue < 0.05 ? String(localized: "None") : String(format: String(localized: "%.1f lines"), spacingSlider.doubleValue)
        paddingLabel.stringValue = String(localized: "\(Int(paddingSlider.doubleValue)) pt")
    }

    @objc private func settingChanged(_ sender: Any?) {
        // The stepper and the field mirror each other.
        if sender as? NSStepper === sizeStepper {
            sizeField.doubleValue = sizeStepper.doubleValue
        } else {
            sizeStepper.doubleValue = sizeField.doubleValue
        }

        let theme = themePopup.titleOfSelectedItem ?? ThemeCatalog.defaultName
        settings.themeName = theme
        settings.codeThemeName = codeThemePopup.titleOfSelectedItem ?? ThemeCatalog.matchTheme
        let family = fontPopup.titleOfSelectedItem ?? String(localized: "System")
        settings.fontName = family == String(localized: "System") ? nil : family
        let mono = monoFontPopup.titleOfSelectedItem ?? "SF Mono"
        settings.monoFontName = mono == "SF Mono" ? nil : mono
        if (9...48).contains(sizeField.doubleValue) { settings.fontSize = sizeField.doubleValue }

        settings.lineWidth = widthSlider.doubleValue.rounded()
        settings.lineHeight = (lineHeightSlider.doubleValue * 20).rounded() / 20
        settings.paragraphSpacing = (spacingSlider.doubleValue * 10).rounded() / 10
        settings.padding = paddingSlider.doubleValue.rounded()
        settings.autoPair = autoPairBox.state == .on
        settings.smartQuotes = smartQuotesBox.state == .on
        settings.spellCheck = spellCheckBox.state == .on
        settings.typewriterDefault = typewriterBox.state == .on
        settings.focusDefault = focusBox.state == .on
        settings.checkForUpdates = updatesBox.state == .on

        var extensions: SyntaxExtensions = []
        for (option, box) in extensionBoxes where box.state == .on { extensions.insert(option) }
        settings.extensions = extensions
        settings.bulletMarker = ["-", "*", "+"][max(0, bulletPopup.indexOfSelectedItem)]
        settings.orderedNumbering = numberingPopup.indexOfSelectedItem == 1 ? .allOnes : .sequential
        settings.numberHeadings = numberHeadingsBox.state == .on

        updateLabels()
        updateThemeWarnings()
        Settings.notifyChanged()
    }

    @objc private func revealThemes(_ sender: Any?) {
        do {
            let example = try ThemeCatalog.installExample()
            NSWorkspace.shared.activateFileViewerSelecting([example])
        } catch {
            if let window { NSAlert(error: error).beginSheetModal(for: window) }
        }
    }
}
