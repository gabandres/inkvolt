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

/// How often macOS's queue list is polled for changes (PrintMac's `CupsQueueNotices`: macOS's cupsd takes no
/// subscriptions): every `live` while the window shows, every `saving` on battery or in Low Power Mode, and not at all while
/// it's closed (nil): the app's 60 s read of the queues is enough then, and cupsd, started on demand, may exit when idle.
public enum QueueNoticePolling {
    public static let live: Duration = .seconds(2)
    public static let saving: Duration = .seconds(6)

    public static func interval(windowOpen: Bool, onBattery: Bool, lowPower: Bool) -> Duration? {
        guard windowOpen else { return nil }
        return onBattery || lowPower ? saving : live
    }
}

/// A polling thread's pace and stop flag, shared with its owner instead of the owner itself (the owner's deinit stops it,
/// so dropping the owner ends the thread). `pause` waits `interval()` (while that's nil, until `wake`) and says whether to
/// go on; `stop` and `wake` cut a wait short, and a wait that ends with the interval nil (the window closed meanwhile)
/// waits on for `wake`. `sleep` stands in for the timed wait in tests (a fake clock).
public final class PollingLoop: Sendable {
    private let interval: @Sendable () -> Duration?
    private let sleep: (@Sendable (Duration) -> Void)?
    private let running = Mutex<Bool>(true)
    private let signal = DispatchSemaphore(value: 0)

    public init(interval: @escaping @Sendable () -> Duration?, sleep: (@Sendable (Duration) -> Void)? = nil) {
        self.interval = interval
        self.sleep = sleep
    }

    public var isRunning: Bool { running.withLock { $0 } }

    /// Waits for the next poll; false once stopped.
    public func pause() -> Bool {
        guard isRunning else { return false }
        if let every = interval() {
            var woken = false
            if let sleep {
                sleep(every)
            } else {
                let parts = every.components
                let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
                woken = signal.wait(timeout: .now() + seconds) == .success
            }
            if !woken && isRunning && interval() == nil { signal.wait() } // closed meanwhile: nothing until it opens
        } else {
            signal.wait()
        }
        while signal.wait(timeout: .now()) == .success {} // wakes that came together count once
        return isRunning
    }

    /// The interval may have changed (the window opened): a wait ends now.
    public func wake() { signal.signal() }

    /// No more polls: a wait ends now, and `pause` says stop.
    public func stop() {
        running.withLock { $0 = false }
        signal.signal()
    }
}
