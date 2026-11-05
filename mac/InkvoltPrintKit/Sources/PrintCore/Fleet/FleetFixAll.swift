import Foundation

/// How one repair of Fix all went (the Windows app's `FixAllKind`, without its permission prompt's: the sandbox has none).
public enum FixAllKind: Equatable, Sendable {
    case fixed
    /// The person said no: nothing was done.
    case declined
    /// macOS refused (not an administrator): `FixAllStep.steps` say how by hand.
    case manual
    case failed
    /// The queue went (renamed, removed) while the question was open: nothing was done.
    case gone
    /// Something else fixed it while the question was open: nothing was done.
    case alreadyFine
}

/// One line of Fix all's result. `queue` is the name Printers & Scanners shows.
public struct FixAllStep: Equatable, Sendable {
    public var queue: String
    public var title: String
    public var kind: FixAllKind
    public var message: String
    public var steps: [String] = []

    public init(_ queue: String, _ title: String, _ kind: FixAllKind, _ message: String, steps: [String] = []) {
        self.queue = queue
        self.title = title
        self.kind = kind
        self.message = message
        self.steps = steps
    }
}

/// What Fix all did, what it left to each printer's own fixer, and why it stopped early if it did.
public struct FixAllReport: Equatable, Sendable {
    public var steps: [FixAllStep]
    public var left: [String]
    /// No licence: nothing was looked at or done (the caller shows what Pro does).
    public var locked = false
    public var stopped: String?

    public init(_ steps: [FixAllStep], _ left: [String], locked: Bool = false, stopped: String? = nil) {
        self.steps = steps
        self.left = left
        self.locked = locked
        self.stopped = stopped
    }

    /// "Fixed 2, 1 you said no to, 1 to do by hand." for the page and VoiceOver.
    public var summary: String {
        if locked { return Pro.locked(.fleetExport) }
        if let stopped, steps.isEmpty { return stopped }
        if steps.isEmpty { return left.isEmpty ? "Every queue is fine: nothing to fix." : "No safe repair to make. What's left needs each printer's own Fix It…" }
        func count(_ kinds: FixAllKind...) -> Int { steps.filter { kinds.contains($0.kind) }.count }
        let parts: [(Int, String)] = [
            (count(.fixed), "Fixed %d"),
            (count(.declined), "%d you said no to"),
            (count(.manual), "%d to do by hand"),
            (count(.failed), "%d didn't work"),
            (count(.gone, .alreadyFine), "%d no longer needed"),
        ]
        let said = parts.filter { $0.0 > 0 }.map { $0.1.replacingOccurrences(of: "%d", with: String($0.0)) }.joined(separator: ", ")
        return said + "." + (stopped.map { " \($0)" } ?? "")
    }
}

/// What Fix all looks at for one printer: a queue printer's own CUPS queue by its name, or a network printer, whose own queues
/// are those known to be its (`FleetFixAll.own`).
public enum FixAllTarget: Equatable, Sendable {
    case queue(String)
    case network(OfflineDevice)
}

/// Fix all (Inkvolt Pro, the Windows app's `FleetFixAll`): the fixer's safe repairs over every printer's macOS queues, each
/// confirmed by name. Safe are Resume (a paused queue) and Accept Jobs (a queue that turns jobs away, what Windows' Use Printer
/// Offline comes to on a Mac): no network step and no change of address. A queue printer counts only its own queue, a network
/// printer only queues known to be its own (the UUID or its address in the device URI, its Bonjour service; never one that
/// merely has its model's name). cupsd's answers are waited for only so long. After each yes the queue is read again, since
/// the question may have been open for minutes: one that went or got fixed meanwhile is left alone. One refusal or failure
/// doesn't stop the rest. Cancelling stuck jobs and adding a printer again aren't safe: they're named in `FixAllReport.left`,
/// for the printer's own fixer.
public enum FleetFixAll {
    /// How long a read of cupsd's queues is waited for (the Windows app's `QueueReadLimit`).
    public static let readLimit: Duration = .seconds(10)

    static let noAnswer = "macOS's printing system didn't answer"
    static let stoppedText = "Stopped: the rest wasn't changed."

    public static func run(_ targets: [FixAllTarget], queues: any PrintQueues, control: any QueueControl,
                           confirm: @escaping @Sendable (Repair) async -> Bool, progress: (@Sendable (FixAllStep) -> Void)? = nil,
                           limit: Duration = readLimit) async -> FixAllReport {
        guard Pro.allows(.fleetExport) else { return FixAllReport([], [], locked: true) }
        // What's wrong, first: nothing is asked while the rest is still being read.
        guard let destinations = await read(queues, limit) else {
            return FixAllReport([], [], stopped: "\(noAnswer), so nothing was changed. Try again in a moment.")
        }
        var matched: [(target: FixAllTarget, queue: MatchedQueue)] = []
        var seen = Set<String>()
        for target in targets {
            for queue in own(target, destinations) where seen.insert(queue.queue.name.lowercased()).inserted { matched.append((target, queue)) }
        }
        let jobs = await jobs(matched.map(\.queue.queue.name), queues, limit)
        if Task.isCancelled { return FixAllReport([], [], stopped: stoppedText) }
        var safe: [Repair] = [], left: [String] = []
        for (i, m) in matched.enumerated() {
            var match = m.queue
            match.jobs = jobs[i]
            for repair in OfflineDiagnosis.plan(device(m.target), found: nil, reach: nil, queues: [match], user: queues.user) {
                if isSafe(repair) { safe.append(asked(repair, match.queue.displayName)) } else if !repair.isAlternative { left.append(shown(repair.title)) }
            }
        }

        var steps: [FixAllStep] = []
        for repair in safe {
            if Task.isCancelled { return FixAllReport(steps, left, stopped: stoppedText) }
            guard let step = await one(repair, queues, control, confirm, limit) else { return FixAllReport(steps, left, stopped: stoppedText) }
            steps.append(step)
            progress?(step)
        }
        return FixAllReport(steps, left)
    }

