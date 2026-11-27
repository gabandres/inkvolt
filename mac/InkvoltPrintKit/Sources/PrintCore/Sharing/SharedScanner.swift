import Foundation

/// One HTTP request to the shared scanner, as the server read it (its size already bounded there). `path`: without the
/// query; `peer`: who asked, kept in memory with the jobs it starts, never logged; `authority`: the request's Host header
/// (for the job's absolute address), nil when it hasn't one.
public struct ShareRequest: Sendable {
    public var method: String
    public var path: String
    public var body: [UInt8]
    public var peer: String
    public var authority: String?

    public init(_ method: String, _ path: String, body: [UInt8] = [], peer: String, authority: String? = nil) {
        self.method = method
        self.path = path
        self.body = body
        self.peer = peer
        self.authority = authority
    }
}

/// The answer: status, body and the headers eSCL uses.
public struct ShareReply: Equatable, Sendable {
    public var status: Int
    public var contentType: String?
    public var body: [UInt8]?
    public var location: String?
    public var retryAfterSeconds: Int?

    public init(_ status: Int, contentType: String? = nil, body: [UInt8]? = nil, location: String? = nil, retryAfterSeconds: Int? = nil) {
        self.status = status
        self.contentType = contentType
        self.body = body
        self.location = location
        self.retryAfterSeconds = retryAfterSeconds
    }

    public static func empty(_ status: Int, retryAfter: Int? = nil) -> ShareReply { ShareReply(status, retryAfterSeconds: retryAfter) }
}

/// How much one shared scanner takes on (roadmap 3.1: bounded counts, jobs that expire). Tests shorten the times.
public struct ShareLimits: Sendable {
    /// Jobs waiting behind the one scanning; one more gets 503 (try later).
    public var maxQueued = 2
    /// Jobs kept at all (finished ones are forgotten first).
    public var maxJobs = 16
    /// Jobs one device may have waiting or scanning.
    public var maxJobsPerPeer = 2
    /// A job nobody asks about for this long is cancelled (the scan stops, its pages are dropped).
    public var idleLimit: TimeInterval = 60
    /// A job is cancelled after this long whatever happens.
    public var maxJobLife: TimeInterval = 30 * 60
    /// A finished job is listed this long, then forgotten.
    public var keepFinished: TimeInterval = 5 * 60
    /// How long NextDocument waits for a page before answering 503 (the client asks again).
    public var longPoll: Duration = .seconds(90)
    /// Pages scanned ahead of the client's reading (each held in memory); the scanner waits past that.
    public var pageBuffer = 2

    public init(maxQueued: Int = 2, maxJobs: Int = 16, maxJobsPerPeer: Int = 2, idleLimit: TimeInterval = 60, maxJobLife: TimeInterval = 30 * 60,
                keepFinished: TimeInterval = 5 * 60, longPoll: Duration = .seconds(90), pageBuffer: Int = 2) {
        self.maxQueued = maxQueued
        self.maxJobs = maxJobs
        self.maxJobsPerPeer = maxJobsPerPeer
        self.idleLimit = idleLimit
        self.maxJobLife = maxJobLife
        self.keepFinished = keepFinished
        self.longPoll = longPoll
        self.pageBuffer = pageBuffer
    }
}

/// A scanner of this Mac as an eSCL server (roadmap 3.1; the Windows Core's `SharedScanner`): the documents and jobs a
/// client (an iPhone's scan app, a Mac's Image Capture, sane-airscan, another Inkvolt Print) asks for, without the HTTP
/// server around it (PrintMac's `NetworkShareHost`, through `PhoneHttp`). Every request comes from a device on the network
/// and is read as hostile (`ShareXml.readSettings`); nothing in a request names a file, a path on this Mac or another
/// scanner. One scan at a time, a few waiting (`ShareLimits`), each job reachable only by the device that started it,
/// scanned pages handed out as JPEG (or a PDF of each) exactly as the scanner gave them. Jobs nobody reads expire. `close`
/// cancels every job at once. **Mac difference:** ScannerStatus never says the feeder's state (ImageCaptureCore tells it
/// only with the feeder selected, which a status poll mustn't change), as a scanner that can't tell leaves it out.
public final class SharedScanner: @unchecked Sendable {
    public static let root = "/eSCL/"
    private static let xml = "text/xml"

