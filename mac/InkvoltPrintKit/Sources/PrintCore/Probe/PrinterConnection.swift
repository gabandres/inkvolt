import Foundation

/// Which interfaces a printer answered on. Probed once, in parallel, with short timeouts.
public struct ProbeResult: Sendable {
    public var host: String
    public var ledm: DiscoveryTree?
    public var product: ProductInfo?
    public var scanner: ScannerCapabilities?
    public var esclRoot: URL?
    public var ipp: IppResponse?

    /// The URL IPP answered on (nil when it didn't).
    public var ippEndpoint: URL?

    /// HP's newer interface (CDM) answered: a newer HP printer without LEDM. Only asked when LEDM isn't there.
    public var cdm: CdmProbe?

    /// The printer answered SNMP with the Printer MIB: asked only when neither LEDM, CDM nor IPP answered, and only when
    /// the caller passed an SNMP transport.
    public var snmp: SnmpIdentity?

    public var reachable: Bool { ledm != nil || scanner != nil || ipp != nil || cdm != nil || snmp != nil }

    public var uuid: String? {
        product?.uuid ?? scanner?.uuid ?? ipp?.str("printer-uuid").map { $0.replacingOccurrences(of: "urn:uuid:", with: "", options: .caseInsensitive) }
    }

    /// Every UUID the printer reports, one per interface (they normally agree; a scanner may have its own).
    public var reportedUuids: [String?] { [product?.uuid, cdm?.identity.uuid, scanner?.uuid, ipp?.str("printer-uuid")] }

    public var model: String? { product?.makeAndModel ?? scanner?.makeAndModel ?? ipp?.str("printer-make-and-model") ?? snmp?.model }

    /// The serial number: LEDM's or CDM's, else the Printer MIB's prtGeneralSerialNumber.
    public var serialNumber: String? { product?.serialNumber ?? snmp?.serialNumber }

    public var firmware: FirmwareInfo? { FirmwareInfo.from(product, ipp) }

    /// HP's own interfaces answered (LEDM): settings, firmware updates and usage counters work. Other printers get IPP and
    /// eSCL only.
    public var hasHpInterfaces: Bool { ledm != nil }

    /// Who made it: HP when LEDM or CDM answers, else from the make-and-model the printer reports.
    public var brand: PrinterBrand {
        hasHpInterfaces || cdm != nil ? .hp
            : PrinterBrand.detect(ipp?.str("printer-make-and-model"), scanner?.makeAndModel, scanner?.manufacturer, snmp?.model, snmp?.systemDescription)
    }

    /// IPP `printer-location`, when someone set it on the printer.
    public var location: String? {
        if let l = ipp?.str("printer-location")?.trimmingCharacters(in: .whitespacesAndNewlines), !l.isEmpty { return l }
        return snmp?.location
    }

    /// The printer's own web page: IPP `printer-more-info` when it is an http(s) page on this printer (the address comes from
    /// the network, so never another host), else nil (callers fall back to `https://host/`).
    public var webPage: URL? { ipp?.str("printer-more-info").flatMap(onThisPrinter) }

    /// IPP `printer-icons` (PWG 5100.13: 48, 128 and 512 px PNGs, in that order) on this printer, the 128 px one first (the
    /// app shows it at up to 256 px), then the larger, then the smaller.
    public var icons: [URL] {
        let icons = (ipp?.strs("printer-icons") ?? []).compactMap(onThisPrinter)
        return icons.count < 2 ? icons : Array(icons.dropFirst()) + [icons[0]]
    }

    /// An http(s) URL from the printer's replies, only when it points back at this printer (never another host).
    private func onThisPrinter(_ text: String) -> URL? {
        guard let u = URL(string: text), u.scheme == "http" || u.scheme == "https", let h = u.host,
              h.caseInsensitiveCompare(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) == .orderedSame,
              u.user == nil, u.password == nil else { return nil }
        // As .NET's Uri: the default port isn't written.
        if let port = u.port, port == (u.scheme == "https" ? 443 : 80), var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.port = nil
            return c.url
        }
        return u
    }

    public var interfaces: [String] {
        var list: [String] = []
        if ledm != nil { list.append("LEDM") }
        if ledm?.hasCdm == true || cdm != nil { list.append("CDM") }
        if scanner != nil { list.append("eSCL") }
        if ipp != nil { list.append("IPP") }
        if snmp != nil { list.append("SNMP") }
        return list
    }
}

