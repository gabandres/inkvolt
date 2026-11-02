import Foundation
import Synchronization

/// How a recording is made (`PrinterRecorder.record`).
public struct RecordOptions: Sendable {
    /// The network to the printer: URLSession in PrintMac; a fixture transport in tests. PrintCore never opens a socket.
    public var transport: any HttpTransport
    /// Where SNMP goes (UDP in PrintMac, or a made-up agent in tests); nil: SNMP isn't recorded.
    public var snmp: (any SnmpTransport)?
    public var community = SnmpClient.defaultCommunity
    /// eSCL and IPP addresses from DNS-SD, when the printer's aren't the usual ones (as `PrinterConnection.open`).
    public var esclHint: URL?
    public var ippHint: URL?
    /// Also one glass page and, when the feeder holds paper, its pages (kept as JPEG, as scanned: never scrubbed).
    public var scan = false
    /// The address the recording calls the printer by (`FixtureScrubber.placeholderHost`).
    public var placeholderHost = FixtureScrubber.defaultPlaceholderHost
    /// This Mac's user and computer names, taken out wherever they appear; nil: `Diagnostics.Identity.current`.
    public var who: Diagnostics.Identity?

    public init(transport: any HttpTransport, snmp: (any SnmpTransport)? = nil) {
        self.transport = transport
        self.snmp = snmp
    }
}

/// What a recording holds: the files written, what answered, and how many identifiers of each kind were replaced.
public struct RecordResult: Sendable {
    public var files: [String]
    public var interfaces: [String]
    public var model: String?
    public var scrubbed: [String: Int]
    public var notKept: [String]
}

/// A recording that couldn't be made: nothing answered, or a write it refused to send.
public struct RecordingError: Error, CustomStringConvertible {
    public let description: String
}

/// `record <address> <folder>` (print/ROADMAP.md 1.2; the Windows app's `PrinterRecorder`): asks a printer everything the
/// app's readers ask (the probe, a printer reading, the UUID check, LEDM's settings, firmware and maintenance documents,
/// CDM's, eSCL's capabilities and status, IPP's Get-Printer-Attributes, the SNMP objects the Printer MIB reader walks) and
/// writes each reply in the layout the tests' fixtures use, so `FixtureTransport` and `SnmpAgent` serve the folder
/// unchanged: `DevMgmt_ProductStatusDyn.xml`, `cdm_system_v1_identity.json`, `eSCL_ScannerCapabilities.xml`,
/// `ipp_print.ipp.txt` (`IppText`), `snmp.txt` (snmpwalk -On). Every document goes through `FixtureScrubber` first. Read
/// only: the recording transport lets GETs and IPP Get-Printer-Attributes through and nothing else (with `scan`, the eSCL
/// scan job too); no credentials are ever sent. Each request's time and status are kept in `notesFile`. Mac difference: a
/// reply is held whole by the transport (PrintMac's URLSession transport bounds it), where Windows reads it within
/// `DeviceHttp`'s limit here.
public enum PrinterRecorder {
    /// The recording's notes: what was asked, how long each reply took, what wasn't kept. Not a fixture document.
    public static let notesFile = "recording.tsv"

    /// The SNMP objects, as `SnmpAgent.parseWalk` reads them.
    public static let snmpFile = "snmp.txt"

    /// Subtrees walked over SNMP: system, the Host Resources device and printer tables, the Printer MIB.
    static let snmpSubtrees: [Oid] = ["1.3.6.1.2.1.1", "1.3.6.1.2.1.25.3.2", "1.3.6.1.2.1.25.3.5", "1.3.6.1.2.1.43"]

    private static let maxSnmpObjects = 4000
    private static let snmpWalkLimit: Duration = .seconds(60)

    /// The file a reply at this path is kept in, or nil to leave it out. A printer's discovery tree decides what gets asked
    /// for, so it also decides this name: it stays a plain name inside the folder, is a kind of file the fixtures are
    /// (nothing that runs when opened from the folder), and isn't one of the recording's own.
    static func keptName(_ path: String, ipp: Bool = false) -> String? {
        let raw = ipp ? FixtureTransport.ippDocumentName(path) : FixtureTransport.documentName(path)
        let name = String(raw.map { $0.isASCII && ($0.isLetter || $0.isNumber) || $0 == "." || $0 == "_" || $0 == "-" ? $0 : "_" })
        let ext = name.lastIndex(of: ".").map { String(name[$0...]).lowercased() } ?? ""
        guard [".xml", ".json", ".txt"].contains(ext), name.count != ext.count, name.count <= 200 else { return nil }
        let lower = name.lowercased()
        return lower == notesFile || lower == snmpFile ? nil : name
    }

