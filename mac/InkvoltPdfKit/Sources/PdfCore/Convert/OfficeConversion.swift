import Darwin
import Foundation
import PrintCore

/// Folders for a conversion's work files, in the user's own temp folder and for the user only. Each is removed when its
/// conversion ends; what a crash leaves goes at the next launch (`sweepLeftovers`), since it can hold a copy of a document.
public enum ConversionTemp {
    public static let officePrefix = "inkvolt-office-", webPrefix = "inkvolt-web-"

    public static func make(_ prefix: String, root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let folder = root.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// Removes `folder`; a process just ended may still hold a file for a moment.
    public static func remove(_ folder: URL) {
        for attempt in 0..<4 {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.2) }
            do {
                try FileManager.default.removeItem(at: folder)
                return
            } catch {
                if !FileManager.default.fileExists(atPath: folder.path) { return }
            }
        }
    }

    /// Removes conversion folders older than `age` seconds (longer than any conversion can run).
    public static func sweepLeftovers(root: URL = FileManager.default.temporaryDirectory, age: TimeInterval = 3600, now: Date = Date()) {
        let items = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for item in items where item.lastPathComponent.hasPrefix(officePrefix) || item.lastPathComponent.hasPrefix(webPrefix) {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age { remove(item) }
        }
    }
}

/// Turns an Office file into PDF bytes with a program of the user's: Microsoft's own app (`MicrosoftOfficeConverter`)
/// or LibreOffice (`LibreOfficeConverter`), as `OfficeInstalls.route` chooses. Tests give each a fake.
public protocol OfficeConverter: Sendable {
    /// The program's name, for messages.
    var appName: String { get }
    /// - Throws: `PdfEditError` (the message says why), `CancellationError`.
    func toPdf(_ path: String, timeout: TimeInterval, cancel: CancelToken) throws -> [UInt8]
}

/// The office apps found on this Mac, and how Microsoft's are driven.
public struct OfficeInstalls: Equatable, Sendable {
    /// LibreOffice's program, when installed.
    public var soffice: String?
    /// Microsoft's apps that are installed: each converts its own kind of file, before LibreOffice (Windows converts
    /// through Office only).
    public var microsoft: Set<OfficeApp>
    /// What runs the AppleScript that drives Microsoft's apps (`osascript`; tests give a fake).
    public var scriptRunner: any OfficeScriptRunner
    /// Where a copy of the file is put for Microsoft's apps, which are sandboxed (`MicrosoftOfficeConverter.stagingRoot`).
    public var staging: URL

    public init(soffice: String? = nil, microsoft: Set<OfficeApp> = [], scriptRunner: any OfficeScriptRunner = OsascriptRunner(),
                staging: URL = MicrosoftOfficeConverter.stagingRoot()) {
        self.soffice = soffice
        self.microsoft = microsoft
        self.scriptRunner = scriptRunner
        self.staging = staging
    }

    public static func == (a: OfficeInstalls, b: OfficeInstalls) -> Bool {
        a.soffice == b.soffice && a.microsoft == b.microsoft && a.staging == b.staging
    }

    /// Something can convert some kind of Office file.
    public var hasAny: Bool { soffice != nil || !microsoft.isEmpty }

    public static let libreOfficeBundleId = "org.libreoffice.script"
    public static let microsoftBundleIds: [(OfficeApp, String)] = [(.word, "com.microsoft.Word"), (.excel, "com.microsoft.Excel"), (.powerPoint, "com.microsoft.Powerpoint")]

    /// Where LibreOffice's installer puts it. Never through PATH: an app started from the Dock has none worth trusting.
    public static func libreOfficeBundles(home: String = NSHomeDirectory()) -> [String] {
        ["/Applications/LibreOffice.app", (home as NSString).appendingPathComponent("Applications/LibreOffice.app")]
    }

