import AppKit

/// The bottom bar: counts on the left, document facts on the right.
///
/// A full-width chrome surface rather than a floating pill, so it reads as part
/// of the window frame the way the titlebar does.
final class StatusBarView: NSView {
    private let counts = NSTextField(labelWithString: "")
    private let details = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        for label in [counts, details] {
            label.font = .systemFont(ofSize: 11)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        details.alignment = .right

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),

            counts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),

            details.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            details.centerYAnchor.constraint(equalTo: centerYAnchor),
            details.leadingAnchor.constraint(greaterThanOrEqualTo: counts.trailingAnchor, constant: 12),

            heightAnchor.constraint(equalToConstant: Metrics.statusBarHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        counts.textColor = theme.secondaryText
        details.textColor = theme.secondaryText
        layer?.backgroundColor = theme.canvas.cgColor
    }

    func update(words: Int, characters: Int, lines: Int, line: Int, column: Int) {
        let minutes = max(1, Int((Double(words) / 200.0).rounded(.up)))
        counts.stringValue = "Words: \(words)   Characters: \(characters)   Lines: \(lines)"
        details.stringValue = "\(minutes) min read   ·   Line \(line), Column \(column)"
    }
}
