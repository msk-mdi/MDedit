import AppKit
import Testing
@testable import MdEdit

@Suite("FileFormat")
struct FileFormatTests {
    @Test("Plain UTF-8 with LF round-trips unchanged")
    func utf8RoundTrip() throws {
        let data = Data("# Title\n\nbody\n".utf8)
        let (text, format) = try FileFormat.decode(data)
        #expect(text == "# Title\n\nbody\n")
        #expect(format == FileFormat())
        #expect(try format.encode(text) == data)
    }

    @Test("CRLF is edited as LF and written back as CRLF")
    func crlfRoundTrip() throws {
        let data = Data("a\r\nb\r\n".utf8)
        let (text, format) = try FileFormat.decode(data)
        #expect(text == "a\nb\n")
        #expect(format.lineEnding == "\r\n")
        #expect(try format.encode(text + "c\n") == Data("a\r\nb\r\nc\r\n".utf8))
    }

    @Test("A UTF-8 byte order mark is hidden from the editor and kept on save")
    func bomRoundTrip() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("hello".utf8)
        let (text, format) = try FileFormat.decode(data)
        #expect(text == "hello")
        #expect(format.hasByteOrderMark)
        #expect(try format.encode(text) == data)
    }

    @Test("A non-UTF-8 file is saved in its original encoding")
    func legacyEncodingRoundTrip() throws {
        let data = try #require("café crème".data(using: .isoLatin1))
        let (text, format) = try FileFormat.decode(data)
        #expect(text == "café crème")
        #expect(format.encoding != .utf8)
        #expect(try format.encode(text) == data)
    }

    @Test("Text the original encoding cannot hold is an error, not a silent conversion")
    func unencodableTextThrows() {
        let format = FileFormat(encoding: .ascii)
        #expect(throws: (any Error).self) { try format.encode("naïve") }
    }
}

@Suite("RecoveryStore")
struct RecoveryStoreTests {
    private func store() -> RecoveryStore {
        RecoveryStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("MdEditRecoveryTests-\(UUID().uuidString)", isDirectory: true))
    }

    @Test("Snapshots are written, replaced, removed and cleared")
    func lifecycle() throws {
        let store = store()
        defer { store.removeAll() }
        #expect(store.snapshots().isEmpty)

        let untitled = RecoveryStore.Snapshot(id: UUID(), url: nil, text: "draft")
        var named = RecoveryStore.Snapshot(id: UUID(), url: URL(fileURLWithPath: "/tmp/a.md"), text: "one")
        try store.write(untitled)
        try store.write(named)
        named.text = "two"
        try store.write(named)

        let all = store.snapshots()
        #expect(all.count == 2)
        #expect(all.contains(untitled))
        #expect(all.contains(named))

        store.remove(id: untitled.id)
        #expect(store.snapshots() == [named])

        store.removeAll()
        #expect(store.snapshots().isEmpty)
    }
}

@Suite("Session")
struct SessionTests {
    @Test("A session survives a round trip through user defaults")
    func roundTrip() throws {
        let suite = "MdEditSessionTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        #expect(Session.load(from: defaults) == nil)
        let session = Session(
            tabs: [.init(url: URL(fileURLWithPath: "/tmp/a.md"), selectedLocation: 12)],
            selectedIndex: 0
        )
        session.save(to: defaults)
        #expect(Session.load(from: defaults) == session)
    }
}

@MainActor
@Suite("Document")
struct DocumentTests {
    @Test("Recovered text counts as unsaved; saving clears it")
    func restoredTextIsDirty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditDocTest-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("saved\r\n".utf8).write(to: url)

        let document = try Document.open(contentsOf: url, theme: .light)
        #expect(!document.isDirty)
        document.restoreUnsavedText("recovered\n")
        #expect(document.isDirty)

        try document.save()
        #expect(!document.isDirty)
        #expect(try Data(contentsOf: url) == Data("recovered\r\n".utf8))
    }

    @Test("A document whose file vanished stays dirty until saved")
    func missingFileIsDirty() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditDocTest-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = Document(url: url, text: "x", theme: .light)
        #expect(!document.isDirty)
        document.markMissingOnDisk()
        #expect(document.isDirty)
        try document.save()
        #expect(!document.isDirty)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
