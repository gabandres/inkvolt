import CoreServices
import Darwin
import Foundation
import PrintCore

/// How an indexer goes about it (Windows' `FolderIndexerOptions`). Tests shorten the times.
public struct FolderIndexerOptions: Sendable {
    /// Files read at one time, each on a thread of its own. A background job: half the cores, up to four.
    public var maxReaders = max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    /// A file changed this recently (seconds) waits: it may still be being written.
    public var quiet: Double = 2
    /// The folder is listed at least this often, in case FSEvents misses something (network volumes may).
    public var rescan: Double = 30
    /// After a change notice, how long to wait for the rest of a burst.
    public var debounce: Double = 1
    /// What has been read is committed at least this often, so a crash costs little and a search sees it.
    public var commitEvery: Double = 10
    /// ...or once this much is waiting in memory.
    public var commitBytes = 32 << 20
    /// A file is given this much processor time on its reading thread (a busy Mac doesn't count against a file).
    public var fileDeadline: Double = 120
    /// ...and this long between signs of life while the Mac is awake, for a reading stuck without using the processor.
    public var stall: Double = 600
    /// Pausing lets files being read finish for this long, then stops them (they are read again later); a reading that
    /// doesn't stop within it after it was given up is left to end by itself, and a new thread reads on.
    public var pauseGrace: Double = 2
    public var maxFileBytes: Int64 = 512 << 20
    public var maxPages = 50_000
    /// UTF-16 characters of text a file may keep.
    public var maxChars = 32 << 20
    /// Seconds one page may take to read (the engine's page check); a page past it is refused and counted as unread.
    public var pageBudget: Double = PdfEngine.defaultPageBudget
    /// PDFs a folder may have in its index; more are listed as over the limit, not read.
    public var maxFiles = 100_000
    /// The index file's size on disk at most: past it nothing more is read until compaction makes room.
    public var maxIndexBytes: Int64 = 2 << 30
    /// More separate lists of terms than this are compacted into one.
    public var maxSegments = 8
    /// Text of a changed or removed file leaves the index file at the next compaction, this long after the last at the earliest.
    public var compactAfter: Double = 120
    /// Test hook: called on the reading thread with each file's path before it is read (it may hang, spin until the
    /// token is cancelled, or throw, which counts as the reading crashing).
    public var readFault: (@Sendable (String, CancelToken) throws -> Void)?

    public init() {}
}

public enum IndexerPhase: Sendable, Equatable {
    case starting, scanning, indexing, compacting, upToDate, paused, stopped
    /// Something is in the way (`IndexerStatus.problem`); it tries again by itself.
    case problem
}

/// Where an indexer is now.
public struct IndexerStatus: Sendable {
    public let phase: IndexerPhase
    /// Files with text in the index.
    public let searchable: Int
    /// Files left in this pass.
    public let waiting: Int
    /// Files read in this pass.
    public let done: Int
    /// Files that couldn't be indexed, by why; `.noText` among them.
    public let skipped: [IndexedState: Int]
    /// Files that couldn't be opened just now, tried again on the next pass.
    public let unavailable: Int
    /// Files only in iCloud Drive (or another File Provider) so far: reading them would download them, so they wait.
    public let cloudOnly: Int
    /// PDFs past `FolderIndexerOptions.maxFiles`, not indexed.
    public let overLimit: Int
    public let problem: String?
    /// `FolderIndexerOptions.maxFiles`, to say.
    public var fileLimit = 100_000

    /// The whole state in one line for the window, and what was left out says so.
    public var text: String {
        var s: String
        switch phase {
        case .starting: s = loc("Starting.")
        case .scanning: s = loc("Looking through the folder.")
        case .indexing: s = loc("Indexing: {0} of {1} files read.", CoreLanguage.number(done), CoreLanguage.number(done + waiting))
        case .compacting: s = loc("Tidying the index.")
        case .upToDate: s = loc("Up to date.")
        case .paused: s = loc("Paused.")
        case .stopped: s = loc("Stopped.")
        case .problem: s = problem ?? loc("Something is in the way.")
        }
        s += " " + (searchable == 1 ? loc("{0} PDF searchable.", CoreLanguage.number(searchable))
                                    : loc("{0} PDFs searchable.", CoreLanguage.number(searchable)))
        let left = IndexedState.allCases.filter { $0 != .noText && $0 != .indexed && (skipped[$0] ?? 0) > 0 }
        if !left.isEmpty {
            let total = left.reduce(0) { $0 + (skipped[$1] ?? 0) }
            let parts = left.map { "\(CoreLanguage.number(skipped[$0] ?? 0)) \(FolderIndexer.describe($0))" }
            s += " " + loc("{0} skipped or cut short: {1}.", CoreLanguage.number(total), parts.joined(separator: ", "))
        }
        if let scans = skipped[.noText], scans > 0 {
            s += " " + loc("{0} with no text yet (scans: Recognize Text makes them searchable).", CoreLanguage.number(scans))
        }
        if unavailable > 0 { s += " " + loc("{0} couldn't be opened just now and will be tried again.", CoreLanguage.number(unavailable)) }
        if cloudOnly > 0 { s += " " + loc("{0} only in iCloud, not downloaded for this.", CoreLanguage.number(cloudOnly)) }
        if overLimit > 0 {
            s += " " + loc("{0} more not indexed: a folder's index holds at most {1} PDFs.", CoreLanguage.number(overLimit),
                           CoreLanguage.number(fileLimit))
        }
        return s
    }
}

