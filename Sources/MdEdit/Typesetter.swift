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
    /// Finished entries, oldest first, with what their images weigh, so the
    /// oldest go once there are too many or they weigh too much: every
    /// source a block ever had while being typed stays otherwise.
    private var finished: [(request: Request, bytes: Int)] = []
    static let finishedLimit = 1000
    /// A diagram is a Retina bitmap up to `maxDimension` points a side:
    /// counted alone, a thousand of them could hold gigabytes.
    static let finishedByteLimit = 256 << 20
    private var queue: [Request] = []
    private var flight = Flight()
    /// Fails the request in flight when it has taken too long.
    private var watchdog: Task<Void, Never>?
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
        // It may be waiting for another try after taking the page down.
        flight.forget(request)
    }

    /// Whether a request is waiting its turn.
    func isQueued(_ request: Request) -> Bool { queue.contains(request) }

    /// Why a source could not be typeset — a TeX or Mermaid syntax error.
    func error(for request: Request) -> String? {
        if case let .failed(message)? = entries[request] { return message }
        return nil
    }

    /// Whether anything is still being typeset, so printing can wait for it.
    var isBusy: Bool { flight.request != nil || !queue.isEmpty }

    // MARK: - Work

    /// The request being typeset, and what becomes of it when the page it
    /// was sent to is lost.
    ///
    /// A web view's answer cannot be called off: one torn down for being
    /// stuck, or whose process died, may still answer later, when another
    /// request is under way on a new page. Each request sent therefore takes
    /// a ticket, and only the ticket still in flight may land its answer.
    struct Flight {
        private(set) var request: Request?
        private var ticket = 0
        /// How many times each source was in flight when the page's process
        /// died. Most deaths are not the source's doing (memory pressure,
        /// the diagram before it), so it is tried again; but one that kills
        /// the process every time must not do so forever.
        private var crashes: [Request: Int] = [:]
        /// The deaths after which a source is given up on: tried twice.
        static let crashLimit = 2

        /// Takes off with a request; the ticket lets its answer land.
        mutating func begin(_ request: Request) -> Int {
            self.request = request
            ticket += 1
            return ticket
        }

        func isCurrent(_ ticket: Int) -> Bool { request != nil && ticket == self.ticket }

        /// The request an answer is for, or nil when its ticket is stale:
        /// the page was torn down since, and the request already dealt with.
        mutating func land(_ ticket: Int) -> Request? {
            guard isCurrent(ticket), let request else { return nil }
            self.request = nil
            crashes[request] = nil
            return request
        }

        /// The page died: the request it took with it, if any, and whether
        /// to send that one again.
        mutating func crash() -> (request: Request, retry: Bool)? {
            guard let request else { return nil }
            self.request = nil
            let count = crashes[request, default: 0] + 1
            guard count < Self.crashLimit else {
                crashes[request] = nil
                return (request, false)
            }
            crashes[request] = count
            return (request, true)
        }

        /// A request that will not be sent again.
        mutating func forget(_ request: Request) {
            crashes[request] = nil
        }
    }

    /// How long a request may take before the page is taken for stuck.
    ///
    /// KaTeX is synchronous and done in milliseconds, so five seconds only
    /// ever cuts off a macro expanding without end; that still leaves the
    /// first formula time to wait for the fonts when they come from the
    /// network. Mermaid lays out a large graph in a second or two and is
    /// given ten times that: a slow machine should still get its diagram,
    /// while printing, which waits on `isBusy`, is not held up for minutes.
    nonisolated static func timeout(for kind: Kind) -> Duration {
        switch kind {
        case .inlineMath, .displayMath: .seconds(5)
        case .diagram: .seconds(20)
        }
    }

    private func pump() {
        guard flight.request == nil, !queue.isEmpty else { return }
        guard loadedWebView() != nil, isPageLoaded else { return }
        let request = queue.removeFirst()
        let ticket = flight.begin(request)
        watchdog = Task {
            try? await Task.sleep(for: Self.timeout(for: request.kind))
            guard !Task.isCancelled else { return }
            self.timedOut(ticket)
        }
        Task {
            let outcome = await self.typeset(request, ticket: ticket)
            // Timed out or lost with its process meanwhile: already settled.
            guard self.flight.isCurrent(ticket) else { return }
            switch outcome {
            case .lost:
                // Ahead of the delegate, when it is the process that died.
                self.processDied()
            case let .settled(entry):
                _ = self.flight.land(ticket)
                self.watchdog?.cancel()
                self.settle(request, entry)
                self.pump()
            }
        }
    }

    private func settle(_ request: Request, _ entry: Entry) {
        entries[request] = entry
        remember(request)
        if case .done = entry {
            NotificationCenter.default.post(name: Self.didRender, object: self, userInfo: ["request": request])
        }
    }

    /// The request in flight never came back: its JavaScript may be spinning
    /// still, so the page goes with it and the next request gets a new one.
    private func timedOut(_ ticket: Int) {
        guard let request = flight.land(ticket) else { return }
        discardWebView(stuck: true)
        settle(request, .failed(String(localized: "Took too long to draw")))
        pump()
    }

    /// The page's process is gone, and the page with it. Whatever waits is
    /// kept and typeset on a new page; so is the request that was in
    /// flight, unless it has now seen the process die too often.
    private func processDied() {
        let lost = flight.crash()
        discardWebView()
        if let lost {
            if lost.retry {
                // Still `.pending`, and first in line again.
                queue.insert(lost.request, at: 0)
            } else {
                settle(lost.request, .failed(String(localized: "Could not be drawn")))
            }
        }
        // Builds the new page only if something waits for it.
        pump()
    }

    /// Lets the web view go, with its process; `loadedWebView()` makes
    /// another when next asked.
    private func discardWebView(stuck: Bool = false) {
        watchdog?.cancel()
        watchdog = nil
        // Nothing more is to be heard from it: not its load finishing, not
        // its process dying of being closed.
        webView?.navigationDelegate = nil
        if stuck, let webView {
            // Closing a web view asks its process to leave, and one inside a
            // JavaScript loop never hears: it kept a core busy until the app
            // quit. Nothing public stops it (loading another page waits on
            // the same loop), so this asks WebKit by a private name, and
            // does without where that name is gone.
            let kill = NSSelectorFromString("_killWebContentProcessAndResetState")
            if webView.responds(to: kill) { webView.perform(kill) }
        }
        webView = nil
        isPageLoaded = false
    }

    private func remember(_ request: Request) {
        var bytes = 0
        if case let .done(rendering)? = entries[request] { bytes = Self.bytes(of: rendering.image) }
        finished.append((request, bytes))
        let count = Self.oldestToDrop(finished.map(\.bytes))
        guard count > 0 else { return }
        // A text storage keeps the images it shows; one asking again later
        // has it typeset again.
        let dropped = finished.prefix(count)
        for old in dropped where !queue.contains(old.request) { entries[old.request] = nil }
        finished.removeFirst(count)
    }

    /// How many of the oldest finished entries to let go, given what each
    /// weighs, oldest first: none while under both limits, and once over
    /// either, enough to come back under three quarters of both.
    static func oldestToDrop(_ sizes: [Int]) -> Int {
        var bytes = sizes.reduce(0, +)
        guard sizes.count > finishedLimit || bytes > finishedByteLimit else { return 0 }
        var count = 0
        // The newest stays, whatever it weighs: it was just asked for.
        while count < sizes.count - 1, sizes.count - count > finishedLimit * 3 / 4 || bytes > finishedByteLimit * 3 / 4 {
            bytes -= sizes[count]
            count += 1
        }
        return count
    }

    private static func bytes(of image: NSImage) -> Int {
        let pixels = image.representations.map { $0.pixelsWide * $0.pixelsHigh }.max() ?? 0
        // Snapshots are taken at the screen's scale; assume Retina when the
        // image does not say.
        return 4 * (pixels > 0 ? pixels : Int(image.size.width * image.size.height * 4))
    }

    private enum Outcome: Sendable {
        case settled(Entry)
        /// The page went away under the request: no verdict on its source.
        case lost

        /// The page either answers or throws a JavaScript exception, a TeX
        /// or Mermaid error. Any other failure is the web view's own: its
        /// process died (which can be heard of here before the delegate is
        /// told), or the view was torn down.
        init(_ error: Error) {
            self = Typesetter.isVerdict(error) ? .settled(.failed(Typesetter.message(of: error))) : .lost
        }
    }

    /// Whether an error is about the source typeset, rather than about the
    /// page that should have typeset it.
    nonisolated static func isVerdict(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == WKErrorDomain && error.code == WKError.javaScriptExceptionOccurred.rawValue
    }

    /// Where the page laid the source out.
    private struct Box: Sendable {
        var rect: CGRect
        var descent: CGFloat
    }

    /// Typesets with the current web view, which is never held across a
    /// wait here: a page whose JavaScript spins never answers, and its
    /// process only stops once nothing keeps the web view torn down from
    /// under it. That is why the calls take completion handlers; their
    /// `async` forms hold the view until it answers.
    private func typeset(_ request: Request, ticket: Int) async -> Outcome {
        let measured: Result<Box?, Error> = await withCheckedContinuation { continuation in
            measure(request) { continuation.resume(returning: $0) }
        }
        let box: Box
        switch measured {
        case let .success(measured?): box = measured
        case .success(nil): return .settled(.failed("Nothing to draw"))
        case let .failure(error): return Outcome(error)
        }
        // A formula of thousands of characters, or a diagram of thousands of
        // nodes, would be drawn into a bitmap of hundreds of megabytes.
        guard box.rect.width <= Self.maxDimension, box.rect.height <= Self.maxDimension else {
            return .settled(.failed(String(localized: "Too large to draw")))
        }
        // The box is of a page since torn down.
        guard flight.isCurrent(ticket) else { return .lost }
        let snapshot: Result<NSImage, Error> = await withCheckedContinuation { continuation in
            takeSnapshot(of: box.rect) { continuation.resume(returning: $0) }
        }
        switch snapshot {
        case let .success(image):
            image.size = box.rect.size
            return .settled(.done(Rendering(image: image, descent: box.descent)))
        case let .failure(error):
            return Outcome(error)
        }
    }

    private func measure(_ request: Request, completion: @escaping @MainActor @Sendable (Result<Box?, Error>) -> Void) {
        guard let webView else { return completion(.failure(WKError(.webViewInvalidated))) }
        webView.callAsyncJavaScript(
            "return await typeset(kind, source, size, color, dark, width)",
            arguments: [
                "kind": request.kind.rawValue,
                "source": request.source,
                "size": Double(request.fontSize),
                "color": request.color,
                "dark": request.dark,
                "width": Double(request.width),
            ],
            in: nil,
            in: .page
        ) { result in
            completion(result.map { measured in
                guard let box = measured as? [String: Any],
                      let x = (box["x"] as? NSNumber)?.doubleValue,
                      let y = (box["y"] as? NSNumber)?.doubleValue,
                      let width = (box["width"] as? NSNumber)?.doubleValue,
                      let height = (box["height"] as? NSNumber)?.doubleValue,
                      width > 0, height > 0
                else { return nil }
                let descent = (box["descent"] as? NSNumber)?.doubleValue ?? 0
                return Box(rect: CGRect(x: x, y: y, width: width, height: height), descent: descent)
            })
        }
    }

    private func takeSnapshot(of rect: CGRect, completion: @escaping @MainActor @Sendable (Result<NSImage, Error>) -> Void) {
        guard let webView else { return completion(.failure(WKError(.webViewInvalidated))) }
        // The snapshot can only take what the view shows.
        let needed = NSSize(width: max(1200, ceil(rect.maxX)), height: max(800, ceil(rect.maxY)))
        if webView.frame.width < needed.width || webView.frame.height < needed.height {
            webView.setFrameSize(needed)
        }
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.afterScreenUpdates = true
        webView.takeSnapshot(with: configuration) { image, error in
            if let image {
                completion(.success(image))
            } else {
                completion(.failure(error ?? WKError(.unknown)))
            }
        }
    }

    /// The widest or tallest image typeset, in points.
    static let maxDimension: Double = 8192

    nonisolated private static func message(of error: Error) -> String {
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
            guard webView === self.webView else { return }
            isPageLoaded = true
            pump()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            giveUp()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            giveUp()
        }
    }

    /// Memory pressure, or a diagram too much for it, killed the page's
    /// process. Without this the dead page failed every request to the end
    /// of the session.
    nonisolated func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        MainActor.assumeIsolated {
            guard webView === self.webView else { return }
            processDied()
        }
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
