import AppKit
import ImageIO

/// Loads images referenced by documents, once each, off the main thread.
///
/// Posts `didLoad` with the URL as the object when an image arrives, so text
/// storages that asked for it can make room and draw it.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    /// The app has the one; tests make their own to fill.
    init() {}
    nonisolated static let didLoad = Notification.Name("MdEditImageCacheDidLoad")

    private enum Entry {
        case loading
        /// When it failed, and the file it failed on, if it is one.
        case failed(at: ContinuousClock.Instant, stamp: FileStamp?)
    }

    /// A local file as it was when read: one that changes is read again.
    struct FileStamp: Equatable, Sendable {
        let modified: Date?
        let size: Int?

        /// Nil for a web address, and for a file that is not there.
        nonisolated init?(_ url: URL) {
            guard url.isFileURL,
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)
            else { return nil }
            modified = attributes[.modificationDate] as? Date
            size = attributes[.size] as? Int
        }
    }

    /// A loaded image, with what tells whether its file has changed since.
    private final class Loaded {
        let image: NSImage
        let stamp: FileStamp?
        var checked: ContinuousClock.Instant

        init(image: NSImage, stamp: FileStamp?, checked: ContinuousClock.Instant) {
            self.image = image
            self.stamp = stamp
            self.checked = checked
        }
    }

    /// Images on their way or that could not be read.
    private var entries: [URL: Entry] = [:]
    /// Loaded images, by decoded size: those no open document still shows
    /// can go when memory is short. A document showing one keeps it alive.
    private let loaded: NSCache<NSURL, Loaded> = {
        let cache = NSCache<NSURL, Loaded>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// Wider than the widest column at 2x: more pixels are never drawn, and
    /// a photo straight off a camera would be 48 MB decoded and scaled down
    /// again on every redraw.
    nonisolated static let maxPixelWidth = 2800

    /// How long a web image that failed is left alone before a line showing
    /// it may ask again: the server was down or the machine offline, and
    /// asking on every restyle would be a request per arrival and caret move.
    nonisolated static let retryInterval: Duration = .seconds(30)
    /// How often a local file is looked at for a change, at most: a restyle
    /// should not cost a trip to the disk each time, on a network volume least of all.
    nonisolated static let fileCheckInterval: Duration = .seconds(2)
    /// The failures remembered. Past this the oldest are forgotten, which
    /// only means they are tried again when next asked for.
    nonisolated static let maxFailures = 256

    /// The image if it is ready; otherwise starts loading it and returns nil.
    ///
    /// Without `startingLoad` nothing is started: the image shows if it is
    /// here already. A line being edited asks that way, or typing a URL
    /// would fetch every prefix of it. One that failed is tried again once
    /// its file has changed or, on the web, after `retryInterval`; a local
    /// image whose file has changed since keeps showing while it is read again.
    func image(for url: URL, startingLoad: Bool = true, now: ContinuousClock.Instant = .now) -> NSImage? {
        let ready = loaded.object(forKey: url as NSURL)
        guard startingLoad else { return ready?.image }
        switch entries[url] {
        case .loading?:
            break
        case let .failed(at, stamp)?:
            if url.isFileURL {
                guard now - at >= Self.fileCheckInterval else { break }
                if FileStamp(url) == stamp {
                    entries[url] = .failed(at: now, stamp: stamp)
                } else {
                    startLoad(url)
                }
            } else if now - at >= Self.retryInterval {
                startLoad(url)
            }
        case nil:
            guard let ready else {
                startLoad(url)
                break
            }
            if url.isFileURL, now - ready.checked >= Self.fileCheckInterval {
                ready.checked = now
                if FileStamp(url) != ready.stamp { startLoad(url) }
            }
        }
        return ready?.image
    }

    private func startLoad(_ url: URL) {
        entries[url] = .loading
        Task.detached(priority: .utility) {
            // Before the bytes: a file written while it is read is read again.
            let stamp = FileStamp(url)
            let image = await Self.load(url)
            await MainActor.run {
                self.finish(url, image: image, stamp: stamp)
            }
        }
    }

    /// Whether an image could not be read, so nothing is waiting for it.
    func hasFailed(_ url: URL) -> Bool {
        if case .failed? = entries[url] { true } else { false }
    }

    /// Whether this image is on its way, so a line showing it has an
    /// arrival to wait for.
    func isLoading(_ url: URL) -> Bool {
        if case .loading? = entries[url] { true } else { false }
    }

    /// Whether any image is still on its way, so printing can wait for it.
    var isLoading: Bool {
        entries.values.contains { if case .loading = $0 { true } else { false } }
    }

    private func finish(_ url: URL, image: NSImage?, stamp: FileStamp?) {
        guard let image else {
            entries[url] = .failed(at: .now, stamp: stamp)
            forgetOldFailures()
            // An image that was showing and whose file is gone or no longer
            // an image: its lines are told, to stop showing it.
            if loaded.object(forKey: url as NSURL) != nil {
                loaded.removeObject(forKey: url as NSURL)
                NotificationCenter.default.post(name: Self.didLoad, object: url)
            }
            return
        }
        entries[url] = nil
        let cost = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        loaded.setObject(Loaded(image: image, stamp: stamp, checked: .now), forKey: url as NSURL, cost: cost)
        NotificationCenter.default.post(name: Self.didLoad, object: url)
    }

    /// Keeps `entries` from growing with every address that ever failed.
    /// The oldest quarter goes at once, so a full table is not searched
    /// again on each failure after it.
    private func forgetOldFailures() {
        let failures = entries.compactMap { url, entry in
            if case let .failed(at, _) = entry { (url, at) } else { nil }
        }
        guard failures.count > Self.maxFailures else { return }
        for (url, _) in failures.sorted(by: { $0.1 < $1.1 }).prefix(Self.maxFailures / 4 + failures.count - Self.maxFailures) {
            entries[url] = nil
        }
    }

    private nonisolated static func load(_ url: URL) async -> NSImage? {
        let data: Data?
        if url.isFileURL {
            data = localData(url)
        } else {
            data = await ImageDownloader.shared.data(from: url)
        }
        guard let data else { return nil }
        return decoded(data) ?? NSImage(data: data).flatMap { $0.size.width > 0 && $0.size.height > 0 ? $0 : nil }
    }

    /// The most a web image may weigh: a document must not be able to make
    /// the app read an endless response into memory.
    nonisolated static let maxDownloadBytes = 50 * 1024 * 1024

    /// A local image's bytes, held to the same limit as a web image's. Only
    /// a regular file is read: `/dev/zero` or a named pipe would be read
    /// forever, or wait forever for a writer.
    nonisolated static func localData(_ url: URL) -> Data? {
        let path = url.resolvingSymlinksInPath().path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? Int, size <= maxDownloadBytes
        else { return nil }
        return try? Data(contentsOf: URL(fileURLWithPath: path))
    }

    /// A bitmap decoded here, off the main thread, rather than on its first
    /// draw, and no wider than `maxPixelWidth`. It keeps the size the image
    /// would have had: its pixels at its resolution, upright. Nil for what
    /// ImageIO does not read as a bitmap, such as PDF and SVG.
    nonisolated static func decoded(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              var width = properties[kCGImagePropertyPixelWidth] as? Int,
              var height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        // Orientations 5 to 8 turn the picture on its side.
        if let orientation = properties[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
        let longest = max(width, height) * min(maxPixelWidth, width) / width
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: longest,
        ] as CFDictionary) else { return nil }
        let dpi = (properties[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 0 ? $0 : nil } ?? 72
        let size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
        // A bitmap rep, which counts the pixels it has; NSImage(cgImage:)
        // reports pixels for the screen it might be drawn on instead.
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = size
        let result = NSImage(size: size)
        result.addRepresentation(rep)
        return result
    }
}

