import Foundation
import Testing
@testable import PrintCore

/// `print`, run in-process: lines, exit codes the same as Inkvolt PDF's, nothing sent when something's wrong. Ported from
/// BatchPrintTests.cs's BatchPrintCommandLineTests with the same names; under `ProGated`, since they read the gate. Adapted:
/// Ctrl+C is a `BatchStop`; the papers are IPP's names; another computer's file is under /net; what's written goes to two
/// closures (the app's entry passes standard output and standard error).
extension ProGated {
@Suite final class BatchPrintCommandLineTests {
    final class Host: BatchPrintHost {
        let queue: FakeQueue
        let documents: any BatchDocuments

        init(_ queue: FakeQueue, documents: (any BatchDocuments)? = nil) {
            self.queue = queue
            self.documents = documents ?? FakeDocuments()
        }

        func findPrinter(_ name: String) async throws -> any BatchQueue {
            guard name == "Office laser" else { throw BatchCommandError("There is no printer \"\(name)\".") }
            return queue
        }
    }

    let f = BatchFolder()
    let out = Guarded("")
    let err = Guarded("")
    let queue = FakeQueue()

    init() {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    deinit {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    func run(_ args: [String], env: (@Sendable (String) -> String?)? = nil, queue: FakeQueue? = nil, _ stop: BatchStop = BatchStop()) async -> Int32 {
        let out = out, err = err
        return await BatchPrintCommandLine.run(args, Host(queue ?? self.queue), environment: env ?? { _ in nil }, folderQuiet: .milliseconds(50),
                                               folderPoll: .milliseconds(10), stop, output: { line in out.change { $0 += line + "\n" } },
                                               error: { line in err.change { $0 += line + "\n" } })
    }

    func list(_ files: String...) -> String {
        let path = (f.root as NSString).appendingPathComponent("list" + BatchPrintList.fileExtension)
        try? BatchPrintList.save(path, files.map { BatchListEntry($0, BatchPrintSettings()) })
        return path
    }

    func clearSent() { queue.sentJobs.withLock { $0.removeAll() } }

    @Test func Its_exit_codes_are_inkvolt_pdfs() {
        // PdfCore's BatchCommandLine: done 0, someFailed 1, wrong 2, stopped 3
        #expect((BatchPrintSummary.done, BatchPrintSummary.someFailed, BatchPrintSummary.wrong, BatchPrintSummary.stopped) == (0, 1, 2, 3))
    }

    @Test func Only_print_is_a_command() {
        #expect(BatchPrintCommandLine.isCommand(["print", "--list", "x"]))
        #expect(BatchPrintCommandLine.isCommand(["PRINT"]))
        #expect(!BatchPrintCommandLine.isCommand([]))
        #expect(!BatchPrintCommandLine.isCommand(["report.pdf"]))
        #expect(!BatchPrintCommandLine.isCommand(["--demo", "print"]))
    }

    @Test func A_list_prints_in_order_and_exits_0() async {
        let list = list(f.file("b.pdf", "pages=2"), f.file("a.pdf"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 0)
        #expect(queue.sent.map(\.name) == ["b.pdf", "a.pdf"])
        #expect(out.value.contains("Estimate: 2 files, 3 sheets on Test queue."))
        #expect(out.value.contains("2 sent (3 sheets)."))
    }

    @Test func A_file_that_fails_exits_1_and_the_rest_still_print() async {
        let gone = (f.root as NSString).appendingPathComponent("gone.pdf")
        let list = list(gone, f.file("a.pdf"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 1)
        #expect(queue.sent.map(\.name) == ["a.pdf"])
        #expect(err.value.contains("gone.pdf"))
    }

    @Test(arguments: [[], ["--printer", "Office laser"], ["a.pdf"], ["--list", "a", "--watch", "b", "--printer", "Office laser"],
                      ["--list", "a", "--printer", "Office laser", "--copies", "2"], ["a.pdf", "--printer", "Office laser", "--copies", "100"],
                      ["a.pdf", "--printer", "Office laser", "--max-sheets", "none"], ["a.pdf", "--printer", "Office laser", "--once"],
                      ["a.pdf", "--printer"], ["a.pdf", "--printer", "Office laser", "--nonsense"]])
    func A_wrong_command_line_exits_2_with_nothing_sent(_ rest: [String]) async {
        #expect(await run(["print"] + rest) == 2)
        #expect(queue.sent.isEmpty)
        #expect(err.value.contains("--help"))
    }

    @Test func Help_exits_0() async {
        #expect(await run(["print", "--help"]) == 0)
        #expect(out.value.contains("Exit codes"))
    }

    @Test func An_unknown_printer_a_bad_list_or_missing_input_exits_2() async {
        let list = list(f.file("a.pdf"))
        #expect(await run(["print", "--list", list, "--printer", "Nobody"]) == 2)
        #expect(err.value.contains("no printer"))
        #expect(await run(["print", "--list", f.file("bad.inkvoltlist", "nonsense"), "--printer", "Office laser"]) == 2)
        #expect(await run(["print", "--list", (f.root as NSString).appendingPathComponent("none"), "--printer", "Office laser"]) == 2)
        #expect(await run(["print", (f.root as NSString).appendingPathComponent("none.pdf"), "--printer", "Office laser"]) == 2)
        let none = FakeQueue()
        none.noQueue = true
        #expect(await run(["print", "--list", list, "--printer", "Office laser"], queue: none) == 2)
        #expect(queue.sent.isEmpty)
    }

    @Test func A_list_reaching_another_computer_exits_2_until_allowed_and_the_disk_isnt_touched() async {
        let list = f.file("net.inkvoltlist", #"{ "version": 1, "files": [ { "path": "/net/files01/share/a.pdf" } ] }"#)
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 2)
        #expect(err.value.contains("files01"))
        #expect(err.value.contains("--allow-network"))
    }

    @Test func Over_max_sheets_exits_2_before_the_first_sheet() async {
        let list = list(f.file("a.pdf", "pages=60"), f.file("b.pdf", "pages=50"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser", "--max-sheets", "100"]) == 2)
        #expect(queue.sent.isEmpty)
        #expect(err.value.contains("110 sheets"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser", "--max-sheets", "110"]) == 0)
        #expect(queue.sent.count == 2)
    }

    @Test func The_default_max_sheets_stops_a_runaway_list() async {
        let path = f.file("a.pdf", "pages=600")
        let list = list(path)
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 2)
        #expect(queue.sent.isEmpty)
    }

    @Test func A_dry_run_only_estimates() async {
        let list = list(f.file("a.pdf", "pages=4"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser", "--dry-run"]) == 0)
        #expect(queue.sent.isEmpty)
        #expect(out.value.contains("4 sheets"))
    }

    @Test func A_locked_file_uses_the_variable_once_and_is_skipped_without_it() async {
        let path = f.file("locked.pdf", "pages=2;password=right")
        let list = list(path, f.file("open.pdf"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 1)
        #expect(queue.sent.map(\.name) == ["open.pdf"])

        clearSent()
        let wrong: @Sendable (String) -> String? = { $0 == BatchPrintCommandLine.passwordVariable ? "wrong" : nil }
        #expect(await run(["print", "--list", list, "--printer", "Office laser"], env: wrong) == 1)
        #expect(queue.sent.map(\.name) == ["open.pdf"])

        clearSent()
        let right: @Sendable (String) -> String? = { $0 == BatchPrintCommandLine.passwordVariable ? "right" : nil }
        #expect(await run(["print", "--list", list, "--printer", "Office laser"], env: right) == 0)
        #expect(queue.sent.map(\.name) == ["locked.pdf", "open.pdf"])
        #expect(!out.value.contains("right"))
    }

    @Test func A_printer_problem_exits_3_and_says_where() async {
        let list = list(f.file("a.pdf"), f.file("b.pdf"))
        let jammed = FakeQueue()
        jammed.problemBefore = { $0 == 1 ? "Paper jam" : nil }
        #expect(await run(["print", "--list", list, "--printer", "Office laser"], queue: jammed) == 3)
        #expect(out.value.contains("Stopped at file 2 of 2 (b.pdf): Paper jam"))
    }

    @Test func Stopping_exits_3() async {
        let list = list(f.file("a.pdf"), f.file("b.pdf"))
        let stop = BatchStop()
        let stopping = FakeQueue()
        stopping.afterSent = { _ in stop.stop() }
        #expect(await run(["print", "--list", list, "--printer", "Office laser"], queue: stopping, stop) == 3)
        #expect(stopping.sent.count == 1)

        let already = BatchStop()
        already.stop()
        #expect(await run(["print", "--list", list, "--printer", "Office laser"], already) == 3)
    }

    @Test func The_report_is_a_csv_of_each_file_and_a_bad_report_path_exits_2_first() async throws {
        let list = list(f.file("=1+1.pdf"), (f.root as NSString).appendingPathComponent("gone.pdf"))
        let report = (f.root as NSString).appendingPathComponent("results.csv")
        #expect(await run(["print", "--list", list, "--printer", "Office laser", "--report", report]) == 1)
        let text = try String(contentsOfFile: report, encoding: .utf8)
        let rows = text.trimmingCharacters(in: CharacterSet(charactersIn: "\u{FEFF}")).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(rows.count == 3)
        #expect(rows[1].contains("'=1+1.pdf,"))
        #expect(rows[1].contains("Sent,"))
        #expect(rows[2].contains("Skipped,"))

        clearSent()
        let noFolder = ((f.root as NSString).appendingPathComponent("no folder") as NSString).appendingPathComponent("r.csv")
        #expect(await run(["print", "--list", list, "--printer", "Office laser", "--report", noFolder]) == 2)
        #expect(await run(["print", "--list", list, "--printer", "Office laser", "--report", (f.root as NSString).appendingPathComponent("r.command")]) == 2)
        #expect(queue.sent.isEmpty)
    }

    @Test func Files_given_directly_print_with_the_settings_given() async {
        f.file("in/b 10.pdf")
        f.file("in/b 2.pdf")
        let args = ["print", (f.root as NSString).appendingPathComponent("in"), "--printer", "Office laser", "--copies", "2", "--two-sided", "--paper", "iso_a4_210x297mm"]
        #expect(await run(args) == 0)
        #expect(queue.sent.map(\.name) == ["b 2.pdf", "b 10.pdf"])
        #expect(queue.sent.allSatisfy { $0.copies == 2 && $0.twoSided && $0.paper == "iso_a4_210x297mm" })
    }

    @Test func A_setting_the_printer_doesnt_have_skips_the_files_rather_than_changing_it() async {
        let a = f.file("a.pdf")
        #expect(await run(["print", a, "--printer", "Office laser", "--paper", "Tabloid"]) == 1)
        #expect(queue.sent.isEmpty)
        #expect(err.value.contains("Tabloid"))
    }

    @Test func Control_characters_in_a_name_dont_reach_the_terminal() async {
        let list = f.file("esc.inkvoltlist", #"{ "version": 1, "files": [] }"#)
        #expect(BatchPrintText.clean("a\u{1B}[31mred.pdf") == "a [31mred.pdf")
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 2)
    }

    @Test func Without_pro_it_says_so_and_exits_2_with_nothing_sent() async {
        Pro.store = MemoryProStore()
        Pro.enforced = true
        let list = list(f.file("a.pdf"))
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 2)
        #expect(queue.sent.isEmpty)
        #expect(err.value.contains("Inkvolt Pro"))
        #expect(!namesAPriceOrAShop(err.value), "\(err.value)") // Mac difference: the App Store copy (PLAN.md P12 1.6)
        #expect(BatchPrintCsv.export([]) == nil)
        Pro.enforced = false
        #expect(BatchPrintCsv.export([]) != nil)
    }

    @Test func Watch_once_handles_whats_there_and_a_locked_folder_exits_2() async throws {
        f.file("a.pdf")
        f.file("locked.pdf", "password=x")
        #expect(await run(["print", "--watch", f.root, "--printer", "Office laser", "--once"]) == 1)
        #expect(queue.sent.map(\.name) == ["a.pdf"])
        #expect(await run(["print", "--watch", (f.root as NSString).appendingPathComponent("none"), "--printer", "Office laser", "--once"]) == 2)
        #expect(await run(["print", "--watch", f.root, "--printer", "Office laser", "--paper", "Tabloid", "--once"]) == 2)

        let stop = BatchStop()
        var options = BatchFolderOptions()
        options.pollInterval = .milliseconds(10)
        let root = f.root, chosen = options
        let watching = Task { try await BatchPrintFolder.run(root, FakeQueue(), FakeDocuments(), chosen, progress: nil, stop) }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await run(["print", "--watch", f.root, "--printer", "Office laser", "--once"]) == 2)
        #expect(err.value.contains("already watched"))
        stop.stop()
        _ = try await watching.value
    }

    @Test func Watch_stops_at_max_sheets_with_exit_3() async {
        f.file("1.pdf", "pages=3")
        f.file("2.pdf", "pages=3")
        #expect(await run(["print", "--watch", f.root, "--printer", "Office laser", "--once", "--max-sheets", "4"]) == 3)
        #expect(queue.sent.count == 1)
        #expect(FileManager.default.fileExists(atPath: (f.root as NSString).appendingPathComponent("2.pdf")))
    }

    @Test func A_file_given_that_cant_be_printed_exits_2_with_nothing_sent() async {
        let pdf = f.file("a.pdf")
        let notes = f.file("notes.docx")
        #expect(await run(["print", pdf, notes, "--printer", "Office laser"]) == 2)
        #expect(queue.sent.isEmpty)
        #expect(err.value.contains("notes.docx"))
    }

    @Test(arguments: [#"{ "version": 1, "files": [null] }"#, #"{ "version": 1, "files": [{ "path": "a.pdf" }, null] }"#])
    func A_list_with_an_empty_line_is_refused_not_a_crash(_ json: String) async {
        f.file("a.pdf")
        let list = f.file("bad.inkvoltlist", json)
        #expect(await run(["print", "--list", list, "--printer", "Office laser"]) == 2)
        #expect(queue.sent.isEmpty)
    }

    @Test func Stopping_a_watch_once_with_files_left_exits_3() async {
        f.file("a.pdf")
        f.file("b.pdf")
        let stop = BatchStop()
        let stopping = FakeQueue()
        stopping.afterSent = { _ in stop.stop() }
        #expect(await run(["print", "--watch", f.root, "--printer", "Office laser", "--once"], queue: stopping, stop) == 3)
        #expect(stopping.sent.count == 1)
        #expect(FileManager.default.fileExists(atPath: (f.root as NSString).appendingPathComponent("b.pdf")))
    }
}
}
