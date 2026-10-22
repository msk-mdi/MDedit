import AppKit
import MarkdownKit
import WebKit

/// Typesets TeX with KaTeX and draws Mermaid diagrams, into images the editor
/// shows in place of their source.
///
/// The editor itself stays a text view: one web view, never on screen, does
/// the typesetting, and the layout manager draws the snapshots it takes. Like
/// `ImageCache`, a request returns nil until its image is ready and then posts
/// `didRender`, so the text storages that asked can restyle.
@MainActor
final class Typesetter: NSObject {
    static let shared = Typesetter()
    nonisolated static let didRender = Notification.Name("MdEditTypesetterDidRender")

    enum Kind: String, Hashable {
        case inlineMath, displayMath, diagram
    }

    struct Request: Hashable {
        var kind: Kind
        var source: String
        var fontSize: CGFloat
        /// The ink, as CSS.
        var color: String
        var dark: Bool
        /// Diagrams are laid out to fit the text column.
        var width: CGFloat

        /// What VoiceOver reads in place of the image.
        var spokenLabel: String {
            switch kind {
            case .inlineMath, .displayMath: String(localized: "formula \(source)")
            case .diagram: String(localized: "diagram \(source)")
            }
        }
    }

    /// A typeset formula or diagram: its image, and how far it hangs below
    /// the baseline when it sits in a line of text.
    final class Rendering: NSObject, Sendable {
        let image: NSImage
        let descent: CGFloat
        var size: CGSize { image.size }

        init(image: NSImage, descent: CGFloat) {
            self.image = image
            self.descent = descent
        }
    }

    private enum Entry {
        case pending
        case done(Rendering)
        case failed(String)
    }

    private var entries: [Request: Entry] = [:]
    /// Finished entries, oldest first, so the oldest go once there are too
    /// many: every source a block ever had while being typed stays otherwise.
    private var finished: [Request] = []
    private static let finishedLimit = 1000
    private var queue: [Request] = []
    private var isWorking = false
    private var webView: WKWebView?
    private var isPageLoaded = false
    /// Without KaTeX and Mermaid, nothing can be typeset and sources stay as written.
    private var isUnavailable = false

    /// The image if it is ready; otherwise queues the work and returns nil.
    func rendering(for request: Request) -> Rendering? {
        switch entries[request] {
        case let .done(rendering)?:
            return rendering
        case .pending?, .failed?:
            return nil
        case nil:
            guard !isUnavailable, !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            entries[request] = .pending
            queue.append(request)
            pump()
            return nil
        }
    }

    /// Drops a request nothing waits for any more, if it has not started.
    /// A block being edited asks for each new source as it is typed, and
    /// typesetting every one in turn left the preview far behind.
    func cancel(_ request: Request) {
        guard case .pending? = entries[request], let index = queue.firstIndex(of: request) else { return }
        queue.remove(at: index)
        entries[request] = nil
    }

    /// Whether a request is waiting its turn.
    func isQueued(_ request: Request) -> Bool { queue.contains(request) }

    /// Why a source could not be typeset — a TeX or Mermaid syntax error.
    func error(for request: Request) -> String? {
        if case let .failed(message)? = entries[request] { return message }
        return nil
    }

    /// Whether anything is still being typeset, so printing can wait for it.
    var isBusy: Bool { isWorking || !queue.isEmpty }

    // MARK: - Work

    private func pump() {
        guard !isWorking, !queue.isEmpty else { return }
        guard let webView = loadedWebView() else { return }
        guard isPageLoaded else { return }
        isWorking = true
        let request = queue.removeFirst()
        Task {
            let entry = await self.typeset(request, in: webView)
            self.entries[request] = entry
            self.remember(request)
            self.isWorking = false
            if case .done = entry {
                NotificationCenter.default.post(name: Self.didRender, object: self, userInfo: ["request": request])
            }
            self.pump()
        }
    }

    private func remember(_ request: Request) {
        finished.append(request)
        guard finished.count > Self.finishedLimit else { return }
        // A text storage keeps the images it shows; one asking again later
        // has it typeset again.
        let dropped = finished.prefix(finished.count - Self.finishedLimit * 3 / 4)
        for old in dropped where !queue.contains(old) { entries[old] = nil }
        finished.removeFirst(dropped.count)
    }

