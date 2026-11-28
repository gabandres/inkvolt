import Foundation

/// What the person chose (the app keeps it with its state): which scanner is shared, if any. Off by default (the Windows
/// Core's `ScannerShareChoice`). `deviceId`: the shared scanner's ImageCaptureCore id (`SystemScanner.id`), nil: nothing
/// shared; `name`: its name, for the card while it isn't connected; `uuid`: the UUID it is announced with, made once and
/// kept, so clients know it again after a restart; `places`: the networks the person turned it on in (**Mac difference**,
/// `NetworkPlace`), the only ones it's shared on; nil or empty (a choice kept before them): shared nowhere until turned on
/// again.
public struct ScannerShareChoice: Equatable, Sendable, Codable {
    public var deviceId: String?
    public var name: String?
    public var uuid: UUID?
    public var places: [NetworkPlace]?

    public init(deviceId: String? = nil, name: String? = nil, uuid: UUID? = nil, places: [NetworkPlace]? = nil) {
        self.deviceId = deviceId
        self.name = name
        self.uuid = uuid
        self.places = places
    }
}

/// Where a share stands.
public enum ShareState: Equatable, Sendable {
    /// Nothing shared: nothing listens.
    case off
    /// Turned on, the scanner isn't connected (off, unplugged): nothing listens until it is.
    case waitingForScanner
    /// Turned on, no private network: nothing listens until there is one.
    case noPrivateNetwork
    /// Turned on, but only on other networks than this Mac is on now (a café's, a hotel's): paused, nothing listens or is
    /// announced until the person turns it on here too (`ShareCard.canShareHere`).
    case otherNetwork
    /// Opening the port.
    case starting
    /// Listening and announced.
    case on
    /// Couldn't start (`ScannerShare.problem` says why): nothing listens.
    case failed
}

/// What the HTTPS server listens with: on loopback only (demo mode, tests) or every address; the port (0: any free one);
/// the certificate; who may connect (the peer, and this Mac's address it reached when known: `SharePeers.allows`); the
/// scanner it serves.
public struct ShareListen: Sendable {
    public var loopbackOnly: Bool
    public var port: Int
    public var certificate: any PhoneCertificate
    public var allowPeer: @Sendable (String, String?) -> Bool
    public var scanner: SharedScanner

    public init(loopbackOnly: Bool, port: Int, certificate: any PhoneCertificate, allowPeer: @escaping @Sendable (String, String?) -> Bool,
                scanner: SharedScanner) {
        self.loopbackOnly = loopbackOnly
        self.port = port
        self.certificate = certificate
        self.allowPeer = allowPeer
        self.scanner = scanner
    }
}

/// Starts the HTTPS server (PrintMac's `NetworkShareHost`, the phone scan's server serving eSCL). Throws
/// `PhoneHostError.portInUse` when the port is taken. The listener it returns closes the port at once on `close`.
public protocol ShareHost: Sendable {
    func start(_ listen: ShareListen) async throws -> any PhoneListener
}

/// What the Scan tab's card shows for one entry's scanner. `deviceId`: the scanner the card is about, nil when it shows
/// nothing; `fingerprint`: the certificate's fingerprint, 16 bytes a line, while this scanner is shared and listening;
/// `canShareHere`: it's paused on this network (`ShareState.otherNetwork`), and Share on This Network turns it on here too.
public struct ShareCard: Equatable, Sendable {
    public var deviceId: String?
    public var isOn: Bool
    public var text: String
    public var fingerprint: String?
    public var canShareHere = false

    public static let hidden = ShareCard(deviceId: nil, isOn: false, text: "", fingerprint: nil)

    public var isShown: Bool { deviceId != nil }
}

/// What turning sharing on did.
public enum ShareSwitch: Equatable, Sendable {
    /// Turned on (it listens once the scanner and a private network allow).
    case on
    /// The scanner isn't connected, or is one macOS reaches over eSCL itself: nothing changed.
    case noScanner
}

/// The adapters a share works through. `loopbackOnly` (demo mode, tests): it listens on 127.0.0.1 only, any free port, for
/// this Mac alone, announces nothing and needs no private network.
public struct ShareEnvironment: Sendable {
    public var host: any ShareHost
    public var networks: any ShareNetworks
    public var advertiser: any ShareAdvertiser
    public var certificates: any ShareCertificates
    public var port: Int
    public var loopbackOnly: Bool

