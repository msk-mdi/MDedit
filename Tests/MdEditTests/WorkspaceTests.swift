import Foundation
import Testing
@testable import MdEdit

@Suite("Workspace")
struct WorkspaceTests {
    private func makeFolder(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditWorkspace-\(UUID().uuidString)", isDirectory: true)
        for (path, contents) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    @Test("Markdown files are found, hidden and dependency folders skipped")
    func enumeration() throws {
        let root = try makeFolder([
            "a.md": "", "notes/b.markdown": "", "notes/pic.png": "",
            ".hidden/c.md": "", "node_modules/pkg/readme.md": "", "notes/deep/d.txt": "",
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root)
        #expect(workspace.markdownFiles().map(workspace.relativePath(of:)) == ["a.md", "notes/b.markdown", "notes/deep/d.txt"])
    }

    @Test("Fuzzy matching prefers file names, word starts and runs")
    func fuzzy() {
        #expect(FuzzyMatcher.score("xyz", in: "notes/today.md") == nil)
        #expect(FuzzyMatcher.score("", in: "anything") == 0)

        let candidates = ["archive/roadmap-draft.md", "notes/road/map.md", "roadmap.md", "src/rendering/old-amap.md"]
        #expect(FuzzyMatcher.score("roadmap", in: candidates[3]) == nil)
        let ranked = candidates
            .compactMap { candidate in FuzzyMatcher.score("roadmap", in: candidate).map { (candidate, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        #expect(ranked.first == "roadmap.md")
        #expect(ranked == ["roadmap.md", "archive/roadmap-draft.md", "notes/road/map.md"])
        // Case does not matter, and camelCase humps count as word starts.
        #expect(FuzzyMatcher.score("RM", in: "ReadMe.md") != nil)
        #expect(FuzzyMatcher.score("rm", in: "ReadMe.md")! > FuzzyMatcher.score("rm", in: "aardvarkmonkey.md")!)
    }

    @Test("Find in Folder reports every match by line, preferring unsaved text")
    func search() throws {
        let root = try makeFolder(["one.md": "Alpha beta\nalphabet soup\n", "two.md": "nothing here\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appendingPathComponent("one.md")
        let two = root.appendingPathComponent("two.md")

        let results = WorkspaceSearch.search("ALPHA", in: [one, two])
        #expect(results.count == 1)
        #expect(results[0].matches.map(\.line) == [0, 1])
        #expect(results[0].matches[1].range == NSRange(location: 0, length: 5))

        let edited = WorkspaceSearch.search("here", in: [one, two], overrides: [two: "changed\n"])
        #expect(edited.isEmpty)
    }
}
