import Foundation
import Testing
@testable import PdfCore

/// A made-up Word, Excel or PowerPoint: the script runner faked, doing what the test says with the script's arguments
/// (the copy, the PDF to save, the copy's name, the seconds, whether the app was running). Its probe ("is the app
/// running?") answers `wasRunning`; its clean-up script is recorded. No test runs Microsoft Office (it isn't on the Mac
/// or in CI; PLAN.md's E12 lists what only a person with Microsoft 365 can check). `OsascriptRunner` itself is run with
/// scripts that drive no app.
private final class FakeRunner: OfficeScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let act: @Sendable ([String]) -> ScriptRun
    private let wasRunning: Bool
    private let app: OfficeApp
    /// The conversion scripts run (not the probe or the clean-up).
    private(set) var calls: [(script: String, arguments: [String], timeout: TimeInterval)] = []
    private(set) var cleanups: [(arguments: [String], timeout: TimeInterval)] = []
    private(set) var probes = 0
    private(set) var stagedBytes: [Data] = []
    /// Whether the staged copy was still there when each clean-up ran.
    private(set) var copyThereAtCleanup: [Bool] = []
    private(set) var threadNames: [String] = []
    private var running = 0
    private(set) var mostAtOnce = 0
    private var lastStaged = ""

    init(app: OfficeApp = .word, wasRunning: Bool = false, _ act: @escaping @Sendable ([String]) -> ScriptRun) {
        self.app = app
        self.wasRunning = wasRunning
        self.act = act
    }

    func run(_ script: String, arguments: [String], timeout: TimeInterval, cancel: CancelToken, appName: String) throws -> ScriptRun {
        lock.withLock {
            running += 1
            mostAtOnce = max(mostAtOnce, running)
            threadNames.append(Thread.current.name ?? "")
        }
        defer { lock.withLock { running -= 1 } }
        if script == MicrosoftOfficeScripts.probe(app) {
            lock.withLock { probes += 1 }
            return ScriptRun(.exited(0), output: wasRunning ? "true\n" : "false\n")
        }
        if script == MicrosoftOfficeScripts.cleanup(app) {
            lock.withLock {
                cleanups.append((arguments, timeout))
                copyThereAtCleanup.append(FileManager.default.fileExists(atPath: lastStaged))
            }
            Thread.sleep(forTimeInterval: 0.05)
            return ScriptRun(.exited(0), output: "ok")
        }
        lock.withLock {
            calls.append((script, arguments, timeout))
            if let first = arguments.first, let data = FileManager.default.contents(atPath: first) { stagedBytes.append(data) }
            lastStaged = arguments.first ?? ""
        }
        return act(arguments)
    }

    /// Saves a PDF where the script was told to.
    static let savesPdf: @Sendable ([String]) -> ScriptRun = { arguments in
        try? Data("%PDF-1.7\n%made by a made-up Word\n".utf8).write(to: URL(fileURLWithPath: arguments[1]))
        return ScriptRun(.exited(0), output: "ok")
    }

    static func fails(_ line: String) -> @Sendable ([String]) -> ScriptRun {
        { _ in ScriptRun(.exited(1), errors: "/tmp/inkvolt-office-x/convert.applescript: execution error: \(line)\n") }
    }
}

/// A home with Office's group container (or without), a document, and the converter pointed at both.
private final class FakeHome {
    let root: URL, group: URL, staging: URL, document: URL
    let original = Data("PK\u{3}\u{4}quarterly figures".utf8)

