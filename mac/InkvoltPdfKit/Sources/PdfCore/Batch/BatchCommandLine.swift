import Foundation

public enum CommandKind: Sendable { case help, batch, watch, fill }

/// A parsed command line (see `BatchCommandLine.usage`). `preset`: the preset file; `inputs`: --batch's files and
/// folders, --fill's form and CSV; `folder`: --watch's folder; `name`: --fill's file name pattern.
public struct CommandLineRequest: Equatable, Sendable {
    public var kind: CommandKind
    public var preset: String?
    public var inputs: [String]?
    public var folder: String?
    public var output: String?
    public var recursive = false
    public var once = false
    public var quiet = false
    public var name: String?
    public var flatten = false

    public init(_ kind: CommandKind, preset: String? = nil, inputs: [String]? = nil, folder: String? = nil, output: String? = nil,
                recursive: Bool = false, once: Bool = false, quiet: Bool = false, name: String? = nil, flatten: Bool = false) {
        self.kind = kind
        self.preset = preset
        self.inputs = inputs
        self.folder = folder
        self.output = output
        self.recursive = recursive
        self.once = once
        self.quiet = quiet
        self.name = name
        self.flatten = flatten
    }
}

/// The command line is wrong; the message says how.
public struct CommandLineError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Lines a command writes (standard output and error; tests collect them).
public protocol LineWriter: AnyObject, Sendable {
    func writeLine(_ text: String)
}

/// Lines kept in memory.
public final class MemoryLines: LineWriter, @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    public init() {}

    public func writeLine(_ text: String) {
        lock.lock()
        lines.append(text)
        lock.unlock()
    }

    public var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.map { $0 + "\n" }.joined()
    }
}

/// `inkvoltpdf --batch` and `--watch` (the Windows app's `BatchCommandLine`): a preset run without a window, from a
/// terminal, a script or launchd. Lines go to `output` (one per file) and problems to `error`; the exit code says how
/// it went (`done`, `someFailed`, `wrong`, `stopped`). Nothing is asked: files that need a password to open are skipped,
/// and Protect's passwords come from `openPasswordVariable` and `permissionsPasswordVariable` (presets never keep them).
/// The app's entry point passes the recognizer (OCR); everything else is here, so tests run it in-process. `--fill`
/// is the form merge (`FormMerge`, roadmap 1.4), free like the app's Fill Forms from CSV.
public enum BatchCommandLine {
    /// Exit codes: every file done; a file failed or was skipped; the command line, preset or folder is wrong (nothing
    /// was done); stopped (Ctrl+C) before the end.
    public static let done = 0, someFailed = 1, wrong = 2, stopped = 3

    public static let openPasswordVariable = "INKVOLTPDF_OPEN_PASSWORD"
    public static let permissionsPasswordVariable = "INKVOLTPDF_PERMISSIONS_PASSWORD"

    /// The app's binary, as a terminal reaches it.
    public static let command = "\"/Applications/Inkvolt PDF.app/Contents/MacOS/InkvoltPdf\""

    public static let usage = """
        Inkvolt PDF command line: run a saved Batch preset without a window.

          inkvoltpdf --batch <preset.json> <files or folders>... [--out <folder>] [--recursive] [--quiet]
              Runs the preset on PDFs and images (a folder: the PDFs and images in it), a line per file.
              --out <folder>   where the results go (default: the preset's folder)
              --recursive      the folders' subfolders too

          inkvoltpdf --watch <folder> --preset <preset.json> [--out <folder>] [--once] [--quiet]
              Runs the preset on each PDF or image that lands in the folder, once it has stopped growing.
              Originals move to "done" or "failed" below the folder; inkvolt-watch.log there has a line per file.
              Ctrl+C stops (the files being worked on finish their current action first).
              --out <folder>   where the results go (default: the preset's folder, else <folder>/results)
              --once           handle the files there now, then stop (for a launchd job)

          inkvoltpdf --fill <form.pdf> <data.csv> [--out <folder>] [--name <pattern>] [--flatten] [--quiet]
              Fills one copy of the form for each row of the CSV (its header names the fields), a line per row.
              A row with a value the form refuses is not saved; a report CSV lists why.
              --out <folder>   where the forms go (default: "<form> forms" beside the CSV)
              --name <pattern> file names: <<name>> the form's name, <<n>> or <<n:3>> the row, <<date>>, and any
                               column as <<Column>> (default: "<<name>> <<n:3>>")
              --flatten        the values become part of the pages

          inkvoltpdf --help

        inkvoltpdf is \(command).
        Make presets in Inkvolt PDF: File > Batch > Save Preset (or Export). They are plain JSON.
        Protect with a password takes its passwords from the environment variables INKVOLTPDF_OPEN_PASSWORD and
        INKVOLTPDF_PERMISSIONS_PASSWORD. Files that need a password to open are skipped.

        Exit codes: 0 every file done; 1 a file failed or was skipped; 2 wrong command line, preset or folder
        (nothing done); 3 stopped before the end.
        """

