import CoreServices
import Foundation

/// Watches a folder and everything below it, coalescing bursts of changes.
///
/// `FileWatcher` follows one file through a dispatch source; a whole tree
/// needs FSEvents, which reports changes anywhere beneath a path.
/// `@unchecked Sendable` because it is created on the main queue and the
/// stream delivers there too.
final class DirectoryWatcher: @unchecked Sendable {
    /// What changed: the folders whose contents did, as FSEvents reports them
    /// (symlinks resolved), with the items created, removed or renamed in
    /// them; or everything, when FSEvents lost track. A file written over in
    /// place names its folder, and no item.
    enum Change {
        case folders([String], moved: [Item] = [])
        case everything
    }

    /// A file or folder that came, went, or was renamed.
    struct Item: Equatable {
        var path: String
        var isDirectory: Bool
    }

    private var stream: FSEventStreamRef?
    private let onChange: @MainActor (Change) -> Void

    init?(url: URL, onChange: @escaping @MainActor (Change) -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<DirectoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let items = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            let lostTrack = FSEventStreamEventFlags(
                kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                    | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged
            )
            let everything = (0..<count).contains { flags[$0] & lostTrack != 0 }
            let movedFlags = FSEventStreamEventFlags(
                kFSEventStreamEventFlagItemCreated | kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed
            )
            var folders: [String] = []
            var moved: [Item] = []
            for (index, path) in items.enumerated() where index < count {
                folders.append((path as NSString).deletingLastPathComponent)
                if flags[index] & movedFlags != 0 {
                    moved.append(Item(path: path, isDirectory: flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagItemIsDir) != 0))
                }
            }
            var seen = Set<String>()
            folders.removeAll { !seen.insert($0).inserted }
            let change: Change = everything ? .everything : .folders(folders, moved: moved)
            // The stream delivers on the main queue.
            MainActor.assumeIsolated { watcher.onChange(change) }
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.4,  // seconds of latency, which coalesces a save's several events
            // File events, not folder ones: a note saved, by this app or
            // another, is told from one created or removed, which alone
            // changes what a folder lists.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
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
