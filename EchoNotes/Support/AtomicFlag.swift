import Foundation

/// A lock-protected Bool readable from any thread. Used where the audio tap
/// thread needs a cheap gate check before doing work that a queue hop would
/// make wasteful (e.g. copying buffers that would only be dropped).
final class AtomicFlag {
    private let lock = NSLock()
    private var value: Bool

    init(_ initial: Bool = false) {
        value = initial
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
