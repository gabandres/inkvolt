import Foundation
import Testing
@testable import PrintCore

/// The offline fixer's diagnosis and repairs on the Mac: the Mac's counterpart of OfflineFixerTests.cs. Windows' queues and
/// ports become CUPS destinations and their device URIs; there's no Print Spooler service, no "Use Printer Offline" and no
/// permission prompt, so repairs are tried once and handed off to Printers & Scanners when macOS refuses or can't do them.
///
/// Ported as they are: Each_step_reports_running_then_its_result_in_order, Queue_matched_only_by_model_name_is_skipped_when_its_old_address_answers,
/// Printer_that_doesnt_answer_gets_no_port_change_and_plain_advice, Failing_probes_become_warnings_not_exceptions,
/// Cancellation_is_not_swallowed, Stale_ports (device URIs), Manual_steps_name_the_queue_and_target,
/// Reachability_names_the_ports_that_answered (no ping), Two_devices_announcing_the_uuid_means_asking_before_adopting,
/// Old_address_still_answering_means_asking_before_adopting, Only_ip_addresses_and_local_names_are_accepted,
/// Unusable_rediscovery_is_treated_as_not_found.
///
/// Adapted to what they mean on the Mac (renamed):
/// - New_address_from_dhcp_points_the_tcpip_port_at_it → newAddressFromDhcpHandsOffAddingTheQueueAgainAtIt (macOS can't
///   re-point a queue: remove it and add it again at the new address).
/// - Paused_and_work_offline_queue_can_be_fixed_as_the_user → pausedAndNotAcceptingQueueOffersResumeAndAccept.
/// - Previous_address_and_stored_queue_name_match_too → previousAddressesMatchToo (Inkvolt Print stores no queue here).
/// - Printer_answers_but_windows_says_offline → printerAnswersButMacosSaysOffline (one hand-off: add it again).
/// - Stuck_jobs_can_be_cancelled_or_restarted_and_long_cancelling_ones_need_the_spooler →
///   stuckJobsCanBeCancelledAndOtherPeoplesNeedAnAdministrator.
/// - Repairs_try_as_the_user_first_and_elevate_only_when_refused and Packaged_copies_never_elevate_and_show_the_steps →
///   repairsTryOnceAndHandOffWhenRefused; Admin_only_and_manual_only_repairs → manualOnlyRepairsOnlyShowTheSteps;
///   Elevated_retry_touches_only_the_jobs_the_user_was_refused → cancellingJobsSaysWhichCouldntBeCancelled.
///
/// Left out (Windows only): Stopped_spooler_offers_only_starting_it_and_skips_the_queues (no spooler; cupsd not answering
/// is in failingProbesBecomeWarningsNotExceptions), Ping_alone_is_not_the_printer_answering (no ping from the sandbox),
/// Scripts_find_queues_ports_and_jobs_by_exact_name and Recreating_an_ipp_queue_reuses_a_temporary_queue_left_by_an_earlier_attempt
/// (RepairScripts isn't ported), Stopping_the_wait_for_permission_is_its_own_outcome, Stopping_after_the_user_pass_says_what_it_already_did,
/// Stopping_before_the_prompt_showed_is_stopped_too, Declining_after_the_user_pass_says_what_it_already_did and
/// Timed_out_elevation_is_unknown_not_failed (no UAC prompt), Port_kind_from_the_real_monitor_strings (Windows port
/// monitors; a queue's connection from its device URI is QueuePrinterTests').
///
/// The Mac's own: reachabilityAsksThePrintingAndWebPorts, rediscoveryFromBonjourJoinsEveryAddressForTheUuid,
/// demoOfficeLaserMovedAndItsQueueIsPaused.
struct OfflineFixerTests {
    private static let uuid = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    private static let oldIp = "192.0.2.12", newIp = "192.0.2.23"
    private static let now = Date(timeIntervalSince1970: 1_792_843_200) // 2026-10-24 12:00 UTC

