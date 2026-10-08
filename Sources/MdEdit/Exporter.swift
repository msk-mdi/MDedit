import AppKit
import MarkdownKit
import UniformTypeIdentifiers

/// The choices export offers, remembered from one export to the next.
struct ExportOptions: Codable, Equatable {
    /// Writes the theme's stylesheet into exported HTML.
    var includeStylesheet = true
    /// A theme name, or nil for the editor's.
    var themeName: String?
    /// Local images go into the HTML as `data:` URIs.
    var embedImages = false
    /// A table of contents ahead of the content.
    var tableOfContents = false
    /// KaTeX and Mermaid go into the page, when the app carries them.
    var offlineScripts = true
    var paper: Paper = Locale.current.measurementSystem == .us ? .letter : .a4
    var margins: Margins = .normal
    /// The title at the top of each page and its number at the bottom.
    var headerAndFooter = true

    enum Paper: String, Codable, CaseIterable {
        case letter, legal, a4, a5

        var title: String {
            switch self {
            case .letter: "US Letter"
            case .legal: "US Legal"
            case .a4: "A4"
            case .a5: "A5"
            }
        }

        /// In points.
        var size: NSSize {
            switch self {
            case .letter: NSSize(width: 612, height: 792)
            case .legal: NSSize(width: 612, height: 1008)
            case .a4: NSSize(width: 595, height: 842)
            case .a5: NSSize(width: 420, height: 595)
            }
        }
    }

    enum Margins: String, Codable, CaseIterable {
        case narrow, normal, wide

        var title: String { rawValue.capitalized }

        var points: CGFloat {
            switch self {
            case .narrow: 36
            case .normal: 54
            case .wide: 90
            }
        }
    }

    private static let key = "exportOptions"

