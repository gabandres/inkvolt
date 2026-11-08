import Foundation
import PrintCore

/// How a script run by `OfficeScriptRunner` ended, with what it printed (each read back to a bounded length).
public struct ScriptRun: Equatable, Sendable {
    public enum Ending: Equatable, Sendable {
        case exited(Int32)
        case timedOut
        case cancelled
    }

    public var ending: Ending
    public var output: String
    public var errors: String

    public init(_ ending: Ending, output: String = "", errors: String = "") {
        self.ending = ending
        self.output = output
        self.errors = errors
    }
}

/// Runs an AppleScript: the seam between `MicrosoftOfficeConverter` and macOS (`OsascriptRunner`), so tests run no Office.
public protocol OfficeScriptRunner: Sendable {
    /// Runs `script` (AppleScript source) with `arguments` as its run handler's list; ended at `timeout` or on Cancel.
    /// - Throws: `PdfEditError` when it couldn't be started.
    func run(_ script: String, arguments: [String], timeout: TimeInterval, cancel: CancelToken, appName: String) throws -> ScriptRun
}

/// `/usr/bin/osascript` as a program of its own (`ConverterProcess`: its own process group, ended at the time limit or on
/// Cancel), the script in a file of a temp folder of its own and the paths given as arguments, never written into the
/// script's source. macOS asks the person once whether Inkvolt PDF may control the app (the Apple Events entitlement and
/// `NSAppleEventsUsageDescription`); osascript's events count as Inkvolt PDF's, which started it.
public struct OsascriptRunner: OfficeScriptRunner {
    public static let osascript = "/usr/bin/osascript"
    /// How much of what the script printed is read back.
    static let maxText = 16384
    let tempRoot: URL

    public init(tempRoot: URL = FileManager.default.temporaryDirectory) { self.tempRoot = tempRoot }

