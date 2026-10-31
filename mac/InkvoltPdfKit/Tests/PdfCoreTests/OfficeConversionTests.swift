import Darwin
import Foundation
import Testing
@testable import PdfCore

/// A fake `soffice`: a shell script that records what it was given, then does what the test says. No test here runs
/// LibreOffice or Word (neither is on the Mac or in CI); the real ones are listed as not run in PLAN.md's E12.
private final class FakeOffice {
    let root: URL
    let temp: URL
    let record: URL
    let soffice: String
    let document: URL

    /// `body` runs in the script with `$out` (the output folder), `$input` (the file) and `$record` (a folder to write to).
    init(_ body: String, documentName: String = "Report.docx", documentBytes: [UInt8] = Array("PK\u{3}\u{4}content".utf8)) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-test-\(UUID().uuidString)", isDirectory: true)
        temp = root.appendingPathComponent("temp", isDirectory: true)
        record = root.appendingPathComponent("record", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let docs = root.appendingPathComponent("docs", isDirectory: true)
        for folder in [temp, record, bin, docs] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        document = docs.appendingPathComponent(documentName)
        try Data(documentBytes).write(to: document)
        let script = bin.appendingPathComponent("soffice")
        let prelude = #"""
        #!/bin/sh
        record='\#(record.path)'
        : > "$record/args"
        prev=
        for a in "$@"; do
            printf '%s\n' "$a" >> "$record/args"
            [ "$prev" = "--outdir" ] && out="$a"
            prev="$a"
            input="$a"
        done
        env > "$record/env"
        printf '%s\n' "$$" > "$record/pid"
        pwd > "$record/cwd"

        """#
        try Data((prelude + body + "\n").utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        soffice = script.path
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    var converter: LibreOfficeConverter { LibreOfficeConverter(soffice: soffice, tempRoot: temp) }
    func recorded(_ name: String) -> String { (try? String(contentsOf: record.appendingPathComponent(name), encoding: .utf8)) ?? "" }
    var arguments: [String] { recorded("args").split(separator: "\n").map(String.init) }
    var wasStarted: Bool { FileManager.default.fileExists(atPath: record.appendingPathComponent("args").path) }
    /// The temp folder holds nothing: no work folder left, on any path.
    var tempIsEmpty: Bool { ((try? FileManager.default.contentsOfDirectory(atPath: temp.path)) ?? ["?"]).isEmpty }

    func isAlive(_ recordName: String) -> Bool {
        guard let pid = Int32(recorded(recordName).trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return kill(pid, 0) == 0
    }

    func message(timeout: TimeInterval = 20, cancel: CancelToken = CancelToken()) -> String? {
        do {
            _ = try converter.toPdf(document.path, timeout: timeout, cancel: cancel)
            return nil
        } catch {
            return (error as? PdfEditError)?.message ?? "\(type(of: error))"
        }
    }

    static let writesPdf = #"printf '%%PDF-1.4\n%%fake\n' > "$out/$(basename "$input" | sed 's/\.[^.]*$//').pdf""#
}

@Suite struct OfficeConversionTests {
    @Test func theConverterTurnsAFileIntoPdfBytes() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf)
        let pdf = try fake.converter.toPdf(fake.document.path, timeout: 20, cancel: CancelToken())
        #expect(pdf.starts(with: Array("%PDF-1.4".utf8)))
        #expect(fake.converter.appName == "LibreOffice")
    }

    /// Paths go as arguments, never through a shell: what a shell would run stays a part of the name.
    @Test(arguments: ["a b; touch PWNED; $(touch PWNED2) `touch PWNED3` 'q' \"d\" & |.docx", "-rf.docx", "--headless.docx", "ünï çødé ✓.docx", "new\nline.docx"])
    func theFileReachesTheConverterAsOneArgument(name: String) throws {
        let fake = try FakeOffice(FakeOffice.writesPdf, documentName: name)
        let pdf = try fake.converter.toPdf(fake.document.path, timeout: 20, cancel: CancelToken())
        #expect(!pdf.isEmpty)
        #expect(fake.recorded("args").hasSuffix(fake.document.path + "\n"))
        for planted in ["PWNED", "PWNED2", "PWNED3"] {
            let cwd = fake.recorded("cwd").trimmingCharacters(in: .newlines)
            #expect(!FileManager.default.fileExists(atPath: (cwd as NSString).appendingPathComponent(planted)))
            #expect(!FileManager.default.fileExists(atPath: fake.root.appendingPathComponent(planted).path))
        }
    }

    @Test func aPathThatIsNotFullIsNeverTakenForAnOption() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf)
        #expect(throws: PdfEditError.self) { _ = try fake.converter.toPdf("--help", timeout: 20, cancel: CancelToken()) }
        #expect(!fake.wasStarted)
    }

    @Test func theConverterRunsHeadlessInAProfileOfItsOwn() throws {
        let fake = try FakeOffice(#"""
        for a in "$@"; do case "$a" in -env:UserInstallation=file://*) cp "${a#-env:UserInstallation=file://}/user/registrymodifications.xcu" "$record/xcu";; esac; done
        \#(FakeOffice.writesPdf)
        """#)
        _ = try fake.converter.toPdf(fake.document.path, timeout: 20, cancel: CancelToken())
        let args = fake.arguments
        #expect(args.contains("--headless"))
        #expect(args.contains("--norestore"))
        #expect(args.firstIndex(of: "--convert-to").map { args[$0 + 1] } == "pdf")
        let profile = try #require(args.first { $0.hasPrefix("-env:UserInstallation=file://") })
        #expect(profile.contains(fake.temp.lastPathComponent)) // inside the temp folder, gone afterwards
        let settings = fake.recorded("xcu")
        #expect(settings.hasPrefix("<?xml"))
        #expect(settings.contains(#"<prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value>"#))
        #expect(settings.contains(#"<prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value>"#))
        #expect(settings.contains(#"<prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value>"#))
        #expect(settings.contains(#"Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value>"#)) // Writer's "never"
        #expect(settings.contains(#"Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>1</value>"#)) // Calc's "never"
    }

    @Test func theProfileSettingsAreWellFormed() throws {
        let parser = XMLParser(data: Data(LibreOfficeConverter.profileSettings.utf8))
        #expect(parser.parse())
    }

    @Test func theConverterGetsNoneOfTheAppsEnvironment() throws {
        setenv("INKVOLT_TEST_SECRET", "x", 1)
        defer { unsetenv("INKVOLT_TEST_SECRET") }
        let fake = try FakeOffice(FakeOffice.writesPdf)
        _ = try fake.converter.toPdf(fake.document.path, timeout: 20, cancel: CancelToken())
        let env = fake.recorded("env")
        #expect(!env.contains("INKVOLT_TEST_SECRET"))
        let temp = try #require(env.split(separator: "\n").first { $0.hasPrefix("TMPDIR=") })
        #expect(temp.contains(fake.temp.lastPathComponent)) // its temp files go with the work folder
    }

    @Test func theOriginalIsLeftAsItWas() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf)
        let before = try Data(contentsOf: fake.document), date = try FileManager.default.attributesOfItem(atPath: fake.document.path)[.modificationDate] as? Date
        _ = try fake.converter.toPdf(fake.document.path, timeout: 20, cancel: CancelToken())
        #expect(try Data(contentsOf: fake.document) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: fake.document.path)[.modificationDate] as? Date == date)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fake.document.deletingLastPathComponent().path) == [fake.document.lastPathComponent])
    }

    // MARK: The temp folder goes on every path

    @Test func theTempFolderGoesAfterASuccess() throws {
        let fake = try FakeOffice(#"cp "$input" "$TMPDIR/copy.docx"; "# + FakeOffice.writesPdf)
        #expect(fake.message() == nil)
        #expect(fake.tempIsEmpty)
    }

    @Test(arguments: [("exit 3", "couldn't save"), // it failed
                      (#"echo 'Error: source file could not be loaded' >&2; exit 1"#, "source file could not be loaded"), // and said why
                      ("exit 0", "couldn't save"), // LibreOffice exits 0 when it writes nothing
                      (#"printf 'not a pdf' > "$out/x.pdf""#, "couldn't save"), // not a PDF
                      (#"printf '%%PDF-' > "$out/a.pdf"; printf '%%PDF-' > "$out/b.pdf""#, "couldn't save"), // which one?
                      (#"ln -s /etc/passwd "$out/x.pdf""#, "couldn't save")]) // a link out of the folder
    func aFailureSaysSoAndLeavesNothing(script: String, says: String) throws {
        let fake = try FakeOffice(script)
        let message = try #require(fake.message())
        #expect(message.contains(says))
        #expect(message.hasPrefix("LibreOffice"))
        #expect(fake.tempIsEmpty)
    }

    @Test func aMissingProgramSaysSo() throws {
        let fake = try FakeOffice("")
        try FileManager.default.removeItem(atPath: fake.soffice)
        #expect(fake.message() == "LibreOffice couldn't be started.")
        #expect(fake.tempIsEmpty)
    }

    // MARK: A hung converter

    @Test func aHungConverterIsEndedWithItsChildren() throws {
        let fake = try FakeOffice(#"sleep 300 & printf '%s\n' "$!" > "$record/child"; wait"#)
        let started = Date()
        let message = try #require(fake.message(timeout: 1))
        #expect(message.contains("didn't finish within 1 seconds"))
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(!fake.isAlive("pid"))
        #expect(!fake.isAlive("child"))
        #expect(fake.tempIsEmpty)
    }

    @Test func aConverterThatIgnoresTerminationIsKilled() throws {
        let fake = try FakeOffice(#"trap '' TERM; sleep 300 & printf '%s\n' "$!" > "$record/child"; while :; do sleep 1; done"#)
        let started = Date()
        let message = try #require(fake.message(timeout: 1))
        #expect(message.contains("didn't finish"))
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(!fake.isAlive("pid"))
        #expect(!fake.isAlive("child"))
        #expect(fake.tempIsEmpty)
    }

    @Test func cancellingEndsTheConverter() throws {
        let fake = try FakeOffice(#"sleep 300 & printf '%s\n' "$!" > "$record/child"; wait"#)
        let cancel = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { cancel.cancel() }
        let started = Date()
        #expect(throws: CancellationError.self) { _ = try fake.converter.toPdf(fake.document.path, timeout: 60, cancel: cancel) }
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(!fake.isAlive("pid"))
        #expect(!fake.isAlive("child"))
        #expect(fake.tempIsEmpty)
    }

    @Test func alreadyCancelledNeverStartsIt() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf)
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { _ = try fake.converter.toPdf(fake.document.path, timeout: 60, cancel: cancel) }
        #expect(!fake.wasStarted)
    }

    /// A child that outlives the program keeps its stderr; nothing here waits for that, and the child goes too.
    @Test func aChildLeftBehindBlocksNothing() throws {
        let fake = try FakeOffice(#"sleep 300 & printf '%s\n' "$!" > "$record/child"; "# + FakeOffice.writesPdf)
        let started = Date()
        #expect(fake.message() == nil)
        #expect(Date().timeIntervalSince(started) < 8)
        #expect(!fake.isAlive("child"))
        #expect(fake.tempIsEmpty)
    }

    /// A converter that floods its output can't fill a pipe: there is none.
    @Test func aConverterThatTalksALotDoesNotBlock() throws {
        let fake = try FakeOffice(#"head -c 2000000 /dev/zero | tr '\0' 'x'; head -c 2000000 /dev/zero | tr '\0' 'y' >&2; exit 1"#)
        let message = try #require(fake.message())
        #expect(message.count < 400)
        #expect(message.contains("…"))
        #expect(fake.tempIsEmpty)
    }

    @Test func errorOutputIsShort() {
        #expect(OfficeConversion.reason("") == "")
        #expect(OfficeConversion.reason("\n \n") == "")
        #expect(OfficeConversion.reason("\nfirst\nsecond\n") == " (first)")
        let long = OfficeConversion.reason(String(repeating: "x", count: 500))
        #expect(long.count == 164)
    }

    // MARK: Before it starts

    @Test func aPasswordProtectedFileIsRefusedBeforeStarting() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf, documentBytes: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0])
        let installs = OfficeInstalls(soffice: fake.soffice)
        let problem = try #require(OfficeConversion.precheck(fake.document.path, installs))
        #expect(problem.contains("password"))
        #expect(throws: PdfEditError.self) { _ = try OfficeConversion.convert(fake.document.path, installs: installs, fromInternetConfirmed: true, cancel: CancelToken()) }
        #expect(!fake.wasStarted)
    }

    @Test func nothingInstalledSaysWhatIsMissing() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf)
        let problem = try #require(OfficeConversion.precheck(fake.document.path, OfficeInstalls()))
        #expect(problem.contains("LibreOffice, which isn't installed on this Mac"))
        #expect(problem.contains("libreoffice.org"))
        #expect(!problem.contains("Microsoft"))
    }

    /// Word for Mac isn't used yet: it is said so, with what to do instead, and only for the file kind it could open.
    @Test func wordAloneSaysItCantBeUsedYet() throws {
        let installs = OfficeInstalls(microsoft: [.word])
        #expect(installs.route("/a/x.docx") == nil)
        #expect(installs.missing(.word).contains("can't use Microsoft Word yet"))
        #expect(installs.missing(.word).contains("save it as PDF there"))
        #expect(!installs.missing(.excel).contains("Microsoft"))
    }

    @Test func libreOfficeTakesEveryKind() throws {
        let installs = OfficeInstalls(soffice: "/x/soffice", microsoft: [.word])
        for path in ["/a/x.docx", "/a/x.xlsx", "/a/x.pptx", "/a/x.odt"] { #expect(installs.route(path)?.appName == "LibreOffice") }
    }

    @Test func libreOfficeIsFoundWhereItsInstallerPutsIt() {
        let bundles = OfficeInstalls.libreOfficeBundles(home: "/Users/me")
        #expect(bundles == ["/Applications/LibreOffice.app", "/Users/me/Applications/LibreOffice.app"])
        #expect(OfficeInstalls.soffice(in: bundles) { $0 == "/Users/me/Applications/LibreOffice.app/Contents/MacOS/soffice" } == "/Users/me/Applications/LibreOffice.app/Contents/MacOS/soffice")
        #expect(OfficeInstalls.soffice(in: bundles) { _ in false } == nil)
    }

    @Test func aDownloadedFileNeedsAnOkFirst() throws {
        let fake = try FakeOffice(FakeOffice.writesPdf)
        let mark = "0083;65a1b2c3;Safari;"
        #expect(setxattr(fake.document.path, "com.apple.quarantine", mark, mark.utf8.count, 0, 0) == 0)
        let installs = OfficeInstalls(soffice: fake.soffice)
        #expect(throws: PdfEditError.self) { _ = try OfficeConversion.convert(fake.document.path, installs: installs, fromInternetConfirmed: false, cancel: CancelToken()) }
        #expect(!fake.wasStarted)
    }

    // MARK: What a crash leaves

    @Test func leftoversAreSwept() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let office = try ConversionTemp.make(ConversionTemp.officePrefix, root: root)
        let web = try ConversionTemp.make(ConversionTemp.webPrefix, root: root)
        let other = root.appendingPathComponent("someone-elses", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        #expect((try FileManager.default.attributesOfItem(atPath: office.path)[.posixPermissions] as? Int) == 0o700)

        ConversionTemp.sweepLeftovers(root: root) // just made: may be running
        #expect(FileManager.default.fileExists(atPath: office.path))
        ConversionTemp.sweepLeftovers(root: root, now: Date().addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: office.path))
        #expect(!FileManager.default.fileExists(atPath: web.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }
}
