import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// A folder printed as it fills (roadmap 2.4, Pro). Ported from BatchPrintTests.cs's BatchPrintFolderTests with the same names.
/// Adapted: "someone still writing" is another program holding the file locked (`flock`, what an app that locks its files holds
/// on macOS; Windows' FileShare has no Mac equivalent, as Inkvolt PDF for Mac's watched folder found); Stop is a `BatchStop`;
/// the log made read-only through its permissions. One test at a time: quiet periods and polling.
@Suite(.serialized)
struct BatchPrintFolderTests {
    static var fast: BatchFolderOptions {
        var o = BatchFolderOptions()
        o.once = true
        o.pollInterval = .milliseconds(10)
        o.quietPeriod = .milliseconds(50)
        return o
    }

    static func with(_ change: (inout BatchFolderOptions) -> Void) -> BatchFolderOptions {
        var o = fast
        change(&o)
        return o
    }

    static func run(_ f: BatchFolder, _ queue: FakeQueue, _ options: BatchFolderOptions? = nil, progress: (@Sendable (BatchFolderProgress) -> Void)? = nil,
                    _ stop: BatchStop = BatchStop()) async throws -> BatchFolderSummary {
        try await BatchPrintFolder.run(f.root, queue, FakeDocuments(), options ?? fast, progress: progress, stop)
    }