    /// The program inside the first of `bundles` that has one.
    public static func soffice(in bundles: [String], isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String? {
        bundles.map { ($0 as NSString).appendingPathComponent("Contents/MacOS/soffice") }.first(where: isExecutable)
    }

    /// What converts `path`: Microsoft's app for its kind when installed, else LibreOffice; nil when nothing can
    /// (`missing` says what to do).
    public func route(_ path: String) -> (any OfficeConverter)? {
        if let app = OfficeFiles.appFor(path), microsoft.contains(app) {
            return MicrosoftOfficeConverter(app: app, runner: scriptRunner, stagingRoot: staging)
        }
        return soffice.map { LibreOfficeConverter(soffice: $0) }
    }

    /// The honest message when no converter can take a file of this kind (nil: any kind).
    public func missing(_ app: OfficeApp?) -> String {
        if let app {
            return loc("Inkvolt PDF makes PDFs from Office files with {0} or LibreOffice, and neither is installed on this Mac. LibreOffice is free, from libreoffice.org.", OfficeFiles.appName(app))
        }
        return loc("Inkvolt PDF makes PDFs from Office files with Microsoft Word, Excel or PowerPoint, or with LibreOffice, and none of them is installed on this Mac. LibreOffice is free, from libreoffice.org.")
    }
}

/// Opening an Office file as a PDF, before and around the converter (the Windows `OfficeConverter`'s Precheck and ConvertAsync).
public enum OfficeConversion {
    /// How long a conversion may take before the converter is stopped.
    public static let timeout: TimeInterval = 180

    /// What stops `path` from being converted before anything is started, or nil.
    public static func precheck(_ path: String, _ installs: OfficeInstalls) -> String? {
        let app = OfficeFiles.appFor(path)
        guard installs.route(path) != nil else { return installs.missing(app) }
        guard let file = FileHandle(forReadingAtPath: path) else { return loc("That file couldn't be read.") }
        defer { try? file.close() }
        let head = (try? file.read(upToCount: 8)).flatMap { $0 }.map { [UInt8]($0) } ?? []
        if OfficeFiles.isEncryptedOpenXml(head, path) {
            return loc("This file is protected with a password. Open it in the app that made it, then save it as PDF there (or save a copy without the password).")
        }
        return nil
    }

    /// Converts `path` to PDF bytes. Cancelling (or the timeout) ends the converter.
    /// - Parameter fromInternetConfirmed: the user agreed to convert a file marked as from the internet.
    /// - Throws: `PdfEditError` (the message says why), `CancellationError`.
    public static func convert(_ path: String, installs: OfficeInstalls, fromInternetConfirmed: Bool, timeout: TimeInterval = OfficeConversion.timeout, cancel: CancelToken) throws -> [UInt8] {
        if let problem = precheck(path, installs) { throw PdfEditError(problem) }
        if OfficeFiles.isFromInternet(path) && !fromInternetConfirmed {
            throw PdfEditError(loc("This file came from the internet: confirm before it is opened in the converter."))
        }
        guard let converter = installs.route(path) else { throw PdfEditError(installs.missing(OfficeFiles.appFor(path))) }
        return try converter.toPdf(path, timeout: timeout, cancel: cancel)
    }

    /// " (first line of the converter's error output)", short; empty when there is none.
    public static func reason(_ stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard var first = lines.first(where: { !$0.isEmpty }) else { return "" }
        if first.count > 160 { first = String(first.prefix(160)) + "…" }
        return " (\(first))"
    }
}

/// LibreOffice's `soffice --headless --convert-to pdf`, as a program of its own: a crafted file can hurt only that, and a
/// stuck one can't freeze the app. It gets its arguments as a list (no shell), an empty environment but for the basics, a
/// new profile in a temp folder (so it runs apart from a LibreOffice the user has open, and the user's settings don't
/// apply: macros, link updates and the update check are off in it), and TMPDIR inside that folder, so the temp files it
/// makes of the document go with the folder on every path. The original opens read-only and stays where it is, uncopied.
public struct LibreOfficeConverter: OfficeConverter {
    public let appName = "LibreOffice"
    public let soffice: String
    let tempRoot: URL

