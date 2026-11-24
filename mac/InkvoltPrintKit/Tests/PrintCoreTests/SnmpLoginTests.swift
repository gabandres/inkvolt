import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// A community per printer (roadmap 3.2): the login kept through its store's seam (memory here; the Keychain in the app),
/// the made-up agent answering only to the right community, every read of the printer using it, and none of it reaching
/// state.json or a log line. Ported from print/tests/InkvoltPrint.Tests/SnmpLoginTests.cs.
struct SnmpLoginTests {
    private static let printer = "12345678-1234-4abc-8def-123456789abc", host = "192.0.2.14", secret = "kx9-office ro"

    private static func agent(_ community: String = secret) throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/workgroup-laser.txt")), community: community)
    }

    private static func login(_ community: String) throws -> SnmpLogin { try SnmpLogin.forCommunity(community) }

    @Test func aCommunityRoundTripsAsItsKeptSecret() throws {
        let login = try Self.login(Self.secret)
        #expect(login.community == Self.secret)
        #expect(!login.isDefault)
        #expect(SnmpLogin.fromSecret(login.toSecret()) == login)
        // An agent compares bytes: kept as typed.
        #expect(SnmpLogin.fromSecret(try Self.login(" spaced ").toSecret())?.community == " spaced ")
        #expect(SnmpLogin.fromSecret("v9:something") == nil)
        #expect(SnmpLogin.fromSecret(nil) == nil)
    }

    @Test func aPassphraseTooLongForCredentialManagerIsRefusedWhenTyped() throws {
        // Windows' limit (what Credential Manager keeps); the Keychain keeps the same logins.
        let fine = String(repeating: "p", count: SnmpV3User.maxPassphrase)
        let pasted = String(repeating: "p", count: SnmpV3User.maxPassphrase + 1)
        _ = try SnmpLogin.forUser("reader", fine, fine)
        #expect { try SnmpLogin.forUser("reader", pasted, fine) } throws: { "\($0)".contains("\(SnmpV3User.maxPassphrase)") }
        #expect { try SnmpLogin.forUser("reader", fine, pasted) } throws: { "\($0)".contains("\(SnmpV3User.maxPassphrase)") }
        let euros = String(repeating: "€", count: SnmpV3User.maxPassphrase)
        let longest = try SnmpLogin.forUser(String(repeating: "é", count: SnmpV3User.maxName / 2), euros, euros)
        #expect(longest.toSecret().count < 2560, "\(longest.toSecret().count)")
    }

    @Test func aUserNameIsMeasuredAsTheAgentDoesInBytes() throws {
        _ = try SnmpLogin.forUser(String(repeating: "a", count: SnmpV3User.maxName), "authpassphrase", "privpassphrase")
        #expect(throws: SnmpLoginError.self) { // 64 bytes
            try SnmpLogin.forUser(String(repeating: "é", count: SnmpV3User.maxName), "authpassphrase", "privpassphrase")
        }
    }

    @Test(arguments: [nil, "", "   ", "public"] as [String?])
    func blankOrPublicIsTheDefaultAndNothingIsKept(_ typed: String?) throws {
        let login = try SnmpLogin.forCommunity(typed)
        #expect(login.community == SnmpLogin.public.community)
        #expect(login.isDefault)
    }

    @Test func aCommunityThatCantBeSentIsRefusedWithWhy() throws {
        #expect { try SnmpLogin.forCommunity("line\nbreak") } throws: { "\($0)".contains("control characters") }
        #expect { try SnmpLogin.forCommunity(String(repeating: "c", count: SnmpLogin.maxCommunity + 1)) } throws: { "\($0)".contains("255") }
        _ = try SnmpLogin.forCommunity(String(repeating: "c", count: SnmpLogin.maxCommunity))
        // Measured in bytes, as it's sent: 128 two-byte letters are 256.
        #expect(throws: SnmpLoginError.self) { try SnmpLogin.forCommunity(String(repeating: "é", count: 128)) }
    }

    // Mac difference (SnmpLogin.swift): no rename, so Windows' TheStoreKeepsRenamesAndDeletesAPrintersLogin keeps and
    // deletes here, and RenamingNeverOverwritesALoginKeptUnderTheNewId has no Mac counterpart.
    @Test func theStoreKeepsAndDeletesAPrintersLogin() throws {
        let store = MemorySnmpLogins()
        let logins: any SnmpLogins = store
        #expect(logins.get(Self.printer) == nil)
        logins.save(try Self.login(Self.secret), for: Self.printer)
        #expect(logins.get(Self.printer.uppercased())?.community == Self.secret)

        logins.save(.public, for: Self.printer) // public: what was kept goes, nothing takes its place
        #expect(logins.get(Self.printer) == nil)
        #expect(store.count == 0)

        logins.save(try Self.login(Self.secret), for: Self.printer)
        logins.delete(Self.printer.uppercased()) // removed from the list: its login goes with it
        #expect(store.count == 0)
    }

    @Test func theAgentAnswersOnlyToItsCommunityAndEveryReadUsesIt() async throws {
        let agent = try Self.agent()
        #expect(try await SnmpPrinterClient.probe(transport: agent, host: Self.host) == nil) // public: silence, as from a real agent
        #expect(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.login("wrong")) == nil)
        let before = agent.received.count

        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.login(Self.secret)))
        #expect(printer.identity.serialNumber == "DEMO0005200")
        #expect(try await printer.supplies().count == 3)
        #expect(try await printer.readIdentity() != nil)
        #expect(agent.received.dropFirst(before).allSatisfy { $0.community == Self.secret })
    }

    @Test func aSessionConnectsWithTheLoginKeptNowAndWithoutItThePrinterIsOffline() async throws {
        let agent = try Self.agent()
        let identity = try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.login(Self.secret))).identity
        let target = PrinterWhere(Self.host, snmp: SnmpDevice.from(identity))
        let logins = MemorySnmpLogins()
        let recipe = PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: agent, snmpLogin: { logins.get(Self.printer) })

        let without = PrinterSession(id: Self.printer, recipe: recipe, accepted: { [] }, acceptUuids: { _ in })
        guard case .offline = try await without.connect(target) else { // nothing kept: public, which it ignores
            Issue.record("connected without the community")
            return
        }

        logins.save(try Self.login(Self.secret), for: Self.printer) // the printer's menu › SNMP Access…, then a new connection
        let session = PrinterSession(id: Self.printer, recipe: recipe, accepted: { [] }, acceptUuids: { _ in })
        guard case .connected(let conn, _) = try await session.connect(target) else {
            Issue.record("not connected with the community")
            return
        }
        #expect(conn.overSnmp)
        guard case .read(let reading) = try await session.read(target) else {
            Issue.record("not read")
            return
        }
        #expect(reading.supplies?.count == 3)
        #expect(agent.received.contains { $0.community == Self.secret })
    }

    /// SnmpV3Tests' passphrases (and wrong ones): stretched once a run (`Usm.Keys`), which is slow with the PC's crypto.
    private static let user = SnmpV3User(name: "reader", authPassphrase: "authpass-2026", privPassphrase: "privpass-2026")

    private static func v3Agent() throws -> SnmpAgent {
        TestSnmpCrypto.install()
        return SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/workgroup-laser.txt")), user: user,
                         engineId: Array("inkvolt-engine".utf8), crypto: TestSnmpCrypto())
    }

    private static func v3Login(auth: String = user.authPassphrase, priv: String = user.privPassphrase) throws -> SnmpLogin {
        try SnmpLogin.forUser(user.name, auth, priv)
    }

    @Test func aRefusedLoginIsItsOwnStateNotOffline() async throws {
        let agent = try Self.v3Agent()
        let identity = try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.v3Login())).identity
        let wrong = try Self.v3Login(auth: "wrong-auth-pass")
        let recipe = PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: agent, snmpLogin: { wrong })
        let monitor = PrinterMonitor(id: Self.printer, name: "Laser", target: PrinterWhere(Self.host, snmp: SnmpDevice.from(identity)),
                                     recipe: recipe, accepted: { [] }, acceptUuids: { _ in }, onEvent: { _ in })
        #expect(await monitor.check() == false)
        let view = await monitor.view
        #expect(view.phase != .offline)
        #expect(view.statusDetail?.contains("authentication passphrase") == true, "\(view.statusDetail ?? "")")
    }

    @Test func aLoginRefusedOnAConnectionReadsAsRefusedNotOffline() async throws {
        let agent = SnmpV3Tests.Spoofer(try Self.v3Agent())
        let identity = try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.v3Login())).identity
        let login = try Self.v3Login()
        let recipe = PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: agent, snmpLogin: { login })
        let monitor = PrinterMonitor(id: Self.printer, name: "Laser", target: PrinterWhere(Self.host, snmp: SnmpDevice.from(identity)),
                                     recipe: recipe, accepted: { [] }, acceptUuids: { _ in }, onEvent: { _ in })
        #expect(await monitor.check())
        agent.spoof.withLock { $0 = (Usm.wrongDigests, agent.agent.engineId) } // the printer's administrator changed its key
        try await Task.sleep(for: SnmpPrinterClient.sharedFor + .milliseconds(100)) // past the read shared by status and supplies
        // A refusal on a connection whose login answered signed isn't trusted (anyone can send one), so that read is offline;
        // the next connection discovers the engine again and its refusal decides.
        #expect(await monitor.check() == false)
        #expect(await monitor.view.phase != .refused)
        #expect(await monitor.check() == false)
        let view = await monitor.view
        #expect(view.phase == .refused)
        #expect(view.statusDetail?.contains("authentication passphrase") == true, "\(view.statusDetail ?? "")")
    }

    /// Everything a monitor told.
    final class Events: Sendable {
        private let list = Mutex<[MonitorEvent]>([])
        func add(_ e: MonitorEvent) { list.withLock { $0.append(e) } }
        var snapshots: [PrinterSnapshot] { list.withLock { $0 }.compactMap { if case .observed(let s) = $0 { s } else { nil } } }
    }

    private static let engine = Array("inkvolt-engine".utf8)
    private static let engineHex = Digest.hex(engine, uppercase: true)

    private static func monitor(_ snmp: any SnmpTransport, _ known: SnmpDevice, _ login: SnmpLogin, _ events: Events = Events()) -> PrinterMonitor {
        let recipe = PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: snmp, snmpLogin: { login })
        return PrinterMonitor(id: printer, name: "Laser", target: PrinterWhere(host, snmp: known), recipe: recipe, accepted: { [] },
                              acceptUuids: { _ in }, onEvent: { events.add($0) })
    }

    private static func known() async throws -> SnmpDevice {
        SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: v3Agent(), host: host, login: v3Login())).identity)
    }

    @Test func aRefusalSpoofedOnAConnectionNeverShowsThePrinterRefusedOrSilencesItsAlerts() async throws {
        let agent = SnmpV3Tests.Spoofer(try Self.v3Agent())
        let events = Events()
        let monitor = Self.monitor(agent, try await Self.known(), try Self.v3Login(), events)
        #expect(await monitor.check())

        agent.spoof.withLock { $0 = (Usm.unknownUserNames, Self.engine) } // unsigned, from the printer's own engine ID, by someone else
        try await Task.sleep(for: SnmpPrinterClient.sharedFor + .milliseconds(100))
        #expect(await monitor.check() == false)
        #expect(await monitor.view.phase != .refused) // offline: its offline alert follows as for any printer that stops answering
        #expect(events.snapshots.last?.reachable == false)

        agent.spoof.withLock { $0 = nil } // gone: connected again, read as itself
        #expect(await monitor.check())
        #expect(!events.snapshots.contains { $0.loginRefused != nil })
    }

    @Test func aRefusalAfterAnotherDeviceAnsweredKeepsItElsewhere() async throws {
        let known = try await Self.known()
        let walk = try Fixtures.text("snmp-demo/workgroup-laser.txt").replacingOccurrences(of: "DEMO0005200", with: "OTHER0001")
        let other = SnmpV3Tests.Spoofer(SnmpAgent(try SnmpAgent.parseWalk(walk), user: Self.user, engineId: Self.engine, crypto: TestSnmpCrypto()))
        let monitor = Self.monitor(other, known, try Self.v3Login())
        #expect(await monitor.check() == false)
        #expect(await monitor.view.phase == .elsewhere)
        #expect(await monitor.canAcceptDevice)

        other.spoof.withLock { $0 = (Usm.wrongDigests, Self.engine) } // it refuses now, without saying who it is
        #expect(await monitor.check() == false)
        let view = await monitor.view
        #expect(view.phase == .refused)
        #expect(view.anotherDeviceAnswered) // still the device that answered last: This Is My Printer stays offered
        #expect(view.offersAcceptDevice) // the pane's button, from the same rule
        #expect(await monitor.canAcceptDevice)
    }

    /// A switch with SNMPv3 at the address (DHCP gave it the printer's old one): it refuses a user it doesn't know.
    private static func switchAgent() throws -> SnmpAgent {
        TestSnmpCrypto.install()
        return SnmpAgent(try SnmpAgent.parseWalk(".1.3.6.1.2.1.1.5.0 = STRING: \"core-switch\""),
                         user: SnmpV3User(name: "admin", authPassphrase: "switch-auth-1", privPassphrase: "switch-priv-1"),
                         engineId: Array("switch-engine".utf8), crypto: TestSnmpCrypto())
    }

    @Test func aRefusalFromAnEngineNotKnownAsThePrintersIsOfflineNotRefused() async throws {
        let known = try await Self.known()
        #expect(known.engineId == Self.engineHex) // remembered from its signed answer

        // Another device's engine: offline, so Fix it… looks for the printer; no refused alert.
        let events = Events()
        let monitor = Self.monitor(try Self.switchAgent(), known, try Self.v3Login(), events)
        #expect(await monitor.check() == false)
        let view = await monitor.view
        #expect(view.phase == .offline)
        #expect(view.statusMessage == "Can't reach the printer")
        #expect(!events.snapshots.contains { $0.loginRefused != nil })

        // No engine remembered (never read over SNMPv3): even the printer's own refusal can't be told from another device's.
        let wrong = try Self.v3Login(auth: "wrong-auth-pass")
        let session = PrinterSession(id: Self.printer, recipe: PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: try Self.v3Agent(),
                                                                             snmpLogin: { wrong }),
                                     accepted: { [] }, acceptUuids: { _ in })
        var unknown = known, another = known
        unknown.engineId = nil
        another.engineId = "80001F8880AAAAAAAAAAAAAAAA"
        guard case .offline = try await session.connect(PrinterWhere(Self.host, snmp: unknown)) else {
            Issue.record("not offline without an engine")
            return
        }
        guard case .offline = try await session.connect(PrinterWhere(Self.host, snmp: another)) else {
            Issue.record("not offline from another engine")
            return
        }
        guard case .refused = try await session.connect(PrinterWhere(Self.host, snmp: known)) else {
            Issue.record("not refused from its engine")
            return
        }
    }

    @Test func aSignedConnectionRemembersThePrintersEngineSoItsRefusalCountsAfter() async throws {
        let agent = SnmpV3Tests.Spoofer(try Self.v3Agent())
        var known = try await Self.known()
        known.engineId = nil // read over v2c before, say
        let monitor = Self.monitor(agent, known, try Self.v3Login())
        #expect(await monitor.check())
        let remembered = try #require(await monitor.target.snmp)
        #expect(remembered.engineId == Self.engineHex) // kept in state.json when the app remembers it
        #expect(remembered.serialNumber == known.serialNumber)

        agent.spoof.withLock { $0 = (Usm.wrongDigests, Self.engine) } // its administrator changed the key
        try await Task.sleep(for: SnmpPrinterClient.sharedFor + .milliseconds(100))
        #expect(await monitor.check() == false) // on the open connection: offline (anyone can send one)
        #expect(await monitor.check() == false) // a new connection, its own engine: refused
        #expect(await monitor.view.phase == .refused)

        // What state.json keeps of it: the engine ID (not a secret), never the login.
        let json = String(decoding: try JSONEncoder().encode(remembered), as: UTF8.self)
        #expect(json.contains(Self.engineHex))
        #expect(!json.contains(Self.user.authPassphrase) && !json.contains(Self.user.privPassphrase) && !json.contains(Self.user.name))
    }

    @Test func checkingALoginRefusedByAnEngineNotKnownAsThePrintersMayBeSavedAnyway() async throws {
        let device = try await Self.known()
        let login = try Self.v3Login(), switchAgent = try Self.switchAgent(), agent = try Self.v3Agent()
        #expect(await SnmpLoginCheck.check(login, host: Self.host, known: device, transport: switchAgent) == .refused(.unknownUser, fromThisPrinter: false))
        var noEngine = device
        noEngine.engineId = nil
        let wrong = try Self.v3Login(auth: "wrong-auth-pass")
        #expect(await SnmpLoginCheck.check(wrong, host: Self.host, known: noEngine, transport: agent) == .refused(.wrongAuthKey, fromThisPrinter: false))
        #expect(await SnmpLoginCheck.check(wrong, host: Self.host, known: nil, transport: agent) == .refused(.wrongAuthKey, fromThisPrinter: false))
        #expect(await SnmpLoginCheck.check(wrong, host: Self.host, known: device, transport: agent) == .refused(.wrongAuthKey, fromThisPrinter: true))
    }

    @Test func aNewLoginIsUsedByTheNextCheckEvenOnAConnectionStillGood() async throws {
        let agent = try Self.agent()
        let identity = try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.login(Self.secret))).identity
        let logins = MemorySnmpLogins()
        logins.save(try Self.login(Self.secret), for: Self.printer)
        let recipe = PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: agent, snmpLogin: { logins.get(Self.printer) })
        let monitor = PrinterMonitor(id: Self.printer, name: "Laser", target: PrinterWhere(Self.host, snmp: SnmpDevice.from(identity)),
                                     recipe: recipe, accepted: { [] }, acceptUuids: { _ in }, onEvent: { _ in })
        #expect(await monitor.check()) // the window closed: checked now and then on the connection made

        logins.save(try Self.login("changed"), for: Self.printer) // SNMP Access… while it's checked in the background
        #expect(await monitor.check() == false) // asked with the new community, which the agent ignores
        #expect(agent.received.last?.community == "changed")
    }

    @Test func checkingALoginSaysWhetherItsAnsweredOrWhichPartIsRefused() async throws {
        let agent = try Self.v3Agent()
        let device = SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.host, login: Self.v3Login())).identity)
        #expect(await SnmpLoginCheck.check(try Self.v3Login(), host: Self.host, known: device, transport: agent) == .answered)
        #expect(await SnmpLoginCheck.check(try Self.v3Login(auth: "wrong-auth-pass"), host: Self.host, known: device, transport: agent)
            == .refused(.wrongAuthKey))
        #expect(await SnmpLoginCheck.check(try Self.v3Login(priv: "wrong-priv-pass"), host: Self.host, known: device, transport: agent)
            == .refused(.wrongPrivKey))
        #expect(await SnmpLoginCheck.check(try Self.login(Self.secret), host: Self.host, known: device, transport: agent) == .noAnswer)

        let other = SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/workgroup-laser.txt").replacingOccurrences(of: "DEMO0005200", with: "OTHER0001")),
                              community: Self.secret)
        #expect(await SnmpLoginCheck.check(try Self.login(Self.secret), host: Self.host, known: device, transport: other) == .anotherDevice)
    }

    @Test func neitherWhatIsRememberedNorALogLineHoldsTheCommunity() async throws {
        let identity = try #require(try await SnmpPrinterClient.probe(transport: Self.agent(), host: Self.host, login: Self.login(Self.secret))).identity
        #expect(identity.loginOrPublic.community == Self.secret) // the identity knows it, for this run's reads only

        // state.json keeps a printer read over SNMP as its SnmpDevice: what the printer said, never the login.
        let known = KnownPrinter(uuid: Self.host, name: "Laser", host: Self.host, snmp: SnmpDevice.from(identity))
        var state = PrintState()
        state.printers = [known]
        let remembered = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        #expect(!remembered.contains(Self.secret))
        #expect(!remembered.lowercased().contains("community"))

        // What the log may show of either.
        for shown in [String(describing: identity), String(reflecting: identity), "\(identity.loginOrPublic)",
                      String(describing: PrinterWhere(Self.host, snmp: SnmpDevice.from(identity)))] {
            #expect(!shown.contains(Self.secret), "\(shown)")
        }
        var dumped = ""
        dump(identity, to: &dumped)
        #expect(!dumped.contains(Self.secret))
    }

    @Test func theAppsStateFileHasNoPlaceForALogin() throws {
        // The app's state (state.json) is written from PrintState and KnownPrinter: neither may name a login or a community.
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/SnmpLoginTests.swift
        for _ in 0..<3 { url.deleteLastPathComponent() }
        let source = try String(contentsOf: url.appendingPathComponent("Sources/PrintCore/Model/PrintState.swift"), encoding: .utf8)
        #expect(!source.contains("SnmpLogin"))
        #expect(!source.lowercased().contains("community"))
    }
}
