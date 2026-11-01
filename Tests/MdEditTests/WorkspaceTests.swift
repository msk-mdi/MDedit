import AppKit
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

    /// A cancelled search walked the rest of the folder anyway, so searches
    /// typed in a large folder piled up walks side by side.
    @Test("A cancelled walk stops early")
    func cancelledWalk() throws {
        let root = try makeFolder(Dictionary(uniqueKeysWithValues: (0..<600).map { ("f\($0).md", "") }))
        defer { try? FileManager.default.removeItem(at: root) }
        var asked = 0
        let files = Workspace(root: root).markdownFiles { asked += 1; return true }
        #expect(asked == 1)
        #expect(files.count < 600)
        #expect(Workspace(root: root).markdownFiles().count == 600)
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

    /// The text is searched whole now, not a line at a time; the matches
    /// must be the ones the line-by-line search found.
    @Test("Searching whole files finds what searching line by line did")
    func searchMatchesLineByLine() {
        func lineByLine(_ query: String, in text: String) -> [WorkspaceSearch.Match] {
            var matches: [WorkspaceSearch.Match] = []
            var lineNumber = 0
            text.enumerateLines { line, _ in
                let ns = line as NSString
                var searchRange = NSRange(location: 0, length: ns.length)
                while true {
                    let found = ns.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
                    guard found.location != NSNotFound else { break }
                    matches.append(.init(line: lineNumber, range: found, lineText: line))
                    searchRange = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
                }
                lineNumber += 1
            }
            return matches
        }
        let texts = [
            "Alpha beta\nalphabet soup\n",
            "no newline at the end alpha",
            "\n\nalpha\n\n\nALPHA alpha\n",
            "crlf alpha\r\nnext alpha\r\n",
            "lone cr alpha\rnext alpha\u{2028}separated alpha\u{2029}x",
            "café cafe CAFÉ\nàlpha",
            "alphalpha alpha-alpha",
            "spans al\npha lines",
        ]
        let url = URL(fileURLWithPath: "/nonexistent/note.md")
        for text in texts {
            for query in ["alpha", "cafe", "al", "a"] {
                let found = WorkspaceSearch.search(query, in: [url], overrides: [url: text]).first?.matches ?? []
                #expect(found == lineByLine(query, in: text), "\(query) in \(text.debugDescription)")
            }
        }
    }

    /// Any change in the folder threw the file list away, `.git`'s at each
    /// commit and a build folder's all through a build.
    @Test("Only changes where the listing looks make the folder be listed again")
    func listingChanges() {
        let workspace = Workspace(root: URL(fileURLWithPath: "/tmp/Notes", isDirectory: true))
        let root = workspace.root.resolvingSymlinksInPath().path
        #expect(workspace.listingChanged(inFolders: [root]))
        #expect(workspace.listingChanged(inFolders: [root + "/journal/2026"]))
        #expect(!workspace.listingChanged(inFolders: [root + "/.git/objects/ab", root + "/node_modules/x", root + "/site/build"]))
        #expect(workspace.listingChanged(inFolders: [root + "/.git", root + "/drafts"]))
        // Outside the root: FSEvents lost its place; list again.
        #expect(workspace.listingChanged(inFolders: ["/elsewhere"]))
    }

    @MainActor
    @Test("The folder's file list is kept until it is invalidated")
    func fileListCaches() async throws {
        let root = try makeFolder(["a.md": "a\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root)
        let list = WorkspaceFileList()
        #expect(await list.files(of: workspace).map(\.lastPathComponent) == ["a.md"])
        try "b\n".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        #expect(await list.files(of: workspace).map(\.lastPathComponent) == ["a.md"])
        list.invalidate()
        #expect(await list.files(of: workspace).map(\.lastPathComponent) == ["a.md", "b.md"])
    }

    /// Any save in the folder dropped the list, and the next ⌘P or search
    /// walked the whole folder again.
    @MainActor
    @Test("Notes that come and go are taken into the kept list; a save keeps it")
    func fileListUpdates() async throws {
        let root = try makeFolder(["a.md": "a\n", "c.md": "c\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = Workspace(root: root)
        let real = root.resolvingSymlinksInPath().path
        let list = WorkspaceFileList()
        #expect(await list.files(of: workspace).map(\.lastPathComponent) == ["a.md", "c.md"])

        try "b\n".write(to: root.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: root.appendingPathComponent("c.md"))
        try "x\n".write(to: root.appendingPathComponent("image.png"), atomically: true, encoding: .utf8)
        list.update([
            .init(path: real + "/b.md", isDirectory: false),
            .init(path: real + "/c.md", isDirectory: false),
            .init(path: real + "/image.png", isDirectory: false),
            // Saved over: still there, still listed once.
            .init(path: real + "/a.md", isDirectory: false),
        ], in: workspace)
        let afterSave = await list.files(of: workspace).map(\.lastPathComponent)
        #expect(afterSave == ["a.md", "b.md"])

        // Not walked again: a file added without word stays out.
        try "d\n".write(to: root.appendingPathComponent("d.md"), atomically: true, encoding: .utf8)
        list.update([.init(path: real + "/node_modules/e.md", isDirectory: false)], in: workspace)
        let skipped = await list.files(of: workspace).map(\.lastPathComponent)
        #expect(skipped == ["a.md", "b.md"])

        // A folder that comes or goes has the folder walked again.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"), withIntermediateDirectories: true)
        list.update([.init(path: real + "/sub", isDirectory: true)], in: workspace)
        let walked = await list.files(of: workspace).map(\.lastPathComponent)
        #expect(walked == ["a.md", "b.md", "d.md"])
    }

    /// A named pipe with a note's name was read like a file: the read waited
    /// forever, holding a concurrency thread, and opening it hung the same way.
    @Test("Find in Folder and opening skip a named pipe; opening refuses a huge file")
    func unreadableFiles() async throws {
        let root = try makeFolder(["note.md": "alpha\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let pipe = root.appendingPathComponent("pipe.md")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        let note = root.appendingPathComponent("note.md")
        #expect(WorkspaceSearch.search("alpha", in: [pipe, note]).map(\.url) == [note])
        await #expect(throws: CocoaError.self) { try await FileFormat.read(pipe) }

        // Sparse: as large as it says without writing it.
        let huge = root.appendingPathComponent("huge.md")
        FileManager.default.createFile(atPath: huge.path, contents: nil)
        let handle = try FileHandle(forWritingTo: huge)
        try handle.truncate(atOffset: UInt64(FileFormat.maxBytes + 1))
        try handle.close()
        do {
            _ = try await FileFormat.read(huge)
            Issue.record("read a file past the limit")
        } catch let error as CocoaError {
            #expect(error.code == .fileReadTooLarge)
        }
        #expect(try await FileFormat.read(note).text == "alpha\n")
    }

    @MainActor
    @Test("A result's tooltip is cut short on a very long line")
    func longLineTooltip() {
        #expect(SearchPaneView.tooltip("short") == "short")
        let long = SearchPaneView.tooltip(String(repeating: "x", count: 1_000_000))
        #expect(long.count == 501)
    }

    /// Every row had a fresh cell built for it, constraints and all, and
    /// measured for its height: up to 2,000 of them on each query.
    @MainActor
    @Test("Find in Folder reuses its result rows")
    func searchReusesRows() async throws {
        let url = URL(fileURLWithPath: "/nonexistent/notes.md")
        let pane = SearchPaneView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        let window = NSWindow(contentRect: pane.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = pane
        pane.searchScope = { (nil, [url], [url: String(repeating: "alpha\n", count: 500)]) }
        pane.field.stringValue = "alpha"
        pane.search()
        await pane.finishSearching()
        let scrollView = pane.subviews.first { $0 is NSScrollView } as? NSScrollView
        let outline = try #require(scrollView?.documentView as? NSOutlineView)
        #expect(!outline.usesAutomaticRowHeights)
        #expect(outline.numberOfRows == 501)
        var cells: Set<ObjectIdentifier> = []
        for row in stride(from: 0, to: outline.numberOfRows, by: 5) {
            outline.scrollRowToVisible(row)
            window.layoutIfNeeded()
            window.display()
            let visible = outline.rows(in: outline.visibleRect)
            for shown in visible.location..<NSMaxRange(visible) {
                if let cell = outline.view(atColumn: 0, row: shown, makeIfNecessary: false) { cells.insert(ObjectIdentifier(cell)) }
            }
        }
        // Scrolling through every row took only a screenful of cells or so.
        #expect(cells.count < 60)
    }
}
