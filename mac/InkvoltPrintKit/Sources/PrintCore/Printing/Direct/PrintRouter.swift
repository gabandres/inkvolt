import Foundation
import Synchronization

/// One decision of where a printer's jobs go (`PrintRoutes.choose`), with what it was made from: the macOS queue found (nil:
/// none) and the printer's IPP client when it takes a raster format (nil: it doesn't, or isn't connected). `queueBroken`: the
/// queue can't print (macOS lost it, or stopped it when its driver failed: `PrintRoutes.queueWorks`), so the jobs go straight
/// to the printer though the person didn't choose that. Windows' `RouteChoice`, where a broken queue is one whose driver
/// Windows can't load; on the Mac, one cupsd stopped because its filter or driver failed.
public struct RouteChoice: Sendable {
    public var route: PrintRoute
    public var queue: String?
    public var ipp: IppClient?
    public var queueBroken: Bool

    public init(_ route: PrintRoute, _ queue: String?, _ ipp: IppClient?, queueBroken: Bool = false) {
        (self.route, self.queue, self.ipp, self.queueBroken) = (route, queue, ipp, queueBroken)
    }

    public static let none = RouteChoice(.none, nil, nil)
}

extension PrintRoutes {
    /// Whether macOS can print through a queue (the Mac's counterpart of Windows' `QueueDriver`, a driver Windows can load):
    /// false when macOS no longer lists it (nil), or cupsd stopped it (`printer-state` 5) because its driver failed: a filter
    /// missing or failing (`cups-missing-filter`, `cups-filter-failed`, a "Filter failed" message), its PPD gone. A queue
    /// someone paused in Printers & Scanners or set to reject jobs (`cupsreject`) works: they did that on purpose, its jobs
    /// wait there as on Windows, and printing around it would print what someone tried to hold.
    public static func queueWorks(_ destination: CupsDestination?) -> Bool {
        guard let d = destination else { return false }
        guard d.state == 5 else { return true }
        let failed = ["cups-missing-filter", "cups-filter-failed", "cups-insecure-filter"]
        if d.reasons.contains(where: { r in failed.contains { r == $0 || r.hasPrefix($0 + "-") } }) { return false }
        let said = (d.options["printer-state-message"] ?? "").lowercased()
        return !["filter failed", "missing filter", "unable to open ppd"].contains { said.contains($0) }
    }
}

/// The one place a printer's route is decided and remembered (roadmap 2.1, Windows' `PrintRouter`). Every print (Print a PDF,
/// Copy, Photos, Batch print, a scan preset's print step) decides afresh with `choose`, looking the macOS queue up again; job
/// alerts, asked every minute, follow the last decision (`forWatching`), deciding once when none was made yet, so they watch
/// where the jobs went. The app also decides when what it's made from changes (a connection, a queue set up or removed, the
/// person's choice), so the last decision stays current. `queueWorks` (nil: taken as yes) is asked only when the jobs would go
/// to the queue and the printer takes them straight too: a queue macOS can't use then gives way to the printer.
/// Mac difference: the lookups are async closures (the app reads its printers on the main actor), the person's choice a
/// synchronous one.
public final class PrintRouter: Sendable {
    private let findQueue: @Sendable () async throws -> String?
    private let rasterIpp: @Sendable () async -> IppClient?
    private let personChoseDirect: @Sendable () -> Bool
    private let queueWorks: (@Sendable (String) async -> Bool)?
    private let last = Mutex<RouteChoice?>(nil)

    public init(findQueue: @escaping @Sendable () async throws -> String?, rasterIpp: @escaping @Sendable () async -> IppClient?,
                personChoseDirect: @escaping @Sendable () -> Bool, queueWorks: (@Sendable (String) async -> Bool)? = nil) {
        (self.findQueue, self.rasterIpp, self.personChoseDirect, self.queueWorks) = (findQueue, rasterIpp, personChoseDirect, queueWorks)
    }

    /// The last decision; nil before the first.
    public var lastChoice: RouteChoice? { last.withLock { $0 } }