    static func names(_ f: BatchFolder, _ sub: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: (f.root as NSString).appendingPathComponent(sub))) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    static func exists(_ f: BatchFolder, _ name: String) -> Bool {
        FileManager.default.fileExists(atPath: (f.root as NSString).appendingPathComponent(name))
    }

    static func logText(_ f: BatchFolder) -> String {
        (try? String(contentsOfFile: (f.root as NSString).appendingPathComponent(BatchPrintFolder.logName), encoding: .utf8)) ?? ""
    }

    /// Waits up to `seconds` for `done`.
    static func until(_ seconds: Double = 6, _ done: () -> Bool) async {
        let end = Date().addingTimeInterval(seconds)
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func Files_print_in_name_order_once_and_move_to_done() async throws {
        let f = BatchFolder()
        f.file("b 10.pdf", "pages=2")
        f.file("b 2.pdf")
        f.file("a.jpg")
        f.file("notes.txt")
        let queue = FakeQueue()
        let summary = try await Self.run(f, queue)
        #expect(queue.sent.map(\.name) == ["a.jpg", "b 2.pdf", "b 10.pdf"])
        #expect((summary.sent, summary.failed, summary.sheetsSent) == (3, 0, 4))
        #expect(Self.names(f, "done") == ["a.jpg", "b 10.pdf", "b 2.pdf"])
        #expect(Self.exists(f, "notes.txt"))
        #expect(Self.names(f, "working").isEmpty)
        #expect(Self.logText(f).split(separator: "\n").count == 3)
    }

    @Test func A_restart_prints_nothing_twice() async throws {
        let f = BatchFolder()
        f.file("a.pdf")
        let queue = FakeQueue()
        _ = try await Self.run(f, queue)
        _ = try await Self.run(f, queue)
        #expect(queue.sent.count == 1)
        #expect(Self.names(f, "done") == ["a.pdf"])
    }

    @Test func A_file_left_working_by_a_crash_goes_to_failed_and_never_prints_by_itself() async throws {
        let f = BatchFolder()
        f.file("working/sent before the crash.pdf")
        let queue = FakeQueue()
        let entries = Guarded<[BatchFolderEntry]>([])
        let summary = try await Self.run(f, queue, progress: { p in
            if let e = p.finished { entries.change { $0.append(e) } }
        })
        #expect(queue.sent.isEmpty)
        #expect(summary.failed == 1)
        #expect(Self.names(f, "failed") == ["sent before the crash.pdf"])
        #expect(entries.value.first?.message.contains("may have printed") == true)
    }

    @Test func A_file_someone_is_still_writing_isnt_taken() async throws {
        let f = BatchFolder()
        let path = f.file("slow copy.pdf")
        let held = DropFolder.hold(path) // another program has it locked while it writes
        #expect(held != nil)
        let queue = FakeQueue()
        _ = try await Self.run(f, queue)
        #expect(queue.sent.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
        held?.release()
        let after = FakeQueue()
        _ = try await Self.run(f, after)
        #expect(after.sent.count == 1)
    }

    @Test func A_file_still_growing_waits_until_it_has_stopped() async throws {
        let f = BatchFolder()
        let path = f.file("growing.pdf")
        let stop = BatchStop()
        let queue = FakeQueue()
        // The writes come every 50 ms for a second, far inside the quiet period, so a stalled timer on a busy runner can't
        // open a quiet gap between two of them.
        let options = Self.with {
            $0.once = false
            $0.quietPeriod = .seconds(2)
        }
        let root = f.root
        let run = Task { try await BatchPrintFolder.run(root, queue, FakeDocuments(), options, progress: nil, stop) }
        let started = Date()
        while Date().timeIntervalSince(started) < 1 {
            try await Task.sleep(for: .milliseconds(50))
            let handle = FileHandle(forWritingAtPath: path)
            _ = try handle?.seekToEnd()
            try handle?.write(contentsOf: Data(" ".utf8))
            try handle?.close()
            #expect(queue.sent.isEmpty)
        }
        await Self.until(15) { !queue.sent.isEmpty }
        #expect(queue.sent.count == 1)
        stop.stop()
        _ = try await run.value
    }

    static let cutOff: [(String, [UInt8])] = [
        ("half.pdf", Array("%PDF-1.4\n1 0 obj\n<<>>\nendobj\n".utf8)),
        ("half.jpg", [0xFF, 0xD8, 0xFF, 0xE0, 0, 16, 1, 2, 3, 4]),
        ("half.png", [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]),
        ("tiny.pdf", [0x25]),
    ]

    @Test(arguments: cutOff)
    func A_file_that_stops_short_of_its_end_waits_then_fails_and_never_prints(_ name: String, _ bytes: [UInt8]) async throws {
        let f = BatchFolder()
        let path = (f.root as NSString).appendingPathComponent(name)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        let queue = FakeQueue()
        _ = try await Self.run(f, queue)
        #expect(queue.sent.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path)) // still there for when the rest arrives

        let stop = BatchStop()
        let options = Self.with {
            $0.once = false
            $0.cutOffLimit = .milliseconds(100)
        }
        let root = f.root
        let run = Task { try await BatchPrintFolder.run(root, queue, FakeDocuments(), options, progress: nil, stop) }
        await Self.until { Self.exists(f, "failed/" + name) }
        stop.stop()
        let summary = try await run.value
        #expect(queue.sent.isEmpty)
        #expect(summary.failed == 1)
        #expect(Self.names(f, "failed") == [name])
    }

    @Test func Whole_files_read_as_whole() {
        #expect(BatchPrintFolder.looksWhole(BatchPrintSamples.pdf(2, "x")))
        #expect(BatchPrintFolder.looksWhole(BatchPrintSamples.jpeg(16, 16)))
        #expect(BatchPrintFolder.looksWhole(BatchPrintSamples.png(4, 4)))
        #expect(BatchPrintFolder.looksWhole(BatchPrintSamples.tiff(2, 4, 4)))
    }

    @Test func A_second_watcher_is_refused() async throws {
        let f = BatchFolder()
        let stop = BatchStop()
        let root = f.root
        let options = Self.with { $0.once = false }
        let run = Task { try await BatchPrintFolder.run(root, FakeQueue(), FakeDocuments(), options, progress: nil, stop) }
        try await Task.sleep(for: .milliseconds(100))
        await #expect(throws: BatchFolderBusyError.self) { _ = try await Self.run(f, FakeQueue()) }
        stop.stop()
        _ = try await run.value
    }

    @Test func A_folder_inkvolt_pdf_watches_is_refused_too() async throws {
        // Both apps use "working", and each takes what's left there as interrupted: they must not share a folder.
        let f = BatchFolder()
        let held = DropFolder.lock(f.root)
        #expect(held != nil)
        await #expect(throws: BatchFolderBusyError.self) { _ = try await Self.run(f, FakeQueue()) }
        #expect(DropFolder.lockName == ".inkvolt-watch.lock") // the name Inkvolt PDF for Mac's watched folder holds (WatchedFolder)
        held?.release()
    }

    @Test func A_file_that_needs_a_password_goes_to_failed_with_nobody_asked() async throws {
        let f = BatchFolder()
        f.file("locked.pdf", "password=x")
        f.file("open.pdf")
        let queue = FakeQueue()
        let summary = try await Self.run(f, queue)
        #expect(queue.sent.map(\.name) == ["open.pdf"])
        #expect((summary.sent, summary.failed) == (1, 1))
        #expect(Self.names(f, "failed") == ["locked.pdf"])
        #expect(Self.logText(f).contains("password"))
    }

    @Test func A_given_password_opens_a_locked_file_once() async throws {
        let f = BatchFolder()
        f.file("locked.pdf", "pages=3;password=x")
        let summary = try await Self.run(f, FakeQueue(), Self.with { $0.password = "x" })
        #expect(summary.sheetsSent == 3)
    }

    @Test func A_file_over_the_runs_sheets_fails_and_one_that_would_pass_them_waits_in_the_folder() async throws {
        let f = BatchFolder()
        f.file("1 big.pdf", "pages=50")
        f.file("2 fits.pdf", "pages=8")
        f.file("3 passes.pdf", "pages=8")
        let queue = FakeQueue()
        let summary = try await Self.run(f, queue, Self.with { $0.maxSheets = 10 })
        #expect(queue.sent.map(\.name) == ["2 fits.pdf"])
        #expect(Self.names(f, "failed") == ["1 big.pdf"])
        #expect(Self.exists(f, "3 passes.pdf"))
        #expect(summary.stopReason?.contains("10") == true)
    }

    @Test func While_the_printer_has_a_problem_files_stay_in_the_folder_and_print_after() async throws {
        let f = BatchFolder()
        f.file("a.pdf")
        let problem = Guarded<String?>("Paper jam")
        let said = Guarded<[String?]>([])
        let queue = FakeQueue()
        queue.problemBefore = { _ in problem.value }
        let once = try await Self.run(f, queue, progress: { p in said.change { $0.append(p.waiting) } })
        #expect(once.stopReason == "Paper jam")
        #expect(queue.sent.isEmpty)
        #expect(Self.exists(f, "a.pdf"))
        #expect(said.value.contains("Paper jam"))

        let stop = BatchStop()
        let root = f.root
        let options = Self.with { $0.once = false }
        let run = Task { try await BatchPrintFolder.run(root, queue, FakeDocuments(), options, progress: nil, stop) }
        try await Task.sleep(for: .milliseconds(200))
        #expect(queue.sent.isEmpty)
        problem.change { $0 = nil }
        await Self.until { !queue.sent.isEmpty }
        #expect(queue.sent.count == 1)
        stop.stop()
        _ = try await run.value
    }

    @Test func A_queue_that_fails_for_sure_puts_the_file_back_and_one_that_may_have_sent_doesnt() async throws {
        let f = BatchFolder()
        f.file("a.pdf")
        let sureQueue = FakeQueue()
        sureQueue.failOn = { _ in BatchQueueError("The queue is gone.", mayHaveSent: false) }
        let sure = try await Self.run(f, sureQueue)
        #expect(sure.failed == 0)
        #expect(Self.exists(f, "a.pdf"))

        let unsureQueue = FakeQueue()
        unsureQueue.failOn = { _ in BatchQueueError("The spooler stopped.", mayHaveSent: true) }
        let unsure = try await Self.run(f, unsureQueue)
        #expect(unsure.failed == 1)
        #expect(Self.names(f, "failed") == ["a.pdf"])
        #expect(Self.logText(f).contains("check the queue"))
    }

    @Test func Stop_while_a_file_is_being_drawn_puts_it_back_for_next_time() async throws {
        let f = BatchFolder()
        f.file("a.pdf")
        let stop = BatchStop()
        let queue = FakeQueue()
        queue.beforeSpooling = { _ in stop.stop() }
        _ = try await Self.run(f, queue, Self.with { $0.once = false }, stop)
        #expect(queue.sent.isEmpty)
        #expect(Self.exists(f, "a.pdf"))
        #expect(Self.names(f, "working").isEmpty)
    }

    @Test func A_name_with_control_characters_doesnt_break_the_log() {
        #expect(BatchPrintText.clean("a\u{1B}b") == "a b")
        let entry = BatchFolderEntry(time: Date(timeIntervalSince1970: 1_793_404_800), fileName: "a\tb.pdf", state: .sent, message: "x\ny", sheetsSent: 1, movedTo: nil)
        #expect(entry.logLine.split(separator: "\t", omittingEmptySubsequences: false).count == 5)
    }

    @Test(arguments: [("=1+1.pdf", "'=1+1.pdf"), ("@SUM(A1).pdf", "'@SUM(A1).pdf"), ("plain, name.pdf", "plain, name.pdf")])
    func The_log_for_a_spreadsheet_cant_run_a_file_name_as_a_formula(_ c: (name: String, logged: String)) {
        let line = BatchFolderEntry(time: Date(timeIntervalSince1970: 1_793_491_200), fileName: c.name, state: .sent, message: "=2+2", sheetsSent: 1, movedTo: nil)
            .logLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        #expect(line[2] == c.logged)
        #expect(line[3] == "'=2+2")
    }

    @Test func A_log_that_cant_be_written_stops_nothing_and_loses_no_count() async throws {
        let f = BatchFolder()
        f.file("a.pdf")
        f.file("b.pdf")
        let log = f.file(BatchPrintFolder.logName, "")
        try FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: log)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: log) }
        let queue = FakeQueue()
        let summary = try await Self.run(f, queue)
        #expect(summary.sent == 2)
        #expect(queue.sent.count == 2)
    }

    @Test func Existing_files_are_counted_before_a_watch_starts() {
        let f = BatchFolder()
        f.file("a.pdf")
        f.file("b.jpg")
        f.file("c.txt")
        #expect(BatchPrintFolder.readyToPrint(f.root) == 2)
    }
}

/// A value several tasks read and change (a test's own record of what it was told).
final class Guarded<T: Sendable>: Sendable {
    private let state: Mutex<T>

    init(_ value: T) { state = Mutex(value) }

    var value: T { state.withLock { $0 } }

    func change(_ body: (inout T) -> Void) { state.withLock { body(&$0) } }
}