/// A file the index has no (or not all of its) text for, and why.
public struct SkippedFile: Sendable, Equatable {
    public let relativePath: String
    public let why: IndexedState
    public let reason: String
}

/// Keeps one folder's `FolderIndex` current, on a thread of its own at utility priority (Windows' `FolderIndexer`): lists
/// the folder (subfolders too), reads what is new or changed, commits as it goes, and then waits for FSEvents' notices or
/// the next look. A file is known by its size and modification time, so nothing is read twice, and nothing reads while
/// nothing changes. A file that can't be indexed (damaged, a password, too big, too slow, ended the app twice) is counted,
/// kept in the index with why, and tried again only when it changes or the index is rebuilt. Text is what PDFs carry, OCR
/// text layers included; a page with no text isn't recognized here.
///
/// The Mac reads in process, on reading threads, where Windows starts index worker processes (as Find does, E16): every
/// page goes through the engine's page check (`pageBudget`, the largest picture, a stream decompressed again and again),
/// so a bomb page is refused, not waited on; a watchdog gives up a file past its processor time or silent too long, and
/// a reading that doesn't stop is left behind while a new thread reads on. A file being read when the app ended is noted
/// in a journal beside the index: twice, and it is `crashed`, never read again until it changes (mac/docs/PLAN.md).
public final class FolderIndexer: @unchecked Sendable {
    public let folder: String
    private let basePath: String
    private let options: FolderIndexerOptions
    private let cond = NSCondition()
    private let gate = NSLock()                  // the batch, counts, the readers
    private var thread: Thread?
    private var stopped = false
    private var woken = false
    private var noted = false
    private var pausedNow: Bool
    private var rebuildAsked = false
    private var deleteIndex = false
    private var abortPass = false
    private var full = false
    private var index: FolderIndex?
    private var batch: IndexBatch?
    private var queue: [Item] = []
    private var readings: [ObjectIdentifier: Reading] = [:]
    private var readerThreads = 0
    private var journal: CrashJournal?
    private var watcher: FolderWatcher?
    private var statusNow = IndexerStatus(phase: .starting, searchable: 0, waiting: 0, done: 0, skipped: [:], unavailable: 0,
                                          cloudOnly: 0, overLimit: 0, problem: nil)
    private var phase: IndexerPhase = .starting
    private var problem: String?
    private var waiting = 0, done = 0, unavailable = 0, cloudOnly = 0, overLimit = 0
    private var lastCompact = Date.distantPast
    private var compactTook: Double = 0
    private var lastPublish: UInt64 = 0
    private var finished = false                 // under cond: the indexer's thread has closed the index
    private let stopToken = CancelToken()

    /// The status changed (at most a few times a second; on the indexer's thread).
    public var changed: (@Sendable () -> Void)? {
        get { gate.withLock { onChange } }
        set { gate.withLock { onChange = newValue } }
    }
    private var onChange: (@Sendable () -> Void)?

    public init(folder: String, basePath: String, options: FolderIndexerOptions = FolderIndexerOptions(), startPaused: Bool = false) {
        var full = URL(fileURLWithPath: folder).standardizedFileURL.path
        while full.count > 1 && full.hasSuffix("/") { full.removeLast() }
        self.folder = full
        self.basePath = basePath
        self.options = options
        pausedNow = startPaused
    }

    public var status: IndexerStatus { gate.withLock { statusNow } }

    public var isPaused: Bool { cond.withLock { pausedNow } }

    /// The index, once it is open; searches go straight to it.
    public var currentIndex: FolderIndex? { gate.withLock { index } }

    /// Test hook: files being read now.
    var liveReadings: Int { gate.withLock { readings.count } }

    public func start() {
        let t = Thread { [self] in loop() }
        t.name = "Inkvolt PDF folder index"
        t.qualityOfService = .utility
        cond.withLock { thread = t }
        t.start()
    }

    /// Stops reading within `pauseGrace`; what was read is committed, and nothing is lost.
    public func pause() { signal { pausedNow = true } }

    public func resume() { signal { pausedNow = false } }

    /// Look at the folder now.
    public func refresh() { signal { noted = true } }

    /// Throws the index away and reads everything again (skipped files get another chance).
    public func rebuild() { signal { rebuildAsked = true } }

    private func signal(_ change: () -> Void) {
        cond.withLock {
            change()
            woken = true
            cond.broadcast()
        }
    }

    /// What the index has no text for, and why, in path order.
    public func skipped() -> [SkippedFile] {
        guard let index = currentIndex else { return [] }
        return index.files.values
            .filter { $0.state != .indexed || $0.failedPages > 0 }
            .sorted { FolderIndex.pathOrder($0.relativePath, $1.relativePath) }
            .map { f in
                SkippedFile(relativePath: f.relativePath, why: f.state, reason: f.state == .indexed
                            ? loc("{0} of {1} pages couldn't be read", CoreLanguage.number(f.failedPages), CoreLanguage.number(f.pages))
                            : Self.describe(f.state))
            }
    }

