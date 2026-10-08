import AppKit

/// The left sidebar: Files, Outline and Search, one at a time, picked by a
/// segmented control at the top.
final class SidebarView: NSView {
    enum Pane: Int, CaseIterable {
        case files, outline, search

        var symbol: String {
            switch self {
            case .files: "folder"
            case .outline: "list.bullet.indent"
            case .search: "magnifyingglass"
            }
        }

        var label: String {
            switch self {
            case .files: String(localized: "Files")
            case .outline: String(localized: "Outline")
            case .search: String(localized: "Find in Folder")
            }
        }
    }

    let files = FileTreeView()
    let outline = OutlineView()
    let search = SearchPaneView()

    /// Called when the user switches panes with the segmented control.
    var onPaneChange: ((Pane) -> Void)?

    private let picker = NSSegmentedControl()
    /// A plain view, not a separator `NSBox`: a box decides it is horizontal
    /// and hugs its height, which pinned top to bottom collapses the window.
    private let divider = NSView()

    private(set) var pane: Pane = .outline

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        picker.segmentCount = Pane.allCases.count
        picker.segmentStyle = .automatic
        picker.trackingMode = .selectOne
        for pane in Pane.allCases {
            picker.setImage(NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.label), forSegment: pane.rawValue)
            picker.setToolTip(pane.label, forSegment: pane.rawValue)
            picker.setWidth(36, forSegment: pane.rawValue)
        }
        picker.target = self
        picker.action = #selector(pickerChanged)
        picker.translatesAutoresizingMaskIntoConstraints = false

        divider.wantsLayer = true
        divider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(picker)
        addSubview(divider)
        var constraints = [
            picker.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),

            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.bottomAnchor.constraint(equalTo: bottomAnchor),
            divider.widthAnchor.constraint(equalToConstant: 1),

            widthAnchor.constraint(equalToConstant: Metrics.sidebarWidth),
        ]
        for view in [files, outline, search] as [NSView] {
            addSubview(view)
            constraints += [
                view.leadingAnchor.constraint(equalTo: leadingAnchor),
                view.trailingAnchor.constraint(equalTo: divider.leadingAnchor),
                view.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 6),
                view.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        show(.outline)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func applyTheme(_ theme: Theme) {
        layer?.backgroundColor = theme.canvas.cgColor
        divider.layer?.backgroundColor = NSColor.separatorColor.cgColor
        files.applyTheme(theme)
        outline.applyTheme(theme)
        search.applyTheme(theme)
    }

    func show(_ pane: Pane) {
        self.pane = pane
        picker.selectedSegment = pane.rawValue
        files.isHidden = pane != .files
        outline.isHidden = pane != .outline
        search.isHidden = pane != .search
    }

    @objc private func pickerChanged() {
        guard let pane = Pane(rawValue: picker.selectedSegment) else { return }
        show(pane)
        onPaneChange?(pane)
    }
}
