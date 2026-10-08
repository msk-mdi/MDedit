import AppKit
import MarkdownKit

/// The small bar pinned to the top-right of the code block the caret is in:
/// a language menu and a Copy button. It rides in the text view, so it
/// scrolls with the block.
final class CodeBlockAccessory: NSView {
    /// Asked to change the block's language; an empty string means plain text.
    var onChooseLanguage: ((String) -> Void)?
    /// Asked to copy the block's code.
    var onCopy: (() -> Void)?

    private let languageButton = NSPopUpButton(frame: .zero, pullsDown: true)
    private let copyButton = NSButton()
    private var currentLanguage = ""

    static let extraLanguages = ["mermaid"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.cornerCurve = .continuous

        languageButton.isBordered = false
        languageButton.controlSize = .small
        languageButton.font = .systemFont(ofSize: 11)
        (languageButton.cell as? NSPopUpButtonCell)?.arrowPosition = .arrowAtBottom
        languageButton.target = self
        languageButton.action = #selector(languageChosen)
        languageButton.toolTip = "Code block language"

        copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        copyButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
        copyButton.isBordered = false
        copyButton.bezelStyle = .accessoryBarAction
        copyButton.target = self
        copyButton.action = #selector(copyCode)
        copyButton.toolTip = "Copy code"

        let stack = NSStackView(views: [languageButton, copyButton])
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 22),
        ])
        rebuildMenu()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        layer?.backgroundColor = theme.canvas.withAlphaComponent(0.9).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
        languageButton.contentTintColor = theme.secondaryText
        copyButton.contentTintColor = theme.secondaryText
    }

    /// Shows a block's language; its first word is the language name.
    func show(language info: String) {
        let name = info.split(separator: " ").first.map(String.init) ?? ""
        guard name != currentLanguage else { return }
        currentLanguage = name
        languageButton.item(at: 0)?.title = name.isEmpty ? "Plain Text" : name
        for item in languageButton.itemArray.dropFirst() {
            item.state = (item.representedObject as? String) == name.lowercased() ? .on : .off
        }
    }

    private func rebuildMenu() {
        languageButton.removeAllItems()
        // A pull-down's first item is its title.
        languageButton.addItem(withTitle: "Plain Text")
        let plain = NSMenuItem(title: "Plain Text", action: nil, keyEquivalent: "")
        plain.representedObject = ""
        languageButton.menu?.addItem(plain)
        languageButton.menu?.addItem(.separator())
        for name in (Language.allNames + Self.extraLanguages).sorted() {
            let item = NSMenuItem(title: name, action: nil, keyEquivalent: "")
            item.representedObject = name
            languageButton.menu?.addItem(item)
        }
    }

    @objc private func languageChosen() {
        guard let name = languageButton.selectedItem?.representedObject as? String else { return }
        onChooseLanguage?(name)
    }

    @objc private func copyCode() {
        onCopy?()
        // A moment of confirmation, then back to the copy icon.
        copyButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy code")
        }
    }
}
