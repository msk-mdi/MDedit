import AppKit
import Testing
@testable import MarkdownKit
@testable import MdEdit

@MainActor
@Suite("Settings")
struct SettingsTests {
    private func withDefaults(_ body: (Settings) throws -> Void) throws {
        let suite = "MdEditSettingsTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(Settings(defaults: defaults))
    }

    @Test("Missing and out-of-range values fall back to defaults")
    func fallbacks() throws {
        try withDefaults { settings in
            #expect(settings.fontSize == 15)
            #expect(settings.lineHeight == 1.35)
            #expect(settings.extensions == .all)
            #expect(settings.bulletMarker == "-")
            settings.defaults.set(400.0, forKey: Settings.Key.fontSize)
            settings.defaults.set("?", forKey: Settings.Key.bulletMarker)
            #expect(settings.fontSize == 15)
            #expect(settings.bulletMarker == "-")
            settings.zoom = 10
            #expect(settings.zoom == Settings.zoomRange.upperBound)
            settings.extensions = [.math]
            #expect(settings.extensions == [.math])
        }
    }

    @Test("The theme follows settings: family, code palette, fonts and zoom")
    func currentTheme() throws {
        try withDefaults { settings in
            settings.themeName = "Solarized"
            settings.codeThemeName = "Monokai"
            settings.fontSize = 16
            settings.zoom = 1.5
            settings.lineHeight = 1.6
            let dark = Theme.current(for: NSAppearance(named: .darkAqua)!, settings: settings)
            #expect(dark.canvas.cssValue == "#002b36")
            #expect(dark.syntax.keyword.cssValue == "#f92672")
            #expect(dark.bodyFontSize == 24)
            #expect(dark.monoFontSize == 21)
            #expect(dark.lineHeight == 1.6)
            let light = Theme.current(for: NSAppearance(named: .aqua)!, settings: settings)
            #expect(light.canvas.cssValue == "#fdf6e3")
        }
    }

    @Test("Theme files: a base, per-appearance blocks, and warnings for mistakes")
    func themeFile() {
        let result = ThemeFile.parse("""
        /* comment { not a block } */
        :root { base: Nord; highlight: rgba(255, 0, 0, 0.5); }
        light { canvas: #fff; syntax-keyword: #123456; }
        dark { text: #abcdef; }
        dark { wobble: #000; link: banana; }
        sidebar { canvas: #000; }
        """, name: "Mine")
        #expect(result.family.name == "Mine")
        #expect(result.family.light.canvas.cssValue == "#ffffff")
        #expect(result.family.light.syntax.keyword.cssValue == "#123456")
        #expect(result.family.dark.text.cssValue == "#abcdef")
        // Untouched values come from Nord.
        #expect(result.family.dark.canvas.cssValue == "#2e3440")
        #expect(result.family.light.highlight.cssValue == "rgba(255, 0, 0, 0.50)")
        #expect(result.warnings.count == 3)
    }

    @Test("Custom themes are found by name in their folder")
    func customLookup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditThemes-\(UUID().uuidString)")
        let example = try ThemeCatalog.installExample(in: directory)
        #expect(ThemeCatalog.allNames(in: directory).last == "Example")
        #expect(ThemeCatalog.family(named: "Example", in: directory).light.canvas.cssValue == "#fffdf7")
        #expect(ThemeCatalog.family(named: "Nope", in: directory).name == ThemeCatalog.defaultName)
        #expect(ThemeFile.parse(try String(contentsOf: example, encoding: .utf8), name: "Example").warnings.isEmpty)
    }

    @Test("Space after blocks lands on a block's last line only")
    func paragraphSpacing() throws {
        var theme = Theme.light
        theme.paragraphSpacing = 10
        let storage = MarkdownTextStorage(theme: theme)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "one\ntwo\n\nthree")
        func spacing(at location: Int) -> CGFloat {
            (storage.attribute(.paragraphStyle, at: location, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing ?? -1
        }
        #expect(spacing(at: 0) == 0)
        #expect(spacing(at: 4) == 10)
        // Typing a blank line under "three"'s predecessor restyles it.
        storage.replaceCharacters(in: NSRange(location: 3, length: 0), with: "\n")
        #expect(spacing(at: 0) == 10)
    }

    @Test("Turning an extension off restyles: `==x==` loses its highlight")
    func storageExtensions() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "a ==b== c")
        #expect(storage.attribute(.backgroundColor, at: 4, effectiveRange: nil) != nil)
        storage.extensions = .all.subtracting(.highlight)
        #expect(storage.attribute(.backgroundColor, at: 4, effectiveRange: nil) == nil)
    }

    @Test("Heading numbers follow edits")
    func headingNumbers() {
        let storage = MarkdownTextStorage(theme: .light)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# A\n## B\n# C")
        #expect(storage.headingNumber(forLine: 1) == "1.1")
        #expect(storage.headingNumber(forLine: 2) == "2")
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Z\n")
        #expect(storage.headingNumber(forLine: 3) == "3")
    }

    @Test("View modes are remembered per tab, and old sessions still load")
    func viewModes() throws {
        let tab = Session.Tab(url: URL(fileURLWithPath: "/tmp/a.md"), selectedLocation: 0, sourceMode: true, typewriterMode: false, focusMode: true)
        let data = try JSONEncoder().encode(tab)
        #expect(try JSONDecoder().decode(Session.Tab.self, from: data) == tab)
        let old = try JSONDecoder().decode(Session.Tab.self, from: Data(#"{"url":"file:///tmp/a.md","selectedLocation":3}"#.utf8))
        #expect(old.sourceMode == nil)
    }
}
