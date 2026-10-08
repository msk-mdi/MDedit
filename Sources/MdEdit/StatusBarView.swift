import AppKit
import MarkdownKit

/// The bottom bar: counts on the left, document facts on the right.
///
/// A full-width chrome surface rather than a floating pill, so it reads as part
/// of the window frame the way the titlebar does. The counts are a button:
/// clicking them opens the statistics popover.
final class StatusBarView: NSView {
    private let counts = NSButton(title: "", target: nil, action: nil)
    private let goalProgress = NSProgressIndicator()
    private let details = NSTextField(labelWithString: "")
    private let separator = NSBox()
    private var textColor: NSColor = .secondaryLabelColor

    /// Asked to show statistics, anchored to the counts.
    var onShowStatistics: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        counts.isBordered = false
        counts.font = .systemFont(ofSize: 11)
        counts.target = self
        counts.action = #selector(showStatistics)
        counts.toolTip = "Statistics and word goal"
        counts.setAccessibilityLabel("Document statistics")

        goalProgress.style = .bar
        goalProgress.isIndeterminate = false
        goalProgress.controlSize = .small
        goalProgress.minValue = 0
        goalProgress.isHidden = true

        details.font = .systemFont(ofSize: 11)
        details.alignment = .right
        for view in [counts, goalProgress, details] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(separator)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: topAnchor),

            counts.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            counts.centerYAnchor.constraint(equalTo: centerYAnchor),

            goalProgress.leadingAnchor.constraint(equalTo: counts.trailingAnchor, constant: 8),
            goalProgress.centerYAnchor.constraint(equalTo: centerYAnchor),
            goalProgress.widthAnchor.constraint(equalToConstant: 72),

            details.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            details.centerYAnchor.constraint(equalTo: centerYAnchor),
            details.leadingAnchor.constraint(greaterThanOrEqualTo: goalProgress.trailingAnchor, constant: 12),

            heightAnchor.constraint(equalToConstant: Metrics.statusBarHeight),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        textColor = theme.secondaryText
        details.textColor = theme.secondaryText
        counts.attributedTitle = NSAttributedString(string: counts.title, attributes: titleAttributes)
        layer?.backgroundColor = theme.canvas.cgColor
    }

    private var titleAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: textColor]
    }

    /// Where the statistics popover points.
    var statisticsAnchor: NSView { counts }

    @objc private func showStatistics() {
        onShowStatistics?(counts)
    }

    func update(statistics: TextStatistics, selection: TextStatistics?, goal: Int?, line: Int, column: Int) {
        let words = statistics.words.formatted()
        var left: String
        if let selection, selection.characters > 0 {
            left = "Selected: \(selection.words.formatted()) of \(words) words   Characters: \(selection.characters.formatted())"
        } else if let goal {
            left = "Words: \(words) of \(goal.formatted())   Characters: \(statistics.characters.formatted())"
        } else {
            left = "Words: \(words)   Characters: \(statistics.characters.formatted())   Lines: \(statistics.lines.formatted())"
        }
        if let goal, statistics.words >= goal { left += "   ✓" }
        counts.attributedTitle = NSAttributedString(string: left, attributes: titleAttributes)
        counts.title = left

        goalProgress.isHidden = goal == nil
        if let goal {
            goalProgress.maxValue = Double(goal)
            goalProgress.doubleValue = Double(min(statistics.words, goal))
        }
        let minutes = statistics.readingMinutes
        details.stringValue = "\(max(1, minutes)) min read   ·   Line \(line), Column \(column)"
    }
}

/// Counts for the whole document or the selection, and a word goal.
@MainActor
final class StatisticsViewController: NSViewController {
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let goalField = NSTextField()
    private var values: [NSTextField] = []
    /// Called with the new goal, or nil to clear it.
    var onSetGoal: ((Int?) -> Void)?

    private static let rows = [
        "Words", "Characters", "Without spaces", "Paragraphs", "Sentences", "Lines", "Reading time", "Speaking time",
    ]

    override func loadView() {
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false
        for title in Self.rows {
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "")
            value.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            values.append(value)
            grid.addRow(with: [label, value])
        }
        goalField.placeholderString = "None"
        goalField.formatter = {
            let formatter = NumberFormatter()
            formatter.minimum = 0
            formatter.maximum = 10_000_000
            formatter.allowsFloats = false
            return formatter
        }()
        goalField.widthAnchor.constraint(equalToConstant: 90).isActive = true
        goalField.target = self
        goalField.action = #selector(goalChanged)
        let goalLabel = NSTextField(labelWithString: "Word goal")
        goalLabel.textColor = .secondaryLabelColor
        grid.addRow(with: [goalLabel, goalField])
        grid.row(at: grid.numberOfRows - 1).topPadding = 8

        let container = NSView()
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            grid.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])
        view = container
    }

    func show(_ statistics: TextStatistics, isSelection: Bool, goal: Int?) {
        loadViewIfNeeded()
        func minutes(_ value: Int) -> String { value == 0 ? "—" : "\(value) min" }
        let texts = [
            statistics.words.formatted(), statistics.characters.formatted(),
            statistics.charactersExcludingSpaces.formatted(), statistics.paragraphs.formatted(),
            statistics.sentences.formatted(), statistics.lines.formatted(),
            minutes(statistics.readingMinutes), minutes(statistics.speakingMinutes),
        ]
        for (field, text) in zip(values, texts) { field.stringValue = text }
        (grid.cell(atColumnIndex: 0, rowIndex: 0).contentView as? NSTextField)?.stringValue = isSelection ? "Selected words" : "Words"
        if view.window?.firstResponder !== goalField.currentEditor() {
            goalField.stringValue = goal.map(String.init) ?? ""
        }
    }

    @objc private func goalChanged() {
        let value = goalField.integerValue
        onSetGoal?(value > 0 ? value : nil)
    }
}
