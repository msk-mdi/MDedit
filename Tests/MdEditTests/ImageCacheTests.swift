import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import MdEdit

@Suite("Image cache")
struct ImageCacheTests {
    /// An image file's data: pixels, a resolution, and an EXIF orientation.
    private func imageData(width: Int, height: Int, type: UTType = .png, dpi: Double = 72, orientation: Int = 1) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi, kCGImagePropertyOrientation: orientation,
        ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("Decoded images keep the size NSImage gives them", arguments: [
        (UTType.png, 72.0), (UTType.png, 144.0), (UTType.jpeg, 72.0), (UTType.jpeg, 300.0),
    ])
    func sizeMatchesNSImage(type: UTType, dpi: Double) throws {
        let data = try imageData(width: 600, height: 400, type: type, dpi: dpi)
        let decoded = try #require(ImageCache.decoded(data))
        let reference = try #require(NSImage(data: data))
        #expect(decoded.size == reference.size)
        #expect(decoded.representations.first?.pixelsWide == 600)
    }

    @Test("A large image is decoded at most as wide as the widest column needs")
    func largeImagesShrink() throws {
        let decoded = try #require(ImageCache.decoded(imageData(width: 4000, height: 3000, type: .jpeg)))
        #expect(decoded.size == NSSize(width: 4000, height: 3000))
        #expect(decoded.representations.first?.pixelsWide == ImageCache.maxPixelWidth)
        #expect(decoded.representations.first?.pixelsHigh == 2100)

        // A tall, narrow image is under the width already: it keeps every pixel.
        let tall = try #require(ImageCache.decoded(imageData(width: 1000, height: 8000)))
        #expect(tall.representations.first?.pixelsWide == 1000)
        #expect(tall.representations.first?.pixelsHigh == 8000)
    }

    @Test("A photo taken sideways is decoded upright")
    func orientation() throws {
        let decoded = try #require(ImageCache.decoded(imageData(width: 600, height: 400, type: .jpeg, orientation: 6)))
        #expect(decoded.size == NSSize(width: 400, height: 600))
        #expect(decoded.representations.first?.pixelsWide == 400)
    }

    @Test("What ImageIO cannot read as a bitmap is left to NSImage")
    func vectorFallsBack() {
        let svg = Data(#"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"/>"#.utf8)
        #expect(ImageCache.decoded(svg) == nil)
    }

    /// `![](/dev/zero)` read forever, and a pipe waited forever for a writer.
    @Test("Only a regular local file within the size limit is read as an image")
    func localFilesOnly() throws {
        #expect(ImageCache.localData(URL(fileURLWithPath: "/dev/zero")) == nil)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pipe = directory.appendingPathComponent("pipe.png")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(ImageCache.localData(pipe) == nil)
        let small = directory.appendingPathComponent("small.png")
        try Data([1, 2, 3]).write(to: small)
        #expect(ImageCache.localData(small) == Data([1, 2, 3]))
        let large = directory.appendingPathComponent("large.png")
        #expect(FileManager.default.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: UInt64(ImageCache.maxDownloadBytes + 1))
        try handle.close()
        #expect(ImageCache.localData(large) == nil)
    }

    /// A folder of its own, so no other test's images are in the cache.
    private func imageFolder() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditImages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @MainActor
    private func settled(_ url: URL) async throws {
        for _ in 0..<200 where ImageCache.shared.isLoading(url) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!ImageCache.shared.isLoading(url))
    }

    /// A line being edited asks this way: typing a URL fetched each prefix.
    @MainActor
    @Test("Asking without starting a load starts none")
    func askingWithoutLoading() async throws {
        let folder = try imageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pic.png")
        try imageData(width: 20, height: 10).write(to: url)
        #expect(ImageCache.shared.image(for: url, startingLoad: false) == nil)
        #expect(!ImageCache.shared.isLoading(url))
        #expect(!ImageCache.shared.hasFailed(url))

        #expect(ImageCache.shared.image(for: url) == nil)
        #expect(ImageCache.shared.isLoading(url))
        try await settled(url)
        // Once here, it shows however it is asked for.
        #expect(ImageCache.shared.image(for: url, startingLoad: false)?.size.width == 20)
    }

    /// An image named before its file was saved never showed until relaunch.
    @MainActor
    @Test("A local image that failed is read again once its file changes")
    func failedFileRetries() async throws {
        let folder = try imageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pic.png")
        _ = ImageCache.shared.image(for: url)
        try await settled(url)
        #expect(ImageCache.shared.hasFailed(url))

        // Still missing: looked at again, not read again.
        _ = ImageCache.shared.image(for: url, now: .now + ImageCache.fileCheckInterval)
        #expect(ImageCache.shared.hasFailed(url))

        try imageData(width: 20, height: 10).write(to: url)
        // Not looked at on every request.
        _ = ImageCache.shared.image(for: url)
        #expect(ImageCache.shared.hasFailed(url))
        // Nor for a line being edited.
        _ = ImageCache.shared.image(for: url, startingLoad: false, now: .now + ImageCache.fileCheckInterval * 2)
        #expect(ImageCache.shared.hasFailed(url))

        _ = ImageCache.shared.image(for: url, now: .now + ImageCache.fileCheckInterval * 2)
        #expect(ImageCache.shared.isLoading(url))
        try await settled(url)
        #expect(ImageCache.shared.image(for: url)?.size.width == 20)
    }

