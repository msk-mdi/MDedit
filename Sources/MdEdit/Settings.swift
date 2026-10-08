import AppKit
import MarkdownKit

/// Every user preference, typed, over `UserDefaults`.
///
/// Reads always go through here so a missing or out-of-range value falls back
/// to the same default everywhere. Writers post `Settings.didChange`, and open
/// windows restyle from it.
@MainActor
struct Settings {
    static let didChange = Notification.Name("MdEditSettingsDidChange")

    var defaults: UserDefaults = .standard

    /// Tells every open editor to re-read its settings.
    static func notifyChanged() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    enum Key {
        static let fontName = "editorFontName"
        static let fontSize = "editorFontSize"
        static let monoFontName = "editorMonoFontName"
        static let lineWidth = "editorLineWidth"
        static let lineHeight = "editorLineHeight"
        static let paragraphSpacing = "editorParagraphSpacing"
        static let padding = "editorPadding"
        static let zoom = "editorZoom"
        static let theme = "editorTheme"
        static let codeTheme = "editorCodeTheme"
        static let autoPair = "autoPairBrackets"
        static let smartQuotes = "smartQuotes"
        static let spellCheck = "spellCheck"
        static let typewriterDefault = "typewriterModeDefault"
        static let focusDefault = "focusModeDefault"
        static let extensions = "syntaxExtensions"
        static let knownExtensions = "knownSyntaxExtensions"
        static let bulletMarker = "bulletMarker"
        static let orderedNumbering = "orderedListNumbering"
        static let numberHeadings = "numberHeadings"
        static let checkForUpdates = "checkForUpdates"
    }

    private func double(_ key: String, default value: Double, in range: ClosedRange<Double>) -> Double {
        guard defaults.object(forKey: key) != nil else { return value }
        let stored = defaults.double(forKey: key)
        return range.contains(stored) ? stored : value
    }

    private func bool(_ key: String, default value: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? value
    }

    // MARK: - Fonts and layout

    /// The body font family, or nil for the system font.
    var fontName: String? {
        get { defaults.string(forKey: Key.fontName).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue ?? "", forKey: Key.fontName) }
    }

    var fontSize: Double {
        get { double(Key.fontSize, default: 15, in: 9...48) }
        nonmutating set { defaults.set(newValue, forKey: Key.fontSize) }
    }

    /// The code font family, or nil for SF Mono.
    var monoFontName: String? {
        get { defaults.string(forKey: Key.monoFontName).flatMap { $0.isEmpty ? nil : $0 } }
        nonmutating set { defaults.set(newValue ?? "", forKey: Key.monoFontName) }
    }

    var lineWidth: Double {
        get { double(Key.lineWidth, default: Double(Metrics.defaultLineWidth), in: 480...1400) }
        nonmutating set { defaults.set(newValue, forKey: Key.lineWidth) }
    }

    /// Multiple of the font's natural line height for prose.
    var lineHeight: Double {
        get { double(Key.lineHeight, default: 1.35, in: 1...2.5) }
        nonmutating set { defaults.set(newValue, forKey: Key.lineHeight) }
    }

    /// Space after each paragraph, in multiples of the body size.
    var paragraphSpacing: Double {
        get { double(Key.paragraphSpacing, default: 0, in: 0...2) }
        nonmutating set { defaults.set(newValue, forKey: Key.paragraphSpacing) }
    }

    /// Space above the first line and below the last, in points.
    var padding: Double {
        get { double(Key.padding, default: 28, in: 0...200) }
        nonmutating set { defaults.set(newValue, forKey: Key.padding) }
    }

    /// View ▸ Zoom, multiplying every font size.
    var zoom: Double {
        get { double(Key.zoom, default: 1, in: Self.zoomRange) }
        nonmutating set { defaults.set(min(max(newValue, Self.zoomRange.lowerBound), Self.zoomRange.upperBound), forKey: Key.zoom) }
    }

    static let zoomRange = 0.5...3.0
    static let zoomSteps: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    // MARK: - Theme

    /// A built-in theme's name, or a custom theme file's name.
    var themeName: String {
        get { defaults.string(forKey: Key.theme) ?? ThemeCatalog.defaultName }
        nonmutating set { defaults.set(newValue, forKey: Key.theme) }
    }

    /// A code palette's name, or `ThemeCatalog.matchTheme` to use the theme's own.
    var codeThemeName: String {
        get { defaults.string(forKey: Key.codeTheme) ?? ThemeCatalog.matchTheme }
        nonmutating set { defaults.set(newValue, forKey: Key.codeTheme) }
    }

    // MARK: - Typing

    var autoPair: Bool {
        get { bool(Key.autoPair, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.autoPair) }
    }

    /// Curly quotes and dashes as you type. Off by default: they turn code
    /// spans and front matter into something other than what was typed.
    var smartQuotes: Bool {
        get { bool(Key.smartQuotes, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.smartQuotes) }
    }

    var spellCheck: Bool {
        get { bool(Key.spellCheck, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.spellCheck) }
    }

    /// Asks GitHub once a day whether a newer release is out.
    var checkForUpdates: Bool {
        get { bool(Key.checkForUpdates, default: true) }
        nonmutating set { defaults.set(newValue, forKey: Key.checkForUpdates) }
    }

    /// The mode new tabs start in.
    var typewriterDefault: Bool {
        get { bool(Key.typewriterDefault, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.typewriterDefault) }
    }

    var focusDefault: Bool {
        get { bool(Key.focusDefault, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.focusDefault) }
    }

    // MARK: - Markdown

    var extensions: SyntaxExtensions {
        get {
            guard defaults.object(forKey: Key.extensions) != nil else { return .all }
            let enabled = SyntaxExtensions(rawValue: defaults.integer(forKey: Key.extensions))
            // Syntax added since the choice was saved starts on; settings
            // saved before this was tracked knew the first five.
            let known = defaults.object(forKey: Key.knownExtensions) != nil
                ? SyntaxExtensions(rawValue: defaults.integer(forKey: Key.knownExtensions))
                : [.highlight, .scripts, .emoji, .math, .bareURLs]
            return enabled.union(SyntaxExtensions.all.subtracting(known)).intersection(.all)
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Key.extensions)
            defaults.set(SyntaxExtensions.all.rawValue, forKey: Key.knownExtensions)
        }
    }

    /// What new bulleted lists start with: `-`, `*` or `+`.
    var bulletMarker: String {
        get {
            let stored = defaults.string(forKey: Key.bulletMarker) ?? "-"
            return ["-", "*", "+"].contains(stored) ? stored : "-"
        }
        nonmutating set { defaults.set(newValue, forKey: Key.bulletMarker) }
    }

    enum OrderedNumbering: String, CaseIterable {
        /// 1. 2. 3.
        case sequential
        /// 1. 1. 1. — renders the same, and reordering never renumbers.
        case allOnes
    }

    var orderedNumbering: OrderedNumbering {
        get { defaults.string(forKey: Key.orderedNumbering).flatMap(OrderedNumbering.init(rawValue:)) ?? .sequential }
        nonmutating set { defaults.set(newValue.rawValue, forKey: Key.orderedNumbering) }
    }

    /// Shows 1, 1.1, 1.2 … beside headings, and numbers them in export.
    var numberHeadings: Bool {
        get { bool(Key.numberHeadings, default: false) }
        nonmutating set { defaults.set(newValue, forKey: Key.numberHeadings) }
    }
}
