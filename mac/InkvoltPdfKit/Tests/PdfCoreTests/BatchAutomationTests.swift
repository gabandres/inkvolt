import Foundation
import Testing
@testable import PdfCore

/// Ported from BatchAutomationTests.cs (same names): batch presets (JSON in and out), the watched folder and the command
/// line (roadmap 1.2). Adapted: the Everything preset leaves out the action the Mac doesn't have (Check accessibility; a
/// preset naming it is refused saying so);
/// the JSON refusals are the Mac's words for the same mistakes; ALockedFileWaitsUntilItIsLetGo holds an flock on the
/// file (what "held open" means on a Mac); the command line's `/?` isn't a Mac spelling. Serialized with ProTests
/// (`ProGated`): the command line asks the Pro check that those tests flip.
extension ProGated {
@Suite final class BatchAutomationTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-auto-\(NewIds.hex().prefix(8))")
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

    private func p(_ parts: String...) -> String { parts.reduce(root) { ($0 as NSString).appendingPathComponent($1) } }

    private static func text(_ pdf: [UInt8], page: Int = 0) throws -> String {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.text(page).text
    }

    private static func pages(_ path: String) throws -> Int {
        let engine = try PdfEngine.open(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        defer { engine.close() }
        return engine.pageCount
    }

    private static func read(_ path: String) throws -> [UInt8] { Array(try Data(contentsOf: URL(fileURLWithPath: path))) }
    private static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    /// Every action with settings off their defaults.
    private static func everything() -> BatchPreset {
        var header = HeaderFooterOptions()
        header.headerLeft = "<<file>>"
        header.footerCenter = "Page <<page>> of <<pages>>"
        header.footerRight = "<<bates>>"
        header.fontSize = 9
        header.marginBottom = 20
        header.bates = BatesFormat("CASE-", 100, 7, "-X")
        var preset = BatchPreset(name: "Everything «über»", steps: [
            .ocr,
            .optimize(OptimizeOptions(compressStreams: false, removeMetadata: true, maxImageDpi: nil, jpegQuality: 60)),
            .sanitize([.signatures, .metadata, .activeContent]),
            .redactPatterns(RedactionPatternOptions(patterns: [.zipCode, .email], phrases: ["Acme Corp", "Jane \"JD\" Doe"], wholeWord: false, matchCase: true,
                                                    expression: #"CASE-\d{4}"#, pages: [0, 2])),
            .checkRedaction,
            .reportContents,
            .watermark(WatermarkOptions(text: "DRAFT", fontSize: 60, color: AnnotColor(1, 0, 0), opacity: 0.25, rotation: -30, layout: .tiled, behind: true)),
            .watermark(WatermarkOptions(image: StampImage(2, 1, [255, 0, 0, 0, 0, 255], [255, 128]), color: AnnotColor(0, 0, 1), imageScale: 0.2)), // colors keep 8 bits a channel
            .headerFooter(header, continueBates: true),
            .rotate(-90),
            .flatten(FlattenOptions(links: true, printableOnly: true)),
            .unprotect,
            .export(.jpeg, dpi: 300),
            .export(.word, dpi: 150),
            .makeAccessible(language: "es-PR"),
            .saveAsPdfA,
            .protect(ProtectStep("open-secret", "owner-secret", PdfPermissions(print: .lowResolution, copy: false), .aes128)),
        ], outputFolder: "/Users/me/Results/Scans")
        preset.nameTemplate = "<<name>> <<n:3>> <<date:yyyy-MM>>"
        preset.neverOverwrite = false
        preset.keepSubfolders = false
        preset.signedFiles = .edit
        preset.passwords = .skip
        preset.imagePageSize = .a4
        return preset
    }

    // ───────────── presets ─────────────

    @Test func aPresetRoundTripsThroughExportAndImportUnchanged() throws {
        let json = BatchPresets.write(Self.everything())
        let path = p("presets", BatchPresets.fileName("Everything «über»"))
        try BatchPresets.save(try BatchPresets.read(json), path)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == json) // export → import → export: the same text
        let again = try BatchPresets.load(path)
        #expect(BatchPresets.write(again) == json)

        // The same settings come back (passwords aside, and the picture as pixels).
        let original = Self.everything()
        func output(_ p: BatchPreset) -> String { "\(p.name)|\(p.outputFolder ?? "")|\(p.nameTemplate)|\(p.neverOverwrite)|\(p.keepSubfolders)|\(p.signedFiles)|\(p.passwords)|\(p.imagePageSize)" }
        #expect(output(original) == output(again))
        #expect(original.steps.count == again.steps.count)
        for (a, b) in zip(original.steps, again.steps) {
            switch (a, b) {
            case (.watermark(let w1), .watermark(let w2)) where w1.image != nil:
                #expect(w1.image?.width == w2.image?.width && w1.image?.height == w2.image?.height)
                #expect(w1.image?.rgb == w2.image?.rgb)
                #expect(w1.image?.alpha == w2.image?.alpha)
                var x = w1, y = w2
                x.image = nil
                y.image = nil
                #expect(x == y)
            case (.protect(let p1), .protect(let p2)):
                #expect(p2.userPassword == "" && p2.ownerPassword == "") // wanted, not kept
                #expect(p2.needsPasswords)
                #expect(p1.permissions == p2.permissions && p1.method == p2.method)
            case (.headerFooter(let h1, let c1), .headerFooter(let h2, let c2)):
                var x = h1, y = h2
                x.date = Date(timeIntervalSince1970: 0)
                y.date = x.date
                #expect(x == y)
                #expect(c1 == c2)
            default:
                #expect(a == b)
            }
        }
    }

    @Test func aPresetIsPlainReadableJsonWithoutPasswords() {
        let json = BatchPresets.write(Self.everything())
        #expect(!json.contains("open-secret"))
        #expect(!json.contains("owner-secret"))
        #expect(json.hasPrefix("{\n  \"format\": \"Inkvolt PDF batch preset\",\n  \"version\": 1,\n  \"name\": \"Everything «über»\","))
        #expect(json.contains("\"names\": \"<<name>> <<n:3>> <<date:yyyy-MM>>\"")) // not < escapes
        #expect(json.contains("\"action\": \"redactPatterns\""))
        #expect(json.contains("\"patterns\": [\n        \"email\",\n        \"zipCode\"\n      ]")) // the offered order, one per line
        #expect(json.contains("\"openPassword\": true,\n      \"permissionsPassword\": true"))
        #expect(json.contains("\"color\": \"#FF0000\""))
        #expect(json.contains("\"pages\": [\n        1,\n        3\n      ]")) // page numbers from 1
        #expect(json.contains("\"phrases\": [\n        \"Acme Corp\",\n        \"Jane \\\"JD\\\" Doe\"\n      ]"))
        #expect(json.hasSuffix("}\n"))
        #expect(!json.contains("\r"))
    }

    @Test func aHandWrittenPresetTakesDefaultsForWhatItLeavesOut() throws {
        let preset = try BatchPresets.read("""
            // comments and trailing commas are fine
            { "version": 1, "actions": [ { "action": "watermark", "text": "COPY" }, { "action": "saveAsPdfA" }, ], }
            """, fallbackName: "From file")
        #expect(preset.name == "From file")
        #expect(preset.outputFolder == nil)
        #expect(preset.nameTemplate == BatchNames.defaultTemplate)
        #expect(preset.steps[0] == .watermark(WatermarkOptions(text: "COPY")))
        #expect(preset.steps[1] == .saveAsPdfA)
    }

    static let malformed: [(json: String, expected: String)] = [
        ("{ \"version\": 1, ", "isn't valid JSON"),
        ("[1, 2]", "should be a JSON object"),
        ("{ \"actions\": [] }", "has no \"version\""),
        ("{ \"format\": \"something else\", \"version\": 1 }", "isn't an Inkvolt PDF batch preset"),
        ("{ \"version\": \"one\" }", "isn't one Inkvolt PDF knows"),
        ("{ \"version\": 2, \"actions\": [ { \"action\": \"teleport\" } ] }", "saved by a newer Inkvolt PDF (preset version 2"),
        ("{ \"version\": 1 }", "has no \"actions\""),
        ("{ \"version\": 1, \"actions\": [] }", "list is empty"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"stamp\" } ] }", "Action 1: \"stamp\" isn't an action"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"checkAccessibility\" } ] }", "Inkvolt PDF for Windows"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"ocr\" }, { \"action\": \"rotate\", \"degres\": 90 } ] }", "Action 2 (rotate): \"degres\" isn't a setting"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"rotate\", \"degrees\": 45 } ] }", "should be 90, -90 or 180"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"watermark\", \"text\": \"X\", \"opacity\": \"half\" } ] }", "\"opacity\" should be a number"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"watermark\", \"text\": \"X\", \"opacity\": 3 } ] }", "\"opacity\" should be between 0 and 1"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"export\", \"format\": \"pptx\" } ] }", "\"format\" should be one of \"word\", \"excel\""),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\", \"openPassword\": \"hunter2\" } ] }", "passwords aren't kept in presets"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\", \"openPassword\": true, \"password\": \"x\" } ] }", "passwords are never kept in presets"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\" } ] }", "set \"openPassword\", \"permissionsPassword\" or both"),
        ("{ \"version\": 1, \"output\": { \"folder\": \"results\" }, \"actions\": [ { \"action\": \"ocr\" } ] }", "should be a full path"),
        ("{ \"version\": 1, \"actions\": [ { \"action\": \"redactPatterns\", \"patterns\": [\"ssn\"] } ] }", "(\"ssn\" isn't one)"),
    ]

    @Test(arguments: malformed)
    func aMalformedOrNewerPresetIsRefusedSayingWhy(_ case_: (json: String, expected: String)) {
        var message = "(accepted)"
        do {
            _ = try BatchPresets.read(case_.json)
        } catch let e as BatchPresetError {
            message = e.message
        } catch {
            message = "\(error)"
        }
        #expect(message.contains(case_.expected), "\(message)")
    }

    @Test func loadingAMissingOrDamagedFileSaysWhichFile() throws {
        func refusal(_ path: String) -> String {
            do {
                _ = try BatchPresets.load(path)
                return "(accepted)"
            } catch let e as BatchPresetError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        #expect(refusal(p("none.json")).contains("no preset file"))
        let damaged = try put("damaged.json", [0xFF, 0xFE, 0x00])
        #expect(refusal(damaged).contains("isn't valid JSON"))
    }

    @Test func protectPasswordsAreGivenWhenItRuns() throws {
        let steps = try BatchPresets.read("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\", \"openPassword\": true } ] }").steps
        var plan = BatchPlan(steps: steps, outputFolder: root)
        #expect(plan.validate(ocrAvailable: true)?.contains("needs its passwords") == true)
        let given = BatchPresets.withPasswords(steps, open: "s3cret", permissions: "ignored: not wanted")
        #expect(given[0] == .protect(ProtectStep("s3cret", nil, .all)))
        plan.steps = given
        #expect(plan.validate(ocrAvailable: true) == nil)
        #expect(given[0].title == "Protect with a password") // never the password
    }

    // ───────────── Save as PDF/A in a batch ─────────────

    @Test func saveAsPdfAIsABatchAction() async throws {
        let a = try put("in/a.pdf", TestPdf.make(2, marker: "archive"))
        var plan = BatchPlan(steps: [.rotate(90), .saveAsPdfA], outputFolder: p("out"))
        let summary = try await BatchRunner.run([BatchFile(a)], plan, BatchHost())
        #expect(summary.items.count == 1)
        let item = summary.items[0]
        #expect(item.state == .done, "\(item.message)")
        let result = try Self.read(try #require(item.outputs.first))
        #expect(PdfA.validate(result) == [])
        #expect(try Self.text(result).contains("archive"))
        #expect(item.notes.contains { $0.hasPrefix("PDF/A-2b") })

        plan.steps = [.saveAsPdfA, .protect(ProtectStep("a", nil, .all))]
        #expect(plan.validate(ocrAvailable: true)?.contains("can't be password protected") == true)
        plan.steps = [.saveAsPdfA, .rotate(90)]
        #expect(plan.validate(ocrAvailable: true)?.contains("after the other changes") == true)
        plan.steps = [.saveAsPdfA, .export(.text, dpi: 150)]
        #expect(plan.validate(ocrAvailable: true) == nil) // exports may follow
    }

    // ───────────── watched folder ─────────────

    private static let quick = WatchOptions(pollInterval: 0.05, quietPeriod: 0.8)

    private var inbox: String { p("inbox") }
    private var results: String { p("results") }

    private var rotatePlan: BatchPlan { BatchPlan(steps: [.rotate(90)], outputFolder: results) }

    private static func names(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted { $0.lowercased() < $1.lowercased() }
    }

    private func logLines() -> [String] {
        let path = (inbox as NSString).appendingPathComponent(WatchedFolder.logName)
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    private static func until(_ condition: @escaping () -> Bool, seconds: Double = 90) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { throw PdfEditError("the watched folder didn't get there in time") }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// A copy that keeps the file open and locked and adds a chunk at a time (as a copy over a slow network does).
    private static func copySlowlyHeld(_ bytes: [UInt8], _ path: String, _ chunks: Int) async throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_EXLOCK, 0o644)
        guard fd >= 0 else { throw PdfEditError("couldn't create \(path)") }
        defer { close(fd) }
        ftruncate(fd, off_t(bytes.count)) // network copies set the full size first
        let size = (bytes.count + chunks - 1) / chunks
        var at = 0
        while at < bytes.count {
            let chunk = Array(bytes[at..<min(at + size, bytes.count)])
            _ = chunk.withUnsafeBufferPointer { pwrite(fd, $0.baseAddress, $0.count, off_t(at)) }
            at += size
            try await Task.sleep(nanoseconds: 120_000_000)
        }
    }

    /// A copy that closes the file between chunks (a tool appending to it): it keeps growing, with pauses well inside the
    /// quiet period.
    private static func copySlowlyInBursts(_ bytes: [UInt8], _ path: String, _ chunks: Int) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                let size = (bytes.count + chunks - 1) / chunks
                var at = 0
                while at < bytes.count {
                    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                    let chunk = Array(bytes[at..<min(at + size, bytes.count)])
                    _ = chunk.withUnsafeBufferPointer { Foundation.write(fd, $0.baseAddress, $0.count) }
                    close(fd)
                    at += size
                    Thread.sleep(forTimeInterval: 0.08)
                }
                cont.resume()
            }
        }
    }

    @Test func aWatchedFolderTakesEachFileOnceEvenWhenCopiedSlowly() async throws {
        try FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        let each = 8
        let token = CancelToken()
        let entries = Collected<WatchEntry>()
        let inbox = inbox, results = results, plan = rotatePlan
        // A longer quiet period than the other tests: the bursts' pauses must stay well inside it on a busy Mac.
        var options = Self.quick
        options.quietPeriod = 1.5
        let watch = Task { try await WatchedFolder.run(inbox, plan, BatchHost(), options, progress: { if let e = $0.finished { entries.add(e) } }, cancel: token) }

        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<each {
                group.addTask { try await Self.copySlowlyHeld(TestPdf.make(3, marker: "held\(i)"), (inbox as NSString).appendingPathComponent("held\(i).pdf"), 10) }
                group.addTask { await Self.copySlowlyInBursts(TestPdf.make(3, marker: "burst\(i)"), (inbox as NSString).appendingPathComponent("burst\(i).pdf"), 10) }
                try? Data(TestPdf.make(3, marker: "quick\(i)")).write(to: URL(fileURLWithPath: (inbox as NSString).appendingPathComponent("quick\(i).pdf")))
            }
            try? Data([1, 2, 3]).write(to: URL(fileURLWithPath: (inbox as NSString).appendingPathComponent("notes.txt"))) // not a PDF or an image: left alone
        }
        let doneFolder = (inbox as NSString).appendingPathComponent(WatchedFolder.doneFolder)
        let failedFolder = (inbox as NSString).appendingPathComponent(WatchedFolder.failedFolder)
        try await Self.until { Self.names(doneFolder).count + Self.names(failedFolder).count >= each * 3 }
        try await Task.sleep(nanoseconds: UInt64(Self.quick.quietPeriod * 2 * 1_000_000_000)) // nothing more may come out
        token.cancel()
        let summary = try await watch.value

        #expect(summary == WatchSummary(each * 3, 0))
        #expect(Self.names(failedFolder).isEmpty)
        #expect(Self.names((inbox as NSString).appendingPathComponent(WatchedFolder.workingFolder)).isEmpty)
        let done = Self.names(doneFolder)
        #expect(done.count == each * 3)
        #expect(!done.contains { $0.contains(" (2)") }) // none twice
        let made = Self.names(results)
        #expect(done == made) // one result per file, same names
        for name in made {
            let path = (results as NSString).appendingPathComponent(name)
            #expect(try Self.pages(path) == 3) // whole: taken once the copy was complete
            #expect(try Self.text(try Self.read(path), page: 2).contains((name as NSString).deletingPathExtension))
        }
        let left: [String] = Self.names(inbox).filter { name in
            name != WatchedFolder.logName && !name.hasSuffix("/") && !Self.isFolder((inbox as NSString).appendingPathComponent(name))
        }
        #expect(left == ["notes.txt"])
        let log: [[String]] = logLines().map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        #expect(log.count == each * 3)
        #expect(log.allSatisfy { $0[1] == "done" })
        let logged: [String] = log.map { $0[2] }.sorted { $0.lowercased() < $1.lowercased() }
        #expect(logged == done)
        #expect(entries.all.count == each * 3)
    }

    private static func isFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    @Test func aLockedFileWaitsUntilItIsLetGo() async throws {
        let path = try put("inbox/held.pdf", TestPdf.make(1, marker: "held"))
        let token = CancelToken()
        let inbox = inbox, plan = rotatePlan, quick = Self.quick // a local: Xcode 26's region checker can't follow Self.quick into the task
        let watch = Task { try await WatchedFolder.run(inbox, plan, BatchHost(), quick, cancel: token) }
        let doneFolder = (inbox as NSString).appendingPathComponent(WatchedFolder.doneFolder)
        let fd = open(path, O_RDWR | O_EXLOCK) // another app holds it
        #expect(fd >= 0)
        try await Task.sleep(nanoseconds: UInt64(Self.quick.quietPeriod * 3 * 1_000_000_000))
        #expect(Self.exists(path))
        #expect(Self.names(doneFolder).isEmpty)
        close(fd)
        try await Self.until { Self.names(doneFolder).count == 1 }
        token.cancel()
        #expect(try await watch.value == WatchSummary(1, 0))
        #expect(Self.names(results) == ["held.pdf"])
    }

    @Test func originalsGoToDoneOrFailedWithALogLineEach() async throws {
        try put("inbox/good.pdf", TestPdf.make(1, marker: "good"))
        try put("inbox/bad.pdf", Array("this is not a PDF".utf8))
        try put("inbox/done/good.pdf", [1]) // a name taken already
        try put("inbox/sub/deeper.pdf", TestPdf.make(1)) // subfolders aren't watched
        var once = Self.quick
        once.once = true
        let summary = try await WatchedFolder.run(inbox, rotatePlan, BatchHost(), once)

        #expect(summary == WatchSummary(1, 1))
        #expect(Self.names((inbox as NSString).appendingPathComponent(WatchedFolder.doneFolder)) == ["good (2).pdf", "good.pdf"])
        #expect(Self.names((inbox as NSString).appendingPathComponent(WatchedFolder.failedFolder)) == ["bad.pdf"])
        #expect(Self.names(results) == ["good.pdf"])
        #expect(Self.exists(p("inbox", "sub", "deeper.pdf")))
        let lines: [[String]] = logLines().map { line in line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        let log = lines.sorted { $0[2] < $1[2] }
        #expect(log.count == 2)
        #expect(log[0][1] == "failed" && log[0][2] == "bad.pdf" && log[0][3] == "This file isn't a PDF.")
        #expect(log[1][1] == "done" && log[1][2] == "good.pdf" && log[1][4] == (results as NSString).appendingPathComponent("good.pdf"))
    }

    @Test func aRestartSendsInterruptedFilesToFailedAndOneFolderHasOneWatcher() async throws {
        try put("inbox/working/crashed.pdf", TestPdf.make(1)) // the app closed while working on it
        try put("inbox/new.pdf", TestPdf.make(1))
        let token = CancelToken()
        let inbox = inbox, plan = rotatePlan, quick = Self.quick
        let first = Task { try await WatchedFolder.run(inbox, plan, BatchHost(), quick, cancel: token) }
        let doneFolder = (inbox as NSString).appendingPathComponent(WatchedFolder.doneFolder)
        try await Self.until { Self.names(doneFolder).count == 1 }

        await #expect(throws: FolderWatched.self) { try await WatchedFolder.run(inbox, plan, BatchHost(), Self.quick) }
        token.cancel()
        #expect(try await first.value == WatchSummary(1, 1))
        #expect(Self.names((inbox as NSString).appendingPathComponent(WatchedFolder.failedFolder)) == ["crashed.pdf"]) // never run again
        #expect(Self.names(results) == ["new.pdf"])
        #expect(logLines().contains { $0.contains("crashed.pdf") && $0.contains("Interrupted") })

        // Restarted: nothing is done twice, and the folder can be watched again.
        var once = Self.quick
        once.once = true
        #expect(try await WatchedFolder.run(inbox, plan, BatchHost(), once) == WatchSummary(0, 0))
        #expect(Self.names(results) == ["new.pdf"])
    }

    @Test func theResultsCantGoIntoTheWatchedFolderItself() throws {
        try FileManager.default.createDirectory(atPath: inbox, withIntermediateDirectories: true)
        #expect(WatchedFolder.validate(inbox, inbox + "/")?.contains("can't go into the watched folder") == true)
        #expect(WatchedFolder.validate(inbox, WatchedFolder.defaultOutput(inbox)) == nil)
        #expect(WatchedFolder.validate(p("missing"), results)?.contains("There is no folder") == true)
    }

    // ───────────── command line ─────────────

    private func cli(_ environment: [String: String]?, _ args: String...) async -> (code: Int, output: String, error: String) {
        let output = MemoryLines(), error = MemoryLines()
        let code = await BatchCommandLine.run(args, output: output, error: error, host: BatchHost(), environment: { environment?[$0] })
        return (code, output.text, error.text)
    }

    private func preset(_ json: String) throws -> String { try put("presets/\(NewIds.hex()).json", Array(json.utf8)) }

    @Test func theCommandLineIsParsed() throws {
        #expect(BatchCommandLine.isCommand(["--BATCH", "p.json", "a.pdf"]))
        #expect(BatchCommandLine.isCommand(["-h"]))
        #expect(!BatchCommandLine.isCommand(["/docs/--batch.pdf"]))
        #expect(!BatchCommandLine.isCommand([]))
        #expect(try BatchCommandLine.parse(["-h"]) == CommandLineRequest(.help))
        let batch = try BatchCommandLine.parse(["--batch", "p.json", "a.pdf", "--out", "/out", "folder", "--recursive", "--quiet"])
        #expect(batch.kind == .batch && batch.preset == "p.json" && batch.output == "/out" && batch.recursive && batch.quiet)
        #expect(batch.inputs == ["a.pdf", "folder"])
        let watch = try BatchCommandLine.parse(["--watch", "/in", "--preset", "p.json", "--once"])
        #expect(watch.kind == .watch && watch.preset == "p.json" && watch.folder == "/in" && watch.once && watch.output == nil)

        func refusal(_ args: [String]) -> String {
            do {
                _ = try BatchCommandLine.parse(args)
                return "(accepted)"
            } catch let e as CommandLineError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        #expect(refusal(["--batch", "p.json"]).contains("needs the files or folders"))
        #expect(refusal(["--batch", "p.json", "a.pdf", "--out"]).contains("--out needs a value"))
        #expect(refusal(["--batch", "p.json", "a.pdf", "--fast"]).contains("\"--fast\" isn't an option"))
        #expect(refusal(["--watch", "/in"]).contains("needs a preset"))
        #expect(refusal(["--watch", "a", "b", "--preset", "p"]).contains("one folder"))
        #expect(refusal(["--batch", "p", "a", "--once"]).contains("goes with --watch"))
    }

    @Test func helpAndWrongCommandLinesGiveTheirExitCodes() async throws {
        let help = await cli(nil, "--help")
        #expect(help.code == BatchCommandLine.done)
        #expect(help.output.contains("inkvoltpdf --batch <preset.json>"))
        #expect(help.output.contains("Exit codes"))

        let wrong = await cli(nil, "--batch")
        #expect(wrong.code == BatchCommandLine.wrong)
        #expect(wrong.error.contains("--help"))

        let missing = await cli(nil, "--batch", p("none.json"), root, "--out", results)
        #expect(missing.code == BatchCommandLine.wrong && missing.error.contains("no preset file"))

        let future = await cli(nil, "--batch", try preset("{ \"version\": 9, \"actions\": [] }"), root, "--out", results)
        #expect(future.code == BatchCommandLine.wrong && future.error.contains("newer Inkvolt PDF"))

        let noOut = await cli(nil, "--batch", try preset("{ \"version\": 1, \"actions\": [ { \"action\": \"rotate\" } ] }"), root)
        #expect(noOut.code == BatchCommandLine.wrong && noOut.error.contains("--out <folder>"))

        let noFiles = await cli(nil, "--batch", try preset("{ \"version\": 1, \"actions\": [ { \"action\": \"rotate\" } ] }"), p("nothing-here.pdf"), "--out", results)
        #expect(noFiles.code == BatchCommandLine.wrong && noFiles.error.contains("There is no file or folder"))
        #expect(!Self.exists(results)) // nothing done
    }

    @Test func theBatchCommandRunsAPresetAndFailsOnAnyFailure() async throws {
        try put("in/a.pdf", TestPdf.make(1, marker: "first"))
        try put("in/b.pdf", TestPdf.make(1, marker: "second"))
        let preset = try preset(BatchPresets.write(BatchPreset(name: "Turn", steps: [.rotate(90)], outputFolder: results)))

        let ok = await cli(nil, "--batch", preset, p("in"))
        #expect(ok.code == BatchCommandLine.done)
        #expect(Self.names(results) == ["a.pdf", "b.pdf"])
        #expect(ok.output.contains("[2/2] done"))
        #expect(ok.output.contains("2 done."))
        #expect(ok.error == "")

        try put("in/c.pdf", Array("not a pdf".utf8))
        let other = p("other")
        let failing = await cli(nil, "--batch", preset, p("in"), "--out", other, "--quiet")
        #expect(failing.code == BatchCommandLine.someFailed)
        #expect(Self.names(other) == ["a.pdf", "b.pdf"]) // --out wins over the preset's folder
        #expect(failing.error.contains("failed   c.pdf: This file isn't a PDF."))
        #expect(!failing.output.contains("done ")) // --quiet: only failures and the summary
        #expect(failing.output.contains("2 done, 1 failed."))
    }

    @Test func theBatchCommandTakesProtectPasswordsFromTheEnvironment() async throws {
        try put("in/a.pdf", TestPdf.make(1))
        let archive = try preset("{ \"version\": 1, \"output\": { \"folder\": null }, \"actions\": [ { \"action\": \"saveAsPdfA\" }, { \"action\": \"export\", \"format\": \"text\" } ] }")
        let archived = await cli(nil, "--batch", archive, p("in", "a.pdf"), "--out", results)
        #expect(archived.code == BatchCommandLine.done)
        #expect(PdfA.validate(try Self.read((results as NSString).appendingPathComponent("a.pdf"))) == [])
        #expect(Self.exists((results as NSString).appendingPathComponent("a.txt")))

        let protect = try preset("{ \"version\": 1, \"actions\": [ { \"action\": \"protect\", \"openPassword\": true } ] }")
        let without = await cli(nil, "--batch", protect, p("in"), "--out", p("locked"))
        #expect(without.code == BatchCommandLine.wrong)
        #expect(without.error.contains(BatchCommandLine.openPasswordVariable))

        let with = await cli([BatchCommandLine.openPasswordVariable: "s3cret"], "--batch", protect, p("in"), "--out", p("locked"))
        #expect(with.code == BatchCommandLine.done)
        let locked = try Self.read(p("locked", "a.pdf"))
        #expect(PdfSecurity.needsOpenPassword(locked))
        #expect(!(with.output + with.error).contains("s3cret"))
    }

    @Test func theWatchCommandHandlesTheFolderOnce() async throws {
        try put("inbox/a.pdf", TestPdf.make(1))
        try put("inbox/b.pdf", Array("broken".utf8))
        let preset = try preset("{ \"version\": 1, \"actions\": [ { \"action\": \"rotate\", \"degrees\": 180 } ] }")
        let run = await cli(nil, "--watch", inbox, "--preset", preset, "--once")
        #expect(run.code == BatchCommandLine.someFailed)
        #expect(Self.names(WatchedFolder.defaultOutput(inbox)) == ["a.pdf"]) // the preset has no folder: <folder>/results
        #expect(run.output.contains("a.pdf"))
        #expect(run.error.contains("b.pdf"))
        #expect(run.output.contains("1 file done, 1 failed."))

        let itself = await cli(nil, "--watch", inbox, "--preset", preset, "--out", inbox, "--once")
        #expect(itself.code == BatchCommandLine.wrong)
    }

    // ───────────── the Pro gate (ProTests' The_command_line_without_a_licence…) ─────────────

    @Test func The_command_line_without_a_licence_says_so_and_exits_2_only_when_enforced() async {
        Pro.store = MemoryProStore()
        Pro.enforced = true
        var run = await cli(nil, "--batch", "none.json", "a.pdf")
        #expect(run.code == BatchCommandLine.wrong)
        #expect(run.error.contains("part of Inkvolt Pro"))
        #expect(run.error.contains(Pro.buyUrl))

        Pro.enforced = false
        run = await cli(nil, "--batch", "none.json", "a.pdf")
        #expect(run.code == BatchCommandLine.wrong) // the preset is missing, not the licence
        #expect(!run.error.contains("Inkvolt Pro"))
    }
}
}
