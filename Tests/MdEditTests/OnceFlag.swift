import Foundation

/// True the first time it is asked, from any thread: lets a stand-in reader
/// do something to the file on its first read only, as a sync client
/// rewriting it once would.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var taken = false

    func take() -> Bool {
        lock.withLock {
            defer { taken = true }
            return !taken
        }
    }
}