    public func run(_ script: String, arguments: [String], timeout: TimeInterval, cancel: CancelToken, appName: String) throws -> ScriptRun {
        let fm = FileManager.default
        let work: URL
        do {
            work = try ConversionTemp.make(ConversionTemp.officePrefix, root: tempRoot)
        } catch {
            throw PdfEditError(loc("{0} couldn't be started: no temporary folder could be made.", appName))
        }
        defer { ConversionTemp.remove(work) }
        let file = work.appendingPathComponent("convert.applescript")
        let errors = work.appendingPathComponent("errors.txt"), output = work.appendingPathComponent("output.txt")
        do {
            try Data(script.utf8).write(to: file)
            guard fm.createFile(atPath: errors.path, contents: nil), fm.createFile(atPath: output.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            throw PdfEditError(loc("{0} couldn't be started: its temporary files couldn't be written.", appName))
        }
        var environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "USER": NSUserName()]
        environment["LANG"] = ProcessInfo.processInfo.environment["LANG"] ?? "en_US.UTF-8"
        let outcome = try ConverterProcess.run(Self.osascript, [file.path] + arguments, environment: environment, errors: errors, output: output,
                                               timeout: timeout, cancel: cancel, appName: appName)
        let ending: ScriptRun.Ending = switch outcome {
        case .exited(let code): .exited(code)
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
        return ScriptRun(ending, output: Self.read(output), errors: Self.read(errors))
    }

    private static func read(_ url: URL) -> String {
        ((try? FileHandle(forReadingFrom: url))?.readData(ofLength: maxText)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

/// An Office file made into a PDF by Microsoft Word, Excel or PowerPoint for Mac, through AppleScript (the Windows
/// `OfficeConverter` drives Office through COM). Office for Mac is sandboxed, so a copy of the file goes in Office's group
/// container (`stagingRoot`), in a folder of its own that is removed after (and at the next launch if a crash left it):
/// the original is never opened or changed. The copy's name is unique (`stagedName`), so the script finds and closes that
/// document only, never one the person has open; the app quits after only if it wasn't running before and has no
/// document left. One conversion at a time: two scripts in one app could quit it under each other.
public struct MicrosoftOfficeConverter: OfficeConverter {
    public let app: OfficeApp
    let runner: any OfficeScriptRunner
    let stagingRoot: URL

    public var appName: String { OfficeFiles.appName(app) }

    /// The largest file copied for Office: a copy is made of every file, so it is bounded.
    public static let maxInputBytes: Int64 = 512 << 20
    /// The group container Word, Excel and PowerPoint share (team UBF8T346G9), which each can read and write.
    public static let officeGroup = "UBF8T346G9.Office"
    /// The folder inside it that holds the copies.
    public static let stagingFolder = "Inkvolt PDF"

    public init(app: OfficeApp, runner: any OfficeScriptRunner = OsascriptRunner(), stagingRoot: URL = MicrosoftOfficeConverter.stagingRoot()) {
        self.app = app
        self.runner = runner
        self.stagingRoot = stagingRoot
    }

    /// `~/Library/Group Containers/UBF8T346G9.Office/Inkvolt PDF`.
    public static func stagingRoot(home: String = NSHomeDirectory()) -> URL {
        URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Group Containers", isDirectory: true)
            .appendingPathComponent(officeGroup, isDirectory: true).appendingPathComponent(stagingFolder, isDirectory: true)
    }

    public static func bundleId(_ app: OfficeApp) -> String {
        OfficeInstalls.microsoftBundleIds.first { $0.0 == app }?.1 ?? ""
    }

    private static let oneAtATime = NSLock()

    public func toPdf(_ path: String, timeout: TimeInterval, cancel: CancelToken) throws -> [UInt8] {
        try cancel.check()
        let fm = FileManager.default
        guard path.hasPrefix("/"), let attributes = try? fm.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { throw PdfEditError(loc("That file couldn't be read.")) }
        if let size = (attributes[.size] as? NSNumber)?.int64Value, size > Self.maxInputBytes {
            throw PdfEditError(loc("This file is too big to convert here (more than {0} MB).", CoreLanguage.number(Int(Self.maxInputBytes >> 20))))
        }
        // Office makes its group container the first time it runs; without it, the app hasn't been set up on this Mac.
        guard fm.fileExists(atPath: stagingRoot.deletingLastPathComponent().path) else {
            throw PdfEditError(loc("{0} hasn't been set up on this Mac yet. Open it once and sign in, then try again.", appName))
        }
        while !Self.oneAtATime.lock(before: Date().addingTimeInterval(0.2)) { try cancel.check() }
        defer { Self.oneAtATime.unlock() }

        let folder: URL, staged: URL, pdf: URL
        do {
            try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        } catch where fm.fileExists(atPath: stagingRoot.path) {
        } catch {
            throw PdfEditError(stagingDenied)
        }
        ConversionTemp.sweepLeftovers(root: stagingRoot) // what a crash left here
        do {
            folder = try ConversionTemp.make(ConversionTemp.officePrefix, root: stagingRoot)
        } catch {
            throw PdfEditError(stagingDenied)
        }
        defer { ConversionTemp.remove(folder) }
        let name = Self.stagedName((path as NSString).lastPathComponent, tag: String(folder.lastPathComponent.suffix(8)))
        staged = folder.appendingPathComponent(name)
        pdf = folder.appendingPathComponent(((name as NSString).deletingPathExtension) + ".pdf")
        do {
            try fm.copyItem(at: URL(fileURLWithPath: path), to: staged)
        } catch {
            throw PdfEditError(stagingDenied)
        }
        // The script's own limit ends a stuck event first, so it can still close what it opened; the process limit after.
        let scriptSeconds = max(5, Int(timeout.isFinite ? min(timeout, 3600) : 3600) - 10) // bounded: clamped, finite
        let run = try runner.run(MicrosoftOfficeScripts.script(app), arguments: [staged.path, pdf.path, name, String(scriptSeconds)],
                                 timeout: timeout, cancel: cancel, appName: appName)
        switch run.ending {
        case .cancelled:
            throw CancellationError()
        case .timedOut:
            throw PdfEditError(Self.timedOut(appName, timeout))
        case .exited(let code):
            if code != 0 { throw PdfEditError(Self.failure(run.errors, appName: appName, timeout: timeout)) }
            guard let bytes = try ConvertedPdf.read(in: folder, appName: appName) else { throw PdfEditError(Self.notSaved(appName)) }
            return bytes
        }
    }

    private var stagingDenied: String {
        loc("Inkvolt PDF couldn't put a copy of the file where {0} can read it. If macOS asked whether Inkvolt PDF may use other apps' data, allow it, then try again.", appName)
    }

    /// The copy's name: the original's, shortened, with `tag` (unique to the conversion) so that no document the person has
    /// open in the app has it, and without the characters a Mac path (HFS's ":") or the app could take apart.
    public static func stagedName(_ original: String, tag: String) -> String {
        // ".docx" alone is a name with no stem (NSString reads it as a hidden file with no extension).
        let dotOnly = original.hasPrefix(".") && !original.dropFirst().contains(".")
        let ext = dotOnly ? String(original.dropFirst()).lowercased() : (original as NSString).pathExtension.lowercased()
        var stem = dotOnly ? "" : (original as NSString).deletingPathExtension
        while stem.hasPrefix(".") { stem.removeFirst() } // never a hidden file
        stem = String(stem.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || " -_.,()".unicodeScalars.contains($0) ? Character($0) : "-" })
        stem = String(stem.trimmingCharacters(in: .whitespaces).prefix(60))
        if stem.isEmpty { stem = "Document" }
        let safeExt = ext.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) }) && ext.count <= 5 ? ext : ""
        return "\(stem) (Inkvolt \(tag))" + (safeExt.isEmpty ? "" : ".\(safeExt)")
    }

