import Foundation
import Testing
@testable import PrintCore

/// Job notifications (roadmap 3.4): `AlertTracker.observeJobs` on the demo queue's made-up jobs and the demo fixer's stuck
/// job, on a fake clock; the document's name as a notification shows it; what's kept across a restart. Ported from
/// JobAlertTests.cs with CUPS's job states in place of Windows' status bits: Error is `stopped`, None `pending`, Printing
/// `processing`, Paused `held`, Printed `completed`, Deleting `canceled`; Windows' PaperOut and Offline job bits are the
/// queue's own offline reason (`JobQueueState.printerOffline`). Not ported: the toasts' XML, tags and arguments (the Mac
/// app's notifications), the spooler's bits (`SpoolerQueue`), Use Printer Offline, Spooling, Retained and the real
/// spooler's dead-port sequence, which have no CUPS counterpart; the Mac's own cases are at the end.
struct JobAlertTests {
    private static let laser = "12345678-1234-4abc-8def-123456789abc", printerName = "Office laser"
    private static let me = JobOwner(userName: "gabri", domain: "OFFICE", machine: "GABRI-PC")
    private static let zone = TimeZone(secondsFromGMT: -4 * 3600)!
    /// 2026-10-24 12:00 at UTC-4.
    private static let t0 = Date(timeIntervalSince1970: 1_792_857_600)
    /// 2026-10-24 15:30 UTC.
    private static let submitted = t0.addingTimeInterval(-30 * 60)

    private static let ready = PrinterStatus(code: "ready", message: "Ready", severity: .info, alerts: [])
    private static let printing = PrinterStatus(code: "processing", message: "Printing", severity: .info, alerts: [])

    private static func at(_ minutes: Double, from: Date = t0) -> Date { from.addingTimeInterval(minutes * 60) }

    private static func rules(_ change: (inout AlertRules) -> Void = { _ in }) -> AlertRules {
        var r = AlertRules()
        r.jobs = true
        change(&r)
        return r
    }

    private static func tracker(_ rules: AlertRules = rules()) -> AlertTracker { AlertTracker(rules: rules, timeZone: zone) }

    private static func job(_ id: Int = 7, _ state: JobState = .processing, printed: Int = 0, name: String = "Report.pdf", owner: String = "gabri",
                            submitted: Date? = nil, pages: Int? = 10, bytes: Int64 = 0, machine: String? = nil) -> QueueJob {
        QueueJob(id: id, name: name, pages: pages, pagesPrinted: printed, state: state, submitted: submitted ?? Self.submitted, owner: owner,
                 bytes: bytes, machine: machine)
    }