    init(groupExists: Bool = true, documentName: String = "Quarterly: report.docx") throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-test-\(UUID().uuidString)", isDirectory: true)
        staging = MicrosoftOfficeConverter.stagingRoot(home: root.path)
        group = staging.deletingLastPathComponent()
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        if groupExists { try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true) }
        document = docs.appendingPathComponent(documentName)
        try original.write(to: document)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    func converter(_ runner: FakeRunner, _ app: OfficeApp = .word) -> MicrosoftOfficeConverter {
        MicrosoftOfficeConverter(app: app, runner: runner, stagingRoot: staging)
    }

    var installs: OfficeInstalls { OfficeInstalls(microsoft: [.word], staging: staging) }

    /// A made-up LibreOffice that writes a PDF holding `marker` (or fails with `exit 1` when `fails`).
    func soffice(marker: String = "%libre", fails: Bool = false) throws -> String {
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let soffice = bin.appendingPathComponent("soffice")
        let body = fails ? "echo 'Error: source file could not be loaded' >&2\nexit 1\n"
            : "printf '%%PDF-1.4\\n\(marker.replacingOccurrences(of: "%", with: "%%"))\\n' > \"$out/out.pdf\"\n"
        let script = "#!/bin/sh\nprev=\nfor a in \"$@\"; do [ \"$prev\" = \"--outdir\" ] && out=\"$a\"; prev=\"$a\"; done\n" + body
        try Data(script.utf8).write(to: soffice)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: soffice.path)
        return soffice.path
    }

    func installs(_ runner: FakeRunner, soffice: String?) -> OfficeInstalls {
        OfficeInstalls(soffice: soffice, microsoft: [.word], scriptRunner: runner, staging: staging)
    }
    var stagingIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: staging.path)) ?? []).isEmpty }
}

@Suite struct MicrosoftOfficeConversionTests {
    // MARK: Which app converts

    @Test func microsoftsAppConvertsItsOwnKindFirst_LibreOfficeTheRest() {
        let installs = OfficeInstalls(soffice: "/x/soffice", microsoft: [.word, .powerPoint])
        #expect((installs.route("/a/x.docx") as? MicrosoftOfficeConverter)?.app == .word)
        #expect((installs.route("/a/x.RTF") as? MicrosoftOfficeConverter)?.app == .word)
        #expect((installs.route("/a/x.pptx") as? MicrosoftOfficeConverter)?.app == .powerPoint)
        #expect(installs.route("/a/x.xlsx") is LibreOfficeConverter)
        #expect(installs.route("/a/x.docx")?.appName == "Microsoft Word")
    }

