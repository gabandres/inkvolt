import Foundation
import Testing
@testable import PdfCore

/// A made-up Word, Excel or PowerPoint: the script runner faked, doing what the test says with the script's arguments
/// (the copy, the PDF to save, the copy's name, the seconds). No test runs Microsoft Office (it isn't on the Mac or in CI;
/// PLAN.md's E12 lists what only a person with Microsoft 365 can check). `OsascriptRunner` itself is run with scripts
/// that drive no app.
private final class FakeRunner: OfficeScriptRunner, @unchecked Sendable {
    private let lock = NSLock()
    private let act: @Sendable ([String]) -> ScriptRun
    private(set) var calls: [(script: String, arguments: [String], timeout: TimeInterval)] = []
    private(set) var stagedBytes: [Data] = []
    private var running = 0
    private(set) var mostAtOnce = 0

    init(_ act: @escaping @Sendable ([String]) -> ScriptRun) { self.act = act }

    func run(_ script: String, arguments: [String], timeout: TimeInterval, cancel: CancelToken, appName: String) throws -> ScriptRun {
        lock.withLock {
            calls.append((script, arguments, timeout))
            if let first = arguments.first, let data = FileManager.default.contents(atPath: first) { stagedBytes.append(data) }
            running += 1
            mostAtOnce = max(mostAtOnce, running)
        }
        defer { lock.withLock { running -= 1 } }
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
        let bin = home.root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let soffice = bin.appendingPathComponent("soffice")
        let script = "#!/bin/sh\nprev=\nfor a in \"$@\"; do [ \"$prev\" = \"--outdir\" ] && out=\"$a\"; prev=\"$a\"; done\n"
            + "printf '%%PDF-1.4\\n%%libre\\n' > \"$out/Report.pdf\"\n"
        try Data(script.utf8).write(to: soffice)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: soffice.path)
        let runner = FakeRunner(FakeRunner.savesPdf)
        let installs = OfficeInstalls(soffice: soffice.path, microsoft: [.excel], scriptRunner: runner, staging: home.staging)
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
        #expect(call.arguments.count == 4)
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
        let error = try #require(throws: PdfEditError.self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
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
        let error = try #require(throws: PdfEditError.self) { _ = try home.converter(runner).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
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
        let error = try #require(throws: PdfEditError.self) {
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

    @Test func conversionsRunOneAtATime() async throws {
        let home = try FakeHome()
        let runner = FakeRunner { arguments in
            Thread.sleep(forTimeInterval: 0.2)
            return FakeRunner.savesPdf(arguments)
        }
        let converter = home.converter(runner), path = home.document.path
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<3 { group.addTask { _ = try converter.toPdf(path, timeout: 180, cancel: CancelToken()) } }
            try await group.waitForAll()
        }
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

    @Test(arguments: [
        ("inkvolt:open: Not authorized to send Apple events to Microsoft Word. (-1743)", "Privacy & Security › Automation"),
        ("inkvolt:open: would require user consent (-1744)", "Privacy & Security › Automation"),
        ("inkvolt:open: Microsoft Word got an error: AppleEvent timed out. (-1712)", "didn't finish within 3 minutes"),
        ("inkvolt:save: Microsoft Word got an error: Connection is invalid. (-609)", "closed before it finished"),
        ("Application isn't running. (-600)", "closed before it finished"),
        ("LaunchServices returned an error (-10810)", "couldn't be started"),
        ("convert.applescript:120:126: syntax error: Expected end of line but found identifier. (-2741)", "couldn't be started"),
        ("inkvolt:open: The password is incorrect. (5408)", "without its password"),
        ("inkvolt:open: the file didn't open (1)", "It may be damaged, or protected with a password"),
        ("inkvolt:save: Microsoft Word got an error: Parameter error. (-50)", "saves only when it is activated"),
        ("something else entirely", "saves only when it is activated"),
    ])
    func eachFailureHasItsMessage(line: String, says: String) {
        let message = MicrosoftOfficeConverter.failure("/x/convert.applescript: execution error: " + line + "\n", appName: "Microsoft Word", timeout: 180)
        #expect(message.contains(says), "\(line) → \(message)")
        #expect(!message.contains("-1") && !message.contains("execution error"))
    }

    @Test func aTimeoutSaysWhereToLook() throws {
        let home = try FakeHome()
        let error = try #require(throws: PdfEditError.self) { _ = try home.converter(FakeRunner { _ in ScriptRun(.timedOut) }).toPdf(home.document.path, timeout: 180, cancel: CancelToken()) }
        #expect(error.message == "Microsoft Word didn't finish within 3 minutes. It may be waiting in its window: to sign in, for a password, or with a question. Look at Microsoft Word, then try again.")
        #expect(MicrosoftOfficeConverter.timedOut("Microsoft Excel", 45).contains("within 45 seconds"))
        #expect(MicrosoftOfficeConverter.timedOut("Microsoft Excel", .infinity).contains("within 0 seconds"))
        #expect(MicrosoftOfficeConverter.errorCode("x (-1743)") == -1743 && MicrosoftOfficeConverter.errorCode("x (123456789012)") == nil)
    }

    // MARK: The scripts

    @Test(arguments: [(OfficeApp.word, "com.microsoft.Word", "document"), (.excel, "com.microsoft.Excel", "workbook"), (.powerPoint, "com.microsoft.Powerpoint", "presentation")])
    func eachScriptTouchesOnlyItsCopy_AndLeavesTheAppAsFound(app: OfficeApp, id: String, element: String) {
        let script = MicrosoftOfficeScripts.script(app)
        let ascii = script.unicodeScalars.allSatisfy { $0.isASCII }
        #expect(ascii)
        #expect(script.contains("tell application id \"\(id)\""))
        #expect(script.contains("set wasRunning to application id \"\(id)\" is running"))
        #expect(script.contains("with timeout of limit seconds"))
        for n in 1...4 { #expect(script.contains("item \(n) of argv")) }
        #expect(script.contains("exists \(element) docName"))
        #expect(script.contains("close \(element) docName saving no"))
        #expect(script.contains("if not wasRunning then") && script.contains("if (count of \(element)s) is 0 then quit"))
        // Nothing but the copy is named; nothing brought to the front, run in a shell or saved over.
        for word in ["activate", "do shell script", "active document", "active workbook", "active presentation", "saving yes", "/Users", "close every"] {
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
        #expect(MicrosoftOfficeConverter.failure(run.errors, appName: "Microsoft Word", timeout: 180).contains("saves only when it is activated"))
    }

    @Test func osascriptIsStoppedAtTheTimeLimit_AndOnCancel() throws {
        let start = Date()
        let run = try OsascriptRunner().run("delay 30\n", arguments: [], timeout: 1, cancel: CancelToken(), appName: "Microsoft Word")
        #expect(run.ending == .timedOut)
        #expect(Date().timeIntervalSince(start) < 10)
        let token = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { token.cancel() }
        let cancelled = try OsascriptRunner().run("delay 30\n", arguments: [], timeout: 60, cancel: token, appName: "Microsoft Word")
        #expect(cancelled.ending == .cancelled)
    }
}