    public let identity: ShareIdentity
    private let scanner: any ScanDevice
    private let caps: ScannerCapabilities
    private let limits: ShareLimits
    private let now: @Sendable () -> Date
    private let busyElsewhere: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void
    private let capabilitiesDocument: [UInt8]
    private let scanning = AsyncGate()
    private let lock = NSLock()
    private var jobs: [Job] = []
    private var closed = false
    private var released = 0
    private var sweeper: Task<Void, Never>?

    /// - Parameters:
    ///   - now: the clock jobs expire by (tests move it by hand; the sweep also runs on each request).
    ///   - busyElsewhere: true while this app scans with the scanner itself (a job from here then waits: 503).
    ///   - log: told when a job starts and how it ends: no address or other detail of the device that asked.
    public init(_ scanner: any ScanDevice, _ caps: ScannerCapabilities, _ identity: ShareIdentity, limits: ShareLimits = ShareLimits(),
                now: @escaping @Sendable () -> Date = { Date() }, busyElsewhere: @escaping @Sendable () -> Bool = { false },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.scanner = scanner
        self.caps = caps
        self.identity = identity
        self.limits = limits
        self.now = now
        self.busyElsewhere = busyElsewhere
        self.log = log
        capabilitiesDocument = ShareXml.capabilities(caps, identity)
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self?.sweep()
            }
        }
    }

    deinit { sweeper?.cancel() }

    /// Jobs waiting or scanning now.
    public var activeJobs: Int { lock.withLock { jobs.filter(\.isActive).count } }

    /// Jobs kept now (active and recently finished).
    public var keptJobs: Int { lock.withLock { jobs.count } }

    /// Jobs forgotten whose scan is over too (nothing of them left running): for tests.
    var releasedJobs: Int { lock.withLock { released } }

    private var isClosed: Bool { lock.withLock { closed } }

    /// Whether a request for the job `id` is under way now: for tests.
    func jobAsked(_ id: String) -> Bool { lock.withLock { jobs.first { $0.id == id.lowercased() }?.isAsked ?? false } }

    public func handle(_ request: ShareRequest) async -> ShareReply {
        if isClosed { return .empty(503) }
        sweep()
        guard request.path.hasPrefix(Self.root) else { return .empty(404) }
        var rest = request.path.dropFirst(Self.root.count)
        while rest.hasSuffix("/") { rest = rest.dropLast() }
        let parts = rest.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let method = request.method
        switch parts.count {
        case 1 where parts[0] == "ScannerCapabilities":
            return method == "GET" ? ShareReply(200, contentType: Self.xml, body: capabilitiesDocument) : .empty(405)
        case 1 where parts[0] == "ScannerStatus":
            return method == "GET" ? ShareReply(200, contentType: Self.xml, body: status(request.peer)) : .empty(405)
        case 1 where parts[0] == "ScanJobs":
            return method == "POST" ? create(request) : .empty(405)
        case 2 where parts[0] == "ScanJobs":
            return method == "DELETE" ? delete(parts[1], request.peer) : .empty(405)
        case 3 where parts[0] == "ScanJobs" && parts[2] == "NextDocument":
            return method == "GET" ? await nextDocument(parts[1], request.peer) : .empty(405)
        case 3 where parts[0] == "ScanJobs" && parts[2] == "ScanImageInfo":
            return method == "GET" ? imageInfo(parts[1], request.peer) : .empty(405)
        default:
            return .empty(404)
        }
    }

    private func status(_ peer: String) -> [UInt8] {
        let at = now()
        let (scanning, lines): (Bool, [ShareXml.JobLine]) = lock.withLock {
            let mine = jobs.filter { $0.isFrom(peer) }
            for job in mine { job.touch(at) } // a device polling its jobs' status is still waiting for them
            return (jobs.contains { $0.state == "Processing" }, mine.map { $0.line(at) })
        }
        return ShareXml.status(scanning || busyElsewhere() ? "Processing" : "Idle", adfState: nil, lines)
    }

    private func create(_ request: ShareRequest) -> ShareReply {
        let settings: ShareScanSettings
        do {
            settings = try ShareXml.readSettings(request.body, caps)
        } catch let refused as ShareRequestError {
            return .empty(refused.status)
        } catch {
            return .empty(400)
        }
        let at = now()
        enum Created { case job(Job), busy(Int), closed }
        let created: Created = lock.withLock {
            if closed { return .closed }
            let active = jobs.filter(\.isActive).count
            if active > limits.maxQueued || jobs.filter({ $0.isActive && $0.isFrom(request.peer) }).count >= limits.maxJobsPerPeer { return .busy(10) }
            if active == 0 && busyElsewhere() { return .busy(5) } // this Mac scans with it now
            while jobs.count >= limits.maxJobs, let old = jobs.first(where: { !$0.isActive }) { forget(old) }
            if jobs.count >= limits.maxJobs { return .busy(10) }
            let job = Job(owner: request.peer, settings: settings, at: at, buffer: limits.pageBuffer)
            jobs.append(job)
            return .job(job)
        }
        let job: Job
        switch created {
        case .closed: return .empty(503)
        case .busy(let seconds): return .empty(503, retryAfter: seconds)
        case .job(let j): job = j
        }
        log("Shared scanner: a device on the network started a scan (\(settings.request.source), \(settings.request.resolution) dpi, \(settings.format)).")
        job.start(Task { [weak self] in
            guard let self else { return job.end("Canceled", "JobCanceledByUser", Date()) }
            await self.run(job)
        })
        let location = request.authority.flatMap { Self.isPlainAuthority($0) ? "https://\($0)\(job.path)" : nil } ?? job.path
        return ShareReply(201, location: location)
    }

    /// A host and port as a client sends them: letters, digits, dots, dashes, colons and an IPv6 literal's brackets.
    private static func isPlainAuthority(_ host: String) -> Bool {
        (1...255).contains(host.utf8.count) && host.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || ".-:[]%".contains($0)) }
    }

    private func run(_ job: Job) async {
        var entered = false
        defer {
            if entered { scanning.leave() }
            runEnded(job)
        }
        do {
            try await scanning.enter()
            entered = true
            job.processing()
            let request = job.settings.request
            let dpi = caps.input(for: request.source).map { EsclXml.resolution(request, $0) } ?? request.resolution
            for try await page in scanner.scan(request) {
                if Task.isCancelled { break }
                let info = Self.info(page)
                let document = job.settings.format == ShareXml.pdf ? try PdfWriter.write([PdfWriter.Page(page, dpi: dpi)]) : page
                guard await job.pages.write(SharedPage(document: document, width: info.0, height: info.1, components: info.2)) else { break }
                job.wrote()
            }
            if Task.isCancelled || job.isStopped { throw CancellationError() }
            job.end("Completed", nil, now())
        } catch is CancellationError {
            job.end("Canceled", "JobCanceledByUser", now())
        } catch let error as ScanError {
            job.end("Aborted", "AbortedBySystem", now())
            log("Shared scanner: the scan stopped: \(error.description)")
        } catch {
            job.end("Aborted", "AbortedBySystem", now())
            log("Shared scanner: the scan failed: \(type(of: error)): \(error)")
        }
        log("Shared scanner: the scan ended (\(job.state.lowercased()), \(job.scanned) page(s) scanned).")
    }

    /// A page's size for ScanImageInfo; zero when its header doesn't say (the page goes out as the scanner gave it all the
    /// same).
    private static func info(_ jpeg: [UInt8]) -> (Int, Int, Int) {
        guard let i = try? PdfWriter.jpegInfo(jpeg) else { return (0, 0, 3) }
        return (i.width, i.height, i.components)
    }

    private func nextDocument(_ id: String, _ peer: String) async -> ShareReply {
        guard let job = find(id, peer) else { return .empty(404) }
        guard job.reading.tryEnter() else { return .empty(503, retryAfter: 1) } // one page asked at a time
        // While the device waits here (a long poll, or a slow page at a high resolution), the job counts as asked about.
        job.asking(true, now())
        defer {
            job.asking(false, now())
            job.reading.leave()
        }
        enum Waited: Sendable { case page(SharedPage), nothing }
        let longPoll = limits.longPoll
        let pages = job.pages
        let results = await withTaskGroup(of: Waited.self) { group -> [Waited] in
            group.addTask { await pages.read().map(Waited.page) ?? .nothing }
            group.addTask {
                try? await Task.sleep(for: longPoll)
                return .nothing
            }
            var all: [Waited] = []
            if let first = await group.next() { all.append(first) }
            group.cancelAll()
            for await rest in group { all.append(rest) } // a page handed over as the time ran out is still this answer
            return all
        }
        for case .page(let page) in results {
            job.delivered(page)
            return ShareReply(200, contentType: job.settings.format, body: page.document)
        }
        if Task.isCancelled { return .empty(503, retryAfter: 2) } // the device went away, or the share stopped
        // No more pages: the end of the job, or (nothing sent and it failed) the scan couldn't run.
        guard pages.isFinished && pages.count == 0 else { return .empty(503, retryAfter: 2) } // still scanning: ask again
        return .empty(job.state == "Aborted" && job.images == 0 ? 409 : 404)
    }

    private func imageInfo(_ id: String, _ peer: String) -> ShareReply {
        guard let job = find(id, peer), let last = job.lastImage else { return .empty(404) }
        job.touch(now())
        return ShareReply(200, contentType: Self.xml, body: ShareXml.imageInfo(job.path, job.uuid, width: last.width, height: last.height,
                                                                               components: last.components))
    }

    private func delete(_ id: String, _ peer: String) -> ShareReply {
        guard let job = find(id, peer) else { return .empty(404) }
        job.stop()
        return .empty(200)
    }

    /// A job's id is its UUID's 32 hex digits (.NET's "N"), and only its device finds it.
    private func find(_ id: String, _ peer: String) -> Job? {
        guard id.count == 32, id.allSatisfy(\.isHexDigit) else { return nil }
        let key = id.lowercased()
        return lock.withLock { jobs.first { $0.id == key && $0.isFrom(peer) } }
    }

    /// Cancels jobs nobody asks about (no request for them under way, none for `ShareLimits.idleLimit`) and those past
    /// `ShareLimits.maxJobLife`, and forgets finished ones; runs every few seconds and on each request.
    func sweep() {
        let at = now()
        let cancel: [Job] = lock.withLock {
            for old in jobs where !old.isActive {
                if let ended = old.ended, at.timeIntervalSince(ended) >= limits.keepFinished { forget(old) }
            }
            return jobs.filter { j in
                !j.isStopped && (at.timeIntervalSince(j.created) >= limits.maxJobLife
                    || ((j.isActive || j.hasUnread) && !j.isAsked && at.timeIntervalSince(j.touched) >= limits.idleLimit))
            }
        }
        for job in cancel {
            job.stop()
            job.dropPages()
        }
    }

    /// Under the lock.
    private func forget(_ job: Job) {
        jobs.removeAll { $0 === job }
        job.dropPages()
        job.stop()
        if job.markForgotten() { released += 1 }
    }

    private func runEnded(_ job: Job) {
        lock.withLock {
            if job.markRunEnded() { released += 1 }
        }
    }

    /// Stops: every job cancelled and its pages dropped; any later request is answered 503.
    public func close() {
        let first: Bool = lock.withLock {
            if closed { return false }
            closed = true
            for job in jobs { forget(job) }
            return true
        }
        guard first else { return }
        sweeper?.cancel()
    }
}

