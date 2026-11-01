import AppKit
import Testing
@testable import MdEdit

@MainActor
@Suite("File tree")
struct FileTreeTests {
    /// A folder with `notes/` holding one file, and `top.md` beside it.
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditTree-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("top.md"))
        try Data().write(to: root.appendingPathComponent("notes/first.md"))
        return root
    }

    /// The tree in a window, as the sidebar shows it, with its folder listed.
    private func makeTree(_ root: URL, listing: (@Sendable (URL) -> [FileNode.Entry])? = nil) async -> (FileTreeView, NSWindow) {
        let tree = FileTreeView()
        if let listing { tree.listFolder = listing }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 400), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = tree
        tree.setRoot(root)
        if listing == nil { await tree.finishListing() }
        return (tree, window)
    }

    private func rows(_ tree: FileTreeView) -> [String] {
        (0..<tree.outline.numberOfRows).compactMap { (tree.outline.item(atRow: $0) as? FileNode)?.url.lastPathComponent }
    }

    /// FSEvents names folders with symlinks resolved; the temporary folder is
    /// under one, /var to /private/var.
    private func reported(_ url: URL) -> String {
        realPath(url.path) + "/"
    }

    @Test("A change re-lists only that folder, keeping what is open and selected")
    func refreshKeepsState() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tree, window) = await makeTree(root)
        _ = window
        let notes = try #require(tree.outline.item(atRow: 0) as? FileNode)
        tree.outline.expandItem(notes)
        await tree.finishListing()
        tree.reveal(root.appendingPathComponent("notes/first.md"))
        #expect(rows(tree) == ["notes", "first.md", "top.md"])

        try Data().write(to: root.appendingPathComponent("notes/second.md"))
        tree.folderContentsChanged(.folders([reported(root.appendingPathComponent("notes"))]))
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "first.md", "second.md", "top.md"])
        #expect(tree.outline.item(atRow: 0) as? FileNode === notes)
        #expect(tree.outline.isItemExpanded(notes))
        #expect((tree.outline.item(atRow: tree.outline.selectedRow) as? FileNode)?.url.lastPathComponent == "first.md")

        // The root itself, with a folder that is open below it.
        try Data().write(to: root.appendingPathComponent("another.md"))
        tree.folderContentsChanged(.folders([reported(root)]))
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "first.md", "second.md", "another.md", "top.md"])
        #expect(tree.outline.isItemExpanded(notes))
    }

    @Test("Changes in hidden and dependency folders, or folders never listed, read nothing")
    func ignoredFolders() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tree, window) = await makeTree(root)
        _ = window
        #expect(rows(tree) == ["notes", "top.md"])
        let notes = try #require(tree.outline.item(atRow: 0) as? FileNode)

        try Data().write(to: root.appendingPathComponent("unseen.md"))
        for folder in [".git", ".git/objects", "node_modules/pkg", "notes"] {
            tree.folderContentsChanged(.folders([reported(root) + folder]))
        }
        await tree.finishListing()
        // The root was not read again, and `notes`, never opened, was not listed.
        #expect(rows(tree) == ["notes", "top.md"])
        #expect(notes.listedChildren == nil)
    }

    @Test("Out of sight, the tree waits until it is shown")
    func hiddenTreeDefers() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tree, window) = await makeTree(root)
        _ = window
        tree.isHidden = true
        try Data().write(to: root.appendingPathComponent("later.md"))
        tree.folderContentsChanged(.folders([reported(root)]))
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "top.md"])

        tree.isHidden = false
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "later.md", "top.md"])
    }

    @Test("Reloading re-reads every listed folder and keeps open folders open")
    func reloadKeepsExpansion() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (tree, window) = await makeTree(root)
        _ = window
        let notes = try #require(tree.outline.item(atRow: 0) as? FileNode)
        tree.outline.expandItem(notes)
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "first.md", "top.md"])

        try Data().write(to: root.appendingPathComponent("notes/second.md"))
        try Data().write(to: root.appendingPathComponent("another.md"))
        tree.reload()
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "first.md", "second.md", "another.md", "top.md"])
        #expect(tree.outline.isItemExpanded(notes))
    }

    @Test("Revealing a file lists the folders on the way to it first")
    func revealListsFolders() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("notes/deep"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("notes/deep/buried.md"))
        let (tree, window) = await makeTree(root)
        _ = window
        tree.reveal(root.appendingPathComponent("notes/deep/buried.md"))
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "deep", "buried.md", "first.md", "top.md"])
        #expect((tree.outline.item(atRow: tree.outline.selectedRow) as? FileNode)?.url.lastPathComponent == "buried.md")
    }

    /// Folders were listed on the main thread as the tree asked for them, so
    /// a folder on a slow or remote volume froze the app until it answered.
    @Test("Folders are listed off the main thread, which stays free meanwhile")
    func listingOffMainThread() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = SlowGate()
        let (tree, window) = await makeTree(root) { url in
            gate.pass()
            return FileNode.list(url)
        }
        _ = window
        // Still waiting on the listing, and the main thread was handed back.
        #expect(rows(tree).isEmpty)
        try await gate.waitForReads()

        gate.open()
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "top.md"])
        let notes = try #require(tree.outline.item(atRow: 0) as? FileNode)
        tree.outline.expandItem(notes)
        await tree.finishListing()
        #expect(rows(tree) == ["notes", "first.md", "top.md"])
        #expect(tree.outline.isItemExpanded(notes))
        #expect(gate.calls == 2)
        #expect(!gate.ranOnMainThread)
        #expect(!gate.gaveUp)
    }

    @Test("The watcher reports the folder a file changed in")
    func watcherReportsFolders() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        final class Box { var folders: [String] = [] }
        let box = Box()
        let watcher = DirectoryWatcher(url: root) { change in
            if case let .folders(folders, _) = change { box.folders += folders }
        }
        #expect(watcher != nil)
        // FSEvents starts watching a moment after the stream does.
        try await Task.sleep(for: .milliseconds(300))
        try Data().write(to: root.appendingPathComponent("notes/new.md"))
        for _ in 0..<50 where box.folders.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
        }
        let notes = realPath(root.appendingPathComponent("notes").path)
        #expect(box.folders.contains { $0 == notes || $0 == notes + "/" }, "\(box.folders)")
        withExtendedLifetime(watcher) {}
    }
}
