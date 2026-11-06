import Foundation

public enum BatchCommandKind: Sendable { case help, list, files, watch }

/// A parsed `print` (see `BatchPrintCommandLine.usage`).
public struct BatchCommandRequest: Sendable {
    public var kind: BatchCommandKind
    public var printer: String?
    public var list: String?
    public var inputs: [String] = []
    public var folder: String?
    public var settings = BatchPrintSettings()
    public var report: String?
    public var maxSheets = BatchPrintLimits.defaultMaxSheets
    public var allowNetwork = false
    public var recursive = false
    public var dryRun = false
    public var once = false
    public var quiet = false

    init(_ kind: BatchCommandKind) { self.kind = kind }
}

/// The command line is wrong, or a printer can't be used; the message says how.
public struct BatchCommandError: Error, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// This Mac's side of the command line: the files, and the printer a name stands for.
public protocol BatchPrintHost: Sendable {
    var documents: any BatchDocuments { get }

    /// The printer called `name`.
    /// - Throws: `BatchCommandError`: there's none, or it isn't one to print a batch to.
    func findPrinter(_ name: String) async throws -> any BatchQueue
}

/// `print` (roadmap 2.4, Pro; Windows' `inkvoltprint print`): a saved list, some files or a folder as it fills, without a window,
/// from Terminal, a script or a scheduled job. Lines go to `output` (one per file) and problems to `error`; the exit code says
/// how it went, the same as Inkvolt PDF's (`BatchPrintSummary.done`, `.someFailed`, `.wrong`, `.stopped`). Nothing is asked:
/// a file that needs a password is tried once with `passwordVariable` and otherwise skipped. Everything is estimated before
/// the first sheet, and a batch over `--max-sheets` isn't started. The app's entry point passes the Mac's side and the
/// terminal; the rest is here, so tests run it in-process.
public enum BatchPrintCommandLine {
    public static let verb = "print"
    public static let passwordVariable = "INKVOLTPRINT_OPEN_PASSWORD"
    /// How Terminal runs it: the app's own program.
    public static let program = "\"/Applications/Inkvolt Print.app/Contents/MacOS/Inkvolt Print\""

    public static let usage = """
        Inkvolt Print command line: print without a window. Run it as \(program) print …

          print --list <list file> --printer <name> [options]
              Prints a list saved in the Batch Print window (plain JSON), in its order.

          print <files or folders>... --printer <name> [--copies n] [--two-sided] [--paper name] [--pages range] [--recursive] [options]
              Prints PDFs and pictures (a folder: those at its top, in name order; --recursive: below too).

          print --watch <folder> --printer <name> [--copies n] [--two-sided] [--paper name] [--once] [options]
              Prints each PDF or picture that lands in the folder, once it has stopped changing and reads as whole.
              Originals move to "done" or "failed" below the folder; \(BatchPrintFolder.logName) there has a line per file.
              A file left in "working" by a run that never finished may have printed: it goes to "failed", never through again.
              Control-C stops. --once handles the files there now, then stops (for a scheduled job).

          print --help

        Options:
          --max-sheets <n>     the most sheets this run may use (default \(BatchPrintLimits.defaultMaxSheets)); over it, a list doesn't start
          --report <file.csv>  the results as a CSV, a row per file
          --dry-run            the estimate only, nothing is sent (not with --watch)
          --allow-network      a list may open files on other computers (it's refused otherwise)
          --quiet              only problems, and the last line

        --printer is a macOS print queue's name (lpstat -p lists them) or its name as System Settings shows it.
        --paper is the queue's paper name (lpoptions -p <queue> -l lists them), as the Batch Print window saves it.
        A file that needs a password gets the one in the environment variable \(passwordVariable), once, and is otherwise skipped.
        "Sent" means macOS's print queue has it. The App Store's sandbox lets the command read and write only the files and
        folders the Batch Print window was given (added, saved to or watched there), and the app's own container.

        Exit codes: 0 every file sent; 1 a file failed or was skipped; 2 wrong command line, list, printer or folder, or over
        --max-sheets (nothing sent); 3 stopped before the end (Control-C, or the printer has a problem).
        """

