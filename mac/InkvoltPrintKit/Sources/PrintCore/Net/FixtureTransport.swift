import Foundation
import Synchronization

/// Offline stand-in for a printer's web server: answers requests from device documents written from the specs and never
/// opens a socket. Used by demo mode and the tests. A request path maps to a document name by replacing `/` with `_` and
/// adding `.xml` when there is no extension: `/DevMgmt/ProductStatusDyn.xml` → `DevMgmt_ProductStatusDyn.xml`,
/// `/eSCL/ScannerCapabilities` → `eSCL_ScannerCapabilities.xml`; HP CDM's `/cdm/...` → `cdm_….json`. An IPP
/// Get-Printer-Attributes request to `/ipp/print` is answered from `ipp_print.ipp.txt` (`IppText`), and so is
/// Identify-Printer when that document lists it. Writes (PUT, LEDM POSTs) are accepted and forgotten. Anything without a
/// document is 404.
public final class FixtureTransport: HttpTransport {
    /// Address shown for the demo printer: RFC 5737 documentation range, never a real device.
    public static let demoHost = "192.0.2.10"

    private static let jobPath = "/eSCL/ScanJobs/demo-1"

    private let document: @Sendable (String) -> [UInt8]?
    private let scanPage: (@Sendable () -> [UInt8])?
    private let scanArea: (@Sendable (Int, Int) -> [UInt8])?
    private let feederBatch: (@Sendable () -> [[UInt8]]?)?
    private let state = Mutex<(pagesLeft: Int, area: (width: Int, height: Int), batch: [[UInt8]])>((0, (2550, 3300), []))

    /// - Parameters:
    ///   - document: document name → bytes, or nil when there is none.
    ///   - scanPage: the JPEG returned for each eSCL scan job (one page); nil: scanning fails with 404.
    ///   - scanArea: instead of `scanPage`, the JPEG for the job's scan region (width, height in 1/300 in).
    ///   - feederBatch: for a feeder job, the pages the feeder holds (served in turn), or nil for one page as usual.
    public init(document: @escaping @Sendable (String) -> [UInt8]?, scanPage: (@Sendable () -> [UInt8])? = nil,
                scanArea: (@Sendable (Int, Int) -> [UInt8])? = nil, feederBatch: (@Sendable () -> [[UInt8]]?)? = nil) {
        self.document = document
        self.scanPage = scanPage
        self.scanArea = scanArea
        self.feederBatch = feederBatch
    }

    private var canScan: Bool { scanPage != nil || scanArea != nil }

    /// `/ipp/print` → `ipp_print.ipp.txt`.
    public static func ippDocumentName(_ path: String) -> String { trimmed(path).replacingOccurrences(of: "/", with: "_") + ".ipp.txt" }

    /// `/DevMgmt/ProductStatusDyn.xml` → `DevMgmt_ProductStatusDyn.xml`; HP CDM's JSON (`/cdm/...`) → `cdm_….json`.
    public static func documentName(_ path: String) -> String {
        let name = trimmed(path).replacingOccurrences(of: "/", with: "_")
        // As .NET's Path.HasExtension: a dot that isn't the last character.
        if let dot = name.lastIndex(of: "."), name.index(after: dot) != name.endIndex { return name }
        return name + (path.hasPrefix("/cdm/") ? ".json" : ".xml")
    }