    public init(soffice: String, tempRoot: URL = FileManager.default.temporaryDirectory) {
        self.soffice = soffice
        self.tempRoot = tempRoot
    }

    /// The profile's settings. LibreOffice's `--convert-to` takes macros and links from its configuration, not from the
    /// command line (desktop/source/app/dispatchwatcher.cxx). "Never" is 2 for Writer's links but 1 for Calc's (their .xcs).
    static let profileSettings = #"""
    <?xml version="1.0" encoding="UTF-8"?>
    <oor:items xmlns:oor="http://openoffice.org/2001/registry" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="BlockUntrustedRefererLinks" oor:op="fuse"><value>true</value></prop></item>
    <item oor:path="/org.openoffice.Office.Writer/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>2</value></prop></item>
    <item oor:path="/org.openoffice.Office.Calc/Content/Update"><prop oor:name="Link" oor:op="fuse"><value>1</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="CrashReport" oor:op="fuse"><value>false</value></prop></item>
    <item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="CollectUsageInformation" oor:op="fuse"><value>false</value></prop></item>
    <item oor:path="/org.openoffice.Office.Jobs/Jobs/org.openoffice.Office.Jobs:Job['UpdateCheck']/Arguments"><prop oor:name="AutoCheckEnabled" oor:op="fuse"><value>false</value></prop></item>
    </oor:items>

