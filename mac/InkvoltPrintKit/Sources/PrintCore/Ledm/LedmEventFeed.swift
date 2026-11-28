import Foundation
import Synchronization

/// One read of the printer's EventTable: its events, or (`answered` false) the printer stopped answering.
public struct LedmEventTable: Equatable, Sendable {
    public var events: [LedmEvent]
    public var answered: Bool

    public init(_ events: [LedmEvent], answered: Bool) {
        self.events = events
        self.answered = answered
    }
}

/// One connection's EventTable long poll, shared (Windows' `LedmEventFeed`): the poll runs while anyone watches (the printer
/// monitor, Scan to Computer) and stops when the last one leaves, so a printer never holds two long polls from this Mac. Each
/// watcher gets the last table at once (its starting point), then every table after it; one that falls behind keeps the
/// newest few (a table holds the latest event of each kind, so the newest says all). The poll ending (the tree lists no
/// EventTable) ends every watcher.
public final class LedmEventFeed: Sendable {
    private static let backlog = 8

    private typealias Watcher = AsyncStream<LedmEventTable>.Continuation

    private struct State {
        var watchers: [Int: Watcher] = [:]
        var next = 0
        var pump: (id: Int, task: Task<Void, Never>)?
        var last: LedmEventTable?
    }

    private let poll: @Sendable () -> AsyncStream<LedmEventTable>
    private let state = Mutex(State())

    public init(poll: @escaping @Sendable () -> AsyncStream<LedmEventTable>) { self.poll = poll }

    /// Long polls running now (tests: one per connection, however many watch).
    public var polls: Int { state.withLock { $0.pump == nil ? 0 : 1 } }

    public func subscribe() -> AsyncStream<LedmEventTable> {
        let (stream, continuation) = AsyncStream.makeStream(of: LedmEventTable.self, bufferingPolicy: .bufferingNewest(Self.backlog))
        let id: Int = state.withLock { s in
            let id = s.next
            s.next += 1
            s.watchers[id] = continuation
            if let last = s.last { continuation.yield(last) }
            if s.pump == nil {
                let pumpId = id
                s.pump = (pumpId, Task { [weak self] in await self?.pump(pumpId) })
            }
            return id
        }
        continuation.onTermination = { [weak self] _ in self?.leave(id) }
        return stream
    }

    private func leave(_ id: Int) {
        let stop: Task<Void, Never>? = state.withLock { s in
            s.watchers[id] = nil
            guard s.watchers.isEmpty, let pump = s.pump else { return nil }
            s.pump = nil
            s.last = nil
            return pump.task
        }
        stop?.cancel()
    }

    private func pump(_ id: Int) async {
        for await table in poll() {
            let running = state.withLock { s -> Bool in
                guard s.pump?.id == id else { return false } // stopped: everyone left
                s.last = table
                for w in s.watchers.values { w.yield(table) }
                return true
            }
            if !running { return }
        }
        // The poll ended (no EventTable, or stopped): the watchers end, and the next one starts it again.
        let ended: [Watcher] = state.withLock { s in
            guard s.pump?.id == id else { return [] }
            s.pump = nil
            s.last = nil
            defer { s.watchers.removeAll() }
            return Array(s.watchers.values)
        }
        for w in ended { w.finish() } // outside the lock: finishing runs each one's onTermination
    }
}
