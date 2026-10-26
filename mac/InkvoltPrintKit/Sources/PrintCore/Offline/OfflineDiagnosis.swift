import Foundation

/// Everything the fixer found, and what it can repair.
public struct OfflineReport: Equatable, Sendable {
    public var device: OfflineDevice
    public var found: Rediscovery?
    public var reach: Reachability?
    public var checks: [CheckResult]
    public var queues: [MatchedQueue]
    public var repairs: [Repair]
    /// The printer moved, but something still answers at the address Inkvolt Print had (another device took it, or this
    /// isn't the printer that moved).
    public var oldAddressAnswers: Bool

    /// Bonjour found the printer at a different address than the one Inkvolt Print had.
    public var moved: Bool { found.map { !IpText.same($0.address, device.host) } ?? false }

    /// What to do with the new address: nothing (it didn't move), use it, or ask first. The UUID Bonjour answered for is
    /// public, so when more than one device announces it, or the old address still answers, the user decides.
    public var adoption: AdoptDecision {
        guard moved, let found else { return .none }
        return found.isAmbiguous || oldAddressAnswers ? .ask : .adopt
    }

    /// The question for `.ask`.
    public var adoptionQuestion: String? {
        guard adoption == .ask, let found else { return nil }
        return "\(OfflineDiagnosis.caution(device, found, oldAddressAnswers))Use \(found.address) for \(device.name)? Choose this only if that's the "
            + "printer's address (its control panel or a network configuration page shows it)."
    }

    public var answers: Bool { reach?.answers == true }

    public var headline: String {
        let n = repairs.count(where: { !$0.isAlternative })
        if n > 0 { return "Found \(n == 1 ? "one thing" : "\(n) things") to fix" }
        if !answers { return "The printer isn't answering" }
        if queues.isEmpty { return "The printer answers, but this Mac has no printer for it" }
        return "No problems found"
    }

    public var advice: String {
        if !repairs.isEmpty && answers { return "Fix each one below, then check again." }
        if !repairs.isEmpty {
            return "Fix what's listed below. The printer itself isn't answering yet: check that it's on and connected to the same network as this Mac."
        }
        if !answers {
            return "Check that it's switched on and awake, and connected to the same Wi-Fi or network as this Mac (its control panel or a "
                + "network configuration page shows its address). Turning the printer off and on, then the router, fixes most of these."
        }
        if queues.isEmpty {
            return "Add it in System Settings › Printers & Scanners (Add Printer, Scanner, or Fax…) so every app lists it."
        }
        return "The printer answers and macOS's printer for it is ready. If a job still won't print, turn the printer off and on, then try again."
    }
}

public enum AdoptDecision: Equatable, Sendable { case none, adopt, ask }

/// The "printer offline" fixer's diagnosis on the Mac, step by step: a fresh Bonjour look-up by UUID (DHCP often hands the
/// printer a new address); whether it answers there; which macOS print queues print to it and where their device URIs
/// point; whether those queues are paused, not accepting jobs or hold stuck jobs. Each step is reported as it starts and
/// ends, then the repairs are planned from what was found (`plan`). No Print Spooler step: cupsd starts on demand, and not
/// answering shows as the queues not being readable.
public enum OfflineDiagnosis {
    public static func run(_ device: OfflineDevice, probes: any OfflineProbes, queues: any PrintQueues,
                           progress: (@Sendable (CheckResult) -> Void)? = nil) async throws -> OfflineReport {
        var checks: [CheckKind: CheckResult] = [:]
        func report(_ r: CheckResult) {
            checks[r.kind] = r
            progress?(r)
        }
        func start(_ kind: CheckKind) { report(CheckResult(kind, .running)) }

        // 1. Where is it now? Bonjour by UUID, since the router may have given it a new address.
        start(.network)
        var found: Rediscovery?
        var lookupError: String?
        do { found = try await probes.rediscover(device.uuid)?.cleaned() } catch is CancellationError where Task.isCancelled {
            throw CancellationError()
        } catch { lookupError = message(error) }
        // Moved: does anything still answer at the old address? Then the new one isn't used without asking.
        var oldAnswers = false
        if let found, let oldHost = device.host, !IpText.same(found.address, oldHost) {
            oldAnswers = try await probe({ try await probes.reach(oldHost) }, fallback: Reachability(oldHost)).answers
        }
        report(networkCheck(device, found, oldAnswers, lookupError))

        // 2. Does it answer there?
        let address = found?.address ?? device.host
        var reach: Reachability?
        if let address {
            start(.connection)
            let r = try await probe({ try await probes.reach(address) }, fallback: Reachability(address))
            reach = r
            report(connectionCheck(r))
        } else {
            report(CheckResult(.connection, .skipped, "Its address isn't known."))
        }

        // 3 and 4. macOS's queues for it, and their state.
        try Task.checkCancellation()
        start(.queues)
        var matched: [MatchedQueue] = []
        if let destinations = await queues.destinations() {
            matched = try await match(device, found: found, address: address, destinations: destinations, probes: probes)
            for i in matched.indices { matched[i].jobs = await queues.jobs(matched[i].queue.name) ?? [] }
            report(queuesCheck(matched))
            start(.queueState)
            report(queueStateCheck(matched, user: queues.user))
        } else {
            report(CheckResult(.queues, .warning, "Couldn't read this Mac's printers: macOS's printing system didn't answer."))
            report(CheckResult(.queueState, .skipped))
        }

        let caution = caution(device, found, oldAnswers)
        let repairs = plan(device, found: found, reach: reach, queues: matched, user: queues.user, caution: caution.isEmpty ? nil : caution)
        return OfflineReport(device: device, found: found, reach: reach, checks: CheckKind.allCases.map { checks[$0] ?? .waiting($0) },
                             queues: matched, repairs: repairs, oldAddressAnswers: oldAnswers)
    }

