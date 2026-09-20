import AppKit

struct TabDescriptor {
    var title: String
    var isDirty: Bool
}

@MainActor
protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ bar: TabBarView, didSelect index: Int)
    func tabBar(_ bar: TabBarView, didRequestClose index: Int)
    func tabBarDidRequestNewTab(_ bar: TabBarView)
}

/// The tab strip, shaped like a segmented control: one recessed track spanning
/// the window, equal-width segments inside it, and a single raised glass thumb
/// that slides to whichever segment is selected.
///
/// The track is a tinted fill rather than glass, so the thumb is the only glass
/// here — glass stacked on glass reads as muddy, and the thumb is what should
/// look lifted.
final class TabBarView: NSView {
    weak var delegate: TabBarViewDelegate?

    private let track = NSView()
    private let stack = NSStackView()
    private let thumb: GlassPanel
    private let newTabButton: GlassPanel
    private let plusButton = NSButton()
    private var segments: [TabSegment] = []

    private var thumbLeading: NSLayoutConstraint?
    private var thumbWidth: NSLayoutConstraint?

    private(set) var tabs: [TabDescriptor] = []
    private(set) var selectedIndex = 0

    private var theme: Theme = .current(for: NSApp.effectiveAppearance)

    override init(frame frameRect: NSRect) {
        thumb = GlassPanel(
            content: NSView(),
            cornerRadius: (Metrics.trackHeight - 2 * Metrics.thumbInset) / 2,
            interactive: true
        )
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")
        plusButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        plusButton.isBordered = false
        plusButton.bezelStyle = .accessoryBarAction
        plusButton.translatesAutoresizingMaskIntoConstraints = false
        newTabButton = GlassPanel(
            content: plusButton,
            cornerRadius: Metrics.plusDiameter / 2,
            interactive: true
        )

        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.cornerRadius = Metrics.trackHeight / 2
        track.layer?.cornerCurve = .continuous

        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.distribution = .fillEqually
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Thumb first: it sits behind the segment labels.
        track.addSubview(thumb)
        track.addSubview(stack)
        addSubview(track)
        addSubview(newTabButton)

        plusButton.target = self
        plusButton.action = #selector(newTab)
        plusButton.toolTip = "New Tab (⌘T)"

        let thumbLeading = thumb.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: Metrics.thumbInset)
        let thumbWidth = thumb.widthAnchor.constraint(equalToConstant: 0)
        self.thumbLeading = thumbLeading
        self.thumbWidth = thumbWidth

        NSLayoutConstraint.activate([
            track.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.chromeInset),
            track.centerYAnchor.constraint(equalTo: centerYAnchor),
            track.heightAnchor.constraint(equalToConstant: Metrics.trackHeight),
            track.trailingAnchor.constraint(equalTo: newTabButton.leadingAnchor, constant: -Metrics.tabGap),

            newTabButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.chromeInset),
            newTabButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            newTabButton.widthAnchor.constraint(equalToConstant: Metrics.plusDiameter),
            newTabButton.heightAnchor.constraint(equalToConstant: Metrics.plusDiameter),

            stack.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: track.trailingAnchor),
            stack.topAnchor.constraint(equalTo: track.topAnchor),
            stack.bottomAnchor.constraint(equalTo: track.bottomAnchor),

            thumbLeading,
            thumbWidth,
            thumb.topAnchor.constraint(equalTo: track.topAnchor, constant: Metrics.thumbInset),
            thumb.bottomAnchor.constraint(equalTo: track.bottomAnchor, constant: -Metrics.thumbInset),

            heightAnchor.constraint(equalToConstant: Metrics.trackHeight + 2 * Metrics.tabGap),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setTabs(_ tabs: [TabDescriptor], selected: Int) {
        let countChanged = tabs.count != segments.count
        self.tabs = tabs
        selectedIndex = selected

        if countChanged { rebuildSegments() }
        for (index, segment) in segments.enumerated() where index < tabs.count {
            segment.apply(tabs[index], isSelected: index == selected, theme: theme)
        }
        // A brand new tab appears in place rather than sliding from the old one.
        moveThumb(animated: !countChanged)
    }

    func applyTheme(_ theme: Theme) {
        self.theme = theme
        track.layer?.backgroundColor = theme.trackFill.cgColor
        plusButton.contentTintColor = theme.secondaryText
        thumb.tint = nil
        setTabs(tabs, selected: selectedIndex)
    }

    override func layout() {
        super.layout()
        moveThumb(animated: false)
    }

    private func rebuildSegments() {
        for segment in segments { segment.removeFromSuperview() }
        segments = tabs.indices.map { index in
            let segment = TabSegment(index: index)
            segment.onSelect = { [weak self] index in
                guard let self else { return }
                delegate?.tabBar(self, didSelect: index)
            }
            segment.onClose = { [weak self] index in
                guard let self else { return }
                delegate?.tabBar(self, didRequestClose: index)
            }
            stack.addArrangedSubview(segment)
            return segment
        }
    }

    /// Slides the thumb under the selected segment. This is the tab-switch
    /// animation: one piece of glass moving, not a crossfade.
    private func moveThumb(animated: Bool) {
        guard segments.indices.contains(selectedIndex) else {
            thumb.isHidden = true
            return
        }
        thumb.isHidden = false
        layoutSubtreeIfNeeded()

        let segment = segments[selectedIndex]
        let leading = segment.frame.minX + Metrics.thumbInset
        let width = max(0, segment.frame.width - 2 * Metrics.thumbInset)
        guard thumbLeading?.constant != leading || thumbWidth?.constant != width else { return }

        let apply = {
            self.thumbLeading?.constant = leading
            self.thumbWidth?.constant = width
        }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.22
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                context.allowsImplicitAnimation = true
                apply()
                layoutSubtreeIfNeeded()
            }
        } else {
            apply()
        }
    }

    @objc private func newTab() {
        delegate?.tabBarDidRequestNewTab(self)
    }
}

/// One segment of the track: a centred title, a dirty dot, and a close button
/// that appears on hover.
final class TabSegment: NSView {
    let index: Int
    var onSelect: ((Int) -> Void)?
    var onClose: ((Int) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let dirtyDot = NSView()
    private var isDirty = false
    private var isHovering = false

    init(index: Int) {
        self.index = index
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false

        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")
        closeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.isHidden = true
        closeButton.target = self
        closeButton.action = #selector(close)

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.cornerRadius = 3
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.isHidden = true

        addSubview(label)
        addSubview(closeButton)
        addSubview(dirtyDot)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),

            closeButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            closeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 14),

            dirtyDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dirtyDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyDot.widthAnchor.constraint(equalToConstant: 6),
            dirtyDot.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func apply(_ tab: TabDescriptor, isSelected: Bool, theme: Theme) {
        label.stringValue = tab.title
        label.textColor = isSelected ? theme.text : theme.secondaryText
        closeButton.contentTintColor = theme.secondaryText
        dirtyDot.layer?.backgroundColor = theme.secondaryText.cgColor
        isDirty = tab.isDirty
        toolTip = tab.title
        updateHoverItems()
    }

    private func updateHoverItems() {
        closeButton.isHidden = !isHovering
        dirtyDot.isHidden = !isDirty
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        updateHoverItems()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        updateHoverItems()
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(index)
    }

    @objc private func close() {
        onClose?(index)
    }
}
