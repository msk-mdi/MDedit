import AppKit
import MarkdownKit

/// The built-in themes and code palettes, plus any theme files the user has
/// put in `~/Library/Application Support/MdEdit/Themes`.
@MainActor
enum ThemeCatalog {
    static let defaultName = "Default"
    /// The code-palette choice that uses whatever the theme itself defines.
    static let matchTheme = "Match Theme"
    static let fileExtension = "mdtheme"

    static var customDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MdEdit/Themes", isDirectory: true)
    }

    // MARK: - Lookup

    static var builtIns: [ThemeFamily] {
        [
            ThemeFamily(name: defaultName, light: .light, dark: .dark),
            paper,
            solarized,
            nord,
        ]
    }

    /// Every theme name, built-ins first.
    static func allNames(in directory: URL = customDirectory) -> [String] {
        builtIns.map(\.name) + customThemeFiles(in: directory).map { $0.deletingPathExtension().lastPathComponent }
    }

    /// A built-in theme, a theme file of that name, or Default.
    static func family(named name: String, in directory: URL = customDirectory) -> ThemeFamily {
        if let builtIn = builtIns.first(where: { $0.name == name }) { return builtIn }
        let file = directory.appendingPathComponent(name).appendingPathExtension(fileExtension)
        if let source = try? String(contentsOf: file, encoding: .utf8) {
            return ThemeFile.parse(source, name: name).family
        }
        return builtIns[0]
    }

    static func customThemeFiles(in directory: URL = customDirectory) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files
            .filter { $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static var codePalettes: [CodePalette] {
        [
            CodePalette(name: "Xcode", light: .light, dark: .dark),
            CodePalette(name: "GitHub", light: githubLight, dark: githubDark),
            CodePalette(name: "Solarized", light: solarizedSyntax(comment: "#93a1a1"), dark: solarizedSyntax(comment: "#586e75")),
            CodePalette(name: "Nord", light: nordSyntaxLight, dark: nordSyntaxDark),
            CodePalette(name: "Monokai", light: monokaiLight, dark: monokaiDark),
        ]
    }

    /// Nil for Match Theme, or a name that is not a palette.
    static func codePalette(named name: String) -> CodePalette? {
        codePalettes.first { $0.name == name }
    }

    /// Writes a commented example theme to start from, and returns it.
    static func installExample(in directory: URL = customDirectory) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("Example").appendingPathExtension(fileExtension)
        if !FileManager.default.fileExists(atPath: url.path) {
            try ThemeFile.example.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    // MARK: - Built-in themes

    private static let paper = ThemeFamily(
        name: "Paper",
        light: Theme(
            canvas: NSColor(hex: "#f8f1e3")!, text: NSColor(hex: "#3b3127")!, heading: NSColor(hex: "#2a2118")!,
            marker: NSColor(hex: "#b3a48c")!, secondaryText: NSColor(hex: "#7d6e5b")!, link: NSColor(hex: "#2f6f9f")!,
            codeText: NSColor(hex: "#8c3b2e")!, codeBackground: NSColor(hex: "#efe6d2")!, quoteBar: NSColor(hex: "#d8c9a8")!,
            quoteText: NSColor(hex: "#6b5d4b")!, rule: NSColor(hex: "#e0d4bb")!, accent: NSColor(hex: "#b5651d")!,
            trackFill: NSColor(white: 0, alpha: 0.06), syntax: .light
        ),
        dark: Theme(
            canvas: NSColor(hex: "#2a251f")!, text: NSColor(hex: "#e6dccb")!, heading: NSColor(hex: "#f5ecdc")!,
            marker: NSColor(hex: "#7d715f")!, secondaryText: NSColor(hex: "#a89a85")!, link: NSColor(hex: "#8cb8de")!,
            codeText: NSColor(hex: "#e5a48f")!, codeBackground: NSColor(hex: "#352f27")!, quoteBar: NSColor(hex: "#5a4f40")!,
            quoteText: NSColor(hex: "#bfb19b")!, rule: NSColor(hex: "#4a4136")!, accent: NSColor(hex: "#d9925a")!,
            trackFill: NSColor(white: 1, alpha: 0.08), syntax: .dark
        )
    )

    private static let solarized = ThemeFamily(
        name: "Solarized",
        light: Theme(
            canvas: NSColor(hex: "#fdf6e3")!, text: NSColor(hex: "#586e75")!, heading: NSColor(hex: "#073642")!,
            marker: NSColor(hex: "#93a1a1")!, secondaryText: NSColor(hex: "#839496")!, link: NSColor(hex: "#268bd2")!,
            codeText: NSColor(hex: "#d33682")!, codeBackground: NSColor(hex: "#eee8d5")!, quoteBar: NSColor(hex: "#d6cfb9")!,
            quoteText: NSColor(hex: "#657b83")!, rule: NSColor(hex: "#e4ddc8")!, accent: NSColor(hex: "#268bd2")!,
            trackFill: NSColor(white: 0, alpha: 0.06), syntax: solarizedSyntax(comment: "#93a1a1")
        ),
        dark: Theme(
            canvas: NSColor(hex: "#002b36")!, text: NSColor(hex: "#93a1a1")!, heading: NSColor(hex: "#eee8d5")!,
            marker: NSColor(hex: "#586e75")!, secondaryText: NSColor(hex: "#839496")!, link: NSColor(hex: "#268bd2")!,
            codeText: NSColor(hex: "#d33682")!, codeBackground: NSColor(hex: "#073642")!, quoteBar: NSColor(hex: "#2a4a52")!,
            quoteText: NSColor(hex: "#839496")!, rule: NSColor(hex: "#0d3d4a")!, accent: NSColor(hex: "#2aa198")!,
            trackFill: NSColor(white: 1, alpha: 0.08), syntax: solarizedSyntax(comment: "#586e75")
        )
    )

    private static let nord = ThemeFamily(
        name: "Nord",
        light: Theme(
            canvas: NSColor(hex: "#eceff4")!, text: NSColor(hex: "#2e3440")!, heading: NSColor(hex: "#242933")!,
            marker: NSColor(hex: "#9aa3b5")!, secondaryText: NSColor(hex: "#4c566a")!, link: NSColor(hex: "#5e81ac")!,
            codeText: NSColor(hex: "#8f6a8a")!, codeBackground: NSColor(hex: "#e5e9f0")!, quoteBar: NSColor(hex: "#c5ccd9")!,
            quoteText: NSColor(hex: "#4c566a")!, rule: NSColor(hex: "#d8dee9")!, accent: NSColor(hex: "#5e81ac")!,
            trackFill: NSColor(white: 0, alpha: 0.06), syntax: nordSyntaxLight
        ),
        dark: Theme(
            canvas: NSColor(hex: "#2e3440")!, text: NSColor(hex: "#d8dee9")!, heading: NSColor(hex: "#eceff4")!,
            marker: NSColor(hex: "#616e88")!, secondaryText: NSColor(hex: "#9aa5b8")!, link: NSColor(hex: "#88c0d0")!,
            codeText: NSColor(hex: "#b48ead")!, codeBackground: NSColor(hex: "#3b4252")!, quoteBar: NSColor(hex: "#4c566a")!,
            quoteText: NSColor(hex: "#b0b9c9")!, rule: NSColor(hex: "#434c5e")!, accent: NSColor(hex: "#88c0d0")!,
            trackFill: NSColor(white: 1, alpha: 0.08), syntax: nordSyntaxDark
        )
    )

    // MARK: - Built-in code palettes

    /// Twelve colours in `SyntaxPalette.kinds` order.
    private static func palette(_ hexes: [String]) -> SyntaxPalette {
        var palette = SyntaxPalette.light
        for (kind, hex) in zip(SyntaxPalette.kinds, hexes) {
            if let color = NSColor(hex: hex) { palette.set(color, for: kind) }
        }
        return palette
    }

    private static func solarizedSyntax(comment: String) -> SyntaxPalette {
        palette(["#859900", "#b58900", "#6c71c4", "#2aa198", "#d33682", comment,
                 "#268bd2", "#cb4b16", "#b58900", "#268bd2", "#859900", "#dc322f"])
    }

    private static let githubLight = palette(["#cf222e", "#953800", "#0550ae", "#0a3069", "#0550ae", "#6e7781",
                                              "#8250df", "#953800", "#0550ae", "#116329", "#116329", "#82071e"])
    private static let githubDark = palette(["#ff7b72", "#ffa657", "#79c0ff", "#a5d6ff", "#79c0ff", "#8b949e",
                                             "#d2a8ff", "#ffa657", "#79c0ff", "#7ee787", "#aff5b4", "#ffa198"])
    private static let nordSyntaxLight = palette(["#5e81ac", "#4c8c8a", "#8f6a8a", "#6a8a4f", "#8f6a8a", "#7b88a1",
                                                  "#3f7f96", "#b0623a", "#4c8c8a", "#5e81ac", "#6a8a4f", "#bf616a"])
    private static let nordSyntaxDark = palette(["#81a1c1", "#8fbcbb", "#b48ead", "#a3be8c", "#b48ead", "#616e88",
                                                 "#88c0d0", "#d08770", "#8fbcbb", "#81a1c1", "#a3be8c", "#bf616a"])
    private static let monokaiLight = palette(["#d0105a", "#1c8ca8", "#7a4fd1", "#998a00", "#7a4fd1", "#8a8572",
                                               "#5f8f00", "#c96a00", "#5f8f00", "#d0105a", "#5f8f00", "#d0105a"])
    private static let monokaiDark = palette(["#f92672", "#66d9ef", "#ae81ff", "#e6db74", "#ae81ff", "#75715e",
                                              "#a6e22e", "#fd971f", "#a6e22e", "#f92672", "#a6e22e", "#f92672"])
}

/// A theme file: CSS-like blocks of `name: value;` declarations.
///
///     :root { base: Paper; }            /* start from a built-in theme */
///     light { canvas: #fffdf7; link: #0b6bcb; }
///     dark  { canvas: #1b1b1d; keyword: #ff79c6; }
///
/// `:root` (or `*`) applies to both variants; `light` and `dark` to one.
/// Anything left out comes from the base theme.
enum ThemeFile {
    struct Result {
        var family: ThemeFamily
        /// Declarations that were not understood, for the user to fix.
        var warnings: [String]
    }

    /// Names of the colour properties, as written in a theme file.
    static let colorProperties: [String] = [
        "canvas", "text", "heading", "marker", "secondary-text", "link", "code-text", "code-background",
        "quote-bar", "quote-text", "rule", "accent", "track-fill", "highlight",
    ] + SyntaxPalette.kinds.map(tokenProperty)

    static func tokenProperty(_ kind: TokenKind) -> String {
        "\(kind)"
    }

    @MainActor
    static func parse(_ source: String, name: String) -> Result {
        var warnings: [String] = []
        var blocks: [(selectors: [String], declarations: [(String, String)])] = []

        // Comments out, then `selector { … }` blocks.
        let stripped = source.replacingOccurrences(of: #"/\*[\s\S]*?\*/"#, with: "", options: .regularExpression)
        var rest = Substring(stripped)
        while let open = rest.firstIndex(of: "{") {
            let selectorText = rest[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let close = rest[open...].firstIndex(of: "}") else {
                warnings.append("Unclosed block after “\(selectorText)”")
                break
            }
            let body = rest[rest.index(after: open)..<close]
            let selectors = selectorText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            var declarations: [(String, String)] = []
            for declaration in body.split(separator: ";") {
                let parts = declaration.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else {
                    let text = declaration.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty { warnings.append("Not a declaration: “\(text)”") }
                    continue
                }
                declarations.append((
                    parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                    parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
            blocks.append((selectors, declarations))
            rest = rest[rest.index(after: close)...]
        }

        // The base is chosen first, wherever it was written.
        var base = ThemeCatalog.builtIns[0]
        for block in blocks {
            for (property, value) in block.declarations where property == "base" {
                if let builtIn = ThemeCatalog.builtIns.first(where: { $0.name.lowercased() == value.lowercased() }) {
                    base = builtIn
                } else {
                    warnings.append("Unknown base theme “\(value)”")
                }
            }
        }

        var family = ThemeFamily(name: name, light: base.light, dark: base.dark)
        for block in blocks {
            for selector in block.selectors where ![":root", "*", "light", "dark"].contains(selector) {
                warnings.append("Unknown selector “\(selector)”; use :root, light or dark")
            }
            let toLight = block.selectors.contains { [":root", "*", "light"].contains($0) }
            let toDark = block.selectors.contains { [":root", "*", "dark"].contains($0) }
            for (property, value) in block.declarations where property != "base" {
                guard let color = NSColor(cssColor: value) else {
                    warnings.append("Not a colour: “\(property): \(value)”")
                    continue
                }
                var known = true
                if toLight { known = apply(color, to: property, in: &family.light) }
                if toDark { known = apply(color, to: property, in: &family.dark) }
                if !known { warnings.append("Unknown property “\(property)”") }
            }
        }
        return Result(family: family, warnings: warnings)
    }

    /// Sets one property; false when there is no such property.
    private static func apply(_ color: NSColor, to property: String, in theme: inout Theme) -> Bool {
        let name = property.hasPrefix("syntax-") ? String(property.dropFirst(7)) : property
        switch name {
        case "canvas": theme.canvas = color
        case "text": theme.text = color
        case "heading": theme.heading = color
        case "marker": theme.marker = color
        case "secondary-text": theme.secondaryText = color
        case "link": theme.link = color
        case "code-text": theme.codeText = color
        case "code-background": theme.codeBackground = color
        case "quote-bar": theme.quoteBar = color
        case "quote-text": theme.quoteText = color
        case "rule": theme.rule = color
        case "accent": theme.accent = color
        case "track-fill": theme.trackFill = color
        case "highlight": theme.highlight = color
        default:
            guard let kind = SyntaxPalette.kinds.first(where: { tokenProperty($0) == name }) else { return false }
            theme.syntax.set(color, for: kind)
        }
        return true
    }

    static let example = """
    /*
      An MdEdit theme. Save files like this one in this folder with the
      .mdtheme extension, then choose them in Settings ▸ Appearance.

      :root applies to both appearances; light and dark to one each.
      Colours: #rgb, #rrggbb, #rrggbbaa, rgb(…) or rgba(…).
      Anything left out comes from the base theme.

      Properties: canvas, text, heading, marker, secondary-text, link,
      code-text, code-background, quote-bar, quote-text, rule, accent,
      track-fill, highlight — and for code: keyword, type, constant, string,
      number, comment, function, variable, attribute, tag, inserted, deleted.
    */

    :root {
      base: Default;
      highlight: rgba(255, 214, 0, 0.35);
    }

    light {
      canvas: #fffdf7;
      text: #23211d;
      link: #0b6bcb;
      accent: #0b6bcb;
    }

    dark {
      canvas: #19191b;
      text: #e4e2dd;
      link: #6cb4ff;
      accent: #6cb4ff;
    }

    """
}

extension NSColor {
    /// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa`, in sRGB.
    convenience init?(hex: String) {
        var digits = hex.trimmingCharacters(in: .whitespaces)
        guard digits.hasPrefix("#") else { return nil }
        digits.removeFirst()
        if digits.count == 3 || digits.count == 4 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard digits.count == 6 || digits.count == 8, let value = UInt64(digits, radix: 16) else { return nil }
        let hasAlpha = digits.count == 8
        let red = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// A hex colour, or `rgb(r, g, b)` / `rgba(r, g, b, a)`.
    convenience init?(cssColor value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespaces).lowercased()
        if trimmed.hasPrefix("#") {
            self.init(hex: trimmed)
            return
        }
        guard trimmed.hasPrefix("rgb"), let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") else { return nil }
        let numbers = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard numbers.count == 3 || numbers.count == 4 else { return nil }
        self.init(
            srgbRed: numbers[0] / 255, green: numbers[1] / 255, blue: numbers[2] / 255,
            alpha: numbers.count == 4 ? numbers[3] : 1
        )
    }

    /// CSS for this colour as it resolves now: `#rrggbb`, or `rgba(…)` when translucent.
    var cssValue: String {
        guard let color = usingColorSpace(.sRGB) else { return "inherit" }
        let red = Int((color.redComponent * 255).rounded())
        let green = Int((color.greenComponent * 255).rounded())
        let blue = Int((color.blueComponent * 255).rounded())
        if color.alphaComponent < 0.999 {
            return "rgba(\(red), \(green), \(blue), \(String(format: "%.2f", color.alphaComponent)))"
        }
        return String(format: "#%02x%02x%02x", red, green, blue)
    }
}
