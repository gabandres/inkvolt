import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// A temporary folder of made-up files. A file's text says what the fake engine makes of it: `pages=3;password=x;hang;drawfail=2`.
final class BatchFolder {
    let root: String

    init() {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-batch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func file(_ name: String, _ text: String = "pages=1") -> String {
        let path = (root as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        _ = FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        return path
    }
}

/// Opens files as the real engines do: held and fingerprinted, then read; the file's text stands for what's in it.
final class FakeDocuments: BatchDocuments {
    let opened = Mutex<[(name: String, password: String?)]>([])

    func open(_ path: String, _ password: String?, _ stop: BatchStop) async throws -> any BatchDocument {
        opened.withLock { $0.append(((path as NSString).lastPathComponent, password)) }
        let held = try BatchHeldFile.open(path)
        let text = String(decoding: held.bytes, as: UTF8.self)
        var fields: [String: String] = [:]
        for field in text.split(separator: ";") {
            let parts = field.split(separator: "=", maxSplits: 1)
            fields[String(parts[0])] = parts.count > 1 ? String(parts[1]) : ""
        }
        if fields["hang"] != nil { while !stop.isStopped { try await Task.sleep(for: .milliseconds(20)) } }
        if let needed = fields["password"], password != needed { throw BatchPasswordError() }
        if fields["damaged"] != nil { throw BatchFileError("This file is damaged.") }
        return FakeDocument(held, Int(fields["pages"]?.trimmingCharacters(in: .whitespaces) ?? "1") ?? 1, Int(fields["drawfail"] ?? "0") ?? 0, fields["hangdraw"] != nil)
    }

    final class FakeDocument: BatchDocument {
        let held: BatchHeldFile
        let pageCount: Int
        let drawFail: Int
        let hangDraw: Bool

        init(_ held: BatchHeldFile, _ pages: Int, _ drawFail: Int, _ hangDraw: Bool) {
            self.held = held
            pageCount = pages
            self.drawFail = drawFail
            self.hangDraw = hangDraw
        }

        var fingerprint: BatchFingerprint { held.fingerprint }
        var sizing: PageSizing { .actualSize }

        func render(_ page: Int, _ stop: BatchStop) async throws -> BatchPrintPage {
            try stop.check()
            if hangDraw { while true { try await Task.sleep(for: .milliseconds(20)); try stop.check() } }
            if page == drawFail { throw BatchFileError("Page \(page) can't be drawn.") }
            return BatchPrintPage([0xFF, 0xD8, 0xFF, 0xD9], 8.5, 11)
        }

        func close() {}
    }
}

/// A queue that records what it's sent: it draws every page first, as the real one does, and counts what it drew.
final class FakeQueue: BatchQueue, @unchecked Sendable {
    static let papers = [BatchPaper("na_letter_8.5x11in", "Letter"), BatchPaper("iso_a4_210x297mm", "A4")]

    let sentJobs = Mutex<[BatchPrintJob]>([])
    var canTwoSided = true
    var problemBefore: (@Sendable (Int) -> String?)? // by how many jobs were sent
    var failOn: (@Sendable (BatchPrintJob) -> (any Error)?)?
    var sheetsOverride: (@Sendable (BatchPrintJob) -> Int)?
    var beforeSpooling: (@Sendable (BatchPrintJob) -> Void)?
    var afterSent: (@Sendable (BatchPrintJob) -> Void)?
    var hangSpooling = false
    var noQueue = false

    var sent: [BatchPrintJob] { sentJobs.withLock { $0 } }

    func read() async throws -> BatchQueueInfo? {
        noQueue ? nil : BatchQueueInfo("Test queue", Self.papers, "na_letter_8.5x11in", canTwoSided: canTwoSided)
    }

    func problem() async throws -> String? { problemBefore?(sent.count) }

    func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?, onSpooling: @escaping @Sendable () -> Void,
              _ stop: BatchStop) async throws -> BatchReceipt {
        var drawn = 0
        for page in job.pages {
            try stop.check()
            _ = try await document.render(page, stop)
            drawn += 1
        }
        if let failure = failOn?(job) { throw failure }
        beforeSpooling?(job)
        try stop.check()
        onSpooling()
        if hangSpooling { await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } } // never comes back and ignores Stop, as a stuck queue would
        sentJobs.withLock { $0.append(job) }
        afterSent?(job)
        return BatchReceipt(pages: drawn, sheets: sheetsOverride?(job) ?? BatchPrintSettings.sheets(drawn, job.copies, job.twoSided))
    }
}