    private static func device(host: String? = oldIp, previousHosts: [String] = []) -> OfflineDevice {
        OfflineDevice(uuid: uuid, name: "Office laser", model: "Example Laser 400", host: host, previousHosts: previousHosts)
    }

    private static func queue(_ info: String, _ uri: String, state: Int = 3, reasons: String = "none", accepting: Bool = true) -> CupsDestination {
        let name = String(info.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return CupsDestination(name: name, options: [
            "printer-info": info, "device-uri": uri, "printer-type": "4", "printer-state": String(state),
            "printer-state-reasons": reasons, "printer-is-accepting-jobs": accepting ? "true" : "false",
        ])
    }

    private static func socketQueue(_ info: String, _ host: String) -> CupsDestination { queue(info, "socket://\(host)") }

    /// A queue macOS set up from Bonjour: its device URI carries the printer's UUID.
    private static func bonjourQueue(_ info: String, uuid: String = uuid, state: Int = 3, reasons: String = "none", accepting: Bool = true) -> CupsDestination {
        queue(info, "dnssd://Office%20laser._ipp._tcp.local./?uuid=\(uuid)", state: state, reasons: reasons, accepting: accepting)
    }

    private struct FakeProbes: OfflineProbes {
        var found: Rediscovery?
        var answering: Set<String> = []
        var lookupFails: String?
        let reached = Shared<[String]>([])

        struct LookupError: Error, CustomStringConvertible { var description: String }

        func rediscover(_ uuid: String) async throws -> Rediscovery? {
            if let lookupFails { throw LookupError(description: lookupFails) }
            return uuid == OfflineFixerTests.uuid ? found : nil
        }

        func reach(_ host: String) async throws -> Reachability {
            reached.withLock { $0.append(host) }
            return Reachability(host, openPorts: answering.contains(host) ? [631, 9100, 80] : [])
        }
    }

    /// cupsd can't be asked.
    private struct NoCups: PrintQueues {
        let user = "you"
        func destinations() async -> [CupsDestination]? { nil }
        func jobs(_ queue: String) async -> [QueueJob]? { nil }
        func cancel(_ queue: String, job: Int) async throws { throw PrintJobCancelError("cupsd isn't answering.") }
    }

    private static func run(_ probes: FakeProbes, _ queues: [CupsDestination] = [], jobs: [String: [QueueJob]] = [:],
                            device: OfflineDevice? = nil, progress: (@Sendable (CheckResult) -> Void)? = nil) async throws -> OfflineReport {
        try await OfflineDiagnosis.run(device ?? Self.device(), probes: probes, queues: FixedQueues(queues, jobs: jobs, user: "you"), progress: progress)
    }

    private static func check(_ r: OfflineReport, _ kind: CheckKind) -> CheckResult { r.checks.first { $0.kind == kind }! }

    // MARK: Diagnosis

    @Test func newAddressFromDhcpHandsOffAddingTheQueueAgainAtIt() async throws {
        let probes = FakeProbes(found: Rediscovery(Self.newIp, hostName: "NPIEXAMPLE.local"), answering: [Self.newIp])
        let report = try await Self.run(probes, [Self.socketQueue("Office laser", Self.oldIp), Self.socketQueue("Someone else's", "192.0.2.99")])

        #expect(report.moved)
        #expect(Self.check(report, .network).state == .warning)
        #expect(Self.check(report, .network).detail.contains(Self.newIp))
        #expect(Self.check(report, .connection).state == .passed)
        #expect(probes.reached.withLock { $0 } == [Self.oldIp, Self.newIp]) // nothing answers at the old address any more; the new one is tried
        #expect(report.adoption == .adopt)
        try #require(report.queues.count == 1)
        #expect(report.queues[0].reason == .address)
        #expect(report.queues[0].portIsStale)
        #expect(Self.check(report, .queues).state == .failed)

        let add = report.repairs[0]
        #expect(add.kind == .addAgainAt)
        #expect(add.target == Self.newIp)
        #expect(add.queue == "Office_laser")
        #expect(add.manualOnly) // macOS can't change a queue's address: the user removes it and adds it again
        #expect(!add.isAlternative)
        #expect(add.manualSteps.contains { $0.contains(Self.newIp) && $0.contains("HP Jetdirect - Socket") })
        #expect(add.manualSteps.contains { $0.contains("“Office laser”") })
        let byName = report.repairs[1]
        #expect(byName.target == "NPIEXAMPLE.local")
        #expect(byName.isAlternative)
        #expect(report.headline == "Found one thing to fix")
    }

    @Test func eachStepReportsRunningThenItsResultInOrder() async throws {
        let seen = Shared<[CheckResult]>([])
        let probes = FakeProbes(found: Rediscovery(Self.oldIp), answering: [Self.oldIp])
        let report = try await Self.run(probes, [Self.bonjourQueue("Office laser")], progress: { r in seen.withLock { $0.append(r) } })

        let events = seen.withLock { $0 }
        try #require(events.count == 8)
        for (i, kind) in CheckKind.allCases.enumerated() {
            #expect(events[2 * i].kind == kind && events[2 * i].state == .running)
            #expect(events[2 * i + 1].kind == kind)
            #expect(events[2 * i + 1].state != .running)
        }
        #expect(report.checks.allSatisfy { $0.state == .passed })
        #expect(report.repairs.isEmpty)
        #expect(report.headline == "No problems found")
    }

    @Test func pausedAndNotAcceptingQueueOffersResumeAndAccept() async throws {
        let probes = FakeProbes(answering: [Self.oldIp])
        let report = try await Self.run(probes, [Self.bonjourQueue("Office laser", state: 5, reasons: "paused,offline-report", accepting: false)])

        #expect(report.repairs.map(\.kind) == [.resumeQueue, .acceptJobs])
        #expect(report.repairs.allSatisfy { !$0.manualOnly }) // tried first; a refusal hands off
        #expect(Self.check(report, .queueState).detail.contains("paused"))
        #expect(Self.check(report, .queueState).detail.contains("not accepting jobs"))
        #expect(Self.check(report, .queueState).state == .failed)
        #expect(report.queues[0].reason == .uuid)
    }

    @Test func queueMatchedOnlyByModelNameIsSkippedWhenItsOldAddressAnswers() async throws {
        let probes = FakeProbes(found: Rediscovery(Self.newIp), answering: [Self.newIp, "192.0.2.50"])
        let report = try await Self.run(probes, [
            Self.socketQueue("Example Laser 400 (upstairs)", "192.0.2.50"), Self.socketQueue("Example Laser 400", "192.0.2.51"),
            Self.socketQueue("Example Laser 4000", "192.0.2.52"),
        ])

        try #require(report.queues.count == 1) // 400 (upstairs) answers at its own address; 4000 is another model
        #expect(report.queues[0].queue.displayName == "Example Laser 400")
        #expect(report.queues[0].reason == .name)
        #expect(Self.check(report, .queues).detail.contains("matched by its name"))
        try #require(report.repairs.count == 1)
        #expect(report.repairs[0].detail.contains("same model name")) // same model name isn't proof: it says so first
        #expect(report.repairs[0].detail.contains("192.0.2.51"))
    }

    @Test func previousAddressesMatchToo() async throws {
        let probes = FakeProbes(answering: [Self.newIp])
        let report = try await Self.run(probes, [Self.socketQueue("Front desk", "192.0.2.5"), Self.queue("Made by hand", "ipp://192.0.2.6:631/ipp/print")],
                                        device: Self.device(host: Self.newIp, previousHosts: ["192.0.2.5", "192.0.2.6"]))

        #expect(report.queues.map(\.reason) == [.address, .address])
        #expect(report.queues.allSatisfy { $0.portIsStale })
        #expect(report.repairs.map(\.kind) == [.addAgainAt, .addAgainAt])
        let ipp = report.repairs[1]
        #expect(ipp.targetUri == "ipp://\(Self.newIp):631/ipp/print") // port and path kept
        #expect(ipp.manualSteps.contains { $0.contains("Internet Printing Protocol - IPP") && $0.contains("ipp/print") })
    }

    @Test func printerAnswersButMacosSaysOffline() async throws {
        let probes = FakeProbes(answering: [Self.oldIp])
        let bonjour = try await Self.run(probes, [Self.bonjourQueue("Paired", reasons: "offline-report")])
        try #require(bonjour.repairs.count == 1)
        #expect(bonjour.repairs[0].kind == .addAgain)
        #expect(bonjour.repairs[0].manualOnly)
        #expect(Self.check(bonjour, .queueState).state == .warning)
        #expect(Self.check(bonjour, .queueState).detail.contains("macOS shows it offline"))

        let socket = try await Self.run(probes, [Self.queue("Plain", "socket://\(Self.oldIp)", reasons: "offline-report")])
        #expect(socket.repairs.map(\.kind) == [.addAgain])
    }

    @Test func stuckJobsCanBeCancelledAndOtherPeoplesNeedAnAdministrator() async throws {
        let probes = FakeProbes(answering: [Self.oldIp])
        let q = Self.bonjourQueue("Office laser")
        let report = try await Self.run(probes, [q], jobs: [q.name: [
            QueueJob(id: 7, name: "Report.pdf", pages: 3, state: .stopped, submitted: Self.now.addingTimeInterval(-1200), owner: "you"),
            QueueJob(id: 8, name: "Label.pdf", pages: 1, state: .pending, submitted: Self.now.addingTimeInterval(-1140), owner: "you"),
            QueueJob(id: 9, name: "", state: .stopped, submitted: Self.now.addingTimeInterval(-600), owner: ""), // someone else's: cupsd hides its details
        ]])

        #expect(report.repairs.map(\.kind) == [.cancelStuckJobs, .cancelOthersJobs])
        #expect(report.repairs[0].jobIds == [7])
        #expect(report.repairs[0].question?.contains("Report.pdf") == true)
        #expect(!report.repairs[0].manualOnly)
        #expect(report.repairs[1].manualOnly)
        #expect(report.repairs[1].manualSteps.contains { $0.contains("administrator") })
        #expect(Self.check(report, .queueState).detail.contains("2 stuck jobs"))
        #expect(report.headline == "Found 2 things to fix")
    }

    @Test func printerThatDoesntAnswerGetsNoPortChangeAndPlainAdvice() async throws {
        let report = try await Self.run(FakeProbes(), [Self.socketQueue("Office laser", Self.oldIp)])

        #expect(Self.check(report, .network).state == .warning)
        #expect(Self.check(report, .connection).state == .failed)
        #expect(!report.queues[0].portIsStale)
        #expect(report.repairs.isEmpty)
        #expect(report.headline == "The printer isn't answering")
        #expect(report.advice.contains("switched on"))
    }

    @Test func failingProbesBecomeWarningsNotExceptions() async throws {
        let report = try await Self.run(FakeProbes(lookupFails: "Bonjour failed"))
        #expect(Self.check(report, .network).detail.contains("Bonjour failed"))

        let noQueues = try await OfflineDiagnosis.run(Self.device(), probes: FakeProbes(answering: [Self.oldIp]), queues: NoCups())
        #expect(Self.check(noQueues, .queues).state == .warning)
        #expect(Self.check(noQueues, .queues).detail.contains("Couldn't read"))
        #expect(Self.check(noQueues, .queueState).state == .skipped)
    }

    private struct CancelledProbes: OfflineProbes {
        func rediscover(_ uuid: String) async throws -> Rediscovery? {
            try await Task.sleep(for: .seconds(30))
            return nil
        }

        func reach(_ host: String) async throws -> Reachability {
            try await Task.sleep(for: .seconds(30))
            return Reachability(host)
        }
    }

    @Test func cancellationIsNotSwallowed() async {
        let task = Task { try await OfflineDiagnosis.run(Self.device(), probes: CancelledProbes(), queues: NoCups()) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test(arguments: [
        ("socket://192.0.2.12", "192.0.2.23", nil, true),
        ("socket://192.0.2.23:9100", "192.0.2.23", nil, false),
        ("ipp://npiexample.local/ipp/print", "192.0.2.23", "NPIEXAMPLE.local", false), // already follows the printer
        ("lpd://printer.example.com/queue", "192.0.2.23", nil, false), // a DNS name may follow it too
        ("socket://192.0.2.12", nil, nil, false), // nowhere better to point it
        ("dnssd://Office%20laser._ipp._tcp.local./?uuid=2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b", "192.0.2.23", nil, false),
        ("ipp://192.0.2.12:631/ipp/print", "192.0.2.23", nil, true),
        ("usb://Example/Laser?serial=1", "192.0.2.23", nil, false),
    ] as [(String, String?, String?, Bool)])
    func stalePorts(_ uri: String, _ address: String?, _ hostName: String?, _ stale: Bool) {
        #expect(OfflineDiagnosis.isStale(uri, address: address, hostName: hostName) == stale)
    }

    @Test func twoDevicesAnnouncingTheUuidMeansAskingBeforeAdopting() async throws {
        let probes = FakeProbes(found: Rediscovery(Self.newIp, addresses: [Self.newIp, "192.0.2.66"]), answering: [Self.newIp])
        let report = try await Self.run(probes, [Self.socketQueue("Office laser", Self.oldIp)])

        #expect(report.adoption == .ask)
        #expect(report.adoptionQuestion?.contains("192.0.2.66") == true)
        #expect(report.adoptionQuestion?.contains("Use \(Self.newIp)") == true)
        #expect(Self.check(report, .network).state == .warning)
        #expect(Self.check(report, .network).detail.contains("asks before"))
        #expect(report.repairs[0].detail.hasPrefix("More than one device")) // the hand-off says so too, before the user types the address
    }

    @Test func oldAddressStillAnsweringMeansAskingBeforeAdopting() async throws {
        var probes = FakeProbes(found: Rediscovery(Self.newIp), answering: [Self.oldIp, Self.newIp])
        let report = try await Self.run(probes, [Self.socketQueue("Office laser", Self.oldIp)])

        #expect(report.oldAddressAnswers)
        #expect(report.adoption == .ask)
        #expect(report.adoptionQuestion?.contains("still answers at its old address, \(Self.oldIp)") == true)

        probes.found = Rediscovery(Self.oldIp)
        #expect(try await Self.run(probes, [Self.socketQueue("Office laser", Self.oldIp)]).adoption == AdoptDecision.none) // didn't move: nothing to adopt
    }

    @Test(arguments: [
        ("192.0.2.23", "printer.local", "192.0.2.23", "printer.local"),
        ("192.0.2.23", "printer.example.com", "192.0.2.23", nil), // only .local names
        ("192.0.2.23", "bad name;.local", "192.0.2.23", nil),
        ("192.0.2.23", "-x.local", "192.0.2.23", nil),
        ("not-an-address", "printer.local", nil, nil), // no IP address: nothing usable
        ("192.0.2.023", nil, nil, nil), // not in canonical form
    ] as [(String, String?, String?, String?)])
    func onlyIpAddressesAndLocalNamesAreAccepted(_ address: String, _ hostName: String?, _ expectAddress: String?, _ expectName: String?) {
        let r = Rediscovery.accept([address], hostName: hostName)
        #expect(r?.address == expectAddress)
        #expect(r?.hostName == expectName)
    }

    @Test func unusableRediscoveryIsTreatedAsNotFound() async throws {
        let report = try await Self.run(FakeProbes(found: Rediscovery("evil;host", hostName: "x.example.com"), answering: [Self.oldIp]))
        #expect(report.found == nil)
        #expect(report.adoption == .none)
    }

    @Test func reachabilityNamesThePortsThatAnswered() {
        #expect(Reachability(Self.newIp, openPorts: [631, 9100, 80, 443]).portsText == "IPP, raw printing (port 9100) and its web page")
        #expect(!Reachability(Self.newIp).answers)
    }

    // MARK: Repairs

    private struct FakeControl: QueueControl {
        var result: QueueControlError?
        let calls = Shared<[String]>([])

        func resume(_ queue: String) async throws {
            calls.withLock { $0.append("resume \(queue)") }
            if let result { throw result }
        }

        func acceptJobs(_ queue: String) async throws {
            calls.withLock { $0.append("accept \(queue)") }
            if let result { throw result }
        }
    }

    private static let resume = Repair(.resumeQueue, "Resume", "", queue: "q", manualSteps: ManualSteps.for(.resumeQueue, queue: "q"))

    @Test func repairsTryOnceAndHandOffWhenRefused() async {
        let ok = FakeControl()
        #expect(await RepairRunner.run(Self.resume, queues: NoCups(), control: ok).kind == .fixed)
        #expect(ok.calls.withLock { $0 } == ["resume q"])

        let refused = FakeControl(result: .refused) // a standard user: macOS wants an administrator
        let handOff = await RepairRunner.run(Self.resume, queues: NoCups(), control: refused)
        #expect(handOff.kind == .manual)
        #expect(handOff.steps == Self.resume.manualSteps)
        #expect(handOff.message.contains("administrator"))
        #expect(refused.calls.withLock { $0 }.count == 1)

        let failed = await RepairRunner.run(Self.resume, queues: NoCups(), control: FakeControl(result: .failed("cupsd said no")))
        #expect(failed.kind == .failed)
        #expect(failed.message == "cupsd said no")
        #expect(failed.steps == Self.resume.manualSteps)
    }

    @Test func manualOnlyRepairsOnlyShowTheSteps() async {
        let add = Repair(.addAgainAt, "Add again", "", queue: "q", target: Self.newIp, manualOnly: true,
                         manualSteps: ManualSteps.for(.addAgainAt, queue: "q", target: Self.newIp, uri: "socket://\(Self.newIp)"))
        let control = FakeControl()
        let outcome = await RepairRunner.run(add, queues: NoCups(), control: control)
        #expect(outcome.kind == .manual)
        #expect(outcome.steps.contains { $0.contains(Self.newIp) })
        #expect(control.calls.withLock { $0 }.isEmpty)
    }

    @Test func cancellingJobsSaysWhichCouldntBeCancelled() async {
        let jobs = [
            QueueJob(id: 7, name: "Report.pdf", state: .stopped, submitted: Self.now, owner: "you"),
            QueueJob(id: 8, name: "Theirs.pdf", state: .stopped, submitted: Self.now, owner: "alex"),
        ]
        let queues = FixedQueues([Self.bonjourQueue("Office laser")], jobs: ["Office_laser": jobs], user: "you")
        let cancel = Repair(.cancelStuckJobs, "Cancel", "", queue: "Office_laser", jobIds: [7, 8],
                            manualSteps: ManualSteps.for(.cancelStuckJobs, queue: "Office laser"))
        let outcome = await RepairRunner.run(cancel, queues: queues, control: FakeControl())

        #expect(outcome.kind == .failed)
        #expect(outcome.message.hasPrefix("1 job was cancelled."))
        #expect(outcome.message.contains("Only an administrator"))
        #expect(outcome.steps == cancel.manualSteps)
        #expect(await queues.jobs("Office_laser")?.map(\.id) == [8])

        let mine = Repair(.cancelStuckJobs, "Cancel", "", queue: "Office_laser", jobIds: [7])
        let again = FixedQueues([], jobs: ["Office_laser": jobs], user: "you")
        #expect(await RepairRunner.run(mine, queues: again, control: FakeControl()).kind == .fixed)
    }

    @Test func manualStepsNameTheQueueAndTarget() {
        #expect(ManualSteps.for(.addAgainAt, queue: "Office laser", target: Self.newIp, uri: "socket://\(Self.newIp)").contains { $0.contains(Self.newIp) })
        #expect(ManualSteps.for(.resumeQueue, queue: "Office laser").contains { $0.contains("“Office laser”") })
        #expect(ManualSteps.for(.addAgainAt, queue: "q", target: Self.newIp, uri: "lpd://\(Self.newIp)/raw").contains { $0.contains("Line Printer Daemon - LPD") && $0.contains("raw") })
        #expect(RepairKind.allCases.allSatisfy { !ManualSteps.for($0, queue: "q", target: Self.newIp).isEmpty })
        #expect(RepairKind.allCases.allSatisfy { k in ManualSteps.for(k, queue: "q").contains { $0.contains("Printers & Scanners") } })
    }

    // MARK: The Mac's own

    private struct ConnectFailed: Error {}

    private struct FakeScanner: NetworkScanner {
        var open: Set<Int>
        func localNetworks() -> [LocalNetwork] { [] }
        func isOpen(_ host: String, port: Int, timeout: Duration) async throws -> Bool {
            if port == 443 { throw ConnectFailed() } // a failed connect is just closed
            return open.contains(port)
        }
        func broadcastSnmp(_ broadcasts: [String], requests: [[UInt8]], window: Duration, answered: @escaping @Sendable (String) -> Void) async throws {}
    }

    @Test func reachabilityAsksThePrintingAndWebPorts() async throws {
        let r = try await Reachability.check(Self.newIp, with: FakeScanner(open: [80, 9100, 515]))
        #expect(r.host == Self.newIp)
        #expect(r.openPorts == [9100, 80]) // in Reachability.ports' order; 515 isn't asked
        #expect(r.answers)
        #expect(try await Reachability.check(Self.newIp, with: FakeScanner(open: [])).answers == false)
    }

    @Test func rediscoveryFromBonjourJoinsEveryAddressForTheUuid() {
        func printer(_ uuid: String, _ addresses: [String], hostName: String? = nil) -> DiscoveredPrinter {
            DiscoveredPrinter(uuid: uuid, name: "Office laser", model: nil, host: addresses.first, hostName: hostName, esclRoot: nil, hasScanner: false,
                              ippUri: nil, txt: [:], addresses: addresses)
        }
        let printers = [printer("0e1f2a3b-0000-4000-8000-000000000001", ["192.0.2.40"]),
                        printer(Self.uuid, [Self.newIp, "192.0.2.66"], hostName: "NPIEXAMPLE.local.")]
        let found = Rediscovery.from(printers, uuid: Self.uuid.uppercased())
        #expect(found?.address == Self.newIp)
        #expect(found?.hostName == "NPIEXAMPLE.local")
        #expect(found?.isAmbiguous == true)
        #expect(Rediscovery.from(printers, uuid: "3c9a7e51-8d2b-4f60-a1e4-5b7c9d0e2f13") == nil)
    }

    @Test func demoOfficeLaserMovedAndItsQueueIsPaused() async throws {
        let demo = DemoOffline(now: Self.now, delay: .zero)
        let office = OfflineDevice(uuid: Demo.officeUuid, name: "Demo office laser", model: nil, host: Demo.officeOldHost)
        let report = try await OfflineDiagnosis.run(office, probes: demo, queues: demo)

        #expect(report.adoption == .adopt)
        #expect(report.found?.address == Demo.officeNewHost)
        #expect(report.queues.map(\.queue.name) == [DemoOffline.officeQueue])
        #expect(report.repairs.map(\.kind) == [.resumeQueue, .addAgainAt, .addAgainAt, .cancelStuckJobs])

        #expect(await RepairRunner.run(report.repairs[0], queues: demo, control: demo).kind == .fixed)
        #expect(await RepairRunner.run(report.repairs[3], queues: demo, control: demo).kind == .fixed)
        let after = try await OfflineDiagnosis.run(office, probes: demo, queues: demo)
        #expect(after.repairs.map(\.kind) == [.addAgainAt, .addAgainAt]) // only the hand-off is left

        let demoPrinter = OfflineDevice(uuid: Demo.uuid, name: "Demo printer", model: nil, host: FixtureTransport.demoHost)
        #expect(try await OfflineDiagnosis.run(demoPrinter, probes: demo, queues: demo).headline == "No problems found")
    }
}