    /// Why a file isn't (fully) in the index, in a few words.
    public static func describe(_ state: IndexedState) -> String {
        switch state {
        case .noText: loc("no text (a scan)")
        case .password: loc("password protected")
        case .damaged: loc("damaged")
        case .tooBig: loc("too big")
        case .tooSlow: loc("too slow to read")
        case .crashed: loc("ended the app while being read")
        case .indexed: loc("indexed")
        }
    }

    /// Stops, as soon as the readings are stopped and what was read is committed, and closes the index. Waits up to
    /// `wait` seconds.
    public func stop(wait: Double = 10) {
        let started: Thread? = cond.withLock {
            stopped = true
            woken = true
            cond.broadcast()
            return thread
        }
        stopToken.cancel()
        for r in gate.withLock({ Array(readings.values) }) { r.end(.interrupted) }
        guard started != nil else { return }
        let deadline = Date(timeIntervalSinceNow: wait)
        cond.withLock {
            while !finished && Date() < deadline { _ = cond.wait(until: deadline) }
        }
    }

    /// Stops and deletes the index.
    public func stopAndDelete(wait: Double = 10) {
        let started: Bool = cond.withLock {
            deleteIndex = true
            return thread != nil
        }
        stop(wait: wait)
        if started { return }
        if let index = try? FolderIndex.open(basePath) { index.disposeAndDelete() }
        CrashJournal.delete(basePath)
    }

    private var isStopped: Bool { cond.withLock { stopped } }
    private var isPausedNow: Bool { cond.withLock { pausedNow } }

    // ---- The indexer's thread ----

    private func loop() {
        while !isStopped {
            if currentIndex == nil && !openIndex() {
                wait(options.rescan)
                continue
            }
            let rebuildNow: Bool = cond.withLock {
                let r = rebuildAsked
                rebuildAsked = false
                return r
            }
            if rebuildNow {
                try? currentIndex?.clear()
                journal?.clear()
            }
            if isPausedNow {
                setPhase(.paused)
                wait(.infinity)
                continue
            }
            var next = options.rescan
            do {
                next = try pass()
            } catch is FolderIndexDamaged {
                // Found while tidying: its text is all in the PDFs. Read again from nothing.
                try? currentIndex?.clear()
                continue
            } catch is CancellationError {
                continue
            } catch let e as FolderIndexIOError {
                setProblem(loc("Couldn't write the index: {0}", e.message))
            } catch {
                setProblem(loc("Indexing stopped on an error: {0}", "\(error)"))
            }
            wait(next)
        }
        // Stopping.
        let deleting = deleteIndexNow
        gate.withLock {
            if !deleting { try? commitBatch() }
        }
        setPhase(.stopped)
        watcher?.stop()
        watcher = nil
        let index: FolderIndex? = gate.withLock {
            let had = self.index
            self.index = nil
            return had
        }
        if deleting {
            index?.disposeAndDelete()
            CrashJournal.delete(basePath)
        } else {
            index?.dispose()
        }
        cond.withLock {
            finished = true
            cond.broadcast()
        }
    }

    private var deleteIndexNow: Bool { cond.withLock { deleteIndex } }

    private func openIndex() -> Bool {
        do {
            let opened = try FolderIndex.open(basePath)
            let journal = CrashJournal(basePath)
            journal.noteEndedReadings()
            gate.withLock {
                index = opened
                self.journal = journal
                problem = nil
            }
            startWatching()
            return true
        } catch let busy as FolderIndexBusy {
            setProblem(busy.description)
        } catch {
            setProblem(loc("Couldn't open the index: {0}", "\(error)"))
        }
        return false
    }

    /// FSEvents' notices of changes in the folder; without them the regular look still finds everything.
    private func startWatching() {
        watcher?.stop()
        watcher = FolderWatcher(folder) { [weak self] in self?.refresh() }
    }

    /// Waits for a notice, a command or the time, and stays a moment after a notice for the rest of the burst.
    private func wait(_ seconds: Double) {
        cond.lock()
        let until = seconds.isFinite ? Date(timeIntervalSinceNow: seconds) : Date.distantFuture
        while !woken && !stopped && Date() < until { _ = cond.wait(until: until) }
        let signaled = woken
        woken = false
        let debounce = signaled && noted && !stopped
        if debounce { noted = false }
        if debounce {
            let end = Date(timeIntervalSinceNow: options.debounce)
            while !stopped && Date() < end { _ = cond.wait(until: end) }
            woken = false
        }
        cond.unlock()
    }

    // ---- One look at the folder ----

    struct Item: Sendable {
        let relativePath: String
        let fullPath: String
        let size: Int64
        let ticks: Int64
    }

    private static var away: String {
        loc("The folder isn't there just now. The index stays as it is, and its files are found again when it's back.")
    }