    /// The arguments ask for the command line (rather than opening files in the app).
    public static func isCommand(_ args: [String]) -> Bool {
        guard let first = args.first?.lowercased() else { return false }
        return ["--batch", "--watch", "--fill", "--help", "-h", "-?"].contains(first)
    }

    /// - Throws: `CommandLineError` when the arguments are wrong.
    public static func parse(_ args: [String]) throws -> CommandLineRequest {
        guard let first = args.first else { throw CommandLineError("Say what to do: --batch, --watch, --fill or --help.") }
        let kind: CommandKind
        switch first.lowercased() {
        case "--batch": kind = .batch
        case "--watch": kind = .watch
        case "--fill": kind = .fill
        case "--help", "-h", "-?": kind = .help
        default: throw CommandLineError("\"\(first)\" isn't a command: use --batch, --watch, --fill or --help.")
        }
        if kind == .help { return CommandLineRequest(kind) }

        var firstValue: String?, preset: String?, output: String?, name: String?
        var recursive = false, once = false, quiet = false, flatten = false
        var inputs: [String] = []
        var i = 1
        func value(_ name: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw CommandLineError("\(name) needs a value after it.") }
            i += 1
            return args[i]
        }
        while i < args.count {
            let a = args[i]
            switch a.lowercased() {
            case "--out": output = try value("--out")
            case "--preset": preset = try value("--preset")
            case "--recursive": recursive = true
            case "--once": once = true
            case "--quiet": quiet = true
            case "--name" where kind == .fill: name = try value("--name")
            case "--flatten" where kind == .fill: flatten = true
            default:
                if a.hasPrefix("--") { throw CommandLineError("\"\(a)\" isn't an option Inkvolt PDF knows (--help lists them).") }
                if firstValue == nil { firstValue = a } else { inputs.append(a) }
            }
            i += 1
        }
        if kind == .fill {
            guard let firstValue, inputs.count == 1 else { throw CommandLineError("--fill needs the form (a PDF), then the CSV of values.") }
            if preset != nil || recursive || once { throw CommandLineError("--fill takes --out, --name, --flatten and --quiet.") }
            return CommandLineRequest(kind, inputs: [firstValue, inputs[0]], output: output, quiet: quiet, name: name, flatten: flatten)
        }
        if kind == .batch {
            guard let firstValue else { throw CommandLineError("--batch needs a preset file, then the files or folders to run it on.") }
            if preset != nil { throw CommandLineError("--batch takes the preset right after it, not with --preset.") }
            if once { throw CommandLineError("--once goes with --watch.") }
            if inputs.isEmpty { throw CommandLineError("--batch needs the files or folders to run the preset on, after the preset.") }
            return CommandLineRequest(kind, preset: firstValue, inputs: inputs, output: output, recursive: recursive, quiet: quiet)
        }
        guard let firstValue else { throw CommandLineError("--watch needs the folder to watch.") }
        if !inputs.isEmpty { throw CommandLineError("--watch takes one folder (\"\(inputs[0])\" is one too many).") }
        guard let preset else { throw CommandLineError("--watch needs a preset: --preset <preset.json>.") }
        if recursive { throw CommandLineError("--recursive goes with --batch (a watched folder takes the files at its top).") }
        return CommandLineRequest(kind, preset: preset, folder: firstValue, output: output, once: once, quiet: quiet)
    }

    /// Runs the command line; returns the exit code. `host`: the recognizer (OCR) when there is one; its password prompt
    /// is never used. `environment`: reads an environment variable (tests give their own).
    public static func run(_ args: [String], output stdout: LineWriter, error stderr: LineWriter, host: BatchHost, cancel: CancelToken? = nil,
                           environment: (@Sendable (String) -> String?)? = nil) async -> Int {
        let environment = environment ?? { ProcessInfo.processInfo.environment[$0] }
        let request: CommandLineRequest
        do {
            request = try parse(args)
        } catch let e as CommandLineError {
            stderr.writeLine(e.message)
            stderr.writeLine("inkvoltpdf --help shows how to use it.")
            return wrong
        } catch {
            return wrong
        }
        if request.kind == .help {
            stdout.writeLine(usage)
            return done
        }
        if request.kind == .fill { return fill(request, stdout, stderr, environment(openPasswordVariable), cancel) } // free (roadmap 1.4)
        if !Pro.allows(.commandLine) {
            stderr.writeLine(Pro.locked(.commandLine) + " " + Pro.howToGet)
            return wrong
        }

        var preset: BatchPreset
        do {
            preset = try BatchPresets.load((request.preset! as NSString).standardizingPath.hasPrefix("/") ? (request.preset! as NSString).standardizingPath : full(request.preset!))
        } catch let e as BatchPresetError {
            stderr.writeLine(e.message)
            return wrong
        } catch {
            stderr.writeLine("\(error)")
            return wrong
        }
        let steps = BatchPresets.withPasswords(preset.steps, open: environment(openPasswordVariable), permissions: environment(permissionsPasswordVariable))
        for case .protect(let p) in steps where p.needsPasswords {
            stderr.writeLine("The preset protects files with a password: set \(openPasswordVariable) and/or \(permissionsPasswordVariable) (presets never keep passwords).")
            return wrong
        }
        preset.steps = steps
        let quiet = BatchHost(recognize: host.recognize, recognizeLanguage: host.recognizeLanguage)
        return request.kind == .batch
            ? await batch(request, preset, quiet, stdout, stderr, cancel)
            : await watch(request, preset, quiet, stdout, stderr, cancel)
    }

    /// A path as given on the command line, made absolute from the current directory.
    static func full(_ path: String) -> String {
        let p = (path as NSString).expandingTildeInPath
        return (p.hasPrefix("/") ? p : (FileManager.default.currentDirectoryPath as NSString).appendingPathComponent(p) as String) as NSString as String
    }

    private static func batch(_ request: CommandLineRequest, _ preset: BatchPreset, _ host: BatchHost, _ stdout: LineWriter, _ stderr: LineWriter,
                              _ cancel: CancelToken?) async -> Int {
        guard let outFolderGiven = request.output ?? preset.outputFolder, !outFolderGiven.trimmingCharacters(in: .whitespaces).isEmpty else {
            stderr.writeLine("Say where the results go: --out <folder> (the preset has no folder of its own).")
            return wrong
        }
        let outFolder = (full(outFolderGiven) as NSString).standardizingPath
        var plan = preset.toPlan(outFolder)
        plan.passwords = .skip
        if let planError = plan.validate(ocrAvailable: host.recognize != nil) {
            stderr.writeLine("The preset can't run: \(planError)")
            return wrong
        }
        let inputs = (request.inputs ?? []).map { (full($0) as NSString).standardizingPath }
        if let missing = inputs.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            stderr.writeLine("There is no file or folder \(missing).")
            return wrong
        }
        let files = BatchFiles.expand(inputs, recursive: request.recursive, excludeFolder: outFolder)
        if files.isEmpty {
            stderr.writeLine("No PDFs or images to work on there.")
            return wrong
        }
        do {
            try FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
        } catch {
            stderr.writeLine("The results can't be saved in \(outFolder): \(error.localizedDescription)")
            return wrong
        }

        if !request.quiet {
            stdout.writeLine("\"\(preset.name)\" (\(plan.steps.map(\.title).joined(separator: ", "))) on \(count(files.count, "file")), results in \(outFolder)")
        }
        let finished = Counter()
        let total = files.count
        let quiet = request.quiet
        let progress: @Sendable (BatchProgress) -> Void = { p in
            guard let r = p.result else { return }
            let n = finished.next()
            let name = (r.file.path as NSString).lastPathComponent
            let notes = r.notes.isEmpty ? "" : " (\(r.notes.joined(separator: "; ")))"
            let text: String
            switch r.state {
            case .done: text = "done     \(name)\(r.outputs.isEmpty ? ": nothing to save" : " -> " + r.outputs.joined(separator: ", "))\(notes)"
            case .skipped: text = "skipped  \(name): \(r.message)\(notes)"
            case .failed: text = "failed   \(name): \(r.message)\(notes)"
            default: text = "stopped  \(name)"
            }
            if r.state == .done && quiet { return }
            (r.state == .failed || r.state == .skipped ? stderr : stdout).writeLine("[\(n)/\(total)] \(text)")
        }

        let summary: BatchSummary
        do {
            summary = try await BatchRunner.run(files, plan, host, progress: progress, cancel: cancel)
        } catch {
            stderr.writeLine("The preset can't run: \(error)")
            return wrong
        }
        stdout.writeLine(summary.text)
        if summary.cancelled > 0 || cancel?.isCancelled == true { return stopped }
        return summary.failed + summary.skipped > 0 ? someFailed : done
    }

    private static func watch(_ request: CommandLineRequest, _ preset: BatchPreset, _ host: BatchHost, _ stdout: LineWriter, _ stderr: LineWriter,
                              _ cancel: CancelToken?) async -> Int {
        let folder = (full(request.folder!) as NSString).standardizingPath
        let outFolder = (full(request.output ?? preset.outputFolder ?? WatchedFolder.defaultOutput(folder)) as NSString).standardizingPath
        if !Pro.allows(.watchedFolders) {
            stderr.writeLine(Pro.locked(.watchedFolders) + " " + Pro.howToGet)
            return wrong
        }
        if let folderError = WatchedFolder.validate(folder, outFolder) {
            stderr.writeLine(folderError)
            return wrong
        }
        if !request.quiet {
            stdout.writeLine("Watching \(folder) with \"\(preset.name)\", results in \(outFolder). \(request.once ? "Handling the files there now." : "Ctrl+C stops.")")
        }
        let quiet = request.quiet
        let progress: @Sendable (WatchProgress) -> Void = { p in
            guard let e = p.finished else { return }
            if e.state == .done && quiet { return }
            let f = DateFormatter()
            f.locale = HeaderFooter.invariant
            f.dateFormat = "HH:mm:ss"
            let state = e.state.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)
            let text = "\(f.string(from: e.time)) \(state) \(e.fileName): \(e.message)\(e.outputs.isEmpty ? "" : " -> " + e.outputs.joined(separator: ", "))"
            (e.state == .failed || e.state == .skipped ? stderr : stdout).writeLine(text)
        }
        do {
            let plan = preset.toPlan(outFolder)
            let summary = try await WatchedFolder.run(folder, plan, host, WatchOptions(once: request.once), progress: progress, cancel: cancel)
            stdout.writeLine("\(count(summary.done, "file")) done, \(summary.failed) failed.")
            return summary.failed > 0 ? someFailed : done
        } catch {
            stderr.writeLine("\(error)")
            return wrong
        }
    }

    private static func count(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int {
            lock.lock()
            defer { lock.unlock() }
            n += 1
            return n
        }
    }

    /// --fill: a form merge (`FormMerge`), a line per row; a report CSV beside the forms when a row failed.
    private static func fill(_ request: CommandLineRequest, _ stdout: LineWriter, _ stderr: LineWriter, _ password: String?, _ cancel: CancelToken?) -> Int {
        let form = full(request.inputs?[0] ?? ""), csv = full(request.inputs?[1] ?? "")
        if let missing = [form, csv].first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            stderr.writeLine("There is no file \(missing).")
            return wrong
        }
        let stem = ((form as NSString).lastPathComponent as NSString).deletingPathExtension
        let outFolder = full(request.output ?? ((csv as NSString).deletingLastPathComponent as NSString).appendingPathComponent(stem + " forms"))
        var options = FormMergeOptions(outputFolder: outFolder, nameTemplate: request.name ?? FormMergeOptions.defaultTemplate)
        options.flatten = request.flatten
        let report: FormMergeReport
        do {
            let formData = [UInt8](try Data(contentsOf: URL(fileURLWithPath: form)))
            let csvData = [UInt8](try Data(contentsOf: URL(fileURLWithPath: csv)))
            report = try FormMerge.run(formData, password, csvData, formPath: form, options, cancel: cancel)
        } catch {
            stderr.writeLine((error as? PdfEditError)?.message ?? error.localizedDescription)
            return wrong
        }
        for c in report.unknownColumns { stderr.writeLine("column   \"\(c)\" isn't a field of the form: left out") }
        for r in (report.made + report.failed).sorted(by: { $0.row < $1.row }) {
            if let file = r.file {
                if !request.quiet { stdout.writeLine("made     row \(r.row) -> \(file)") }
            } else {
                stderr.writeLine("failed   row \(r.row): \(r.problems.joined(separator: "; "))")
            }
        }
        if !report.failed.isEmpty {
            let path = (outFolder as NSString).appendingPathComponent(stem + " merge report.csv")
            do {
                try FileManager.default.createDirectory(atPath: outFolder, withIntermediateDirectories: true)
                try Data(report.csv()).write(to: URL(fileURLWithPath: path))
                stdout.writeLine("Report: \(path)")
            } catch {
                stderr.writeLine("The report can't be saved: \(error.localizedDescription)")
            }
        }
        stdout.writeLine(report.text)
        if report.stopped { return stopped }
        return report.failed.isEmpty ? done : someFailed
    }
}
