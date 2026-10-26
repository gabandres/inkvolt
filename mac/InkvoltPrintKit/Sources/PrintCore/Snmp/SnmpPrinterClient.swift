import Foundation

/// Who answered over SNMP: the version it speaks, its printer's hrDeviceIndex, and what it says about itself.
public struct SnmpIdentity: Equatable, Sendable {
    public var version: SnmpVersion
    public var deviceIndex: UInt32
    public var deviceDescription: String?
    public var systemDescription: String?
    public var systemName: String?
    public var location: String?
    public var serialNumber: String?
    public var community: String

    public init(version: SnmpVersion, deviceIndex: UInt32, deviceDescription: String?, systemDescription: String?, systemName: String?,
                location: String?, serialNumber: String?, community: String = SnmpClient.defaultCommunity) {
        self.version = version
        self.deviceIndex = deviceIndex
        self.deviceDescription = deviceDescription
        self.systemDescription = systemDescription
        self.systemName = systemName
        self.location = location
        self.serialNumber = serialNumber
        self.community = community
    }

    /// The model: hrDeviceDescr ("Brand Model"), else the first line of sysDescr (often model plus firmware).
    public var model: String? {
        if let deviceDescription { return deviceDescription }
        guard let first = systemDescription?.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == ";" }).first
        else { return nil }
        let s = first.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }
}