    @MainActor
    @Test("A local image edited on disk is read again, and shows as it was meanwhile")
    func changedFileReloads() async throws {
        let folder = try imageFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("pic.png")
        try imageData(width: 20, height: 10).write(to: url)
        _ = ImageCache.shared.image(for: url)
        try await settled(url)

        // A different size, so the change shows whatever the clock's grain.
        try imageData(width: 40, height: 10).write(to: url)
        #expect(ImageCache.shared.image(for: url, now: .now + ImageCache.fileCheckInterval)?.size.width == 20)
        #expect(ImageCache.shared.isLoading(url))
        try await settled(url)
        #expect(ImageCache.shared.image(for: url)?.size.width == 40)

        // Gone: the lines showing it are told, and it stops showing.
        try FileManager.default.removeItem(at: url)
        _ = ImageCache.shared.image(for: url, now: .now + ImageCache.fileCheckInterval)
        try await settled(url)
        #expect(ImageCache.shared.image(for: url) == nil)
        #expect(ImageCache.shared.hasFailed(url))
    }

    /// A scheme no session loads fails at once, without the network.
    @MainActor
    @Test("An image that failed off the disk is asked for again only after a while")
    func failedAddressRetriesLater() async throws {
        let url = try #require(URL(string: "mdedit-test://\(UUID().uuidString)/pic.png"))
        _ = ImageCache.shared.image(for: url)
        try await settled(url)
        #expect(ImageCache.shared.hasFailed(url))

        _ = ImageCache.shared.image(for: url, now: .now + ImageCache.retryInterval / 2)
        #expect(ImageCache.shared.hasFailed(url))
        _ = ImageCache.shared.image(for: url, now: .now + ImageCache.retryInterval)
        #expect(ImageCache.shared.isLoading(url))
        try await settled(url)
        #expect(ImageCache.shared.hasFailed(url))
    }

    /// A cache of its own: the shared one would forget, with these, the
    /// failures other tests are looking at.
    @MainActor
    @Test("Only so many failures are remembered")
    func failuresAreBounded() async throws {
        let cache = ImageCache()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MdEditMissing-\(UUID().uuidString)")
        let missing = (0...ImageCache.maxFailures).map { folder.appendingPathComponent("\($0).png") }
        let first = try #require(missing.first), last = try #require(missing.last)
        _ = cache.image(for: first)
        for _ in 0..<200 where !cache.hasFailed(first) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cache.hasFailed(first))

        for url in missing.dropFirst() { _ = cache.image(for: url) }
        for _ in 0..<500 where cache.isLoading {
            try await Task.sleep(for: .milliseconds(10))
        }
        // The oldest was forgotten, to be tried again when next asked for.
        #expect(!cache.hasFailed(first))
        #expect(cache.hasFailed(last))
    }

    /// Answers by host name, with no network: `small` with 600 bytes,
    /// `missing` with a 404, `announced` with a length of 5000 and
    /// `endless` with bytes until it is stopped.
    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url, let host = url.host else { return }
            let response = HTTPURLResponse(
                url: url, statusCode: host == "missing" ? 404 : 200, httpVersion: "HTTP/1.1",
                headerFields: host == "announced" ? ["Content-Length": "5000"] : [:]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            guard host == "endless" else {
                client?.urlProtocol(self, didLoad: Data(repeating: 1, count: host == "small" ? 600 : 10))
                client?.urlProtocolDidFinishLoading(self)
                return
            }
            Thread.detachNewThread { [self] in
                while !lock.withLock({ stopped }) {
                    client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 100))
                    usleep(1000)
                }
            }
        }

        override func stopLoading() {
            lock.withLock { stopped = true }
        }
    }

    /// The limit was checked once the whole response was on disk, so one
    /// with no end was written there for as long as the server sent it.
    @Test("A web image is given up on as soon as it is too large")
    func downloadStopsAtLimit() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let downloader = ImageDownloader(configuration: configuration, limit: 1000)
        defer { downloader.invalidate() }
        func data(_ host: String) async throws -> Data? {
            let url = try #require(URL(string: "https://\(host)/pic.png"))
            return await downloader.data(from: url)
        }
        #expect(try await data("small") == Data(repeating: 1, count: 600))
        #expect(try await data("missing") == nil)
        #expect(try await data("announced") == nil)
        // Returns at all: the stub sends until the transfer is cancelled.
        #expect(try await data("endless") == nil)
    }

    @Test("A response is read only if it succeeded and fits")
    func acceptedResponses() throws {
        let url = try #require(URL(string: "https://example.com/pic.png"))
        func response(status: Int = 200, length: Int) -> URLResponse {
            HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Length": String(length)])!
        }
        #expect(ImageDownloader.accepts(response(length: 1000), limit: 1000))
        #expect(!ImageDownloader.accepts(response(length: 1001), limit: 1000))
        #expect(!ImageDownloader.accepts(response(status: 503, length: 10), limit: 1000))
        // A length the server left out is found out as the bytes come.
        #expect(ImageDownloader.accepts(URLResponse(url: url, mimeType: nil, expectedContentLength: -1, textEncodingName: nil), limit: 1000))
    }
}
