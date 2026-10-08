import AppKit

/// Loads images referenced by documents, once each, off the main thread.
///
/// Posts `didLoad` with the URL as the object when an image arrives, so text
/// storages that asked for it can make room and draw it.
@MainActor
final class ImageCache {
    static let shared = ImageCache()
    nonisolated static let didLoad = Notification.Name("MdEditImageCacheDidLoad")

    private enum Entry {
        case loading
        case loaded(NSImage)
        case failed
    }

    private var entries: [URL: Entry] = [:]

    /// The image if it is ready; otherwise starts loading it and returns nil.
    func image(for url: URL) -> NSImage? {
        switch entries[url] {
        case let .loaded(image)?:
            return image
        case .loading?, .failed?:
            return nil
        case nil:
            entries[url] = .loading
            Task.detached(priority: .utility) {
                let image = await Self.load(url)
                await MainActor.run {
                    ImageCache.shared.finish(url, image: image)
                }
            }
            return nil
        }
    }

    /// Whether any image is still on its way, so printing can wait for it.
    var isLoading: Bool {
        entries.values.contains { if case .loading = $0 { true } else { false } }
    }

    /// Forgets an image so the next request reloads it, for files edited on disk.
    func invalidate(_ url: URL) {
        entries[url] = nil
    }

    private func finish(_ url: URL, image: NSImage?) {
        guard let image else {
            entries[url] = .failed
            return
        }
        entries[url] = .loaded(image)
        NotificationCenter.default.post(name: Self.didLoad, object: url)
    }

    private nonisolated static func load(_ url: URL) async -> NSImage? {
        let data: Data?
        if url.isFileURL {
            data = try? Data(contentsOf: url)
        } else {
            data = try? await URLSession.shared.data(from: url).0
        }
        guard let data, let image = NSImage(data: data), image.size.width > 0, image.size.height > 0 else { return nil }
        return image
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
