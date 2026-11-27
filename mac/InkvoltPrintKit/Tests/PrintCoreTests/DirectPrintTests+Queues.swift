import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Ported from DirectPrintTests.Queues.cs: roadmap 2.1's last uses of a queue: Batch print (2.4) a job per file straight to the
/// printer (`DirectBatchQueue`), job alerts (3.4) on the printer's own job list (`DirectJobWatch`), and the one route decision
/// (`PrintRouter`, `RoutedBatchQueue`, `RoutedJobQueue`). Left out: the command line's printer (BatchPrinterLookup and
/// The_state_file_gives_the_command_line_…: the Mac's `print` command prints to a macOS queue, PLAN P12 2.1). Mac differences:
/// a direct printer's job list says no other computer prints there, so a job that doesn't say where it came from is yours as
/// on Windows (`DirectJobWatch`); a queue that doesn't work is one macOS can't use (`PrintRoutes.queueWorks`).
extension DirectPrintTests {
    // ---- batch print ----

    /// What the fake drawing was given, and whether it reached the point of no return.
    struct SentJob: Sendable {
        var name: String
        var request: DirectPrintRequest
        var drawn: Int
        var sending: Bool
    }

    /// The jobs the fake drawing was given.
    final class SentJobs: Sendable {
        private let list = Mutex<[SentJob]>([])
        func add(_ job: SentJob) { list.withLock { $0.append(job) } }
        var all: [SentJob] { list.withLock { $0 } }
        var names: [String] { all.map(\.name) }
    }

    typealias Act = @Sendable (_ name: String, _ send: @escaping @Sendable () -> Void, _ stop: BatchStop) async throws -> Void

    static let readyPrinter: @Sendable ([UInt8]) -> [UInt8] = { _ in printer { b in b.enums("printer-state", 3); b.kw("printer-state-reasons", "none") } }

    static func client(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) -> IppClient {
        IppClient(DeviceHttp(host: "192.0.2.11", transport: Answering(answer)), endpoint: URL(string: "http://192.0.2.11:631/ipp/print")!)
    }

    /// A batch to the printer with `caps()`, its jobs drawn by a fake: `act` decides, by file name, what happens once the pages
    /// are drawn (throw before or after the point of no return); by default the job goes.
    static func directBatch(_ act: Act? = nil, printer: (@Sendable ([UInt8]) -> [UInt8])? = nil, caps: IppPrintCaps? = nil)
        -> (queue: DirectBatchQueue, sent: SentJobs) {
        let sent = SentJobs()
        let c = caps ?? Self.caps()
        let queue = DirectBatchQueue("Office inkjet", ipp: client(printer ?? readyPrinter), caps: IppCapsCache({ c })) { document, job, request, _, onSending, stop in
            var drawn = 0
            for page in job.pages {
                try stop.check()
                _ = try await document.render(page, stop)
                drawn += 1
            }
            let sending = Atomic(false)
            let send: @Sendable () -> Void = {
                onSending()
                sending.store(true, ordering: .releasing)
            }
            defer { sent.add(SentJob(name: job.name, request: request, drawn: drawn, sending: sending.load(ordering: .acquiring))) }
            if let act { try await act(job.name, send, stop) } else { send() }
        }
        return (queue, sent)
    }

    static func lines(_ folder: BatchFolder, _ queue: any BatchQueue, _ files: [(String, String, BatchPrintSettings)]) async throws -> [BatchPrintLine] {
        let info = try await queue.read()
        var lines: [BatchPrintLine] = []
        for (name, text, settings) in files {
            let path = folder.file(name, text)
            lines.append(BatchPrintLine(path, settings, try await BatchMeasurer.measure(path, offered: nil, FakeDocuments(), ask: nil), info))
        }
        return lines
    }

    static func run(_ lines: [BatchPrintLine], _ queue: any BatchQueue, options: BatchPrintOptions = BatchPrintOptions(), _ stop: BatchStop = BatchStop()) async -> BatchPrintSummary {
        await BatchPrintRunner.run(lines, queue, FakeDocuments(), options: options, stop)
    }

    static let one = BatchPrintSettings()