    @Test func aPasswordProtectedFileIsRefusedBeforeWordStarts() throws {
        let home = try FakeHome()
        try Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]).write(to: home.document)
        let runner = FakeRunner(FakeRunner.savesPdf)
        var installs = home.installs
        installs.scriptRunner = runner
        let problem = try #require(OfficeConversion.precheck(home.document.path, installs))
        #expect(problem.contains("password"))
        #expect(throws: PdfEditError.self) { _ = try OfficeConversion.convert(home.document.path, installs: installs, fromInternetConfirmed: true, cancel: CancelToken()) }
        #expect(runner.calls.isEmpty)
    }

    /// Only Excel installed: a Word file goes to LibreOffice, end to end through a made-up soffice.
    @Test func withoutWordAWordFileFallsBackToLibreOffice() throws {
        let home = try FakeHome(documentName: "Report.docx")
        let runner = FakeRunner(FakeRunner.savesPdf)
        let installs = OfficeInstalls(soffice: try home.soffice(), microsoft: [.excel], scriptRunner: runner, staging: home.staging)
        let pdf = try OfficeConversion.convert(home.document.path, installs: installs, fromInternetConfirmed: true, cancel: CancelToken())
        #expect(String(decoding: pdf, as: UTF8.self).contains("%libre"))
        #expect(runner.calls.isEmpty)
    }

    // MARK: Staging and cleanup

    @Test func aCopyIsStagedInOfficesGroupFolder_ThePdfComesBack_AndTheCopyGoes() throws {
        let home = try FakeHome()
        let runner = FakeRunner(FakeRunner.savesPdf)
        let pdf = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken())
        #expect(String(decoding: pdf, as: UTF8.self).contains("made-up Word"))
        let call = try #require(runner.calls.first)
        #expect(call.arguments.count == 5 && call.arguments[4] == "false")
        #expect(runner.probes == 1 && runner.cleanups.isEmpty)
        let staged = call.arguments[0], name = call.arguments[2]
        #expect(staged.hasPrefix(home.staging.path + "/" + ConversionTemp.officePrefix))
        #expect((staged as NSString).lastPathComponent == name)
        #expect(call.arguments[1] == (staged as NSString).deletingPathExtension + ".pdf")
        #expect(name.hasPrefix("Quarterly- report (Inkvolt ") && name.hasSuffix(").docx"))
        #expect(call.arguments[3] == "170")
        #expect(call.timeout == 180)
        #expect(runner.stagedBytes == [home.original])
        #expect(home.stagingIsEmpty)
        #expect(FileManager.default.contents(atPath: home.document.path) == home.original)
    }

    @Test func theCopyGoesWhenWordFails_TimesOut_OrIsCancelled() throws {
        let home = try FakeHome()
        for act in [FakeRunner.fails("inkvolt:save: no (-50)"), { _ in ScriptRun(.timedOut) }, { _ in ScriptRun(.cancelled) }] as [@Sendable ([String]) -> ScriptRun] {
            #expect(throws: (any Error).self) { _ = try home.converter(FakeRunner(act)).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
            #expect(home.stagingIsEmpty)
        }
    }

    @Test func aCancelledRunThrowsCancellation_AndACancelledTokenRunsNothing() throws {
        let home = try FakeHome()
        #expect(throws: CancellationError.self) { _ = try home.converter(FakeRunner { _ in ScriptRun(.cancelled) }).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        let runner = FakeRunner(FakeRunner.savesPdf)
        let token = CancelToken()
        token.cancel()
        #expect(throws: CancellationError.self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: token) }
        #expect(runner.calls.isEmpty)
    }

    @Test func officeNeverRunHereSaysToSetItUp() throws {
        let home = try FakeHome(groupExists: false)
        let runner = FakeRunner(FakeRunner.savesPdf)
        let error = try #require(throws: OfficeAppFailure.self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        #expect(error.message.contains("Microsoft Word hasn't been set up on this Mac yet"))
        #expect(runner.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: home.group.path))
    }

    @Test func aFileTooBigIsNotCopied() throws {
        let home = try FakeHome()
        let handle = try FileHandle(forWritingTo: home.document)
        try handle.truncate(atOffset: UInt64(MicrosoftOfficeConverter.maxInputBytes) + 1) // sparse: nothing written
        try handle.close()
        let runner = FakeRunner(FakeRunner.savesPdf)
        let error = try #require(throws: OfficeAppFailure.self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        #expect(error.message.contains("too big to convert here (more than 512 MB)"))
        #expect(runner.calls.isEmpty)
    }

    @Test func aPdfTooBigIsNotRead_AndALinkOrTwoPdfsAreNone() throws {
        let home = try FakeHome()
        let folder = home.root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("%PDF-1.7\n".utf8 + [UInt8](repeating: 32, count: 100)).write(to: folder.appendingPathComponent("a.pdf"))
        #expect(throws: PdfEditError.self) { _ = try ConvertedPdf.read(in: folder, appName: "Microsoft Word", maxBytes: 50) }
        #expect(try ConvertedPdf.read(in: folder, appName: "Microsoft Word", maxBytes: 500) != nil)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("b.pdf").path, withDestinationPath: home.document.path)
        #expect(try ConvertedPdf.read(in: folder, appName: "Microsoft Word") == nil)
    }

    @Test func noPdfSavedSaysToActivateOffice() throws {
        let home = try FakeHome()
        let error = try #require(throws: OfficeAppFailure.self) {
            _ = try home.converter(FakeRunner { _ in ScriptRun(.exited(0), output: "ok") }).toPdf(home.document.path, timeout: 180, cancel: CancelToken())
        }
        #expect(error.message.contains("didn't save it as PDF") && error.message.contains("sign in"))
    }

    @Test func leftoversInOfficesFolderAreSwept() throws {
        let home = try FakeHome()
        try FileManager.default.createDirectory(at: home.staging, withIntermediateDirectories: true)
        let old = home.staging.appendingPathComponent(ConversionTemp.officePrefix + "crashed", isDirectory: true)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: old.path)
        _ = try home.converter(FakeRunner(FakeRunner.savesPdf)).toPdf(home.document.path, timeout: 180, cancel: CancelToken())
        #expect(home.stagingIsEmpty)
    }

    @Test func conversionsRunOneAtATime() throws {
        let home = try FakeHome()
        let runner = FakeRunner { arguments in
            Thread.sleep(forTimeInterval: 0.2)
            return FakeRunner.savesPdf(arguments)
        }
        let converter = home.converter(runner), path = home.document.path
        try Self.onThreads(3) { _ = try converter.toPdf(path, timeout: 180, cancel: CancelToken()) }
        #expect(runner.calls.count == 3 && runner.mostAtOnce == 1)
        #expect(Set(runner.calls.map { $0.arguments[2] }).count == 3)
    }

    @Test func stagedNamesAreUniqueShortAndSafe() {
        #expect(MicrosoftOfficeConverter.stagedName("Report.DOCX", tag: "1a2b3c4d") == "Report (Inkvolt 1a2b3c4d).docx")
        #expect(MicrosoftOfficeConverter.stagedName("a:b/c\u{0}d.xlsx", tag: "t") == "a-b-c-d (Inkvolt t).xlsx")
        #expect(MicrosoftOfficeConverter.stagedName(".pptx", tag: "t") == "Document (Inkvolt t).pptx")
        #expect(MicrosoftOfficeConverter.stagedName(".hidden notes.docx", tag: "t") == "hidden notes (Inkvolt t).docx")
        #expect(MicrosoftOfficeConverter.stagedName("Año 2026.docx", tag: "t") == "Año 2026 (Inkvolt t).docx")
        #expect(MicrosoftOfficeConverter.stagedName(String(repeating: "x", count: 300) + ".doc", tag: "t").count == 60 + " (Inkvolt t).doc".count)
        #expect(MicrosoftOfficeConverter.stagedName("x.d\"oc", tag: "t") == "x (Inkvolt t)")
    }

    @Test func theStagingFolderIsInOfficesGroupContainer() {
        #expect(MicrosoftOfficeConverter.stagingRoot(home: "/Users/me").path == "/Users/me/Library/Group Containers/UBF8T346G9.Office/Inkvolt PDF")
    }

    // MARK: Errors in words

    /// Each failure's message, and whether it is the file's (no other converter is tried) or the app's (LibreOffice is).
    @Test(arguments: [
        ("inkvolt:open: Not authorized to send Apple events to Microsoft Word. (-1743)", "Privacy & Security › Automation", false),
        ("inkvolt:open: would require user consent (-1744)", "Privacy & Security › Automation", false),
        ("inkvolt:open: Microsoft Word got an error: AppleEvent timed out. (-1712)", "didn't finish within 3 minutes", false),
        ("inkvolt:save: Microsoft Word got an error: Connection is invalid. (-609)", "closed before it finished", false),
        ("Application isn't running. (-600)", "closed before it finished", false),
        ("LaunchServices returned an error (-10810)", "couldn't be started", false),
        ("convert.applescript:120:126: syntax error: Expected end of line but found identifier. (-2741)", "couldn't be started", false),
        ("inkvolt:open: The password is incorrect. (5408)", "without its password", true),
        ("inkvolt:open: the file didn't open (1)", "It may be damaged, or protected with a password", true),
        ("inkvolt:save: Microsoft Word got an error: Parameter error. (-50)", "saves only when it is activated", false),
        ("something else entirely", "saves only when it is activated", false),
    ])
    func eachFailureHasItsMessage(line: String, says: String, aboutTheFile: Bool) {
        let failure = MicrosoftOfficeConverter.failure("/x/convert.applescript: execution error: " + line + "\n", appName: "Microsoft Word", timeout: 180)
        #expect(failure.message.contains(says), "\(line) → \(failure.message)")
        #expect(failure.aboutTheFile == aboutTheFile)
        #expect(!failure.message.contains("-1") && !failure.message.contains("execution error"))
    }

    /// "password" in the file's name (or its path) isn't a password error.
    @Test func aPasswordInTheFilesNameIsNotAPasswordError() {
        let name = "Password list (Inkvolt 1a2b3c4d).docx"
        let line = "/x/convert.applescript: execution error: inkvolt:save: Microsoft Word got an error: Can't save \"/Users/me/Library/Group Containers/UBF8T346G9.Office/Inkvolt PDF/inkvolt-office-x/\(name)\". (-50)\n"
        let failure = MicrosoftOfficeConverter.failure(line, appName: "Microsoft Word", timeout: 180, hiding: [name, "/Users/me/Library/Group Containers/UBF8T346G9.Office/Inkvolt PDF/inkvolt-office-x"])
        #expect(failure.message.contains("saves only when it is activated"))
        #expect(!failure.aboutTheFile)
    }

    @Test func aTimeoutSaysWhereToLook() throws {
        let home = try FakeHome()
        let error = try #require(throws: OfficeAppFailure.self) { _ = try home.converter(FakeRunner { _ in ScriptRun(.timedOut) }).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        #expect(error.message == "Microsoft Word didn't finish within 3 minutes. It may be waiting in its window: to sign in, for a password, or with a question. Look at Microsoft Word, then try again.")
        #expect(MicrosoftOfficeConverter.timedOut("Microsoft Excel", 45).contains("within 45 seconds"))
        #expect(MicrosoftOfficeConverter.timedOut("Microsoft Excel", .infinity).contains("within 0 seconds"))
        // LibreOffice's message says the limit the same way, and an infinite one doesn't trap.
        #expect(OfficeConversion.limitText(180) == "3 minutes" && OfficeConversion.limitText(45) == "45 seconds")
        #expect(OfficeConversion.limitText(.infinity) == "0 seconds" && OfficeConversion.limitText(-.nan) == "0 seconds")
        #expect(MicrosoftOfficeConverter.errorCode("x (-1743)") == -1743 && MicrosoftOfficeConverter.errorCode("x (123456789012)") == nil)
    }

    // MARK: The scripts

    @Test(arguments: [(OfficeApp.word, "com.microsoft.Word", "document"), (.excel, "com.microsoft.Excel", "workbook"), (.powerPoint, "com.microsoft.Powerpoint", "presentation")])
    func eachScriptTouchesOnlyItsCopy_AndLeavesTheAppAsFound(app: OfficeApp, id: String, element: String) {
        let script = MicrosoftOfficeScripts.script(app)
        let ascii = script.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
        #expect(script.contains("tell application id \"\(id)\""))
        #expect(script.contains("with timeout of limit seconds"))
        for n in 1...5 { #expect(script.contains("item \(n) of argv")) }
        #expect(script.contains("set wasRunning to (item 5 of argv) is \"true\""))
        #expect(!script.contains("is running"))
        // Every line inside `tell` that asks the app something is inside a `try`, so an Apple Event error there still
        // comes back tagged and the clean-up still runs.
        #expect(MicrosoftOfficeConversionTests.eventsOutsideTry(script, element: element).isEmpty, "\(MicrosoftOfficeConversionTests.eventsOutsideTry(script, element: element))")
        for helper in [MicrosoftOfficeScripts.probe(app), MicrosoftOfficeScripts.cleanup(app)] {
            #expect(helper.contains("application id \"\(id)\""))
            #expect(!helper.contains("activate") && !helper.contains("do shell script") && !helper.contains("open "))
        }
        let cleanup = MicrosoftOfficeScripts.cleanup(app)
        #expect(cleanup.contains("if application id \"\(id)\" is running then")) // never launches the app to close it
        #expect(cleanup.contains("close \(element) docName saving no") && cleanup.contains("if not wasRunning then"))
        #expect(MicrosoftOfficeConversionTests.eventsOutsideTry(cleanup, element: element).isEmpty)
        #expect(script.contains("exists \(element) docName"))
        #expect(script.contains("close \(element) docName saving no"))
        #expect(script.contains("if not wasRunning then") && script.contains("if (count of \(element)s) is 0 then quit"))
        // Nothing but the copy is named; nothing brought to the front, run in a shell or saved over.
        for word in ["activate", "do shell script", "active document", "active workbook", "active presentation", "saving yes", "/Users", "close every", "open for access"] {
            #expect(!script.contains(word), "\(word)")
        }
        #expect(script.contains(MicrosoftOfficeScripts.terms(app).save))
        #expect(script.contains("error \"inkvolt:\" & failure number failureCode"))
        // A stuck or denied event isn't followed by more that would wait too.
        #expect(script.contains("if failureCode is not -1712 and failureCode is not -1743 and failureCode is not -1744 then"))
    }

    // MARK: osascript itself (no app driven)

    @Test func osascriptGetsItsArgumentsAsTheyAre() throws {
        let tricky = "/tmp/a \"b\" & 'c' $(d) `e`.docx"
        let run = try OsascriptRunner().run("on run argv\nreturn (item 1 of argv) & \"|\" & (count of argv)\nend run\n",
                                            arguments: [tricky, "two"], timeout: 30, cancel: CancelToken(), appName: "Microsoft Word")
        #expect(run.ending == .exited(0))
        #expect(run.output.trimmingCharacters(in: .newlines) == tricky + "|2")
    }

    @Test func osascriptsErrorsComeBackWithTheirNumber() throws {
        let run = try OsascriptRunner().run("on run argv\nerror \"inkvolt:save: no\" number -50\nend run\n",
                                            arguments: [], timeout: 30, cancel: CancelToken(), appName: "Microsoft Word")
        #expect(run.ending != .exited(0))
        #expect(run.errors.contains("inkvolt:save: no (-50)"))
        #expect(MicrosoftOfficeConverter.failure(run.errors, appName: "Microsoft Word", timeout: 180).message.contains("saves only when it is activated"))
    }

    @Test func osascriptIsStoppedAtTheTimeLimit_AndOnCancel() throws {
        let start = Date()
        let run = try OsascriptRunner().run("delay 30\n", arguments: [], timeout: 1, cancel: CancelToken(), appName: "Microsoft Word")
        #expect(run.ending == .timedOut)
        #expect(Date().timeIntervalSince(start) < 30)
        // Cancelled from a thread of its own: under the whole suite's load Dispatch's queues can be too busy to run it in time.
        let token = CancelToken()
        Thread {
            Thread.sleep(forTimeInterval: 0.5)
            token.cancel()
        }.start()
        let cancelled = try OsascriptRunner().run("delay 30\n", arguments: [], timeout: 60, cancel: token, appName: "Microsoft Word")
        #expect(cancelled.ending == .cancelled)
    }

    // MARK: Review fixes (2026-11-07)

    /// Runs `body` on `count` threads of their own at once (as the app's conversions do, `OfficeConversion.run`), so the
    /// blocking conversions hold none of the pool's threads other tests need; rethrows the first error.
    static func onThreads(_ count: Int, _ body: @escaping @Sendable () throws -> Void) throws {
        let done = DispatchGroup(), lock = NSLock()
        nonisolated(unsafe) var first: Error?
        for _ in 0..<count {
            done.enter()
            Thread {
                do { try body() } catch { lock.withLock { if first == nil { first = error } } }
                done.leave()
            }.start()
        }
        done.wait()
        if let first = lock.withLock({ first }) { throw first }
    }

    /// The lines inside `tell application` that talk to the app (exists, close, count, quit, open, save) outside a `try`.
    static func eventsOutsideTry(_ script: String, element: String) -> [String] {
        var tells = 0, tries = 0, found: [String] = []
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("tell application") { tells += 1; continue }
            if line == "end tell" { tells -= 1; continue }
            if line == "try" { tries += 1; continue }
            if line == "end try" { tries -= 1; continue }
            let talks = ["exists ", "close ", "count of", "quit", "open ", "save "].contains { line.contains($0) }
            if tells > 0 && tries == 0 && talks { found.append(line) }
        }
        return found
    }

    /// 1. Word failing for a reason of its own (not activated, Automation denied, couldn't start, a timeout, too big, not
    /// set up) is followed by LibreOffice when installed; the result says which converted it and why Word didn't.
    @Test(arguments: [
        "inkvolt:save: Microsoft Word got an error: Parameter error. (-50)",
        "inkvolt:open: Not authorized to send Apple events to Microsoft Word. (-1743)",
        "LaunchServices returned an error (-10810)",
        "inkvolt:open: Microsoft Word got an error: AppleEvent timed out. (-1712)",
    ])
    func wordsOwnFailureFallsBackToLibreOffice(line: String) throws {
        let home = try FakeHome(documentName: "Report.docx")
        let runner = FakeRunner(FakeRunner.fails(line))
        let installs = home.installs(runner, soffice: try home.soffice())
        let job = try OfficeConversion.job(home.document.path, installs)
        #expect(job.appName == "Microsoft Word")
        let result = try OfficeConversion.convert(job, fromInternetConfirmed: true, cancel: CancelToken())
        #expect(String(decoding: result.pdf, as: UTF8.self).contains("%libre"))
        #expect(result.appName == "LibreOffice")
        #expect(result.firstFailure != nil && result.firstFailure != "")
        let notice = result.notice("Report.docx")
        #expect(notice.hasPrefix("Made from Report.docx with LibreOffice.") && notice.contains("Microsoft Word couldn't convert it: \(result.firstFailure ?? "")"))
        #expect(runner.calls.count == 1 && home.stagingIsEmpty)
    }

    @Test func aTimeoutOrTooBigFallsBackToo() throws {
        let home = try FakeHome(documentName: "Big.docx")
        let timedOut = FakeRunner { _ in ScriptRun(.timedOut) }
        let viaTimeout = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, home.installs(timedOut, soffice: try home.soffice())),
                                                      fromInternetConfirmed: true, cancel: CancelToken())
        #expect(viaTimeout.appName == "LibreOffice" && viaTimeout.firstFailure?.contains("didn't finish within") == true)
        // 6. A file over Office's 512 MB copy limit still goes to LibreOffice, as it did before.
        let handle = try FileHandle(forWritingTo: home.document)
        try handle.truncate(atOffset: UInt64(MicrosoftOfficeConverter.maxInputBytes) + 1)
        try handle.close()
        let runner = FakeRunner(FakeRunner.savesPdf)
        let big = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, home.installs(runner, soffice: try home.soffice())),
                                               fromInternetConfirmed: true, cancel: CancelToken())
        #expect(big.appName == "LibreOffice" && big.firstFailure?.contains("too big") == true && runner.calls.isEmpty)
        // Without LibreOffice, the same file says Word's own reason.
        let alone = try #require(throws: PdfEditError.self) {
            _ = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, home.installs(runner, soffice: nil)), fromInternetConfirmed: true, cancel: CancelToken())
        }
        #expect(alone.message.contains("too big to convert here"))
    }

    /// The file's own trouble (a password, a file Word couldn't open) isn't handed to LibreOffice.
    @Test(arguments: ["inkvolt:open: The password is incorrect. (5408)", "inkvolt:open: the file didn't open (1)"])
    func theFilesOwnFailureIsNotRetried(line: String) throws {
        let home = try FakeHome(documentName: "Report.docx")
        let installs = home.installs(FakeRunner(FakeRunner.fails(line)), soffice: try home.soffice())
        let error = try #require(throws: PdfEditError.self) {
            _ = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, installs), fromInternetConfirmed: true, cancel: CancelToken())
        }
        #expect(error.message.contains("Microsoft Word couldn't open this file"))
    }

    @Test func whenLibreOfficeFailsTooBothAreSaid() throws {
        let home = try FakeHome(documentName: "Report.docx")
        let installs = home.installs(FakeRunner(FakeRunner.fails("inkvolt:save: no (-50)")), soffice: try home.soffice(fails: true))
        let error = try #require(throws: PdfEditError.self) {
            _ = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, installs), fromInternetConfirmed: true, cancel: CancelToken())
        }
        #expect(error.message.contains("saves only when it is activated") && error.message.contains("LibreOffice couldn't save this file as PDF"))
    }

    @Test func cancellingIsNeverRetried() throws {
        let home = try FakeHome(documentName: "Report.docx")
        let installs = home.installs(FakeRunner { _ in ScriptRun(.cancelled) }, soffice: try home.soffice())
        #expect(throws: CancellationError.self) {
            _ = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, installs), fromInternetConfirmed: true, cancel: CancelToken())
        }
    }

    /// 2. After a timeout, a Cancel, osascript stopped at the limit or the script's own timeout, a short script closes the
    /// copy by name and quits the app if Inkvolt started it, before the copy is removed; not after a success or a denial.
    @Test func aStuckRunIsCleanedUpBeforeTheCopyGoes() throws {
        let home = try FakeHome()
        let cases: [(ScriptRun, Bool)] = [
            (ScriptRun(.timedOut), true), (ScriptRun(.cancelled), true),
            (ScriptRun(.exited(1), errors: "execution error: inkvolt:open: AppleEvent timed out. (-1712)"), true),
            (ScriptRun(.exited(1), errors: "execution error: inkvolt:save: no (-50)"), true),
            (ScriptRun(.exited(1), errors: "execution error: inkvolt:open: Not authorized (-1743)"), false),
        ]
        for (ending, cleans) in cases {
            let runner = FakeRunner { _ in ending }
            #expect(throws: (any Error).self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
            #expect(runner.cleanups.count == (cleans ? 1 : 0), "\(ending)")
            if cleans {
                let cleanup = try #require(runner.cleanups.first)
                #expect(cleanup.arguments == [try #require(runner.calls.first).arguments[2], "false"])
                #expect(cleanup.timeout <= 20)
                #expect(runner.copyThereAtCleanup == [true])
            }
            #expect(home.stagingIsEmpty)
        }
        let fine = FakeRunner(FakeRunner.savesPdf)
        _ = try home.converter(fine).toPdf(home.document.path, timeout: 180, cancel: CancelToken())
        #expect(fine.cleanups.isEmpty)
    }

    /// The app was running before: neither script may quit it.
    @Test func anAppThatWasRunningIsNeverQuit() throws {
        let home = try FakeHome()
        let runner = FakeRunner(wasRunning: true) { _ in ScriptRun(.timedOut) }
        #expect(throws: OfficeAppFailure.self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        #expect(runner.calls.first?.arguments[4] == "true" && runner.cleanups.first?.arguments[1] == "true")
    }

    /// 3. The next conversion waits for the last one's clean-up: no two scripts ever run at once.
    @Test func theNextConversionWaitsForTheCleanUp() throws {
        let home = try FakeHome()
        let runner = FakeRunner { _ in
            Thread.sleep(forTimeInterval: 0.1)
            return ScriptRun(.timedOut)
        }
        let converter = home.converter(runner), path = home.document.path
        try Self.onThreads(3) { _ = try? converter.toPdf(path, timeout: 180, cancel: CancelToken()) }
        #expect(runner.calls.count == 3 && runner.cleanups.count == 3 && runner.mostAtOnce == 1)
    }

    /// 5. Excel saving one PDF per sheet is said as such (and LibreOffice tried), never as "not activated".
    @Test func severalPdfsAreSaidAsSuch_AndLibreOfficeTried() throws {
        let home = try FakeHome(documentName: "Book.xlsx")
        let runner = FakeRunner(app: .excel) { arguments in
            let pdf = arguments[1] as NSString
            for sheet in ["Sheet1", "Sheet2"] {
                try? Data("%PDF-1.7\n".utf8).write(to: URL(fileURLWithPath: pdf.deletingPathExtension + " \(sheet).pdf"))
            }
            return ScriptRun(.exited(0), output: "ok")
        }
        let failure = try #require(throws: OfficeAppFailure.self) { _ = try home.converter(runner, .excel).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        #expect(failure.message.contains("2 separate PDFs") && !failure.message.contains("activated") && !failure.aboutTheFile)
        let installs = OfficeInstalls(soffice: try home.soffice(), microsoft: [.excel], scriptRunner: runner, staging: home.staging)
        let result = try OfficeConversion.convert(try OfficeConversion.job(home.document.path, installs), fromInternetConfirmed: true, cancel: CancelToken())
        #expect(result.appName == "LibreOffice" && result.firstFailure?.contains("separate PDFs") == true)
    }

    /// 8. The blocking work runs on a thread of its own, not one of Swift concurrency's pool.
    @Test func theAsyncConversionRunsOnAThreadOfItsOwn() async throws {
        let home = try FakeHome()
        let runner = FakeRunner(FakeRunner.savesPdf)
        let job = try OfficeConversion.job(home.document.path, home.installs(runner, soffice: nil))
        let result = try await OfficeConversion.run(job, fromInternetConfirmed: true, cancel: CancelToken())
        #expect(result.appName == "Microsoft Word")
        #expect(!runner.threadNames.isEmpty && runner.threadNames.allSatisfy { $0 == OfficeConversion.threadName })
    }

    /// 10. The job is chosen once: what it names is what runs, whatever is installed after.
    @Test func theJobNamesTheConverterThatRuns() throws {
        let home = try FakeHome()
        let runner = FakeRunner(FakeRunner.savesPdf)
        let job = try OfficeConversion.job(home.document.path, home.installs(runner, soffice: try home.soffice()))
        #expect(job.converters.map(\.appName) == ["Microsoft Word", "LibreOffice"])
        let result = try OfficeConversion.convert(job, fromInternetConfirmed: true, cancel: CancelToken())
        #expect(result.appName == job.appName && result.firstFailure == nil && runner.calls.count == 1)
        #expect(throws: PdfEditError.self) { _ = try OfficeConversion.job(home.document.path, OfficeInstalls()) }
    }
}
