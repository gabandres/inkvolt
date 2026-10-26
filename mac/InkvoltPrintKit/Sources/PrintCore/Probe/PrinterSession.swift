import Foundation

/// Where a remembered printer is reached: its address, the eSCL and IPP addresses it gave, and (SNMP-only printers) what it
/// said about itself.
public struct PrinterWhere: Sendable {
    public var host: String
    public var esclHint: URL?
    public var ippHint: URL?
    public var snmp: SnmpDevice?

    public init(_ host: String, esclHint: URL? = nil, ippHint: URL? = nil, snmp: SnmpDevice? = nil) {
        self.host = host
        self.esclHint = esclHint
        self.ippHint = ippHint
        self.snmp = snmp
    }
}

/// The connection recipe: what every connection to a printer carries, the same for the first connection, a reconnection, an
/// upgrade from SNMP and a look at another address.
public struct PrinterRecipe: Sendable {
    /// The network, asked for each connection (URLSession in the app; fixtures in demo mode and tests).
    public var transport: HttpTransportFactory
    /// Where SNMP goes; used only for printers added as SNMP-only (`PrinterWhere.snmp`).
    public var snmp: any SnmpTransport
    /// The printer's certificate pins (trust on first use), for its own connections only.
    public var pin: (any CertificatePin)?
    /// For the intervals below; tests pass their own.
    public var now: @Sendable () -> Date

    public init(transport: @escaping HttpTransportFactory, snmp: any SnmpTransport, pin: (any CertificatePin)? = nil,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.transport = transport
        self.snmp = snmp
        self.pin = pin
        self.now = now
    }
}

/// What a session step came to: the view model shows it.
public enum SessionStep: Sendable {
    /// Nothing answers at the printer's address.
    case offline
    /// Another device answers at the address (it reports other UUIDs, or over SNMP another serial number, model or name).
    /// The session has let go of every connection: nothing of that device is read under this printer's name.
    case elsewhere(uuids: [String], snmp: SnmpIdentity?)
    /// A new connection to the printer (the session dropped the one before). `upgraded`: a printer read over SNMP that
    /// answers LEDM, CDM or IPP now; it isn't an SNMP-only printer any more.
    case connected(PrinterConnection, upgraded: Bool)
    /// A read of the printer, after making sure it is still this printer.
    case read(PrinterReading)
}

/// Why mDNS's announcement of the printer at another address was or wasn't followed.
public enum AddressCheck: Sendable {
    /// Move there: it answers as this printer, or can't tell and the address in use no longer answers as it.
    case move
    /// Another device answers there.
    case anotherDevice
    /// It answers without saying who it is, and the address in use still answers as this kind of printer.
    case noId
    /// Nothing answers there, and the address in use still does.
    case noAnswer
    /// Not asked: being asked already, or refused a moment ago (an address announced again and again is asked now and then).
    case skipped
}

