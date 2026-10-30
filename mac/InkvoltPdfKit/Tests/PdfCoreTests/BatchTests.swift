import Foundation
import Testing
@testable import PdfCore

/// Ported from BatchTests.cs (same names). Adapted: paths are Mac paths (NameTemplatesExpand… keeps the Windows rules
/// for names, so results move between the two); ExportsCommentsFormDataAndSummaries exports form data only (comments
/// and summaries come with roadmap 1.4 on the Mac); AFailureIsListed…'s "%PDF-" file that isn't one is opened by MuPDF
/// as a document without pages, which the batch fails as such; the progress callback is called on the job's task, so
/// a `Collected` list gathers it.
final class BatchTests {
    private let root: String
    private static let when: Date = {
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute) = (2026, 10, 24, 9, 30)
        return Calendar.current.date(from: c)!
    }()

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-batch-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    private func put(_ relative: String, _ bytes: [UInt8]) throws -> String {
        let path = (root as NSString).appendingPathComponent(relative)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data(bytes).write(to: URL(fileURLWithPath: path))
        return path
    }

    private var out: String { (root as NSString).appendingPathComponent("out") }

    private func p(_ parts: String...) -> String { parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) } }

    private func outFile(_ name: String) -> String { (out as NSString).appendingPathComponent(name) }

    private func plan(_ steps: BatchStep...) -> BatchPlan {
        var plan = BatchPlan(steps: steps, outputFolder: out)
        plan.date = Self.when
        return plan
    }

    private static func run(_ paths: [String], _ plan: BatchPlan, host: BatchHost = BatchHost(), progress: (@Sendable (BatchProgress) -> Void)? = nil,
                            cancel: CancelToken? = nil) async throws -> BatchSummary {
        try await BatchRunner.run(paths.map { BatchFile($0) }, plan, host, progress: progress, cancel: cancel)
    }

    private static func text(_ pdf: [UInt8], password: String? = nil, page: Int = 0) throws -> String {
        let engine = try PdfEngine.open(pdf, password: password)
        defer { engine.close() }
        return try engine.text(page).text
    }

    private static func read(_ path: String) throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path))) }
    private static func readText(_ path: String) throws -> String { try String(contentsOfFile: path, encoding: .utf8) }
    private static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    private static func files(_ folder: String) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted() }
    private static func white(_ w: Int, _ h: Int) -> [UInt8] { TestImages.png(w, h) { _, _ in (255, 255, 255, 255) } }

    // ───────────── names and files ─────────────

    @Test func nameTemplatesExpandAndStayValidFileNames() {
        #expect(BatchNames.expand("<<name>>", "/in/report.pdf", 1, Self.when) == "report")
        #expect(BatchNames.expand("<<NAME>> (signed) <<n:3>> <<date>> <<folder>>", "/in/report.pdf", 7, Self.when) == "report (signed) 007 2026-10-24 in")
        #expect(BatchNames.expand("<<date:yyyy/MM>>", "/in/a.pdf", 1, Self.when) == "2026_10") // a separator can't make a subfolder
        #expect(BatchNames.expand("a:b?c", "/in/x.pdf", 1, Self.when) == "a_b_c")
        #expect(BatchNames.expand("   ", "/in/x.pdf", 1, Self.when) == "x") // empty: the original name
        #expect(BatchNames.expand("CON", "/in/x.pdf", 1, Self.when) == "_CON") // a device name can't be a file name on Windows
        #expect(BatchNames.expand("<<name>>...", "/in/x.pdf", 1, Self.when) == "x") // Windows drops trailing dots
        #expect(BatchNames.expand("<<other>> <<name>>", "/in/x.pdf", 1, Self.when) == "__other__ x")
        #expect(BatchNames.expand(String(repeating: "a", count: 400), "/in/x.pdf", 1, Self.when).count <= BatchNames.maxLength)
        #expect(BatchNames.validate("<<name>> small") == nil)
        #expect(BatchNames.validate("") != nil)
    }

    @Test func foldersExpandToTheirPdfsAndImages() throws {
        let a = try put("in/a.pdf", TestPdf.make(1))
        try put("in/b.PNG", TestImages.png(4, 4) { _, _ in (255, 0, 0, 255) })
        try put("in/notes.txt", [1, 2, 3])
        try put("in/sub/c.pdf", TestPdf.make(1))
        try put("in/sub/deeper/d.jpg", TestImages.jpeg(8, 8))
        try put("out/old.pdf", TestPdf.make(1)) // the output folder isn't read back in

        let top = BatchFiles.expand([p("in")], recursive: false)
        #expect(top.map { ($0.path as NSString).lastPathComponent } == ["a.pdf", "b.PNG"])
        #expect(top.allSatisfy { $0.relativeFolder == "" })

        let all = BatchFiles.expand([p("in"), a, p("in", "sub", "c.pdf")], recursive: true)
        #expect(all.map { ($0.path as NSString).lastPathComponent } == ["a.pdf", "b.PNG", "c.pdf", "d.jpg"]) // no duplicates
        #expect(all.first { $0.path.hasSuffix("d.jpg") }?.relativeFolder == "sub/deeper")
        #expect(all[1].isImage)
        #expect(!all[0].isImage)

        let whole = BatchFiles.expand([root], recursive: true, excludeFolder: out)
        #expect(!whole.contains { $0.path.contains("old.pdf") })
    }

    @Test func plansAreCheckedBeforeRunning() {
        #expect(plan().validate(ocrAvailable: true) != nil) // no actions
        #expect(plan(.rotate(90)).validate(ocrAvailable: true) == nil)
        var noFolder = plan(.rotate(90))
        noFolder.outputFolder = ""
        #expect(noFolder.validate(ocrAvailable: true) != nil)
        var relative = plan(.rotate(90))
        relative.outputFolder = "relative"
        #expect(relative.validate(ocrAvailable: true) != nil)
        // Protecting comes after the other changes (they would need its password); exports may follow it.
        let protect = BatchStep.protect(ProtectStep("open", "owner", .all))
        #expect(plan(protect, .rotate(90)).validate(ocrAvailable: true) != nil)
        #expect(plan(.rotate(90), protect, .export(.text, dpi: 150)).validate(ocrAvailable: true) == nil)
        #expect(plan(protect, .protect(ProtectStep("a", "b", .all))).validate(ocrAvailable: true) != nil)
        #expect(plan(.export(.text, dpi: 150), .export(.text, dpi: 150)).validate(ocrAvailable: true) != nil)
        #expect(plan(.ocr).validate(ocrAvailable: false) != nil)
        #expect(plan(.protect(ProtectStep(nil, nil, .all))).validate(ocrAvailable: true) != nil) // no password at all
        #expect(!protect.title.contains("open")) // passwords never reach a log through the title
    }

    @Test func weightedGateKeepsTheBudget() {
        let gate = WeightedGate(100)
        #expect(gate.tryEnter(60))
        #expect(!gate.tryEnter(60))
        #expect(gate.tryEnter(40))
        gate.release(60)
        #expect(gate.tryEnter(50))
        // A job larger than the whole budget still runs, alone.
        let big = WeightedGate(100)
        #expect(big.tryEnter(500))
        #expect(!big.tryEnter(1))
        big.release(500)
        #expect(big.tryEnter(1))
    }

    // ───────────── running ─────────────

    @Test func eachFileGetsTheActionsInOrderAndASeparateResult() async throws {
        let files = [try put("in/one.pdf", TestPdf.make(2, marker: "first")), try put("in/two.pdf", TestPdf.make(1, marker: "second"))]
        let plan = plan(.rotate(90), .watermark(WatermarkOptions(text: "DRAFT")), .export(.text, dpi: 150))
        let seen = Collected<BatchProgress>()
        let summary = try await Self.run(files, plan, progress: { seen.add($0) })

        #expect(summary.done == 2)
        #expect(summary.failed == 0)
        let one = try Self.read(outFile("one.pdf"))
        let engine = try PdfEngine.open(one)
        #expect(engine.pageCount == 2)
        #expect(engine.page(0).width > engine.page(0).height) // turned: shown landscape
        #expect(try engine.text(1).text.contains("DRAFT"))
        engine.close()
        #expect(try Self.readText(outFile("two.txt")).contains("Page 1 second"))
        #expect(try Self.readText(outFile("one.txt")).contains("DRAFT")) // the export sees the earlier steps
        #expect(summary.items[0].outputs == [outFile("one.pdf"), outFile("one.txt")])
        // Originals untouched.
        #expect(try Self.read(files[0]).count == TestPdf.make(2, marker: "first").count)
        #expect(seen.all.contains { $0.index == 1 && $0.state == .running })
        #expect(seen.all.contains { $0.index == 1 && $0.state == .done })
        #expect(summary.text == "2 done.")
    }

    @Test func existingFilesAreNeverOverwrittenUnlessAsked() async throws {
        let a = try put("in/a.pdf", TestPdf.make(1))
        try put("out/a.pdf", [1])
        var summary = try await Self.run([a], plan(.rotate(180)))
        #expect(summary.done == 1)
        #expect(try Self.read(outFile("a.pdf")) == [1])
        #expect(Self.exists(outFile("a (2).pdf")))

        var overwrite = plan(.rotate(180))
        overwrite.neverOverwrite = false
        summary = try await Self.run([a], overwrite)
        #expect(try Self.read(outFile("a.pdf")) != [1])
        #expect(!Self.exists(outFile("a (3).pdf")))

        // Writing into the input folder never replaces an input, even with overwriting allowed.
        var inPlace = plan(.rotate(90))
        inPlace.neverOverwrite = false
        inPlace.outputFolder = (a as NSString).deletingLastPathComponent
        let result = try await Self.run([a], inPlace)
        #expect(result.done == 1)
        #expect(try Self.read(a).count == TestPdf.make(1).count)
        #expect(Self.exists(p("in", "a (2).pdf")))
    }

    @Test func twoInputsWithTheSameNameGetTwoOutputs() async throws {
        let x = try put("in/x/report.pdf", TestPdf.make(1, marker: "x"))
        let y = try put("in/y/report.pdf", TestPdf.make(1, marker: "y"))
        var plan = plan(.rotate(90))
        plan.keepSubfolders = false
        plan.neverOverwrite = false
        let summary = try await Self.run([x, y], plan)
        #expect(summary.done == 2)
        #expect(Self.files(out).count == 2)
    }

    @Test func subfoldersAreKeptBelowTheOutputFolder() async throws {
        try put("in/top.pdf", TestPdf.make(1))
        try put("in/sub/inner.pdf", TestPdf.make(1))
        let files = BatchFiles.expand([p("in")], recursive: true)
        let summary = try await BatchRunner.run(files, plan(.rotate(90)), BatchHost())
        #expect(summary.done == 2)
        #expect(Self.exists(outFile("top.pdf")))
        #expect(Self.exists(p("out", "sub", "inner.pdf")))
    }

    @Test func aFailureIsListedAndTheBatchGoesOn() async throws {
        let bad = try put("in/broken.pdf", Array("%PDF-1.7\nthis is not a pdf at all".utf8))
        let notPdf = try put("in/fake.pdf", Array("hello".utf8))
        let good = try put("in/good.pdf", TestPdf.make(1))
        let summary = try await Self.run([bad, notPdf, good], plan(.rotate(90)))
        #expect(summary.done == 1)
        #expect(summary.failed == 2)
        #expect(summary.items[0].state == .failed)
        #expect(!summary.items[0].message.trimmingCharacters(in: .whitespaces).isEmpty)
        #expect(summary.items[1].message.contains("isn't a PDF"))
        #expect(Self.exists(outFile("good.pdf")))
        #expect(!Self.exists(outFile("broken.pdf"))) // nothing half-written
        #expect(summary.text == "1 done, 2 failed.")
    }

    @Test func imagesBecomePdfsFirst() async throws {
        let png = try put("in/photo.png", TestImages.png(40, 20) { _, _ in (0, 0, 255, 255) })
        var plan = plan(.export(.text, dpi: 150))
        plan.imagePageSize = .a4
        let summary = try await Self.run([png], plan)
        #expect(summary.done == 1)
        let pdf = try Self.read(outFile("photo.pdf")) // made even with only an export chosen
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        #expect(abs(engine.page(0).width - 842) < 1) // A4, turned for a wide picture
        // A picture has no text: no text file, and the result says why.
        #expect(!Self.exists(outFile("photo.txt")))
        #expect(summary.items[0].notes.contains { $0.lowercased().contains("no text") })
    }

    @Test func onlyExportsWriteNoPdf() async throws {
        let a = try put("in/a.pdf", TestPdf.make(2))
        let summary = try await Self.run([a], plan(.export(.word, dpi: 150), .export(.png, dpi: 72)))
        #expect(summary.done == 1)
        #expect(!Self.exists(outFile("a.pdf")))
        let docx = try Self.read(outFile("a.docx"))
        #expect(docx.count > 1000)
        #expect(Self.exists(outFile("a - page 1.png")))
        #expect(Self.exists(outFile("a - page 2.png")))
        let word = try WordDoc(docx)
        #expect(word.bodyParagraphs.contains { OpenXmlPackage.text($0).contains("Page 2 alpha") })
    }

    @Test func exportsCommentsFormDataAndSummaries() async throws {
        let form = try put("in/form.pdf", Core1TestPdf.navigation())
        let plain = try put("in/plain.pdf", TestPdf.make(1))
        let plan = plan(.export(.formDataXfdf, dpi: 150), .export(.formDataFdf, dpi: 150))
        #expect(plan.validate(ocrAvailable: true) == nil)
        let summary = try await Self.run([form, plain], plan)
        #expect(summary.done == 2)
        #expect(try Self.readText(outFile("form.xfdf")).contains("Alice"))
        #expect(latin1(try Self.read(outFile("form.fdf"))).contains("Alice"))
        #expect(!Self.exists(outFile("plain.xfdf")))
        #expect(summary.items.first { $0.file.path == plain }?.notes.contains { $0.hasPrefix("Form data: no form fields") } == true)

        // The exports go into presets and come back.
        #expect(try BatchPresets.read(BatchPresets.write(BatchPreset.from("Review", plan, keepFolder: false))).steps == plan.steps)
    }

    /// Answers password prompts from a list, in order, and keeps what was asked.
    private final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var answers: [String?]
        private(set) var asked: [BatchPasswordRequest] = []
        init(_ answers: [String?]) { self.answers = answers }
        func answer(_ r: BatchPasswordRequest) -> String? {
            lock.lock()
            defer { lock.unlock() }
            asked.append(r)
            return answers.isEmpty ? nil : answers.removeFirst()
        }
        func clear() {
            lock.lock()
            asked = []
            lock.unlock()
        }
    }

    @Test func passwordsAreAskedPerFileOrSkipped() async throws {
        let locked = try put("in/locked.pdf", TestPdf.encrypted(1, "secret"))
        let open = try put("in/open.pdf", TestPdf.make(1))
        let answers = Answers(["wrong", "secret", "secret-owner"])
        let host = BatchHost(askPassword: { r, _ in answers.answer(r) })
        let summary = try await Self.run([locked, open], plan(.watermark(WatermarkOptions(text: "COPY"))), host: host)
        #expect(summary.done == 2)
        // Opened with its open password, which doesn't allow changes: its permissions password is asked for next.
        #expect(answers.asked.map(\.kind) == [.open, .open, .permissions])
        #expect(!answers.asked[0].wrong)
        #expect(answers.asked[1].wrong)
        #expect(!answers.asked[2].wrong)
        #expect(answers.asked[0].file.path == locked)
        // The result keeps its protection: it opens with the same password only.
        let result = try Self.read(outFile("locked.pdf"))
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(result).close() }
        #expect(try Self.text(result, password: "secret").contains("COPY"))

        // Skip: a file that needs a password is listed as skipped, without asking.
        answers.clear()
        var skip = plan(.rotate(90))
        skip.passwords = .skip
        let skipped = try await Self.run([locked, open], skip, host: host)
        #expect(answers.asked.isEmpty)
        #expect(skipped.skipped == 1)
        #expect(skipped.items[0].state == .skipped)
        #expect(skipped.items[0].message.contains("password"))

        // No answer (Cancel in the prompt) skips that file only.
        let declined = try await Self.run([locked, open], plan(.rotate(90)), host: BatchHost(askPassword: { _, _ in nil }))
        #expect(declined.skipped == 1 && declined.done == 1)
    }

    @Test func aRestrictedFileAsksForItsPermissionsPassword() async throws {
        let restricted = try put("in/r.pdf", try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: nil, ownerPassword: "boss", permissions: PdfPermissions(modify: false)))
        let answers = Answers(["boss", "boss", "boss"])
        let summary = try await Self.run([restricted], plan(.rotate(90)), host: BatchHost(askPassword: { r, _ in answers.answer(r) }))
        #expect(summary.done == 1)
        #expect(answers.asked.map(\.kind) == [.permissions])
        let info = try PdfSecurity.readSecurity(try Self.read(outFile("r.pdf")), nil)
        #expect(!info.permissions.modify) // still restricted
    }

    @Test func protectAndUnprotect() async throws {
        let a = try put("in/a.pdf", TestPdf.make(1))
        let summary = try await Self.run([a], plan(.rotate(90), .protect(ProtectStep("open", "owner", .all)), .export(.text, dpi: 150)))
        #expect(summary.done == 1)
        let protectedPdf = try Self.read(outFile("a.pdf"))
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(protectedPdf).close() }
        #expect(try Self.text(protectedPdf, password: "open").contains("Page 1"))
        #expect(try Self.readText(outFile("a.txt")).contains("Page 1"))

        let locked = try put("in/locked.pdf", TestPdf.encrypted(1, "pw"))
        let host = BatchHost(askPassword: { r, _ in r.kind == .open ? "pw" : "pw-owner" })
        let unprotected = try await Self.run([locked], plan(.unprotect), host: host)
        #expect(unprotected.done == 1)
        #expect(try Self.text(try Self.read(outFile("locked.pdf"))).contains("Page 1"))
    }

    @Test func signedFilesAreSkippedUnlessChosen() async throws {
        let signed = try put("in/signed.pdf", SignedEditTests.signed())
        let summary = try await Self.run([signed], plan(.rotate(90)))
        #expect(summary.skipped == 1)
        #expect(summary.items[0].message.lowercased().contains("signed"))

        // Exports only read the file: signed files are exported.
        #expect(try await Self.run([signed], plan(.export(.text, dpi: 150))).done == 1)

        var edit = plan(.flatten(FlattenOptions()))
        edit.signedFiles = .edit
        let edited = try await Self.run([signed], edit)
        #expect(edited.done == 1)

        // Changes and exports together: the changes are skipped, the exports still made, no changed copy written.
        try FileManager.default.removeItem(atPath: out)
        let mixed = try await Self.run([signed], plan(.rotate(90), .export(.text, dpi: 150)))
        #expect(mixed.done == 1)
        #expect(try Self.readText(outFile("signed.txt")).contains("Hello contract"))
        #expect(!Self.exists(outFile("signed.pdf")))
        #expect(mixed.items[0].notes.contains { $0.contains("Signed") })
    }

    @Test func renderingActionsWeighTheirPages() {
        let plain = plan(.rotate(90))
        #expect(BatchRunner.weight(1000, (612, 792), plain) == 32 << 20) // small file, no rendering: the minimum
        // A small vector PDF exported at 600 dpi: a Letter page is 5100 x 6600 pixels, 4 bytes each.
        let images = plan(.export(.png, dpi: 600))
        #expect(BatchRunner.weight(1000, (612, 792), images) == (32 << 20) + 4 * 5100 * 6600)
        // Four of them don't fit a 256 MB budget together.
        #expect(4 * BatchRunner.weight(1000, (612, 792), images) > 256 << 20)
        // OCR renders at 300 dpi; a huge page is capped as the renderers cap it.
        #expect(BatchRunner.weight(1000, nil, plan(.ocr)) == (32 << 20) + 4 * 2550 * 3300)
        #expect(BatchRunner.weight(1000, (14400, 14400), images) == (32 << 20) + 4 * 64_000_000)
    }

    @Test func aFileThatAppearsMeanwhileIsNeverOverwritten() throws {
        let names = OutputNames(overwrite: false, inputs: [])
        let path = try names.place(out, "a.pdf") { temp in
            try Data([1]).write(to: URL(fileURLWithPath: temp))
            try Data([9]).write(to: URL(fileURLWithPath: self.outFile("a.pdf"))) // another program, between picking the name and the move
        }
        #expect(path == outFile("a (2).pdf"))
        #expect(try Self.read(outFile("a.pdf")) == [9])
        #expect(try Self.read(path) == [1])
        #expect(!Self.files(out).contains { $0.hasSuffix(".tmp") })
        // A failed write leaves nothing behind.
        #expect(throws: PdfEditError.self) { try names.place(out, "b.pdf") { _ in throw PdfEditError("no") } }
        #expect(Self.files(out).count == 2)
    }

    @Test func batesNumbersCanContinueFromFileToFile() async throws {
        let files = [try put("in/1.pdf", TestPdf.make(2)), try put("in/2.pdf", TestPdf.make(3)), try put("in/3.pdf", TestPdf.make(1))]
        var options = HeaderFooterOptions()
        options.footerRight = "<<bates>>"
        options.headerLeft = "<<file>>"
        options.bates = BatesFormat("CASE-", 1, 4)
        var plan = plan(.headerFooter(options, continueBates: true))
        plan.maxParallel = 3
        let summary = try await Self.run(files, plan)
        #expect(summary.done == 3)
        #expect(try Self.text(try Self.read(outFile("1.pdf"))).contains("CASE-0001"))
        #expect(try Self.text(try Self.read(outFile("1.pdf"))).contains("1.pdf"))
        #expect(try Self.text(try Self.read(outFile("2.pdf"))).contains("CASE-0003"))
        #expect(try Self.text(try Self.read(outFile("2.pdf")), page: 2).contains("CASE-0005"))
        #expect(try Self.text(try Self.read(outFile("3.pdf"))).contains("CASE-0006"))

        // Without it, each file starts again.
        try FileManager.default.removeItem(atPath: out)
        _ = try await Self.run(files, self.plan(.headerFooter(options, continueBates: false)))
        #expect(try Self.text(try Self.read(outFile("3.pdf"))).contains("CASE-0001"))
    }

    /// A thread-safe counter for the recognizer fakes.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var value = 0
        private(set) var most = 0
        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            most = max(most, value)
            return value
        }
        func decrement() {
            lock.lock()
            value -= 1
            lock.unlock()
        }
    }

    @Test func ocrUsesTheHostsRecognizerOnPagesWithoutText() async throws {
        let scan = try put("in/scan.png", Self.white(200, 100))
        let calls = Counter()
        let host = BatchHost(recognize: { _, _, _ in
            _ = calls.increment()
            return [OcrWord("Recognized", RectD(10, 10, 80, 12))]
        })
        let summary = try await Self.run([scan, try put("in/text.pdf", TestPdf.make(1))], plan(.ocr, .export(.text, dpi: 150)), host: host)
        #expect(summary.done == 2)
        #expect(calls.value == 1) // the PDF with text isn't recognized
        #expect(try Self.readText(outFile("scan.txt")).contains("Recognized"))
    }

    @Test func parallelismIsBounded() async throws {
        let running = Counter()
        let host = BatchHost(recognize: { _, _, _ in
            _ = running.increment()
            Thread.sleep(forTimeInterval: 0.06)
            running.decrement()
            return []
        })
        // Pages with text aren't recognized, so give them blank pages to recognize.
        let blank = try (0..<8).map { try put("in/b\($0).png", Self.white(10, 10)) }
        var plan = plan(.ocr)
        plan.maxParallel = 2
        let summary = try await Self.run(blank, plan, host: host)
        #expect(summary.done == 8)
        #expect(running.most >= 1 && running.most <= 2)
    }

    @Test func cancelStopsTheRest() async throws {
        let files = try (0..<6).map { try put("in/c\($0).png", Self.white(10, 10)) }
        let token = CancelToken()
        let host = BatchHost(recognize: { _, _, cancel in
            token.cancel()
            try cancel.check()
            return []
        })
        var plan = plan(.ocr)
        plan.maxParallel = 1
        let summary = try await Self.run(files, plan, host: host, cancel: token)
        #expect(summary.cancelled == 6)
        #expect(summary.done == 0)
        #expect(Self.files(out).isEmpty) // nothing written for cancelled files
        #expect(summary.text == "6 cancelled.")
    }
}