    /// Resume and Accept Jobs: what Fix all does itself.
    public static func isSafe(_ repair: Repair) -> Bool {
        !repair.manualOnly && (repair.kind == .resumeQueue || repair.kind == .acceptJobs)
    }

    /// The queues a target counts: a queue printer's by its name (CUPS names don't go by case), a network printer's own.
    static func own(_ target: FixAllTarget, _ destinations: [CupsDestination]) -> [MatchedQueue] {
        switch target {
        case .queue(let name):
            return destinations.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.prefix(1)
                .map { MatchedQueue(queue: $0, reason: .uuid, portIsStale: false) }
        case .network(let device):
            let uuid = CupsQueues.normalizedUuid(device.uuid)
            let hosts = ([device.host] + device.previousHosts).compactMap { $0 }.filter { !$0.isEmpty }
            return destinations.filter(CupsQueues.isRealQueue).compactMap { d in
                guard let reason = OfflineDiagnosis.reason(d, device, uuid: uuid, hosts: hosts), reason != .name else { return nil }
                return MatchedQueue(queue: d, reason: reason, portIsStale: false)
            }
        }
    }

    private static func device(_ target: FixAllTarget) -> OfflineDevice {
        switch target {
        case .queue(let name): OfflineDevice(uuid: CupsQueues.id(for: name), name: name, host: nil)
        case .network(let device): device
        }
    }

    /// A queue's name (`printer-info`, which a driverless printer fills itself) or a line holding it, cleaned and bounded as
    /// the page's text is (`FleetText`): it goes into a question and onto the page.
    static func shown(_ text: String) -> String { FleetText.clean(text, FleetPrinter.maxText) ?? "Printer with no name" }

    /// The question asked before a safe repair, by the printer's name.
    private static func asked(_ repair: Repair, _ name: String) -> Repair {
        let shown = Self.shown(name)
        var r = repair
        r.title = Self.shown(r.title)
        if r.kind == .resumeQueue {
            r.question = "Resume “\(shown)”? The jobs waiting in it start printing."
            r.confirm = "Resume"
        } else {
            r.question = "Let “\(shown)” accept print jobs again?"
            r.confirm = "Accept Jobs"
        }
        return r
    }

    /// One repair: asked, looked at again, done. Nil when stopped.
    private static func one(_ repair: Repair, _ queues: any PrintQueues, _ control: any QueueControl,
                            _ confirm: @Sendable (Repair) async -> Bool, _ limit: Duration) async -> FixAllStep? {
        let name = repair.queue ?? ""
        guard await confirm(repair) else { return Task.isCancelled ? nil : FixAllStep(name, repair.title, .declined, "You said no: not changed.") }
        if Task.isCancelled { return nil }
        guard let destinations = await read(queues, limit) else {
            return FixAllStep(name, repair.title, .failed, "Couldn't check it first, so it wasn't changed: \(noAnswer).")
        }
        if Task.isCancelled { return nil }
        guard let now = destinations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return FixAllStep(name, repair.title, .gone, "macOS no longer has this printer: nothing changed.")
        }
        let fine = repair.kind == .resumeQueue ? now.state != 5 : now.isAcceptingJobs
        if fine { return FixAllStep(name, repair.title, .alreadyFine, "Already fixed: nothing more to do.") }
        let outcome = await RepairRunner.run(repair, queues: queues, control: control)
        let kind: FixAllKind = switch outcome.kind {
        case .fixed: .fixed
        case .manual: .manual
        case .failed: .failed
        }
        return FixAllStep(name, repair.title, kind, outcome.message, steps: outcome.steps)
    }

    /// Each queue's jobs, in `names`' order, read at the same time (none when its read fails or doesn't answer in `limit`):
    /// queues whose jobs don't answer cost one limit before the first question, not one each.
    private static func jobs(_ names: [String], _ queues: any PrintQueues, _ limit: Duration) async -> [[QueueJob]] {
        await withTaskGroup(of: (Int, [QueueJob]).self) { group in
            for (i, name) in names.enumerated() {
                group.addTask { (i, await FleetReader.race(limit, timedOut: { nil }) { await queues.jobs(name) } ?? []) }
            }
            var all = [[QueueJob]](repeating: [], count: names.count)
            for await (i, jobs) in group { all[i] = jobs }
            return all
        }
    }

    /// cupsd's queues, or nil when it doesn't answer in `limit`.
    private static func read(_ queues: any PrintQueues, _ limit: Duration) async -> [CupsDestination]? {
        await FleetReader.race(limit, timedOut: { nil }) { await queues.destinations() }
    }
}