/// Live connection to one printer: LEDM for status, supplies and settings when present, then CDM, then IPP, and SNMP for
/// a printer that has none of them; eSCL for scanning. Owns the printer's one `DeviceHttp`.
public final class PrinterConnection: Sendable {
    public let http: DeviceHttp
    public let probe: ProbeResult

    /// HP's LEDM, for what only it does: settings, firmware updates, maintenance pages.
    public let ledm: LedmClient?
    public let scanner: EsclClient?

    /// IPP, for what only it does: Identify-Printer, maintenance. Status and supplies come from `read`.
    public let ipp: IppClient?

    /// HP CDM, read only, for newer HP printers without LEDM.
    public let cdm: CdmClient?

    /// SNMP (Printer MIB), read only, for a printer without LEDM, CDM or IPP.
    let snmp: SnmpPrinterClient?
    private let reader: PrinterReader

    private init(http: DeviceHttp, probe: ProbeResult, snmp transport: (any SnmpTransport)?) {
        self.http = http
        self.probe = probe
        ledm = probe.ledm != nil ? LedmClient(http) : nil
        scanner = probe.esclRoot.map { EsclClient(http, root: $0) }
        ipp = probe.ipp != nil ? IppClient(http, endpoint: probe.ippEndpoint ?? IppClient.defaultEndpoint(http)) : nil
        cdm = probe.cdm.map { CdmClient(http, root: $0.root) }
        snmp = probe.snmp.flatMap { id in transport.map { SnmpPrinterClient(transport: $0, host: http.host, identity: id) } }
        var sources: [any ReadingSource] = []
        if let ledm { sources.append(LedmSource(client: ledm)) }
        if let cdm { sources.append(CdmSource(client: cdm)) }
        if let ipp { sources.append(IppSource(client: ipp)) }
        if let snmp { sources.append(SnmpSource(client: snmp)) }
        if let scanner { sources.append(EsclSource(client: scanner)) }
        reader = PrinterReader(sources: sources)
    }

    /// Connected over SNMP only (a printer that answered none of LEDM, CDM and IPP): no UUID, identity by serial number.
    public var overSnmp: Bool { snmp != nil }

    /// - Parameters:
    ///   - esclHint: eSCL base from DNS-SD (`rs` TXT + port), tried if `http://host/eSCL/` fails.
    ///   - transport: the network for this printer (URLSession in the app; fixtures in demo mode and tests).
    ///   - ippHint: IPP printer URL from DNS-SD (`rp` TXT + port, https for `_ipps`), tried first.
    ///   - snmp: where SNMP goes when the printer has neither LEDM, CDM nor IPP; nil: SNMP isn't tried.
    public static func open(_ host: String, transport: @escaping HttpTransportFactory, esclHint: URL? = nil, ippHint: URL? = nil,
                            pin: (any CertificatePin)? = nil, snmp: (any SnmpTransport)? = nil) async throws -> PrinterConnection {
        let http = DeviceHttp(host: host, transport: transport, pin: pin)
        return PrinterConnection(http: http, probe: try await probe(http, esclHint: esclHint, ippHint: ippHint, snmp: snmp), snmp: snmp)
    }

    /// The same network for every host (demo mode, tests).
    public static func open(_ host: String, transport: any HttpTransport, esclHint: URL? = nil, ippHint: URL? = nil,
                            pin: (any CertificatePin)? = nil, snmp: (any SnmpTransport)? = nil) async throws -> PrinterConnection {
        try await open(host, transport: { _, _ in transport }, esclHint: esclHint, ippHint: ippHint, pin: pin, snmp: snmp)
    }

