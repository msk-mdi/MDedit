import AppKit
import Testing
@testable import MdEdit

@MainActor
@Suite("Distribution", .serialized)
struct DistributionTests {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private func scratchDefaults() -> UserDefaults {
        let name = "MdEditTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("A remembered file is found again after it is renamed")
    func bookmarkFollowsRename() throws {
        let defaults = scratchDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditBookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let original = folder.appendingPathComponent("notes.md")
        try "text".write(to: original, atomically: true, encoding: .utf8)
        FileAccess.remember(original, in: defaults)

        let renamed = folder.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: original, to: renamed)
        #expect(FileAccess.resolve(original, in: defaults).standardizedFileURL.path == renamed.standardizedFileURL.path)
        // A file never remembered comes back as it was.
        let other = folder.appendingPathComponent("other.md")
        #expect(FileAccess.resolve(other, in: defaults) == other)
    }

    @Test("A session's files resolve together, in order, renamed ones found again")
    func bookmarksResolveTogether() throws {
        let defaults = scratchDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditBookmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try (0..<3).map { index -> URL in
            let url = folder.appendingPathComponent("f\(index).md")
            try "text".write(to: url, atomically: true, encoding: .utf8)
            FileAccess.remember(url, in: defaults)
            return url
        }
        let renamed = folder.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: files[1], to: renamed)
        let unknown = folder.appendingPathComponent("never.md")