    /// Lists the folder, reads what is new or changed, takes out what is gone. Returns how long until the next look.
    private func pass() throws -> Double {
        cond.withLock { noted = false }
        setPhase(.scanning)
        guard let index = currentIndex else { return options.rescan }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            // A volume that is away for now: the index stays as it is. Only a listing that worked can take files out.
            setProblem(Self.away)
            return options.rescan
        }
        if watcher == nil { startWatching() }
        gate.withLock { problem = nil }

        let known = index.files
        var present = Set<String>()
        var queue: [Item] = []
        var tooBig: [Item] = []
        var cloud = 0, over = 0, listed = 0
        var recent = false
        let now = Date().timeIntervalSince1970
        do {
            try Self.listPdfs(folder) { entry in
                if entry.name.hasPrefix("~$") { return }
                let same = known[entry.relativePath].map { $0.size == entry.size && $0.writeTicks == entry.ticks } ?? false
                if !same && listed >= options.maxFiles {
                    over += 1
                    return
                }
                listed += 1
                present.insert(entry.relativePath)
                if same { return }
                if entry.cloudOnly {
                    cloud += 1 // reading it would download it
                    return
                }
                let age = now - Double(entry.ticks) / 1e9
                if age >= 0 && age < options.quiet {
                    recent = true // may still be being written: next look
                    return
                }
                let item = Item(relativePath: entry.relativePath, fullPath: entry.fullPath, size: entry.size, ticks: entry.ticks)
                if entry.size > options.maxFileBytes { tooBig.append(item) } else { queue.append(item) }
            }
        } catch {
            // Gone between the check above and the listing: away, as above, not a listing that failed.
            setProblem(FileManager.default.fileExists(atPath: folder) ? loc("Couldn't list the folder: {0}", "\(error)") : Self.away)
            return options.rescan
        }

