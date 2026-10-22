import AppKit

/// Looks for a newer release on GitHub and offers its page.
///
/// No framework and no installer: the release page has the signed disk
/// image, and Homebrew users upgrade with `brew upgrade`. Checked at most once
/// a day when Settings allows, or whenever asked from the app menu.
@MainActor
enum UpdateChecker {
    static let latestRelease = URL(string: "https://api.github.com/repos/msk-mdi/MDedit/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/msk-mdi/MDedit/releases")!
    private static let lastCheckKey = "lastUpdateCheck"

    nonisolated static func isReleasePage(_ url: URL) -> Bool {
        url.scheme == "https" && url.host?.lowercased() == "github.com"
    }

    struct Release: Decodable, Equatable {
        var tagName: String
        var htmlURL: URL
        var draft: Bool?
        var prerelease: Bool?

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
            case draft, prerelease
        }

        /// `v0.10.1` as [0, 10, 1].
        var version: [Int] { UpdateChecker.components(tagName) }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func components(_ version: String) -> [Int] {
        version.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0) ?? 0 }
    }

    /// Whether `candidate` is a later version than `current`, numerically by
    /// component: 0.10 is after 0.9.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        var a = components(candidate), b = components(current)
        let count = max(a.count, b.count)
        a += Array(repeating: 0, count: count - a.count)
        b += Array(repeating: 0, count: count - b.count)
        return b.lexicographicallyPrecedes(a)
    }

    /// How the release is fetched; a stand-in in tests.
    static var fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) }

    /// A response other than the release: GitHub limiting requests, or an error page.
    struct ResponseError: LocalizedError, Equatable {
        var status: Int

        var errorDescription: String? {
            status == 403 || status == 429
                ? String(localized: "GitHub is limiting how often it can be asked. Try again in an hour or so.")
                : String(localized: "GitHub answered with an error (\(status)).")
        }
    }

    /// The release a response describes, or why it describes none.
    nonisolated static func release(from data: Data, response: URLResponse) throws -> Release {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ResponseError(status: http.statusCode)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// The daily background check: says something only when there is news.
    /// The day starts over only once a check has gone through: a check made
    /// offline, or turned away, is tried again at the next launch.
    @discardableResult
    static func checkInBackgroundIfDue(settings: Settings = Settings(), now: Date = Date()) -> Task<Void, Never>? {
        guard settings.checkForUpdates else { return nil }
        if let last = settings.defaults.object(forKey: lastCheckKey) as? Date, now.timeIntervalSince(last) < 24 * 60 * 60 { return nil }
        let defaults = settings.defaults
        return check(quietly: true) { defaults.set(now, forKey: lastCheckKey) }
    }

    /// The check under way, so a second click on the menu item while GitHub
    /// is still answering joins it rather than asking again.
    private static var inFlight: Task<Void, Never>?

    /// App menu ▸ Check for Updates…: always answers.
    @discardableResult
    static func check(quietly: Bool = false, onSuccess: @escaping @MainActor () -> Void = {}) -> Task<Void, Never> {
        if let inFlight { return inFlight }
        let task = Task {
            defer { inFlight = nil }
            do {
                var request = URLRequest(url: latestRelease)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await fetch(request)
                let release = try release(from: data, response: response)
                if present(release, quietly: quietly) { onSuccess() }
            } catch {
                if !quietly { show(String(localized: "Couldn’t check for updates."), detail: error.localizedDescription) }
            }
        }
        inFlight = task
        return task
    }

    /// Says what the release means for this copy; false when there was news
    /// but, unasked and with no window to wait on, it went unsaid.
    @discardableResult
    private static func present(_ release: Release, quietly: Bool) -> Bool {
        let current = currentVersion
        guard release.draft != true, release.prerelease != true, isNewer(release.tagName, than: current) else {
            if !quietly {
                show(String(localized: "MdEdit is up to date."), detail: String(localized: "Version \(current) is the latest."))
            }
            return true
        }
        // Unasked, the news waits on a window rather than stopping the whole
        // app at launch, in the middle of whatever was being typed.
        let window = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible)
        if quietly, window == nil { return false }
        let alert = NSAlert()
        alert.messageText = String(localized: "MdEdit \(release.version.map(String.init).joined(separator: ".")) is available.")
        alert.informativeText = String(localized: "You have version \(current). The release page has the new disk image; with Homebrew, run brew upgrade mdedit.")
        alert.addButton(withTitle: String(localized: "Open Release Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        let open = { (response: NSApplication.ModalResponse) in
            guard response == .alertFirstButtonReturn else { return }
            // Only ever a page on GitHub, whatever the response says.
            let page = isReleasePage(release.htmlURL) ? release.htmlURL : releasesPage
            NSWorkspace.shared.open(page)
        }
        if quietly, let window {
            alert.beginSheetModal(for: window, completionHandler: open)
        } else {
            open(alert.runModal())
        }
        return true
    }

    private static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