    public init(host: any ShareHost, networks: any ShareNetworks, advertiser: any ShareAdvertiser, certificates: any ShareCertificates,
                port: Int = ScannerShare.defaultPort, loopbackOnly: Bool = false) {
        self.host = host
        self.networks = networks
        self.advertiser = advertiser
        self.certificates = certificates
        self.port = port
        self.loopbackOnly = loopbackOnly
    }

    /// Sharing to this Mac alone (demo mode, tests): `host` on 127.0.0.1 and any free port, no networks read and nothing
    /// announced. `certificates`: a keychain of the run's own (the sandbox can't make a key in no keychain at all).
    public static func thisMacOnly(_ host: any ShareHost, certificates: any ShareCertificates) -> ShareEnvironment {
        ShareEnvironment(host: host, networks: NoNetworks(), advertiser: NoAdvertiser(), certificates: certificates, port: 0, loopbackOnly: true)
    }

    private struct NoNetworks: ShareNetworks {
        func read() -> [LocalNetwork] { [] }
        func watch(_ changed: @escaping @Sendable () -> Void) -> any ShareWatch { Nothing() }
        func place(of network: LocalNetwork) -> NetworkPlace { NetworkPlace(network) }
    }

    private struct NoAdvertiser: ShareAdvertiser {
        func advertise(_ advert: ShareAdvert, on: [LocalNetwork]) async throws -> any ShareWatch { Nothing() }
    }

    private struct Nothing: ShareWatch {
        func stop() async {}
    }
}

/// A scanner of this Mac shared on the network as an eSCL scanner (print/ROADMAP.md 3.1, free since 2026-11-22; the
/// Windows Core's `ScannerShare`): one scanner at a time, off by default, only on the private networks it was turned on in
/// (`NetworkPlace`; paused on others, `ShareState.otherNetwork`), only while the app
/// runs. Turned on, it listens over HTTPS on `defaultPort` with the app's self-signed certificate (`fingerprint`), serves
/// the scanner through a `SharedScanner` and announces it as `_uscans._tcp`; it stops listening the moment it's turned off,
/// the scanner goes, the last private network goes, or the app closes. The app hands it the shared scanner when it's
/// connected (`offer`); calls are taken one at a time; `onChange` is told from any thread.
public final class ScannerShare: @unchecked Sendable {
    /// The port it listens on (TCP, HTTPS); Windows' too.
    public static let defaultPort = 9780

    private let env: ShareEnvironment
    private let computerName: String
    private let save: @Sendable (ScannerShareChoice) -> Void
    private let log: @Sendable (String) -> Void
    private let limits: ShareLimits
    private let now: @Sendable () -> Date
    private let calls = AsyncGate()
    private let lock = NSLock()

    // Under `lock`.
    private var current: ScannerShareChoice
    private var scanner: ConnectedScanner?
    private var stateNow = ShareState.off
    private var problemNow: String?, fingerprintNow: String?, note: String?
    private var portNow: Int?
    private var closed = false
    private var listeners: [@Sendable () -> Void] = []
    /// The calls under way that a close cancels (a start or an announcement doesn't run its time out).
    private var underWay: [UUID: Task<Void, Never>] = [:]
    private var served: [LocalNetwork] = []

    // Inside `calls`.
    private var running: (server: SharedScanner, caps: ScannerCapabilities, listener: any PhoneListener, advert: (any ShareWatch)?, networks: String)?
    private var watching: (any ShareWatch)?