    /// Decides now: the macOS queue is looked up, the connection and the person's choice read. Throws what the lookup threw.
    public func choose() async throws -> RouteChoice {
        let queue = try await findQueue()
        let ipp = await rasterIpp()
        let route = PrintRoutes.choose(hasQueue: queue != nil, printerTakesRaster: ipp != nil, personChoseDirect: personChoseDirect())
        var broken = false
        if route == .queue, ipp != nil, let queueWorks, let queue { broken = !(await queueWorks(queue)) }
        let choice = RouteChoice(broken ? .direct : route, queue, ipp, queueBroken: broken)
        last.withLock { $0 = choice }
        return choice
    }

    /// The last decision, without looking the queue up again; decided now if there was none. Straight to the printer, the
    /// connection's current client when there is one (a reconnect makes a new one).
    public func forWatching() async throws -> RouteChoice {
        var choice: RouteChoice
        if let kept = lastChoice { choice = kept } else { choice = try await choose() }
        if choice.route == .direct, let now = await rasterIpp(), now !== choice.ipp { choice.ipp = now }
        return choice
    }
}

/// A printer's batch jobs where its other prints go: its macOS queue, or straight to the printer (`DirectBatchQueue`, made by
/// `direct` for the client chosen) as `router` decides for each call. What the batch asks between calls (`noAnswer`, the
/// limits) follows the queue chosen last: the runner asks whether the printer is ready (`problem`) just before each file.
public final class RoutedBatchQueue: BatchQueue {
    private let queue: any BatchQueue
    private let router: PrintRouter
    private let direct: @Sendable (IppClient) -> any BatchQueue
    private let chosen = Mutex<(any BatchQueue)?>(nil)

    public init(_ queue: any BatchQueue, router: PrintRouter, direct: @escaping @Sendable (IppClient) -> any BatchQueue) {
        (self.queue, self.router, self.direct) = (queue, router, direct)
    }

    private var current: any BatchQueue { chosen.withLock { $0 } ?? queue }

    private func route() async throws -> any BatchQueue {
        let choice = try await router.choose()
        let next: any BatchQueue = if choice.route == .direct, let ipp = choice.ipp { direct(ipp) } else { queue }
        chosen.withLock { $0 = next }
        return next
    }

    public func read() async throws -> BatchQueueInfo? { try await route().read() }

    public func problem() async throws -> String? { try await route().problem() }

    public func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?,
                     onSpooling: @escaping @Sendable () -> Void, _ stop: BatchStop) async throws -> BatchReceipt {
        try await route().send(document, job, progress: progress, onSpooling: onSpooling, stop)
    }

    public var noAnswer: String { current.noAnswer }

    public func sendLimit(_ job: BatchPrintJob, _ options: BatchPrintOptions) -> Duration { current.sendLimit(job, options) }

    public var endsOnItsOwnOnceSpooling: Bool { current.endsOnItsOwnOnceSpooling }
}

/// Job alerts for a printer that may print without its macOS queue: while its jobs go straight (the last route chosen,
/// `PrintRouter.forWatching`), the printer's own job list (`DirectJobWatch`); else the macOS queue's (`queue`). Never both: a
/// queue for an IPP printer lists macOS's jobs, and the printer lists them too under its own ids, so each would be told twice.
public final class RoutedJobQueue: Sendable {
    private let queue: @Sendable () async throws -> JobQueueState?
    private let router: PrintRouter
    private let user: String
    public let watch: DirectJobWatch

    public init(_ queue: @escaping @Sendable () async throws -> JobQueueState?, router: PrintRouter, user: String, watch: DirectJobWatch = DirectJobWatch()) {
        (self.queue, self.router, self.user, self.watch) = (queue, router, user, watch)
    }

    /// The queue now, or nil when the printer has none. Throws when it couldn't be read.
    public func read() async throws -> JobQueueState? {
        let choice = try await router.forWatching()
        if choice.route == .direct, let ipp = choice.ipp { return try await watch.read(ipp, user: user) }
        return try await queue()
    }
}
