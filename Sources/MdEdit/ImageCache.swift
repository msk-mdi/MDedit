import AppKit
import ImageIO

/// Loads images referenced by documents, once each, off the main thread.
///
/// Posts `didLoad` with the URL as the object when an image arrives, so text
/// storages that asked for it can make room and draw it.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    private init() {}
    nonisolated static let didLoad = Notification.Name("MdEditImageCacheDidLoad")

    private enum Entry {
        case loading
        case failed
    }

    /// Images on their way or that could not be read.
    private var entries: [URL: Entry] = [:]
    /// Loaded images, by decoded size: those no open document still shows
    /// can go when memory is short. A document showing one keeps it alive.
    private let loaded: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()

    /// Wider than the widest column at 2x: more pixels are never drawn, and
    /// a photo straight off a camera would be 48 MB decoded and scaled down
    /// again on every redraw.
    nonisolated static let maxPixelWidth = 2800

    /// The image if it is ready; otherwise starts loading it and returns nil.
    func image(for url: URL) -> NSImage? {
        if let image = loaded.object(forKey: url as NSURL) { return image }
        switch entries[url] {
        case .loading?, .failed?:
            return nil
        case nil:
            entries[url] = .loading
            Task.detached(priority: .utility) {
                let image = await Self.load(url)
                await MainActor.run {
                    self.finish(url, image: image)
                }
            }
            return nil
        }
    }

    /// Whether an image could not be read, so nothing is waiting for it.
    func hasFailed(_ url: URL) -> Bool {
        if case .failed? = entries[url] { true } else { false }
    }

    /// Whether any image is still on its way, so printing can wait for it.
    var isLoading: Bool {
        entries.values.contains { if case .loading = $0 { true } else { false } }
    }

    /// Forgets an image so the next request reloads it, for files edited on disk.
    func invalidate(_ url: URL) {
        entries[url] = nil
        loaded.removeObject(forKey: url as NSURL)
    }

    private func finish(_ url: URL, image: NSImage?) {
        guard let image else {
            entries[url] = .failed
            return
        }
        entries[url] = nil
        let cost = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
        loaded.setObject(image, forKey: url as NSURL, cost: cost)
        NotificationCenter.default.post(name: Self.didLoad, object: url)
    }

    private nonisolated static func load(_ url: URL) async -> NSImage? {
        let data: Data?
        if url.isFileURL {
            data = localData(url)
        } else {
            data = await download(url)
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

    /// A web image's bytes, by way of a file so an oversized one never
    /// reaches memory. Nil when it fails or is too large.
    private nonisolated static func download(_ url: URL) async -> Data? {
        guard let (file, response) = try? await URLSession.shared.download(from: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int.max
        guard size <= maxDownloadBytes else { return nil }
        return try? Data(contentsOf: file)
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