/// A printer's status and supplies over SNMP (read only): Host Resources MIB and Printer MIB objects of the printer's
/// hrDeviceIndex. Status and supplies come from one read, shared for a moment, since the connection asks for both at once.
public actor SnmpPrinterClient {
    public nonisolated let identity: SnmpIdentity
    private nonisolated let client: SnmpClient
    private nonisolated let transport: any SnmpTransport
    private var shared: (id: Int, read: Task<SnmpReading, any Error>, at: ContinuousClock.Instant)?
    private var reads = 0
    private var colorants: [Int: String]?

    /// How long one read serves both the status and the supplies.
    static let sharedFor: Duration = .seconds(2)

    /// How long a probe waits for each reply (it asks over v2c and v1 at once, and once more on silence).
    public static let probeTimeout: Duration = .seconds(1)

    public init(transport: any SnmpTransport, host: String, identity: SnmpIdentity, timeout: Duration? = nil) {
        self.identity = identity
        self.transport = transport
        client = SnmpClient(transport: transport, host: host, version: identity.version, community: identity.community,
                            timeout: timeout ?? Self.probeTimeout)
    }

    public nonisolated var host: String { client.host }

    /// Asks `host` over SNMP whether it is a printer: one GetNext of the system description, name and location and of
    /// hrPrinterStatus, over v2c and v1 at once (v2c kept when both answer). Only an agent with a Host Resources printer entry
    /// counts (a router or a PC answering "public" isn't a printer). Then its model and serial number. Nil when nothing
    /// answers, or it isn't a printer.
    public static func probe(transport: any SnmpTransport, host: String, community: String = SnmpClient.defaultCommunity)
        async throws -> SnmpPrinterClient? {
        enum Event: Sendable {
            case answer(SnmpVersion, SnmpIdentity?)
            case v2cDeadline
        }
        let found = await withTaskGroup(of: Event.self) { group -> SnmpIdentity? in
            for version in [SnmpVersion.v2c, .v1] {
                group.addTask { .answer(version, await identify(transport, host, version, community)) }
            }
            var pending = 2
            var v1Answer: SnmpIdentity?
            defer { group.cancelAll() }
            while let event = await group.next() {
                switch event {
                case .answer(.v2c, let identity?):
                    return identity
                case .answer(.v2c, nil):
                    pending -= 1
                    if v1Answer != nil || pending == 0 { return v1Answer }
                case .answer(.v1, let identity):
                    pending -= 1
                    guard let identity else {
                        if pending == 0 { return nil }
                        continue
                    }
                    if pending == 0 { return identity }
                    // v1 answered first: a v2c agent's reply is usually right behind it.
                    v1Answer = identity
                    group.addTask {
                        try? await Task.sleep(for: .milliseconds(300))
                        return .v2cDeadline
                    }
                case .v2cDeadline:
                    return v1Answer
                }
            }
            return v1Answer
        }
        try Task.checkCancellation()
        return found.map { SnmpPrinterClient(transport: transport, host: host, identity: $0) }
    }

    private static func identify(_ transport: any SnmpTransport, _ host: String, _ version: SnmpVersion, _ community: String) async
        -> SnmpIdentity? {
        do {
            let client = SnmpClient(transport: transport, host: host, version: version, community: community, timeout: probeTimeout)
            let next = try await client.getNext([PrinterMib.sysDescr, PrinterMib.sysName, PrinterMib.sysLocation, PrinterMib.hrPrinterStatus])
            guard !next[3].value.isException, let index = next[3].name.after(PrinterMib.hrPrinterStatus), index.count == 1 else { return nil }
            func text(_ i: Int, _ column: Oid) -> String? { next[i].name.after(column) == [0] ? next[i].value.text : nil }
            let more = try await client.get([PrinterMib.hrDeviceDescr.appending(index[0]), PrinterMib.prtGeneralSerialNumber.appending(index[0])])
            return SnmpIdentity(version: version, deviceIndex: index[0], deviceDescription: more[0].value.text,
                                systemDescription: text(0, PrinterMib.sysDescr), systemName: text(1, PrinterMib.sysName),
                                location: text(2, PrinterMib.sysLocation), serialNumber: more[1].value.text, community: community)
        } catch {
            return nil
        }
    }

    /// The printer's status objects now (or from a read a moment ago). A read that failed isn't shared.
    public func read() async throws -> SnmpReading {
        let now = ContinuousClock.now
        if let shared, now - shared.at < Self.sharedFor { return try await shared.read.value }
        reads += 1
        let id = reads
        let read = Task { try await readSharing(id) }
        shared = (id, read, now)
        return try await read.value
    }

    private func readSharing(_ id: Int) async throws -> SnmpReading {
        do {
            return try await readNow()
        } catch {
            if shared?.id == id { shared = nil }
            throw error
        }
    }

    /// Who answers SNMP at the printer's address now (asked as `probe` does, with this printer's community), to tell whether
    /// it is still this printer (`SnmpDevice.identify`). Nil when nothing answers.
    public nonisolated func readIdentity() async throws -> SnmpIdentity? {
        try await Self.probe(transport: transport, host: host, community: identity.community)?.identity
    }

    public func status() async throws -> PrinterStatus { SnmpPrinterStatus.toStatus(try await read()) }

    public func supplies() async throws -> [Consumable] { SnmpPrinterStatus.toConsumables(try await read()) }

    /// A read now, not shared (callers that keep their own pace: a queue printer's status).
    func readNow() async throws -> SnmpReading {
        let i = identity.deviceIndex
        let state = try await client.get([PrinterMib.hrDeviceStatus.appending(i), PrinterMib.hrPrinterStatus.appending(i),
                                          PrinterMib.hrPrinterDetectedErrorState.appending(i)])
        let alertColumns = [PrinterMib.alertSeverity, PrinterMib.alertGroup, PrinterMib.alertGroupIndex, PrinterMib.alertCode,
                            PrinterMib.alertDescription]
        let alerts = Self.rows(try await client.walk(alertColumns.map { $0.appending(i) }))
        let supplyColumns = [PrinterMib.suppliesClass, PrinterMib.suppliesType, PrinterMib.suppliesDescription,
                             PrinterMib.suppliesMaxCapacity, PrinterMib.suppliesLevel, PrinterMib.suppliesColorantIndex]
        let supplies = Self.rows(try await client.walk(supplyColumns.map { $0.appending(i) }))
        // Colorants belong to the marker, not the cartridge in it: read once.
        if colorants == nil {
            var found: [Int: String] = [:]
            for (row, cells) in Self.rows(try await client.walk([PrinterMib.colorantValue.appending(i)])) {
                if let text = cells[0]?.text { found[row] = text }
            }
            colorants = found
        }

        func int(_ value: SnmpValue?, _ missing: Int = 0) -> Int { value?.int ?? missing }
        return SnmpReading(
            deviceStatus: state[0].value.int,
            printerStatus: state[1].value.int,
            detectedErrorState: state[2].value.bytes ?? [],
            alerts: alerts.map { row, v in
                SnmpAlert(row, severity: int(v[0]), group: int(v[1]), groupIndex: int(v[2], -1), code: int(v[3]), description: v[4]?.text)
            },
            supplies: supplies.map { row, v in
                SnmpSupply(row, supplyClass: int(v[0]), type: int(v[1]), description: v[2]?.text, maxCapacity: int(v[3], -2),
                           level: int(v[4], -2), colorantIndex: int(v[5]))
            },
            colorants: colorants ?? [:])
    }

    /// Columns walked side by side → rows by their (single-arc) index, in order, each with its value per column (nil where
    /// missing).
    private static func rows(_ columns: [[SnmpRow]]) -> [(row: Int, cells: [SnmpValue?])] {
        var rows: [Int: [SnmpValue?]] = [:]
        for (c, column) in columns.enumerated() {
            for cell in column {
                guard cell.index.count == 1, cell.index[0] <= UInt32(Int32.max) else { continue }
                let row = Int(cell.index[0])
                rows[row, default: [SnmpValue?](repeating: nil, count: columns.count)][c] = cell.value
            }
        }
        return rows.keys.sorted().map { ($0, rows[$0]!) }
    }
}