    /// The arguments ask for the command line (rather than opening the app).
    public static func isCommand(_ args: [String]) -> Bool { args.first?.lowercased() == verb }

    /// - Throws: `BatchCommandError`: the arguments are wrong.
    public static func parse(_ args: [String]) throws -> BatchCommandRequest {
        guard isCommand(args) else { throw BatchCommandError("Say what to do: print --list <file> --printer <name>.") }
        var printer: String?, list: String?, watch: String?, report: String?, paper: String?, range: String?
        var copies = 1, maxSheets = BatchPrintLimits.defaultMaxSheets
        var twoSided = false, network = false, recursive = false, dry = false, once = false, quiet = false, help = false, settingsGiven = false
        var inputs: [String] = []
        var i = 1
        func value(_ name: String) throws -> String {
            guard i + 1 < args.count, !args[i + 1].hasPrefix("--") else { throw BatchCommandError("\(name) needs a value after it.") }
            i += 1
            return args[i]
        }
        func number(_ name: String, _ low: Int, _ high: Int) throws -> Int {
            let text = try value(name)
            guard let n = Int(text), n >= low, n <= high else {
                throw BatchCommandError("\(name) must be a number from \(low) to \(CoreLanguage.number(high)) (\"\(BatchPrintText.clean(text))\" isn't).")
            }
            return n
        }
        while i < args.count {
            let a = args[i]
            switch a.lowercased() {
            case "--help", "-h", "-?": help = true
            case "--printer": printer = try value(a)
            case "--list": list = try value(a)
            case "--watch": watch = try value(a)
            case "--report": report = try value(a)
            case "--copies":
                copies = try number(a, 1, BatchPrintLimits.maxCopies)
                settingsGiven = true
            case "--paper":
                paper = try value(a)
                settingsGiven = true
            case "--pages":
                range = try value(a)
                settingsGiven = true
            case "--two-sided":
                twoSided = true
                settingsGiven = true
            case "--max-sheets": maxSheets = try number(a, 1, 1_000_000)
            case "--allow-network": network = true
            case "--recursive": recursive = true
            case "--dry-run": dry = true
            case "--once": once = true
            case "--quiet": quiet = true
            default:
                if a.hasPrefix("--") { throw BatchCommandError("\"\(BatchPrintText.clean(a))\" isn't an option print knows (--help lists them).") }
                inputs.append(a)
            }
            i += 1
        }
        if help { return BatchCommandRequest(.help) }
        if (list == nil ? 0 : 1) + (watch == nil ? 0 : 1) + (inputs.isEmpty ? 0 : 1) != 1 {
            throw BatchCommandError("Say what to print: --list <file>, --watch <folder>, or files and folders (only one of those).")
        }
        guard let printer, !printer.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw BatchCommandError("Say which printer: --printer <name>. Nothing is sent to a default printer.")
        }
        var request = BatchCommandRequest(.files)
        request.printer = printer
        request.report = report
        request.maxSheets = maxSheets
        request.quiet = quiet
        request.settings = BatchPrintSettings(copies: copies, range: range, twoSided: twoSided, paper: paper)
        if let list {
            if settingsGiven { throw BatchCommandError("A list says how each file prints: --copies, --two-sided, --paper and --pages go with files or --watch.") }
            if recursive || once { throw BatchCommandError("--recursive goes with folders given on the command line, and --once with --watch.") }
            request.kind = .list
            request.list = list
            request.settings = BatchPrintSettings()
            request.allowNetwork = network
            request.dryRun = dry
            return request
        }
        if let watch {
            if recursive || dry || network { throw BatchCommandError("--watch takes the files at the folder's top, as they come: no --recursive, --dry-run or --allow-network.") }
            if range != nil { throw BatchCommandError("--pages goes with files: a folder's files have different pages.") }
            request.kind = .watch
            request.folder = watch
            request.once = once
            return request
        }
        if once { throw BatchCommandError("--once goes with --watch.") }
        request.inputs = inputs
        request.allowNetwork = network
        request.recursive = recursive
        request.dryRun = dry
        return request
    }

    public typealias Write = @Sendable (String) -> Void

    /// Runs the command line; returns the exit code. `environment` reads an environment variable (tests give their own);
    /// `stop` is Control-C.
    public static func run(_ args: [String], _ host: any BatchPrintHost, environment: @Sendable (String) -> String? = { ProcessInfo.processInfo.environment[$0] },
                           options: BatchPrintOptions = BatchPrintOptions(), folderQuiet: Duration? = nil, folderPoll: Duration? = nil,
                           _ stop: BatchStop = BatchStop(), output out: @escaping Write, error err: @escaping Write) async -> Int32 {
        let request: BatchCommandRequest
        do {
            request = try parse(args)
        } catch {
            err((error as? BatchCommandError)?.message ?? "\(error)")
            err("print --help shows how to use it.")
            return BatchPrintSummary.wrong
        }
        if request.kind == .help {
            out(usage)
            return BatchPrintSummary.done
        }
        if !Pro.allows(.batchPrintAutomation) {
            err(Pro.locked(.batchPrintAutomation))
            err(Pro.howToGet)
            return BatchPrintSummary.wrong
        }
        if let report = request.report, let problem = checkReport(report) {
            err(problem)
            return BatchPrintSummary.wrong
        }
        if stop.isStopped { return BatchPrintSummary.stopped }

        let queue: any BatchQueue
        let info: BatchQueueInfo
        do {
            queue = try await host.findPrinter(request.printer ?? "")
            guard let read = try await queue.read() else {
                throw BatchCommandError("\"\(BatchPrintText.clean(request.printer ?? ""))\" has no macOS print queue to print through.")
            }
            info = read
        } catch let e as BatchCommandError {
            err(e.message)
            return BatchPrintSummary.wrong
        } catch is CancellationError {
            return BatchPrintSummary.stopped
        } catch let e {
            err("The printer can't be read: \(BatchPrintText.describe(e))")
            return BatchPrintSummary.wrong
        }

        let password = environment(passwordVariable)
        return request.kind == .watch
            ? await watch(request, queue, info, host.documents, password, out, err, options, folderQuiet, folderPoll, stop)
            : await batch(request, queue, info, host.documents, password, out, err, options, stop)
    }

    /// Why the report can't be written, said before any paper is used.
    private static func checkReport(_ report: String) -> String? {
        let full = BatchPrintList.absolute(report)
        if !full.lowercased().hasSuffix(".csv") { return "--report needs a .csv file." }
        let folder = (full as NSString).deletingLastPathComponent
        var isFolder: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) || !isFolder.boolValue {
            return "--report: there is no folder \(BatchPrintText.clean(folder))."
        }
        return nil
    }

    private static func batch(_ request: BatchCommandRequest, _ queue: any BatchQueue, _ info: BatchQueueInfo, _ documents: any BatchDocuments, _ password: String?,
                              _ out: @escaping Write, _ err: @escaping Write, _ options: BatchPrintOptions, _ stop: BatchStop) async -> Int32 {
        let entries: [BatchListEntry]
        do {
            if request.kind == .list {
                entries = try BatchPrintList.expand(try BatchPrintList.load(BatchPrintList.absolute(request.list ?? ""), allowNetwork: request.allowNetwork))
            } else {
                let checks = request.inputs.map(BatchPrintList.absolute)
                if let missing = checks.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
                    throw BatchListError("There is no file or folder \(BatchPrintText.clean(missing)).")
                }
                let (files, leftOut) = BatchPrintFiles.expand(checks, recursive: request.recursive)
                if leftOut > 0 {
                    let odd = checks.first { path in
                        var isFolder: ObjCBool = false
                        return !(FileManager.default.fileExists(atPath: path, isDirectory: &isFolder) && isFolder.boolValue) && !BatchPrintFiles.isSupported(path)
                    } ?? checks[0]
                    throw BatchListError("\(BatchPrintText.clean(odd)) is neither a PDF, a picture nor a folder. Nothing was sent.")
                }
                if files.count > BatchPrintLimits.maxFiles {
                    throw BatchListError("That's \(CoreLanguage.number(files.count)) files: a batch takes at most \(CoreLanguage.number(BatchPrintLimits.maxFiles)).")
                }
                entries = files.map { BatchListEntry($0, request.settings) }
            }
        } catch let e as BatchListError {
            err(e.message)
            if e.needsNetwork { err("--allow-network opens them.") }
            return BatchPrintSummary.wrong
        } catch let e {
            err(BatchPrintText.describe(e))
            return BatchPrintSummary.wrong
        }
        if entries.isEmpty {
            err("No PDFs or pictures to print there.")
            return BatchPrintSummary.wrong
        }

        // The estimate: every file is opened, every password tried, before the first sheet.
        var lines: [BatchPrintLine] = []
        do {
            for (n, entry) in entries.enumerated() {
                let measure = try await BatchMeasurer.measure(entry.path, offered: password, documents, ask: nil, options: options, stop)
                let line = BatchPrintLine(entry.path, entry.settings, measure, info)
                lines.append(line)
                let place = "[\(n + 1)/\(entries.count)]"
                if let problem = line.problem {
                    err("\(place) left out \(BatchPrintText.clean(line.name)): \(problem)")
                } else if !request.quiet {
                    out("\(place) estimate \(BatchPrintText.clean(line.name)): \(BatchPrintText.count(line.pages.count, .page)), \(BatchPrintText.sheets(line.sheets))")
                }
            }
        } catch {
            err("Stopped during the estimate: nothing was sent.")
            return BatchPrintSummary.stopped
        }
        let total = lines.reduce(0) { $0 + $1.sheets }
        if !request.quiet {
            out("Estimate: \(BatchPrintText.count(lines.count, .file)), \(BatchPrintText.sheets(total)) on \(BatchPrintText.clean(info.name)).")
        }
        if total > request.maxSheets {
            err("That's \(BatchPrintText.sheets(total)), more than --max-sheets allows (\(CoreLanguage.number(request.maxSheets))). Nothing was sent.")
            return BatchPrintSummary.wrong
        }
        if request.dryRun { return lines.contains { $0.problem != nil } ? BatchPrintSummary.someFailed : BatchPrintSummary.done }

        let count = lines.count, quiet = request.quiet
        let summary = await BatchPrintRunner.run(lines, queue, documents, options: options, progress: { p in
            guard let r = p.result, r.state != .skipped else { return }
            if r.state == .sent && quiet { return }
            let word = r.state == .sent ? "sent    " : r.state == .failed ? "failed  " : "not sent"
            let line = "[\(r.index + 1)/\(count)] \(word) \(BatchPrintText.clean(r.name)): \(r.message)"
            if r.state == .failed { err(line) } else { out(line) }
        }, stop)
        out(summary.text)
        var code = summary.exitCode
        if let report = request.report, !writeReport(report, summary.items, err), code == BatchPrintSummary.done { code = BatchPrintSummary.someFailed }
        return code
    }

    private static func watch(_ request: BatchCommandRequest, _ queue: any BatchQueue, _ info: BatchQueueInfo, _ documents: any BatchDocuments, _ password: String?,
                              _ out: @escaping Write, _ err: @escaping Write, _ options: BatchPrintOptions, _ quiet: Duration?, _ poll: Duration?,
                              _ stop: BatchStop) async -> Int32 {
        let folder = BatchPrintList.absolute(request.folder ?? "")
        if let problem = BatchPrintFolder.validate(folder) {
            err(problem)
            return BatchPrintSummary.wrong
        }
        let check = BatchPrintLine((folder as NSString).appendingPathComponent("x.pdf"), request.settings, BatchMeasure(.ready, pageCount: 1), info)
        if let problem = check.problem {
            err(problem)
            return BatchPrintSummary.wrong
        }
        if !request.quiet {
            out("Watching \(BatchPrintText.clean(folder)) for \(BatchPrintText.clean(info.name)), at most \(BatchPrintText.sheets(request.maxSheets)). "
                + (request.once ? "Handling the files there now." : "Control-C stops."))
        }

        let results = ResultList()
        let settings = request.settings, beQuiet = request.quiet
        var folderOptions = BatchFolderOptions()
        folderOptions.settings = settings
        folderOptions.password = password
        folderOptions.once = request.once
        folderOptions.maxSheets = request.maxSheets
        folderOptions.print = options
        if let quiet { folderOptions.quietPeriod = quiet }
        if let poll { folderOptions.pollInterval = poll }
        do {
            let summary = try await BatchPrintFolder.run(folder, queue, documents, folderOptions, progress: { p in
                if let waiting = p.waiting { err("Waiting: \(waiting)") }
                guard let e = p.finished else { return }
                results.add { index in
                    BatchPrintResult(index: index, path: (folder as NSString).appendingPathComponent(e.fileName), state: e.state, message: e.message, pages: 0,
                                     copies: settings.copies, twoSided: settings.twoSided, paper: settings.paper, sheetsEstimated: e.sheetsSent,
                                     sheetsSent: e.sheetsSent, time: e.time)
                }
                if e.state == .sent && beQuiet { return }
                let word = e.state.rawValue.lowercased().padding(toLength: 8, withPad: " ", startingAt: 0)
                let line = "\(BatchFolderEntry.stamp(e.time, date: false)) \(word) \(BatchPrintText.clean(e.fileName)): \(e.message)"
                if e.state == .failed { err(line) } else { out(line) }
            }, stop)
            out("\(BatchPrintText.count(summary.sent, .file)) sent (\(BatchPrintText.sheets(summary.sheetsSent))), \(CoreLanguage.number(summary.failed)) failed.")
            if let why = summary.stopReason { err("Stopped: \(why)") }
            if summary.leftWaiting > 0 {
                err("\(BatchPrintText.count(summary.leftWaiting, .file)) left in the folder for the next run: cut off, or still changing. Not printed.")
            }
            // Control-C is how a plain watch ends; a run that was to finish the folder (--once) stopped before the end.
            var code = summary.stopReason != nil || (request.once && stop.isStopped) ? BatchPrintSummary.stopped
                : summary.failed > 0 || summary.leftWaiting > 0 ? BatchPrintSummary.someFailed : BatchPrintSummary.done
            if let report = request.report, !writeReport(report, results.all, err), code == BatchPrintSummary.done { code = BatchPrintSummary.someFailed }
            return code
        } catch let e as BatchFolderBusyError {
            err(e.message)
            return BatchPrintSummary.wrong
        } catch let e {
            err(BatchPrintText.describe(e))
            return BatchPrintSummary.wrong
        }
    }

    /// A watch's results, gathered as they come.
    private final class ResultList: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [BatchPrintResult] = []

        func add(_ make: (Int) -> BatchPrintResult) { lock.withLock { items.append(make(items.count)) } }
        var all: [BatchPrintResult] { lock.withLock { items } }
    }

    private static func writeReport(_ report: String, _ results: [BatchPrintResult], _ err: Write) -> Bool {
        do {
            // A byte order mark: a spreadsheet reads the names right.
            try BatchPrintList.writeWhole(BatchPrintList.absolute(report), Data(("\u{FEFF}" + BatchPrintCsv.build(results)).utf8))
            return true
        } catch {
            err("The report can't be saved: \(BatchPrintText.describe(error))")
            return false
        }
    }
}