        let gone = known.values.filter { !present.contains($0.relativePath) }
        let crashed = journal?.crashedTwice(queue) ?? []
        queue.removeAll { item in crashed.contains { $0.relativePath == item.relativePath } }
        gate.withLock {
            cloudOnly = cloud
            overLimit = over
            unavailable = 0
            done = 0
            full = false
            batch = index.newBatch()
            for f in gone { batch?.remove(f) }
        }
        for item in tooBig { record(item, .tooBig, 0, 0, nil) }
        for item in crashed { record(item, .crashed, 0, 0, nil) }
        try read(queue)
        try gate.withLock { try commitBatch() }
        journal?.keepOnly(present)
        try tidy(index)
        if isStopped { return 0 }
        if gate.withLock({ full }) {
            setProblem(loc("The index has reached its size limit ({0} MB): files not read yet wait until it has room.",
                           CoreLanguage.number(Int(options.maxIndexBytes >> 20))))
            return options.rescan
        }
        if isPausedNow { return 0 }
        gate.withLock { waiting = 0 }
        setPhase(.upToDate)
        return recent ? options.quiet : options.rescan
    }

    /// One PDF a listing found.
    struct Listed {
        let relativePath: String
        let name: String
        let fullPath: String
        let size: Int64
        let ticks: Int64
        let cloudOnly: Bool
    }

    /// The PDFs under `folder`, with `lstat`: a symbolic link is left alone (it leads outside the folder, or round in a
    /// circle), as are hidden files and folders. Nothing is read, so nothing in iCloud is downloaded.
    /// - Throws: when the folder itself can't be listed.
    static func listPdfs(_ folder: String, _ found: (Listed) -> Void) throws {
        guard let root = opendir(folder) else { throw FolderIndexIOError("Couldn't list \((folder as NSString).lastPathComponent)") }
        closedir(root)
        var before = stat()
        guard stat(folder, &before) == 0 else { throw FolderIndexIOError("Couldn't list \((folder as NSString).lastPathComponent)") }
        var stack: [(path: String, relative: String, depth: Int)] = [(folder, "", 0)]
        while let next = stack.popLast() {
            let (dir, relative, depth) = next
            guard let d = opendir(dir) else { continue } // a subfolder out of reach: left alone
            defer { closedir(d) }
            while let entry = readdir(d) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
                }
                if name.hasPrefix(".") { continue }
                let full = dir == "/" ? "/" + name : dir + "/" + name
                var st = stat()
                guard lstat(full, &st) == 0 else { continue }
                if st.st_flags & UInt32(UF_HIDDEN) != 0 { continue }
                let rel = relative.isEmpty ? name : relative + "/" + name
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    if depth < 64 { stack.append((full, rel, depth + 1)) }
                case S_IFREG:
                    guard (name as NSString).pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else { continue }
                    let ticks = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
                    found(Listed(relativePath: rel, name: name, fullPath: full, size: Int64(st.st_size), ticks: ticks,
                                 cloudOnly: isCloudOnly(st.st_flags)))
                default:
                    continue // links, devices
                }
            }
        }
        // A folder moved or replaced while it was listed: what went missing meanwhile isn't gone. The caller sees the
        // folder away (or a listing that failed), not files to take out.
        var after = stat()
        guard stat(folder, &after) == 0, after.st_ino == before.st_ino, after.st_dev == before.st_dev else {
            throw FolderIndexIOError("The folder moved while it was listed", ENOENT)
        }
    }

    /// A file of iCloud Drive (or another File Provider) with its bytes in the cloud: `SF_DATALESS`.
    static func isCloudOnly(_ flags: UInt32) -> Bool { flags & 0x40000000 != 0 }

    private func tidy(_ index: FolderIndex) throws {
        if isStopped || isPausedNow { return }
        let due = index.hasDeadText && Date().timeIntervalSince(lastCompact) >= max(options.compactAfter, compactTook * 100)
        if index.segments <= options.maxSegments && !due { return }
        setPhase(.compacting)
        let started = Date()
        try index.compact(cancel: stopToken)
        compactTook = Date().timeIntervalSince(started)
        lastCompact = Date()
    }

    // ---- Reading ----

    /// Reads the files on reading threads, keeping an eye on them, committing as it goes, until done, paused or stopped.
    private func read(_ items: [Item]) throws {
        if items.isEmpty { return }
        // Small files first: most of a folder becomes searchable soonest, whatever a huge file takes.
        gate.withLock {
            queue = items.sorted { $0.size < $1.size }
            waiting = items.count
        }
        setPhase(.indexing)
        let count = max(1, min(items.count / 8 + 1, options.maxReaders))
        for _ in 0..<count { startReader() }

        var lastCommit = Date()
        var pausedAt: Date?
        var failed: Error?
        var ticked = Date()
        while gate.withLock({ readerThreads > 0 }) {
            cond.withLock {
                if !stopped { _ = cond.wait(until: Date(timeIntervalSinceNow: 0.1)) }
            }
            // Time asleep is no time at all: a tick is never counted as more than a second.
            let tick = min(1, Date().timeIntervalSince(ticked))
            ticked = Date()
            let live = gate.withLock { Array(readings.values) }
            for r in live {
                let (cpu, quiet) = r.watch(tick)
                if cpu > options.fileDeadline || quiet > options.stall { r.end(.tooSlow) }
                if let since = r.endedAt, Date().timeIntervalSince(since) > options.pauseGrace { abandon(r) }
            }
            if isPausedNow || isStopped {
                if pausedAt == nil { pausedAt = Date() }
                if isStopped || Date().timeIntervalSince(pausedAt!) > options.pauseGrace { for r in live { r.end(.interrupted) } }
            } else {
                pausedAt = nil
            }
            gate.withLock {
                guard let batch, !batch.isEmpty else { return }
                guard batch.bytes >= options.commitBytes || batch.termCount > 2_000_000
                        || Date().timeIntervalSince(lastCommit) >= options.commitEvery else { return }
                do {
                    try commitBatch()
                } catch {
                    // The disk is full, say. The readers stop here; what they read is read again.
                    failed = error
                    abortPass = true
                }
                lastCommit = Date()
            }
            publish()
        }
        gate.withLock { abortPass = false }
        if let failed { throw failed }
    }

    private func startReader() {
        gate.withLock { readerThreads += 1 }
        let t = Thread { [self] in serve() }
        t.name = "Inkvolt PDF index reader"
        t.qualityOfService = .utility
        t.stackSize = 8 << 20 // MuPDF's parsing of deep structures is recursive
        t.start()
    }

    private func takeItem() -> Item? {
        if isPausedNow || isStopped { return nil }
        return gate.withLock {
            if abortPass || full || queue.isEmpty { return nil }
            if let index, index.fileBytes + Int64(batch?.bytes ?? 0) >= options.maxIndexBytes {
                full = true
                return nil
            }
            return queue.removeFirst()
        }
    }

    /// One reading thread: takes files until there are none left or it is told to stop, or until a file it was reading
    /// is given up without stopping (a new thread has taken its place then).
    private func serve() {
        while let item = takeItem() {
            if !Self.canOpen(item.fullPath) {
                gate.withLock {
                    unavailable += 1
                    waiting -= 1
                }
                continue
            }
            let reading = Reading(item)
            gate.withLock { readings[ObjectIdentifier(reading)] = reading }
            journal?.reading(item)
            let outcome: Outcome
            do {
                outcome = .read(try Self.readFile(item.fullPath, limits: limits, reading: reading, fault: options.readFault))
            } catch {
                outcome = .crashed
            }
            guard reading.finish() else {
                return // given up and replaced: the watchdog recorded it
            }
            gate.withLock { readings[ObjectIdentifier(reading)] = nil }
            journal?.done(item)
            switch (reading.endedFor, outcome) {
            case (.tooSlow?, _):
                record(item, .tooSlow, Self.countOf(reading.pages), 0, reading.pages)
            case (.interrupted?, _):
                gate.withLock { waiting -= 1 } // paused or stopped: the next look finds it
            case (nil, .crashed):
                // Once more in case it was something else; twice is the file.
                if (journal?.crashed(item) ?? 2) < 2 {
                    gate.withLock { queue.append(item) }
                } else {
                    record(item, .crashed, Self.countOf(reading.pages), 0, reading.pages)
                }
            case (nil, .read(let r)):
                finish(item, r, reading.pages)
            }
        }
        gate.withLock { readerThreads -= 1 }
        cond.withLock { cond.broadcast() }
    }

    private enum Outcome {
        case read(FileRead)
        case crashed
    }

    /// The watchdog's last word on a reading that was told to end and didn't: what it read is kept, and a new thread reads on.
    private func abandon(_ r: Reading) {
        guard r.abandon() else { return }
        gate.withLock {
            readings[ObjectIdentifier(r)] = nil
            readerThreads -= 1
        }
        journal?.done(r.item)
        if r.endedFor == .tooSlow {
            record(r.item, .tooSlow, Self.countOf(r.pages), 0, r.pages)
        } else {
            gate.withLock { waiting -= 1 }
        }
        if !isStopped && !isPausedNow && gate.withLock({ !queue.isEmpty }) { startReader() }
    }

    private var limits: IndexLimits {
        IndexLimits(maxFileBytes: options.maxFileBytes, maxPages: options.maxPages, maxChars: options.maxChars, pageBudget: options.pageBudget)
    }

    /// Not a file this app may read just now (permissions, a volume going away): no reading is started for it.
    private static func canOpen(_ path: String) -> Bool {
        let fd = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return false }
        Darwin.close(fd)
        return true
    }

    private static func countOf(_ pages: [Int: String]) -> Int { (pages.keys.max() ?? -1) + 1 }

    private func finish(_ item: Item, _ r: FileRead, _ pages: [Int: String]) {
        switch r.end {
        case .read: record(item, pages.isEmpty ? .noText : .indexed, r.pages, r.failed, pages)
        case .password: record(item, .password, 0, 0, nil)
        case .damaged: record(item, .damaged, 0, 0, nil)
        case .tooBig: record(item, .tooBig, max(Self.countOf(pages), pages.isEmpty ? 0 : r.pages), r.failed, pages)
        case .unavailable:
            gate.withLock {
                unavailable += 1
                waiting -= 1
            }
        }
    }

    /// What became of a file, into the batch: its words are filed outside the batch's lock, the only slow part.
    private func record(_ item: Item, _ state: IndexedState, _ pageCount: Int, _ failed: Int, _ pages: [Int: String]?) {
        var list = [String?](repeating: nil, count: pageCount)
        for (page, text) in pages ?? [:] where page < list.count { list[page] = text }
        let packed = FolderIndex.packPages(list)
        gate.withLock {
            guard let batch, let index else { return }
            if let had = index.files[item.relativePath] { batch.remove(had) }
            batch.add(item.relativePath, size: item.size, writeTicks: item.ticks, state: state, pageCount: pageCount,
                      failedPages: failed, packed: packed, pages: list)
            done += 1
            waiting -= 1
        }
    }

    /// Commits what is waiting (under `gate`).
    private func commitBatch() throws {
        guard let batch, !batch.isEmpty, let index else { return }
        var next: IndexBatch?
        defer { self.batch = next } // on failure the batch is dropped: its files are read again on the next look
        try index.commit(batch)
        next = index.newBatch()
        publishLocked(force: true)
    }

    private func setPhase(_ p: IndexerPhase) {
        gate.withLock {
            phase = p
            publishLocked(force: true)
        }
        notify()
    }

    private func setProblem(_ text: String) {
        gate.withLock {
            problem = text
            phase = .problem
            publishLocked(force: true)
        }
        notify()
    }

    private func publish() {
        let sent = gate.withLock { publishLocked(force: false) }
        if sent { notify() }
    }

    private func notify() { gate.withLock { onChange }?() }

    @discardableResult
    private func publishLocked(force: Bool) -> Bool {
        let now = DispatchTime.now().uptimeNanoseconds
        if !force && now - lastPublish < 250_000_000 { return false }
        lastPublish = now
        var skipped: [IndexedState: Int] = [:]
        var searchable = 0
        if let index {
            for f in index.files.values {
                let partly = f.state == .tooBig || f.state == .tooSlow || f.state == .crashed
                if f.state == .indexed || (partly && f.pages > 0) { searchable += 1 }
                if f.state == .indexed { continue }
                skipped[f.state, default: 0] += 1
            }
        }
        statusNow = IndexerStatus(phase: phase, searchable: searchable, waiting: max(0, waiting), done: done, skipped: skipped,
                                  unavailable: unavailable, cloudOnly: cloudOnly, overLimit: overLimit, problem: problem,
                                  fileLimit: options.maxFiles)
        return true
    }

    // ---- Reading one file ----

    /// How a file's reading ended.
    enum ReadEnd: Sendable {
        case read, password, damaged, tooBig
        /// Couldn't be opened just now: not recorded, tried on a later pass.
        case unavailable
    }

    struct FileRead: Sendable {
        let end: ReadEnd
        let pages: Int
        let failed: Int
    }

    /// Reads a file's pages into `reading.pages` within the limits: the file's size and page count, the text it may keep,
    /// and each page's budget (a page past it, or with a picture too large, is refused and counted as unread).
    /// - Throws: `CancellationError` when the reading was ended; anything a test's fault throws.
    static func readFile(_ path: String, limits: IndexLimits, reading: Reading,
                         fault: (@Sendable (String, CancelToken) throws -> Void)?) throws -> FileRead {
        try fault?(path, reading.cancel)
        try reading.cancel.check()
        var st = stat()
        guard stat(path, &st) == 0 else { return FileRead(end: .unavailable, pages: 0, failed: 0) }
        if Int64(st.st_size) > limits.maxFileBytes { return FileRead(end: .tooBig, pages: 0, failed: 0) }
        let bytes: [UInt8]
        do {
            bytes = try PdfEngine.readFile(path)
        } catch {
            return FileRead(end: .unavailable, pages: 0, failed: 0)
        }
        reading.sign()
        let engine: PdfEngine
        do {
            engine = try PdfEngine.open(bytes)
        } catch is PasswordRequired {
            return FileRead(end: .password, pages: 0, failed: 0)
        } catch {
            return FileRead(end: .damaged, pages: 0, failed: 0)
        }
        defer { engine.close() }
        reading.sign()
        engine.pageBudget = limits.pageBudget
        if engine.pageCount > limits.maxPages { return FileRead(end: .tooBig, pages: engine.pageCount, failed: 0) }
        var chars = 0
        var failed = 0
        for page in 0..<engine.pageCount {
            try reading.cancel.check()
            let text: String
            do {
                text = try engine.text(page, cache: false, cancel: reading.cancel).text
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1 // a refused or damaged page: the others are worth having
                reading.sign()
                continue
            }
            reading.sign()
            if text.isEmpty { continue }
            let length = text.utf16.count
            if chars + length > limits.maxChars { return FileRead(end: .tooBig, pages: engine.pageCount, failed: failed) }
            chars += length
            reading.add(page, text)
        }
        return FileRead(end: .read, pages: engine.pageCount, failed: failed)
    }
}

