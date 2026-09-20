import AppKit
import MarkdownKit

/// HTML and PDF export.
@MainActor
enum Exporter {
    /// A stylesheet matching the editor's own look, so an export reads like the
    /// document you were just editing.
    static func stylesheet(theme: Theme) -> String {
        """
        :root { color-scheme: light dark; }
        body {
          max-width: 46rem;
          margin: 3rem auto;
          padding: 0 1.25rem;
          font: \(Int(theme.bodyFontSize))px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
          color: #1f2124;
          background: #fbfbfb;
        }
        h1, h2, h3, h4, h5, h6 { line-height: 1.25; margin: 1.6em 0 0.6em; }
        h1 { font-size: 1.9em; }
        h2 { font-size: 1.5em; }
        p { margin: 0.8em 0; }
        a { color: #1a6ad9; }
        code {
          font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace;
          background: rgba(127, 127, 127, 0.14);
          padding: 0.15em 0.35em;
          border-radius: 4px;
        }
        pre {
          background: rgba(127, 127, 127, 0.12);
          padding: 0.9rem 1rem;
          border-radius: 8px;
          overflow-x: auto;
        }
        pre code { background: none; padding: 0; }
        blockquote {
          margin: 1em 0;
          padding: 0.1em 1rem;
          border-left: 3px solid rgba(127, 127, 127, 0.4);
          color: #5c6066;
        }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid rgba(127, 127, 127, 0.3); padding: 0.4em 0.7em; }
        th { background: rgba(127, 127, 127, 0.1); }
        hr { border: none; border-top: 1px solid rgba(127, 127, 127, 0.35); margin: 2em 0; }
        img { max-width: 100%; }
        .tok-keyword { color: #9c2290; }
        .tok-type { color: #296688; }
        .tok-constant { color: #6b38bf; }
        .tok-string { color: #c42e29; }
        .tok-number { color: #1c54c7; }
        .tok-comment { color: #667a70; font-style: italic; }
        .tok-function { color: #3354a3; }
        .tok-variable { color: #b86217; }
        .tok-attribute { color: #595c22; }
        .tok-tag { color: #247059; }
        .tok-inserted { color: #187534; }
        .tok-deleted { color: #b32626; }
        @media (prefers-color-scheme: dark) {
          body { color: #e0e2e6; background: #1e1f22; }
          a { color: #74a9ff; }
          blockquote { color: #a8adb5; }
          .tok-keyword { color: #fa78bf; }
          .tok-type { color: #8ad4f0; }
          .tok-constant { color: #ba9eff; }
          .tok-string { color: #fd8c7a; }
          .tok-number { color: #d6ca87; }
          .tok-comment { color: #82948a; }
          .tok-function { color: #7dbaff; }
          .tok-variable { color: #ffb86b; }
          .tok-attribute { color: #ccd987; }
          .tok-tag { color: #6bd9b3; }
          .tok-inserted { color: #82db8f; }
          .tok-deleted { color: #ff8585; }
        }
        """
    }

    static func html(for document: Document, theme: Theme) -> String {
        var renderer = HTMLRenderer()
        renderer.baseURL = document.url
        return renderer.renderDocument(
            markdown: document.text,
            title: document.displayName,
            css: stylesheet(theme: theme)
        )
    }

    /// The rendered body only, for pasting into mail or a CMS.
    static func htmlFragment(for document: Document) -> String {
        var renderer = HTMLRenderer()
        renderer.baseURL = document.url
        return renderer.render(markdown: document.text)
    }

    static func exportHTML(document: Document, theme: Theme, in window: NSWindow?, onError: @escaping (Error) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = (document.url?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".html"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try html(for: document, theme: theme).write(to: url, atomically: true, encoding: .utf8)
            } catch {
                onError(error)
            }
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }

    /// Prints the laid-out text view to PDF, so the export matches the editor's
    /// typography rather than a second rendering path.
    static func exportPDF(from editor: EditorViewController, document: Document, in window: NSWindow?, onError: @escaping (Error) -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = (document.url?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".pdf"
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }

            let printInfo = NSPrintInfo.shared.copy() as! NSPrintInfo
            printInfo.jobDisposition = .save
            printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
            printInfo.topMargin = 48
            printInfo.bottomMargin = 48
            printInfo.leftMargin = 48
            printInfo.rightMargin = 48
            printInfo.isHorizontallyCentered = true

            let operation = NSPrintOperation(view: editor.textView, printInfo: printInfo)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            operation.run()
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
