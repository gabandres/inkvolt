import Foundation
import Synchronization

/// Queue change notices made one read of the queues: a burst of them (a queue renamed is a delete, an add and changes a
/// moment apart) reads the list once, `quiet` after the last, and notices that never stop still read it within `longest`
/// of the first. `changed` is called on its own task, never after `close`. The Windows Core's `QueueChangeNotices`; on the
/// Mac the notices come from PrintMac's `CupsQueueNotices` (CUPS's events where cupsd has subscriptions; macOS's hasn't,
/// so a change in the queue list it polls).
public final class QueueChangeNotices: Sendable {
    private struct State {
        var first: ContinuousClock.Instant?
        var last = ContinuousClock.now
        var waiting: Task<Void, Never>?
        var closed = false
    }

    private let changed: @Sendable () -> Void
    private let quiet: Duration
    private let longest: Duration
    private let state = Mutex(State())

    public init(quiet: Duration, longest: Duration, changed: @escaping @Sendable () -> Void) {
        self.changed = changed
        self.quiet = quiet
        self.longest = longest
    }

    /// A notice came: `changed` is called once it's quiet.
    public func notice() {
        state.withLock { s in
            guard !s.closed else { return }
            let now = ContinuousClock.now
            s.last = now
            guard s.first == nil else { return } // the waiting task pushes itself back
            s.first = now
            s.waiting = Task { [weak self] in await self?.wait() }
        }
    }

    /// Waits until it's been quiet for `quiet`, or `longest` since the first notice, then reads.
    private func wait() async {
        while true {
            let due: ContinuousClock.Instant? = state.withLock { s in
                guard !s.closed, let first = s.first else { return nil }
                return min(s.last + quiet, first + longest)
            }
            guard let due else { return }
            if ContinuousClock.now >= due { break }
            guard (try? await Task.sleep(until: due, clock: .continuous)) != nil else { return }
        }
        let fire = state.withLock { s -> Bool in
            guard !s.closed else { return false }
            s.first = nil
            s.waiting = nil
            return true
        }
        if fire { changed() }
    }

    /// No more reads: a notice after this is ignored, and one waiting is dropped.
    public func close() {
        let waiting = state.withLock { s -> Task<Void, Never>? in
            s.closed = true
            defer { s.waiting = nil }
            return s.waiting
        }
        waiting?.cancel()
    }

    deinit { state.withLock { $0.waiting?.cancel() } }
}