/// Batch print (Print roadmap 2.4): the estimate, passwords, the run and its stops, what the printer kept, a folder's files and
/// the results as CSV. Ported from BatchPrintTests.cs with the same names. Adapted: macOS can't stop another program writing,
/// renaming or deleting a file that's open, so the Mac holds the file's bytes from the moment it's opened, and
/// A_file_cant_change_or_vanish_while_its_being_sent checks that what prints is what was fingerprinted, whatever happens to
/// the file; a hidden file is a dot file; the papers are IPP's names; the CSV's folder is a Mac path. Saved lists, watched
/// folders and `print` are BatchPrintListTests, BatchPrintFolderTests and BatchPrintCommandLineTests.
struct BatchPrintTests {
    static let info = BatchQueueInfo("Test queue", FakeQueue.papers, "na_letter_8.5x11in", canTwoSided: true)

    static func line(_ path: String, _ settings: BatchPrintSettings = BatchPrintSettings(), documents: (any BatchDocuments)? = nil, password: String? = nil,
                     info: BatchQueueInfo? = nil) async throws -> BatchPrintLine {
        BatchPrintLine(path, settings, try await BatchMeasurer.measure(path, offered: password, documents ?? FakeDocuments(), ask: nil), info ?? Self.info)
    }

    static func run(_ lines: [BatchPrintLine], _ queue: FakeQueue, _ stop: BatchStop = BatchStop(), options: BatchPrintOptions = BatchPrintOptions()) async -> BatchPrintSummary {
        await BatchPrintRunner.run(lines, queue, FakeDocuments(), options: options, stop)
    }

    static func quick() -> BatchPrintOptions {
        var options = BatchPrintOptions()
        options.sendTimeout = .milliseconds(100)
        options.sendTimePerPage = .zero
        return options
    }

    // ------------------------------------------------------------------ the estimate

    @Test(arguments: [(3, 1, false, 3), (3, 2, false, 6), (3, 1, true, 2), (3, 2, true, 4), (4, 1, true, 2), (1, 1, true, 1), (5000, 99, false, 495000)])
    func Sheets_are_pages_per_side_times_copies(_ c: (pages: Int, copies: Int, twoSided: Bool, sheets: Int)) {
        #expect(BatchPrintSettings.sheets(c.pages, c.copies, c.twoSided) == c.sheets)
    }

    @Test func A_range_is_read_against_the_file_and_counts_only_its_pages() async throws {
        let f = BatchFolder()
        let line = try await Self.line(f.file("a.pdf", "pages=10"), BatchPrintSettings(copies: 2, range: "2-4, 9"))
        #expect(line.problem == nil)
        #expect(line.pages == [2, 3, 4, 9])
        #expect(line.sheets == 8)
    }

    @Test(arguments: ["11", "0-3", "two", "1-99999999"])
    func A_range_the_file_doesnt_have_is_said_and_never_becomes_all_pages(_ range: String) async throws {
        let f = BatchFolder()
        let line = try await Self.line(f.file("a.pdf", "pages=10"), BatchPrintSettings(range: range))
        #expect(line.problem?.contains("can't be printed") == true)
        #expect(line.pages.isEmpty)
        #expect(line.sheets == 0)
    }

    @Test func A_paper_or_side_the_printer_doesnt_have_is_said_not_changed_quietly() async throws {
        let f = BatchFolder()
        let path = f.file("a.pdf")
        #expect(try await Self.line(path, BatchPrintSettings(paper: "A5")).problem?.contains("A5") == true)
        #expect(try await Self.line(path, BatchPrintSettings(paper: "ISO_A4_210X297MM")).problem == nil)
        var noDuplex = Self.info
        noDuplex.canTwoSided = false
        #expect(try await Self.line(path, BatchPrintSettings(twoSided: true), info: noDuplex).problem?.contains("two-sided") == true)
    }