/// The printer session: one remembered printer's connection life cycle. It connects with one recipe, asks who answers
/// before reading (at once on a new or reused connection, then every `identityInterval`), so another device that took the
/// address never has its status, supplies or alerts read under this printer's name; upgrades a printer read over SNMP when
/// it answers more (every `upgradeInterval`); and checks an address mDNS announces the printer at. It owns the connection:
/// callers bind to `connection`.
public actor PrinterSession {
    public static let identityInterval: TimeInterval = 30

    /// How often a printer read over SNMP is asked whether it answers LEDM, CDM or IPP now.
    public static let upgradeInterval: TimeInterval = 120

    /// An address refused is asked again only after this (it may be announced every few seconds).
    public static let refusedFor: TimeInterval = 60

    private let id: String
    private let recipe: PrinterRecipe
    private let accepted: @Sendable () -> [String]
    private let acceptUuids: @Sendable ([String]) -> Void
    private var identityCheckedAt = Date.distantPast
    private var upgradeTriedAt = Date.distantPast
    private var checkingHost: String?
    private var refusedHost: (host: String, at: Date)?

    /// The printer's connection; nil before the first connection and after another device was found at its address.
    public private(set) var connection: PrinterConnection?

    /// - Parameters:
    ///   - id: the printer's id: its UUID, or (no UUID) one made from the address it was added at.
    ///   - accepted: UUIDs the user confirmed are this printer's ("This is my printer"); `acceptUuids` adds to them.
    public init(id: String, recipe: PrinterRecipe, accepted: @escaping @Sendable () -> [String], acceptUuids: @escaping @Sendable ([String]) -> Void) {
        self.id = id
        self.recipe = recipe
        self.accepted = accepted
        self.acceptUuids = acceptUuids
    }

    /// Connects at target: `.connected`, or `.offline`, or `.elsewhere` (nothing kept).
    public func connect(_ target: PrinterWhere) async throws -> SessionStep {
        let conn = try await PrinterConnection.open(target.host, transport: recipe.transport, esclHint: target.esclHint, ippHint: target.ippHint,
                                                    pin: recipe.pin, snmp: SnmpDevice.transport(for: target.snmp, recipe.snmp))
        if !conn.probe.reachable { return .offline }
        if identify(target.host, conn.probe.reportedUuids) == .different { return letGo(conn.probe.reportedUuids, host: target.host) }
        if let snmp = conn.probe.snmp, target.snmp?.identify(snmp) == .different { return letGo([], host: target.host, snmp: snmp) }
        let now = recipe.now()
        identityCheckedAt = now
        if conn.overSnmp { upgradeTriedAt = now } // HTTP just didn't answer: asked again later
        return use(conn, upgraded: false)
    }

    /// A read of the printer over `connection`, once it's sure it's still this printer (asked at most every
    /// `identityInterval`, and first after `askIdentityFirst`): `.read`, or `.elsewhere` (nothing read).
    public func read(_ target: PrinterWhere) async throws -> SessionStep {
        guard let conn = connection else { throw SessionError.notConnected }
        if recipe.now().timeIntervalSince(identityCheckedAt) > Self.identityInterval, let elsewhere = try await stillThisPrinter(conn, target) {
            return elsewhere
        }
        return .read(try await conn.read())
    }

    /// Time passed (the window was hidden): the connection is asked who it is before its next read.
    public func askIdentityFirst() { identityCheckedAt = .distantPast }

    /// A printer read over SNMP is asked now and then (`upgradeInterval`) whether it answers LEDM, CDM or IPP: one that was
    /// asleep when it was added does once it wakes. Identity before data holds here too: the device at the address is first
    /// asked over SNMP who it is, and another device there ends it (`.elsewhere`), since an upgrade makes the UUIDs it
    /// reports this printer's for good and the HTTP probe of a printer added by address often can't tell. When it answers
    /// more, as the same device, the session switches to that connection (`.connected` with upgraded) and the UUIDs it
    /// reports count as this printer's from now on. Nil when nothing changed.
    public func tryUpgrade(_ target: PrinterWhere) async throws -> SessionStep? {
        guard let conn = connection, conn.overSnmp, recipe.now().timeIntervalSince(upgradeTriedAt) >= Self.upgradeInterval else { return nil }
        upgradeTriedAt = recipe.now()
        if let elsewhere = try await stillThisPrinter(conn, target) { return elsewhere }
        guard let richer = try await conn.tryRicher(target.snmp, transport: recipe.transport, esclHint: target.esclHint, ippHint: target.ippHint,
                                                    pin: recipe.pin) else { return nil }
        if identify(target.host, richer.probe.reportedUuids) == .different { return nil }
        let uuids = PrinterId.valid(richer.probe.reportedUuids, host: target.host)
        if !uuids.isEmpty { acceptUuids(uuids) }
        identityCheckedAt = recipe.now()
        return use(richer, upgraded: true)
    }

    /// mDNS announces the printer at `candidate` while it's used at `current`: DHCP may have moved it, or the announcement is
    /// of an address this Mac can't use (a VM's or VPN's). Asked with the same recipe as the printer's own connections (its
    /// SNMP identity included), but without the certificate pin: nothing is sent there that needs one, and trust on first
    /// use must not pin a device not yet known to be this printer.
    /// - Parameters:
    ///   - currentAnswers: the address in use answers as this printer now.
    ///   - announcedModel: the model the announcement names (compared with the one at the address in use).
    public func checkAddress(current: PrinterWhere, candidate: PrinterWhere, currentAnswers: Bool, announcedModel: String?) async throws -> AddressCheck {
        let host = candidate.host
        if checkingHost?.caseInsensitiveCompare(host) == .orderedSame { return .skipped }
        if let refused = refusedHost, refused.host.caseInsensitiveCompare(host) == .orderedSame,
           recipe.now().timeIntervalSince(refused.at) < Self.refusedFor {
            return .skipped
        }
        checkingHost = host
        defer { checkingHost = nil }
        do {
            let probe = try await PrinterConnection.probe(DeviceHttp(host: host, transport: recipe.transport), esclHint: candidate.esclHint,
                                                          ippHint: candidate.ippHint, snmp: SnmpDevice.transport(for: current.snmp, recipe.snmp))
            let identity: DeviceIdentity
            if !probe.reachable {
                identity = .unknown
            } else if let snmp = probe.snmp, let known = current.snmp {
                identity = known.identify(snmp)
            } else {
                identity = identify(host, probe.reportedUuids)
            }
            // No UUID to go by there: the address in use is kept only while it answers as this kind of printer.
            let move = PrinterId.shouldMove(identity, currentAnswers: currentAnswers, currentModel: connection?.probe.model, announcedModel: announcedModel)
            refusedHost = move ? nil : (host, recipe.now())
            return move ? .move : identity == .different ? .anotherDevice : probe.reachable ? .noId : .noAnswer
        } catch {
            refusedHost = (host, recipe.now())
            throw error
        }
    }

    /// Asks the connected device who it is (one small read): nil when it's this printer or it can't tell; else `.elsewhere`.
    private func stillThisPrinter(_ conn: PrinterConnection, _ target: PrinterWhere) async throws -> SessionStep? {
        if conn.overSnmp {
            // SNMP has no UUID: the serial number, model and name it gave when it was added tell.
            let now = try await conn.readSnmpIdentity()
            identityCheckedAt = recipe.now()
            guard let now, target.snmp?.identify(now) == .different else { return nil }
            return letGo([], host: target.host, snmp: now)
        }
        let reported = try await conn.readUuids()
        identityCheckedAt = recipe.now()
        return identify(target.host, reported) != .different ? nil : letGo(reported, host: target.host)
    }

    private func identify(_ host: String, _ reported: [String?]) -> DeviceIdentity {
        PrinterId.identify(id, accepted: accepted(), host: host, reported: reported)
    }

    private func use(_ conn: PrinterConnection, upgraded: Bool) -> SessionStep {
        connection = conn
        return .connected(conn, upgraded: upgraded)
    }

    /// Another device answers: the printer's connection is dropped. Never the UUIDs or serials in a log.
    private func letGo(_ reported: [String?], host: String, snmp: SnmpIdentity? = nil) -> SessionStep {
        connection = nil
        return .elsewhere(uuids: PrinterId.valid(reported, host: host), snmp: snmp)
    }
}

public enum SessionError: Error {
    case notConnected
}