    // MARK: What a failed run means

    /// The AppleScript error numbers that have a message of their own.
    enum Code {
        static let notPermitted = -1743 // errAEEventNotPermitted: Automation denied
        static let consentNeeded = -1744 // errAEEventWouldRequireUserConsent
        static let timedOut = -1712 // errAETimeout
        static let notRunning: Set<Int> = [-600, -609] // procNotFound, connectionInvalid: the app quit
        static let notStarted: Set<Int> = [-10810, -10814, -10661, -2740, -2741] // not launched; its dictionary unreadable
    }

    /// The message for a script that ended with an error: osascript's last line ("…: execution error: inkvolt:save: … (-50)").
    public static func failure(_ errors: String, appName: String, timeout: TimeInterval) -> String {
        let line = errors.split(whereSeparator: \.isNewline).last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }).map(String.init) ?? ""
        let code = errorCode(line)
        let stage = line.range(of: "inkvolt:").map { String(line[$0.upperBound...].prefix { $0 != ":" }) } ?? ""
        if code == Code.notPermitted || code == Code.consentNeeded {
            return loc("macOS didn't let Inkvolt PDF use {0}. Turn on {0} under Inkvolt PDF in System Settings › Privacy & Security › Automation, then try again.", appName)
        }
        if code == Code.timedOut { return timedOut(appName, timeout) }
        if let code, Code.notRunning.contains(code) { return loc("{0} closed before it finished. Try again.", appName) }
        if let code, Code.notStarted.contains(code), stage != "save" { return loc("{0} couldn't be started.", appName) }
        if line.lowercased().contains("password") {
            return loc("{0} couldn't open this file without its password. Open it in {0} and save it as PDF there (or save a copy without the password).", appName)
        }
        if stage == "open" { return loc("{0} couldn't open this file. It may be damaged, or protected with a password.", appName) }
        return notSaved(appName)
    }

    /// The number at the end of osascript's error line, "(-1743)".
    static func errorCode(_ line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.range(of: "(", options: .backwards) else { return nil }
        let digits = trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)]
        return digits.count <= 8 ? Int(digits) : nil
    }

    static func notSaved(_ appName: String) -> String {
        loc("{0} opened the file but didn't save it as PDF. {0} saves only when it is activated: open {0}, sign in with a Microsoft account that includes Office, then try again.", appName)
    }

    static func timedOut(_ appName: String, _ timeout: TimeInterval) -> String {
        let seconds = timeout.isFinite ? Int(min(max(timeout, 0), 86400)) : 0 // bounded: clamped, finite
        let limit = seconds >= 60 ? loc("{0} minutes", CoreLanguage.number(seconds / 60)) : loc("{0} seconds", CoreLanguage.number(seconds))
        return loc("{0} didn't finish within {1}. It may be waiting in its window: to sign in, for a password, or with a question. Look at {0}, then try again.", appName, limit)
    }
}