/// One page of a shared scan as it goes out: the document (the JPEG, or a PDF of it) and the JPEG's size.
struct SharedPage: Sendable {
    var document: [UInt8]
    var width: Int, height: Int, components: Int
}

/// One job of a shared scanner. Thread-safe.
private final class Job: @unchecked Sendable {
    let uuid = UUID()
    let id: String
    let path: String
    let owner: String
    let settings: ShareScanSettings
    let created: Date
    let pages: BoundedChannel<SharedPage>
    let reading = AsyncGate()
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false
    private var currentState = "Pending"
    private var reason: String?
    private var touchedAt: Date
    private var endedAt: Date?
    private var imagesSent = 0, scannedPages = 0, askingNow = 0
    private var last: (width: Int, height: Int, components: Int)?
    private var forgotten = false, runOver = false, released = false

    init(owner: String, settings: ShareScanSettings, at: Date, buffer: Int) {
        id = uuid.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        path = SharedScanner.root + "ScanJobs/" + id
        self.owner = SharePeers.normal(owner)
        self.settings = settings
        created = at
        touchedAt = at
        pages = BoundedChannel(capacity: max(buffer, 1))
    }

    var state: String { lock.withLock { currentState } }
    var isActive: Bool { lock.withLock { currentState == "Pending" || currentState == "Processing" } }
    var ended: Date? { lock.withLock { endedAt } }
    var images: Int { lock.withLock { imagesSent } }
    var scanned: Int { lock.withLock { scannedPages } }
    var touched: Date { lock.withLock { touchedAt } }
    var hasUnread: Bool { pages.count > 0 }
    var isStopped: Bool { lock.withLock { stopped } }
    /// A request for this job is under way (a NextDocument long poll): it isn't idle, however long that takes.
    var isAsked: Bool { lock.withLock { askingNow > 0 } }
    var lastImage: (width: Int, height: Int, components: Int)? { lock.withLock { last } }