    @Test func aBatchGoesToThePrinterAJobPerFileWithItsCopiesSideAndPaper() async throws {
        let folder = BatchFolder()
        let (queue, sent) = Self.directBatch()
        let info = try #require(try await queue.read())
        #expect(info.name == "Office inkjet")
        #expect(info.canTwoSided)
        #expect(info.defaultPaper == "na_letter_8.5x11in")
        #expect(info.papers.map(\.key) == ["na_letter_8.5x11in", "iso_a4_210x297mm", "na_index-4x6_4x6in"]) // letter once, bordered
        let none = DirectBatchQueue("x", ipp: Self.client { _ in [] }, caps: IppCapsCache({ IppPrintCaps() })) { _, _, _, _, _, _ in }
        #expect(try await none.read() == nil) // no raster format: nothing to print through

        let lines = try await Self.lines(folder, queue, [
            ("1 report.pdf", "pages=3", Self.one),
            ("2 form.pdf", "pages=3", BatchPrintSettings(copies: 2, twoSided: true, paper: "iso_a4_210x297mm")),
            ("3 photo.jpg", "pages=1", BatchPrintSettings(range: "1")),
        ])
        let summary = await Self.run(lines, queue)
        #expect(summary.exitCode == BatchPrintSummary.done)
        let jobs = sent.all
        #expect(jobs.map(\.name) == ["1 report.pdf", "2 form.pdf", "3 photo.jpg"])
        var a4 = DirectPrintRequest(copies: 2, twoSided: true)
        a4.paperName = "iso_a4_210x297mm"
        #expect(jobs[1].request == a4)
        #expect(jobs[0].request == DirectPrintRequest()) // the printer's default paper
        #expect(jobs.map(\.drawn) == [3, 3, 1])
        #expect(summary.items.map(\.sheetsSent) == [3, 4, 1]) // two copies of three pages on both sides: 2 sheets each
        // The plan the drawing will make keeps what was asked: the printer collates the copies itself, on A4, both sides.
        let plan = try DirectPrintPlan.choose(Self.caps(), jobs[1].request).get()
        #expect(plan.copies == 2 && plan.repeatCount == 1 && plan.twoSided && plan.paper.name == "iso_a4_210x297mm")
    }

    @Test func aSettingThePrinterCantKeepFailsThatFileWithNothingDrawnAndTheRestPrint() async throws {
        let folder = BatchFolder()
        let (queue, sent) = Self.directBatch()
        let lines = try await Self.lines(folder, queue, [
            ("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=1", BatchPrintSettings(paper: "iso_a4_210x297mm")), ("c.pdf", "pages=1", Self.one),
        ])
        // The printer's A4 went between the estimate and the print (a tray taken out): the line still lists it.
        let (changed, sentAfter) = Self.directBatch(caps: Self.caps { $0.papers.removeAll { $0.name == "iso_a4_210x297mm" } })
        let summary = await Self.run(lines, changed)
        #expect(summary.items.map(\.state) == [.sent, .failed, .sent])
        #expect(summary.items[1].message.contains(DirectPrintProblem.noPaper.message))
        #expect(!summary.items[1].mayHaveSent)
        #expect(sentAfter.names == ["a.pdf", "c.pdf"]) // b was never drawn
        #expect(summary.stoppedAt == nil)
        #expect(sent.names.isEmpty)
    }

    static var aborted: String { loc("The printer stopped the job: {0}", loc("it couldn't read the pages")) }

    @Test func aJobThePrinterStoppedStopsTheBatchAndIsNeverSentAgain() async throws {
        let folder = BatchFolder()
        let aborted = Self.aborted
        let (queue, _) = Self.directBatch { name, send, _ in
            send()
            if name == "b.pdf" { throw DirectPrintError(aborted, mayHavePrinted: true) }
        }
        let lines = try await Self.lines(folder, queue, [("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=2", Self.one), ("c.pdf", "pages=1", Self.one)])
        let summary = await Self.run(lines, queue)
        #expect(summary.items.map(\.state) == [.sent, .failed, .stopped])
        #expect(summary.items[1].mayHaveSent)
        #expect(!summary.items[1].stillToSend) // Print again leaves it alone
        #expect(summary.items[2].stillToSend)
        #expect(summary.stoppedAt == 1)
        #expect(summary.text.contains(aborted + ". ")) // a sentence in the summary, as a queue's reason is
        #expect(summary.exitCode == BatchPrintSummary.stopped)

        // Print again: only c goes.
        let again = await Self.run([lines[2]], Self.directBatch().queue)
        #expect(again.items.map(\.state) == [.sent])
    }

    @Test func aPrinterThatRefusesAJobOrStopsAnsweringSaysWhetherItMayHaveIt() async throws {
        let folder = BatchFolder()
        let busyWords = DirectJob.refused(0x0507)
        // Refused as it came in (busy): nothing printed, the batch stops and Print again sends it.
        let (busy, _) = Self.directBatch { name, send, _ in
            send()
            if name == "b.pdf" { throw DirectPrintError(busyWords, mayHavePrinted: false) }
        }
        let lines = try await Self.lines(folder, busy, [("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=1", Self.one), ("c.pdf", "pages=1", Self.one)])
        var summary = await Self.run(lines, busy)
        #expect(summary.items.map(\.state) == [.sent, .stopped, .stopped])
        #expect(summary.items[1].stillToSend)
        #expect(summary.stopReason == busyWords)

        // Refused before anything went (the drawing found fewer pages): that file fails, the batch goes on.
        let (drawn, _) = Self.directBatch { name, send, _ in
            if name == "b.pdf" { throw DirectPrintError("Fewer pages.", mayHavePrinted: false) }
            send()
        }
        summary = await Self.run(lines, drawn)
        #expect(summary.items.map(\.state) == [.sent, .failed, .sent])
        #expect(!summary.items[1].mayHaveSent)

        // No answer while reading what the printer takes: nothing sent, the batch stops.
        let drew = Atomic(false)
        let mute = DirectBatchQueue("x", ipp: Self.client { _ in Self.printer { b in b.enums("printer-state", 3) } },
                                    caps: IppCapsCache({ throw DeviceNetworkError.failed("unreachable") })) { _, _, _, _, _, _ in
            drew.store(true, ordering: .releasing)
        }
        summary = await Self.run(lines, mute)
        #expect(summary.items[0].state == .stopped)
        #expect(summary.items[0].stillToSend)
        #expect(summary.stopReason == DirectPrintError.noAnswerBeforeSending().message)
        let didDraw = drew.load(ordering: .acquiring)
        #expect(!didDraw)
    }