    public static func record(_ host: String, to folder: URL, _ options: RecordOptions) async throws -> RecordResult {
        let capture = Capture(options.transport, scan: options.scan)
        let snmp = options.snmp.map(SnmpCapture.init)
        var notKept: [String] = []
        var scans: [(name: String, jpeg: [UInt8])] = []

        let connection = try await PrinterConnection.open(host, transport: capture, esclHint: options.esclHint, ippHint: options.ippHint, snmp: snmp)
        let probe = connection.probe
        if !probe.reachable && snmp == nil { throw RecordingError(description: "Nothing answered at \(host).") }

        _ = await quietly { try await connection.read() }
        _ = await quietly { try await connection.readUuids() }
        if let ledm = connection.ledm {
            for resource in ledmResources() { _ = await quietly { try await ledm.get(resource) } }
            _ = await quietly { try await ledm.firmwareUpdate() }
        }
        if let cdm = connection.cdm {
            for path in [CdmPaths.identity, CdmPaths.supplies, CdmPaths.systemStatus, CdmPaths.printStatus, CdmPaths.alerts] {
                guard let url = URL(string: path, relativeTo: cdm.root)?.absoluteURL else { continue }
                _ = await quietly { try await connection.http.getBytesOrNil(url) }
            }
        }
        _ = await quietly { try await MaintenanceClient(connection).detect() }
        if let scanner = connection.scanner {
            _ = await quietly { try await scanner.status() }
            if options.scan { await scan(scanner, &scans, &notKept) }
        }
        if let snmp { await walkSnmp(snmp, host, options.community) }

        // The documents, by the names FixtureTransport serves them under (any case, as on Windows).
        var documents: [String: (name: String, text: String)] = [:]
        for x in capture.exchanges {
            guard let file = x.file else { continue }
            let key = file.lowercased()
            if let had = documents[key] {
                guard let ipp = x.ipp, had.text.count < ipp.count else { continue } // the fullest attribute list
            }
            documents[key] = (file, x.ipp ?? String(decoding: x.body ?? [], as: UTF8.self))
        }
        let objects = snmp?.objects ?? []
        if let snmp, !objects.isEmpty {
            documents[snmpFile] = (snmpFile, "# \(snmp.v2cAnswered ? "SNMP v2c and v1" : "SNMP v1 only (SnmpAgent v1Only: true)"), community as recorded\n"
                + SnmpAgent.formatWalk(objects.map(readable)))
        }

        if documents.isEmpty { throw RecordingError(description: "Nothing answered at \(host).") }
        let scrubber = FixtureScrubber(host, placeholderHost: options.placeholderHost, who: options.who ?? .current)
        for (name, text) in documents.values { scrubber.learn(name, text) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var files: [String] = []
        for (name, text) in documents.values.sorted(by: { Array($0.name.utf8).lexicographicallyPrecedes(Array($1.name.utf8)) }) {
            try Data(scrubber.scrub(name, text).utf8).write(to: folder.appendingPathComponent(name))
            files.append(name)
        }
        for (name, jpeg) in scans {
            try Data(jpeg).write(to: folder.appendingPathComponent(name))
            files.append(name)
        }

        notKept += capture.exchanges.filter { $0.file == nil && $0.status != nil && $0.status != 404 && $0.kept }
            .map { "\($0.method) \($0.path): \($0.status!), not kept (FixtureTransport serves documents only)" }
        var interfaces = probe.interfaces
        if !objects.isEmpty && !interfaces.contains("SNMP") { interfaces.append("SNMP") }
        let model = probe.model ?? snmp?.model
        try Data(notes(capture, snmp, interfaces, model, scrubber, notKept).utf8).write(to: folder.appendingPathComponent(notesFile))
        files.append(notesFile)
        return RecordResult(files: files, interfaces: interfaces, model: model,
                            scrubbed: Dictionary(uniqueKeysWithValues: scrubber.counts.map { ($0.kind, $0.count) }), notKept: notKept)
    }

    /// The LEDM documents the app reads by type: status, supplies, usage, settings (with their Cap documents), events.
    private static func ledmResources() -> [String] {
        var seen = Set<String>()
        let fixed = [LedmResource.productStatusDyn, LedmResource.productConfigDyn, LedmResource.productConfigCap, LedmResource.consumableConfigDyn,
                     LedmResource.productUsageDyn, LedmResource.printConfigDyn, LedmResource.printConfigCap, LedmResource.mediaHandlingDyn,
                     LedmResource.mediaHandlingCap, LedmResource.eventTable, "ledm:hpLedmProductStatusCap", "ledm:hpLedmEventMgmtCap"]
        return (fixed + LedmSettingCatalog.all.flatMap { [$0.dynResource, $0.capResource] }).filter { seen.insert($0).inserted }
    }

    private static func scan(_ scanner: EsclClient, _ scans: inout [(name: String, jpeg: [UInt8])], _ notKept: inout [String]) async {
        guard let caps = await quietly({ try await scanner.capabilities() }) ?? nil else { return }
        do {
            if caps.platen != nil {
                for try await page in scanner.scan(ScanRequest(source: .platen, resolution: 150)) { scans.append(("scan-glass.jpg", page)) }
            }
            if caps.adf != nil, try await scanner.status().adfLoaded {
                for try await page in scanner.scan(ScanRequest(source: .adf, resolution: 150)) {
                    scans.append(("scan-feeder-\(scans.filter { $0.name.hasPrefix("scan-feeder") }.count + 1).jpg", page))
                }
            }
        } catch is CancellationError {
            return
        } catch {
            notKept.append("scan: \(error)")
        }
    }

    private static func walkSnmp(_ snmp: SnmpCapture, _ host: String, _ community: String) async {
        // As the app asks first: the probe (v2c and v1 at once). Then each subtree, one GetNext at a time.
        guard let found = await quietly({ try await SnmpPrinterClient.probe(transport: snmp, host: host, community: community) }), let printer = found else {
            return
        }
        snmp.setModel(printer.identity.model)
        _ = await quietly { try await printer.read() }
        let client = SnmpClient(transport: snmp, host: host, version: printer.identity.version, community: community)
        let started = ContinuousClock.now
        for root in snmpSubtrees {
            var at = root
            while snmp.objects.count < maxSnmpObjects && ContinuousClock.now - started < snmpWalkLimit {
                guard let next = try? await client.getNext([at]), next.count == 1, !next[0].value.isException, next[0].name.isUnder(root) else { break }
                at = next[0].name
            }
        }
    }

    /// A string the printer padded with NULs or broke over lines, as one line of text (the reader trims and splits on line
    /// breaks the same way), so it can be read and scrubbed as text; binary values stay bytes.
    private static func readable(_ vb: SnmpVarBind) -> SnmpVarBind {
        guard vb.value.tag == Ber.octetString, let bytes = vb.value.bytes, !bytes.isEmpty, let text = vb.value.text else { return vb }
        var printable = bytes.allSatisfy { $0 >= 0x20 || $0 == 0x00 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }
        // A stray control byte makes it hex, which no scrubbing reads: what holds a name or a serial, or mostly reads as text,
        // is text regardless. A MAC address stays bytes.
        printable = printable || FixtureScrubber.holdsText(vb.name.description)
            || (bytes.count >= 8 && bytes.filter { $0 >= 0x20 && $0 < 0x7F }.count * 4 >= bytes.count * 3)
        guard printable else { return vb }
        let line = text.replacingOccurrences(of: "\r\n", with: "; ").replacingOccurrences(of: "\n", with: "; ").replacingOccurrences(of: "\r", with: "; ")
            .replacingOccurrences(of: "\t", with: " ")
        return SnmpVarBind(vb.name, .string(line))
    }

    private static func notes(_ capture: Capture, _ snmp: SnmpCapture?, _ interfaces: [String], _ model: String?, _ scrubber: FixtureScrubber,
                              _ notKept: [String]) -> String {
        let day = ISO8601DateFormatter.string(from: Date(), timeZone: TimeZone(identifier: "UTC")!, formatOptions: [.withFullDate])
        let oneLine = model.map { scrubber.scrub("", $0.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")) }
        var out = "# Inkvolt Print recording, \(day): \(oneLine ?? "unknown model"); answered on \(interfaces.joined(separator: ", "))\n"
        out += "# Scrubbed (stand-ins of the same shape): "
            + (scrubber.counts.isEmpty ? "nothing found" : scrubber.counts.map { "\($0.kind) \($0.count)" }.joined(separator: ", ")) + "\n"
        out += "# Every request, in order: milliseconds, method, path, status, file it is kept in\n"
        for x in capture.exchanges {
            out += "\(x.milliseconds)\t\(x.method)\(x.getAttributes ? " Get-Printer-Attributes" : "")\t\(scrubber.scrub("", x.path))\t"
                + "\(x.status.map { String($0) } ?? x.error ?? "")\t\(x.file ?? "-")\n"
        }
        if let snmp {
            out += "\(snmp.milliseconds)\tSNMP\t\(snmp.requests) requests, \(snmp.replies) replies\t\t\(snmp.objects.isEmpty ? "-" : snmpFile)\n"
        }
        for line in notKept { out += "# " + scrubber.scrub("", line) + "\n" }
        return out
    }

    /// A read that may fail: offline, a refusal, garbage. Cancellation still ends the recording.
    private static func quietly<T>(_ read: () async throws -> T) async -> T? {
        do { return try await read() } catch { return nil }
    }

    // MARK: The recording transport

    struct Exchange: Sendable {
        var method: String
        var path: String
        var status: Int?
        var error: String?
        var milliseconds: Int
        var file: String?
        var body: [UInt8]?
        /// The IppText of a Get-Printer-Attributes reply.
        var ipp: String?
        var getAttributes = false
        /// False for scan traffic (pages and jobs), which isn't a document.
        var kept = true
    }

    /// Lets reads through and keeps each reply; refuses anything that would change the printer.
    final class Capture: HttpTransport {
        private let inner: any HttpTransport
        private let scan: Bool
        private let log = Mutex<[Exchange]>([])

        init(_ inner: any HttpTransport, scan: Bool) {
            self.inner = inner
            self.scan = scan
        }

        var exchanges: [Exchange] { log.withLock { $0 } }

        private func keep(_ x: Exchange) { log.withLock { $0.append(x) } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            let path = request.url.path
            let method = request.method
            let mediaType = request.header("Content-Type")?.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            let body = request.body ?? []
            let ipp = method == "POST" && mediaType == "application/ipp"
            let getAttributes = ipp && body.count >= 8 && (try? IppCodec.readRequestHeader(body).operation) == IppCodec.getPrinterAttributes
            let scanJob = scan && path.range(of: "/ScanJobs", options: .caseInsensitive) != nil && ["POST", "DELETE", "GET"].contains(method)
            if method != "GET" && !getAttributes && !scanJob {
                throw RecordingError(description: "A recording only reads: \(method) \(path) not sent.")
            }

            let started = ContinuousClock.now
            func elapsed() -> Int { Int((ContinuousClock.now - started) / .milliseconds(1)) }
            let response: HttpResponse
            do {
                response = try await inner.send(request)
            } catch {
                keep(Exchange(method: method, path: path, error: error as? DeviceNetworkError == .timedOut ? "timed out" : "no answer", milliseconds: elapsed()))
                throw error
            }
            let ms = elapsed()
            if scanJob {
                keep(Exchange(method: method, path: path, status: response.status, milliseconds: ms, kept: false))
                return response
            }
            var file: String?, text: String?
            let type = response.header("Content-Type") ?? ""
            if response.status == 200 && getAttributes {
                if (try? IppCodec.decode(response.body).ok) == true, let name = keptName(path, ipp: true) {
                    file = name
                    text = try? IppText.fromResponse(response.body)
                    if text == nil { file = nil }
                }
            } else if response.status == 200 && method == "GET" && !response.body.isEmpty && request.url.query == nil
                        && !type.lowercased().hasPrefix("image/") && !path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty {
                file = keptName(path)
            }
            keep(Exchange(method: method, path: path, status: response.status, milliseconds: ms, file: file, body: response.body, ipp: text,
                          getAttributes: getAttributes))
            return response
        }
    }

    /// Passes SNMP through and keeps every object a reply carried.
    final class SnmpCapture: SnmpTransport {
        private let inner: any SnmpTransport
        private let state = Mutex<(objects: [Oid: SnmpVarBind], v2c: Bool, model: String?, requests: Int, replies: Int, elapsed: Duration)>(
            ([:], false, nil, 0, 0, .zero))

        init(_ inner: any SnmpTransport) { self.inner = inner }

        var objects: [SnmpVarBind] { state.withLock { Array($0.objects.values) } }
        var v2cAnswered: Bool { state.withLock { $0.v2c } }
        var model: String? { state.withLock { $0.model } }
        var requests: Int { state.withLock { $0.requests } }
        var replies: Int { state.withLock { $0.replies } }
        var milliseconds: Int { state.withLock { Int($0.elapsed / .milliseconds(1)) } }

        func setModel(_ model: String?) { state.withLock { $0.model = model } }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            state.withLock { $0.requests += 1 }
            let started = ContinuousClock.now
            let reply = try await inner.send(request, to: host, timeout: timeout)
            let took = ContinuousClock.now - started
            state.withLock { $0.elapsed += took }
            guard let reply else { return nil }
            let message = try? SnmpMessage.decode(reply)
            state.withLock { s in
                s.replies += 1
                guard let message else { return }
                if message.version == .v2c { s.v2c = true }
                if message.errorStatus == SnmpMessage.noError {
                    for vb in message.varBinds where !vb.value.isException && vb.value.tag != Ber.null { s.objects[vb.name] = vb }
                }
            }
            return reply
        }
    }
}
