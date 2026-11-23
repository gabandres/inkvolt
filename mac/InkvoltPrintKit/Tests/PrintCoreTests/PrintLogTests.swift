import Foundation
import Testing
@testable import PrintCore

/// Ported from PrintLogTests.cs. The print log (roadmap 4.9): CUPS's history of finished jobs into entries
/// (`PrintLogRecorder`), the log bounded and read back as hostile input (`PrintLog`, `PrintLogFile`), month totals and the
/// CSV. Adapted: the Mac reads CUPS's own history (Get-Jobs, `which-jobs=completed`) where Windows follows the spooler's
/// notices, so the recorder's tests feed finished jobs as cupsd lists them (`FinishedJob`), and the DEVMODE and SYSTEMTIME
/// tests are the Get-Jobs attributes' (`FinishedJobAttributes`); a job missing from the spooler's whole list has no
/// counterpart (CUPS's history says how each job ended), so its test is CUPS's aborted job. Months and the CSV's times are
/// read in UTC here (Windows' tests take the PC's zone; `DateTimeOffset` carries its own).
struct PrintLogTests {
    private static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int = 0, _ s: Int = 0) -> Date {
        utc.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi, second: s))!
    }

    private static let now = date(2026, 11, 22, 15)
    private static let submitted = date(2026, 11, 22, 7, 8, 47)
    private static let since = date(2026, 11, 1, 0)

    private static func months(_ n: Int, from d: Date = now) -> Date { utc.date(byAdding: .month, value: n, to: d)! }

    /// What cupsd listed for a three-page job, two copies, to a queue (the Get-Jobs attributes as `LibCups.finishedJobs` reads
    /// them).
    private static func realJob(id: Int = 3, submitted: Date = submitted, state: JobState = .completed, printed: Int = 6) -> FinishedJob {
        FinishedJobAttributes.job([
            "job-id": String(id), "job-printer-uri": "ipp://localhost/printers/Office_Laser", "job-name": "/Users/ana/Taxes/return.pdf",
            "job-state": String(state.rawValue), "job-originating-user-name": "ana", "job-originating-host-name": "office-pc.local",
            "time-at-creation": String(Int(submitted.timeIntervalSince1970)), "time-at-completed": String(Int(submitted.timeIntervalSince1970) + 30),
            "job-impressions": "3", "job-impressions-completed": String(printed), "copies": "2", "print-color-mode": "color",
        ])!
    }

    private static func read(_ recorder: PrintLogRecorder, _ jobs: [FinishedJob], since: Date = since) -> [PrintLogEntry] {
        recorder.read(jobs, since: since, now: now, known: { [] })
    }

    // ---------------------------------------------------------------- the recorder

    @Test func aPrintedJobIsLoggedOnceWithWhatTheSpoolerSaid() {
        let recorder = PrintLogRecorder()
        let done = Self.read(recorder, [Self.realJob()])
        #expect(done.count == 1)
        let e = done[0]
        #expect(e.at == Self.submitted)
        #expect(e.printer == "Office_Laser")
        #expect(e.document == "return.pdf") // the folders stay off the log
        #expect(e.user == "ana")
        #expect(e.machine == "office-pc.local")
        #expect(e.pages == 3)
        #expect(e.copies == 2)
        #expect(e.printed == 6)
        #expect(e.totalPages == 6) // CUPS's printed count has the copies in it already
        #expect(e.color == true)
        #expect(e.twoSided == nil)
        #expect(e.outcome == .printed)
        #expect(Self.read(recorder, [Self.realJob()]).isEmpty) // read again: logged once
        #expect(recorder.open == 1)
    }

    @Test func aJobDeletedBeforeItPrintedIsCancelledAndCountsNoPages() {
        let done = Self.read(PrintLogRecorder(), [Self.realJob(state: .canceled, printed: 0)])
        #expect(done.count == 1)
        #expect(done.first?.outcome == .cancelled)
        #expect(done.first?.totalPages == 0)
        // Cancelled after pages printed: it printed (Windows' printing seen before the deletion).
        #expect(Self.read(PrintLogRecorder(), [Self.realJob(state: .canceled, printed: 2)]).first?.outcome == .printed)
    }

    @Test func aJobAQueueKeepsAfterPrintingIsLoggedWhenItPrintsAndNotAgain() {
        let recorder = PrintLogRecorder()
        let job = FinishedJob(id: 9, queue: "Laser", state: .completed, submitted: Self.now.addingTimeInterval(-60), printed: 2)
        #expect(Self.read(recorder, [job]).count == 1)
        #expect(Self.read(recorder, [job]).isEmpty)
        #expect(Self.read(recorder, [job, job]).isEmpty)
        // A new recorder (the app started again) asks the log what it holds.
        let again = PrintLogRecorder()
        #expect(again.read([job], since: Self.since, now: Self.now, known: { [job.key] }).isEmpty)
    }

    @Test func jobsAlreadyPrintedWhenWatchingStartsWereThereBefore() {
        let recorder = PrintLogRecorder()
        let before = FinishedJob(id: 1, queue: "Laser", submitted: Self.since.addingTimeInterval(-7200), completed: Self.since.addingTimeInterval(-3600))
        let after = FinishedJob(id: 2, queue: "Laser", submitted: Self.since.addingTimeInterval(-60), completed: Self.since.addingTimeInterval(60))
        let done = Self.read(recorder, [before, after])
        #expect(done.map(\.job) == [after.key]) // finished after the log was turned on: logged, though submitted before
    }

    @Test func aJobCupsGaveUpOnHasLeft() {
        let done = Self.read(PrintLogRecorder(), [Self.realJob(id: 4, state: .aborted, printed: 0), Self.realJob(id: 5, state: .aborted, printed: 1)])
        #expect(done.map(\.outcome) == [.left, .printed])
    }

    @Test func anIdUsedAgainIsAnotherJob() {
        let recorder = PrintLogRecorder()
        let first = FinishedJob(id: 7, queue: "A", document: "first", submitted: Self.submitted)
        #expect(Self.read(recorder, [first]).count == 1)
        let second = FinishedJob(id: 7, queue: "B", document: "second", submitted: Self.submitted.addingTimeInterval(300))
        #expect(Self.read(recorder, [second, first]).map(\.document) == ["second"])
        #expect(recorder.open == 2)
    }

    @Test func theJobsFollowedAreBoundedAndForgottenWhenWatchingStops() {
        let recorder = PrintLogRecorder()
        let many = (1...(PrintLogRecorder.maxOpen + 50)).map { FinishedJob(id: $0, queue: "Laser", submitted: Self.now.addingTimeInterval(-Double($0))) }
        #expect(Self.read(recorder, many).count == PrintLogRecorder.maxOpen)
        #expect(recorder.open == PrintLogRecorder.maxOpen)
        recorder.reset()
        #expect(recorder.open == 0)
        // Jobs CUPS no longer lists are forgotten too.
        _ = Self.read(recorder, Array(many.prefix(10)))
        #expect(recorder.open == 10)
    }

    @Test func theKeeperLogsNothingWhileOff() {
        let file = PrintLogFile(nil)
        let clock = Clock(Self.now)
        let keeper = PrintLogKeeper(file, since: nil, clock: { clock.now })
        #expect(keeper.read([Self.realJob()]) == 0)
        #expect(file.read(Self.now).isEmpty)
        let since = keeper.turn(true)
        #expect(since == Self.now)
        let added = Counter()
        keeper.added = { added.bump() }
        // Finished before it was turned on: not logged; after: logged.
        #expect(keeper.read([Self.realJob()]) == 0)
        clock.now = Self.now.addingTimeInterval(600)
        let later = FinishedJob(id: 8, queue: "Laser", submitted: Self.now.addingTimeInterval(60), completed: Self.now.addingTimeInterval(120))
        #expect(keeper.read([later, Self.realJob()]) == 1)
        #expect(file.read(clock.now).count == 1)
        #expect(added.value == 1)
        // Cleared: CUPS still lists the job, and it isn't logged again.
        #expect(keeper.clear().cleared)
        #expect(keeper.read([later]) == 0)
        #expect(keeper.turn(false) == nil)
        #expect(!keeper.on)
    }

    // ---------------------------------------------------------------- what CUPS hands over

    @Test func aDevmodeSaysOnlyWhatItsFieldsSay() {
        func job(_ extra: [String: String]) -> FinishedJob? {
            FinishedJobAttributes.job(["job-id": "3", "job-state": "9", "job-printer-uri": "ipp://localhost/printers/Laser"].merging(extra) { $1 })
        }
        let full = job(["copies": "3", "print-color-mode": "monochrome", "sides": "two-sided-long-edge"])
        #expect(full?.copies == 3 && full?.color == false && full?.twoSided == true)
        let none = job([:])
        #expect(none?.copies == nil && none?.color == nil && none?.twoSided == nil)
        let odd = job(["copies": "-5", "print-color-mode": "color", "sides": "sideways"])
        #expect(odd?.copies == nil && odd?.color == true && odd?.twoSided == nil)
        #expect(job(["copies": "99999999999999999999"])?.copies == nil)
        #expect(job(["job-impressions-completed": "-4", "job-media-sheets-completed": "2"])?.printed == 2)
        // Not a finished job, no queue, no id: none.
        #expect(job(["job-state": "5"]) == nil)
        #expect(job(["job-printer-uri": "ipp://localhost/jobs/3"]) == nil)
        #expect(job(["job-id": "0"]) == nil)
        // This Mac's own job: no machine named.
        #expect(job(["job-originating-host-name": "localhost"])?.machine == nil)
        #expect(job(["job-printer-uri": "ipp://localhost/printers/Front%20Desk"])?.queue == "Front Desk")
    }

    @Test func aSubmissionTimeThatIsntADateIsNone() {
        #expect(FinishedJobAttributes.time("1795331327") == Date(timeIntervalSince1970: 1_795_331_327))
        #expect(FinishedJobAttributes.time("12") == nil) // 1970: not a date a job was sent
        #expect(FinishedJobAttributes.time("soon") == nil)
        #expect(FinishedJobAttributes.time(nil) == nil)
        #expect(FinishedJobAttributes.time("99999999999999") == nil)
    }

    // ---------------------------------------------------------------- the log

    private static func entry(_ at: Date, printer: String = "Laser", user: String = "ana", pages: Int = 2, copies: Int = 1,
                              color: Bool? = nil, outcome: PrintLogOutcome = .printed) -> PrintLogEntry {
        PrintLogEntry(at: at, printer: printer, document: "doc", user: user, pages: pages, copies: copies, color: color, outcome: outcome)
    }

    @Test func namesAreOneLineOfVisibleCharactersAndCountsAreBounded() {
        let e = PrintLog.clean(PrintLogEntry(at: Self.now, printer: "Laser\u{202E}\r\nfake line", document: String(repeating: "x", count: 500),
                                             user: "ana\u{0}", pages: -4, copies: 0, machine: "\\\\PC\u{200B}", printed: Int.max))!
        #expect(e.printer == "Laser fake line")
        #expect(e.document.utf16.count == PrintLog.maxText)
        #expect(e.user == "ana")
        #expect(e.machine == "PC")
        #expect(e.pages == 0)
        #expect(e.copies == 1)
        #expect(e.printed == PrintLog.maxPages)
        #expect(PrintLog.clean(PrintLogEntry(at: Date(timeIntervalSince1970: -62_135_596_800), printer: "a", document: "b", user: "c", pages: 1)) == nil)
        #expect(PrintLog.clean(nil) == nil)
    }

    @Test func theLogKeepsThirteenMonthsAndAtMostItsLimit() {
        var list = [Self.entry(Self.months(-14)), Self.entry(Self.months(-12))]
        list = PrintLog.add(list, Self.entry(Self.now), Self.now)
        #expect(list.count == 2)
        let many = (0..<(PrintLog.maxEntries + 10)).map { Self.entry(Self.now.addingTimeInterval(-60 * Double($0))) }.reversed()
        let kept = PrintLog.trim(Array(many), Self.now)
        #expect(kept.count == PrintLog.maxEntries)
        #expect(kept.last?.at == Self.now) // the newest stay
    }

    @Test func monthTotalsCountPagesTimesCopiesPerPrinterAndPerPersonWithoutCancelledJobs() {
        let november = PrintLogMonth(year: 2026, month: 11)
        let log = [
            Self.entry(Self.now, printer: "Laser", user: "ana", pages: 3, copies: 2),
            Self.entry(Self.now, printer: "laser", user: "ben", pages: 1, color: true),
            Self.entry(Self.now, printer: "Inkjet", user: "ana", pages: 4, color: true),
            Self.entry(Self.now, printer: "Inkjet", user: "ben", pages: 50, outcome: .cancelled),
            Self.entry(Self.months(-1), printer: "Laser", user: "ana", pages: 100),
            Self.entry(Self.now, printer: "", user: "", pages: 1),
        ]
        let byPrinter = PrintLog.byPrinter(log, november, Self.utc)
        #expect(byPrinter[0] == PrintLogTotal("Laser", 2, 7, 1))
        #expect(byPrinter[1] == PrintLogTotal("Inkjet", 1, 4, 4))
        #expect(byPrinter[2].name == PrintLog.unknown)
        let byUser = PrintLog.byUser(log, november, Self.utc)
        #expect(byUser[0] == PrintLogTotal("ana", 2, 10, 4))
        #expect(PrintLog.months(log, Self.utc) == [november, november.adding(months: -1)])
        #expect(PrintLog.jobs(log, in: november, Self.utc).count == 5)
    }

    @Test func theCsvHasAHeaderAndCellsASpreadsheetWontRun() {
        let csv = PrintLog.csv([PrintLogEntry(at: Self.submitted, printer: "Laser, 2nd floor", document: "=HYPERLINK(\"x\")", user: "ana",
                                              pages: 3, copies: 2, color: true, twoSided: false, outcome: .printed, machine: "PC", printed: 6)],
                               timeZone: TimeZone(identifier: "UTC")!)
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0] == "time,printer,document,user,computer,pages,copies,total_pages,color,two_sided,outcome")
        #expect(lines[1] == "2026-11-22T07:08:47+00:00,\"Laser, 2nd floor\",\"'=HYPERLINK(\"\"x\"\")\",ana,PC,3,2,6,yes,no,printed")
    }

    @Test func theFileIsReadBackAsHostileInput() {
        let lines = [
            PrintLogFile.line(Self.entry(Self.now.addingTimeInterval(-86_400))),
            "not json",
            "{\"At\":\"2026-11-20T10:00:00+00:00\",\"Printer\":\"P\\u202Eq\",\"Document\":null,\"User\":\"u\",\"Pages\":-1,\"Outcome\":\"Sideways\"}",
            "{\"At\":\"2026-11-20T10:00:00+00:00\",\"Printer\":\"Q\",\"Document\":\"d\",\"User\":\"u\",\"Pages\":2,\"Outcome\":99}",
            "{\"At\":\"" + String(repeating: "9", count: 9000) + "\"}",
            PrintLogFile.line(Self.entry(Self.months(-20))),
            "",
        ]
        let read = PrintLogFile.parse(lines, Self.now)
        #expect(read.count == 2)
        #expect(read.first?.printer == "Q")
        #expect(read.first?.outcome == .left)
        #expect(read.last?.printer == "Laser")
    }

    private static func folder() -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-printlog-" + UUID().uuidString)
    }

    private static func fileLines(_ path: String) -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func theFileKeepsAppendingAndClears() {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let path = (folder as NSString).appendingPathComponent("print-log.jsonl")
        let file = PrintLogFile(path)
        file.add([Self.entry(Self.now.addingTimeInterval(-7200))], Self.now)
        file.add([Self.entry(Self.now.addingTimeInterval(-3600), printer: "Inkjet")], Self.now)
        #expect(Self.fileLines(path).count == 2)
        #expect(PrintLogFile(path).read(Self.now).map(\.printer) == ["Laser", "Inkjet"])
        #expect(file.clear())
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(file.read(Self.now).isEmpty)
        #expect(PrintLogFile(path).read(Self.now).isEmpty)
    }

    @Test func atItsLimitTheFileIsAppendedToNotWrittenAgainEachJob() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("print-log.jsonl")
        let text = (0..<PrintLog.maxEntries).map { PrintLogFile.line(Self.entry(Self.now.addingTimeInterval(60 * Double($0 - PrintLog.maxEntries)))) + "\n" }.joined()
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        let file = PrintLogFile(path)
        #expect(file.read(Self.now).count == PrintLog.maxEntries)
        for i in 0..<5 { file.add([Self.entry(Self.now.addingTimeInterval(Double(i)), printer: "New")], Self.now) }
        #expect(file.read(Self.now).count == PrintLog.maxEntries) // trimmed in memory
        #expect(Self.fileLines(path).count == PrintLog.maxEntries + 5) // appended, not written again
        for i in 0..<(PrintLog.maxEntries / 5) { file.add([Self.entry(Self.now.addingTimeInterval(Double(10 + i)))], Self.now) }
        #expect(Self.fileLines(path).count <= PrintLog.maxEntries * 6 / 5) // compacted once past a fifth more
        #expect(PrintLogFile(path).read(Self.now).count == PrintLog.maxEntries)
    }

    /// Windows holds the file open without read access; here the file is made unreadable for the while (POSIX permissions,
    /// so not on Windows' Foundation).
    @Test(.enabled(if: Self.posixPermissions)) func aFileThatCouldntBeReadIsNeverWrittenOver() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("print-log.jsonl")
        let text = [Self.entry(Self.now.addingTimeInterval(-86_400)), Self.entry(Self.now.addingTimeInterval(-172_800))].map { PrintLogFile.line($0) + "\n" }.joined()
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        let file = PrintLogFile(path)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: path) // can't be read now; can be appended to
        #expect(file.read(Self.now).isEmpty)
        file.add([Self.entry(Self.months(-20)), Self.entry(Self.now)], Self.now) // an aged-out job would have the file written again
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(file.read(Self.now).count == 3) // read again now that it can be: the two, and the new one appended
        #expect(PrintLogFile(path).read(Self.now).count == 3)
    }

    /// Windows holds the file open so it can't be deleted; here its folder can't be written for the while.
    @Test(.enabled(if: Self.posixPermissions)) func clearingAFileInUseForgetsNothingAndSaysSo() throws {
        let folder = Self.folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
            try? FileManager.default.removeItem(atPath: folder)
        }
        let path = (folder as NSString).appendingPathComponent("print-log.jsonl")
        let file = PrintLogFile(path)
        file.add([Self.entry(Self.now.addingTimeInterval(-3600))], Self.now)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder) // can't be deleted now
        #expect(!file.clear())
        #expect(file.read(Self.now).count == 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        #expect(file.clear())
        #expect(file.read(Self.now).isEmpty)
    }

    @Test(.enabled(if: Self.posixPermissions)) func whenWritingTheFileAgainFailsTheNewJobsAreAppended() throws {
        let folder = Self.folder()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
            try? FileManager.default.removeItem(atPath: folder)
        }
        let path = (folder as NSString).appendingPathComponent("print-log.jsonl")
        let file = PrintLogFile(path)
        file.add([Self.entry(Self.now.addingTimeInterval(-7200))], Self.now)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder) // can be appended to, not replaced
        file.add([Self.entry(Self.months(-20)), Self.entry(Self.now.addingTimeInterval(-3600), printer: "New")], Self.now) // aged out: written again
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder)
        #expect(PrintLogFile(path).read(Self.now).contains { $0.printer == "New" })
    }

    @Test func jobsDatedAheadArentKept() {
        #expect(PrintLog.add([], Self.entry(Self.now.addingTimeInterval(3 * 86_400)), Self.now).isEmpty)
        #expect(PrintLog.add([], Self.entry(Self.now.addingTimeInterval(5 * 3600)), Self.now).count == 1) // a clock a few hours off is fine
        #expect(PrintLogFile.parse([PrintLogFile.line(Self.entry(Self.utc.date(byAdding: .year, value: 5, to: Self.now)!))], Self.now).isEmpty)
    }

    /// The Mac has no command palette: the log opens from Window › Print Log (the app's), so only the Pro part is ported.
    @Test func thePaletteOpensTheLogAndItsCsvIsAProFeatureOfItsOwn() {
        #expect(Pro.title(.printLogExport) == "Print log as CSV")
        #expect(Pro.locked(.printLogExport) == "Saving the print log as CSV is part of Inkvolt Pro. The log and its month totals stay free.")
    }

    @Test func theDemoLogIsMadeUpMonthsOfJobs() {
        let demo = PrintLog.demo(Self.now, Self.utc)
        #expect(demo.count > 20)
        #expect(demo.allSatisfy { PrintLog.clean($0) != nil })
        #expect(PrintLog.months(demo, Self.utc).count >= 3)
        #expect(PrintLog.demo(Self.now, Self.utc) == demo) // the same every run for the day
    }

    // ---------------------------------------------------------------- Mac only

    /// The app reads CUPS's newest jobs each minute and all it keeps now and then: a read of the newest few forgets none of
    /// the older jobs, so the next whole read doesn't log them again.
    @Test func aReadOfTheNewestJobsForgetsNoneOfTheOlderOnes() {
        let recorder = PrintLogRecorder()
        let jobs = (1...5).map { FinishedJob(id: $0, queue: "Laser", submitted: Self.now.addingTimeInterval(-Double(600 - $0))) }
        #expect(Self.read(recorder, jobs).count == 5)
        let newer = FinishedJob(id: 6, queue: "Laser", submitted: Self.now.addingTimeInterval(-60))
        #expect(recorder.read([newer, jobs[4]], since: Self.since, now: Self.now, whole: false, known: { [] }).map(\.job) == [newer.key])
        #expect(recorder.open == 6)
        #expect(Self.read(recorder, [newer] + jobs.reversed()).isEmpty) // each job logged once
        #expect(Self.read(recorder, [newer]).isEmpty)
        #expect(recorder.open == 1) // a whole read forgets the jobs CUPS no longer keeps
    }

    /// The file made unreadable for the while, as `aFileThatCouldntBeReadIsNeverWrittenOver`.
    @Test(.enabled(if: Self.posixPermissions)) func theKeeperReadsNoJobsWhileItsFileCantBeRead() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let path = (folder as NSString).appendingPathComponent("print-log.jsonl")
        let logged = FinishedJob(id: 8, queue: "Laser", submitted: Self.now.addingTimeInterval(-120), completed: Self.now.addingTimeInterval(-60))
        let entry = try #require(PrintLogRecorder.entry(logged, now: Self.now, printerName: { $0 }))
        try Data((PrintLogFile.line(entry) + "\n").utf8).write(to: URL(fileURLWithPath: path))
        let file = PrintLogFile(path)
        let keeper = PrintLogKeeper(file, since: Self.since, clock: { Self.now })
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: path) // can't be read now
        #expect(file.jobs(Self.now) == nil)
        let later = FinishedJob(id: 9, queue: "Laser", submitted: Self.now.addingTimeInterval(-30), completed: Self.now.addingTimeInterval(-10))
        #expect(keeper.read([later, logged]) == 0) // not taken for an empty log
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        #expect(keeper.read([later, logged]) == 1) // read now: only the job it didn't hold
        #expect(Self.fileLines(path).count == 2)
    }

    @Test func aLineIsWrittenAndReadBackWithItsJob() {
        let e = PrintLogEntry(at: Self.submitted, printer: "Front \"desk\"", document: "a\\b", user: "ana", pages: 3, copies: 2, color: false,
                              twoSided: true, outcome: .cancelled, machine: "pc", printed: 0, job: "41@1795331327")
        #expect(PrintLogFile.parse([PrintLogFile.line(e)], Self.now) == [e])
    }

    @Test func aMonthIsNamedInTheInterfacesLanguage() {
        #expect(PrintLog.monthName(PrintLogMonth(year: 2026, month: 11), Locale(identifier: "en_US")) == "November 2026")
        #expect(PrintLog.monthName(PrintLogMonth(year: 2026, month: 11), Locale(identifier: "es_US")).hasPrefix("Noviembre"))
        #expect(PrintLog.csvFileName(Self.now, timeZone: TimeZone(identifier: "UTC")!) == "Print log 2026-11-22.csv")
    }

    private static var posixPermissions: Bool {
        #if os(Windows)
        false
        #else
        getuid() != 0
        #endif
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ d: Date) { value = d }
        var now: Date {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var value: Int { lock.withLock { n } }
    }
}
