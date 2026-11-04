import AppKit

/// The colours text and highlights can take. Markdown has no colour of its
/// own, so they are written as HTML, which markdown passes through:
/// `<span style="color: #E5484D">red</span>` and
/// `<mark style="background: #FFF3A3">highlighted</mark>`. Exports and other
/// markdown apps that keep HTML show them too.
enum TextColor: Int, CaseIterable {
    case red, orange, yellow, green, blue, purple, pink, gray

    var title: String {
        switch self {
        case .red: String(localized: "Red")
        case .orange: String(localized: "Orange")
        case .yellow: String(localized: "Yellow")
        case .green: String(localized: "Green")
        case .blue: String(localized: "Blue")
        case .purple: String(localized: "Purple")
        case .pink: String(localized: "Pink")
        case .gray: String(localized: "Gray")
        }
    }

    /// The English name, which finds it in the `/` menu whatever the language.
    var keyword: String {
        switch self {
        case .red: "red"
        case .orange: "orange"
        case .yellow: "yellow"
        case .green: "green"
        case .blue: "blue"
        case .purple: "purple"
        case .pink: "pink"
        case .gray: "gray"
        }
    }

    /// Mid tones, legible on light and dark pages alike.
    var textHex: String {
        switch self {
        case .red: "#E5484D"
        case .orange: "#F76B15"
        case .yellow: "#D6A100"
        case .green: "#30A46C"
        case .blue: "#3E8EF7"
        case .purple: "#8E4EC6"
        case .pink: "#D6409F"
        case .gray: "#8B8D98"
        }
    }

    /// Pale tints that dark text reads on.
    var highlightHex: String {
        switch self {
        case .red: "#FFD6D6"
        case .orange: "#FFE2C7"
        case .yellow: "#FFF3A3"
        case .green: "#D3F5DC"
        case .blue: "#D5E8FF"
        case .purple: "#E9DDFB"
        case .pink: "#FBDCEE"
        case .gray: "#E8E8EA"
        }
    }

    var textColor: NSColor { ColorMarkup.color(textHex) ?? .labelColor }

    /// A swatch for menus: a dot for text, a rounded square for a highlight.
    /// It is drawn for the appearance it shows in, so on a dark menu a
    /// highlight shows the deeper hue the editor gives it there, not the
    /// pale tint meant for a white page.
    func swatch(highlight: Bool) -> NSImage {
        let pale = ColorMarkup.color(highlightHex) ?? .yellow
        let text = textColor
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let isDark = NSAppearance.currentDrawing().bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let fill: NSColor
            if highlight {
                let wash = ColorMarkup.darkWash(pale)
                fill = isDark ? wash.withAlphaComponent(1).blended(withFraction: 0.15, of: .black) ?? wash : pale
            } else {
                fill = text
            }
            let bounds = rect.insetBy(dx: 0.5, dy: 0.5)
            let shape = highlight ? NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3) : NSBezierPath(ovalIn: bounds)
            fill.setFill()
            shape.fill()
            (isDark ? NSColor.white.withAlphaComponent(0.2) : NSColor.black.withAlphaComponent(0.15)).setStroke()
            shape.lineWidth = 0.5
            shape.stroke()
            return true
        }
        // Drawn afresh each time, so it follows the menu's appearance.
        image.cacheMode = .never
        return image
    }
}

/// What a colour applies to: the letters, or the space behind them.
enum ColorTarget {
    case text, highlight

    var tagName: String { self == .text ? "span" : "mark" }

    var actionName: String {
        self == .text ? String(localized: "Text Color") : String(localized: "Highlight Color")
    }

    func opening(_ color: TextColor) -> String {
        switch self {
        case .text: "<span style=\"color: \(color.textHex)\">"
        case .highlight: "<mark style=\"background: \(color.highlightHex)\">"
        }
    }

    var closing: String { "</\(tagName)>" }

    /// An opening tag of this kind, whatever its colour.
    var openingPattern: String {
        switch self {
        case .text: #"<span\s+style\s*=\s*"\s*color\s*:[^"]*">"#
        case .highlight: #"<mark(?:\s+style\s*=\s*"\s*background(?:-color)?\s*:[^"]*")?>"#
        }
    }
}

/// Reads the colour tags written as HTML: `<span>`, `<mark>` and `<font>`
/// with a `style` (or `color`) giving a colour.
enum ColorMarkup {
    struct Tag: Equatable {
        var name: String
        var isClosing: Bool
        var foreground: NSColor?
        var background: NSColor?
    }

    static let tagNames: Set<String> = ["span", "mark", "font"]