/// What one file may cost to read.
struct IndexLimits: Sendable {
    let maxFileBytes: Int64
    let maxPages: Int
    let maxChars: Int
    let pageBudget: Double
}

/// One file being read on a reading thread, as the watchdog sees it: its thread's processor time, its signs of life, and
/// whether it was told to end, finished, or given up.
final class Reading: @unchecked Sendable {
    enum Ended { case tooSlow, interrupted }

    let item: FolderIndexer.Item
    let cancel = CancelToken()
    private let lock = NSLock()
    private var read: [Int: String] = [:]
    private var signs = 0
    private var seenSigns = 0
    private var quiet: Double = 0
    private let thread = pthread_mach_thread_np(pthread_self())
    private let cpuAtStart: Double
    private var ended: Ended?
    private var endedWhen: Date?
    private var returned = false
    private var abandoned = false

    /// Made on the thread that reads the file.
    init(_ item: FolderIndexer.Item) {
        self.item = item
        cpuAtStart = Self.cpu(pthread_mach_thread_np(pthread_self()))
    }

    var pages: [Int: String] { lock.withLock { read } }
    var endedFor: Ended? { lock.withLock { ended } }
    var endedAt: Date? { lock.withLock { returned || abandoned ? nil : endedWhen } }

    func add(_ page: Int, _ text: String) {
        lock.withLock {
            read[page] = text
            signs += 1
        }
    }

