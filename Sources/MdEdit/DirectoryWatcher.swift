import CoreServices
import Foundation

/// Watches a folder and everything below it, coalescing bursts of changes.
///
/// `FileWatcher` follows one file through a dispatch source; a whole tree
/// needs FSEvents, which reports changes anywhere beneath a path.
/// `@unchecked Sendable` because it is created on the main queue and the
/// stream delivers there too.
final class DirectoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init?(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { watcher.onChange() }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,  // seconds of latency, which coalesces a save's several events
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else { return nil }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