/// Fetches web images, giving up on one as soon as it is known to be too
/// large: when the server says so up front, or once more bytes than the
/// limit have come. `URLSession.download(from:)` checked only the finished
/// file, so an endless response was written to disk until the session's
/// own timeout, which is a week.
final class ImageDownloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    static let shared = ImageDownloader()

    private struct Transfer {
        /// Nil once it has outgrown the limit.
        var body: Data? = Data()
        let continuation: CheckedContinuation<Data?, Never>
    }

    private let limit: Int
    private let lock = NSLock()
    private var transfers: [Int: Transfer] = [:]
    private var session: URLSession!

    /// A server that goes quiet is dropped after `idle` seconds, and a
    /// transfer that trickles is dropped after `total`.
    init(
        configuration: URLSessionConfiguration = .default,
        limit: Int = ImageCache.maxDownloadBytes,
        idle: TimeInterval = 30,
        total: TimeInterval = 300
    ) {
        self.limit = limit
        super.init()
        configuration.timeoutIntervalForRequest = idle
        configuration.timeoutIntervalForResource = total
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// The session holds on to its delegate until told it is done with.
    func invalidate() {
        session.invalidateAndCancel()
    }

    /// The bytes at an address. Nil when the request fails, the answer is
    /// not a success, or it is larger than the limit.
    func data(from url: URL) async -> Data? {
        await withCheckedContinuation { continuation in
            let task = session.dataTask(with: url)
            lock.withLock { transfers[task.taskIdentifier] = Transfer(continuation: continuation) }
            task.resume()
        }
    }

    /// Whether a response is worth reading: a success, and not announced
    /// as larger than the limit. A length of -1 is one the server left out.
    static func accepts(_ response: URLResponse, limit: Int) -> Bool {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return false }
        return response.expectedContentLength <= Int64(limit)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        completionHandler(Self.accepts(response, limit: limit) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let outgrown = lock.withLock {
            // Only the count is read: a second reference to the bytes, alive
            // across the append, had each chunk copy all that came before it.
            guard let count = transfers[dataTask.taskIdentifier]?.body?.count else { return false }
            if count + data.count > limit {
                transfers[dataTask.taskIdentifier]?.body = nil
                return true
            }
            transfers[dataTask.taskIdentifier]?.body?.append(data)
            return false
        }
        if outgrown { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let transfer = lock.withLock({ transfers.removeValue(forKey: task.taskIdentifier) }) else { return }
        transfer.continuation.resume(returning: error == nil ? transfer.body : nil)
    }
}

/// An image placed above its line — or below it, or in it — carried as an
/// attribute for the layout manager to draw.
final class InlineImage: NSObject {
    let image: NSImage
    let size: CGSize
    /// Centred in the column rather than at the line's indent.
    let centered: Bool
    /// In the space after the line instead of above it.
    let below: Bool
    /// For an image in a line of text, how far it hangs below the baseline.
    let descent: CGFloat
    /// What VoiceOver reads in place of the picture: a formula's TeX, a
    /// diagram's source. Empty for a plain image, whose alt text is its caption.
    let label: String

    init(image: NSImage, size: CGSize, centered: Bool = false, below: Bool = false, descent: CGFloat = 0, label: String = "") {
        self.image = image
        self.label = label
        self.size = size
        self.centered = centered
        self.below = below
        self.descent = descent
    }
}