    /// SNMP is asked only after LEDM, CDM and IPP all stayed silent.
    public static func probe(_ http: DeviceHttp, esclHint: URL? = nil, ippHint: URL? = nil, snmp: (any SnmpTransport)? = nil)
        async throws -> ProbeResult {
        // CDM only when the printer clearly has no LEDM (see probeLedm): an offline or waking printer costs nothing more, and a
        // printer with LEDM never gets a CDM request.
        async let ledmAndCdm = probeLedmAndCdm(http)
        async let escl = probeEscl(http, hint: esclHint)
        async let ipp = probeIpp(http, hint: ippHint)
        let (l, s, i) = await (ledmAndCdm, escl, ipp)
        try Task.checkCancellation()

        // SNMP last, and only for a printer none of the others reached.
        var snmpIdentity: SnmpIdentity?
        if l.ledm.tree == nil && l.cdm == nil && i == nil, let snmp {
            snmpIdentity = try await SnmpPrinterClient.probe(transport: snmp, host: http.host)?.identity
        }
        return ProbeResult(host: http.host, ledm: l.ledm.tree, product: l.ledm.product ?? l.cdm?.identity, scanner: s?.0, esclRoot: s?.1,
                           ipp: i?.0, ippEndpoint: i?.1, cdm: l.cdm, snmp: snmpIdentity)
    }

    private static func probeLedmAndCdm(_ http: DeviceHttp) async -> (ledm: LedmProbe, cdm: CdmProbe?) {
        let ledm = await probeLedm(http)
        return (ledm, ledm.tryCdm ? await attempt { try await CdmClient.probe(http) } : nil)
    }

    /// `http://host/eSCL/`, then the DNS-SD hint.
    private static func probeEscl(_ http: DeviceHttp, hint: URL?) async -> (ScannerCapabilities, URL)? {
        var roots = [http.http("/eSCL/")]
        if let hint, hint != roots[0] { roots.append(hint) }
        for root in roots {
            if let caps = await attempt({ try await EsclClient(http, root: root).capabilities() }) { return (caps, root) }
        }
        return nil
    }

    struct LedmProbe: Sendable {
        var tree: DiscoveryTree?
        var product: ProductInfo?
        var tryCdm: Bool
    }

    /// The DiscoveryTree and product info. `tryCdm` only when the printer clearly has no LEDM: the DiscoveryTree is 404,
    /// plain HTTP is refused, or the tree's address redirects somewhere that isn't LEDM (`/DevMgmt/`). A 5xx, 401 or any
    /// other error page, or a timeout, is an LEDM printer waking up or busy: no CDM, the connection tries again later.
    static func probeLedm(_ http: DeviceHttp) async -> LedmProbe {
        do {
            let client = LedmClient(http)
            guard let tree = try await client.tree() else { return LedmProbe(tryCdm: true) }
            return LedmProbe(tree: tree, product: try await client.productInfo(), tryCdm: false)
        } catch DeviceNetworkError.refused {
            return LedmProbe(tryCdm: true)
        } catch let error as DeviceHttpError where (300..<400).contains(error.status) {
            let to = error.location.flatMap { URL(string: $0, relativeTo: http.httpBase)?.absoluteURL }
            return LedmProbe(tryCdm: to.map { !$0.path.lowercased().hasPrefix("/devmgmt/") } ?? false)
        } catch {
            return LedmProbe(tryCdm: false)
        }
    }

    /// The whole IPP probe gets what one request gets: an offline printer costs no more.
    static let ippProbeDeadline = DeviceHttp.defaultTimeout

