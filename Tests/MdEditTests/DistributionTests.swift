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
}
