import AppKit
import UniformTypeIdentifiers

/// Turns pasted or dropped images into markdown: files are linked where they
/// are, raw image data is saved into an `assets` folder beside the document.
enum ImageImporter {
    enum ImportError: LocalizedError {
        case unsavedDocument

        var errorDescription: String? {
            "Save this document first, so pasted images have a folder to go in."
        }
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard url.isFileURL, let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    /// `![name](path)`, relative to the document when it can be.
    static func markdown(forImageAt url: URL, documentURL: URL?) -> String {
        let alt = url.deletingPathExtension().lastPathComponent
        return "![\(alt)](\(destination(for: url, documentURL: documentURL)))"
    }

    /// A path from the document's folder when the image is inside it, else absolute.
    /// Wrapped in `<>` when it contains spaces, which a bare destination cannot.
    static func destination(for url: URL, documentURL: URL?) -> String {
        var path = url.standardizedFileURL.path
        if let folder = documentURL?.deletingLastPathComponent().standardizedFileURL.path {
            let prefix = folder.hasSuffix("/") ? folder : folder + "/"
            if path.hasPrefix(prefix) { path = String(path.dropFirst(prefix.count)) }
        }
        return path.contains(" ") ? "<\(path)>" : path
    }

    /// Saves image data as PNG in `assets/` beside the document, under a name
    /// that does not collide with anything already there.
    static func save(_ image: NSImage, besideDocument documentURL: URL?, date: Date = Date()) throws -> URL {
        guard let documentURL else { throw ImportError.unsavedDocument }
        guard let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }

        let folder = documentURL.deletingLastPathComponent().appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "image-\(formatter.string(from: date))"
        var target = folder.appendingPathComponent("\(stem).png")
        var counter = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = folder.appendingPathComponent("\(stem)-\(counter).png")
            counter += 1
        }
        try png.write(to: target, options: .atomic)
        return target
    }
}