    @Test func stopSendsNothingBeforeThePointOfNoReturnAndNeverReadsAsNotSentAfterIt() async throws {
        let folder = BatchFolder()
        let stop = BatchStop()
        let (queue, sent) = Self.directBatch { name, send, jobStop in
            if name == "b.pdf" { stop.stop() } // Stop pressed while b is drawn
            try jobStop.check()
            send()
        }
        let lines = try await Self.lines(folder, queue, [("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=1", Self.one), ("c.pdf", "pages=1", Self.one)])
        var summary = await Self.run(lines, queue, stop)
        #expect(summary.items.map(\.state) == [.sent, .stopped, .stopped])
        #expect(sent.all.first { $0.name == "b.pdf" }?.sending == false)
        #expect(summary.stopReason == loc("You stopped the batch."))

        // A drawing that let a stop through after the job went would make it look unsent: it's held as maybe sent instead.
        let late = BatchStop()
        let (leaky, _) = Self.directBatch { name, send, _ in
            send()
            guard name == "b.pdf" else { return }
            late.stop()
            throw CancellationError()
        }
        summary = await Self.run(lines, leaky, late)
        #expect(summary.items.map(\.state) == [.sent, .failed, .stopped])
        #expect(summary.items[1].mayHaveSent)
        #expect(!summary.items[1].stillToSend)
    }