    /// - Parameters:
    ///   - save: keeps the choice when it changes.
    ///   - log: told what happens, in plain words: never a device's address.
    public init(_ env: ShareEnvironment, computerName: String, choice: ScannerShareChoice?, save: @escaping @Sendable (ScannerShareChoice) -> Void,
                log: @escaping @Sendable (String) -> Void = { _ in }, limits: ShareLimits = ShareLimits(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.env = env
        self.computerName = computerName
        current = choice ?? ScannerShareChoice()
        self.save = save
        self.log = log
        self.limits = limits
        self.now = now
    }

    /// Told (from any thread) whenever what the card shows may have changed.
    public func onChange(_ listener: @escaping @Sendable () -> Void) { lock.withLock { listeners.append(listener) } }

    public var choice: ScannerShareChoice { lock.withLock { current } }

    /// A scanner is chosen to be shared (whether or not it's listening now).
    public var isOn: Bool { choice.deviceId != nil }

    public func isShared(_ deviceId: String) -> Bool {
        guard let shared = choice.deviceId else { return false }
        return shared.caseInsensitiveCompare(deviceId) == .orderedSame
    }

    public var state: ShareState { lock.withLock { stateNow } }

    /// The port listened on, while `.on`.
    public var port: Int? { lock.withLock { portNow } }

    /// The certificate's SHA-256 fingerprint, while `.on`.
    public var fingerprint: String? { lock.withLock { fingerprintNow } }

    /// Why it couldn't start, in plain words (`.failed`).
    public var problem: String? { lock.withLock { problemNow } }

    /// The scanner card's line for the scanner `deviceId`.
    public func text(_ deviceId: String) -> String {
        let (choice, state, problem, note, port) = lock.withLock { (current, stateNow, problemNow, self.note, portNow) }
        guard choice.deviceId != nil else { return Self.offText }
        if !isShared(deviceId) {
            return loc("{0} is shared now. Turning this on shares this scanner instead: one scanner is shared at a time.", choice.name ?? "")
        }
        switch state {
        case .off: return Self.offText
        case .waitingForScanner: return loc("Shared once the scanner answers. Check that it's on and plugged in.")
        case .noPrivateNetwork:
            return loc("Not shared: this Mac isn't on a private network. On your home or office Wi-Fi or Ethernet, it's shared again where you turned it on.")
        case .otherNetwork:
            return loc("Paused: this Mac is on a network you didn't turn sharing on in, so nobody here can reach the scanner. On a network you trust, choose Share on This Network.")
        case .starting: return loc("Starting…")
        case .on:
            let line = env.loopbackOnly
                ? loc("Demo: shared as \"{0}\" on port {1}, for this Mac only.", choice.name ?? "", String(port ?? 0))
                : loc("Shared as \"{0}\" on port {1}. Phones, Macs and other computers on this private network can scan with it while Inkvolt Print runs here.",
                      choice.name ?? "", String(port ?? 0))
            return note.map { line + " " + $0 } ?? line
        case .failed: return problem ?? Self.failedText
        }
    }

    static var offText: String {
        loc("Off. Turned on, phones, Macs and other computers on a private network can scan with this scanner while Inkvolt Print runs here.")
    }

    static var failedText: String {
        loc("Not shared: sharing couldn't start. Turn it off and on again; if it still doesn't start, Help › Report a Problem sends the details.")
    }

    /// The card for an entry's scanner: the connected one, or the one the entry is known by while it's the shared one (so
    /// a shared scanner that's off or unplugged can still be turned off); never one macOS reaches over eSCL itself (it's on
    /// the network already). Hidden when the entry has neither.
    public func card(connected: SystemScanner?, known: SystemScanner?) -> ShareCard {
        let device: SystemScanner? = if let c = connected, !c.isEscl { c } else if let k = known, !k.isEscl, isShared(k.id) { k } else { nil }
        guard let device else { return .hidden }
        let on = isShared(device.id)
        var shown: String?
        if on, state == .on, let f = fingerprint { shown = f.count > 48 ? String(f.prefix(48)) + "\n" + String(f.dropFirst(48)) : f }
        return ShareCard(deviceId: device.id, isOn: on, text: text(device.id), fingerprint: shown,
                         canShareHere: on && state == .otherNetwork && connected != nil)
    }

    /// Turns sharing on for `scanner`, the entry's connected scanner; nothing for one that isn't connected or that macOS
    /// reaches over eSCL.
    public func turnOn(_ scanner: ConnectedScanner?) async -> ShareSwitch {
        guard let scanner, !scanner.scanner.isEscl else { return .noScanner }
        await share(scanner)
        return .on
    }

    /// An entry is forgotten: if one of its scanners (`deviceIds`) is the shared one, sharing is turned off.
    public func forget(_ deviceIds: [String?]) async {
        if deviceIds.compactMap({ $0 }).contains(where: isShared) { await stop() }
    }

    /// Shares `scanner` (instead of any other) on the private networks this Mac is on now, besides those it was turned on in
    /// before: it listens once the scanner allows, and only on those networks (`NetworkPlace`).
    public func share(_ scanner: ConnectedScanner) async {
        await call {
            let device = scanner.scanner
            let old = self.choice
            let here = self.env.loopbackOnly ? [] : SharePeers.served(self.env.networks.read()).map(self.env.networks.place(of:))
            let choice = ScannerShareChoice(deviceId: device.id, name: device.name, uuid: old.uuid ?? UUID(),
                                            places: NetworkPlace.adding(here, to: old.places ?? []))
            if old.deviceId?.caseInsensitiveCompare(device.id) != .orderedSame { await self.stopRunning() }
            self.lock.withLock {
                self.current = choice
                self.scanner = scanner
            }
            self.save(choice)
            self.log("Scanner sharing turned on for \(device.name).")
            await self.apply()
        }
    }

    /// Turns sharing off: the port closes and the announcement ends now; jobs under way are cancelled.
    public func stop() async {
        await call(evenClosed: true) {
            let choice = self.lock.withLock { () -> ScannerShareChoice in
                self.current.deviceId = nil
                self.current.name = nil
                self.current.places = nil // turned on again, it's where it's turned on then
                self.scanner = nil
                return self.current
            }
            await self.watchNetworks(false)
            await self.stopRunning()
            self.setState(.off)
            if !self.isClosed { self.save(choice) }
            self.log("Scanner sharing turned off.")
        }
    }

    /// The app's connected scanner for `deviceId` (nil: it's gone, off or unplugged). The shared one starts listening when
    /// it comes, and stops when it goes. Others are ignored.
    public func offer(_ deviceId: String, _ scanner: ConnectedScanner?) async {
        guard isShared(deviceId) else { return }
        await call {
            guard self.isShared(deviceId) else { return }
            let before = self.lock.withLock { () -> ConnectedScanner? in
                let b = self.scanner
                self.scanner = scanner
                return b
            }
            if before !== scanner { await self.stopRunning() }
            await self.apply()
        }
    }

    /// Asks again whether it may run (after the networks changed).
    public func recheck() async {
        await call { await self.apply() }
    }

    private var isClosed: Bool { lock.withLock { closed } }

    /// One call at a time; nothing once closed (but `stop`); a close cancels it where it waits.
    private func call(evenClosed: Bool = false, _ body: @escaping @Sendable () async -> Void) async {
        let id = UUID()
        let task = Task {
            guard (try? await self.calls.enter()) != nil else { return }
            defer { self.calls.leave() }
            if self.isClosed && !evenClosed { return }
            await body()
        }
        let cancelNow: Bool = lock.withLock {
            if closed && !evenClosed { return true }
            underWay[id] = task
            return false
        }
        if cancelNow { task.cancel() }
        await task.value
        _ = lock.withLock { underWay.removeValue(forKey: id) }
        raise()
    }

    /// Hears network changes only while a scanner is chosen to be shared (nothing is watched with sharing off). Inside
    /// `calls`.
    private func watchNetworks(_ on: Bool) async {
        let want = on && !env.loopbackOnly && !isClosed
        if want == (watching != nil) { return }
        if want {
            watching = env.networks.watch { [weak self] in self?.networksChanged() }
        } else {
            let old = watching
            watching = nil
            await old?.stop()
        }
    }

    private func networksChanged() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2)) // addresses come and go in bursts
            await self?.recheck()
        }
    }

    /// Starts, stops or re-announces to match the choice, the scanner and the networks. Inside `calls`.
    private func apply() async {
        let (choice, scanner) = lock.withLock { (current, self.scanner) }
        await watchNetworks(choice.deviceId != nil)
        guard choice.deviceId != nil else {
            await stopRunning()
            setState(.off)
            return
        }
        guard let scanner else {
            await stopRunning()
            setState(.waitingForScanner)
            return
        }
        var served: [LocalNetwork] = []
        if !env.loopbackOnly {
            served = SharePeers.served(env.networks.read())
            if served.isEmpty {
                await stopRunning()
                setState(.noPrivateNetwork)
                return
            }
            // Only the networks the person turned it on in: any other (a café's 192.168.x Wi-Fi) is paused.
            let places = choice.places ?? []
            served = served.filter { n in
                let here = env.networks.place(of: n)
                return places.contains { here.isSame(as: $0) }
            }
            if served.isEmpty {
                if running != nil { log("Scanner sharing paused: not a network it was turned on in.") }
                await stopRunning()
                setState(.otherNetwork)
                return
            }
        }
        lock.withLock { self.served = served }
        let networks = served.map { "\($0.address)/\($0.prefixLength)" }.sorted().joined(separator: ";")
        if let running {
            if running.networks == networks { return }
            // The private networks changed: the same server, announced on the networks there are now.
            await running.advert?.stop()
            let advert = await advertise(running.server, running.caps, port: running.listener.port ?? env.port, served)
            self.running = (running.server, running.caps, running.listener, advert, networks)
            setState(.on)
            return
        }
        await start(choice, scanner, served, networks)
    }

    private func start(_ choice: ScannerShareChoice, _ scanner: ConnectedScanner, _ served: [LocalNetwork], _ networks: String) async {
        setState(.starting)
        raise()
        var server: SharedScanner?
        var listener: (any PhoneListener)?
        do {
            guard let caps = try await scanner.capabilities(), !caps.sources.isEmpty else { throw ScanError(loc("The scanner offers no glass or feeder.")) }
            let identity = ShareIdentity(scanner.scanner.name, scanner.manufacturer, choice.uuid ?? UUID())
            let shared = SharedScanner(scanner, caps, identity, limits: limits, now: now, busyElsewhere: { scanner.isBusy }, log: log)
            server = shared
            let certificate = try env.certificates.get(hostName: PhoneScan.hostName(computerName), now: now())
            let loopback = env.loopbackOnly
            let listen = ShareListen(loopbackOnly: loopback, port: env.port, certificate: certificate, allowPeer: { [weak self] peer, local in
                loopback ? SharePeers.isLoopback(peer) : SharePeers.allows(peer, local: local, self?.lock.withLock { self?.served } ?? [])
            }, scanner: shared)
            let started = try await env.host.start(listen)
            listener = started
            guard let port = started.port, !Task.isCancelled else { throw CancellationError() }
            let advert = loopback ? nil : await advertise(shared, caps, port: port, served)
            running = (shared, caps, started, advert, networks)
            lock.withLock {
                portNow = port
                fingerprintNow = certificate.fingerprint
                problemNow = nil
            }
            setState(.on)
            log("Scanner sharing: listening on port \(port) (\(loopback ? "this Mac only" : "\(served.count) private network address(es)")).")
        } catch {
            server?.close()
            await listener?.close()
            let problem = (error as? PhoneHostError) == .portInUse
                ? loc("Not shared: another program uses port {0}. Close it, then turn sharing off and on again.", String(env.port))
                : Self.failedText
            lock.withLock { problemNow = problem }
            setState(.failed)
            log("Scanner sharing didn't start: \(type(of: error)): \(error)")
        }
    }

    /// Announces the share; a failure leaves it listening (reachable by address) and says so on the card.
    private func advertise(_ server: SharedScanner, _ caps: ScannerCapabilities, port: Int, _ served: [LocalNetwork]) async -> (any ShareWatch)? {
        do {
            let advert = try await env.advertiser.advertise(ShareDnssd.advert(server.identity, caps, computerName: computerName, port: port), on: served)
            lock.withLock { note = nil }
            return advert
        } catch {
            lock.withLock {
                note = loc("It couldn't be announced, so devices may not list it on their own: add it by this Mac's address.")
            }
            log("Scanner sharing: not announced on the network: \(type(of: error)): \(error)")
            return nil
        }
    }

    /// Closes the port and ends the announcement, if running. Inside `calls`.
    private func stopRunning() async {
        guard let running else { return }
        self.running = nil
        lock.withLock {
            portNow = nil
            fingerprintNow = nil
            note = nil
        }
        running.server.close() // jobs cancelled first, so no request waits on a page
        // The announcement and the port go together: neither waits on the other.
        let advert = running.advert, listener = running.listener
        await withTaskGroup(of: Void.self) { group in
            if let advert { group.addTask { await advert.stop() } }
            group.addTask { await listener.close() }
        }
        log("Scanner sharing: stopped listening.")
    }

    private func setState(_ state: ShareState) { lock.withLock { stateNow = state } }

    private func raise() {
        for listener in lock.withLock({ listeners }) { listener() }
    }

    /// The app closes: a start or an announcement under way is cancelled at once (it doesn't run its time out), then the
    /// port closes and the announcement ends together; the choice is kept for the next start.
    public func close() async {
        let tasks: [Task<Void, Never>] = lock.withLock {
            closed = true
            return Array(underWay.values)
        }
        tasks.forEach { $0.cancel() }
        guard (try? await calls.enter()) != nil else { return }
        defer { calls.leave() }
        await watchNetworks(false)
        await stopRunning()
        setState(.off)
    }
}
