import Foundation
import PrintCore
import PrintMac

/// A network printer's print routing in the app (roadmap 2.1, Windows' PrinterViewModel and MainViewModel parts): the routing
/// made from this printer (its macOS queue as the printer list last claimed it, its connection's IPP when that lists a raster
/// format, the person's choice kept in the state file, whether macOS can use its queue), what the Print menu shows of it, and
/// where each kind of print and job alerts go. Every print asks the router afresh (`directRoute`).
extension PrinterModel {
    func makeRouting() -> PrintRouting? {
        guard isNetwork else { return nil }
        let id = self.id, store = self.store
        let routing = PrintRouting(
            findQueue: { [weak self] in await self?.queueName },
            rasterIpp: { [weak self] in await self?.rasterIpp() },
            hasAddress: true, choseDirect: store.printsDirect(id),
            rememberChoice: { store.setPrintsDirect(id, $0) },
            log: { NSLog("%@", $0) },
            queueWorks: { [weak self] name in await self?.queueWorks(name) ?? true })
        routing.listen { [weak self, weak routing] in
            guard let self, let routing else { return }
            route = routing.route
            routeNote = routing.note
            canChooseDirect = routing.canChooseDirect
            choseDirect = routing.choseDirect
        }
        return routing
    }

    /// The printer's IPP client when it takes a raster format over IPP (PWG, Apple raster or PCLm); nil when it isn't
    /// connected or doesn't.
    func rasterIpp() async -> IppClient? {
        guard let connection = await connection(), let ipp = connection.ipp else { return nil }
        return IppPrintCaps.formatsIn(connection.probe.ipp?.strs("document-format-supported") ?? []).isEmpty ? nil : ipp
    }

    /// Whether macOS can take a job on `queue` now, as the last read of the queues says (`PrintRoutes.queueWorks`).
    func queueWorks(_ queue: String) -> Bool {
        PrintRoutes.queueWorks(app.destinations?.first { $0.name.caseInsensitiveCompare(queue) == .orderedSame })
    }

    /// The printer list claimed `own` as its macOS queue (or none): the routing is told, and decides again when the queue
    /// started or stopped taking jobs.
    func claimed(queue own: String?) {
        if own != queueName { queueName = own }
        guard let routing else { return }
        routing.queueLookedUp(found: own != nil)
        let works = own.map(queueWorks)
        if works != queueWorked {
            let before = queueWorked
            queueWorked = works
            if before != nil || works == false { routing.decide() }
        }
    }

    /// Straight to the printer for this print, or the macOS queue: the router decides now. The IPP client when straight.
    func directRoute() async -> IppClient? {
        guard let routing, let choice = try? await routing.router.choose() else { return nil }
        return choice.route == .direct ? choice.ipp : nil
    }

    /// The person's choice from the Print menu.
    func chooseDirect(_ direct: Bool) { routing?.chooseDirect(direct) }

    /// Where Batch print, two-sided by hand and a booklet by hand send this printer's jobs: its macOS queue (demo mode's
    /// made-up ones), or straight to the printer as the router decides for each file (`RoutedBatchQueue`); nil when it has
    /// neither a queue nor a network connection.
    func batchQueue() -> (any BatchQueue)? {
        var named: (any BatchQueue)?
        if let queue = queueName { named = app.isDemo ? DemoBatchQueue.named(queue) : CupsBatchQueue(queue: queue) }
        guard let routing else { return named }
        let name = self.name, caps = directCaps, user = DirectPrinting.user
        return RoutedBatchQueue(named ?? NoBatchQueue(), router: routing.router) { ipp in
            let cache = caps.cache(for: ipp)
            return DirectBatchQueue(name, ipp: ipp, caps: cache, send: DirectBatchJobs.send(ipp, caps: cache, user: user))
        }
    }

    /// Job alerts' read of this printer while its jobs go straight: the printer's own job list (`RoutedJobQueue`), else the
    /// queue's as `macOS` reads it. Nil for a printer without routing.
    func jobQueue(_ macOS: @escaping @Sendable () async throws -> JobQueueState?) -> RoutedJobQueue? {
        routing.map { RoutedJobQueue(macOS, router: $0.router, user: DirectPrinting.user, watch: jobWatch) }
    }
}

/// A printer with no macOS queue: nothing to print through but the printer itself.
struct NoBatchQueue: BatchQueue {
    func read() async throws -> BatchQueueInfo? { nil }
    func problem() async throws -> String? { String(localized: "This printer has no macOS print queue to print through.") }
    func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?, onSpooling: @escaping @Sendable () -> Void,
              _ stop: BatchStop) async throws -> BatchReceipt {
        throw BatchQueueError(String(localized: "This printer has no macOS print queue to print through."), mayHaveSent: false)
    }
}