    @Test func aStoppedPrinterOrOneNotTakingJobsStopsTheBatchBeforeAFile() async throws {
        func problem(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) async throws -> String? { try await Self.directBatch(printer: answer).queue.problem() }

        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 3); b.kw("printer-state-reasons", "toner-low-warning") } } == nil)
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 4); b.kw("printer-state-reasons", "none"); b.raw(0x22, "printer-is-accepting-jobs", [1]) } } == nil)
        let jam = loc("Paper jam") + "."
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 5); b.kw("printer-state-reasons", "media-jam-error") } } == jam)
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 3); b.raw(0x22, "printer-is-accepting-jobs", [0]) } } == loc("The printer isn't taking jobs now."))
        #expect(try await problem { _ in Self.response(0x0401) { _ in } } == DirectJob.refused(0x0401))
        #expect(try await problem { _ in [1, 2, 3] } == DirectPrintError.noAnswerBeforeSending().message)
        // The printer's own words, one line and cut short.
        let said = try #require(try await problem { _ in
            Self.printer { b in
                b.enums("printer-state", 5)
                b.kw("printer-state-reasons", "other")
                b.text("printer-state-message", String(repeating: "x", count: 500) + "\r\nsecond line")
            }
        })
        #expect(said.count <= 122)
        #expect(!said.contains("\n"))

        let folder = BatchFolder()
        let jammed = Self.directBatch(printer: { _ in Self.printer { b in b.enums("printer-state", 5); b.kw("printer-state-reasons", "media-jam-error") } })
        let lines = try await Self.lines(folder, jammed.queue, [("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=1", Self.one)])
        let summary = await Self.run(lines, jammed.queue)
        #expect(summary.items.allSatisfy { $0.state == .stopped })
        #expect(summary.stopReason == jam)
        #expect(jammed.sent.names.isEmpty)
    }

    // ---- job alerts ----

    static let ana = JobOwner(userName: "ana", domain: "OFFICE", machine: "ANA-PC")
    /// 2026-11-19 16:00 UTC.
    static let now0 = Date(timeIntervalSince1970: 1_795_622_400)

    /// An IPP dateTime (RFC 8011 §5.1.15) in UTC.
    static func date(_ at: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: at)
        return [UInt8(c.year! >> 8), UInt8(c.year! & 0xFF), UInt8(c.month!), UInt8(c.day!), UInt8(c.hour!), UInt8(c.minute!), UInt8(c.second!), 0,
                UInt8(ascii: "+"), 0, 0]
    }

    /// A Get-Jobs answer: each job its id, state, reasons, owner, and the extras `more` adds.
    static func jobs(_ jobs: [(id: Int, state: Int, reason: String, more: ((B) -> Void)?)]) -> [UInt8] {
        response(0) { b in
            for j in jobs {
                b.group(IppCodec.jobTag)
                b.int("job-id", j.id)
                b.text("job-name", "C:\\Users\\ana\\job \(j.id).pdf")
                b.enums("job-state", j.state)
                b.kw("job-state-reasons", j.reason)
                b.text("job-originating-user-name", "ana")
                b.int("job-impressions", 4)
                j.more?(b)
            }
        }
    }

    static func jobs(_ id: Int, _ state: Int, _ reason: String, _ more: ((B) -> Void)? = nil) -> [UInt8] { jobs([(id, state, reason, more)]) }

    static let noJobs = response(0) { _ in }

    static func jobTracker() -> AlertTracker {
        var rules = AlertRules()
        rules.jobs = true
        return AlertTracker(rules: rules, timeZone: TimeZone(secondsFromGMT: 0)!)
    }

    /// The printer read, then its jobs, as the menu bar does it once a minute.
    static func observe(_ t: AlertTracker, _ watch: DirectJobWatch, _ at: Date, _ open: [UInt8], _ ended: [UInt8]?, state: String = "ready") throws -> [AlertNotice] {
        let status = PrinterStatus(code: state, message: state, severity: .info, alerts: [])
        _ = t.observe(PrinterSnapshot(uuid: "uuid", name: "Office inkjet", reachable: true, status: status, supplies: []), now: at)
        return t.observeJobs("uuid", printerName: "Office inkjet", try watch.read(open, ended), me: ana, now: at)
    }

    final class Clock: @unchecked Sendable {
        var now: Date
        init(_ now: Date) { self.now = now }
        func watch() -> DirectJobWatch { DirectJobWatch(clock: { self.now }) }
    }

    @Test func aDirectJobThePrinterGivesUpOnBetweenTwoReadsIsToldOnceInThePrintersWords() throws {
        let clock = Clock(Self.now0)
        let watch = clock.watch()
        let t = Self.jobTracker()
        // Printing, with no creation time from the printer: the key is the moment it was first seen.
        #expect(try Self.observe(t, watch, clock.now, Self.jobs(5, 5, "job-printing"), Self.noJobs, state: "processing").isEmpty)
        let first = try #require(try watch.read(Self.jobs(5, 5, "job-printing"), Self.noJobs).jobs.first)
        #expect(first.submitted == Self.now0)
        #expect(first.state == .processing)

        // Gone from the open jobs, aborted among the ended: the same job (one key), failed, for the alert's minute.
        let aborted = Self.jobs(5, 8, "document-format-error")
        var told: [AlertNotice] = []
        for m in 1...4 {
            clock.now = Self.now0.addingTimeInterval(Double(m) * 60)
            let read = try #require(try watch.read(Self.noJobs, aborted).jobs.first)
            #expect(read.submitted == Self.now0 && read.state == .aborted)
            told += try Self.observe(t, watch, clock.now, Self.noJobs, aborted)
        }
        #expect(told.count == 1)
        let n = try #require(told.first)
        #expect(n.kind == .jobFailed)
        #expect(n.title.contains("job 5.pdf")) // the document's name, not its folder
        #expect(n.body.contains(Self.aborted))
        #expect(!n.body.contains("macOS"))

        // Kept for 15 minutes after it ended, then it leaves.
        clock.now = Self.now0.addingTimeInterval(60 + DirectJobWatch.endedKept + 60)
        #expect(try watch.read(Self.noJobs, aborted).jobs.isEmpty)
    }

    @Test func jobsThatEndedBeforeTheWatchBeganArentToldAndPrintedOnesHaveLeft() throws {
        let clock = Clock(Self.now0)
        let watch = clock.watch()
        let ended = Self.jobs([
            (1, 8, "aborted-by-system", nil), // no completion time: can't tell how old, left out
            (2, 8, "aborted-by-system", { $0.raw(0x31, "date-time-at-completed", Self.date(Self.now0.addingTimeInterval(-3 * 3600))) }),
            (3, 8, "aborted-by-system", { $0.raw(0x31, "date-time-at-completed", Self.date(Self.now0.addingTimeInterval(-4 * 60))) }),
            (4, 9, "job-completed-successfully", { $0.raw(0x31, "date-time-at-completed", Self.date(Self.now0.addingTimeInterval(-60))) }),
            (6, 7, "job-canceled-by-user", nil),
        ])
        #expect(try watch.read(Self.noJobs, ended).jobs.map(\.id) == [3])
        clock.now = Self.now0.addingTimeInterval(60)
        #expect(try watch.read(Self.noJobs, ended).jobs.map(\.id) == [3]) // 1 and 2 stay left out
        // A new job given up on after the watch began, with no time from the printer: told from when it was seen.
        clock.now = Self.now0.addingTimeInterval(120)
        let more = Self.jobs([(1, 8, "aborted-by-system", nil), (7, 8, "aborted-by-system", nil)])
        #expect(try watch.read(Self.noJobs, more).jobs.map(\.id) == [7])
    }

    @Test func aDirectJobWaitingOnAReadyPrinterIsToldStuckAfterFiveMinutes() throws {
        let clock = Clock(Self.now0)
        let watch = clock.watch()
        let t = Self.jobTracker()
        let waiting = Self.jobs(9, 3, "none") { $0.raw(0x31, "date-time-at-creation", Self.date(Self.now0)) }
        var told: [AlertNotice] = []
        for m in 0...7 {
            clock.now = Self.now0.addingTimeInterval(Double(m) * 60)
            told += try Self.observe(t, watch, clock.now, waiting, Self.noJobs)
        }
        #expect(told.map(\.kind) == [.jobStuck])

        // One stopped at the printer (out of paper) is failed, as on a macOS queue.
        let t2 = Self.jobTracker()
        let w2 = clock.watch()
        let stopped = Self.jobs(10, 6, "resources-are-not-ready")
        told = []
        for m in 0...3 {
            clock.now = Self.now0.addingTimeInterval(Double(m) * 60)
            told += try Self.observe(t2, w2, clock.now, stopped, Self.noJobs)
        }
        #expect(told.map(\.kind) == [.jobFailed])
    }

    @Test func onlyYourOwnDirectJobsAreYoursAndAReusedIdIsANewJob() throws {
        let clock = Clock(Self.now0)
        let watch = clock.watch()
        let state = try watch.read(Self.response(0) { b in
            for (id, user, host) in [(1, "ana", "ANA-PC.office.lan"), (2, "ana", "OTHER-PC"), (3, "ana", "192.0.2.40"), (4, "ana", "PC\u{202E}evil"), (5, "bob", nil)] {
                b.group(IppCodec.jobTag)
                b.int("job-id", id)
                b.enums("job-state", 3)
                b.text("job-originating-user-name", user)
                if let host { b.text("job-originating-host-name", host) }
            }
        }, nil)
        #expect(state.jobs.map { Self.ana.owns($0, othersMayPrint: state.othersMayPrint) } == [true, false, true, true, false]) // an address or a name that isn't one says nothing
        #expect(state.jobs.filter { $0.id == 3 || $0.id == 4 }.map(\.machine) == [nil, nil])

        // A printer that restarted counts from 1 again: an id seen given up on and then waiting is a new job.
        #expect(try watch.read(Self.noJobs, Self.jobs(8, 8, "aborted-by-system") { $0.raw(0x31, "date-time-at-completed", Self.date(Self.now0)) }).jobs.count == 1)
        clock.now = Self.now0.addingTimeInterval(180)
        let again = try #require(try watch.read(Self.jobs(8, 3, "none"), Self.noJobs).jobs.first)
        #expect(again.submitted == clock.now)
    }

    @Test func theWatchAsksForOpenAndEndedJobsAndAPrinterThatListsOnlyOpenOnesStillCounts() async throws {
        let asked = Mutex<[String]>([])
        let refuseEnded = Atomic(false)
        let ipp = Self.client { request in
            let which = String(decoding: request, as: UTF8.self).contains("not-completed") ? "not-completed" : "completed"
            asked.withLock { $0.append(which) }
            return which == "not-completed" ? Self.jobs(4, 5, "job-printing")
                : refuseEnded.load(ordering: .acquiring) ? Self.response(0x040B) { _ in }
                : Self.jobs(3, 8, "aborted-by-system") { $0.raw(0x31, "date-time-at-completed", Self.date(Date())) }
        }
        let watch = DirectJobWatch()
        #expect(try await watch.read(ipp, user: "ana").jobs.map(\.id).sorted() == [3, 4])
        #expect(asked.withLock { $0 } == ["not-completed", "completed"])
        refuseEnded.store(true, ordering: .releasing)
        #expect(try await watch.read(ipp, user: "ana").jobs.map(\.id) == [4])

        // The open jobs refused: the read fails, so the queue isn't taken as empty.
        let refusing = Self.client { _ in Self.response(0x0401) { _ in } }
        await #expect(throws: DirectPrintError.self) { try await DirectJobWatch().read(refusing, user: "ana") }
        let ended = String(decoding: PrinterJobs.getJobsRequest("ipp://x/", user: "ana", which: PrinterJobs.completed), as: UTF8.self)
        #expect(ended.contains("completed") && !ended.contains("not-completed"))
        #expect(String(decoding: PrinterJobs.getJobsRequest("ipp://x/", user: "ana"), as: UTF8.self).contains("not-completed")) // the card's, as before
    }

    // ---- review: limits, wording, this Mac's errors, the job list's memory, a stopped printer ----

    @Test func aLongDirectJobIsWaitedForOnceSentButADrawingThatHangsIsnt() async throws {
        let folder = BatchFolder()
        // A tiny limit stands for 20 pages × 10 copies printing for longer than any limit by pages: once sent, it's the printer's.
        var options = BatchPrintOptions()
        options.sendTimeout = .milliseconds(50)
        options.sendTimePerPage = .zero
        let (slow, _) = Self.directBatch { _, send, _ in
            send()
            try await Task.sleep(for: .milliseconds(400))
        }
        let lines = try await Self.lines(folder, slow, [("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=1", Self.one)])
        var summary = await Self.run(lines, slow, options: options)
        #expect(summary.items.map(\.state) == [.sent, .sent])

        // Before the point of no return the limit holds: a drawing that never ends fails that file, and says nothing of macOS.
        let (hung, _) = Self.directBatch { _, _, stop in
            while true {
                try stop.check()
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        summary = await Self.run(lines, hung, options: options)
        #expect(summary.items[0].state == .failed)
        #expect(summary.items[0].message == loc("It took too long to draw: it may be damaged. Not printed."))
        #expect(!summary.items.map(\.message).joined(separator: " ").contains("macOS"))

        // The drawing's limit counts the copies (each copy the printer doesn't make is drawn again); a macOS queue's doesn't.
        let job = BatchPrintJob(name: "x.pdf", pages: Array(1...20), copies: 10, twoSided: false, paper: nil, sheets: 200)
        let defaults = BatchPrintOptions()
        #expect(slow.sendLimit(job, defaults) == defaults.sendTimeout + defaults.sendTimePerPage * 200)
        #expect(FakeQueue().sendLimit(job, defaults) == defaults.sendTimeout + defaults.sendTimePerPage * 20)
        #expect(slow.endsOnItsOwnOnceSpooling)
        #expect(!FakeQueue().endsOnItsOwnOnceSpooling)
    }

    /// Answers after a while: a printer slower than the batch's patience.
    struct Slow: HttpTransport {
        let delay: Duration
        let answer: @Sendable ([UInt8]) -> [UInt8]

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            try await Task.sleep(for: delay)
            return HttpResponse(status: 200, headers: ["Content-Type": "application/ipp"], body: answer(request.bodyBytes()))
        }
    }

    @Test func aPrinterSlowToSayWhetherItsReadyIsSaidAsThePrinterNotMacOS() async throws {
        let folder = BatchFolder()
        let http = DeviceHttp(host: "192.0.2.11", transport: Slow(delay: .seconds(3)) { _ in Self.printer { b in b.enums("printer-state", 3) } })
        let c = Self.caps()
        let queue = DirectBatchQueue("Office inkjet", ipp: IppClient(http, endpoint: URL(string: "http://192.0.2.11:631/ipp/print")!),
                                     caps: IppCapsCache({ c })) { _, _, _, _, onSending, _ in onSending() }
        let lines = try await Self.lines(folder, queue, [("a.pdf", "pages=1", Self.one)])
        var options = BatchPrintOptions()
        options.queueTimeout = .milliseconds(100)
        let summary = await Self.run(lines, queue, options: options)
        #expect(summary.stopReason == DirectPrintError.noAnswerBeforeSending().message)
        #expect(FakeQueue().noAnswer == loc("macOS doesn't answer about the printer.")) // a macOS queue's words stay its own
    }

    struct DiskFull: Error {}

    @Test func thisMacsDiskOrDrawingFailingFailsThatFileAndOnlyThePrintersSilenceStopsTheBatch() async throws {
        let folder = BatchFolder()
        let (disk, _) = Self.directBatch { name, send, _ in
            switch name {
            case "a.pdf": throw CocoaError(.fileWriteOutOfSpace)
            case "b.pdf": throw DiskFull()
            default: send()
            }
        }
        let lines = try await Self.lines(folder, disk, [("a.pdf", "pages=1", Self.one), ("b.pdf", "pages=1", Self.one), ("c.pdf", "pages=1", Self.one)])
        var summary = await Self.run(lines, disk)
        #expect(summary.items.map(\.state) == [.failed, .failed, .sent])
        #expect(summary.items.prefix(2).allSatisfy { $0.message.contains(DirectBatchQueue.notDrawn) })
        #expect(summary.items.prefix(2).allSatisfy { !$0.mayHaveSent })
        #expect(!summary.items.map(\.message).joined(separator: " ").contains("space")) // no error text
        #expect(summary.stoppedAt == nil)

        // The printer not answering before anything went (its attributes read again): the batch stops, the file still to send.
        let (silent, _) = Self.directBatch { name, _, _ in if name == "b.pdf" { throw DirectPrintError.noAnswerBeforeSending() } }
        summary = await Self.run(lines, silent)
        #expect(summary.items[1].state == .stopped)
        #expect(summary.items[1].stillToSend)
        #expect(summary.stopReason == DirectPrintError.noAnswerBeforeSending().message)
    }

    @Test func aJobIdThePrinterUsesAgainIsANewJobWithItsOwnTime() throws {
        let clock = Clock(Self.now0)
        let watch = clock.watch()
        #expect(try watch.read(Self.jobs(5, 5, "job-printing"), Self.noJobs).jobs.first?.submitted == Self.now0)
        clock.now = Self.now0.addingTimeInterval(60)
        #expect(try watch.read(Self.noJobs, Self.noJobs).jobs.isEmpty) // printed: it left
        clock.now = Self.now0.addingTimeInterval(6 * 60)
        #expect(try watch.read(Self.jobs(5, 3, "none"), Self.noJobs).jobs.first?.submitted == clock.now) // not the old job's

        // A list cut at the limit doesn't say which jobs left: none is forgotten.
        func waiting(_ from: Int) -> [UInt8] { Self.jobs((from..<from + PrinterJobs.maxJobs + 5).map { ($0, 3, "none", nil) }) }
        clock.now = Self.now0.addingTimeInterval(7 * 60)
        #expect(try watch.read(waiting(10), Self.noJobs).jobs.first { $0.id == 10 }?.submitted == clock.now)
        clock.now = Self.now0.addingTimeInterval(8 * 60)
        #expect(try !watch.read(waiting(500), Self.noJobs).jobs.contains { $0.id == 10 }) // cut at the limit: job 10 may still be there
        clock.now = Self.now0.addingTimeInterval(9 * 60)
        #expect(try watch.read(waiting(10), Self.noJobs).jobs.first { $0.id == 10 }?.submitted == Self.now0.addingTimeInterval(7 * 60))
    }

    @Test func aFirstReadWithoutTheEndedListDoesntMakeOldFailuresNew() async throws {
        let calls = Atomic(0)
        let ipp = Self.client { request in
            let ended = !String(decoding: request, as: UTF8.self).contains("not-completed")
            if ended && calls.add(1, ordering: .relaxed).newValue == 1 { return [1, 2] } // the first ended list: unreadable
            return ended ? Self.jobs(3, 8, "aborted-by-system") : Self.noJobs // given up on, no time: from before the watch
        }
        let watch = DirectJobWatch()
        #expect(try await watch.read(ipp, user: "ana").jobs.isEmpty)
        #expect(try await watch.read(ipp, user: "ana").jobs.isEmpty) // the first ended list read: still old
        #expect(try await watch.read(ipp, user: "ana").jobs.isEmpty)
    }

    @Test func aStoppedPrinterIsAProblemEvenWithOnlyWarnings() async throws {
        func problem(_ answer: @escaping @Sendable ([UInt8]) -> [UInt8]) async throws -> String? { try await Self.directBatch(printer: answer).queue.problem() }

        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 5); b.kw("printer-state-reasons", "moving-to-paused-warning") } } != nil)
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 5); b.kw("printer-state-reasons", "toner-low-warning") } } == loc("Stopped") + ".")
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 5); b.kw("printer-state-reasons", "none") } } != nil)
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 3); b.kw("printer-state-reasons", "paused") } } != nil)
        #expect(try await problem { _ in Self.printer { b in b.enums("printer-state", 3); b.kw("printer-state-reasons", "moving-to-paused") } } == nil)
    }

    // ---- the person's choice, kept (Windows' The_state_file_gives_the_command_line_the_print_straight_choice…) ----

    @Test func theStateFileKeepsThePrintStraightChoicePerPrinter() throws {
        let store = StateStore(memory: PrintState())
        store.setPrintsDirect("uuid-inkjet", true)
        store.setPrintsDirect("uuid-inkjet", true)
        #expect(store.printsDirect("UUID-INKJET"))
        #expect(store.current.directPrinters == ["uuid-inkjet"])
        store.rename("uuid-inkjet", "uuid-new")
        #expect(store.printsDirect("uuid-new") && !store.printsDirect("uuid-inkjet"))
        store.setPrintsDirect("uuid-new", false)
        #expect(!store.printsDirect("uuid-new"))
        store.setPrintsDirect("uuid-gone", true)
        store.remove("uuid-gone")
        #expect(store.current.directPrinters.isEmpty)

        let parsed = try JSONDecoder().decode(PrintState.self, from: Data(#"{ "directPrinters": [ "uuid-inkjet", 7, null ] }"#.utf8))
        #expect(parsed.directPrinters == ["uuid-inkjet"])
        #expect(try JSONDecoder().decode(PrintState.self, from: Data(#"{ "directPrinters": "x" }"#.utf8)).directPrinters.isEmpty)
    }

    // ---- one route decision ----

    final class Routed: @unchecked Sendable {
        var lookups = 0
        var queueName: String?
        var chose = false
        var ipp: IppClient?
        var works = true
        var asked: [String] = []
    }

    static func router(_ r: Routed, queueWorks: Bool = false) -> PrintRouter {
        let check: @Sendable (String) async -> Bool = { q in
            r.asked.append(q)
            return r.works
        }
        return PrintRouter(findQueue: { r.lookups += 1; return r.queueName }, rasterIpp: { r.ipp }, personChoseDirect: { r.chose },
                           queueWorks: queueWorks ? check : nil)
    }

    @Test func jobAlertsWatchWhereTheLastPrintWentWithoutLookingTheQueueUpAgain() async throws {
        let r = Routed()
        r.ipp = Self.client { _ in Self.noJobs }
        let router = Self.router(r)
        #expect(router.lastChoice == nil)
        #expect(try await router.forWatching().route == .direct) // none chosen yet: decided once
        #expect(r.lookups == 1)

        // A queue appears (set up in macOS) after the last print went straight: alerts keep watching the printer until the next decision.
        r.queueName = "Office_inkjet"
        #expect(try await router.forWatching().route == .direct)
        #expect(r.lookups == 1)
        let print = try await router.choose() // the next print (or the queue's change) decides again
        #expect(print.route == .queue && print.queue == "Office_inkjet")
        #expect(try await router.forWatching().route == .queue)
        r.chose = true
        #expect(try await router.choose().route == .direct)

        // A reconnect makes a new client: alerts read through it.
        let reconnected = Self.client { _ in Self.noJobs }
        r.ipp = reconnected
        #expect(try await router.forWatching().ipp === reconnected)

        // The alerts' reader reads the printer's list or the queue, as decided.
        let queueReads = Atomic(0)
        let jobs = RoutedJobQueue({ queueReads.add(1, ordering: .relaxed); return JobQueueState(paused: false, printerOffline: false, jobs: []) },
                                  router: router, user: "ana")
        r.ipp = Self.client { request in String(decoding: request, as: UTF8.self).contains("not-completed") ? Self.jobs(4, 5, "job-printing") : Self.noJobs }
        #expect(try await jobs.read()?.jobs.map(\.id) == [4])
        r.chose = false
        _ = try await router.choose()
        #expect(try await jobs.read()?.jobs.isEmpty == true)
        let reads = queueReads.load(ordering: .relaxed)
        #expect(reads == 1)
    }

    @Test func aQueueMacOSCantUseGivesWayToThePrinterWhenItTakesJobsStraight() async throws {
        let r = Routed()
        (r.queueName, r.ipp, r.works) = ("Office_laser", Self.client { _ in Self.noJobs }, false)
        let router = Self.router(r, queueWorks: true)

        // macOS can't use the queue (removed, stopped, or not accepting jobs): straight to the printer, the queue still named.
        let broken = try await router.choose()
        #expect(broken.route == .direct && broken.queue == "Office_laser" && broken.queueBroken)
        #expect(r.asked == ["Office_laser"])

        // The queue works again: back to it.
        r.works = true
        let mended = try await router.choose()
        #expect(mended.route == .queue && !mended.queueBroken)

        // The person chose straight to the printer: the queue isn't asked about, and it isn't the queue's doing.
        let chosen = try await PrintRouter(findQueue: { "Office_laser" }, rasterIpp: { r.ipp }, personChoseDirect: { true },
                                           queueWorks: { _ in Issue.record("not asked"); return false }).choose()
        #expect(chosen.route == .direct && !chosen.queueBroken)

        // No other way to the printer: the queue it is (printing then says what's wrong with it), and it isn't asked.
        r.ipp = nil
        r.asked = []
        r.works = false
        #expect(try await router.choose().route == .queue)
        #expect(r.asked.isEmpty)
    }

    @Test @MainActor func thePrintTabSaysPagesGoStraightBecauseTheQueueIsntWorking() async {
        let r = Routed()
        r.works = false
        let ipp = Self.client { _ in Self.noJobs }
        let routing = PrintRouting(findQueue: { "Office_laser" }, rasterIpp: { ipp }, hasAddress: true, choseDirect: false, rememberChoice: { _ in },
                                   queueWorks: { _ in r.works })
        await routing.decide().value
        #expect(routing.route == .direct && routing.note == .directQueueBroken)
        #expect(routing.hasQueue)
        r.works = true
        await routing.decide().value
        #expect(routing.route == .queue && routing.note == .none)
        #expect(PrintRouteNote.directQueueBroken.text != nil && PrintRouteNote.none.text == nil)
    }

    @Test func aBatchGoesWhereTheRouterDecidesAndAnswersForThatRoute() async throws {
        let folder = BatchFolder()
        let r = Routed()
        (r.queueName, r.ipp) = ("Office_inkjet", Self.client { _ in Self.noJobs })
        let mac = FakeQueue()
        let made = Atomic(0)
        let (direct, sentDirect) = Self.directBatch()
        let router = Self.router(r)
        let routed = RoutedBatchQueue(mac, router: router) { _ in
            made.add(1, ordering: .relaxed)
            return direct
        }
        let lines = try await Self.lines(folder, routed, [("a.pdf", "pages=1", Self.one)])
        _ = await Self.run(lines, routed)
        #expect(mac.sent.count == 1)
        #expect(routed.noAnswer == loc("macOS doesn't answer about the printer."))
        #expect(!routed.endsOnItsOwnOnceSpooling)

        r.queueName = nil // the queue was removed: straight to the printer
        _ = await Self.run(lines, routed)
        #expect(sentDirect.names.count == 1)
        #expect(mac.sent.count == 1)
        #expect(routed.noAnswer == DirectPrintError.noAnswerBeforeSending().message)
        #expect(routed.endsOnItsOwnOnceSpooling)
        let madeCount = made.load(ordering: .relaxed)
        #expect(madeCount > 0)
    }
}