    private func typeset(_ request: Request, in webView: WKWebView) async -> Entry {
        let measured: Any?
        do {
            measured = try await webView.callAsyncJavaScript(
                "return await typeset(kind, source, size, color, dark, width)",
                arguments: [
                    "kind": request.kind.rawValue,
                    "source": request.source,
                    "size": Double(request.fontSize),
                    "color": request.color,
                    "dark": request.dark,
                    "width": Double(request.width),
                ],
                contentWorld: .page
            )
        } catch {
            return .failed(Self.message(of: error))
        }
        guard let box = measured as? [String: Any],
              let x = (box["x"] as? NSNumber)?.doubleValue,
              let y = (box["y"] as? NSNumber)?.doubleValue,
              let width = (box["width"] as? NSNumber)?.doubleValue,
              let height = (box["height"] as? NSNumber)?.doubleValue,
              width > 0, height > 0
        else { return .failed("Nothing to draw") }
        let descent = (box["descent"] as? NSNumber)?.doubleValue ?? 0
        // A formula of thousands of characters, or a diagram of thousands of
        // nodes, would be drawn into a bitmap of hundreds of megabytes.
        guard width <= Self.maxDimension, height <= Self.maxDimension else {
            return .failed(String(localized: "Too large to draw"))
        }

        // The snapshot can only take what the view shows.
        let needed = NSSize(width: max(1200, ceil(x + width)), height: max(800, ceil(y + height)))
        if webView.frame.width < needed.width || webView.frame.height < needed.height {
            webView.setFrameSize(needed)
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = CGRect(x: x, y: y, width: width, height: height)
        configuration.afterScreenUpdates = true
        do {
            let image = try await webView.takeSnapshot(configuration: configuration)
            image.size = NSSize(width: width, height: height)
            return .done(Rendering(image: image, descent: descent))
        } catch {
            return .failed(Self.message(of: error))
        }
    }

    /// The widest or tallest image typeset, in points.
    static let maxDimension: Double = 8192

    private static func message(of error: Error) -> String {
        let info = (error as NSError).userInfo
        return info["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
    }

    // MARK: - The page

    private func loadedWebView() -> WKWebView? {
        if let webView { return webView }
        guard let page = Self.page() else {
            isUnavailable = true
            queue.removeAll()
            entries = entries.filter { if case .pending = $0.value { false } else { true } }
            return nil
        }
        let configuration = WKWebViewConfiguration()
        configuration.suppressesIncrementalRendering = true
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        // Snapshots keep their transparency, so formulas sit on any canvas.
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .clear
        webView.navigationDelegate = self
        webView.loadHTMLString(page.html, baseURL: page.baseURL)
        self.webView = webView
        return webView
    }

    /// The typesetting page: KaTeX and Mermaid inlined when the app carries
    /// them (`Scripts/fetch-vendor.sh`), from jsDelivr otherwise.
    private static func page() -> (html: String, baseURL: URL?)? {
        typealias CDN = HTMLRenderer.CDN
        // The page runs whatever KaTeX and Mermaid make of a document's
        // source, so it may reach nothing: no network, no navigation (the
        // delegate refuses it too), and from the bundle not even an origin.
        var head: String
        let policy: String
        let baseURL: URL?
        if let scripts = Exporter.bundledScripts() {
            policy = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; font-src data:; img-src data: blob:; connect-src 'none'"
            baseURL = nil
            head = """
            <style>\(scripts.katexCSS)</style>
            <script>\(scripts.katexJS)</script>
            <script>\(scripts.mermaidJS)</script>
            """
        } else {
            policy = "default-src 'none'; script-src 'unsafe-inline' https://cdn.jsdelivr.net; style-src 'unsafe-inline' https://cdn.jsdelivr.net; font-src data: https://cdn.jsdelivr.net; img-src data: blob:; connect-src 'none'"
            baseURL = URL(string: "https://cdn.jsdelivr.net/")
            head = """
            <link rel="stylesheet" href="\(CDN.katexCSS.url)" integrity="\(CDN.katexCSS.integrity)" crossorigin="anonymous">
            <script src="\(CDN.katexJS.url)" integrity="\(CDN.katexJS.integrity)" crossorigin="anonymous"></script>
            <script src="\(CDN.mermaidJS.url)" integrity="\(CDN.mermaidJS.integrity)" crossorigin="anonymous"></script>
            """
        }
        head += """
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        body { font-family: -apple-system, sans-serif; }
        #stage { position: absolute; left: 0; top: 0; display: inline-block; padding: 1px 2px; white-space: nowrap; }
        #stage .katex { font-size: 1.1em; }
        #stage .katex-display { margin: 0; }
        #stage.diagram { padding: 0; white-space: normal; }
        </style>
        """
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(policy)">
        \(head)
        </head><body><div id="stage"></div>
        <script>
        let mermaidTheme = null;
        let diagramCount = 0;
        // Every KaTeX face, loaded before the first snapshot: a face still
        // on its way is drawn as nothing.
        const fontsLoaded = Promise.all([...document.fonts].map((face) => face.load().catch(() => null)));
        // A web view off screen gets no animation frames; a timer lets layout settle.
        const painted = () => new Promise((resolve) => setTimeout(resolve, 0));
        function measure(element, descent) {
          const box = element.getBoundingClientRect();
          const left = Math.floor(box.left), top = Math.floor(box.top);
          return { x: left, y: top, width: Math.ceil(box.right) - left, height: Math.ceil(box.bottom) - top, descent: descent };
        }
        async function typeset(kind, source, size, color, dark, width) {
          await fontsLoaded;
          const stage = document.getElementById("stage");
          stage.className = kind === "diagram" ? "diagram" : "";
          stage.style.fontSize = size + "px";
          stage.style.color = color;
          stage.style.width = "";
          stage.innerHTML = "";
          if (kind === "diagram") {
            const theme = dark ? "dark" : "default";
            if (mermaidTheme !== theme) {
              mermaid.initialize({
                startOnLoad: false, theme: theme, securityLevel: "strict",
                fontFamily: "-apple-system, 'Helvetica Neue', sans-serif",
              });
              mermaidTheme = theme;
            }
            stage.style.width = width + "px";
            const id = "diagram" + (++diagramCount);
            try {
              const { svg } = await mermaid.render(id, source);
              stage.innerHTML = svg;
            } finally {
              // A failed render leaves its scratch element behind.
              document.getElementById("d" + id)?.remove();
            }
            await document.fonts.ready;
            await painted();
            return measure(stage.querySelector("svg"), 0);
          }
          katex.render(source, stage, { displayMode: kind === "displayMath", throwOnError: true });
          await document.fonts.ready;
          await painted();
          const box = stage.getBoundingClientRect();
          let descent = 0;
          if (kind === "inlineMath") {
            // An empty inline-block sits on the baseline.
            const probe = document.createElement("span");
            probe.style.display = "inline-block";
            stage.querySelector(".katex").appendChild(probe);
            descent = box.bottom - probe.getBoundingClientRect().bottom;
            probe.remove();
          }
          return measure(stage, descent);
        }
        </script>
        </body></html>
        """
        return (html, baseURL)
    }
}

extension Typesetter: WKNavigationDelegate {
    /// The typesetting page is the only thing this view ever shows: a link
    /// or redirect a formula or diagram might smuggle in goes nowhere.
    nonisolated func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        await MainActor.run {
            !isPageLoaded && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        MainActor.assumeIsolated {
            isPageLoaded = true
            pump()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { giveUp() }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated { giveUp() }
    }

    private func giveUp() {
        isUnavailable = true
        queue.removeAll()
        entries = entries.filter { if case .pending = $0.value { false } else { true } }
    }
}

extension NSColor {
    /// The colour as a CSS `rgba()`.
    var cssString: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000" }
        return String(
            format: "rgba(%d, %d, %d, %.3f)",
            Int((rgb.redComponent * 255).rounded()),
            Int((rgb.greenComponent * 255).rounded()),
            Int((rgb.blueComponent * 255).rounded()),
            rgb.alphaComponent
        )
    }
}
