import Foundation
import Synchronization

/// Where this Mac stands on the printer's Scan to Computer list.
public enum PanelState: String, Sendable {
    /// Being added (or checked).
    case adding
    /// On the list, as this app added it: a press reaches this Mac.
    case listed
    /// A computer by this Mac's name is on the list already, not added by this app (HP's software, say): not added twice.
    case listedByOther
    /// The printer wants its admin password to add a computer.
    case needsPassword
    /// The printer refused, its list changed shape, or its list doesn't show this Mac after adding it.
    case refused
    /// The printer doesn't answer, or answered with an error: tried again a little later.
    case notReached
    /// Something went wrong here (not the printer's answer): stopped until turned off and on.
    case failed
}

/// Who this Mac is on a printer's list: the name the panel shows, and the host name that marks the destination as this app's.
public struct PanelOwner: Equatable, Sendable {
    public var name: String
    public var marker: String

    public init(_ name: String, _ marker: String) {
        self.name = name
        self.marker = marker
    }
}

/// What looking for the panel found: `panel` when the printer offers it; nil with `read` true when it doesn't; `read` false
/// when the printer couldn't be read (no answer, an error, an unreadable reply), to be tried again.
public struct PanelFound: Sendable {
    public var panel: ScanToComputer?
    public var read: Bool
}

/// This Mac on an HP printer's panel under Scan to Computer (`LedmWalkupScan`; Windows' `ScanToComputer`), over one
/// connection: found by reading only (the tree, the manifest, the list), then added with one POST when the person turns it on,
/// kept there while `run` runs (added again after the printer restarts or drops it: its `PowerUpEvent`, a lost connection),
/// and removed with one DELETE (`remove`). This app's destination is known by its host name (`PanelOwner.marker`), not by the
/// answer to the POST, so one whose answer was lost is still found and removed. A press of this Mac on the panel comes as a
/// scan event in the printer's EventTable, read through the connection's one shared long poll (`LedmClient.events`: no second
/// poll, no port opened on this Mac), and is told once. Writes go over HTTPS; the POST is never resent (a second would list
/// the Mac twice).
public final class ScanToComputer: Sendable {
    private let ledm: LedmClient
    public let listPath: String
    private let eventPath: String
    private let state = Mutex<(path: String?, retryDelay: Duration)>((nil, .seconds(30)))

    private init(_ ledm: LedmClient, _ listPath: String, _ eventPath: String) {
        self.ledm = ledm
        self.listPath = listPath
        self.eventPath = eventPath
    }

    /// This Mac's destination on the printer, as this app added it; nil while it isn't (or isn't known to be).
    public var path: String? { state.withLock { $0.path } }

    /// How often a quiet printer's list is looked at again, at most, when its EventTable changes.
    public static let recheck: Duration = .seconds(600)

    /// How long after a check that got no answer (or an error answer) the next one comes, the EventTable quiet or not.
    public var retryDelay: Duration {
        get { state.withLock { $0.retryDelay } }
        set { state.withLock { $0.retryDelay = newValue } }
    }

    /// Whether the printer's panel offers Scan to Computer in the names this code knows (GETs only), or couldn't be read.
    public static func detect(_ connection: PrinterConnection) async throws -> PanelFound {
        guard let ledm = connection.ledm else { return PanelFound(panel: nil, read: true) }
        return try await detect(ledm)
    }

    public static func detect(_ ledm: LedmClient) async throws -> PanelFound {
        do {
            guard let tree = try await ledm.tree(), tree.hasEvents, let manifestPath = LedmWalkupScan.manifestPath(tree),
                  let manifest = try await ledm.get(path: manifestPath), case let (list, event)? = LedmWalkupScan.paths(manifest),
                  let doc = try await ledm.get(path: list), LedmWalkupScan.read(doc) != nil else { return PanelFound(panel: nil, read: true) }
            return PanelFound(panel: ScanToComputer(ledm, list, event), read: true)
        } catch where DeviceFailure.isOffline(error) || DeviceFailure.isTransient(error) {
            return PanelFound(panel: nil, read: false)
        }
    }

