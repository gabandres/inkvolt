import Foundation

/// How a watched folder judges new files and how often it looks.
public struct WatchOptions: Sendable {
    /// How often the folder is listed.
    public var pollInterval: TimeInterval = 1
    /// A file counts as complete once its size and time haven't changed for this long (and nothing else holds it).
    public var quietPeriod: TimeInterval = 3
    /// Stop once nothing has become ready for a while (a scheduled run) instead of watching until cancelled.
    public var once = false
    /// Most files taken out of the folder for one run (the rest wait for the next).
    public var maxPerRun = 8

    public init(pollInterval: TimeInterval = 1, quietPeriod: TimeInterval = 3, once: Bool = false, maxPerRun: Int = 8) {
        self.pollInterval = pollInterval
        self.quietPeriod = quietPeriod
        self.once = once
        self.maxPerRun = maxPerRun
    }
}

/// A file the watched folder finished with: one line of its log. `fileName`: the file's name as it arrived; `movedTo`:
/// where the original went (done, failed, or back into the folder after a stop).
public struct WatchEntry: Equatable, Sendable {
    public var time: Date
    public var fileName: String
    public var state: BatchItemState
    public var message: String
    public var outputs: [String]
    public var movedTo: String?

    /// Time, state, file name, what happened, the results ("; " between them): tab-separated, for a spreadsheet or a script.
    public var logLine: String {
        let f = DateFormatter()
        f.locale = HeaderFooter.invariant
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return [f.string(from: time), state.rawValue, fileName, message.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "),
                outputs.joined(separator: "; ")].joined(separator: "\t")
    }
}

/// `working`: files being worked on now (0: waiting for files); `finished`: set when a file is finished.
public struct WatchProgress: Sendable {
    public var working: Int
    public var finished: WatchEntry?
}

/// `done`: files done; `failed`: files that failed or were skipped (moved to "failed").
public struct WatchSummary: Equatable, Sendable {
    public var done: Int
    public var failed: Int

    public init(_ done: Int, _ failed: Int) {
        self.done = done
        self.failed = failed
    }
}

/// The folder is watched already (by the app or a command line): two watchers would race for its files.
public struct FolderWatched: Error, Equatable, Sendable, CustomStringConvertible {
    public var folder: String
    public var description: String { "\(folder) is already watched by another Inkvolt PDF (the app or a command line). Stop that one first." }
}

/// A watched folder (the Windows app's `WatchedFolder`): each PDF or image that lands in the folder (not its subfolders)
/// is run through a batch plan once it is complete, then the original is moved to "done" or "failed" below the folder
/// and a line is added to `logName` there. A file is complete when its size and modification time have stayed the same
/// for `WatchOptions.quietPeriod` and nobody holds a lock on it (an app that locks the files it writes, through flock);
/// it is then moved into "working" (a rename, so no other watcher or later look can take it again) and run from there.
/// Everything lives in the folder, so a restart picks up where it was: files left in "working" by a run that never
/// finished (the app closed, the Mac lost power) go to "failed" with a note, never through again, so a file that brings
/// the app down can't do it twice. A lock file keeps a second watcher (the app and a command line) off the same folder.
/// Passwords are never asked: files that need one fail.
public enum WatchedFolder {
    public static let doneFolder = "done", failedFolder = "failed", workingFolder = "working", resultsFolder = "results"
    public static let logName = "inkvolt-watch.log"
    private static let lockName = ".inkvolt-watch.lock"

    /// The results folder a watched folder uses when its preset names none.
    public static func defaultOutput(_ folder: String) -> String { (folder as NSString).appendingPathComponent(resultsFolder) }

