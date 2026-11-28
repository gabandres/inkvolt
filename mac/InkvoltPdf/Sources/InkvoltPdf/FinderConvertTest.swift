import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for Finder's Convert to Word (`--only-finder-convert`, on the synthetic text document): one
/// file with the window up shows the one-click's notice there; Finder's service with several files (one missing, one a
/// path into /dev) lists each in the conversions window, writes name.docx beside each PDF, never over a file, and says
/// what was left out; Cancel stops the one running and those waiting. Only names and counts are written.
@MainActor
struct FinderConvertTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[finder-convert] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func settle(_ ms: Int) async { try? await Task.sleep(for: .milliseconds(ms)) }

    /// Waits for the gathered requests and conversions to end (at most a minute).
    private func waitDone() async {
        await settle(Int(ConvertGather.quiet * 1000) + 200)
        let until = Date().addingTimeInterval(60)
        while FinderConvert.converting && Date() < until { await settle(100) }
    }

    private func size(_ path: String) -> Int { ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int) ?? 0 }

    mutating func run() async {
        lines.append("== \(name): Finder's Convert to Word")
        DocumentWindowController.atOnceRecognizer = { _, _, _ in [] } // no Vision model to load
        defer { DocumentWindowController.atOnceRecognizer = nil }
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-finder-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        guard let data = controller.pdf.session?.data else { return check(false, "the synthetic document has its bytes") }
        let files = ["report.pdf", "Q3.final.pdf", "CON.pdf"].map { (folder as NSString).appendingPathComponent($0) }
        for f in files { FileManager.default.createFile(atPath: f, contents: Data(data)) }
        let theirs = (folder as NSString).appendingPathComponent("report.docx")
        FileManager.default.createFile(atPath: theirs, contents: Data("the user's own file".utf8))

        // One file with the window up: the one-click's notice, in that window, no list.
        controller.window?.makeKeyAndOrderFront(nil)
        FinderConvert.route(ConvertCommand.tryParse(["--convert-to", "word", files[0]]).request!)
        await waitDone()
        let first = (folder as NSString).appendingPathComponent("report (2).docx")
        // The window in front gets it: over SSH, with a locked screen, that may be the other synthetic document's.
        let notice = NSDocumentController.shared.documents.compactMap { ($0.windowControllers.first as? DocumentWindowController)?.noticeBar.message }
            .first { $0.contains("report (2).docx") } ?? ""
        check(size(first) > 0 && !FinderConvert.listOpen && notice.contains("report (2).docx")
              && (try? String(contentsOfFile: theirs, encoding: .utf8)) == "the user's own file",
              "one file, window up: report (2).docx beside it (\(size(first)) bytes, never over report.docx), the notice \"\(notice.prefix(60))\", no list")

        // A request within ConvertGather.settle of the notice folds it into the list (Windows' rule): this one waits.
        await settle(Int(ConvertGather.settle * 1000) + 200)

        // Finder's service with the other two, a missing one and a path into /dev: one list, each file's line.
        let board = NSPasteboard(name: NSPasteboard.Name("inkvolt-selftest-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.clearContents()
        let missing = (folder as NSString).appendingPathComponent("gone.pdf")
        board.writeObjects([files[1], files[2], missing, "/dev/null"].map { URL(fileURLWithPath: $0) as NSURL })
        var error: NSString?
        ServiceProvider.shared.convertToWord(board, userData: nil, error: &error)
        await waitDone()
        let made = ["Q3.final.docx", "_CON.docx"].map { (folder as NSString).appendingPathComponent($0) }
        let list = NSApp.windows.compactMap { $0.windowController as? ConvertWindowController }.first
        let rows = list?.rowLabels ?? []
        check(error == nil && made.allSatisfy { size($0) > 0 } && FinderConvert.jobs.suffix(3).map { $0.outcome?.result } == [.saved, .saved, .notFound],
              "Finder's service, 4 files: Q3.final.docx and _CON.docx made, gone.pdf not found; /dev/null left out")
        check(list != nil && rows.count == 3 && list?.headingText == loc("{0} of {1} converted", 2, 3)
              && list?.droppedText.isEmpty == false && list?.buttonTitle == loc("Close"),
              "the conversions window: \"\(list?.headingText ?? "none")\", \(rows.count) rows, the left-out line \"\((list?.droppedText ?? "").prefix(50))\", \(list?.buttonTitle ?? "")")

        // Cancel stops the one running and those waiting; their empty reserved files go.
        FinderConvert.convertForTest = { _, cancel in
            while !cancel.isCancelled { try await Task.sleep(for: .milliseconds(20)) }
            throw CancellationError()
        }
        defer { FinderConvert.convertForTest = nil }
        FinderConvert.route(ConvertCommand.Request(.excel, files))
        await settle(Int(ConvertGather.quiet * 1000) + 300)
        let busy = list?.buttonTitle == loc("Cancel")
        NSApp.windows.compactMap { $0.windowController as? ConvertWindowController }.first?.window?.performClose(nil)
        await waitDone()
        await settle(300)
        let cancelled = FinderConvert.jobs.suffix(3).allSatisfy { $0.outcome?.result == .cancelled }
        check(busy && cancelled && !FinderConvert.listOpen,
              "closing the window while it converts cancels the three waiting and running, then closes it")

        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