    /// Why the new address isn't certain ("" when it is), as the start of a question.
    static func caution(_ device: OfflineDevice, _ found: Rediscovery?, _ oldAnswers: Bool) -> String {
        guard let found else { return "" }
        var parts = ""
        if found.isAmbiguous { parts += "More than one device announces this printer's ID: \(Reachability.join(Rediscovery.distinct(found.addresses))). " }
        if oldAnswers, let old = device.host { parts += "Something still answers at its old address, \(old). " }
        return parts
    }

    private static func probe<T: Sendable>(_ body: () async throws -> T, fallback: T) async throws -> T {
        do { return try await body() } catch is CancellationError where Task.isCancelled { throw CancellationError() } catch { return fallback }
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private static func networkCheck(_ device: OfflineDevice, _ found: Rediscovery?, _ oldAnswers: Bool, _ error: String?) -> CheckResult {
        guard let found else {
            return CheckResult(.network, .warning, error.map { "Couldn't look for it: \($0)" }
                ?? "It didn't announce itself on the network. It may be off or asleep, on another network, or not announce itself at all.")
        }
        guard let old = device.host, !IpText.same(found.address, old) else {
            return CheckResult(.network, .passed, "Found at \(found.address), the address Inkvolt Print uses.")
        }
        let caution = caution(device, found, oldAnswers)
        if !caution.isEmpty {
            return CheckResult(.network, .warning, "Found at \(found.address) (it was \(old)). \(caution)Inkvolt Print asks before using the new address.")
        }
        return CheckResult(.network, .warning,
                           "Found at a new address, \(found.address) (it was \(old)). The router gave it a new one; Inkvolt Print uses the new address now.")
    }

    private static func connectionCheck(_ r: Reachability) -> CheckResult {
        if r.answers { return CheckResult(.connection, .passed, "Answers at \(r.host): \(r.portsText).") }
        return CheckResult(.connection, .failed, "No answer at \(r.host). Check that it's switched on and awake, and on the same network as this Mac.")
    }

    private static func queuesCheck(_ matched: [MatchedQueue]) -> CheckResult {
        if matched.isEmpty { return CheckResult(.queues, .warning, "None: this Mac has no printer for this device yet.") }
        let lines = matched.map { m in
            "“\(m.queue.displayName)”: \(m.portText)" + (m.portIsStale ? ", an old address" : "") + (m.reason == .name ? " (matched by its name)" : "")
        }
        return CheckResult(.queues, matched.contains(where: \.portIsStale) ? .failed : .passed, lines.joined(separator: "\n"))
    }

    private static func queueStateCheck(_ matched: [MatchedQueue], user: String) -> CheckResult {
        if matched.isEmpty { return CheckResult(.queueState, .skipped, "No macOS printer to check.") }
        var lines: [String] = []
        var failed = false
        for m in matched {
            var problems: [String] = []
            if m.isPaused { problems.append("paused") }
            if !m.queue.isAcceptingJobs { problems.append("not accepting jobs") }
            let stuck = stuckJobs(m).count
            if stuck > 0 { problems.append(stuck == 1 ? "1 stuck job" : "\(stuck) stuck jobs") }
            failed = failed || !problems.isEmpty
            let reading = CupsStatus.describe(m.queue)
            if reading.offline { problems.append("macOS shows it offline") } else if reading.status.severity == .error { problems.append("macOS shows an error") }
            if !problems.isEmpty { lines.append("“\(m.queue.displayName)”: \(Reachability.join(problems)).") }
        }
        if lines.isEmpty { return CheckResult(.queueState, .passed, "Not paused or offline, no stuck jobs.") }
        return CheckResult(.queueState, failed ? .failed : .warning, lines.joined(separator: "\n"))
    }

    // MARK: Matching

    /// The queues that print to this printer, in order of certainty: the UUID in the device URI is the printer's; the
    /// URI's host is one of the printer's addresses (current, new or earlier) or its Bonjour host name; the URI names its
    /// Bonjour service; finally a fixed-address queue whose name starts with the printer's model or name, unless something
    /// answers where it points (then it's another printer of the same model). Bonjour's temporary destinations and virtual
    /// printers are left out.
    static func match(_ device: OfflineDevice, found: Rediscovery?, address: String?, destinations: [CupsDestination],
                      probes: any OfflineProbes) async throws -> [MatchedQueue] {
        let uuid = CupsQueues.normalizedUuid(device.uuid)
        let hosts = ([device.host, found?.address, found?.hostName] + device.previousHosts).compactMap { $0 }.filter { !$0.isEmpty }
        var result: [MatchedQueue] = []
        for d in destinations where CupsQueues.isRealQueue(d) {
            let uri = d.deviceUri ?? ""
            let host = fixedHost(uri)
            let names = [d.displayName, d.name.replacingOccurrences(of: "_", with: " ")]
            let reason: MatchReason? =
                if let uuid, CupsQueues.uuidIn(uri) == uuid { .uuid }
                else if let h = CupsQueues.host(uri), hosts.contains(where: { IpText.same($0, h) }) { .address }
                else if let instance = CupsQueues.serviceInstance(uri), instance.caseInsensitiveCompare(device.name) == .orderedSame { .service }
                else if host != nil, names.contains(where: { startsWithWord($0, device.model) || startsWithWord($0, device.name) }) { .name }
                else { nil }
            guard let reason else { continue }
            let stale = isStale(uri, address: address, hostName: found?.hostName)
            if reason == .name, stale, let host {
                // Same model name, another address: only ours if nothing answers there.
                if try await probe({ try await probes.reach(host) }, fallback: Reachability(host)).answers { continue }
            }
            result.append(MatchedQueue(queue: d, reason: reason, portIsStale: stale))
        }
        return result
    }

    /// The device URI's fixed host: a socket, LPD or IPP queue set up by address or name, not by Bonjour service.
    static func fixedHost(_ uri: String) -> String? {
        guard let scheme = CupsQueues.scheme(uri), ["socket", "lpd", "ipp", "ipps", "http", "https"].contains(scheme),
              CupsQueues.serviceInstance(uri) == nil else { return nil }
        return CupsQueues.host(uri)
    }

    /// The queue's fixed address points somewhere other than where the printer is now. A DNS name other than the
    /// printer's own may well follow the printer: only addresses are known to be stale.
    static func isStale(_ uri: String, address: String?, hostName: String?) -> Bool {
        guard let address, let host = fixedHost(uri) else { return false }
        if IpText.same(host, address) || IpText.same(host, hostName) { return false }
        return IpText.isAddress(host)
    }

    /// Jobs that need the user, not patience: stopped or aborted (`QueueJobText.isProblem`).
    static func stuckJobs(_ m: MatchedQueue) -> [QueueJob] { m.jobs.filter { QueueJobText.isProblem($0.state) } }

    // MARK: Plan

    /// What can be repaired, in the order to do it: each queue's state, its address, then its jobs.
    /// - Parameter caution: why the new address isn't certain (two devices announce the UUID, the old address still
    ///   answers): put in front of every hand-off that names it.
    public static func plan(_ device: OfflineDevice, found: Rediscovery?, reach: Reachability?, queues: [MatchedQueue], user: String,
                            caution: String? = nil) -> [Repair] {
        var list: [Repair] = []
        let answers = reach?.answers == true
        // Bonjour seeing it is good evidence on its own (a sleeping printer may not accept connections for a moment).
        let target = found?.address ?? (answers ? reach?.host : nil)
        for m in queues {
            let q = m.queue
            let shown = q.displayName
            if m.isPaused {
                list.append(Repair(.resumeQueue, "Resume “\(shown)”", "Printing is paused in macOS, so jobs wait in the queue.", queue: q.name,
                                   manualSteps: ManualSteps.for(.resumeQueue, queue: shown)))
            }
            if !q.isAcceptingJobs {
                list.append(Repair(.acceptJobs, "Let “\(shown)” accept jobs again", "macOS turns new print jobs away for this printer.",
                                   queue: q.name, manualSteps: ManualSteps.for(.acceptJobs, queue: shown)))
            }

            if m.portIsStale, let target {
                pointAt(&list, m, target, found?.hostName, caution)
            } else if !m.portIsStale, answers, !m.isPaused, CupsStatus.describe(q).offline {
                // It answers, the address is right, yet macOS says offline.
                list.append(Repair(.addAgain, "Add “\(shown)” again",
                                   "The printer answers, but macOS still shows it offline. Removing it and adding it again makes macOS find it afresh.",
                                   queue: q.name, manualOnly: true, manualSteps: ManualSteps.for(.addAgain, queue: shown)))
            }

            let stuck = stuckJobs(m)
            let mine = stuck.filter { QueueJobText.isOwner($0.owner, user) }
            if !mine.isEmpty {
                let names = mine.prefix(3).map { "“\($0.name)”" }.joined(separator: ", ")
                let what = mine.count == 1 ? "“\(mine[0].name)”" : "\(mine.count) jobs (\(names)\(mine.count > 3 ? "…" : ""))"
                list.append(Repair(.cancelStuckJobs, mine.count == 1 ? "Cancel the stuck job in “\(shown)”" : "Cancel \(mine.count) stuck jobs in “\(shown)”",
                                   mine.count == 1 ? "\(capital(what)) is stuck and holds up everything after it." : "\(capital(what)) are stuck and hold up everything after them.",
                                   queue: q.name, jobIds: mine.map(\.id), question: "Cancel \(what)? \(mine.count == 1 ? "It" : "They") won't print.",
                                   confirm: mine.count == 1 ? "Cancel job" : "Cancel jobs", manualSteps: ManualSteps.for(.cancelStuckJobs, queue: shown)))
            }
            let others = stuck.count - mine.count
            if others > 0 {
                list.append(Repair(.cancelOthersJobs, "Cancel other people's stuck jobs in “\(shown)”",
                                   "\(others == 1 ? "1 job" : "\(others) jobs") from someone else on this Mac \(others == 1 ? "is" : "are") stuck. Only an administrator can cancel \(others == 1 ? "it" : "them").",
                                   queue: q.name, jobIds: stuck.filter { !QueueJobText.isOwner($0.owner, user) }.map(\.id), manualOnly: true,
                                   manualSteps: ManualSteps.for(.cancelOthersJobs, queue: shown)))
            }
        }
        return list
    }

    /// The queue is pointed at the printer's address (or its Bonjour host name, which follows it); refused (not an
    /// administrator), the steps remove it and add it again there. The address came from the network, so a doubt about it
    /// comes first, in the question too.
    private static func pointAt(_ list: inout [Repair], _ m: MatchedQueue, _ target: String, _ hostName: String?, _ caution: String?) {
        let q = m.queue
        let shown = q.displayName
        let uri = q.deviceUri ?? ""
        let old = CupsQueues.host(uri) ?? uri
        let doubt = (m.reason == .name ? "“\(shown)” has the same model name as this printer, but prints to \(old). Is it for this printer? " : "") + (caution ?? "")
        let newUri = replacingHost(uri, with: target)
        list.append(Repair(.pointAt, "Point “\(shown)” at \(target)",
                           "\(doubt)It still prints to \(old), the printer's old address. Inkvolt Print points it at \(target).",
                           queue: q.name, target: target, targetUri: newUri,
                           question: "\(doubt)Point “\(shown)” at \(target)? Its print jobs go to \(target) from now on.", confirm: "Point It",
                           manualSteps: ManualSteps.for(.pointAt, queue: shown, target: target, uri: newUri)))
        if let hostName, !hostName.isEmpty {
            let byName = replacingHost(uri, with: hostName)
            list.append(Repair(.pointAt, "Or point it at \(hostName)",
                               "\(doubt)The printer's network name, which follows it when the router gives it a new address.",
                               queue: q.name, target: hostName, targetUri: byName,
                               question: "\(doubt)Point “\(shown)” at \(hostName)? Its print jobs go to whichever address that name has.",
                               confirm: "Point It", isAlternative: true,
                               manualSteps: ManualSteps.for(.pointAt, queue: shown, target: hostName, uri: byName)))
        }
    }

    /// The device URI with another host; its scheme, port and path kept ("ipp://192.0.2.23:631/ipp/print").
    static func replacingHost(_ uri: String, with host: String) -> String {
        guard var c = URLComponents(string: uri) else { return uri }
        c.host = host
        return c.string ?? uri
    }

    private static func capital(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// `prefix` starts `text` and ends there or at a character that isn't a letter or digit.
    private static func startsWithWord(_ text: String, _ prefix: String?) -> Bool {
        guard let prefix, !prefix.isEmpty, text.lowercased().hasPrefix(prefix.lowercased()) else { return false }
        return text.dropFirst(prefix.count).first.map { !$0.isLetter && !$0.isNumber } ?? true
    }
}