    @Test(arguments: [0, 100, -1])
    func Copies_out_of_bounds_are_refused(_ copies: Int) async throws {
        let f = BatchFolder()
        #expect(try await Self.line(f.file("a.pdf"), BatchPrintSettings(copies: copies)).problem?.contains("Copies") == true)
    }

    @Test(arguments: [(Int64(0), Int64(100), true), (100, 0, true), (20_000, 20_000, true), (15_000, 15_000, false)])
    func A_picture_claiming_a_huge_size_is_refused_before_decoding(_ c: (width: Int64, height: Int64, refused: Bool)) {
        #expect((BatchPrintLimits.pictureProblem(c.width, c.height) != nil) == c.refused)
    }

    @Test func A_file_of_too_many_pages_is_left_out() async throws {
        let f = BatchFolder()
        let line = try await Self.line(f.file("a.pdf", "pages=\(BatchPrintLimits.maxPages + 1)"))
        #expect(line.measure.state == .problem)
        #expect(line.problem?.contains("at most") == true)
        #expect(try await Self.line(f.file("none.pdf", "pages=0")).measure.state == .problem)
    }

    @Test func An_empty_file_a_folder_and_a_missing_file_read_as_problems_in_words() async throws {
        let f = BatchFolder()
        #expect(try await Self.line(f.file("a.pdf", "")).problem?.contains("empty") == true)
        #expect(try await Self.line((f.root as NSString).appendingPathComponent("missing.pdf")).problem?.contains("gone") == true)
        #expect(try await Self.line(f.file("b.pdf", "damaged")).problem?.contains("damaged") == true)
    }

    // ------------------------------------------------------------------ passwords

    @Test func A_locked_pdf_asks_and_the_right_password_opens_it() async throws {
        let f = BatchFolder()
        let asked = Mutex<[(String, Bool)]>([])
        let measure = try await BatchMeasurer.measure(f.file("locked.pdf", "pages=3;password=right"), offered: nil, FakeDocuments(), ask: { name, wrong in
            asked.withLock { $0.append((name, wrong)) }
            return "right"
        })
        #expect(measure.state == .ready)
        #expect(measure.pageCount == 3)
        #expect(measure.password == "right")
        #expect(asked.withLock { $0.map { "\($0.0) \($0.1)" } } == ["locked.pdf false"])
        #expect(!measure.description.contains("right"))
        #expect(!BatchPrintLine("locked.pdf", BatchPrintSettings(), measure, Self.info).description.contains("right"))
    }

    @Test func A_wrong_password_stops_asking_after_three_tries() async throws {
        let f = BatchFolder()
        let asked = Mutex<[Bool]>([])
        let measure = try await BatchMeasurer.measure(f.file("locked.pdf", "password=right"), offered: nil, FakeDocuments(), ask: { _, wrong in
            asked.withLock { $0.append(wrong) }
            return "nope"
        })
        #expect(measure.state == .wrongPassword)
        #expect(asked.withLock { $0 } == [false, true, true])
        #expect(measure.password == nil)
    }

    @Test func Declining_the_password_leaves_the_file_out() async throws {
        let f = BatchFolder()
        let measure = try await BatchMeasurer.measure(f.file("locked.pdf", "password=right"), offered: nil, FakeDocuments(), ask: { _, _ in nil })
        #expect(measure.state == .needsPassword)
    }