    /// Makes sure this Mac is on the list: this app's destination (its `PanelOwner.marker`) is kept wherever it is; a computer
    /// by this Mac's name without the marker is another program's and nothing is added; else one POST adds it. Never throws for
    /// the printer's answers (they're the state): no answer or an error answer is `.notReached`, to try again later.
    public func ensureListed(_ owner: PanelOwner) async throws -> PanelState {
        let (list, listed, problem) = try await readList()
        if let problem { return problem }
        guard let list, let listed else { return .refused }

        if let mine = Self.mine(listed, owner) {
            state.withLock { $0.path = mine }
            return .listed
        }
        state.withLock { $0.path = nil }
        if listed.contains(where: { Self.same($0.name, owner.name) || Self.same($0.hostname, owner.name) }) { return .listedByOther }

        let location: String?
        do {
            location = try await ledm.post(path: listPath, LedmWalkupScan.build(list, panelName: owner.name, hostName: owner.marker))
        } catch is LedmAuthRequiredError {
            return .needsPassword
        } catch let refusal as DeviceHttpError {
            return Self.busy(refusal.status) ? .notReached : .refused // busy: if it was added anyway, its marker finds it
        } catch is DeviceNetworkError {
            return .notReached // sent, maybe: the next check finds it by its marker
        }

        var path = LedmWalkupScan.ownPath(location, listPath)
        if path == nil {
            // No usable Location: the list says where it went.
            let (_, again, trouble) = try await readList()
            if trouble != nil { return .notReached }
            path = again.flatMap { Self.mine($0, owner) }
        }
        let found = path
        state.withLock { $0.path = found }
        return found == nil ? .refused : .listed
    }

    /// Takes this Mac off the list: one DELETE of this app's destination (found by its marker when the path isn't known),
    /// nothing else on the printer touched. True when it's gone or there was none; false when the printer didn't answer in
    /// time or refused.
    public func remove(_ owner: PanelOwner) async -> Bool {
        do {
            var path = self.path
            if path == nil {
                let (_, listed, problem) = try await readList()
                if let problem { return problem == .refused } // no list of that shape: nothing of ours to remove
                guard let listed, let mine = Self.mine(listed, owner) else { return true }
                path = mine
            }
            guard let path else { return true }
            try await ledm.delete(path: path)
            state.withLock { s in if s.path == path { s.path = nil } }
            return true
        } catch {
            return false // it stays on the list, and the next run finds it again by its marker
        }
    }

    /// Keeps this Mac on the list and tells each press of it, until the task is cancelled (it isn't removed then: `remove`
    /// does that). The first table the printer answered with is where it starts (an outage before it doesn't count): only
    /// events after it count, each once (`SeenEvents`). A press is told only when the event names this Mac's destination and
    /// the event document says scan (`LedmWalkupScan.isStart`). A check that got no answer is tried again after `retryDelay`;
    /// one refused (or wanting a password) waits until turned off and on (a new run); anything else going wrong ends in
    /// `.failed`, said, not a run left hanging.
    /// - Parameters:
    ///   - state: each check's outcome.
    ///   - pressed: a press of this Mac on the panel.
    public func run(_ owner: PanelOwner, state: @escaping @Sendable (PanelState) -> Void, pressed: @escaping @Sendable () -> Void) async {
        let inbox = TableInbox()
        let tables = ledm.events.subscribe()
        let forward = Task {
            for await table in tables { inbox.put(table) }
            inbox.end()
        }
        defer { forward.cancel() }
        var seen = SeenEvents()
        var started = false, check = true, stopped = false
        let clock = ContinuousClock()
        var checkedAt: ContinuousClock.Instant?
        while !Task.isCancelled {
            if !stopped && (check || checkedAt.map { clock.now - $0 > Self.recheck } ?? true) {
                let now: PanelState
                do {
                    now = try await ensureListed(owner)
                } catch is CancellationError {
                    return
                } catch {
                    now = .failed
                }
                if Task.isCancelled { return }
                state(now)
                checkedAt = clock.now
                check = now == .notReached
                stopped = now == .refused || now == .needsPassword || now == .failed
            }
            switch await inbox.take(timeout: check && !stopped ? retryDelay : nil) {
            case .timedOut:
                continue // time to try again, the EventTable quiet
            case .ended:
                return // cancelled, or the printer has no EventTable after all
            case .table(let table):
                if !table.answered {
                    check = true // back: look at the list again
                    continue
                }
                let fresh = seen.take(table.events, start: !started)
                started = true
                if fresh.contains(where: { $0.category == LedmWalkupScan.powerUpCategory }) { check = true } // a restarted printer forgets its list
                guard let own = path else { continue }
                for e in fresh where LedmWalkupScan.isPressFor(e, own) {
                    if let type = await readEvent(), LedmWalkupScan.isStart(type), !Task.isCancelled { pressed() }
                }
            }
        }
    }

