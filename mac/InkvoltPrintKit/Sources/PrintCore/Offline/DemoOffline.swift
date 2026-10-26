import Foundation

/// The offline fixer's view of demo mode's made-up Mac (the Windows app's `DemoOfflinePc`): `Demo`'s print queues plus one
/// for the office laser, and a network where the demo printers answer at their addresses. The office laser moved from
/// `Demo.officeOldHost` to `Demo.officeNewHost`; its queue still prints to the old address over a raw socket, is paused and
/// holds a stuck job of the user's. Repairs change only this made-up state, so the whole flow can be tried and snapshotted
/// without reading or touching this Mac's real queues.
public final class DemoOffline: OfflineProbes, QueueControl, QueueSetupControl, PrintQueues {
    /// The office laser's queue.
    public static let officeQueue = "Demo_office_laser"

    public let user: String
    private let base: FixedQueues
    private let delay: Duration
    /// The demo printers that are where Inkvolt Print remembers them: UUID → address.
    private let online: [String: String]
    private let office: Shared<CupsDestination>
    private let officeJobs: Shared<[QueueJob]>
    /// Queues "Set up in macOS" added.
    private let added = Shared<[CupsDestination]>([])

    /// `delay`: how long a Bonjour look-up takes (a reachability check half that), so the checks show as they run.
    public init(now: Date = Date(), delay: Duration = .milliseconds(700)) {
        base = Demo.queues(now: now)
        user = base.user
        self.delay = delay
        online = [Demo.uuid: FixtureTransport.demoHost, Demo.inkjetUuid: Demo.inkjetHost, Demo.cdmUuid: Demo.cdmHost]
        office = Shared(CupsDestination(name: Self.officeQueue, options: [
            "printer-info": "Demo office laser", "device-uri": "socket://\(Demo.officeOldHost)", "printer-make-and-model": "Demo office laser",
            "printer-type": "4", "printer-state": "5", "printer-state-reasons": "paused,offline-report", "printer-is-accepting-jobs": "true",
        ]))
        officeJobs = Shared([QueueJob(id: 21, name: "Invoice 1043.pdf", pages: 2, state: .stopped, submitted: now.addingTimeInterval(-14 * 60), owner: base.user)])
    }

    // MARK: OfflineProbes

    public func rediscover(_ uuid: String) async throws -> Rediscovery? {
        try await pause(delay)
        let id = uuid.lowercased()
        if id == Demo.officeUuid { return Rediscovery(Demo.officeNewHost, hostName: "officelaser-demo.local") }
        return online[id].map { Rediscovery($0) }
    }

    public func reach(_ host: String) async throws -> Reachability {
        try await pause(delay / 2)
        let answers = host == Demo.officeNewHost || online.values.contains(host)
        return Reachability(host, openPorts: answers ? [631, 9100, 80] : [])
    }

    // MARK: PrintQueues

    public func destinations() async -> [CupsDestination]? {
        var office = office.withLock { $0 }
        office.jobs = officeJobs.withLock { $0.count }
        return (await base.destinations() ?? []) + [office] + added.withLock { $0 }
    }

    public func jobs(_ queue: String) async -> [QueueJob]? {
        isOffice(queue) ? officeJobs.withLock { $0 } : await base.jobs(queue)
    }

    public func cancel(_ queue: String, job: Int) async throws {
        guard isOffice(queue) else { return try await base.cancel(queue, job: job) }
        let user = user
        let refused: PrintJobCancelError? = officeJobs.withLock { jobs in
            guard let i = jobs.firstIndex(where: { $0.id == job }) else { return PrintJobCancelError("It has already finished.") }
            guard QueueJobText.isOwner(jobs[i].owner, user) else { return PrintJobCancelError("Only an administrator can cancel someone else's job.") }
            jobs.remove(at: i)
            return nil
        }
        if let refused { throw refused }
    }

    // MARK: QueueControl

    public func resume(_ queue: String) async throws {
        try await pause(delay / 2)
        guard isOffice(queue) else { return }
        office.withLock { d in
            d.options["printer-state"] = "3"
            d.options["printer-state-reasons"] = d.reasons.filter { $0 != "paused" }.joined(separator: ",")
        }
    }

    public func acceptJobs(_ queue: String) async throws {
        try await pause(delay / 2)
        guard isOffice(queue) else { return }
        office.withLock { $0.options["printer-is-accepting-jobs"] = "true" }
    }

    // MARK: QueueSetupControl

    /// Adds the queue at once (made up: nothing on this Mac changes), after the moment cupsd takes to read a printer.
    public func addQueue(_ plan: QueueSetupPlan) async throws {
        try await pause(delay * 2)
        added.withLock { list in
            guard !list.contains(where: { $0.name.caseInsensitiveCompare(plan.queueName) == .orderedSame }) else { return }
            list.append(CupsDestination(name: plan.queueName, options: [
                "printer-info": plan.info, "device-uri": plan.deviceUri, "printer-make-and-model": plan.info, "printer-type": "4",
                "printer-state": "3", "printer-is-accepting-jobs": "true",
            ]))
        }
    }

    public func setDeviceUri(_ queue: String, _ uri: String) async throws {
        try await pause(delay / 2)
        guard isOffice(queue) else { return }
        office.withLock { d in
            d.options["device-uri"] = uri
            // cupsd reaches the printer at its new address: its "offline" goes.
            d.options["printer-state-reasons"] = d.reasons.filter { $0 != "offline-report" }.joined(separator: ",")
        }
    }

    private func isOffice(_ queue: String) -> Bool { queue.caseInsensitiveCompare(Self.officeQueue) == .orderedSame }

    private func pause(_ d: Duration) async throws {
        if d > .zero { try await Task.sleep(for: d) }
    }
}