    @Test func With_nobody_to_ask_a_password_is_tried_once_and_only_on_a_file_that_asks() async throws {
        let f = BatchFolder()
        let documents = FakeDocuments()
        #expect(try await Self.line(f.file("locked.pdf", "password=right"), documents: documents).measure.state == .needsPassword)
        documents.opened.withLock { $0.removeAll() }
        #expect(try await Self.line(f.file("locked.pdf", "password=right"), documents: documents, password: "nope").measure.state == .wrongPassword)
        #expect(documents.opened.withLock { $0.map { "\($0.name) \($0.password ?? "-")" } } == ["locked.pdf -", "locked.pdf nope"])

        documents.opened.withLock { $0.removeAll() }
        let open = try await Self.line(f.file("open.pdf"), documents: documents, password: "secret")
        #expect(open.problem == nil)
        #expect(open.measure.password == nil)
        #expect(documents.opened.withLock { $0.map { "\($0.name) \($0.password ?? "-")" } } == ["open.pdf -"]) // a file that doesn't ask never sees it
    }

    @Test func A_file_that_hangs_the_engine_is_given_up_on_and_the_next_one_reads() async throws {
        let f = BatchFolder()
        var options = BatchPrintOptions()
        options.openTimeout = .milliseconds(100)
        let measure = try await BatchMeasurer.measure(f.file("hang.pdf", "hang"), offered: nil, FakeDocuments(), ask: nil, options: options)
        #expect(measure.state == .problem)
        #expect(measure.problem?.contains("too long") == true)
        #expect(try await BatchMeasurer.measure(f.file("ok.pdf"), offered: nil, FakeDocuments(), ask: nil, options: options).state == .ready)
    }

    // ------------------------------------------------------------------ the run

    @Test func Fifty_files_print_in_order_with_the_estimated_sheet_count() async throws {
        let f = BatchFolder()
        var lines: [BatchPrintLine] = []
        let kinds = [".pdf", ".jpg", ".png", ".tif"]
        let documents = FakeDocuments()
        var expected: [String] = []
        for i in 0..<49 {
            let name = String(format: "file %02d", i) + kinds[i % 4]
            let settings = BatchPrintSettings(copies: 1 + i % 3, twoSided: i % 3 == 0, paper: i % 5 == 0 ? "iso_a4_210x297mm" : nil)
            lines.append(try await Self.line(f.file(name, "pages=\(1 + i % 7)"), settings, documents: documents))
            expected.append(name)
        }
        let locked = try await BatchMeasurer.measure(f.file("locked.pdf", "pages=5;password=open sesame"), offered: nil, documents, ask: { _, _ in "open sesame" })
        lines.insert(BatchPrintLine((f.root as NSString).appendingPathComponent("locked.pdf"), BatchPrintSettings(), locked, Self.info), at: 20)
        expected.insert("locked.pdf", at: 20)

        let queue = FakeQueue()
        let summary = await BatchPrintRunner.run(lines, queue, documents)

        #expect(summary.sent == 50)
        #expect(queue.sent.map(\.name) == expected)
        #expect(summary.sheetsSent == lines.reduce(0) { $0 + $1.sheets })
        #expect(summary.items.map(\.sheetsSent) == lines.map(\.sheets))
        #expect(queue.sent.map(\.sheets) == lines.map(\.sheets))
        #expect(summary.exitCode == BatchPrintSummary.done)
        #expect(queue.sent[20].pages.count == 5)
    }

