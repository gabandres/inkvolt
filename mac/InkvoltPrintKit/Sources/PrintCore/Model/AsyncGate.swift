import Foundation
import Synchronization

/// One at a time through, in order of arrival (the Mac's counterpart of .NET's `SemaphoreSlim(1, 1)`): `ScanButton`'s and
/// a share's calls, a shared scanner's one scan. `enter` waits its turn and throws `CancellationError` when its task is
/// cancelled while it waits (it is then not let in); `run` waits whatever happens, and leaves when its work is done. Every
/// `enter` that returned is matched by one `leave`.
public final class AsyncGate: Sendable {
    private struct State {
        var busy = false
        var waiting: [(id: Int, continuation: CheckedContinuation<Bool, Never>)] = []
        var nextId = 0
    }

    private let state = Mutex(State())

    public init() {}

    /// Whether someone is through now.
    public var isBusy: Bool { state.withLock { $0.busy } }

    /// `work` alone through the gate, in its turn (the wait isn't cut short by cancellation).
    public func run<T>(_ work: () async throws -> T) async rethrows -> T {
        _ = await wait(cancellable: false)
        defer { leave() }
        return try await work()
    }

    public func enter() async throws {
        if !(await wait(cancellable: true)) { throw CancellationError() }
    }

    /// Without waiting: true (and through) when nobody is.
    public func tryEnter() -> Bool {
        state.withLock { s in
            if s.busy { return false }
            s.busy = true
            return true
        }
    }

    public func leave() {
        let next = state.withLock { s -> CheckedContinuation<Bool, Never>? in
            if s.waiting.isEmpty {
                s.busy = false
                return nil
            }
            return s.waiting.removeFirst().continuation // still busy: handed straight to the next
        }
        next?.resume(returning: true)
    }

    /// Through (true), or not let in because the task was cancelled while it waited (false; only when `cancellable`).
    private func wait(cancellable: Bool) async -> Bool {
        let id = state.withLock { s -> Int in
            s.nextId += 1
            return s.nextId
        }
        let start: @Sendable (CheckedContinuation<Bool, Never>) -> Void = { c in
            let now: Bool? = self.state.withLock { s in
                if cancellable && Task.isCancelled { return false }
                if !s.busy {
                    s.busy = true
                    return true
                }
                s.waiting.append((id, c))
                return nil
            }
            if let now { c.resume(returning: now) }
        }
        guard cancellable else { return await withCheckedContinuation(start) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation(start)
        } onCancel: {
            let waiter = state.withLock { s -> CheckedContinuation<Bool, Never>? in
                guard let i = s.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                return s.waiting.remove(at: i).continuation
            }
            waiter?.resume(returning: false)
        }
    }
}