    /// The tag a piece of raw HTML is, if it is one of the colour tags.
    static func tag(_ html: String) -> Tag? {
        guard html.hasPrefix("<"), html.hasSuffix(">"), html.count >= 3 else { return nil }
        var body = html.dropFirst().dropLast()
        let isClosing = body.hasPrefix("/")
        if isClosing { body = body.dropFirst() }
        let name = String(body.prefix { $0.isLetter }).lowercased()
        guard tagNames.contains(name) else { return nil }
        if isClosing { return Tag(name: name, isClosing: true) }

        var tag = Tag(name: name, isClosing: false)
        let attributes = String(body.dropFirst(name.count))
        if let style = attribute("style", in: attributes) {
            for declaration in style.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let property = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(parts[1])
                switch property {
                case "color": tag.foreground = color(value) ?? tag.foreground
                case "background", "background-color": tag.background = color(value) ?? tag.background
                default: break
                }
            }
        }
        if name == "font", let value = attribute("color", in: attributes) {
            tag.foreground = color(value)
        }
        return tag
    }

    /// An attribute's value, quoted with either quote.
    private static func attribute(_ name: String, in attributes: String) -> String? {
        let pattern = "(?i)\\b\(name)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)')"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: attributes, range: NSRange(location: 0, length: (attributes as NSString).length))
        else { return nil }
        for group in 1...2 {
            let range = match.range(at: group)
            if range.location != NSNotFound { return (attributes as NSString).substring(with: range) }
        }
        return nil
    }

    private static let named: [String: String] = [
        "black": "#000000", "white": "#FFFFFF", "red": "#FF0000", "green": "#008000", "blue": "#0000FF",
        "yellow": "#FFFF00", "orange": "#FFA500", "purple": "#800080", "pink": "#FFC0CB", "gray": "#808080",
        "grey": "#808080", "brown": "#A52A2A", "cyan": "#00FFFF", "magenta": "#FF00FF", "lime": "#00FF00",
        "navy": "#000080", "teal": "#008080", "maroon": "#800000", "olive": "#808000", "silver": "#C0C0C0",
        "gold": "#FFD700", "violet": "#EE82EE", "indigo": "#4B0082", "crimson": "#DC143C", "coral": "#FF7F50",
        "salmon": "#FA8072", "tomato": "#FF6347", "orchid": "#DA70D6", "turquoise": "#40E0D0",
        "lightblue": "#ADD8E6", "lightgreen": "#90EE90", "lightyellow": "#FFFFE0", "lightgray": "#D3D3D3",
        "lightgrey": "#D3D3D3", "darkred": "#8B0000", "darkgreen": "#006400", "darkblue": "#00008B",
        "darkorange": "#FF8C00", "darkgray": "#A9A9A9", "darkgrey": "#A9A9A9",
    ]

    /// A highlight for a dark page: the colour's hue, deepened so it still
    /// reads as that colour, laid over the page as a translucent wash that
    /// light text shows through. Greys stay grey.
    static func darkWash(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let isGrey = saturation < 0.05
        return NSColor(
            hue: hue,
            saturation: isGrey ? 0 : max(saturation, 0.7),
            brightness: isGrey ? 0.6 : 0.85,
            alpha: alpha * 0.4
        )
    }

    /// A CSS colour: `#rgb`, `#rrggbb`, `#rrggbbaa`, `rgb()`, `rgba()` or a common name.
    static func color(_ value: String) -> NSColor? {
        var value = value.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix("!important") { value = String(value.dropLast(10)).trimmingCharacters(in: .whitespaces) }
        if let hex = named[value] { value = hex.lowercased() }
        if value.hasPrefix("#") {
            var digits = String(value.dropFirst())
            if digits.count == 3 || digits.count == 4 { digits = digits.map { "\($0)\($0)" }.joined() }
            guard digits.count == 6 || digits.count == 8, let number = UInt64(digits, radix: 16) else { return nil }
            let hasAlpha = digits.count == 8
            let rgb = hasAlpha ? number >> 8 : number
            return NSColor(
                srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255,
                alpha: hasAlpha ? CGFloat(number & 0xFF) / 255 : 1
            )
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
            let parts = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 3 else { return nil }
            func channel(_ part: String) -> CGFloat? {
                if part.hasSuffix("%") { return Double(part.dropLast()).map { CGFloat($0) / 100 } }
                return Double(part).map { CGFloat($0) / 255 }
            }
            guard let red = channel(parts[0]), let green = channel(parts[1]), let blue = channel(parts[2]) else { return nil }
            var alpha: CGFloat = 1
            if parts.count >= 4 {
                let part = parts[3]
                alpha = part.hasSuffix("%") ? (Double(part.dropLast()).map { CGFloat($0) / 100 } ?? 1) : (Double(part).map { CGFloat($0) } ?? 1)
            }
            return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
        }
        return nil
    }
}