    @Test func A_file_that_vanishes_after_the_estimate_is_listed_and_the_batch_goes_on() async throws {
        let f = BatchFolder()
        let (a, b, c) = (f.file("a.pdf"), f.file("b.pdf"), f.file("c.pdf"))
        let lines = [try await Self.line(a), try await Self.line(b), try await Self.line(c)]
        try FileManager.default.removeItem(atPath: b)
        let queue = FakeQueue()
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.map(\.name) == ["a.pdf", "c.pdf"])
        #expect(summary.items[1].state == .failed)
        #expect(summary.items[1].message.contains("gone"))
        #expect(summary.items[1].sheetsSent == 0)
        #expect(summary.exitCode == BatchPrintSummary.someFailed)
        #expect(summary.stoppedAt == nil)
    }

    @Test func A_file_that_changes_after_the_estimate_isnt_printed() async throws {
        let f = BatchFolder()
        let (a, b) = (f.file("a.pdf", "pages=2"), f.file("b.pdf", "pages=2"))
        let lines = [try await Self.line(a), try await Self.line(b)]
        f.file("a.pdf", "pages=200")
        f.file("b.pdf", "pages=2 ") // the same page count, other bytes: what would print isn't what was seen
        let queue = FakeQueue()
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.isEmpty)
        #expect(summary.items.allSatisfy { $0.state == .failed })
        #expect(summary.items[0].message.contains("2 pages then, 200 now"))
        #expect(summary.items[1].message.contains("changed"))
    }

    @Test func A_file_cant_change_or_vanish_while_its_being_sent() async throws {
        let f = BatchFolder()
        let a = f.file("a.pdf")
        let line = try await Self.line(a)
        let queue = FakeQueue()
        queue.beforeSpooling = { _ in
            // macOS lets another program do all of this to an open file: what prints is still what was fingerprinted.
            _ = FileManager.default.createFile(atPath: a, contents: Data("pages=200".utf8))
            try? FileManager.default.moveItem(atPath: a, toPath: a + ".moved")
        }
        let summary = await Self.run([line], queue)
        #expect(summary.sent == 1)
        #expect(queue.sent.first?.pages == [1])
    }

    @Test func A_page_that_cant_be_drawn_sends_nothing_for_that_file() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("bad.pdf", "pages=4;drawfail=3")), try await Self.line(f.file("good.pdf"))]
        let queue = FakeQueue()
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.map(\.name) == ["good.pdf"])
        #expect(summary.items[0].message.contains("Page 3"))
        #expect(summary.items[0].state == .failed)
    }

    @Test func A_line_with_a_problem_is_skipped_with_its_reason_and_the_batch_goes_on() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf", "pages=2"), BatchPrintSettings(range: "5")), try await Self.line(f.file("locked.pdf", "password=x")),
                     try await Self.line(f.file("b.pdf"))]
        let queue = FakeQueue()
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.map(\.name) == ["b.pdf"])
        #expect(summary.items[0].state == .skipped)
        #expect(summary.items[1].state == .skipped)
        #expect(summary.items[1].message.contains("password"))
        #expect(summary.exitCode == BatchPrintSummary.someFailed)
        #expect(summary.text == "1 sent (1 sheet), 2 skipped.")
    }

    @Test func A_printer_with_a_problem_stops_the_batch_and_it_says_where() async throws {
        let f = BatchFolder()
        var lines: [BatchPrintLine] = []
        for i in 1...10 { lines.append(try await Self.line(f.file("f\(i).pdf"))) }
        let queue = FakeQueue()
        queue.problemBefore = { $0 == 6 ? "Paper jam" : nil }
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.count == 6)
        #expect(summary.stoppedAt == 6)
        #expect(summary.text == "Stopped at file 7 of 10 (f7.pdf): Paper jam 6 sent (6 sheets), 4 not sent.")
        #expect(summary.exitCode == BatchPrintSummary.stopped)
        #expect(summary.items.dropFirst(6).allSatisfy { $0.state == .stopped })
    }

    @Test func A_queue_that_fails_stops_the_batch_and_only_a_sure_failure_reads_as_not_sent() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf")), try await Self.line(f.file("b.pdf")), try await Self.line(f.file("c.pdf"))]

        let sureQueue = FakeQueue()
        sureQueue.failOn = { $0.name == "b.pdf" ? BatchQueueError("The queue is gone.", mayHaveSent: false) : nil }
        let sure = await Self.run(lines, sureQueue)
        #expect(sure.stoppedAt == 1)
        #expect(sure.items[1].state == .stopped)

        let unsureQueue = FakeQueue()
        unsureQueue.failOn = { $0.name == "b.pdf" ? BatchQueueError("The queue stopped.", mayHaveSent: true) : nil }
        let unsure = await Self.run(lines, unsureQueue)
        #expect(unsure.stoppedAt == 1)
        #expect(unsure.items[1].state == .failed)
        #expect(unsure.items[1].message.contains("check the queue"))
        #expect(unsure.items[2].state == .stopped)

        struct DriverSaidNo: Error {}
        let strangeQueue = FakeQueue()
        strangeQueue.failOn = { $0.name == "a.pdf" ? DriverSaidNo() : nil }
        let strange = await Self.run(lines, strangeQueue)
        #expect(strange.stoppedAt == 0)
        #expect(strange.items[0].message.contains("check the queue"))
    }

    @Test func A_setting_the_driver_wont_keep_fails_only_that_file() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf")), try await Self.line(f.file("b.pdf"))]
        let queue = FakeQueue()
        queue.failOn = { $0.name == "a.pdf" ? BatchSettingRefused("The printer wouldn't keep the paper.") : nil }
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.map(\.name) == ["b.pdf"])
        #expect(summary.items[0].state == .failed)
        #expect(summary.items[0].message.contains("Not printed"))
    }

    @Test func Stop_between_files_sends_nothing_more_and_says_where() async throws {
        let f = BatchFolder()
        var lines: [BatchPrintLine] = []
        for i in 1...5 { lines.append(try await Self.line(f.file("f\(i).pdf"))) }
        let stop = BatchStop()
        let queue = FakeQueue()
        queue.afterSent = { if $0.name == "f2.pdf" { stop.stop() } } // while the second is being handed over: it finishes
        let summary = await Self.run(lines, queue, stop)
        #expect(queue.sent.map(\.name) == ["f1.pdf", "f2.pdf"])
        #expect(summary.stoppedAt == 2)
        #expect(summary.text.contains("You stopped"))
        #expect(summary.text.contains("file 3 of 5 (f3.pdf)"))
        #expect(summary.exitCode == BatchPrintSummary.stopped)
    }

    @Test func Stop_while_a_file_is_being_drawn_sends_nothing_for_it() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf")), try await Self.line(f.file("b.pdf"))]
        let stop = BatchStop()
        let queue = FakeQueue()
        queue.beforeSpooling = { _ in stop.stop() }
        let summary = await Self.run(lines, queue, stop)
        #expect(queue.sent.isEmpty)
        #expect(summary.stoppedAt == 0)
        #expect(summary.items[0].state == .stopped)
    }

    @Test func A_drawing_that_hangs_is_given_up_on_and_the_next_file_prints() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("hang.pdf", "pages=2;hangdraw")), try await Self.line(f.file("b.pdf"))]
        let queue = FakeQueue()
        let summary = await Self.run(lines, queue, options: Self.quick())
        #expect(queue.sent.map(\.name) == ["b.pdf"])
        #expect(summary.items[0].state == .failed)
        #expect(summary.items[0].message.contains("too long"))
        #expect(summary.stoppedAt == nil)
    }

    @Test func A_spooler_that_hangs_stops_the_batch_as_the_job_may_be_there() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf")), try await Self.line(f.file("b.pdf"))]
        let queue = FakeQueue()
        queue.hangSpooling = true
        let summary = await Self.run(lines, queue, options: Self.quick())
        #expect(summary.stoppedAt == 0)
        #expect(summary.items[0].state == .failed)
        #expect(summary.items[0].message.contains("check the queue"))
        #expect(summary.items[1].state == .stopped)
    }

    @Test func A_job_that_comes_to_more_sheets_than_the_estimate_stops_the_batch() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf")), try await Self.line(f.file("b.pdf"))]
        let queue = FakeQueue()
        queue.sheetsOverride = { _ in 2 }
        let summary = await Self.run(lines, queue)
        #expect(queue.sent.count == 1)
        #expect(summary.stoppedAt == 0)
        #expect(summary.items[0].message.contains("more than the 1 estimated"))
    }

    @Test func The_job_carries_the_range_copies_side_and_paper_of_its_line_and_no_password() async throws {
        let f = BatchFolder()
        let path = f.file("a.pdf", "pages=9;password=x")
        let line = BatchPrintLine(path, BatchPrintSettings(copies: 3, range: "2,4-5", twoSided: true, paper: "iso_a4_210x297mm"),
                                  try await BatchMeasurer.measure(path, offered: "x", FakeDocuments(), ask: nil), Self.info)
        let queue = FakeQueue()
        _ = await Self.run([line], queue)
        try #require(queue.sent.count == 1)
        let job = queue.sent[0]
        #expect(job.pages == [2, 4, 5])
        #expect(job.copies == 3 && job.twoSided && job.paper == "iso_a4_210x297mm" && job.sheets == 6)
        #expect(!"\(job)".contains("\"x\""))
    }

    @Test func Resuming_a_stopped_batch_sends_only_what_wasnt_sent_so_nothing_prints_twice() async throws {
        let f = BatchFolder()
        var lines: [BatchPrintLine] = []
        for i in 1...6 { lines.append(try await Self.line(f.file("f\(i).pdf"))) }
        let problem = Atomic(true)
        let queue = FakeQueue()
        queue.problemBefore = { problem.load(ordering: .relaxed) && $0 == 2 ? "Paper jam" : nil }
        let first = await Self.run(lines, queue)
        problem.store(false, ordering: .relaxed)
        let again = first.items.filter(\.stillToSend).map { lines[$0.index] }
        let second = await Self.run(again, queue)
        #expect(queue.sent.map(\.name) == lines.map(\.name))
        #expect(second.sent == 4)
        #expect(!second.items.contains { $0.stillToSend })
    }

    @Test func A_file_that_may_have_reached_the_queue_isnt_sent_again_by_itself() async throws {
        let f = BatchFolder()
        let lines = [try await Self.line(f.file("a.pdf")), try await Self.line(f.file("b.pdf")),
                     try await Self.line(f.file("c.pdf", "pages=2"), BatchPrintSettings(range: "9"))]
        let queue = FakeQueue()
        queue.failOn = { $0.name == "b.pdf" ? BatchQueueError("The queue stopped.", mayHaveSent: true) : nil }
        let summary = await Self.run(lines, queue)
        #expect(!summary.items[0].stillToSend) // sent
        #expect(!summary.items[0].mayHaveSent)
        #expect(!summary.items[1].stillToSend)
        #expect(summary.items[1].mayHaveSent)
        #expect(summary.items[2].stillToSend) // skipped: checked again when it's sent

        let refusing = FakeQueue()
        refusing.failOn = { _ in BatchSettingRefused("No.") }
        let changed = await Self.run([try await Self.line(f.file("d.pdf"))], refusing)
        #expect(!changed.items[0].mayHaveSent) // refused before anything was sent
    }

    // ------------------------------------------------------------------ what the printer kept

    @Test func A_ticket_that_doesnt_keep_what_was_asked_is_refused() {
        let letter = (width: 612.0, height: 792.0), a4 = (width: 595.3, height: 841.9)
        #expect(BatchTicketCheck.problem(2, true, letter, 2, true, letter) == nil)
        #expect(BatchTicketCheck.problem(1, false, nil, 1, nil, a4) == nil)
        #expect(BatchTicketCheck.problem(1, false, nil, nil, false, letter) == nil)
        #expect(BatchTicketCheck.problem(1, true, nil, 1, false, letter)?.contains("two-sided") == true)
        #expect(BatchTicketCheck.problem(1, true, nil, 1, nil, letter)?.contains("two-sided") == true)
        #expect(BatchTicketCheck.problem(1, false, nil, 1, true, letter)?.contains("one-sided") == true)
        #expect(BatchTicketCheck.problem(1, false, a4, 1, false, letter)?.contains("paper") == true)
        #expect(BatchTicketCheck.problem(1, false, a4, 1, false, nil)?.contains("paper") == true)
        #expect(BatchTicketCheck.problem(5, false, nil, 3, false, letter)?.contains("3 copies") == true)
        #expect(BatchTicketCheck.problem(5, false, nil, 1, false, letter)?.contains("1 copy") == true)
    }

    // ------------------------------------------------------------------ a folder's files

    @Test func A_folder_comes_in_explorers_order_each_file_once() {
        let f = BatchFolder()
        for name in ["page 10.pdf", "page 2.pdf", "Page 1.jpg", "notes.txt", "scan.TIF", "~$draft.pdf", "a.png", ".hidden.pdf"] { f.file(name) }
        f.file("sub/below.pdf")

        let (files, leftOut) = BatchPrintFiles.expand([f.root, (f.root as NSString).appendingPathComponent("page 2.pdf")], recursive: false)
        #expect(files.map { ($0 as NSString).lastPathComponent } == ["a.png", "Page 1.jpg", "page 2.pdf", "page 10.pdf", "scan.TIF"])
        #expect(leftOut == 0)

        let below = BatchPrintFiles.expand([f.root], recursive: true).files
        // By its last two parts: the Windows PC that also runs these tests writes its own separators.
        #expect(below.contains { ($0 as NSString).lastPathComponent == "below.pdf" && (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent == "sub" })
        #expect(below.count == 6)
    }

    @Test func What_isnt_printable_is_counted_as_left_out() {
        let f = BatchFolder()
        let (files, leftOut) = BatchPrintFiles.expand([f.file("notes.txt"), (f.root as NSString).appendingPathComponent("gone.pdf"), f.file("a.pdf")], recursive: false)
        #expect(files.map { ($0 as NSString).lastPathComponent } == ["a.pdf"])
        #expect(leftOut == 2)
    }

    @Test(arguments: [("a2", "a10", -1), ("a010", "a10", -1), ("B", "a", 1), ("file", "file 1", -1), ("a", "a", 0),
                      ("99999999999999999999999", "100000000000000000000000", -1)])
    func Natural_order_compares_numbers_as_numbers(_ c: (a: String, b: String, sign: Int)) {
        #expect(NaturalOrder.compare(c.a, c.b).signum() == c.sign)
    }

    // ------------------------------------------------------------------ the results as CSV

    static func result(_ name: String, _ message: String = "Sent to the queue: 1 sheet.") -> BatchPrintResult {
        BatchPrintResult(index: 0, path: "/Users/jdoe/Docs/" + name, state: .sent, message: message, pages: 1, copies: 2, twoSided: true, paper: "iso_a4_210x297mm",
                         sheetsEstimated: 1, sheetsSent: 1, time: Date(timeIntervalSince1970: 1_793_437_500)) // 2026-10-31 09:05:00 UTC
    }

    @Test func The_csv_has_a_row_per_file() {
        let rows = BatchPrintCsv.build([Self.result("a, b.pdf")], timeZone: FleetTests.utc).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows[0].hasPrefix("Order,File,Folder,Result,Details,Pages,Copies,Two-sided,Paper,Sheets estimated,Sheets sent,Time"))
        #expect(rows[1] == #"1,"a, b.pdf",/Users/jdoe/Docs,Sent,Sent to the queue: 1 sheet.,1,2,Yes,iso_a4_210x297mm,1,1,2026-10-31 09:05:00"#)
    }

    @Test(arguments: ["=HYPERLINK(1).pdf", "+1.pdf", "-1.pdf", "@SUM(1).pdf", " =1+1.pdf", "\t=1+1.pdf", "\u{FF1D}1+1.pdf"])
    func A_file_name_that_is_a_formula_stays_words(_ name: String) {
        let cell = BatchPrintCsv.build([Self.result(name)]).components(separatedBy: "\r\n")[1].components(separatedBy: ",")[1]
        #expect(cell.drop { $0 == "\"" }.hasPrefix("'"))
    }

    @Test(arguments: ["=cmd|' /C calc'!A0", "\r=1"])
    func A_cell_is_never_a_formula_whatever_the_message(_ message: String) {
        #expect(CsvCell.of(message).drop { $0 == "\"" }.hasPrefix("'"))
    }

    @Test func Plain_text_and_quotes_are_left_as_rfc_4180_has_them() {
        #expect(CsvCell.of("report.pdf") == "report.pdf")
        #expect(CsvCell.of("say \"hi\", ok") == "\"say \"\"hi\"\", ok\"")
        #expect(CsvCell.of("") == "")
    }
}
