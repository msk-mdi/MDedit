import AppKit
import MarkdownKit

/// Colours for code tokens, one set per appearance.
struct SyntaxPalette {
    var keyword: NSColor
    var type: NSColor
    var constant: NSColor
    var string: NSColor
    var number: NSColor
    var comment: NSColor
    var function: NSColor
    var variable: NSColor
    var attribute: NSColor
    var tag: NSColor
    var inserted: NSColor
    var deleted: NSColor

    func color(for kind: TokenKind) -> NSColor {
        switch kind {
        case .keyword: keyword
        case .type: type
        case .constant: constant
        case .string: string
        case .number: number
        case .comment: comment
        case .function: function
        case .variable: variable
        case .attribute: attribute
        case .tag: tag
        case .inserted: inserted
        case .deleted: deleted
        }
    }

    /// Tuned against the light canvas: saturated enough to separate, dark
    /// enough to read as body text at 13pt.
    static let light = SyntaxPalette(
        keyword: NSColor(calibratedRed: 0.61, green: 0.13, blue: 0.56, alpha: 1),
        type: NSColor(calibratedRed: 0.16, green: 0.40, blue: 0.53, alpha: 1),
        constant: NSColor(calibratedRed: 0.42, green: 0.22, blue: 0.75, alpha: 1),
        string: NSColor(calibratedRed: 0.77, green: 0.18, blue: 0.16, alpha: 1),
        number: NSColor(calibratedRed: 0.11, green: 0.33, blue: 0.78, alpha: 1),
        comment: NSColor(calibratedRed: 0.40, green: 0.47, blue: 0.43, alpha: 1),
        function: NSColor(calibratedRed: 0.20, green: 0.33, blue: 0.64, alpha: 1),
        variable: NSColor(calibratedRed: 0.72, green: 0.38, blue: 0.09, alpha: 1),
        attribute: NSColor(calibratedRed: 0.35, green: 0.36, blue: 0.13, alpha: 1),
        tag: NSColor(calibratedRed: 0.14, green: 0.44, blue: 0.35, alpha: 1),
        inserted: NSColor(calibratedRed: 0.10, green: 0.46, blue: 0.20, alpha: 1),
        deleted: NSColor(calibratedRed: 0.70, green: 0.15, blue: 0.15, alpha: 1)
    )

    static let dark = SyntaxPalette(
        keyword: NSColor(calibratedRed: 0.98, green: 0.47, blue: 0.75, alpha: 1),
        type: NSColor(calibratedRed: 0.54, green: 0.83, blue: 0.94, alpha: 1),
        constant: NSColor(calibratedRed: 0.73, green: 0.62, blue: 1.00, alpha: 1),
        string: NSColor(calibratedRed: 0.99, green: 0.55, blue: 0.48, alpha: 1),
        number: NSColor(calibratedRed: 0.84, green: 0.79, blue: 0.53, alpha: 1),
        comment: NSColor(calibratedRed: 0.51, green: 0.58, blue: 0.54, alpha: 1),
        function: NSColor(calibratedRed: 0.49, green: 0.73, blue: 1.00, alpha: 1),
        variable: NSColor(calibratedRed: 1.00, green: 0.72, blue: 0.42, alpha: 1),
        attribute: NSColor(calibratedRed: 0.80, green: 0.85, blue: 0.53, alpha: 1),
        tag: NSColor(calibratedRed: 0.42, green: 0.85, blue: 0.70, alpha: 1),
        inserted: NSColor(calibratedRed: 0.51, green: 0.86, blue: 0.56, alpha: 1),
        deleted: NSColor(calibratedRed: 1.00, green: 0.52, blue: 0.52, alpha: 1)
    )
}

/// Every color and font the editor draws with.
///
/// The canvas is deliberately opaque: glass belongs to the chrome floating above
/// it, never behind body text.
struct Theme {
    var canvas: NSColor
    var text: NSColor
    var heading: NSColor
    /// Syntax markers, when revealed on the active line.
    var marker: NSColor
    var secondaryText: NSColor
    var link: NSColor
    var codeText: NSColor
    var codeBackground: NSColor
    var quoteBar: NSColor
    var quoteText: NSColor
    var rule: NSColor
    var accent: NSColor
    /// Recessed fill behind the segmented tab track.
    var trackFill: NSColor
    /// Colours for highlighted code.
    var syntax: SyntaxPalette

    var bodyFontSize: CGFloat = 15
    var bodyFontName: String?
    var monoFontSize: CGFloat = 13

    var body: NSFont {
        if let bodyFontName, let font = NSFont(name: bodyFontName, size: bodyFontSize) {
            return font
        }
        return .systemFont(ofSize: bodyFontSize)
    }

    var mono: NSFont {
        .monospacedSystemFont(ofSize: monoFontSize, weight: .regular)
    }

    /// Heading sizes follow a modest scale; 1.6x down to body size at h6.
    func headingFont(level: Int) -> NSFont {
        let scale: [CGFloat] = [1.9, 1.55, 1.3, 1.15, 1.05, 1.0]
        let index = min(max(level, 1), 6) - 1
        let size = (bodyFontSize * scale[index]).rounded()
        let weight: NSFont.Weight = level <= 2 ? .bold : .semibold
        return .systemFont(ofSize: size, weight: weight)
    }

    static let light = Theme(
        canvas: NSColor(white: 0.99, alpha: 1),
        text: NSColor(white: 0.13, alpha: 1),
        heading: NSColor(white: 0.07, alpha: 1),
        marker: NSColor(white: 0.62, alpha: 1),
        secondaryText: NSColor(white: 0.45, alpha: 1),
        link: NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.85, alpha: 1),
        codeText: NSColor(calibratedRed: 0.63, green: 0.17, blue: 0.33, alpha: 1),
        codeBackground: NSColor(white: 0.94, alpha: 1),
        quoteBar: NSColor(white: 0.80, alpha: 1),
        quoteText: NSColor(white: 0.38, alpha: 1),
        rule: NSColor(white: 0.85, alpha: 1),
        accent: .controlAccentColor,
        trackFill: NSColor(white: 0, alpha: 0.06),
        syntax: .light
    )

    static let dark = Theme(
        canvas: NSColor(white: 0.12, alpha: 1),
        text: NSColor(white: 0.88, alpha: 1),
        heading: NSColor(white: 0.97, alpha: 1),
        marker: NSColor(white: 0.45, alpha: 1),
        secondaryText: NSColor(white: 0.60, alpha: 1),
        link: NSColor(calibratedRed: 0.45, green: 0.70, blue: 1.0, alpha: 1),
        codeText: NSColor(calibratedRed: 0.93, green: 0.60, blue: 0.68, alpha: 1),
        codeBackground: NSColor(white: 0.17, alpha: 1),
        quoteBar: NSColor(white: 0.33, alpha: 1),
        quoteText: NSColor(white: 0.66, alpha: 1),
        rule: NSColor(white: 0.28, alpha: 1),
        accent: .controlAccentColor,
        trackFill: NSColor(white: 1, alpha: 0.09),
        syntax: .dark
    )

    /// The theme matching an appearance, with user font preferences applied.
    static func current(for appearance: NSAppearance) -> Theme {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        var theme = isDark ? Theme.dark : Theme.light
        let defaults = UserDefaults.standard
        if let name = defaults.string(forKey: "editorFontName"), !name.isEmpty {
            theme.bodyFontName = name
        }
        let size = defaults.double(forKey: "editorFontSize")
        if size >= 9, size <= 48 {
            theme.bodyFontSize = size
            theme.monoFontSize = size - 2
        }
        return theme
    }
}