    private static func queue(_ jobs: QueueJob...) -> JobQueueState { JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: jobs) }

    /// The printer read, then its queue, at one moment: as the menu bar does it, a minute apart.
    @discardableResult
    private static func read(_ t: AlertTracker, _ when: Date, _ queue: JobQueueState?, _ status: PrinterStatus? = nil, reachable: Bool = true) -> [AlertNotice] {
        let snap = PrinterSnapshot(uuid: laser, name: printerName, reachable: reachable, status: reachable ? status ?? ready : nil, supplies: [])
        return t.observe(snap, now: when) + t.observeJobs(laser, printerName: printerName, queue, me: me, now: when)
    }

    /// Reads every minute from `from` for `minutes`; every notice told.
    private static func minutes(_ t: AlertTracker, _ from: Date, _ minutes: Int, _ queue: JobQueueState?, _ status: PrinterStatus? = nil) -> [AlertNotice] {
        (0...minutes).flatMap { read(t, at(Double($0), from: from), queue, status) }
    }

    // MARK: Off by default

    @Test func jobAlertsAreOffByDefault() {
        let t = AlertTracker(rules: AlertRules(), timeZone: Self.zone)
        #expect(!t.rules.jobs)
        #expect(Self.minutes(t, Self.t0, 20, Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(t.shown().isEmpty)
    }

    @Test func alertsOffOrPausedDropAJobAlertAndItStaysTold() {
        let off = Self.tracker(Self.rules { $0.enabled = false })
        #expect(Self.minutes(off, Self.t0, 3, Self.queue(Self.job(7,.stopped))).isEmpty)
        off.rules.enabled = true
        #expect(Self.minutes(off, Self.at(4), 3, Self.queue(Self.job(7,.stopped))).isEmpty)

        let paused = Self.tracker()
        paused.pausedUntil = Self.at(10)
        #expect(Self.minutes(paused, Self.t0, 3, Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(Self.minutes(paused, Self.at(11), 3, Self.queue(Self.job(7,.stopped))).isEmpty)
    }

    @Test func quietHoursHoldAJobAlertAndDropItIfTheJobRecovered() throws {
        let rules = Self.rules { $0.quiet = QuietHours(from: (22, 0), to: (7, 0)) }
        let night = Self.t0.addingTimeInterval(11 * 3600) // 23:00
        let t = Self.tracker(rules)
        #expect(Self.minutes(t, night, 4, Self.queue(Self.job(7,.stopped))).isEmpty)
        let released = t.release(now: night.addingTimeInterval(8.5 * 3600))
        try #require(released.count == 1)
        #expect(released[0].kind == .jobFailed)

        let u = Self.tracker(rules)
        #expect(Self.minutes(u, night, 4, Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(Self.minutes(u, Self.at(5, from: night), 2, Self.queue(Self.job(7,.processing, printed: 3))).isEmpty)
        #expect(u.release(now: night.addingTimeInterval(8.5 * 3600)).isEmpty)
    }

    // MARK: Failed

    @Test func aFailedJobIsToldOnceNamingTheDocumentAndThePrinter() throws {
        let t = Self.tracker()
        #expect(Self.read(t, Self.t0, Self.queue(Self.job(7,.stopped))).isEmpty) // could be someone at the printer right now
        let told = Self.read(t, Self.at(1), Self.queue(Self.job(7,.stopped)))
        try #require(told.count == 1)
        let n = told[0]
        #expect(n.kind == .jobFailed)
        #expect(n.level == .error)
        #expect(n.title.contains("Report.pdf"))
        #expect(n.body.contains(Self.printerName))
        #expect(n.printerName == Self.printerName)
        #expect(n.uuid == Self.laser)
        #expect(n.jobKey != nil)
        #expect(Self.minutes(t, Self.at(2), 60, Self.queue(Self.job(7,.stopped))).isEmpty)
    }

    /// A failure within its hold asks for a read when the hold runs out, as a printer's own problem does.
    @Test func aFailedJobAsksForAReadWhenItsHoldRunsOut() {
        let t = Self.tracker()
        #expect(Self.read(t, Self.t0, Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(t.pendingUntil(Self.laser) == Self.t0.addingTimeInterval(t.rules.errorHold))
        #expect(t.nextCheck == Self.t0.addingTimeInterval(t.rules.errorHold))
        #expect(Self.read(t, Self.at(1), Self.queue(Self.job(7,.stopped))).map(\.kind) == [.jobFailed])
        #expect(t.pendingUntil(Self.laser) == nil)
        let someoneElses = Self.tracker()
        #expect(Self.read(someoneElses, Self.t0, Self.queue(Self.job(7,.stopped, owner: "alex"))).isEmpty)
        #expect(someoneElses.pendingUntil(Self.laser) == nil)
    }

    @Test func anErrorGoneBeforeTheHoldWasNothing() {
        let t = Self.tracker()
        #expect(Self.read(t, Self.t0, Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(Self.read(t, Self.t0.addingTimeInterval(30), Self.queue(Self.job(7,.processing, printed: 1))).isEmpty)
        #expect(Self.read(t, Self.at(1), Self.queue(Self.job(7,.processing, printed: 2))).isEmpty)
    }

    @Test(arguments: [
        (JobState.stopped, true), (.aborted, true),
        (.held, false), // held by hand, or until a time
        (.pending, false), (.processing, false), (.canceled, false), (.completed, false),
    ])
    func whatCountsAsFailed(state: JobState, failed: Bool) { #expect(JobRules.isFailed(state) == failed) }

    @Test func aFailureInAPausedQueueOrOnAPrinterThatIsntReadyIsStillTold() {
        let paused = Self.tracker()
        #expect(Self.minutes(paused, Self.t0, 2, JobQueueState(paused: true, printerOffline: false, othersMayPrint: false, jobs: [Self.job(7,.stopped)])).count == 1)
        let offline = Self.tracker()
        let off = PrinterStatus(code: "offline", message: "Offline", severity: .error, alerts: [])
        #expect(Self.minutes(offline, Self.t0, 2, Self.queue(Self.job(7,.stopped)), off).count == 1)
    }

    // MARK: Stuck

    @Test func aJobThatDoesntMoveForFiveMinutesOnAReadyPrinterIsToldOnce() throws {
        let t = Self.tracker()
        let queue = Self.queue(Self.job(printed: 3))
        #expect(Self.minutes(t, Self.t0, 4, queue).isEmpty)
        #expect(t.pendingUntil(Self.laser) == Self.at(5)) // asks for a printer read then
        let told = Self.read(t, Self.at(5), queue)
        try #require(told.count == 1)
        let n = told[0]
        #expect(n.kind == .jobStuck)
        #expect(n.level == .warning)
        #expect(n.title.contains("Report.pdf"))
        #expect(n.body.contains(Self.printerName))
        #expect(n.body.contains("5 minutes"))
        #expect(t.pendingUntil(Self.laser) == nil)
        #expect(Self.minutes(t, Self.at(6), 120, queue).isEmpty)
    }

    @Test func aJobPrintingFineForHoursIsNotStuck() {
        let t = Self.tracker()
        for i in 0..<240 { #expect(Self.read(t, Self.at(Double(i)), Self.queue(Self.job(printed: i / 2, pages: 1000))).isEmpty) }
    }

    @Test(arguments: ["processing", "printing"])
    func aHungJobWhileThePrinterSaysItsPrintingIsToldAfterTheLongerWaitInHonestWords(code: String) throws {
        let t = Self.tracker()
        let printing = PrinterStatus(code: code, message: "Printing", severity: .info, alerts: [])
        let queue = Self.queue(Self.job(printed: 0, pages: 0))
        #expect(Self.minutes(t, Self.t0, 14, queue, printing).isEmpty)
        #expect(t.pendingUntil(Self.laser) == Self.at(15))
        let told = Self.read(t, Self.at(15), queue, printing)
        try #require(told.count == 1)
        #expect(told[0].kind == .jobStuck)
        #expect(told[0].title == "“Report.pdf” may be stuck")
        #expect(told[0].body.contains("hasn't moved for 15 minutes and may be stuck"))
        #expect(told[0].body.contains("says it's printing"))
        #expect(Self.minutes(t, Self.at(16), 180, queue, printing).isEmpty) // no progress: the same episode
    }

    @Test func aSlowJobThatMovesStaysSilentWhileThePrinterSaysItsPrinting() {
        let pages = Self.tracker()
        for i in 0..<300 { // a page every 14 minutes
            #expect(Self.read(pages, Self.at(Double(i)), Self.queue(Self.job(printed: i / 14, pages: 1000)), Self.printing).isEmpty)
        }
        let bytes = Self.tracker()
        for i in 0..<300 { // no page counts, its size still growing
            #expect(Self.read(bytes, Self.at(Double(i)), Self.queue(Self.job(printed: 0, pages: nil, bytes: Int64(1000 + i / 14))), Self.printing).isEmpty)
        }
    }

    @Test func aJobWithPagesReportedAndMovingIsntStuckOnAReadyPrinterEither() {
        let t = Self.tracker()
        for i in 0..<120 { #expect(Self.read(t, Self.at(Double(i)), Self.queue(Self.job(printed: i / 4, pages: 1000))).isEmpty) }
    }

    @Test func aPrinterThatStartsPrintingGetsTheLongerWaitFromTheLastMovementAndOneGoingReadyTheShorter() {
        let t = Self.tracker()
        let queue = Self.queue(Self.job())
        #expect(Self.minutes(t, Self.t0, 3, queue).isEmpty) // ready
        #expect(Self.minutes(t, Self.at(4), 10, queue, Self.printing).isEmpty) // 14 minutes still
        #expect(Self.read(t, Self.at(15), queue, Self.printing).count == 1)

        let u = Self.tracker()
        #expect(Self.minutes(u, Self.t0, 7, queue, Self.printing).isEmpty)
        #expect(Self.minutes(u, Self.at(8), 4, queue).isEmpty) // ready for 4 minutes: printing wasn't being ready
        let told = Self.read(u, Self.at(13), queue)
        #expect(told.count == 1 && told[0].body.contains("is ready"))
    }

    @Test func aPrinterFlippingBetweenReadyAndPrintingStillTellsAJobThatNeverMoves() {
        let t = Self.tracker()
        var told: [AlertNotice] = []
        for i in 0..<60 {
            let status = i % 4 == 3 ? Self.printing : Self.ready
            told += Self.read(t, Self.at(Double(i)), Self.queue(Self.job()), status)
        }
        #expect(told.count == 1 && told[0].body.contains("may be stuck"))
    }

    @Test func aJobWaitingBehindSomeoneElsesLongJobIsNotStuck() {
        let t = Self.tracker()
        for i in 0..<120 {
            let theirs = Self.job(1, .processing, printed: i / 2, name: "Their big file.pdf", owner: "alex", submitted: Self.submitted.addingTimeInterval(-300), pages: 1000)
            #expect(Self.read(t, Self.at(Double(i)), Self.queue(theirs, Self.job(2, .pending, name: "Mine.pdf"))).isEmpty)
        }
    }

    @Test func someoneElsesJobThatFinishesStartsMyWaitAgain() {
        let t = Self.tracker()
        let theirs = Self.job(1, .processing, owner: "alex", submitted: Self.submitted.addingTimeInterval(-300))
        let mine = Self.job(2, .pending)
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(theirs, mine)).isEmpty)
        #expect(Self.minutes(t, Self.at(4), 3, Self.queue(mine)).isEmpty)
        #expect(Self.minutes(t, Self.at(8), 2, Self.queue(mine)).count == 1) // five minutes after the other job left
    }

    @Test func newJobsArrivingBehindItArentProgress() {
        let t = Self.tracker()
        let mine = Self.job(2, .processing)
        var told: [AlertNotice] = []
        for i in 0...5 {
            let behind = (0..<i).map { n in Self.job(100 + n, .pending, owner: "alex", submitted: Self.submitted.addingTimeInterval(Double(n + 1) * 60)) }
            told += Self.read(t, Self.at(Double(i)), JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: [mine] + behind))
        }
        #expect(told.map(\.title) == ["“Report.pdf” isn't moving"])
    }

    @Test func onlyMyFirstJobIsToldStuckTheNextGetsItsOwnWaitOnceThatOneIsGone() {
        let t = Self.tracker()
        let first = Self.job(1, .processing, name: "First.pdf")
        let second = Self.job(2, .pending, name: "Second.pdf", submitted: Self.submitted.addingTimeInterval(60))
        let a = Self.minutes(t, Self.t0, 30, Self.queue(first, second))
        #expect(a.count == 1 && a[0].title.contains("First.pdf"))
        #expect(Self.minutes(t, Self.at(31), 4, Self.queue(second)).isEmpty) // first cancelled: the queue moved
        let b = Self.minutes(t, Self.at(36), 0, Self.queue(second))
        #expect(b.count == 1 && b[0].title.contains("Second.pdf"))
    }

    @Test func aFailedFirstJobStandsForTheOnesBehindIt() {
        let t = Self.tracker()
        let failed = Self.job(1, .stopped, name: "First.pdf")
        let second = Self.job(2, .pending, name: "Second.pdf", submitted: Self.submitted.addingTimeInterval(60))
        let told = Self.minutes(t, Self.t0, 30, Self.queue(failed, second))
        #expect(told.count == 1 && told[0].title.contains("First.pdf"))
    }

    @Test func aQueuePausedOnPurposeHoldsNoStuckJobAndGetsTheFullWaitOnceResumed() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 30, JobQueueState(paused: true, printerOffline: false, othersMayPrint: false, jobs: [Self.job()])).isEmpty)
        #expect(t.pendingUntil(Self.laser) == nil)
        #expect(Self.minutes(t, Self.at(31), 4, Self.queue(Self.job())).isEmpty)
        #expect(Self.minutes(t, Self.at(36), 0, Self.queue(Self.job())).count == 1)
    }

    @Test func aJobPausedByHandIsNotStuck() { #expect(Self.minutes(Self.tracker(), Self.t0, 30, Self.queue(Self.job(7,.held))).isEmpty) }

    @Test(arguments: [JobState.completed, .canceled, .aborted])
    func aJobOnItsWayOutIsNotStuck(state: JobState) {
        #expect(!Self.minutes(Self.tracker(), Self.t0, 30, Self.queue(Self.job(7,state))).contains { $0.kind == .jobStuck })
    }

    @Test(arguments: [("offline", Severity.error), ("warmingUp", .info), ("initializing", .info), ("paused", .warning), ("unknown", .warning),
                      ("unavailable", .warning), ("rejecting", .warning)])
    func aPrinterThatIsntReadyHoldsNoStuckJob(code: String, severity: Severity) {
        #expect(Self.minutes(Self.tracker(), Self.t0, 30, Self.queue(Self.job()), PrinterStatus(code: code, message: code, severity: severity, alerts: [])).isEmpty)
    }

    @Test(arguments: [("jamInPrinter", Severity.error), ("manuallyFeed", .warning), ("manual-feed", .warning)])
    func aReadyCodeWithAProblemOrAManualFeedIsntReady(id: String, severity: Severity) {
        let status = PrinterStatus(code: "ready", message: "Ready", severity: severity, alerts: [PrinterAlert(id: id, severity: severity, message: "Text")])
        #expect(!Self.minutes(Self.tracker(), Self.t0, 30, Self.queue(Self.job()), status).contains { $0.jobKey != nil })
    }

    @Test func aLowTonerWarningDoesntStopAPrinterBeingReady() {
        let status = PrinterStatus(code: "ready", message: "Ready", severity: .warning, alerts: [PrinterAlert(id: "cartridgeLow", severity: .warning, message: "Toner low")])
        #expect(Self.minutes(Self.tracker(), Self.t0, 6, Self.queue(Self.job()), status).count == 1)
    }

    @Test(arguments: ["ready", "idle", "inPowerSave"])
    func aPrinterIdleOrAsleepIsReady(code: String) {
        #expect(Self.minutes(Self.tracker(), Self.t0, 6, Self.queue(Self.job()), PrinterStatus(code: code, message: code, severity: .info, alerts: [])).count == 1)
    }

    /// Windows' PaperOut and Offline job bits: on the Mac, the queue's own offline reason.
    @Test func theQueueSayingThePrinterCantBeReachedHoldsNoStuckJob() {
        #expect(Self.minutes(Self.tracker(), Self.t0, 30, JobQueueState(paused: false, printerOffline: true, othersMayPrint: false, jobs: [Self.job()])).isEmpty)
    }

    @Test func aPrinterThatStopsBeingReadyStartsTheWaitAgain() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job())).isEmpty)
        // Between two queue reads the printer printed a page: the queue read hasn't seen it, the printer's own read has.
        _ = t.observe(PrinterSnapshot(uuid: Self.laser, name: Self.printerName, reachable: true, status: Self.printing, supplies: []), now: Self.at(3.5))
        #expect(Self.minutes(t, Self.at(4), 4, Self.queue(Self.job())).isEmpty)
        #expect(Self.read(t, Self.at(9), Self.queue(Self.job())).count == 1)
    }

    @Test func aPrinterNeverReadOrNotAnsweringOrWithAnUnusableReplyIsntKnownToBeReady() {
        let never = Self.tracker()
        for i in 0..<30 { #expect(never.observeJobs(Self.laser, printerName: Self.printerName, Self.queue(Self.job()), me: Self.me, now: Self.at(Double(i))).isEmpty) }

        let off = Self.tracker()
        for i in 0..<30 { #expect(!Self.read(off, Self.at(Double(i)), Self.queue(Self.job()), reachable: false).contains { $0.jobKey != nil }) }

        let unusable = Self.tracker()
        for i in 0..<30 {
            _ = unusable.observe(PrinterSnapshot(uuid: Self.laser, name: Self.printerName, reachable: true, status: nil, supplies: []), now: Self.at(Double(i)))
            #expect(unusable.observeJobs(Self.laser, printerName: Self.printerName, Self.queue(Self.job()), me: Self.me, now: Self.at(Double(i))).isEmpty)
        }
    }

    @Test func readyHasToBeWhatThePrinterSaysAfterTheWaitNotMinutesBefore() {
        let t = Self.tracker()
        let snap = PrinterSnapshot(uuid: Self.laser, name: Self.printerName, reachable: true, status: Self.ready, supplies: [])
        _ = t.observe(snap, now: Self.t0)
        for i in 0...20 { #expect(t.observeJobs(Self.laser, printerName: Self.printerName, Self.queue(Self.job()), me: Self.me, now: Self.at(Double(i))).isEmpty) }
        #expect(t.pendingUntil(Self.laser) == Self.at(5))
        _ = t.observe(snap, now: Self.at(20.5))
        #expect(t.observeJobs(Self.laser, printerName: Self.printerName, Self.queue(Self.job()), me: Self.me, now: Self.at(21)).count == 1)
    }

    @Test func theTimeTheMacSleptDoesntCountAsWaiting() {
        let t = Self.tracker()
        let woke = Self.t0.addingTimeInterval(8 * 3600)
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job())).isEmpty)
        #expect(Self.read(t, woke, Self.queue(Self.job())).isEmpty) // woke up: a gap says nothing
        #expect(Self.minutes(t, Self.at(1, from: woke), 3, Self.queue(Self.job())).isEmpty)
        #expect(Self.read(t, Self.at(5, from: woke), Self.queue(Self.job())).count == 1)
    }

    @Test func wakingUpStartsTheWaitsAndTheFailureHoldAgain() {
        let t = Self.tracker()
        #expect(Self.read(t, Self.t0, Self.queue(Self.job(7,.stopped))).isEmpty)
        t.resetPending()
        #expect(Self.read(t, Self.t0.addingTimeInterval(90), Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(Self.read(t, Self.t0.addingTimeInterval(150), Self.queue(Self.job(7,.stopped))).count == 1)
    }

    @Test func aJobFirstSeenLateGetsTheFullWaitWheneverItWasSubmitted() {
        let t = Self.tracker()
        let old = Self.job(submitted: Self.submitted.addingTimeInterval(-2 * 86_400))
        #expect(Self.minutes(t, Self.t0, 4, Self.queue(old)).isEmpty)
        #expect(Self.read(t, Self.at(5), Self.queue(old)).count == 1)
    }

    // MARK: One per job

    @Test func stuckRecoveredAndStuckAgainIsToldAgainAfterRealProgress() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 6, Self.queue(Self.job(printed: 1))).count == 1)
        #expect(Self.minutes(t, Self.at(7), 2, Self.queue(Self.job(printed: 2))).isEmpty) // it moved
        #expect(Self.minutes(t, Self.at(10), 1, Self.queue(Self.job(printed: 2))).isEmpty) // the wait runs from the movement
        #expect(Self.read(t, Self.at(12), Self.queue(Self.job(printed: 2))).count == 1)
        #expect(Self.minutes(t, Self.at(13), 60, Self.queue(Self.job(printed: 2))).isEmpty) // the same episode, however long
    }

    @Test func flickerIsNotProgressAndDoesntHideAHungJob() {
        // A state going back and forth, a count going down and up again: never past what was already seen.
        func flip(_ i: Int) -> JobState { i % 2 == 0 ? .processing : .pending }
        func wobble(_ i: Int) -> Int { i % 2 == 0 ? 3 : 2 }
        let t = Self.tracker()
        for i in 0..<5 { #expect(Self.read(t, Self.at(Double(i)), Self.queue(Self.job(7,flip(i), printed: wobble(i)))).isEmpty) }
        #expect(Self.read(t, Self.at(5), Self.queue(Self.job(7,flip(5), printed: wobble(5)))).count == 1)
        for i in 6..<120 { #expect(Self.read(t, Self.at(Double(i)), Self.queue(Self.job(7,flip(i), printed: wobble(i)))).isEmpty) }
    }

    @Test func aFlappingJobWithRealProgressEachTimeIsToldThreeTimesAtMost() {
        let t = Self.tracker()
        let told = (0..<10).flatMap { round in Self.minutes(t, Self.at(Double(round * 7)), 6, Self.queue(Self.job(printed: round))) }
        #expect(told.count == 3)
        #expect(told.allSatisfy { $0.kind == .jobStuck })
    }

    @Test func theCapIsOneSettingAndSoAreTheWaits() {
        let rules = Self.rules {
            $0.jobMaxStuckAlerts = 1
            $0.jobStuckAfter = 2 * 60
            $0.jobHungAfter = 4 * 60
        }
        let t = Self.tracker(rules)
        let a = Self.minutes(t, Self.t0, 3, Self.queue(Self.job(printed: 0)))
        #expect(a.count == 1 && a[0].body.contains("2 minutes"))
        #expect(Self.minutes(t, Self.at(4), 30, Self.queue(Self.job(printed: 1))).isEmpty)
        let u = Self.tracker(rules)
        let b = Self.minutes(u, Self.t0, 5, Self.queue(Self.job()), Self.printing)
        #expect(b.count == 1 && b[0].body.contains("4 minutes"))
        let defaults = AlertRules()
        #expect(defaults.jobStuckAfter == 5 * 60 && defaults.jobHungAfter == 15 * 60 && defaults.jobMaxStuckAlerts == 3)
    }

    @Test func theSameEpisodeDoesntTellAgainAcrossARestartAndProgressWhileAwayDoes() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 6, Self.queue(Self.job(printed: 3))).count == 1)

        let same = AlertTracker(rules: t.rules, shown: t.shown(), timeZone: Self.zone)
        #expect(Self.minutes(same, Self.t0.addingTimeInterval(86_400), 60, Self.queue(Self.job(printed: 3))).isEmpty)

        let moved = AlertTracker(rules: t.rules, shown: t.shown(), timeZone: Self.zone)
        #expect(Self.minutes(moved, Self.t0.addingTimeInterval(86_400), 30, Self.queue(Self.job(printed: 4))).count == 1) // it went on while the app was closed, then stopped
    }

    @Test func theCapSurvivesARestart() {
        var t = Self.tracker()
        var told = 0
        for round in 0..<3 {
            told += Self.minutes(t, Self.t0.addingTimeInterval(Double(round) * 86_400), 6, Self.queue(Self.job(printed: round))).count
            t = AlertTracker(rules: t.rules, shown: t.shown(), timeZone: Self.zone)
        }
        #expect(told == 3)
        #expect(Self.minutes(t, Self.t0.addingTimeInterval(5 * 86_400), 30, Self.queue(Self.job(printed: 50))).isEmpty)
    }

    /// Windows' Restarted bit; on the Mac, a job CUPS had given up on (`aborted`) back in the queue: someone restarted it.
    @Test func aRestartedJobStartsAgainItsPagesCountAsMovingAndItMayBeToldAgain() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 6, Self.queue(Self.job(printed: 5))).count == 1)
        #expect(Self.read(t, Self.at(6.5), Self.queue(Self.job(7,.aborted, printed: 5))).isEmpty)
        // Someone restarted it: the count starts over, below where it had been.
        var told = Self.read(t, Self.at(7), Self.queue(Self.job(7,.processing, printed: 0)))
        for i in 1...4 { told += Self.minutes(t, Self.at(Double(7 + i * 4)), 3, Self.queue(Self.job(7,.processing, printed: i))) }
        #expect(told.isEmpty)
        #expect(Self.minutes(t, Self.at(30), 6, Self.queue(Self.job(7,.processing, printed: 4))).count == 1)
    }

    @Test func failedIsOncePerJobAndToldEvenAfterStuck() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 6, Self.queue(Self.job())).map(\.kind) == [.jobStuck])
        #expect(Self.minutes(t, Self.at(7), 10, Self.queue(Self.job(7,.stopped))).map(\.kind) == [.jobFailed])
        #expect(Self.minutes(t, Self.at(18), 2, Self.queue(Self.job(7,.processing))).isEmpty)
        #expect(Self.minutes(t, Self.at(21), 30, Self.queue(Self.job(7,.stopped))).isEmpty)
    }

    @Test func afterAFailureStuckNeedsRealProgressToo() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).map(\.kind) == [.jobFailed])
        #expect(Self.minutes(t, Self.at(4), 30, Self.queue(Self.job())).isEmpty) // the error went, the job didn't move
        #expect(Self.minutes(t, Self.at(35), 6, Self.queue(Self.job(printed: 1))).map(\.kind) == [.jobStuck])
    }

    @Test func aResubmittedJobIsANewJobAndMayFailAgain() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(9, .stopped))).count == 1)
        #expect(Self.minutes(t, Self.at(4), 3, Self.queue(Self.job(10, .stopped, submitted: Self.submitted.addingTimeInterval(240)))).count == 1)
    }

    @Test func aPauseEndsTheEpisodeWithoutUsingUpTheCap() {
        let t = Self.tracker()
        t.pausedUntil = Self.at(10)
        #expect(Self.minutes(t, Self.t0, 6, Self.queue(Self.job(printed: 1))).isEmpty)
        #expect(Self.minutes(t, Self.at(11), 20, Self.queue(Self.job(printed: 1))).isEmpty) // still the one nobody was told about: it stays quiet
        let told = (2..<10).reduce(0) { n, round in n + Self.minutes(t, Self.t0.addingTimeInterval(Double(round) * 3600), 6, Self.queue(Self.job(printed: round))).count }
        #expect(told == 3)
    }

    @Test func aRestartDoesntTellAgainAndKeepsNoDocumentName() throws {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped, name: "Secret merger plan.pdf"))).count == 1)
        let remembered = t.shown()

        // The state file holds these: the job's id and time, nothing about the document or who printed it.
        let saved = String(decoding: try JSONEncoder().encode(remembered), as: UTF8.self)
        #expect(!saved.contains("Secret") && !saved.contains("merger") && !saved.contains("gabri"))
        let lines = try #require(remembered[Self.laser])
        try #require(lines.count == 1)
        let parts = lines[0].split(separator: "|", omittingEmptySubsequences: false)
        #expect(parts.count == 10 && parts[0] == "Job" && parts[1] == "7" && parts[3] == "1" && parts[4] == "0", "\(lines[0])")
        #expect(parts.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }, "\(lines[0])")

        let next = AlertTracker(rules: Self.rules(), shown: remembered, timeZone: Self.zone)
        #expect(Self.minutes(next, Self.t0.addingTimeInterval(86_400), 30, Self.queue(Self.job(7,.stopped, name: "Secret merger plan.pdf"))).isEmpty)
        #expect(next.shown()[Self.laser]?.count == 1)
    }

    @Test func aRememberedJobThatTurnsOutToBeGoneIsForgottenAfterTheClearHold() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).count == 1)
        let next = AlertTracker(rules: Self.rules(), shown: t.shown(), timeZone: Self.zone)
        let day = Self.t0.addingTimeInterval(86_400)
        #expect(Self.minutes(next, day, 9, Self.queue()).isEmpty)
        #expect(next.shown()[Self.laser]?.count == 1)
        #expect(Self.minutes(next, Self.at(10, from: day), 1, Self.queue()).isEmpty)
        #expect(next.shown().isEmpty)
    }

    @Test func aJobAReadMissedForAMomentIsntToldAgain() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).count == 1)
        #expect(Self.read(t, Self.at(4), Self.queue()).isEmpty)
        #expect(Self.minutes(t, Self.at(5), 5, Self.queue(Self.job(7,.stopped))).isEmpty)
    }

    /// The Mac's own (Windows counts the first read without a job as the queue moving): a job missing from one read hasn't
    /// left, so neither its own wait nor the wait of a job behind it starts again; missing from two reads in a row, it left
    /// when it was first missed.
    @Test func aJobOneReadMissesDoesntStartTheStuckWaitAgain() {
        let mine = Self.job(2, .processing, name: "Mine.pdf")
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(mine)).isEmpty)
        #expect(Self.read(t, Self.at(4), Self.queue()).isEmpty)
        #expect(Self.read(t, Self.at(5), Self.queue(mine)).map(\.kind) == [.jobStuck])

        let theirs = Self.job(1, .processing, owner: "alex", submitted: Self.submitted.addingTimeInterval(-300))
        let behind = Self.job(2, .pending, name: "Mine.pdf")
        let u = Self.tracker()
        #expect(Self.minutes(u, Self.t0, 3, Self.queue(theirs, behind)).isEmpty)
        #expect(Self.read(u, Self.at(4), Self.queue(behind)).isEmpty) // not yet known to have left: nothing decided stuck
        #expect(Self.read(u, Self.at(5), Self.queue(theirs, behind)).map(\.kind) == [.jobStuck])
    }

    @Test func aJobIdTheSpoolerUsedAgainIsANewJob() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7, .stopped, name: "First.pdf"))).count == 1)
        // Gone, and at once a new job under the same id. Not even a read in between saw the queue without it.
        let again = Self.job(7, .stopped, name: "Second.pdf", submitted: Self.submitted.addingTimeInterval(2 * 3600))
        let told = Self.minutes(t, Self.at(4), 3, Self.queue(again))
        #expect(told.count == 1 && told[0].title.contains("Second.pdf"))
        #expect(Self.minutes(t, Self.at(8), 10, Self.queue(again)).isEmpty)
        // Across a restart too.
        let next = AlertTracker(rules: Self.rules(), shown: t.shown(), timeZone: Self.zone)
        let day = Self.t0.addingTimeInterval(86_400)
        #expect(Self.minutes(next, day, 3, Self.queue(again)).isEmpty)
        let third = Self.job(7, .stopped, name: "Third.pdf", submitted: Self.submitted.addingTimeInterval(5 * 3600))
        #expect(Self.minutes(next, Self.at(4, from: day), 3, Self.queue(third)).count == 1)
    }

    @Test func aJobWhoseNameChangesWhileItSpoolsIsTheSameJob() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped, name: "Print job"))).count == 1)
        #expect(Self.minutes(t, Self.at(4), 5, Self.queue(Self.job(7,.stopped, name: "Report.pdf"))).isEmpty)
    }

    @Test func turningAlertsOffAndOnKeepsWhatAJobWasTold() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).count == 1)
        let fresh = AlertTracker(rules: t.rules, shown: t.shownJobs(), timeZone: Self.zone) // as the menu bar starts over when alerts are turned on
        #expect(Self.minutes(fresh, Self.at(4), 5, Self.queue(Self.job(7,.stopped))).isEmpty)
    }

    @Test func rememberedJobKeysThatMakeNoSenseAreIgnoredAndBounded() {
        let keys = ["Job|", "Job|x|y", "Job|7", "Job|7|1", "Job|7|1|2", "Job|-1|5|0|0|0|0|0|0|0", "Job||", "Job|7|99999999999999999999999|0|0|0|0|0|0|0",
                    "Job|7|1|0|0|0|0|0|x|0", "Job|7|1|0|-1|0|0|0|0|0", "Job|7|1|0|0|0|0|0|0|0|0", "Job|+7|1|0|0|0|0|0|0|0", "Job|٧|1|0|0|0|0|0|0|0"]
        #expect(AlertTracker(rules: Self.rules(), shown: [Self.laser: keys], timeZone: Self.zone).shown().isEmpty)
        let many = (0..<5000).map { "Job|\($0)|\($0)|1|0|0|0|0|0|0" }
        let kept = AlertTracker(rules: Self.rules(), shown: [Self.laser: many], timeZone: Self.zone).shown()[Self.laser]?.count ?? 0
        #expect((1...256).contains(kept))
    }

    /// Over the cap, the newest told jobs are kept (by when they were submitted), at a restart and when saving: a job told
    /// just now isn't the one forgotten, and told again after the next start.
    @Test func overTheCapTheNewestToldJobsAreKept() throws {
        let old = (0..<300).map { "Job|\($0)|\(1000 + $0)|1|0|0|0|0|0|0" }
        let loaded = try #require(AlertTracker(rules: Self.rules(), shown: [Self.laser: old], timeZone: Self.zone).shown()[Self.laser])
        #expect(loaded.count == 256)
        #expect(loaded.contains { $0.hasPrefix("Job|299|1299|") })
        #expect(!loaded.contains { $0.hasPrefix("Job|0|1000|") })

        let t = AlertTracker(rules: Self.rules(), shown: [Self.laser: Array(old.prefix(256))], timeZone: Self.zone)
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).count == 1)
        let saved = try #require(t.shown()[Self.laser])
        #expect(saved.count == 256)
        #expect(saved.contains { $0.hasPrefix(JobRules.key(Self.job(7,.stopped)) + "|") })
        let next = AlertTracker(rules: Self.rules(), shown: t.shown(), timeZone: Self.zone)
        #expect(Self.minutes(next, Self.at(10), 3, Self.queue(Self.job(7,.stopped))).isEmpty)
    }

    @Test func aQueueThatWentAwayTellsNothingAndHoldsNothing() {
        let t = Self.tracker()
        #expect(Self.read(t, Self.t0, Self.queue(Self.job(7,.stopped))).isEmpty)
        #expect(Self.minutes(t, Self.at(1), 10, nil).isEmpty)
        #expect(t.pendingUntil(Self.laser) == nil)
        #expect(t.shown().isEmpty)
    }

    @Test func removingThePrinterForgetsItsJobs() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).count == 1)
        t.forget(Self.laser)
        #expect(t.shown().isEmpty)
    }

    @Test func jobsDontColorTheMenuBarIcon() {
        let t = Self.tracker()
        #expect(Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped))).count == 1)
        #expect(t.level(Self.laser) == .ok)
        #expect(t.overall == .ok)
        #expect(t.problem(Self.laser) == nil)
    }

    @Test func thePrintersOwnAlertsStillWorkBesideJobAlerts() {
        let t = Self.tracker()
        let jam = PrinterStatus(code: "stopped", message: "Paper jam", severity: .error, alerts: [PrinterAlert(id: "media-jam", severity: .error, message: "Paper jam")])
        let told = Self.minutes(t, Self.t0, 3, Self.queue(Self.job(7,.stopped)), jam)
        let kinds: [AlertKind] = told.map(\.kind).sorted()
        #expect(kinds == [AlertKind.paperJam, AlertKind.jobFailed])
    }

    // MARK: Your own

    @Test(arguments: [
        ("gabri", nil, true), ("GABRI", nil, true), (" gabri ", nil, true), (#"OFFICE\gabri"#, nil, true), (#"office\Gabri"#, nil, true),
        (#"\\OFFICE\gabri"#, nil, false), // not a domain this computer is in
        (#"HOME\gabri"#, nil, false), // same name, someone else's domain
        ("alex", nil, false), ("gabri2", nil, false), ("gab", nil, false), ("", nil, false), ("   ", nil, false),
        ("gabri", #"\\GABRI-PC"#, true), ("gabri", #"\\gabri-pc"#, true), ("gabri", #"\\GABRI-PC.office.lan"#, true), ("gabri", "", true),
        ("gabri", #"\\FRONT-DESK"#, false), // the same user name on another computer sharing the printer
        ("gabri", #"\\10.0.0.5"#, false), // can't tell: not ours to name
    ] as [(String, String?, Bool)])
    func whoseJobItIs(owner: String, machine: String?, mine: Bool) {
        #expect(Self.me.owns(Self.job(owner: owner, machine: machine), othersMayPrint: false) == mine)
    }

    @Test func aUserNameOrMachineThisMacDoesntKnowIsNeverAMatchByAccident() {
        #expect(!JobOwner(userName: "", domain: "OFFICE", machine: "PC").owns(Self.job(owner: "")))
        #expect(!JobOwner(userName: nil, domain: nil, machine: nil).owns(Self.job(owner: "gabri")))
        // Nothing here to compare with: in doubt, not yours (Windows names it; the Mac's user has no domain, and a job from
        // another computer must not pass for this one's).
        #expect(!JobOwner(userName: "gabri", domain: nil, machine: nil).owns(Self.job(owner: #"OFFICE\gabri"#, machine: #"\\PC"#)))
        #expect(!JobOwner(userName: "gabri", domain: nil, machine: nil).owns(Self.job(owner: "gabri", machine: #"\\PC"#)))
    }

    /// The Mac's own: `cupsGetJobs2` never says which computer a job came from, and a Mac sharing its printer gets other
    /// Macs' jobs under the same user name. A job from nowhere known is yours only on a queue no other computer prints to;
    /// one CUPS says came from this Mac (`job-originating-host-name` is localhost) is yours on any queue.
    @Test func aSameNamedUsersJobFromAnotherMacSharingThisQueueIsNeverNamed() throws {
        func dest(_ options: [String: String]) -> CupsDestination {
            CupsDestination(name: "Q", options: ["printer-type": "4", "printer-state": "3", "printer-is-accepting-jobs": "true"].merging(options) { $1 })
        }
        let payroll = Self.job(7, .stopped, name: "Payroll.pdf")
        for shared in [dest(["printer-is-shared": "true"]), dest([:]), dest(["printer-is-shared": "false", "printer-type": "6"])] {
            let t = Self.tracker()
            #expect(Self.minutes(t, Self.t0, 3, JobQueueState.of(shared, jobs: [payroll], now: Self.t0)).isEmpty, "\(shared.options)")
            #expect(t.shown().isEmpty)
        }
        var fromHere = payroll
        fromHere.machine = "localhost"
        let t = Self.tracker()
        let told = Self.minutes(t, Self.t0, 3, JobQueueState.of(dest(["printer-is-shared": "true"]), jobs: [fromHere], now: Self.t0))
        #expect(told.map(\.kind) == [.jobFailed])
        let alone = Self.tracker()
        #expect(Self.minutes(alone, Self.t0, 3, JobQueueState.of(dest(["printer-is-shared": "false"]), jobs: [payroll], now: Self.t0)).count == 1)
    }

    @Test(arguments: [("localhost", true), ("LOCALHOST", true), ("127.0.0.1", true), ("::1", true), ("[::1]", true),
                      ("127.example", false), ("localhost.evil.example", false), ("192.0.2.7", false), ("other-mac.local", false)])
    func aJobCupsSaysCameFromThisMacIsYours(machine: String, mine: Bool) {
        #expect(Self.me.owns(Self.job(machine: machine)) == mine)
        #expect(JobOwner(userName: "gabri").owns(Self.job(machine: machine)) == mine)
    }

    @Test func aLongPcNameMatchesWindowsShortNameForIt() {
        #expect(JobOwner(userName: "gabri", domain: nil, machine: "ACCOUNTING-WORK").owns(Self.job(machine: #"\\ACCOUNTING-WORKSTATION.corp"#)))
    }

    @Test func otherPeoplesJobsOnASharedQueueNeverRaiseOne() {
        let t = Self.tracker()
        let theirs = JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: [
            Self.job(1, .stopped, name: "Their secret.pdf", owner: "alex"),
            Self.job(2, .processing, name: "Their other.pdf", owner: #"HOME\gabri"#, submitted: Self.submitted.addingTimeInterval(60)),
            Self.job(3, .pending, name: "Same name other PC.pdf", submitted: Self.submitted.addingTimeInterval(120), machine: #"\\FRONT-DESK"#),
            Self.job(4, .pending, name: "No owner.pdf", owner: "", submitted: Self.submitted.addingTimeInterval(180)),
        ])
        #expect(Self.minutes(t, Self.t0, 60, theirs).isEmpty)
        #expect(t.shown().isEmpty)
        #expect(t.pendingUntil(Self.laser) == nil)
    }

    @Test func someoneElsesFailedJobAheadOfMineMakesMineStuckNotTheirsTold() throws {
        let t = Self.tracker()
        let told = Self.minutes(t, Self.t0, 10, Self.queue(Self.job(1, .stopped, name: "Theirs.pdf", owner: "alex"),
                                                           Self.job(2, .pending, name: "Mine.pdf", submitted: Self.submitted.addingTimeInterval(60))))
        try #require(told.count == 1)
        #expect(told[0].kind == .jobStuck)
        #expect(told[0].title.contains("Mine.pdf"))
        #expect(!(told[0].title + told[0].body).contains("Theirs"))
    }

    // MARK: The demo's made-up jobs

    private static let demoNow = t0

    /// The demo office MFP's queue (`Demo.queues`): yours printing, alex's waiting.
    private static func demoJobs(owner: String = "gabri") async throws -> [QueueJob] {
        let jobs = try #require(await Demo.queues(now: demoNow).jobs("Office_color_MFP"))
        return jobs.map { j in
            var j = j
            if j.owner == "you" { j.owner = owner }
            return j
        }
    }

    @Test func theDemoQueuePrintingAlongRaisesNothing() async throws {
        let t = Self.tracker()
        let jobs = try await Self.demoJobs()
        let mine = try #require(jobs.first { $0.owner == "gabri" })
        for i in 0..<8 {
            // As the demo's card moves it on, a page each read.
            let moved = jobs.map { j in
                var j = j
                if j.id == mine.id { j.pagesPrinted += i }
                return j
            }
            #expect(Self.read(t, Self.at(Double(i)), JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: moved)).isEmpty)
        }
    }

    @Test func theDemoQueueFrozenRaisesOneForMyFirstJobOnly() async throws {
        let t = Self.tracker()
        let told = Self.minutes(t, Self.t0, 30, JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: try await Self.demoJobs()))
        try #require(told.count == 1)
        #expect(told[0].kind == .jobStuck)
        #expect(told[0].title.contains("Quarterly report.pdf"))
    }

    @Test func theDemoAlexsJobAloneRaisesNothing() async throws {
        let alex = try #require(try await Self.demoJobs().first { $0.owner == "alex" })
        #expect(Self.minutes(Self.tracker(), Self.t0, 30, Self.queue(alex)).isEmpty)
        var failed = alex
        failed.state = .stopped
        #expect(Self.minutes(Self.tracker(), Self.t0, 30, Self.queue(failed)).isEmpty)
    }

    @Test func theDemoFixersStuckJobRaisesOneNamingTheDocumentAndThePrinter() async throws {
        // Its queue is stopped and the printer doesn't answer, as in the demo: the job's own state still tells.
        let fixer = DemoOffline(now: Self.demoNow)
        let destination = try #require(await fixer.destinations()?.first { $0.name == DemoOffline.officeQueue })
        let jobs = try #require(await fixer.jobs(DemoOffline.officeQueue)).map { j in
            var j = j
            j.owner = "gabri"
            return j
        }
        let queue = JobQueueState.of(destination, jobs: jobs, now: Self.demoNow)
        #expect(queue.paused && queue.printerOffline)
        let t = Self.tracker()
        var told: [AlertNotice] = []
        for i in 0..<60 {
            _ = t.observe(PrinterSnapshot(uuid: Demo.officeUuid, name: "Demo office laser", reachable: false, status: nil, supplies: nil), now: Self.at(Double(i)))
            told += t.observeJobs(Demo.officeUuid, printerName: "Demo office laser", queue, me: Self.me, now: Self.at(Double(i)))
        }
        try #require(told.count == 1)
        #expect(told[0].kind == .jobFailed)
        #expect(told[0].title.contains("Invoice 1043.pdf"))
        #expect(told[0].body.contains("Demo office laser"))
    }

    @Test func theDemoFixersStuckJobHeldBySomeoneElseRaisesNothing() async throws {
        let jobs = try #require(await DemoOffline(now: Self.demoNow).jobs(DemoOffline.officeQueue)).map { j in
            var j = j
            j.owner = "alex"
            return j
        }
        #expect(Self.minutes(Self.tracker(), Self.t0, 30, JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: jobs)).isEmpty)
    }

    // MARK: The document's name

    private static func failed(_ name: String, printer: String = printerName) throws -> AlertNotice {
        let t = tracker()
        #expect(t.observeJobs(laser, printerName: printer, queue(job(7,.stopped, name: name)), me: me, now: t0).isEmpty)
        let told = t.observeJobs(laser, printerName: printer, queue(job(7,.stopped, name: name)), me: me, now: at(1))
        try #require(told.count == 1)
        return told[0]
    }

    /// Lone surrogates can't be in a Swift string: they arrive as U+FFFD from the bytes, as here.
    static let hostile: [String] = [
        "<script>alert(1)</script>.pdf",
        "</text><action content=\"Run\" arguments=\"x\"/><text>.pdf",
        "a&b&amp;c\"'.pdf",
        "]]><!--.pdf",
        "\u{1}\u{2}\u{8}\u{b}\u{c}\u{1f} bell\u{7}.pdf",
        String(decoding: [0xD83D] + Array(" lone high.pdf".utf16), as: UTF16.self),
        String(decoding: Array("lone low ".utf16) + [0xDE00] + Array(".pdf".utf16), as: UTF16.self),
        "\u{FFFF}\u{FFFE} not chars.pdf",
        "line one\r\nFake second line\nthird.pdf",
        "evil\u{202E}gnp.exe",
        "zero\u{200B}width\u{200D}\u{FEFF}.pdf",
        "para\u{2028}sep\u{2029}.pdf",
        "{toast.binding}.pdf",
        #"%TEMP%\$(calc).pdf"#,
    ]

    @Test(arguments: JobAlertTests.hostile)
    func aHostileDocumentNameMakesATitleWithNothingThatLiesAboutItself(name: String) throws {
        let n = try Self.failed(name)
        let banned: Set<UInt32> = [0x202E, 0x200B, 0x200D, 0xFEFF, 0x2028, 0x2029, 0xFFFF, 0xFFFE]
        for s in n.title.unicodeScalars {
            #expect(!(s.properties.generalCategory == .control || banned.contains(s.value)), "U+\(String(s.value, radix: 16)) left in the title")
        }
        #expect(!n.title.contains("\n"))
    }

    @Test func markupShowsAsTheTextItIs() throws {
        #expect(try Self.failed("<b>Report</b> & co.pdf").title.contains("<b>Report</b> & co.pdf"))
    }

    @Test func aVeryLongNameIsCutToFitABalloonsTitle() throws {
        let n = try Self.failed(String(repeating: "x", count: 100_000) + ".pdf")
        #expect(n.title.utf16.count <= 63, "\(n.title)")
        #expect(n.title.contains("…"))
    }

    @Test func cuttingNeverSplitsACharacter() {
        // Emoji (a surrogate pair) and an accent as its own mark, around the cut.
        for name in [String(repeating: "a", count: AlertText.maxDocument - 2) + "😀😀😀😀",
                     String(repeating: "a", count: AlertText.maxDocument - 2) + "e\u{301}e\u{301}e\u{301}"] {
            let shown = AlertText.document(name)
            #expect(shown.utf16.count <= AlertText.maxDocument)
            #expect(shown.hasSuffix("…"))
            let beforeEllipsis = shown.dropLast().last
            #expect(beforeEllipsis != "e") // "é" whole or not at all
            #expect(beforeEllipsis.map { $0.unicodeScalars.allSatisfy { $0.properties.generalCategory != .surrogate } } ?? true)
        }
    }

    @Test(arguments: [
        (nil, "Untitled"), ("", "Untitled"), ("    ", "Untitled"), ("\u{1}\u{2}\u{200B}", "Untitled"),
        ("Report.pdf", "Report.pdf"), ("  Two   spaces  .pdf ", "Two spaces .pdf"),
        (#"C:\Users\gabri\Taxes\2026\return.pdf"#, "return.pdf"), (#"\\server\share\Payroll\march.xlsx"#, "march.xlsx"),
        ("C:/Users/gabri/return.pdf", "return.pdf"), ("/Users/gabri/Taxes/return.pdf", "return.pdf"), ("~/Documents/return.pdf", "return.pdf"),
        ("https://bank.example/statements/oct.pdf?token=abc123#page=2", "oct.pdf"), ("https://bank.example/", "bank.example"),
        ("file:///Users/gabri/Taxes/return.pdf", "return.pdf"),
        ("Microsoft Word - Budget: draft/2.docx", "Microsoft Word - Budget: draft/2.docx"), // a title, not a path
        (#"Microsoft Word - C:\Users\gabri\Taxes\return.docx"#, "Microsoft Word - return.docx"), // a title holding a path
        (#"Notepad - \\server\share\Payroll\oct.txt"#, "Notepad - oct.txt"),
        ("Ñandú año 2026.pdf", "Ñandú año 2026.pdf"), ("報告書.pdf", "報告書.pdf"),
    ] as [(String?, String)])
    func whatANotificationCallsADocument(name: String?, shown: String) { #expect(AlertText.document(name) == shown) }

    @Test func aHostilePrintersNameIsMadeSafeToo() throws {
        let n = try Self.failed("Report.pdf", printer: "Front\u{7} desk\r\n<inkjet>\u{202E}" + String(repeating: "y", count: 500))
        #expect(!n.printerName.unicodeScalars.contains { [0x7, 0xD, 0xA, 0x202E].contains($0.value) })
        #expect(n.printerName.utf16.count <= AlertText.maxPrinter)
        #expect(n.body.hasPrefix(n.printerName))
    }

    @Test func theDocumentNeverTravelsInTheJobKey() throws {
        let n = try Self.failed("Secret merger plan.pdf")
        #expect(n.jobKey?.contains("Secret") == false)
    }

    // MARK: The Mac's own: CUPS's job list

    @Test func aQueueReadsPausedAndOfflineFromCups() {
        let stopped = CupsDestination(name: "Q", options: ["device-uri": "usb://Demo/Laser", "printer-type": "4", "printer-state": "5",
                                                           "printer-state-reasons": "paused"])
        let state = JobQueueState.of(stopped, jobs: [], now: Self.t0)
        #expect(state.paused && !state.printerOffline)
        let off = CupsDestination(name: "Q", options: ["device-uri": "usb://Demo/Laser", "printer-type": "4", "printer-state": "3",
                                                       "printer-state-reasons": "offline-report", "printer-is-accepting-jobs": "true"])
        let offState = JobQueueState.of(off, jobs: [], now: Self.t0)
        #expect(!offState.paused && offState.printerOffline)
        let running = CupsDestination(name: "Q", options: ["device-uri": "usb://Demo/Laser", "printer-type": "4", "printer-state": "4",
                                                           "printer-state-reasons": "none", "printer-is-accepting-jobs": "true"])
        let runningState = JobQueueState.of(running, jobs: [], now: Self.t0)
        #expect(!runningState.paused && !runningState.printerOffline)
    }

    /// CUPS keeps finished jobs in its history: a printed or cancelled one has left the queue as on Windows, and a job CUPS
    /// gave up on stays to be told only while it's recent (an old failure is no news at launch).
    @Test func finishedJobsLeaveTheQueueAndAnOldFailureIsNoNews() {
        let d = CupsDestination(name: "Q", options: ["printer-type": "4", "printer-state": "3", "printer-is-accepting-jobs": "true"])
        var printed = Self.job(1, .completed)
        printed.finished = Self.at(-1)
        var cancelled = Self.job(2, .canceled)
        cancelled.finished = Self.at(-1)
        var gaveUp = Self.job(3, .aborted)
        gaveUp.finished = Self.at(-3)
        var oldFailure = Self.job(4, .aborted)
        oldFailure.finished = Self.at(-60 * 24)
        let kept = JobQueueState.of(d, jobs: [printed, cancelled, gaveUp, oldFailure, Self.job(5, .pending), Self.job(6, .held)], now: Self.t0)
        #expect(kept.jobs.map(\.id) == [3, 5, 6])

        let t = Self.tracker()
        let told = Self.minutes(t, Self.t0, 3, JobQueueState(paused: false, printerOffline: false, othersMayPrint: false, jobs: [gaveUp]))
        #expect(told.map(\.kind) == [.jobFailed])
        #expect(told.first?.body.contains("macOS gave up on this job") == true)
    }

    /// A job CUPS gave up on that doesn't say when is no news either: it may be from any time in CUPS's history.
    @Test func aFailureWithNoFinishTimeIsNoNews() {
        let d = CupsDestination(name: "Q", options: ["printer-type": "4", "printer-state": "3", "printer-is-accepting-jobs": "true",
                                                     "printer-is-shared": "false"])
        let undated = Self.job(3, .aborted)
        #expect(JobQueueState.of(d, jobs: [undated, Self.job(5, .pending)], now: Self.t0).jobs.map(\.id) == [5])
        #expect(Self.minutes(Self.tracker(), Self.t0, 3, JobQueueState.of(d, jobs: [undated], now: Self.t0)).isEmpty)
    }

    /// cupsGetJobs2 gives no page counts: a job only moves by its size, its state or a job leaving. So a long job on a
    /// printer saying it's printing raises one "may be stuck" after 15 minutes (the roadmap's accepted false alert), and
    /// a job whose size still grows doesn't.
    @Test func withoutPageCountsALongJobOnAPrintingPrinterRaisesOneMayBeStuck() {
        let t = Self.tracker()
        let told = Self.minutes(t, Self.t0, 60, Self.queue(Self.job(pages: nil, bytes: 2_048_000)), Self.printing)
        #expect(told.map(\.title) == ["“Report.pdf” may be stuck"])

        let growing = Self.tracker()
        for i in 0..<60 {
            #expect(Self.read(growing, Self.at(Double(i)), Self.queue(Self.job(pages: nil, bytes: Int64(1024 * (100 + i)))), Self.printing).isEmpty)
        }
    }

    @Test func aStoppedJobsReasonSaysMacOSStoppedIt() throws {
        #expect(try Self.failed("Report.pdf").body == "Office laser: macOS stopped this job. Open the queue to cancel it or print it again.")
    }

    @Test func aJobKeyIsTheSameWhateverTheTimeZoneAndChangesWithTheTime() {
        let j = Self.job()
        var later = j
        later.submitted = j.submitted.addingTimeInterval(0.001)
        #expect(JobRules.key(j) != JobRules.key(later))
        #expect(JobRules.isKey(JobRules.key(j)))
        #expect(JobRules.key(j) == "Job|7|\(Int64(Self.submitted.timeIntervalSince1970) * 1000)")
    }

    @Test func theJobAlertsSettingIsOffByDefaultAndReachesTheRules() throws {
        #expect(!AlertSettings().jobAlerts)
        #expect(!AlertSettings().rules.jobs)
        var s = AlertSettings()
        s.jobAlerts = true
        #expect(s.rules.jobs)
        let old = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"alerts":true}"#.utf8)) // a file from before 3.4
        #expect(!old.jobAlerts)
        let back = try JSONDecoder().decode(AlertSettings.self, from: try JSONEncoder().encode(s))
        #expect(back.jobAlerts)
    }

    @Test func theSettingsNoteNamesTheWaitsAndTheCap() {
        let note = AlertRules().jobsNote
        #expect(note.hasPrefix("Naming the document and the printer: macOS stops or gives up on the job, or it hasn't moved for 5 minutes while the printer is ready, or 15 minutes while the printer says it's printing"))
        #expect(note.contains("at most 3 times"))
        #expect(note.contains("if macOS shows notifications there"))
    }

    // MARK: The Mac's own: the job read (IPP Get-Jobs over cupsd's socket) and the notifications

    /// cupsd's own answer for a job this Mac sent (seen on ignia-mac, 2026-11-05): its user, `localhost` as where it came from,
    /// times in seconds since 1970, its size in kilobytes.
    @Test func aGetJobsGroupReadsAsAQueueJob() throws {
        let job = try #require(QueueJobAttributes.job([
            "job-id": "22", "job-name": "Broken file.pdf", "job-state": "6", "job-originating-user-name": "gabri",
            "job-originating-host-name": "localhost", "time-at-creation": "1793832499", "job-k-octets": "2", "job-media-sheets-completed": "1",
        ]))
        #expect(job.id == 22)
        #expect(job.name == "Broken file.pdf")
        #expect(job.state == .stopped)
        #expect(job.owner == "gabri")
        #expect(job.machine == "localhost")
        #expect(job.submitted == Date(timeIntervalSince1970: 1_793_832_499))
        #expect(job.finished == nil)
        #expect(job.bytes == 2048)
        #expect(job.pagesPrinted == 1)
        #expect(job.pages == nil)
        #expect(Self.me.owns(job, othersMayPrint: true)) // localhost: this Mac's, even on a shared queue

        let aborted = try #require(QueueJobAttributes.job(["job-id": "23", "job-state": "8", "time-at-creation": "1793832400",
                                                           "time-at-completed": "1793832460"]))
        #expect(aborted.state == .aborted)
        #expect(aborted.finished == Date(timeIntervalSince1970: 1_793_832_460))
        #expect(aborted.name == AlertText.untitled) // another user's job: cupsd hides its name
        #expect(aborted.owner.isEmpty)
    }

    @Test(arguments: [
        ["job-state": "5", "time-at-creation": "1"], // no id
        ["job-id": "0", "job-state": "5"], ["job-id": "-4", "job-state": "5"], ["job-id": "x", "job-state": "5"],
        ["job-id": "9"], ["job-id": "9", "job-state": "2"], ["job-id": "9", "job-state": "10"], // no state, or not a job state
    ])
    func aJobWithoutAnIdOrAStateIsLeftOut(attributes: [String: String]) {
        #expect(QueueJobAttributes.job(attributes) == nil)
    }

    @Test func hostileNumbersAreKeptInRange() throws {
        let job = try #require(QueueJobAttributes.job([
            "job-id": "9", "job-state": "5", "job-k-octets": "99999999999999999999", "job-media-sheets-completed": "-3",
            "time-at-creation": "-5", "time-at-completed": "abc", "job-name": String(repeating: "x", count: 10_000),
        ]))
        #expect(job.bytes == 0) // not a number it can hold
        #expect(job.pagesPrinted == 0)
        #expect(job.submitted == Date(timeIntervalSince1970: 0))
        #expect(job.finished == nil)
        #expect(job.name.count == QueueJobAttributes.maxName)
        #expect(QueueJobAttributes.job(["job-id": "9", "job-state": "5", "job-k-octets": "4194304"])?.bytes == 4_294_967_296)
    }

    @Test func itAsksForWhatJobAlertsUseAndNothingElse() {
        #expect(QueueJobAttributes.requested == [
            "job-id", "job-name", "job-state", "job-originating-user-name", "job-originating-host-name", "time-at-creation",
            "time-at-completed", "job-k-octets", "job-media-sheets-completed",
        ])
    }

    private static func jobNotice(_ key: String, _ title: String = "“Report.pdf” didn't print") -> AlertNotice {
        AlertNotice(uuid: laser, printerName: printerName, kind: .jobFailed, title: title, body: "\(printerName): macOS stopped this job.", jobKey: key)
    }

    private static let jam = AlertNotice(uuid: laser, printerName: printerName, kind: .paperJam, title: "Paper jam", body: "Clear it.")

    /// Windows' `AlertToasts.PerPrinter`: a job's notification is its own, beside the printers' alerts.
    @Test func aJobGetsANotificationOfItsOwnBesideThePrintersAlertAndNeitherReplacesTheOther() {
        let a = Self.jobNotice("Job|1|1"), b = Self.jobNotice("Job|2|2")
        let split = JobNotices.split([a, Self.jam, b])
        #expect(split.printers == [Self.jam])
        #expect(split.jobs == [[a], [b]])
        #expect(JobNotices.text([a]) == (a.title, a.body))
    }

    @Test func manyJobsFromOnePrinterAtOnceShareANotification() {
        let jobs = (1...12).map { Self.jobNotice("Job|\($0)|\($0)", "“File \($0).pdf” didn't print") }
        let other = AlertNotice(uuid: "other", printerName: "Inkjet", kind: .jobStuck, title: "“A.pdf” isn't moving", body: "…", jobKey: "Job|3|3")
        let split = JobNotices.split(jobs + [other])
        #expect(split.printers.isEmpty)
        #expect(split.jobs.count == 2)
        #expect(split.jobs[0].count == 12)
        let (title, text) = JobNotices.text(split.jobs[0])
        #expect(title == "12 print jobs need attention")
        #expect(text.split(separator: "\n").count == 4)
        #expect(text.hasSuffix("and 9 more"))
        #expect(split.jobs[1] == [other])
        #expect(JobNotices.split(Array(jobs.prefix(3))).jobs.count == 3) // up to three, each its own
    }

    /// Demo mode's made-up jobs (`--report --jobs`): the demo fixer's stopped invoice is yours and fails; the office MFP's
    /// job printing and alex's waiting raise nothing in the first minutes.
    @Test func theDemoQueuesTellOnlyYourStoppedJob() async throws {
        let demo = DemoOffline(now: Self.t0, delay: .zero)
        let me = JobOwner(userName: demo.user, machine: "demo-mac")
        let t = Self.tracker()
        var told: [AlertNotice] = []
        for minute in [0.0, 2] {
            let now = Self.at(minute)
            for d in try #require(await demo.destinations()) where CupsQueues.isRealQueue(d) {
                let jobs = try #require(await demo.alertJobs(d.name))
                told += t.observeJobs(CupsQueues.id(for: d.name), printerName: d.displayName, JobQueueState.of(d, jobs: jobs, now: now), me: me, now: now)
            }
        }
        #expect(told.map(\.title) == ["“Invoice 1043.pdf” didn't print"])
        #expect(told.first?.printerName == "Demo office laser")
    }
}
