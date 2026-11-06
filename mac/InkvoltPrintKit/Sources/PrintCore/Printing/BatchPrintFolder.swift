import Foundation

/// How a batch print folder prints what lands in it, and how it judges new files.
public struct BatchFolderOptions: Sendable {
    public var settings = BatchPrintSettings()
    /// Tried once on a file that needs a password; none is ever asked for (nobody may be there to answer).
    public var password: String?
    public var pollInterval: Duration = .seconds(1)
    /// A file counts as complete once its size and time haven't changed for this long, nobody holds it, and it reads as whole.
    public var quietPeriod: Duration = .seconds(3)
    /// A file that still reads as cut off this long after it last changed is listed as failed rather than printed.
    public var cutOffLimit: Duration = .seconds(600)
    /// Stop once nothing more has become ready (a scheduled run) instead of watching until stopped.
    public var once = false
    /// The most sheets this run sends: a file that alone is more goes to "failed"; one that would pass it waits in the folder
    /// and the run stops.
    public var maxSheets = BatchPrintLimits.defaultMaxSheets
    public var print = BatchPrintOptions()

    public init() {}
}

/// A file the folder finished with: one line of its log. `movedTo`: where the original went (done, failed, or back into the
/// folder).
public struct BatchFolderEntry: Sendable {
    public var time: Date
    public var fileName: String
    public var state: BatchPrintState
    public var message: String
    public var sheetsSent: Int
    public var movedTo: String?

    public init(time: Date, fileName: String, state: BatchPrintState, message: String, sheetsSent: Int, movedTo: String?) {
        self.time = time
        self.fileName = fileName
        self.state = state
        self.message = message
        self.sheetsSent = sheetsSent
        self.movedTo = movedTo
    }

    /// "2026-11-05 14:03:09" in this Mac's time zone, or the time alone.
    public static func stamp(_ time: Date, date: Bool = true, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: time)
        let clock = String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return date ? String(format: "%04d-%02d-%02d ", c.year ?? 0, c.month ?? 0, c.day ?? 0) + clock : clock
    }

    /// Time, state, file name, what happened, sheets sent: tab-separated, for a spreadsheet or a script.
    public var logLine: String {
        [Self.stamp(time), state.rawValue.lowercased(), CsvCell.notFormula(BatchPrintText.clean(fileName)),
         CsvCell.notFormula(BatchPrintText.clean(message)), String(sheetsSent)].joined(separator: "\t")
    }
}

/// `finished`: set when a file is finished; `waiting`: why files are being left in the folder for now (the printer has a
/// problem), or nil.
public struct BatchFolderProgress: Sendable {
    public var finished: BatchFolderEntry?
    public var waiting: String?

    public init(finished: BatchFolderEntry? = nil, waiting: String? = nil) {
        self.finished = finished
        self.waiting = waiting
    }
}

/// `stopReason`: why it stopped with files left in the folder (the printer's problem in a run with `once`, the run's limit of
/// sheets), or nil. `leftWaiting`: with `once`, printable files still at the top of the folder when it ended (cut off, or
/// still changing).
public struct BatchFolderSummary: Equatable, Sendable {
    public var sent: Int
    public var failed: Int
    public var sheetsSent: Int
    public var stopReason: String?
    public var leftWaiting = 0
}

/// The folder is watched already (by either app, or a command line): two watchers would race for its files.
public struct BatchFolderBusyError: Error, Sendable {
    public var message: String

    init(_ folder: String) {
        message = loc("{0} is already watched (by Inkvolt Print or Inkvolt PDF, the app or a command line). Stop that one first.", BatchPrintText.clean(folder))
    }
}

/// A folder printed as it fills (Windows' `BatchPrintFolder`): each PDF or picture that lands at its top is printed once when
/// it's complete, then the original is moved to "done" or "failed" below the folder and a line is added to `logName` there,
/// the way Inkvolt PDF's watched folder works. Paper rules what's different: a file goes to "working" before it's sent and
/// only leaves for "done" after, so a file left in "working" by a run that never finished (the app closed, the Mac lost
/// power) may have printed, goes to "failed" with a note, and is never sent again by a restart. A file that reads as cut off
/// waits; one that needs a password or would pass the run's sheets isn't sent. While the printer has a problem, files stay.
public enum BatchPrintFolder {
    public static let logName = "inkvolt-print.log"

    /// What is wrong with watching this folder, or nil.
    public static func validate(_ folder: String) -> String? {
        if folder.trimmingCharacters(in: .whitespaces).isEmpty || !(folder as NSString).isAbsolutePath { return loc("Choose the folder to watch.") }
        var isFolder: ObjCBool = false
        return FileManager.default.fileExists(atPath: folder, isDirectory: &isFolder) && isFolder.boolValue
            ? nil : loc("There is no folder {0}.", BatchPrintText.clean(folder))
    }

    /// The printable files already at the top of the folder: those would print as soon as the watch starts.
    public static func readyToPrint(_ folder: String) -> Int { DropFolder.candidates(folder, BatchPrintFiles.isSupported).count }

