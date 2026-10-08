import AppKit

/// Looks for a newer release on GitHub and offers its page.
///
/// No framework and no installer: the release page has the signed disk
/// image, and Homebrew users upgrade with `brew upgrade`. Checked at most once
/// a day when Settings allows, or whenever asked from the app menu.
@MainActor
enum UpdateChecker {
    static let latestRelease = URL(string: "https://api.github.com/repos/msk-mdi/MDedit/releases/latest")!
    private static let lastCheckKey = "lastUpdateCheck"

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

    /// The daily background check: says something only when there is news.
    static func checkInBackgroundIfDue(settings: Settings = Settings(), now: Date = Date()) {
        guard settings.checkForUpdates else { return }
        if let last = settings.defaults.object(forKey: lastCheckKey) as? Date, now.timeIntervalSince(last) < 24 * 60 * 60 { return }
        settings.defaults.set(now, forKey: lastCheckKey)
        check(quietly: true)
    }

    /// App menu ▸ Check for Updates…: always answers.
    static func check(quietly: Bool = false) {
        Task {
            do {
                var request = URLRequest(url: latestRelease)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, _) = try await URLSession.shared.data(for: request)
                let release = try JSONDecoder().decode(Release.self, from: data)
                present(release, quietly: quietly)
            } catch {
                if !quietly { show(String(localized: "Couldn’t check for updates."), detail: error.localizedDescription) }
            }
        }
    }

    private static func present(_ release: Release, quietly: Bool) {
        let current = currentVersion
        guard release.draft != true, release.prerelease != true, isNewer(release.tagName, than: current) else {
            if !quietly {
                show(String(localized: "MdEdit is up to date."), detail: String(localized: "Version \(current) is the latest."))
            }
            return
        }
        let alert = NSAlert()
        alert.messageText = String(localized: "MdEdit \(release.version.map(String.init).joined(separator: ".")) is available.")
        alert.informativeText = String(localized: "You have version \(current). The release page has the new disk image; with Homebrew, run brew upgrade mdedit.")
        alert.addButton(withTitle: String(localized: "Open Release Page"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private static func show(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
