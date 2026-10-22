import Foundation
import MarkdownKit
import QuickLookUI
import UniformTypeIdentifiers

/// Space-bar previews of markdown files in Finder, rendered by the same
/// parser and HTML renderer as the app's export.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var markdown = try Self.text(of: Self.leadingLines(of: data, upTo: Self.limit))
        if data.count > Self.limit {
            // An extension has little memory and Finder waits on it: a huge
            // file previews its beginning, and says so.
            let shown = ByteCountFormatter.string(fromByteCount: Int64(Self.limit), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            markdown += "\n\n---\n\n*" + String(localized: "Preview of the first \(shown) of \(total).") + "*\n"
        }
        var renderer = HTMLRenderer(baseURL: url)
        // A preview shows a file it did not ask for: its raw HTML stays
        // visible as markup but runs nothing and loads nothing but images.
        renderer.contentSecurityPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src file: data:"
        let html = renderer.renderDocument(
            markdown: markdown,
            title: url.deletingPathExtension().lastPathComponent,
            css: Self.stylesheet
        )
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { reply in
            reply.stringEncoding = .utf8
            return Data(html.utf8)
        }
    }

    /// The most a preview renders.
    static let limit = 1_000_000

    /// Whole lines from the start, at most `limit` bytes. A cut after a line
    /// break never splits a character in UTF-8 or a single-byte encoding;
    /// UTF-16, whose line breaks are two bytes, is cut at a code unit.
    static func leadingLines(of data: Data, upTo limit: Int) -> Data {
        guard data.count > limit else { return data }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return data.prefix(limit & ~1) }
        let head = data.prefix(limit)
        if let newline = head.lastIndex(of: 0x0A) { return data[data.startIndex...newline] }
        // One enormous line: drop a UTF-8 character the cut runs through.
        var lead = head.endIndex
        while lead > head.startIndex, head[lead - 1] & 0xC0 == 0x80 { lead -= 1 }
        guard lead > head.startIndex, head[lead - 1] >= 0xC0 else { return head }
        let length = head[lead - 1] >= 0xF0 ? 4 : head[lead - 1] >= 0xE0 ? 3 : 2
        return head.endIndex - (lead - 1) == length ? head : data[data.startIndex..<(lead - 1)]
    }

    /// UTF-8 when it is, else whatever encoding Foundation recognises.
    static func text(of data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        var converted: NSString?
        guard NSString.stringEncoding(for: data, encodingOptions: nil, convertedString: &converted, usedLossyConversion: nil) != 0,
              let converted
        else { throw CocoaError(.fileReadInapplicableStringEncoding) }
        return converted as String
    }

    /// The Default theme, light and dark, cut down to what a preview shows.
    static let stylesheet = """
    :root {
      color-scheme: light dark;
      --text: #212121; --heading: #121212; --link: #1a6bd9; --rule: #d9d9d9;
      --code-text: #a12b54; --code-background: #f0f0f0; --quote-bar: #cccccc; --quote-text: #616161;
      --highlight: rgba(255, 204, 0, 0.32);
      --tok-keyword: #9c218f; --tok-type: #296687; --tok-string: #c42e29; --tok-number: #1c54c7;
      --tok-comment: #66786e; --tok-function: #3354a3;
    }
    @media (prefers-color-scheme: dark) {
      :root {
        --text: #dedede; --heading: #f2f2f2; --link: #6aa9ff; --rule: #3a3a3c;
        --code-text: #ff8fb1; --code-background: #2a2a2d; --quote-bar: #4a4a4d; --quote-text: #a6a6a6;
        --tok-keyword: #fa78bf; --tok-type: #8ad4f0; --tok-string: #fc8c7a; --tok-number: #d6c987;
        --tok-comment: #829489; --tok-function: #7dbaff;
      }
    }
    body {
      max-width: 46rem; margin: 2.5rem auto; padding: 0 1.25rem;
      font: 15px/1.6 -apple-system, BlinkMacSystemFont, sans-serif; color: var(--text);
    }
    h1, h2, h3, h4, h5, h6 { color: var(--heading); line-height: 1.25; margin: 1.6em 0 0.6em; }
    h1 { font-size: 1.9em; } h2 { font-size: 1.55em; } h3 { font-size: 1.3em; } h4 { font-size: 1.15em; }
    a { color: var(--link); }
    code { font: 0.9em ui-monospace, SFMono-Regular, Menlo, monospace; color: var(--code-text);
      background: var(--code-background); padding: 0.15em 0.35em; border-radius: 4px; }
    pre { background: var(--code-background); padding: 0.9rem 1rem; border-radius: 8px; overflow-x: auto; }
    pre code { background: none; padding: 0; color: var(--text); }
    blockquote { margin: 1em 0; padding: 0.1em 1rem; border-left: 3px solid var(--quote-bar); color: var(--quote-text); }
    table { border-collapse: collapse; margin: 1em 0; }
    th, td { border: 1px solid var(--rule); padding: 0.4em 0.7em; }
    th { background: var(--code-background); }
    hr { border: none; border-top: 1px solid var(--rule); margin: 2em 0; }
    img { max-width: 100%; }
    mark { background: var(--highlight); color: inherit; }
    dt { font-weight: 600; } dd { margin: 0 0 0.4em 1.5em; }
    .footnotes { margin-top: 3em; padding-top: 1em; border-top: 1px solid var(--rule); font-size: 0.9em; }
    .tok-keyword { color: var(--tok-keyword); } .tok-type { color: var(--tok-type); }
    .tok-string { color: var(--tok-string); } .tok-number, .tok-constant { color: var(--tok-number); }
    .tok-comment { color: var(--tok-comment); font-style: italic; } .tok-function { color: var(--tok-function); }
    """
}