    /// Watches until `stop` (or, with `once`, until nothing more becomes ready). A stop lets a job already handed over finish;
    /// a file not sent goes back into the folder for next time.
    /// - Throws: `BatchFileError`: the folder isn't valid; `BatchFolderBusyError`: another watcher has it.
    public static func run(_ folder: String, _ queue: any BatchQueue, _ documents: any BatchDocuments, _ options: BatchFolderOptions = BatchFolderOptions(),
                           progress: (@Sendable (BatchFolderProgress) -> Void)?, _ stop: BatchStop = BatchStop()) async throws -> BatchFolderSummary {
        var folder = folder
        while folder.count > 1 && (folder.hasSuffix("/") || folder.hasSuffix("\\")) { folder.removeLast() }
        if let problem = validate(folder) { throw BatchFileError(problem) }
        guard let held = DropFolder.lock(folder) else { throw BatchFolderBusyError(folder) }
        defer { held.release() }
        let working = (folder as NSString).appendingPathComponent(DropFolder.workingFolder)
        for sub in [DropFolder.workingFolder, DropFolder.doneFolder, DropFolder.failedFolder] {
            try FileManager.default.createDirectory(atPath: (folder as NSString).appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var sent = 0, failed = 0, sheets = 0

        // A run that never finished: the file may have printed, so it's never sent again by itself.
        let left = ((try? FileManager.default.contentsOfDirectory(atPath: working)) ?? []).filter { !$0.hasPrefix(".") }.sorted(by: NaturalOrder.less)
        for name in left {
            let entry = finish(folder, (working as NSString).appendingPathComponent(name), name, .failed,
                               loc("Interrupted: Inkvolt Print closed while sending it, so it may have printed. Put it back in the folder to print it again."), 0)
            progress?(BatchFolderProgress(finished: entry))
            failed += 1
        }

        let look = DropFolderLook(options.quietPeriod)
        let cutOffLimit = DropFolderLook.seconds(options.cutOffLimit)
        var waiting: String?
        var stopReason: String?
        while !stop.isStopped {
            let now = Date()
            let ready = look.ready(DropFolder.candidates(folder, BatchPrintFiles.isSupported), now).sorted(by: NaturalOrder.less)

            var taken: (path: String, from: String)?
            if !ready.isEmpty {
                let problem: String?
                do {
                    switch try await within(options.print.queueTimeout, { try await queue.problem() }) {
                    case .done(let said): problem = said
                    case .late: problem = loc("macOS doesn't answer about the printer.")
                    }
                } catch is CancellationError {
                    break
                } catch {
                    problem = (error as? BatchQueueError)?.message ?? BatchPrintText.describe(error)
                }
                if stop.isStopped { break }
                if let problem {
                    if problem != waiting { progress?(BatchFolderProgress(waiting: problem)) }
                    waiting = problem
                    if options.once {
                        stopReason = problem
                        break
                    }
                } else {
                    if waiting != nil { progress?(BatchFolderProgress()) }
                    waiting = nil
                    for path in ready {
                        let cutOff = !looksWhole(path)
                        if cutOff && now.timeIntervalSince(look.unchangedSince(path) ?? now) < cutOffLimit { continue }
                        guard let moved = DropFolder.claim(path, working) else { continue }
                        look.forget(path)
                        if cutOff {
                            let entry = finish(folder, moved, (path as NSString).lastPathComponent, .failed,
                                               loc("It reads as cut off and hasn't changed since. Not printed: if it is whole, print it from the Batch Print window."), 0)
                            progress?(BatchFolderProgress(finished: entry))
                            failed += 1
                            continue
                        }
                        taken = (moved, path)
                        break
                    }
                }
            }

            if let taken {
                let (entry, halt) = await printOne(folder, taken.path, (taken.from as NSString).lastPathComponent, queue, documents, options, sheets, stop)
                progress?(BatchFolderProgress(finished: entry))
                if entry.state == .sent { sent += 1 } else if entry.state == .failed { failed += 1 }
                sheets += entry.sheetsSent
                if let halt, options.once || halt.final {
                    stopReason = halt.why
                    break
                }
                continue // look again at once: more may be waiting
            }
            // Once: stop when every file there has had its chance to settle (one still growing or held waits for the next run).
            if options.once && look.allSeenFor(options.quietPeriod + options.pollInterval, now) { break }
            if !(await sleep(options.pollInterval, stop)) { break }
        }
        return BatchFolderSummary(sent: sent, failed: failed, sheetsSent: sheets, stopReason: stopReason, leftWaiting: options.once ? readyToPrint(folder) : 0)
    }

    /// Sleeps in short steps; false when stopped meanwhile.
    private static func sleep(_ time: Duration, _ stop: BatchStop) async -> Bool {
        let end = ContinuousClock.now + time
        while ContinuousClock.now < end {
            if stop.isStopped { return false }
            try? await Task.sleep(for: min(.milliseconds(50), end - ContinuousClock.now))
        }
        return !stop.isStopped
    }

    private struct Halt {
        var why: String
        var final: Bool
    }

    private static func printOne(_ folder: String, _ path: String, _ name: String, _ queue: any BatchQueue, _ documents: any BatchDocuments,
                                 _ options: BatchFolderOptions, _ sheetsSoFar: Int, _ stop: BatchStop) async -> (BatchFolderEntry, Halt?) {
        let result: BatchPrintResult
        let stopReason: String?
        do {
            guard let info = try await queue.read() else {
                return (finish(folder, path, name, .stopped, loc("Not sent: this printer has no queue now. It's back in the folder."), 0, back: true),
                        Halt(why: loc("This printer has no queue now."), final: true))
            }
            let measure = try await BatchMeasurer.measure(path, offered: options.password, documents, ask: nil, options: options.print, stop)
            let line = BatchPrintLine(path, options.settings, measure, info)
            if line.problem == nil && line.sheets > options.maxSheets {
                return (finish(folder, path, name, .failed,
                               loc("It would print {0}, more than the {1} a run may send. Not printed.", BatchPrintText.sheets(line.sheets), CoreLanguage.number(options.maxSheets)), 0), nil)
            }
            if line.problem == nil && sheetsSoFar + line.sheets > options.maxSheets {
                let why = loc("This run has sent {0}, and the next file would pass the {1} it may send.", BatchPrintText.sheets(sheetsSoFar), CoreLanguage.number(options.maxSheets))
                return (finish(folder, path, name, .stopped, loc("Not sent: the run's limit of sheets. It's back in the folder."), 0, back: true), Halt(why: why, final: true))
            }
            let summary = await BatchPrintRunner.run([line], queue, documents, options: options.print, stop)
            result = summary.items[0]
            stopReason = summary.stopReason
        } catch is CancellationError {
            return (finish(folder, path, name, .stopped, loc("Stopped before it was sent: it's back in the folder for next time."), 0, back: true), nil)
        } catch {
            // Asking the printer what it takes failed: nothing was sent.
            return (finish(folder, path, name, .stopped, loc("Not sent: the printer can't be read. It's back in the folder for next time."), 0, back: true),
                    Halt(why: BatchPrintText.describe(error), final: false))
        }
        // Sure not sent: it can go back. Anything less sure stays out of the folder, so it can't print twice.
        if result.state == .stopped {
            return (finish(folder, path, name, .stopped, loc("Not sent: {0} It's back in the folder for next time.", stopReason ?? ""), 0, back: true),
                    stopReason.map { Halt(why: $0, final: false) })
        }
        let state: BatchPrintState = result.state == .sent ? .sent : .failed
        return (finish(folder, path, name, state, result.message, result.sheetsSent), stopReason.map { Halt(why: $0, final: true) })
    }

    /// Moves the original to "done", "failed" or (`back`) the folder itself, and logs the line.
    private static func finish(_ folder: String, _ path: String, _ name: String, _ state: BatchPrintState, _ message: String, _ sheets: Int,
                               back: Bool = false) -> BatchFolderEntry {
        let target = back ? folder : (folder as NSString).appendingPathComponent(state == .sent ? DropFolder.doneFolder : DropFolder.failedFolder)
        let moved = DropFolder.moveTo(path, target, name)
        var message = message
        if moved == nil && FileManager.default.fileExists(atPath: path) {
            message += loc(" (the original stays in {0}: it couldn't be moved)", DropFolder.workingFolder)
        }
        let entry = BatchFolderEntry(time: Date(), fileName: name, state: state, message: message, sheetsSent: sheets, movedTo: moved)
        DropFolder.appendLog((folder as NSString).appendingPathComponent(logName), entry.logLine)
        return entry
    }

    /// False when a PDF, JPEG or PNG stops short of its own end: a copy that paused longer than the quiet period, or a program
    /// that writes, closes and comes back. Printing such a file wastes paper on half a document. Other kinds have no end mark
    /// to read. Only for a file that was read; one that can't be read now is left to the claim.
    public static func looksWhole(_ path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return true }
        defer { try? handle.close() }
        do {
            let head = Array(try handle.read(upToCount: 8) ?? Data())
            let length = try handle.seekToEnd()
            let tailLength = min(length, 1024)
            try handle.seek(toOffset: length - tailLength)
            let tail = Array(try handle.read(upToCount: Int(tailLength)) ?? Data())
            return looksWhole(head: head, tail: tail)
        } catch {
            return true
        }
    }

    public static func looksWhole(_ bytes: [UInt8]) -> Bool {
        looksWhole(head: Array(bytes.prefix(8)), tail: Array(bytes.suffix(1024)))
    }

    private static func looksWhole(head: [UInt8], tail: [UInt8]) -> Bool {
        if head.count < 4 { return false }
        func ends(_ mark: [UInt8]) -> Bool {
            guard tail.count >= mark.count else { return false }
            return (0...(tail.count - mark.count)).contains { Array(tail[$0..<$0 + mark.count]) == mark }
        }
        if head.starts(with: Array("%PDF".utf8)) { return ends(Array("%%EOF".utf8)) }
        if head[0] == 0xFF && head[1] == 0xD8 { return ends([0xFF, 0xD9]) }
        if head.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ends(Array("IEND".utf8)) }
        return true
    }
}
