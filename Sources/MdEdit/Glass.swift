import AppKit

/// A rounded panel of Liquid Glass with a single call site for the whole app.
///
/// Wraps `NSGlassEffectView` and degrades to a solid themed fill when the user
/// has asked for reduced transparency, so no caller ever has to think about it.
final class GlassPanel: NSView {
    enum Style {
        case regular
        case clear

        var appKitStyle: NSGlassEffectView.Style {
            switch self {
            case .regular: .regular
            case .clear: .clear
            }
        }
    }

    /// The view carried inside the glass.
    let content: NSView

    private let style: Style
    private let interactive: Bool
    private var glass: NSGlassEffectView?
    private var fallback: NSVisualEffectView?

    var cornerRadius: CGFloat {
        didSet { applyCornerRadius() }
    }

    var tint: NSColor? {
        didSet { glass?.tintColor = tint }
    }

    init(
        content: NSView,
        style: Style = .regular,
        cornerRadius: CGFloat,
        tint: NSColor? = nil,
        interactive: Bool = false
    ) {
        self.content = content
        self.style = style
        self.cornerRadius = cornerRadius
        self.interactive = interactive
        super.init(frame: .zero)
        self.tint = tint

        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        rebuild()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(accessibilityDisplayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// True when the system asks us to stop rendering translucent materials.
    private var prefersOpaque: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    }

    private func rebuild() {
        glass?.removeFromSuperview()
        fallback?.removeFromSuperview()
        content.removeFromSuperview()
        glass = nil
        fallback = nil

        let backdrop: NSView
        if prefersOpaque {
            let effect = NSVisualEffectView()
            effect.material = .headerView
            effect.blendingMode = .withinWindow
            effect.state = .active
            effect.wantsLayer = true
            fallback = effect
            backdrop = effect
            effect.addSubview(content)
        } else {
            let effect = NSGlassEffectView()
            effect.style = style.appKitStyle
            effect.tintColor = tint
            if #available(macOS 27, *) {
                effect.effectIsInteractive = interactive
            }
            effect.contentView = content
            glass = effect
            backdrop = effect
        }

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if fallback != nil {
            NSLayoutConstraint.activate([
                content.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
                content.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
                content.topAnchor.constraint(equalTo: backdrop.topAnchor),
                content.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
            ])
        }

        applyCornerRadius()
    }

    private func applyCornerRadius() {
        glass?.cornerRadius = cornerRadius
        if let fallback {
            fallback.wantsLayer = true
            fallback.layer?.cornerRadius = cornerRadius
            fallback.layer?.cornerCurve = .continuous
            fallback.layer?.masksToBounds = true
        }
    }

    /// Sets a capsule radius from the panel's own height.
    func makeCapsule(height: CGFloat) {
        cornerRadius = height / 2
    }

    @objc private func accessibilityDisplayOptionsChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let isOpaqueNow = fallback != nil
            guard isOpaqueNow != prefersOpaque else { return }
            rebuild()
        }
    }
}