    func sign() { lock.withLock { signs += 1 } }

    /// For the watchdog, every tick: the processor time this file has taken on its thread, and how long it has given no
    /// sign of life (`tick` seconds since the last look).
    func watch(_ tick: Double) -> (cpu: Double, quiet: Double) {
        let q: Double = lock.withLock {
            quiet = signs == seenSigns ? quiet + tick : 0
            seenSigns = signs
            return quiet
        }
        return (Self.cpu(thread) - cpuAtStart, q)
    }

    /// Tells the reading to end now (its MuPDF calls are aborted through the token).
    func end(_ why: Ended) {
        lock.withLock {
            if ended == nil {
                ended = why
                endedWhen = Date()
            }
        }
        cancel.cancel()
    }

    /// The reading thread is back: false when it was given up meanwhile (its thread then ends).
    func finish() -> Bool {
        lock.withLock {
            if abandoned { return false }
            returned = true
            return true
        }
    }

    /// The watchdog gives up waiting: false when the thread came back just now.
    func abandon() -> Bool {
        lock.withLock {
            if returned || abandoned { return false }
            abandoned = true
            return true
        }
    }

    /// A thread's processor time in seconds (user and system), 0 when it can't be read.
    private static func cpu(_ thread: mach_port_t) -> Double {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let user = Double(info.user_time.seconds) + Double(info.user_time.microseconds) / 1e6
        let system = Double(info.system_time.seconds) + Double(info.system_time.microseconds) / 1e6
        return user + system
    }
}

/// The files being read, kept beside the index while they are, and how often each was being read when the app ended
/// (Windows counts a worker's death; here the app's own). Two lines of text per file, nothing else: the relative path,
/// its modification time, the count.
final class CrashJournal: @unchecked Sendable {
    private let readingPath: String
    private let countsPath: String
    private let lock = NSLock()
    private var now: [String: Int64] = [:]       // path → ticks, being read now
    private var counts: [String: (ticks: Int64, count: Int)] = [:]