    /// The DNS-SD hint (only on this host) and `http://host:631/ipp/print` (IPP Everywhere's path) at the same time; the
    /// first that answers wins. When plain HTTP is refused outright, the same path over TLS: some printers only take IPPS
    /// once their HTTP is switched off. All of it within `ippProbeDeadline`.
    static func probeIpp(_ http: DeviceHttp, hint: URL?) async -> (IppResponse, URL)? {
        enum Attempt: Sendable {
            case answered(IppResponse, URL)
            case missed
            case deadline
        }
        let plain = IppClient.defaultEndpoint(http)
        var candidates = [plain]
        if let hint, hint != plain, hint.host?.caseInsensitiveCompare(http.host) == .orderedSame, hint.scheme == "http" || hint.scheme == "https" {
            candidates.insert(hint, at: 0)
        }
        @Sendable func read(_ url: URL) async throws -> Attempt {
            let r = try await IppClient(http, endpoint: url).printerAttributes()
            return r.ok ? .answered(r, url) : .missed
        }
        return await withTaskGroup(of: Attempt.self) { group in
            for url in candidates {
                group.addTask {
                    do {
                        return try await read(url)
                    } catch DeviceNetworkError.refused where url == plain {
                        var tls = URLComponents(url: plain, resolvingAgainstBaseURL: false)!
                        tls.scheme = "https"
                        return (try? await read(tls.url!)) ?? .missed
                    } catch {
                        return .missed // offline, garbage, or the other attempt won
                    }
                }
            }
            group.addTask {
                try? await Task.sleep(for: ippProbeDeadline)
                return .deadline
            }
            defer { group.cancelAll() }
            var pending = candidates.count
            while let next = await group.next() {
                switch next {
                case .answered(let r, let url): return (r, url)
                case .deadline: return nil
                case .missed:
                    pending -= 1
                    if pending == 0 { return nil }
                }
            }
            return nil
        }
    }

    /// One read of the printer: status, supply levels and usage counters, each from the first interface that gives it
    /// (LEDM, then CDM for newer HP printers, then IPP, then SNMP), with one error rule (`PrinterReader`): a network failure
    /// means offline; a printer that answers with an error or garbage (common while it wakes up) passes the part on to the
    /// next interface, and is unavailable, not offline, when none gives it. Never throws for either.
    public func read() async throws -> PrinterReading { try await reader.read(.all) }

    /// The status part of `read` only.
    public func status() async throws -> PrinterStatus { try await reader.read(.status).status }

    /// The supplies part of `read` only: empty when they couldn't be read (never throws for that).
    public func supplies() async throws -> [Consumable] { try await reader.read(.supplies).supplies ?? [] }

    /// The UUID the device at this address reports now, from one small read of the interface it was connected over,
    /// falling back to the next when one answers with an error. Empty when none told (or the printer didn't answer).
    public func readUuids() async throws -> [String] { try await reader.readUuids() }

    /// Over SNMP: who answers at the address now, to compare with the printer as it was added (`SnmpDevice`). Nil for
    /// other connections and when nothing answers.
    public func readSnmpIdentity() async throws -> SnmpIdentity? { try await snmp?.readIdentity() }

    /// For a connection over SNMP: LEDM, CDM, IPP and eSCL asked again (never SNMP), since a printer that was asleep or busy
    /// when it was added may have them. A new connection when one answers now and it is the same device (its serial number,
    /// when both tell, agrees with `known`); nil otherwise. The caller switches to it.
    public func tryRicher(_ known: SnmpDevice?, transport: @escaping HttpTransportFactory, esclHint: URL? = nil, ippHint: URL? = nil,
                          pin: (any CertificatePin)? = nil) async throws -> PrinterConnection? {
        let richer = try await Self.open(http.host, transport: transport, esclHint: esclHint, ippHint: ippHint, pin: pin)
        guard richer.probe.reachable, known?.identify(serialNumber: richer.probe.serialNumber) != .different else { return nil }
        return richer
    }

    public func tryRicher(_ known: SnmpDevice?, transport: any HttpTransport) async throws -> PrinterConnection? {
        try await tryRicher(known, transport: { _, _ in transport })
    }

    /// Yields whenever status may have changed: on LEDM device events (long poll) or, for printers without events, once
    /// right away and then every `fallbackInterval`.
    public func watch(fallbackInterval: Duration) -> AsyncStream<String> {
        let ledm = probe.ledm?.hasEvents == true ? self.ledm : nil
        return AsyncStream { continuation in
            let task = Task {
                if let ledm {
                    for await events in ledm.watchEvents() { continuation.yield(events.last?.category ?? "changed") }
                } else {
                    continuation.yield("start") // read once right away; IPP-only printers have no event feed
                    while (try? await Task.sleep(for: fallbackInterval)) != nil { continuation.yield("tick") }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The value, or nil when the printer is offline or answered with an error or garbage.
    private static func attempt<T: Sendable>(_ read: () async throws -> T?) async -> T? {
        do {
            return try await read()
        } catch {
            return nil
        }
    }
}