    """#

    public func toPdf(_ path: String, timeout: TimeInterval, cancel: CancelToken) throws -> [UInt8] {
        try cancel.check()
        guard path.hasPrefix("/") else { throw PdfEditError(loc("That file couldn't be read.")) } // never taken for an option
        let fm = FileManager.default
        let work: URL
        do {
            work = try ConversionTemp.make(ConversionTemp.officePrefix, root: tempRoot)
        } catch {
            throw PdfEditError(loc("{0} couldn't be started: no temporary folder could be made.", appName))
        }
        defer { ConversionTemp.remove(work) }
        let profile = work.appendingPathComponent("profile", isDirectory: true)
        let out = work.appendingPathComponent("out", isDirectory: true)
        let temp = work.appendingPathComponent("tmp", isDirectory: true)
        let errors = work.appendingPathComponent("errors.txt")
        do {
            try fm.createDirectory(at: profile.appendingPathComponent("user"), withIntermediateDirectories: true)
            try fm.createDirectory(at: out, withIntermediateDirectories: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: true)
            try Data(Self.profileSettings.utf8).write(to: profile.appendingPathComponent("user/registrymodifications.xcu"))
            guard fm.createFile(atPath: errors.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            throw PdfEditError(loc("{0} couldn't be started: its temporary files couldn't be written.", appName))
        }
        var profileUrl = profile.absoluteString
        if profileUrl.hasSuffix("/") { profileUrl.removeLast() }
        let arguments = ["-env:UserInstallation=\(profileUrl)", "--headless", "--invisible", "--norestore", "--nologo", "--nodefault", "--nolockcheck",
                         "--convert-to", "pdf", "--outdir", out.path, path]
        var environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temp.path + "/"]
        environment["LANG"] = ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        environment["USER"] = NSUserName()

        let outcome = try ConverterProcess.run(soffice, arguments, environment: environment, errors: errors, timeout: timeout, cancel: cancel, appName: appName)
        let stderr = ((try? FileHandle(forReadingFrom: errors))?.readData(ofLength: 16384)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let reason = OfficeConversion.reason(stderr)
        switch outcome {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            let limit = timeout >= 60 ? loc("{0} minutes", CoreLanguage.number(Int(timeout / 60))) : loc("{0} seconds", CoreLanguage.number(Int(timeout)))
            throw PdfEditError(loc("{0} didn't finish within {1} (the file may be damaged). It was closed.", appName, limit) + reason)
        case .exited(let code):
            guard code == 0, let pdf = try ConvertedPdf.read(in: out, appName: appName) else {
                throw PdfEditError(loc("{0} couldn't save this file as PDF. A file protected with a password can't be converted here.", appName) + reason)
            }
            return pdf
        }
    }
}

/// The PDF a converter left in its output folder.
enum ConvertedPdf {
    /// The largest PDF read back: a converter's output is bounded before it is loaded.
    static let maxBytes = 1 << 30

    /// The PDF in `folder`, however the program named it: a regular file (no link) that starts as a PDF does; nil when
    /// there is none (or more than one).
    /// - Throws: `PdfEditError` when it is larger than `maxBytes`.
    static func read(in folder: URL, appName: String, maxBytes: Int = maxBytes) throws -> [UInt8]? {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0.lowercased().hasSuffix(".pdf") }
        guard names.count == 1 else { return nil }
        let file = folder.appendingPathComponent(names[0])
        guard let attributes = try? fm.attributesOfItem(atPath: file.path), attributes[.type] as? FileAttributeType == .typeRegular else { return nil }
        if let size = (attributes[.size] as? NSNumber)?.int64Value, size > Int64(maxBytes) {
            throw PdfEditError(loc("{0} made a PDF of more than {1} MB, too big to open here.", appName, CoreLanguage.number(maxBytes >> 20)))
        }
        guard let data = try? Data(contentsOf: file), data.count <= maxBytes, data.starts(with: Array("%PDF-".utf8)) else { return nil }
        return [UInt8](data)
    }
}

/// Runs a converter program in a process group of its own, with nothing to read from and no pipes to it (a child it left
/// behind can't block anything); at the time limit or on Cancel it and its children get SIGTERM, then SIGKILL.
enum ConverterProcess {
    enum Outcome: Equatable {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    /// How long a program gets to end after SIGTERM, and to be gone after SIGKILL.
    private static let termGrace: TimeInterval = 2, killGrace: TimeInterval = 3

    /// - Parameter output: where the program's standard output goes (nowhere when nil).
    static func run(_ program: String, _ arguments: [String], environment: [String: String], errors: URL, output: URL? = nil, timeout: TimeInterval, cancel: CancelToken, appName: String) throws -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = errors.deletingLastPathComponent()
        process.standardInput = FileHandle.nullDevice
        let outputHandle = output.flatMap { try? FileHandle(forWritingTo: $0) }
        process.standardOutput = outputHandle ?? FileHandle.nullDevice
        let errorHandle = try? FileHandle(forWritingTo: errors)
        process.standardError = errorHandle ?? FileHandle.nullDevice
        defer {
            try? errorHandle?.close()
            try? outputHandle?.close()
        }
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            throw PdfEditError(loc("{0} couldn't be started.", appName))
        }
        let pid = process.processIdentifier
        // Foundation starts a program as the leader of a new group; only then is the group ours to signal.
        let group = getpgid(pid) == pid ? -pid : pid
        let deadline = Date().addingTimeInterval(timeout)
        var outcome: Outcome?
        while outcome == nil {
            if exited.wait(timeout: .now() + 0.1) == .success {
                outcome = .exited(process.terminationStatus)
            } else if cancel.isCancelled {
                outcome = .cancelled
            } else if Date() >= deadline {
                outcome = .timedOut
            }
        }
        if case .exited = outcome {
            if group < 0 { kill(group, SIGKILL) } // what it left behind
        } else {
            kill(group, SIGTERM)
            let ended = exited.wait(timeout: .now() + termGrace) == .success
            kill(group, SIGKILL)
            if !ended { _ = exited.wait(timeout: .now() + killGrace) }
        }
        return outcome ?? .cancelled
    }
}