        let resolved = FileAccess.resolve(files + [unknown], in: defaults).map(\.standardizedFileURL.path)
        #expect(resolved == [files[0], renamed, files[2], unknown].map(\.standardizedFileURL.path))
        // The move is remembered under the new path.
        #expect(FileAccess.resolve(renamed, in: defaults).standardizedFileURL.path == renamed.standardizedFileURL.path)
    }

    /// Opening records bookmarks in the background, so several can be
    /// recorded at once; each rewrites the whole list.
    @Test("Bookmarks recorded at once are all kept")
    func bookmarksAtOnce() throws {
        let defaults = scratchDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditBookmarks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let files = try (0..<40).map { index -> URL in
            let url = folder.appendingPathComponent("f\(index).md")
            try "text".write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        nonisolated(unsafe) let shared = defaults
        DispatchQueue.concurrentPerform(iterations: files.count) { FileAccess.remember(files[$0], in: shared) }
        let kept = (defaults.data(forKey: "fileBookmarks").flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } as? [Any])?.count
        #expect(kept == files.count)
        let renamed = folder.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: files[17], to: renamed)
        #expect(FileAccess.resolve(files[17], in: defaults).standardizedFileURL.path == renamed.standardizedFileURL.path)
    }

    @Test("The bookmark list keeps only the newest")
    func bookmarkLimit() throws {
        let defaults = scratchDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditBookmarks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [URL] = []
        for index in 0...FileAccess.limit {
            let file = folder.appendingPathComponent("\(index).md")
            try "".write(to: file, atomically: true, encoding: .utf8)
            FileAccess.remember(file, in: defaults)
            files.append(file)
        }
        // The first one dropped out: renaming it is no longer followed.
        let moved = folder.appendingPathComponent("moved.md")
        try FileManager.default.moveItem(at: files[0], to: moved)
        #expect(FileAccess.resolve(files[0], in: defaults) == files[0])
    }

    @Test("The session's files and folder keep their bookmarks however many come after")
    func pinnedBookmarks() throws {
        let defaults = scratchDefaults()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditBookmarks-\(UUID().uuidString)")
        let workspace = folder.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let tab = workspace.appendingPathComponent("open.md")
        try "".write(to: tab, atomically: true, encoding: .utf8)
        FileAccess.remember(workspace, in: defaults)
        FileAccess.remember(tab, in: defaults)
        FileAccess.pin([workspace, tab], in: defaults)
        var files: [URL] = []
        for index in 0...FileAccess.limit {
            let file = folder.appendingPathComponent("\(index).md")
            try "".write(to: file, atomically: true, encoding: .utf8)
            FileAccess.remember(file, in: defaults)
            files.append(file)
        }
        // Both still followed when moved; the oldest unpinned file is not.
        let movedWorkspace = folder.appendingPathComponent("moved", isDirectory: true)
        try FileManager.default.moveItem(at: workspace, to: movedWorkspace)
        #expect(FileAccess.resolve(workspace, in: defaults).standardizedFileURL.path == movedWorkspace.standardizedFileURL.path)
        #expect(FileAccess.resolve(tab, in: defaults).standardizedFileURL.path == movedWorkspace.appendingPathComponent("open.md").standardizedFileURL.path)
        try FileManager.default.moveItem(at: files[0], to: folder.appendingPathComponent("gone.md"))
        #expect(FileAccess.resolve(files[0], in: defaults) == files[0])
    }

    /// The day was stamped before asking, so a check made offline put off
    /// the next for a day; and a rate limit read as a garbled release.
    @Test("A background check counts only once it gets an answer, and an error status is not read as a release")
    func updateCheckFailures() async throws {
        let defaults = scratchDefaults()
        var settings = Settings()
        settings.defaults = defaults
        settings.checkForUpdates = true
        let original = UpdateChecker.fetch
        defer { UpdateChecker.fetch = original }
        let api = UpdateChecker.latestRelease
        func respond(_ status: Int, _ body: String) {
            UpdateChecker.fetch = { _ in
                (Data(body.utf8), HTTPURLResponse(url: api, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
        }

        respond(403, #"{"message": "API rate limit exceeded"}"#)
        await UpdateChecker.checkInBackgroundIfDue(settings: settings)?.value
        #expect(defaults.object(forKey: "lastUpdateCheck") == nil)
        #expect(throws: UpdateChecker.ResponseError(status: 403)) {
            try UpdateChecker.release(from: Data(), response: HTTPURLResponse(url: api, statusCode: 403, httpVersion: nil, headerFields: nil)!)
        }

        UpdateChecker.fetch = { _ in throw URLError(.notConnectedToInternet) }
        await UpdateChecker.checkInBackgroundIfDue(settings: settings)?.value
        #expect(defaults.object(forKey: "lastUpdateCheck") == nil)

        // No newer release: nothing to say, and the day starts now.
        respond(200, #"{"tag_name": "v0", "html_url": "https://github.com/msk-mdi/MDedit/releases/tag/v0"}"#)
        let now = Date()
        await UpdateChecker.checkInBackgroundIfDue(settings: settings, now: now)?.value
        #expect(defaults.object(forKey: "lastUpdateCheck") as? Date == now)
        #expect(UpdateChecker.checkInBackgroundIfDue(settings: settings, now: now.addingTimeInterval(60)) == nil)
    }

    @Test("Info.plist declares the markdown type and claims it")
    func markdownType() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        let imported = try #require(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        let markdown = try #require(imported.first { $0["UTTypeIdentifier"] as? String == "net.daringfireball.markdown" })
        let tags = try #require(markdown["UTTypeTagSpecification"] as? [String: Any])
        #expect((tags["public.filename-extension"] as? [String])?.contains("md") == true)
        let documentTypes = try #require(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let handler = try #require(documentTypes.first { ($0["LSItemContentTypes"] as? [String])?.contains("net.daringfireball.markdown") == true })
        #expect(handler["LSHandlerRank"] as? String == "Default")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/\(handler["CFBundleTypeIconFile"] as! String).icns").path))
    }

    /// Documents are not NSDocuments, so AppKit cannot tell when edits are
    /// unsaved: macOS could quit a hidden app without asking about them.
    @Test("Info.plist does not let macOS quit the app on its own")
    func noAutomaticTermination() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSSupportsAutomaticTermination"] as? Bool != true)
        #expect(plist["NSSupportsSuddenTermination"] as? Bool != true)
    }

    @Test("The help pages are well-formed markdown with a title")
    func helpPages() throws {
        for name in ["Welcome", "CheatSheet"] {
            let text = try String(contentsOf: root.appendingPathComponent("Resources/Help/\(name).md"), encoding: .utf8)
            #expect(text.hasPrefix("# "))
        }
    }

    @Test("A help page opens as an untitled copy with its own name")
    func helpCopy() {
        let controller = MainWindowController()
        controller.openCopy(of: "# Hello\n", named: "Welcome")
        let document = controller.activeDocument
        #expect(document?.displayName == "Welcome")
        #expect(document?.url == nil)
        #expect(document?.isDirty == false)
    }
}

@Suite("Update checks")
struct UpdateCheckTests {
    @Test("Versions compare by number, not by text")
    func versionOrder() {
        #expect(UpdateChecker.isNewer("v0.10.0", than: "0.9.0"))
        #expect(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        #expect(UpdateChecker.isNewer("0.9.1", than: "0.9"))
        #expect(!UpdateChecker.isNewer("v0.9.0", than: "0.9"))
        #expect(!UpdateChecker.isNewer("0.8.12", than: "0.9.0"))
    }

    @Test("GitHub's release JSON decodes")
    func decodeRelease() throws {
        let json = #"{"tag_name": "v1.2.0", "html_url": "https://github.com/msk-mdi/MDedit/releases/tag/v1.2.0", "draft": false, "prerelease": false, "assets": []}"#
        let release = try JSONDecoder().decode(UpdateChecker.Release.self, from: Data(json.utf8))
        #expect(release.version == [1, 2, 0])
        #expect(release.htmlURL.absoluteString.hasSuffix("v1.2.0"))
    }

    /// Every file and folder restored was given access that was never
    /// stopped, each holding a sandbox extension for the rest of the run.
    @Test("Access to a closed tab or replaced folder is stopped, not to what stays open")
    func scopedAccessReleased() {
        var stopped: [String] = []
        let access = ScopedAccess { stopped.append($0.path) }
        let folder = URL(fileURLWithPath: "/notes")
        let inside = URL(fileURLWithPath: "/notes/a.md")
        let tab = URL(fileURLWithPath: "/elsewhere/b.md")
        let twice = URL(fileURLWithPath: "/elsewhere/c.md")
        let lookalike = URL(fileURLWithPath: "/notes-old")
        for url in [folder, inside, tab, twice, twice, lookalike] { access.add(url) }
        // The folder is no longer the workspace, but a tab inside it is open.
        access.release(keeping: [inside, tab, twice])
        #expect(stopped == ["/notes-old"])
        #expect(access.paths == ["/notes", "/notes/a.md", "/elsewhere/b.md", "/elsewhere/c.md"])
        access.release(keeping: [tab])
        #expect(stopped.sorted() == ["/elsewhere/c.md", "/elsewhere/c.md", "/notes", "/notes-old", "/notes/a.md"])
        #expect(access.paths == ["/elsewhere/b.md"])
    }
}