    /// What is wrong with watching `folder` into `outputFolder`, or nil.
    public static func validate(_ folder: String, _ outputFolder: String) -> String? {
        if folder.trimmingCharacters(in: .whitespaces).isEmpty || !folder.hasPrefix("/") { return "Choose the folder to watch." }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: folder, isDirectory: &isDir) || !isDir.boolValue { return "There is no folder \(folder)." }
        if trimmed(folder).lowercased() == trimmed(outputFolder).lowercased() {
            return "The results can't go into the watched folder itself (they would be picked up again): use a subfolder such as \"results\", or another folder."
        }
        return nil
    }

    private static func trimmed(_ path: String) -> String {
        var p = (path as NSString).standardizingPath
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    /// Watches `folder` until `cancel` (or, with `WatchOptions.once`, until nothing more becomes ready). A stop lets the
    /// files being worked on finish their current action; those not finished go back into the folder for next time (or
    /// to "failed" when they had written results already).
    /// - Throws: `PdfEditError` when the plan or folders aren't valid; `FolderWatched` when another watcher has the folder.
    public static func run(_ folder: String, _ plan: BatchPlan, _ host: BatchHost, _ options: WatchOptions = WatchOptions(),
                           progress: (@Sendable (WatchProgress) -> Void)? = nil, cancel: CancelToken? = nil) async throws -> WatchSummary {
        let folder = trimmed(folder)
        if let folderError = validate(folder, plan.outputFolder) { throw PdfEditError(folderError) }
        var plan = plan
        plan.passwords = .skip
        plan.keepSubfolders = false
        let host = BatchHost(recognize: host.recognize) // no prompts: nobody may be there to answer
        if let planError = plan.validate(ocrAvailable: host.recognize != nil) { throw PdfEditError(planError) }

        let held = try lock(folder)
        defer { held.release() }
        let fm = FileManager.default
        let working = (folder as NSString).appendingPathComponent(workingFolder)
        for sub in [working, (folder as NSString).appendingPathComponent(doneFolder), (folder as NSString).appendingPathComponent(failedFolder)] {
            try fm.createDirectory(atPath: sub, withIntermediateDirectories: true)
        }
        var done = 0, failed = 0

        // A run that never finished: its files go to "failed", not through again.
        for left in ((try? fm.contentsOfDirectory(atPath: working)) ?? []).filter({ !$0.hasPrefix(".") }).sorted(by: { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }) {
            let entry = finish(folder, (working as NSString).appendingPathComponent(left), left, .failed,
                               "Interrupted: Inkvolt PDF closed while working on it. Put it back in the folder to run it again.", [])
            failed += 1
            progress?(WatchProgress(working: 0, finished: entry))
        }

        // Each file's size and time when last looked at, since when they have been so, and when it was first seen.
        var seen: [String: (size: Int, written: Date, since: Date, first: Date)] = [:]
        while cancel?.isCancelled != true {
            let now = Date()
            var ready: [String] = []
            var present = Set<String>()
            for path in candidates(folder) {
                present.insert(path)
                guard let attributes = try? fm.attributesOfItem(atPath: path), let size = attributes[.size] as? Int,
                      let written = attributes[.modificationDate] as? Date else { continue }
                if let last = seen[path] {
                    if last.size != size || last.written != written {
                        seen[path] = (size, written, now, last.first)
                    } else if now.timeIntervalSince(last.since) >= options.quietPeriod {
                        ready.append(path)
                    }
                } else {
                    seen[path] = (size, written, now, now)
                }
            }
            for gone in seen.keys where !present.contains(gone) { seen[gone] = nil }

            var claimed: [(name: String, path: String)] = []
            for path in ready {
                if claimed.count >= max(1, options.maxPerRun) { break }
                if let moved = claim(path, working) {
                    claimed.append(((path as NSString).lastPathComponent, moved))
                    seen[path] = nil
                }
            }

            if !claimed.isEmpty {
                let (d, f) = await runClaimed(folder, claimed, plan, host, progress, cancel)
                done += d
                failed += f
                continue // look again at once: more may be waiting
            }
            // Once: stop when every file there has had its chance to settle (one still growing or held waits for the next run).
            if options.once && seen.values.allSatisfy({ now.timeIntervalSince($0.first) >= options.quietPeriod + options.pollInterval }) { break }
            let slept = await sleep(options.pollInterval, cancel)
            if !slept { break }
        }
        return WatchSummary(done, failed)
    }

    /// Sleeps for `seconds` in short steps; false when `cancel` fired meanwhile.
    private static func sleep(_ seconds: TimeInterval, _ cancel: CancelToken?) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if cancel?.isCancelled == true { return false }
            try? await Task.sleep(nanoseconds: UInt64(min(0.05, max(0.001, end.timeIntervalSinceNow)) * 1_000_000_000))
        }
        return cancel?.isCancelled != true
    }

    /// The PDFs and images at the top of the folder (not hidden, not Office's "~$" owner files).
    private static func candidates(_ folder: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] } // away for a moment: look again next time
        var files: [String] = []
        for name in names where BatchFiles.isSupported(name) && !name.hasPrefix(".") && !name.hasPrefix("~$") {
            let path = (folder as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { files.append(path) }
        }
        return files
    }

    /// Takes a complete file: open it with an exclusive lock (fails while an app that locks it holds it), then move it
    /// into "working". Nil: not now (still held, or gone).
    private static func claim(_ path: String, _ working: String) -> String? {
        let fd = open(path, O_RDONLY | O_EXLOCK | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let target = free(working, (path as NSString).lastPathComponent)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        } catch {
            return nil
        }
    }

    private static func runClaimed(_ folder: String, _ claimed: [(name: String, path: String)], _ plan: BatchPlan, _ host: BatchHost,
                                   _ progress: (@Sendable (WatchProgress) -> Void)?, _ cancel: CancelToken?) async -> (done: Int, failed: Int) {
        progress?(WatchProgress(working: claimed.count))
        let files = claimed.map { BatchFile($0.path, relativeFolder: "", origin: (folder as NSString).appendingPathComponent($0.name)) }
        var run = plan
        run.date = Date()
        var summary: BatchSummary
        do {
            summary = try await BatchRunner.run(files, run, host, cancel: cancel)
        } catch {
            summary = BatchSummary(files.map { BatchItemResult($0, .failed, BatchRunner.describe(error)) })
        }
        var done = 0, failed = 0
        for (i, (name, path)) in claimed.enumerated() {
            let r = summary.items[i]
            var message = r.notes.isEmpty ? r.message : "\(r.message) (\(r.notes.joined(separator: "; ")))"
            let entry: WatchEntry
            if r.state == .cancelled && r.outputs.isEmpty {
                entry = finish(folder, path, name, r.state, "Stopped before it was done: left in the folder for next time", [], back: true)
            } else {
                let state: BatchItemState = r.state == .cancelled ? .failed : r.state
                if r.state == .cancelled { message = "Stopped part-way (some results were written)" }
                entry = finish(folder, path, name, state, message, r.outputs)
                if state == .done { done += 1 } else { failed += 1 }
            }
            progress?(WatchProgress(working: claimed.count - i - 1, finished: entry))
        }
        return (done, failed)
    }

    /// Moves the original to "done", "failed" or (`back`) the folder itself, and logs the line.
    private static func finish(_ folder: String, _ path: String, _ name: String, _ state: BatchItemState, _ message: String, _ outputs: [String],
                               back: Bool = false) -> WatchEntry {
        let target = back ? folder : (folder as NSString).appendingPathComponent(state == .done ? doneFolder : failedFolder)
        var moved: String?
        var message = message
        var attempt = 0
        while attempt < 20 && moved == nil {
            let to = free(target, name)
            do {
                try FileManager.default.moveItem(atPath: path, toPath: to)
                moved = to
            } catch {
                if !FileManager.default.fileExists(atPath: path) { break }
                attempt += 1
                Thread.sleep(forTimeInterval: 0.1) // briefly held (a virus scanner reading it): try again
            }
        }
        if moved == nil && FileManager.default.fileExists(atPath: path) { message += " (the original stays in \(workingFolder): it couldn't be moved)" }
        let entry = WatchEntry(time: Date(), fileName: name, state: state, message: message, outputs: outputs, movedTo: moved)
        appendLog(folder, entry.logLine)
        return entry
    }

    private static func appendLog(_ folder: String, _ line: String) {
        let path = (folder as NSString).appendingPathComponent(logName)
        for _ in 0..<20 {
            let fd = open(path, O_WRONLY | O_APPEND | O_CREAT | O_EXLOCK, 0o644)
            if fd >= 0 {
                let bytes = Array((line + "\n").utf8)
                _ = bytes.withUnsafeBufferPointer { Foundation.write(fd, $0.baseAddress, $0.count) }
                close(fd)
                return
            }
            Thread.sleep(forTimeInterval: 0.05) // someone has it open to write: wait a moment
        }
    }

    /// A path for `name` in `folder` that isn't taken ("report (2).pdf").
    private static func free(_ folder: String, _ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            let path = (folder as NSString).appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: path) { return path }
            n += 1
        }
    }

    /// The folder's lock file, held for the watch (an advisory lock; the system lets go of it if the process dies).
    private final class Held {
        let fd: Int32
        let path: String
        init(_ fd: Int32, _ path: String) {
            self.fd = fd
            self.path = path
        }
        func release() {
            unlink(path)
            close(fd)
        }
    }

    private static func lock(_ folder: String) throws -> Held {
        let path = (folder as NSString).appendingPathComponent(lockName)
        let fd = open(path, O_RDWR | O_CREAT | O_EXLOCK | O_NONBLOCK, 0o644)
        if fd < 0 {
            if errno == EWOULDBLOCK || errno == EAGAIN { throw FolderWatched(folder: folder) }
            throw PdfEditError("The folder can't be watched: \(String(cString: strerror(errno))).")
        }
        return Held(fd, path)
    }
}