    private static func trimmed(_ path: String) -> String { path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        let path = request.url.path
        let method = request.method
        let contentType = request.header("Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }

        if method == "GET" && path.hasSuffix("/EventTable.xml") && request.header("If-None-Match") != nil {
            // LEDM long poll: nothing ever changes here, so hold the request like an idle printer, then 304.
            let query = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems
            let deciseconds = query?.first { $0.name == "timeout" }?.value.flatMap { Int($0) }
            let wait = min(max((deciseconds.map { $0 * 100 }) ?? 60_000, 1_000), 600_000)
            try await Task.sleep(for: .milliseconds(wait))
            return HttpResponse(status: 304)
        }

        if method == "POST" && path.hasSuffix("/ScanJobs") && canScan {
            let settings = String(decoding: request.body ?? [], as: UTF8.self)
            let pages = settings.contains(">Feeder<") ? feederBatch?() : nil
            state.withLock { s in
                if !settings.isEmpty { s.area = Self.region(settings) ?? s.area }
                s.batch = pages ?? []
                s.pagesLeft = s.batch.isEmpty ? 1 : 0
            }
            return HttpResponse(status: 201, headers: ["Location": Self.jobPath])
        }
        if method == "GET" && path == Self.jobPath + "/NextDocument" {
            enum Next { case batch([UInt8]), one((width: Int, height: Int)), none }
            let next: Next = state.withLock { s in
                if !s.batch.isEmpty { return .batch(s.batch.removeFirst()) }
                if canScan && s.pagesLeft == 1 {
                    s.pagesLeft = 0
                    return .one(s.area)
                }
                return .none
            }
            switch next {
            case .batch(let page): return HttpResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: page)
            case .one(let area):
                let page = scanArea?(area.width, area.height) ?? scanPage!()
                return HttpResponse(status: 200, headers: ["Content-Type": "image/jpeg"], body: page)
            case .none: return HttpResponse(status: 404)
            }
        }
        if method == "POST" && contentType == "application/ipp" {
            guard let text = document(Self.ippDocumentName(path)) else { return HttpResponse(status: 404) }
            let (operation, id) = try IppCodec.readRequestHeader(request.body ?? [])
            let attributes = try IppText.parse(String(decoding: text, as: UTF8.self))
            // Get-Printer-Attributes is answered from the document, and Identify-Printer (a no-op here) when the document's
            // operations-supported lists it; anything else gets server-error-operation-not-supported.
            let identify = operation == IppCodec.identifyPrinter
                && attributes.contains { $0.name == "operations-supported" && $0.value == String(IppCodec.identifyPrinter) }
            let body = operation == IppCodec.getPrinterAttributes ? IppCodec.encodeResponse(status: 0, requestId: id, attributes)
                : identify ? IppCodec.encodeResponse(status: 0, requestId: id, [])
                : IppCodec.encodeResponse(status: 0x0501, requestId: id, [])
            return HttpResponse(status: 200, headers: ["Content-Type": "application/ipp"], body: body)
        }
        // LEDM maintenance (internal print jobs, alignment): accepted and forgotten, like settings writes. Nothing prints.
        if method == "POST" && contentType == "text/xml" && !path.hasSuffix("/ScanJobs") { return HttpResponse(status: 201) }
        if method == "DELETE" { return HttpResponse(status: 200) }
        // Settings writes are accepted and forgotten: the demo printer always reads back its own settings.
        if method == "PUT" { return HttpResponse(status: 200) }

        if method == "GET", let bytes = document(Self.documentName(path)) {
            var headers = ["Content-Type": Self.documentName(path).hasSuffix(".json") ? "application/json" : "text/xml"]
            if path.hasSuffix("/EventTable.xml") { headers["ETag"] = "1-1" }
            return HttpResponse(status: 200, headers: headers, body: bytes)
        }
        return HttpResponse(status: 404)
    }

    /// The ScanSettings' region (Width, Height); nil if it can't be read.
    private static func region(_ settings: String) -> (width: Int, height: Int)? {
        guard let region = try? DeviceXml.load(settings).all("ScanRegion").first,
              let w = region.kidValue("Width").asInt, let h = region.kidValue("Height").asInt, w > 0, h > 0 else { return nil }
        return (w, h)
    }
}

/// Several offline printers behind one transport (demo mode, tests): each request goes to the transport for its host;
/// other hosts don't answer (a connection failure, like a printer that's switched off).
public struct HostRouter: HttpTransport {
    private let hosts: [String: any HttpTransport]

    public init(_ hosts: [String: any HttpTransport]) {
        self.hosts = Dictionary(hosts.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    public func send(_ request: HttpRequest) async throws -> HttpResponse {
        guard let host = request.url.host?.lowercased(), let transport = hosts[host] else {
            throw DeviceNetworkError.failed("No demo printer at \(request.url.host ?? "?")")
        }
        return try await transport.send(request)
    }
}