    init(_ basePath: String) {
        readingPath = basePath + ".reading"
        countsPath = basePath + ".crashes"
        counts = Self.load(countsPath).mapValues { ($0.ticks, $0.count) }
    }

    static func delete(_ basePath: String) {
        unlink(basePath + ".reading")
        unlink(basePath + ".crashes")
    }

    /// At the start: the files being read when the app last ended each count once.
    func noteEndedReadings() {
        lock.withLock {
            for (path, entry) in Self.load(readingPath) {
                let had = counts[path]
                counts[path] = (entry.ticks, had?.ticks == entry.ticks ? (had?.count ?? 0) + 1 : 1)
            }
            unlink(readingPath)
            Self.save(countsPath, counts)
        }
    }

    /// The items that ended the app twice already: not read again until they change.
    func crashedTwice(_ items: [FolderIndexer.Item]) -> [FolderIndexer.Item] {
        lock.withLock {
            items.filter { item in counts[item.relativePath].map { $0.ticks == item.ticks && $0.count >= 2 } ?? false }
        }
    }

    func reading(_ item: FolderIndexer.Item) {
        lock.withLock {
            now[item.relativePath] = item.ticks
            Self.save(readingPath, now.mapValues { ($0, 0) })
        }
    }

    func done(_ item: FolderIndexer.Item) {
        lock.withLock {
            now[item.relativePath] = nil
            if now.isEmpty { unlink(readingPath) } else { Self.save(readingPath, now.mapValues { ($0, 0) }) }
        }
    }

    /// A reading that failed in a way nobody expected, counted as the app ending would be; returns the count.
    func crashed(_ item: FolderIndexer.Item) -> Int {
        lock.withLock {
            let had = counts[item.relativePath]
            let n = had?.ticks == item.ticks ? (had?.count ?? 0) + 1 : 1
            counts[item.relativePath] = (item.ticks, n)
            Self.save(countsPath, counts)
            return n
        }
    }

    /// Forgets files no longer in the folder.
    func keepOnly(_ present: Set<String>) {
        lock.withLock {
            let before = counts.count
            counts = counts.filter { present.contains($0.key) }
            if counts.count != before { Self.save(countsPath, counts) }
        }
    }

    func clear() {
        lock.withLock {
            counts = [:]
            unlink(countsPath)
        }
    }

    private static func load(_ path: String) -> [String: (ticks: Int64, count: Int)] {
        guard let data = FileManager.default.contents(atPath: path), data.count <= 4 << 20 else { return [:] }
        var out: [String: (ticks: Int64, count: Int)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let ticks = Int64(parts[0]), let count = Int(parts[1]), !parts[2].isEmpty else { continue }
            out[String(parts[2])] = (ticks, max(0, min(count, 99)))
        }
        return out
    }

    private static func save(_ path: String, _ entries: [String: (ticks: Int64, count: Int)]) {
        if entries.isEmpty {
            unlink(path)
            return
        }
        let text = entries.map { "\($0.value.ticks)\t\($0.value.count)\t\($0.key)" }.joined(separator: "\n")
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

/// FSEvents on one folder and everything under it: calls `changed` (on its own queue) when a PDF or a folder in it comes,
/// goes or changes. FSEvents gives no notice for a folder it can't watch: the regular look covers that.
final class FolderWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "Inkvolt PDF folder watch", qos: .utility)

    /// What the stream's callback holds: FSEvents retains it and lets go when the stream is released, so a callback
    /// still on its way after `stop` finds it alive.
    private final class Target: @unchecked Sendable {
        let changed: @Sendable () -> Void
        init(_ changed: @escaping @Sendable () -> Void) { self.changed = changed }
    }

    init(_ folder: String, _ changed: @escaping @Sendable () -> Void) {
        let target = Target(changed)
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(target).toOpaque(),
                                           retain: { info in
                                               guard let info else { return nil }
                                               _ = Unmanaged<AnyObject>.fromOpaque(info).retain()
                                               return info
                                           },
                                           release: { info in
                                               guard let info else { return }
                                               Unmanaged<AnyObject>.fromOpaque(info).release()
                                           },
                                           copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<Target>.fromOpaque(info).takeUnretainedValue()
            let list = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String] ?? []
            for i in 0..<min(count, list.count) {
                let f = Int(flags[i])
                let isDir = f & kFSEventStreamEventFlagItemIsDir != 0
                let rescan = f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged) != 0
                if rescan || isDir || (list[i] as NSString).pathExtension.caseInsensitiveCompare("pdf") == .orderedSame {
                    watcher.changed()
                    return
                }
            }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let made = FSEventStreamCreate(nil, callback, &context, [folder] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                             0.2, flags) else { return }
        FSEventStreamSetDispatchQueue(made, queue)
        if FSEventStreamStart(made) {
            stream = made
        } else {
            FSEventStreamInvalidate(made)
            FSEventStreamRelease(made)
        }
    }

    func stop() {
        guard let stream else { return }
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit { stop() }
}