/// The AppleScript each app runs. Its arguments: the copy, the PDF to save, the copy's name and the seconds it may take.
/// Nothing from the file or its name is written into the source. It opens the copy, waits until the app has it, saves it
/// as PDF, closes it without saving, and quits the app only if it started it and nothing else is open there. An error
/// comes back as "inkvolt:<stage>: <message>" with the app's number. No `activate`, no shell, no other document touched.
public enum MicrosoftOfficeScripts {
    /// The app-specific words: how its documents are called, and its "save as PDF" command for `doc` to `pdfPath`.
    static func terms(_ app: OfficeApp) -> (element: String, save: String) {
        switch app {
        case .word: ("document", "save as document docName file name (pdfPath as text) file format format PDF")
        case .excel: ("workbook", "save workbook as workbook docName filename (pdfPath as text) file format PDF file format")
        case .powerPoint: ("presentation", "save presentation docName in (pdfPath as text) as save as PDF")
        }
    }

    public static func script(_ app: OfficeApp) -> String {
        let (element, save) = terms(app)
        let id = MicrosoftOfficeConverter.bundleId(app)
        return """
        -- Inkvolt PDF: \(OfficeFiles.appName(app)) makes a PDF of a copy of a file (mac/docs/PLAN.md, E12).
        on run argv
        \tset inputFile to POSIX file (item 1 of argv)
        \tset pdfPath to POSIX file (item 2 of argv)
        \tset docName to item 3 of argv
        \tset limit to (item 4 of argv) as integer
        \tset wasRunning to application id "\(id)" is running
        \tset failure to ""
        \tset failureCode to 0
        \twith timeout of limit seconds
        \t\ttell application id "\(id)"
        \t\t\ttry
        \t\t\t\topen inputFile
        \t\t\ton error message number code
        \t\t\t\tset failure to "open: " & message
        \t\t\t\tset failureCode to code
        \t\t\tend try
        \t\t\tif failureCode is 0 then
        \t\t\t\tset found to false
        \t\t\t\trepeat 120 times
        \t\t\t\t\tif exists \(element) docName then
        \t\t\t\t\t\tset found to true
        \t\t\t\t\t\texit repeat
        \t\t\t\t\tend if
        \t\t\t\t\tdelay 0.25
        \t\t\t\tend repeat
        \t\t\t\tif not found then
        \t\t\t\t\tset failure to "open: the file didn't open"
        \t\t\t\t\tset failureCode to 1
        \t\t\t\tend if
        \t\t\tend if
        \t\t\tif failureCode is 0 then
        \t\t\t\ttry
        \t\t\t\t\t\(save)
        \t\t\t\ton error message number code
        \t\t\t\t\tset failure to "save: " & message
        \t\t\t\t\tset failureCode to code
        \t\t\t\tend try
        \t\t\tend if
        \t\t\tif failureCode is not -1712 and failureCode is not -1743 and failureCode is not -1744 then
        \t\t\t\ttry
        \t\t\t\t\tif exists \(element) docName then close \(element) docName saving no
        \t\t\t\tend try
        \t\t\t\tif not wasRunning then
        \t\t\t\t\ttry
        \t\t\t\t\t\tif (count of \(element)s) is 0 then quit
        \t\t\t\t\tend try
        \t\t\t\tend if
        \t\t\tend if
        \t\tend tell
        \tend timeout
        \tif failureCode is not 0 then error "inkvolt:" & failure number failureCode
        \treturn "ok"
        end run

        """
    }
}
