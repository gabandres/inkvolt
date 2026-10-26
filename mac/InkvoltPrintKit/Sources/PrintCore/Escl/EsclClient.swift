import Foundation
import Synchronization

/// Why a scan can't go on, in plain words for the user.
public struct ScanError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// eSCL (AirScan / Mopria scan) client. `root` is the eSCL base, e.g. `http://host/eSCL/`.
public final class EsclClient: Sendable {
    private static let pageTimeout: Duration = .seconds(180)

    public let http: DeviceHttp
    public let root: URL
    private let cache = Mutex<(caps: ScannerCapabilities?, quirks: EsclQuirks)>((nil, .none))

    public init(_ http: DeviceHttp, root: URL) {
        self.http = http
        self.root = root.absoluteString.hasSuffix("/") ? root : URL(string: root.absoluteString + "/")!
    }

    private func url(_ path: String) -> URL { URL(string: path, relativeTo: root)!.absoluteURL }

    public func capabilities() async throws -> ScannerCapabilities? {
        if let caps = cache.withLock({ $0.caps }) { return caps }
        guard let bytes = try await getBytesOrNil(url("ScannerCapabilities")) else { return nil }
        let caps = ScannerCapabilities.parse(try DeviceXml.load(bytes))
        cache.withLock { $0 = (caps, EsclQuirks.of(caps)) }
        return caps
    }

    public func status() async throws -> ScannerStatus {
        guard let bytes = try await getBytesOrNil(url("ScannerStatus")) else { throw ScanError("Scanner status not available") }
        return ScannerStatus.parse(try DeviceXml.load(bytes))
    }

    /// Runs one scan job and yields each page as JPEG bytes. Platen jobs return one page; feeder jobs return pages until the
    /// device answers 404 (feeder empty). Stopping early (or an error) deletes the job on the device.
    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runScan(request) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runScan(_ request: ScanRequest, _ yield: @Sendable ([UInt8]) -> Void) async throws {
        guard let caps = try await capabilities() else { throw ScanError("Not an eSCL scanner") }
        if caps.input(for: request.source)?.offersJpeg == false {
            throw ScanError("This scanner doesn't send JPEG pages from this source, which Inkvolt Print needs.")
        }
        if let problem = try await status().problem(feeder: request.source != .platen) { throw ScanError(problem) }
        guard let settings = EsclXml.buildScanSettings(request, caps) else { throw ScanError("The scanner has no such source.") }

        let job = try await createJob(settings)
        var done = false
        defer {
            if !done { Task { await self.tryDelete(job) } }
        }
        let quirks = cache.withLock { $0.quirks }
        let clock = ContinuousClock()
        var lastLoad: Duration = .zero
        var page = 0
        while true {
            if page > 0 && quirks.nextLoadDelay { try await Task.sleep(for: EsclQuirks.nextLoadWait(lastLoad)) }
            let started = clock.now
            let bytes = try await nextDocument(job)
            lastLoad = clock.now - started
            guard let bytes else { break }
            yield(JpegFix.patchZeroHeight(bytes))
            if request.source == .platen { break }
            page += 1
        }
        done = true
    }

    private func createJob(_ settings: String) async throws -> URL {
        var attempt = 0
        while true {
            let target = url("ScanJobs")
            let response: HttpResponse
            do {
                response = try await http.send(request("POST", target, body: Array(settings.utf8), contentType: "text/xml", timeout: .seconds(15)))
            } catch DeviceNetworkError.timedOut {
                // The scanner may have created the job without answering; delete it so the next scan isn't "busy".
                await deleteRecentActiveJobs()
                throw ScanError("The scanner didn't answer in time. Try again.")
            }
            if response.status == 503 && attempt < 10 {
                attempt += 1
                try await Task.sleep(for: .seconds(1)) // warming up / busy
                continue
            }
            if response.status == 409 { throw ScanError("Scanner is busy with another job.") }
            try DeviceHttp.ensureSuccess(response, "POST", target)
            guard let location = response.header("Location"), let to = URL(string: location, relativeTo: root) else {
                throw ScanError("Scanner did not return a job location.")
            }
            // Resolve only the path against our base: Location often names the host by its .local name or another port, and
            // a relative "//other-host/x" can't move the job to another host.
            var path = to.absoluteURL.path
            while path.hasSuffix("/") { path.removeLast() }
            return url(path + "/")
        }
    }

    private func nextDocument(_ job: URL) async throws -> [UInt8]? {
        var attempt = 0
        while true {
            let target = URL(string: "NextDocument", relativeTo: job)!.absoluteURL
            let response = try await http.send(request("GET", target, timeout: Self.pageTimeout))
            switch response.status {
            case 404, 410:
                return nil
            case 503 where attempt < 60:
                attempt += 1
                try await Task.sleep(for: .milliseconds(500))
                continue
            default:
                try DeviceHttp.ensureSuccess(response, "GET", target)
                return response.body
            }
        }
    }

    /// Deletes jobs the scanner reports as just-created and still active (our orphan after a timeout).
    private func deleteRecentActiveJobs() async {
        guard let status = try? await status() else { return }
        // Only jobs the scanner says are seconds old: never a scan another computer started earlier.
        for job in status.jobs where (job.state == "Pending" || job.state == "Processing") && (job.ageSeconds ?? .max) < 60 {
            let path = URL(string: job.uri).flatMap { $0.scheme == nil ? nil : $0.path } ?? job.uri
            if let target = URL(string: path, relativeTo: root) { await tryDelete(target.absoluteURL) }
        }
    }

    private func tryDelete(_ job: URL) async {
        _ = try? await http.send(request("DELETE", job, timeout: .seconds(5))) // best effort; the device times stale jobs out
    }

    /// A request to the scanner, with the port in the Host header for scanners that need it (`EsclQuirks`).
    private func request(_ method: String, _ url: URL, body: [UInt8]? = nil, contentType: String? = nil,
                         timeout: Duration = DeviceHttp.defaultTimeout) -> HttpRequest {
        var r = HttpRequest(method, url, body: body, timeout: timeout)
        if let contentType { r.headers["Content-Type"] = contentType }
        if cache.withLock({ $0.quirks.portInHost }), let host = url.host {
            r.headers["Host"] = "\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
        }
        return r
    }

    private func getBytesOrNil(_ url: URL) async throws -> [UInt8]? {
        let response = try await http.send(request("GET", url))
        if response.status == 404 { return nil }
        try DeviceHttp.ensureSuccess(response, "GET", url)
        return response.body
    }
}
