import AppKit

/// A small settings window over `UserDefaults`; the editor re-reads these
/// through `Theme.current(for:)`.
@MainActor
final class PreferencesWindowController: NSWindowController {
    static let shared = PreferencesWindowController()

    /// Posted when a setting changes so open editors can restyle.
    static let settingsDidChange = Notification.Name("MdEditSettingsDidChange")

    private let fontPopup = NSPopUpButton()
    private let sizeField = NSTextField()
    private let widthSlider = NSSlider()
    private let widthLabel = NSTextField(labelWithString: "")

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        self.init(window: window)
        buildContent()
    }

    private func buildContent() {
        guard let window else { return }
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 12
        grid.columnSpacing = 12

        fontPopup.addItem(withTitle: "System")
        fontPopup.addItems(withTitles: NSFontManager.shared.availableFontFamilies)
        let savedFont = UserDefaults.standard.string(forKey: "editorFontName") ?? ""
        fontPopup.selectItem(withTitle: savedFont.isEmpty ? "System" : savedFont)
        fontPopup.target = self
        fontPopup.action = #selector(settingChanged)

        sizeField.doubleValue = max(9, UserDefaults.standard.double(forKey: "editorFontSize"))
        if sizeField.doubleValue < 9 { sizeField.doubleValue = 15 }
        sizeField.target = self
        sizeField.action = #selector(settingChanged)

        widthSlider.minValue = 480
        widthSlider.maxValue = 1100
        let savedWidth = UserDefaults.standard.double(forKey: "editorLineWidth")
        widthSlider.doubleValue = savedWidth >= 480 ? savedWidth : Double(Metrics.defaultLineWidth)
        widthSlider.target = self
        widthSlider.action = #selector(settingChanged)

        grid.addRow(with: [NSTextField(labelWithString: "Font:"), fontPopup])
        grid.addRow(with: [NSTextField(labelWithString: "Size:"), sizeField])
        grid.addRow(with: [NSTextField(labelWithString: "Line width:"), widthSlider])
        grid.addRow(with: [NSTextField(labelWithString: ""), widthLabel])

        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
        window.contentView = content
        updateWidthLabel()
    }

    private func updateWidthLabel() {
        widthLabel.stringValue = "\(Int(widthSlider.doubleValue)) pt"
        widthLabel.textColor = .secondaryLabelColor
        widthLabel.font = .systemFont(ofSize: 11)
    }

    @objc private func settingChanged() {
        let defaults = UserDefaults.standard
        let family = fontPopup.titleOfSelectedItem ?? "System"
        defaults.set(family == "System" ? "" : family, forKey: "editorFontName")
        defaults.set(sizeField.doubleValue, forKey: "editorFontSize")
        defaults.set(widthSlider.doubleValue, forKey: "editorLineWidth")
        updateWidthLabel()
        NotificationCenter.default.post(name: Self.settingsDidChange, object: nil)
    }
}