    private func readList() async throws -> (XmlElement?, [WalkupDestination]?, PanelState?) {
        do {
            // The list went, or changed shape: nothing written on a guess.
            guard let list = try await ledm.get(path: listPath), let listed = LedmWalkupScan.read(list) else { return (nil, nil, .refused) }
            return (list, listed, nil)
        } catch where DeviceFailure.isOffline(error) || DeviceFailure.isTransient(error) {
            return (nil, nil, .notReached) // no answer, an error answer, an unreadable one: later
        }
    }

    private static func mine(_ listed: [WalkupDestination], _ owner: PanelOwner) -> String? {
        listed.last { $0.path != nil && same($0.hostname, owner.marker) }?.path
    }

    /// A refusal that may pass: busy, overloaded, a server error.
    private static func busy(_ status: Int) -> Bool { status == 408 || status == 409 || status == 429 || status >= 500 }

    private func readEvent() async -> String? {
        guard let doc = try? await ledm.get(path: eventPath) else { return nil }
        return LedmWalkupScan.eventType(doc)
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}

/// The EventTable entries already handled, by category and `AgingStamp`: a rolling window of at most `max` that never drops
/// an entry the printer's table still holds (those are touched on every table and evicted last), so an old event never comes
/// back as new.
struct SeenEvents {
    static let max = 256

    private var seen: [String: Int] = [:]
    private var clock = 0

    /// The table's events not seen before (none when `start`: they're the starting point); all of them are seen after.
    mutating func take(_ events: [LedmEvent], start: Bool) -> [LedmEvent] {
        var fresh: [LedmEvent] = []
        for e in events {
            guard let stamp = e.agingStamp else { continue }
            let key = e.category + "\n" + stamp
            if seen[key] == nil && !start { fresh.append(e) }
            clock += 1
            seen[key] = clock // the table's own entries are the newest
        }
        if seen.count > Self.max {
            for old in seen.sorted(by: { $0.value < $1.value }).prefix(seen.count - Self.max) { seen[old.key] = nil }
        }
        return fresh
    }

    var count: Int { seen.count }
}

/// The tables a run hasn't handled yet, waited for with a time limit (the Windows run's `Task.WhenAny(next, Task.Delay(…))`).
final class TableInbox: Sendable {
    enum Took: Sendable {
        case table(LedmEventTable)
        case ended
        case timedOut
    }

    private struct Waiter {
        var id: Int
        var continuation: CheckedContinuation<Took, Never>
        var timer: Task<Void, Never>?
    }

    private struct State {
        var queue: [LedmEventTable] = []
        var ended = false
        var waiter: Waiter?
        var next = 0
    }

    /// Tables kept while nobody takes them (the feed keeps the newest few too).
    private static let backlog = 16

    private let state = Mutex(State())

    func put(_ table: LedmEventTable) {
        let waiter: Waiter? = state.withLock { s in
            if let w = s.waiter {
                s.waiter = nil
                return w
            }
            s.queue.append(table)
            if s.queue.count > Self.backlog { s.queue.removeFirst() }
            return nil
        }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: .table(table))
    }

    func end() {
        let waiter: Waiter? = state.withLock { s in
            s.ended = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.timer?.cancel()
        waiter?.continuation.resume(returning: .ended)
    }

    /// The next table, `.ended` when none will come (or the task is cancelled), `.timedOut` after `timeout` without one.
    func take(timeout: Duration?) async -> Took {
        let id: Int = state.withLock { s in
            s.next += 1
            return s.next
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Took, Never>) in
                let now: Took? = state.withLock { s in
                    if !s.queue.isEmpty { return .table(s.queue.removeFirst()) }
                    if s.ended { return .ended }
                    s.waiter = Waiter(id: id, continuation: continuation, timer: nil)
                    return nil
                }
                if let now {
                    continuation.resume(returning: now)
                    return
                }
                if Task.isCancelled {
                    fire(id, .ended)
                    return
                }
                if let timeout {
                    let timer = Task { [weak self] in
                        guard (try? await Task.sleep(for: timeout)) != nil else { return }
                        self?.fire(id, .timedOut)
                    }
                    state.withLock { s in if s.waiter?.id == id { s.waiter?.timer = timer } }
                }
            }
        } onCancel: {
            fire(id, .ended)
        }
    }

    private func fire(_ id: Int, _ took: Took) {
        let waiter: Waiter? = state.withLock { s in
            guard s.waiter?.id == id else { return nil }
            defer { s.waiter = nil }
            return s.waiter
        }
        if case .timedOut = took {} else { waiter?.timer?.cancel() }
        waiter?.continuation.resume(returning: took)
    }
}
