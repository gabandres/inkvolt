import Foundation

/// Asks running work to stop (the Windows app's `CancellationToken`): a render stops midway (MuPDF's cookie), text and
/// link reads don't start. Engine calls throw `CancellationError` once it fires. Cancelling is safe from any thread.
public final class CancelToken: @unchecked Sendable {
    private let lock = NSCondition()
    private var cancelled = false
    private var handlers: [Int: () -> Void] = [:]
    private var nextId = 0
    /// Handlers `cancel()` took and hasn't finished running (one of them running now: `current`), and the thread running
    /// them.
    private var running: Set<Int> = []
    private var current: Int?
    private var runner: pthread_t?

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
        let run = handlers
        handlers = [:]
        running = Set(run.keys)
        runner = pthread_self()
        lock.unlock()
        // Outside the lock (a handler may look at the token, unregister itself or another, register: none waits for
        // this thread), each one marked done as it ends, for `unregister`; one unregistered before its turn is skipped.
        for (id, handler) in run {
            lock.lock()
            let due = running.contains(id)
            if due { current = id }
            lock.unlock()
            if !due { continue }
            handler()
            lock.lock()
            running.remove(id)
            current = nil
            lock.broadcast()
            lock.unlock()
        }
        lock.lock()
        runner = nil
        lock.unlock()
    }

    /// Throws `CancellationError` once cancelled.
    public func check() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Runs `handler` when cancelled (at once if it already is); the id unregisters it.
    public func register(_ handler: @escaping () -> Void) -> Int? {
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

    /// The handler won't run from now on: if `cancel()` is running it on another thread, this waits for it to end, so
    /// what the handler touches may be freed once this returns. A handler must not wait for another thread that may be
    /// unregistering (from this token or one it cancels): that thread may be waiting for it.
    public func unregister(_ id: Int?) {
        guard let id else { return }
        lock.lock()
        defer { lock.unlock() }
        handlers[id] = nil
        // Not started yet: it won't be.
        if running.contains(id), current != id { running.remove(id) }
        // A handler unregistering itself (on the thread running it) doesn't wait for itself.
        while running.contains(id), let runner, pthread_equal(runner, pthread_self()) == 0 { lock.wait() }
    }
}

extension Optional where Wrapped == CancelToken {
    func check() throws { try self?.check() }
}