    func isFrom(_ peer: String) -> Bool { SharePeers.normal(peer) == owner }

    /// The job's scan; one stopped before it got its task is cancelled as it gets it.
    func start(_ run: Task<Void, Never>) {
        let cancel: Bool = lock.withLock {
            task = run
            return stopped
        }
        if cancel { run.cancel() }
    }

    func touch(_ at: Date) { lock.withLock { touchedAt = at } }

    func asking(_ starts: Bool, _ at: Date) {
        lock.withLock {
            askingNow += starts ? 1 : -1
            touchedAt = at
        }
    }

    /// Cancels the scan.
    func stop() {
        let run: Task<Void, Never>? = lock.withLock {
            stopped = true
            return task
        }
        run?.cancel()
        pages.finish()
    }

    func processing() { lock.withLock { if currentState == "Pending" { currentState = "Processing" } } }

    func wrote() { lock.withLock { scannedPages += 1 } }

    func delivered(_ page: SharedPage) {
        lock.withLock {
            imagesSent += 1
            last = (page.width, page.height, page.components)
        }
    }

    func end(_ state: String, _ why: String?, _ at: Date) {
        lock.withLock {
            currentState = state
            reason = why
            endedAt = at
        }
        pages.finish()
    }

    /// Unread pages let go (a cancelled or forgotten job's).
    func dropPages() {
        pages.finish()
        while pages.tryRead() != nil {}
    }

    /// No longer listed; true the first time both this and its run's end have happened.
    func markForgotten() -> Bool {
        lock.withLock {
            forgotten = true
            return releaseIfDone()
        }
    }

    func markRunEnded() -> Bool {
        lock.withLock {
            runOver = true
            return releaseIfDone()
        }
    }

    /// Under the lock.
    private func releaseIfDone() -> Bool {
        guard forgotten && runOver && !released else { return false }
        released = true
        task = nil
        return true
    }

    func line(_ at: Date) -> ShareXml.JobLine {
        lock.withLock {
            ShareXml.JobLine(path: path, uuid: uuid, state: currentState, ageSeconds: Int(max(0, min(at.timeIntervalSince(created), Double(Int32.max)))),
                             imagesCompleted: imagesSent, reason: reason)
        }
    }
}