    static func load(from defaults: UserDefaults = .standard) -> ExportOptions {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(ExportOptions.self, from: $0) } ?? ExportOptions()
    }

    func save(to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Formats written through `NSAttributedString`, from the rendered HTML.
enum RichFormat: CaseIterable {
    case word, richText, plainText

    var title: String {
        switch self {
        case .word: "Word Document"
        case .richText: "Rich Text"
        case .plainText: "Plain Text"
        }
    }

    var type: UTType {
        switch self {
        case .word: UTType("org.openxmlformats.wordprocessingml.document") ?? .data
        case .richText: .rtf
        case .plainText: .plainText
        }
    }

    var fileExtension: String {
        switch self {
        case .word: "docx"
        case .richText: "rtf"
        case .plainText: "txt"
        }
    }
}

/// Export to HTML, PDF, Word, RTF, plain text and — when it is installed —
/// anything Pandoc writes; printing; and rich copies for other apps.
@MainActor
enum Exporter {
    // MARK: - Stylesheet

    /// A theme's light and dark variants as export uses them: the theme's
    /// colours with the chosen code palette, at the unzoomed font size.
    static func variants(themeName: String?, settings: Settings = Settings()) -> (light: Theme, dark: Theme) {
        (
            Theme.current(for: Theme.lightAppearance, settings: settings, themeName: themeName, zoomed: false),
            Theme.current(for: Theme.darkAppearance, settings: settings, themeName: themeName, zoomed: false)
        )
    }

    private static func variables(_ theme: Theme) -> String {
        var lines = [
            "--canvas: \(theme.canvas.cssValue);",
            "--text: \(theme.text.cssValue);",
            "--heading: \(theme.heading.cssValue);",
            "--marker: \(theme.marker.cssValue);",
            "--secondary: \(theme.secondaryText.cssValue);",
            "--link: \(theme.link.cssValue);",
            "--code-text: \(theme.codeText.cssValue);",
            "--code-background: \(theme.codeBackground.cssValue);",
            "--quote-bar: \(theme.quoteBar.cssValue);",
            "--quote-text: \(theme.quoteText.cssValue);",
            "--rule: \(theme.rule.cssValue);",
            "--accent: \(theme.accent.cssValue);",
            "--highlight: \(theme.highlight.cssValue);",
        ]
        for kind in SyntaxPalette.kinds {
            lines.append("--tok-\(ThemeFile.tokenProperty(kind)): \(theme.syntax.color(for: kind).cssValue);")
        }
        return lines.map { "  " + $0 }.joined(separator: "\n")
    }

    private static func fontStack(_ name: String?, fallback: String) -> String {
        guard let name else { return fallback }
        return "\"\(name.replacingOccurrences(of: "\"", with: ""))\", \(fallback)"
    }

    /// A stylesheet matching the editor's look in a theme, so an export reads
    /// like the document you were just editing. Dark mode follows the reader's
    /// system unless `includeDark` is off, as for formats with one appearance.
    static func stylesheet(themeName: String? = nil, settings: Settings = Settings(), includeDark: Bool = true) -> String {
        let (light, dark) = variants(themeName: themeName, settings: settings)
        let body = fontStack(settings.fontName, fallback: "-apple-system, BlinkMacSystemFont, \"Segoe UI\", sans-serif")
        let mono = fontStack(settings.monoFontName, fallback: "ui-monospace, SFMono-Regular, Menlo, monospace")
        // The editor's multiple is of the font's natural height, about 1.2em.
        let lineHeight = String(format: "%.2f", settings.lineHeight * 1.19)
        let darkBlock = includeDark ? """
        @media (prefers-color-scheme: dark) {
        :root {
        \(variables(dark))
        }
        }

        """ : ""
        let tokens = SyntaxPalette.kinds.map { kind in
            let name = ThemeFile.tokenProperty(kind)
            return ".tok-\(name) { color: var(--tok-\(name)); }"
        }.joined(separator: "\n")
        return """
        :root {
          color-scheme: \(includeDark ? "light dark" : "light");
        \(variables(light))
        }
        \(darkBlock)body {
          max-width: 46rem;
          margin: 3rem auto;
          padding: 0 1.25rem;
          font: \(Int(settings.fontSize))px/\(lineHeight) \(body);
          color: var(--text);
          background: var(--canvas);
        }
        h1, h2, h3, h4, h5, h6 { color: var(--heading); line-height: 1.25; margin: 1.6em 0 0.6em; }
        h1 { font-size: 1.9em; }
        h2 { font-size: 1.55em; }
        h3 { font-size: 1.3em; }
        h4 { font-size: 1.15em; }
        p { margin: 0.8em 0; }
        a { color: var(--link); }
        code {
          font: 0.9em \(mono);
          color: var(--code-text);
          background: var(--code-background);
          padding: 0.15em 0.35em;
          border-radius: 4px;
        }
        pre {
          background: var(--code-background);
          padding: 0.9rem 1rem;
          border-radius: 8px;
          overflow-x: auto;
        }
        pre code { background: none; padding: 0; }
        blockquote {
          margin: 1em 0;
          padding: 0.1em 1rem;
          border-left: 3px solid var(--quote-bar);
          color: var(--quote-text);
        }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid var(--rule); padding: 0.4em 0.7em; }
        th { background: var(--code-background); }
        hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
        img { max-width: 100%; }
        mark { background: var(--highlight); color: inherit; padding: 0 0.1em; border-radius: 2px; }
        .heading-number { color: var(--marker); font-weight: normal; margin-right: 0.2em; }
        nav.toc { margin: 1.5em 0 2em; padding: 0.6em 1.2em; border-left: 3px solid var(--rule); }
        nav.toc ul { list-style: none; padding-left: 1.2em; margin: 0.2em 0; }
        nav.toc > ul { padding-left: 0; }
        nav.toc a { text-decoration: none; }
        .footnote-ref { font-size: 0.75em; line-height: 0; }
        .footnote-ref a, .footnote-backref { text-decoration: none; }
        .footnotes {
          margin-top: 3em;
          padding-top: 1em;
          border-top: 1px solid var(--rule);
          font-size: 0.9em;
        }
        .tok-comment { font-style: italic; }
        \(tokens)
        @media print {
          body { max-width: none; margin: 0; background: none; }
          pre, blockquote, table, img { break-inside: avoid; }
          h1, h2, h3, h4, h5, h6 { break-after: avoid; }
        }
        """
    }

    // MARK: - Rendering

    /// KaTeX and Mermaid, when the app bundle carries them
    /// (`Scripts/fetch-vendor.sh` before `Scripts/make-app.sh`).
    static func bundledScripts(in bundle: Bundle = .main) -> HTMLRenderer.ScriptAssets? {
        guard let vendor = bundle.resourceURL?.appendingPathComponent("vendor", isDirectory: true) else { return nil }
        func read(_ path: String) -> String? {
            try? String(contentsOf: vendor.appendingPathComponent(path), encoding: .utf8)
        }
        guard var css = read("katex/katex.min.css"),
              let katex = read("katex/katex.min.js"),
              let autoRender = read("katex/contrib/auto-render.min.js"),
              let mermaid = read("mermaid/mermaid.min.js")
        else { return nil }
        // KaTeX's fonts, inlined so the stylesheet needs nothing beside it.
        let fonts = vendor.appendingPathComponent("katex/fonts", isDirectory: true)
        for file in (try? FileManager.default.contentsOfDirectory(at: fonts, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "woff2" {
            guard let data = try? Data(contentsOf: file) else { continue }
            css = css.replacingOccurrences(
                of: "url(fonts/\(file.lastPathComponent))",
                with: "url(data:font/woff2;base64,\(data.base64EncodedString()))"
            )
        }
        return HTMLRenderer.ScriptAssets(katexCSS: css, katexJS: katex, autoRenderJS: autoRender, mermaidJS: mermaid)
    }

    static func renderer(baseURL: URL?, options: ExportOptions, settings: Settings = Settings()) -> HTMLRenderer {
        var renderer = HTMLRenderer(baseURL: baseURL, extensions: settings.extensions)
        renderer.numberHeadings = settings.numberHeadings
        renderer.embedImages = options.embedImages
        renderer.scripts = options.offlineScripts ? bundledScripts() : nil
        return renderer
    }

    /// The markdown with `[TOC]` placed after any front matter, when asked for.
    static func withTableOfContents(_ markdown: String, extensions: SyntaxExtensions = .all) -> String {
        let structure = BlockStructure(text: markdown as NSString, extensions: extensions)
        var line = 0
        while line < structure.lineCount,
              [.frontMatter, .frontMatterDelimiter].contains(structure.lines[line].kind) {
            line += 1
        }
        let insertion = line < structure.lineCount ? structure.index.range(ofLine: line).location : (markdown as NSString).length
        let text = markdown as NSString
        let separator = insertion > 0 && !text.substring(to: insertion).hasSuffix("\n") ? "\n" : ""
        return text.substring(to: insertion) + separator + "[TOC]\n\n" + text.substring(from: insertion)
    }

    /// A whole page, for Export as HTML.
    static func html(markdown: String, title: String, baseURL: URL?, options: ExportOptions, settings: Settings = Settings()) -> String {
        let source = options.tableOfContents ? withTableOfContents(markdown, extensions: settings.extensions) : markdown
        let css = options.includeStylesheet ? stylesheet(themeName: options.themeName, settings: settings) : ""
        return renderer(baseURL: baseURL, options: options, settings: settings)
            .renderDocument(markdown: source, title: title, css: css)
    }

    static func html(for document: Document, options: ExportOptions = .load()) -> String {
        html(markdown: document.text, title: document.displayName, baseURL: document.url, options: options)
    }

    /// The rendered body only, for pasting into mail or a CMS.
    static func htmlFragment(markdown: String, baseURL: URL?) -> String {
        let settings = Settings()
        var renderer = HTMLRenderer(baseURL: baseURL, extensions: settings.extensions)
        renderer.numberHeadings = settings.numberHeadings
        return renderer.render(markdown: markdown)
    }

    /// The document as styled text, by way of WebKit's HTML import, in the
    /// light variant: Word, Pages and Mail have one appearance.
    static func attributedString(markdown: String, title: String, baseURL: URL?, options: ExportOptions) -> NSAttributedString? {
        var importOptions = options
        importOptions.includeStylesheet = true
        // Imported pages cannot run scripts, and images must be local to be read.
        importOptions.offlineScripts = false
        importOptions.embedImages = true
        let source = options.tableOfContents ? withTableOfContents(markdown, extensions: Settings().extensions) : markdown
        let page = renderer(baseURL: baseURL, options: importOptions).renderDocument(
            markdown: source,
            title: title,
            css: stylesheet(themeName: options.themeName, includeDark: false)
                // Imported text has no page to centre in.
                + "\nbody { max-width: none; margin: 0; padding: 0; background: none; }"
        )
        return try? NSAttributedString(
            data: Data(page.utf8),
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    static func data(for format: RichFormat, from text: NSAttributedString) throws -> Data {
        let range = NSRange(location: 0, length: text.length)
        switch format {
        case .word:
            return try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        case .richText:
            return try text.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case .plainText:
            return Data(text.string.utf8)
        }
    }

    // MARK: - Panels

    private static func defaultName(for document: Document, extension fileExtension: String) -> String {
        (document.url?.deletingPathExtension().lastPathComponent ?? "Untitled") + "." + fileExtension
    }

    /// Runs a save panel as a sheet, with the options view under it.
    private static func save(
        _ document: Document,
        types: [UTType],
        fileExtension: String,
        accessory: ExportAccessory?,
        in window: NSWindow?,
        onError: @escaping (Error) -> Void,
        write: @escaping (URL, ExportOptions) async throws -> Void
    ) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = defaultName(for: document, extension: fileExtension)
        accessory?.panel = panel
        panel.accessoryView = accessory
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            let options = accessory?.options ?? .load()
            options.save()
            Task { @MainActor in
                do {
                    try await write(url, options)
                } catch {
                    onError(error)
                }
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    static func exportHTML(document: Document, in window: NSWindow?, onError: @escaping (Error) -> Void) {
        save(document, types: [.html], fileExtension: "html", accessory: ExportAccessory(kind: .html), in: window, onError: onError) { url, options in
            try html(for: document, options: options).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Lays the document out again at the paper's width and prints that to
    /// PDF, so the export keeps the editor's typography and pages break
    /// between lines.
    static func exportPDF(document: Document, in window: NSWindow?, onError: @escaping (Error) -> Void) {
        save(document, types: [.pdf], fileExtension: "pdf", accessory: ExportAccessory(kind: .pdf), in: window, onError: onError) { url, options in
            let printInfo = printInfo(for: options)
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            let printable = PrintableDocument(document: document, options: options, printInfo: printInfo)
            await printable.waitForImages()
            let operation = printable.operation()
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            guard operation.run() else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
        }
    }

    static func export(document: Document, as format: RichFormat, in window: NSWindow?, onError: @escaping (Error) -> Void) {
        save(document, types: [format.type], fileExtension: format.fileExtension, accessory: ExportAccessory(kind: .rich), in: window, onError: onError) { url, options in
            guard let text = attributedString(markdown: document.text, title: document.displayName, baseURL: document.url, options: options) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
            }
            try data(for: format, from: text).write(to: url, options: .atomic)
        }
    }

    static func exportWithPandoc(document: Document, in window: NSWindow?, onError: @escaping (Error) -> Void) {
        guard let pandoc = Pandoc.executable else { return onError(Pandoc.Failure.notInstalled) }
        let accessory = ExportAccessory(kind: .pandoc)
        let format = Pandoc.formats[accessory.pandocFormatIndex]
        save(document, types: [format.type], fileExtension: format.fileExtension, accessory: accessory, in: window, onError: onError) { url, options in
            let chosen = Pandoc.formats[accessory.pandocFormatIndex]
            try await Pandoc.convert(
                markdown: document.text,
                to: chosen,
                output: url,
                executable: pandoc,
                resourceDirectory: document.url?.deletingLastPathComponent(),
                tableOfContents: options.tableOfContents
            )
        }
    }

    // MARK: - Printing

    static func printInfo(for options: ExportOptions) -> NSPrintInfo {
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.paperSize = options.paper.size
        info.topMargin = options.margins.points
        info.bottomMargin = options.margins.points
        info.leftMargin = options.margins.points
        info.rightMargin = options.margins.points
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.dictionary()[NSPrintInfo.AttributeKey.headerAndFooter] = options.headerAndFooter
        return info
    }

    /// File ▸ Print: the same layout as PDF export, through the print panel.
    static func print(document: Document, in window: NSWindow?) {
        let options = ExportOptions.load()
        let printable = PrintableDocument(document: document, options: options, printInfo: printInfo(for: options))
        Task { @MainActor in
            await printable.waitForImages()
            let operation = printable.operation()
            operation.showsPrintPanel = true
            operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsScaling, .showsPreview])
            if let window {
                operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
            } else {
                operation.run()
            }
        }
    }

    // MARK: - Clipboard

    /// HTML for pasting into a CMS, and the markdown as plain text.
    static func copyHTML(markdown: String, baseURL: URL?) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(htmlFragment(markdown: markdown, baseURL: baseURL), forType: .string)
    }

    /// Styled text for Mail, Pages or Word: RTF and HTML, with the markdown
    /// itself for apps that only take plain text.
    static func copyRichText(markdown: String, baseURL: URL?) {
        var options = ExportOptions.load()
        options.tableOfContents = false
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let text = attributedString(markdown: markdown, title: "", baseURL: baseURL, options: options),
           let rtf = try? data(for: .richText, from: text) {
            pasteboard.setData(rtf, forType: .rtf)
        }
        pasteboard.setString(htmlFragment(markdown: markdown, baseURL: baseURL), forType: .html)
        pasteboard.setString(markdown, forType: .string)
    }
}

// MARK: - Options view

/// The options under an export save panel. Changes are kept as they are made.
@MainActor
final class ExportAccessory: NSView {
    enum Kind { case html, pdf, rich, pandoc }

    private let kind: Kind
    private(set) var options = ExportOptions.load()
    weak var panel: NSSavePanel?

    private let themePopup = NSPopUpButton()
    private let stylesheetBox = NSButton(checkboxWithTitle: "Include stylesheet", target: nil, action: nil)
    private let embedBox = NSButton(checkboxWithTitle: "Embed images in the file", target: nil, action: nil)
    private let offlineBox = NSButton(checkboxWithTitle: "Embed KaTeX and Mermaid (works offline)", target: nil, action: nil)
    private let tocBox = NSButton(checkboxWithTitle: "Add a table of contents", target: nil, action: nil)
    private let paperPopup = NSPopUpButton()
    private let marginsPopup = NSPopUpButton()
    private let headerBox = NSButton(checkboxWithTitle: "Title and page numbers on each page", target: nil, action: nil)
    private let formatPopup = NSPopUpButton()
    private(set) var pandocFormatIndex = 0

    init(kind: Kind) {
        self.kind = kind
        super.init(frame: .zero)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func build() {
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        if kind == .pandoc {
            formatPopup.addItems(withTitles: Pandoc.formats.map { "\($0.title) (.\($0.fileExtension))" })
            pandocFormatIndex = min(UserDefaults.standard.integer(forKey: "pandocFormat"), Pandoc.formats.count - 1)
            formatPopup.selectItem(at: pandocFormatIndex)
            formatPopup.target = self
            formatPopup.action = #selector(formatChanged)
            grid.addRow(with: [NSTextField(labelWithString: "Format:"), formatPopup])
        }
        if kind != .pandoc {
            themePopup.addItem(withTitle: "Editor Theme")
            themePopup.menu?.addItem(.separator())
            themePopup.addItems(withTitles: ThemeCatalog.allNames())
            if let name = options.themeName, themePopup.item(withTitle: name) != nil {
                themePopup.selectItem(withTitle: name)
            }
            grid.addRow(with: [NSTextField(labelWithString: "Theme:"), themePopup])
        }
        if kind == .pdf {
            paperPopup.addItems(withTitles: ExportOptions.Paper.allCases.map(\.title))
            paperPopup.selectItem(at: ExportOptions.Paper.allCases.firstIndex(of: options.paper) ?? 0)
            marginsPopup.addItems(withTitles: ExportOptions.Margins.allCases.map(\.title))
            marginsPopup.selectItem(at: ExportOptions.Margins.allCases.firstIndex(of: options.margins) ?? 1)
            grid.addRow(with: [NSTextField(labelWithString: "Paper:"), paperPopup])
            grid.addRow(with: [NSTextField(labelWithString: "Margins:"), marginsPopup])
            grid.addRow(with: [NSGridCell.emptyContentView, headerBox])
        }
        if kind == .html {
            grid.addRow(with: [NSGridCell.emptyContentView, stylesheetBox])
            grid.addRow(with: [NSGridCell.emptyContentView, embedBox])
            if Exporter.bundledScripts() != nil {
                grid.addRow(with: [NSGridCell.emptyContentView, offlineBox])
            }
        }
        grid.addRow(with: [NSGridCell.emptyContentView, tocBox])

        stylesheetBox.state = options.includeStylesheet ? .on : .off
        embedBox.state = options.embedImages ? .on : .off
        offlineBox.state = options.offlineScripts ? .on : .off
        tocBox.state = options.tableOfContents ? .on : .off
        headerBox.state = options.headerAndFooter ? .on : .off
        for control in [themePopup, stylesheetBox, embedBox, offlineBox, tocBox, paperPopup, marginsPopup, headerBox] as [NSControl] {
            control.target = self
            control.action = #selector(changed)
        }

        addSubview(grid)
        NSLayoutConstraint.activate([
            grid.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -20),
            grid.centerXAnchor.constraint(equalTo: centerXAnchor),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        frame.size = fittingSize
    }

    @objc private func changed() {
        options.themeName = themePopup.indexOfSelectedItem <= 0 ? nil : themePopup.titleOfSelectedItem
        options.includeStylesheet = stylesheetBox.state == .on
        options.embedImages = embedBox.state == .on
        options.offlineScripts = offlineBox.state == .on
        options.tableOfContents = tocBox.state == .on
        options.headerAndFooter = headerBox.state == .on
        if kind == .pdf {
            options.paper = ExportOptions.Paper.allCases[max(0, paperPopup.indexOfSelectedItem)]
            options.margins = ExportOptions.Margins.allCases[max(0, marginsPopup.indexOfSelectedItem)]
        }
    }

    /// A new Pandoc format changes the file's extension in the panel.
    @objc private func formatChanged() {
        pandocFormatIndex = max(0, formatPopup.indexOfSelectedItem)
        UserDefaults.standard.set(pandocFormatIndex, forKey: "pandocFormat")
        let format = Pandoc.formats[pandocFormatIndex]
        guard let panel else { return }
        panel.allowedContentTypes = [format.type]
        let name = (panel.nameFieldStringValue as NSString).deletingPathExtension
        panel.nameFieldStringValue = name + "." + format.fileExtension
    }
}

// MARK: - Print layout

/// A document laid out for paper: its own storage in the theme's light
/// variant, every marker concealed, at the printable width.
@MainActor
final class PrintableDocument {
    let storage: MarkdownTextStorage
    let textView: PrintTextView
    private let layoutManager = MarkdownLayoutManager()
    private let container: NSTextContainer
    private let printInfo: NSPrintInfo

    convenience init(document: Document, options: ExportOptions, printInfo: NSPrintInfo) {
        let settings = Settings()
        var text = document.text
        if options.tableOfContents {
            let headings = document.storage.structure.headings(in: text as NSString)
            if !headings.isEmpty {
                text = Exporter.withTableOfContents(text, extensions: settings.extensions)
                    .replacingOccurrences(of: "[TOC]\n", with: tableOfContentsMarkdown(headings, bullet: settings.bulletMarker) + "\n", options: [], range: nil)
            }
        }
        self.init(markdown: text, title: document.displayName, baseURL: document.url, options: options, printInfo: printInfo, settings: settings)
    }

    init(markdown: String, title: String, baseURL: URL?, options: ExportOptions, printInfo: NSPrintInfo, settings: Settings = Settings()) {
        self.printInfo = printInfo
        var theme = Exporter.variants(themeName: options.themeName, settings: settings).light
        // Paper is the canvas.
        theme.canvas = .white
        storage = MarkdownTextStorage(theme: theme)
        storage.extensions = settings.extensions
        storage.numberHeadings = settings.numberHeadings
        storage.baseURL = baseURL

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        layoutManager.theme = theme
        textView = PrintTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100), textContainer: container)
        textView.documentTitle = title
        textView.isEditable = false
        textView.drawsBackground = false
        // Heading numbers hang in a gutter of their own.
        let gutter: CGFloat = settings.numberHeadings ? 36 : 0
        textView.textContainerInset = NSSize(width: gutter, height: 0)
        container.size = CGSize(width: width - gutter * 2, height: .greatestFiniteMagnitude)
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: markdown)
        // Each image is restricted to the column, like the editor's.
        storage.maxImageWidth = container.size.width - 2 * container.lineFragmentPadding
        sizeToFit()
    }

    /// Images load asynchronously; give them a moment to arrive and make room.
    func waitForImages(timeout: Duration = .seconds(3)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while ImageCache.shared.isLoading, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        sizeToFit()
    }

    private func sizeToFit() {
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        textView.setFrameSize(NSSize(width: textView.frame.width, height: ceil(used.height) + 1))
    }

    func operation() -> NSPrintOperation {
        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.jobTitle = textView.documentTitle
        return operation
    }

    /// The page count at the current paper size, for tests.
    var pageCount: Int {
        let pageHeight = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        return max(1, Int(ceil(textView.frame.height / pageHeight)))
    }
}

/// A text view that prints the document's title in the header and
/// "page of pages" in the footer.
final class PrintTextView: NSTextView {
    var documentTitle = ""

    private func centred(_ text: String) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        return NSAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: style,
        ])
    }

    override var pageHeader: NSAttributedString {
        centred(documentTitle)
    }

    override var pageFooter: NSAttributedString {
        guard let operation = NSPrintOperation.current else { return super.pageFooter }
        return centred("\(operation.currentPage) of \(operation.pageRange.length)")
    }
}

