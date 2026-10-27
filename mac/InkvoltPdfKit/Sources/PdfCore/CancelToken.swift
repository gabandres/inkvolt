import Foundation

/// Asks running work to stop (the Windows app's `CancellationToken`): a render stops midway (MuPDF's cookie), text and
/// link reads don't start. Engine calls throw `CancellationError` once it fires. Cancelling is safe from any thread.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handlers: [Int: () -> Void] = [:]
    private var nextId = 0

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let run = handlers.values
        handlers = [:]
        lock.unlock()
        for h in run { h() }
    }

    /// Throws `CancellationError` once cancelled.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Runs `handler` when cancelled (at once if it already is); the id unregisters it.
    func register(_ handler: @escaping () -> Void) -> Int? {
        lock.lock()
        if cancelled {
            lock.unlock()
            handler()
            return nil
        }
        nextId += 1
        handlers[nextId] = handler
        lock.unlock()
        return nextId
    }

    func unregister(_ id: Int?) {
        guard let id else { return }
        lock.lock()
        handlers[id] = nil
        lock.unlock()
    }
}

extension Optional where Wrapped == CancelToken {
    func check() throws { try self?.check() }
}