// MARK: - Pandoc

/// Pandoc, when installed, for the formats MdEdit does not write itself.
enum Pandoc {
    struct Format {
        var title: String
        var fileExtension: String
        /// Pandoc's name for the writer.
        var writer: String

        var type: UTType { UTType(filenameExtension: fileExtension) ?? .data }
    }

    static let formats: [Format] = [
        Format(title: "Word", fileExtension: "docx", writer: "docx"),
        Format(title: "OpenDocument Text", fileExtension: "odt", writer: "odt"),
        Format(title: "EPUB", fileExtension: "epub", writer: "epub"),
        Format(title: "LaTeX", fileExtension: "tex", writer: "latex"),
        Format(title: "Typst", fileExtension: "typ", writer: "typst"),
        Format(title: "reStructuredText", fileExtension: "rst", writer: "rst"),
        Format(title: "AsciiDoc", fileExtension: "adoc", writer: "asciidoc"),
        Format(title: "Org", fileExtension: "org", writer: "org"),
        Format(title: "MediaWiki", fileExtension: "wiki", writer: "mediawiki"),
        Format(title: "PowerPoint", fileExtension: "pptx", writer: "pptx"),
    ]

    enum Failure: LocalizedError {
        case notInstalled
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled: "Pandoc is not installed."
            case let .failed(message): "Pandoc could not export the document.\n\n\(message)"
            }
        }
    }

    /// Apps launched from Finder do not inherit the shell's PATH, so the
    /// usual install locations are looked at directly.
    static var executable: URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/homebrew/bin/pandoc", "/usr/local/bin/pandoc", "/opt/local/bin/pandoc",
            "\(home)/.local/bin/pandoc", "\(home)/.cabal/bin/pandoc", "/usr/bin/pandoc",
        ]
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    static func arguments(for format: Format, output: URL, resourceDirectory: URL?, tableOfContents: Bool) -> [String] {
        var arguments = ["--from", "markdown", "--to", format.writer, "--standalone", "--output", output.path]
        if let resourceDirectory { arguments += ["--resource-path", resourceDirectory.path] }
        if tableOfContents { arguments.append("--toc") }
        return arguments
    }

    static func convert(
        markdown: String,
        to format: Format,
        output: URL,
        executable: URL,
        resourceDirectory: URL?,
        tableOfContents: Bool
    ) async throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments(for: format, output: output, resourceDirectory: resourceDirectory, tableOfContents: tableOfContents)
        if let resourceDirectory { process.currentDirectoryURL = resourceDirectory }
        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { process in
                continuation.yield(process.terminationStatus)
                continuation.finish()
            }
        }
        try process.run()
        // Fed and drained off the main thread, so neither pipe can fill and stall.
        let writer = input.fileHandleForWriting
        let data = Data(markdown.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            writer.write(data)
            try? writer.close()
        }
        let reader = errors.fileHandleForReading
        let message = await Task.detached { String(decoding: reader.readDataToEndOfFile(), as: UTF8.self) }.value
        var status: Int32 = -1
        for await code in exited { status = code }
        guard status == 0 else {
            throw Failure.failed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
