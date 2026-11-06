import Foundation
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

    @Test func theStoreKeepsRenamesAndDeletesAPrintersLogin() throws {
        let store = MemorySnmpLogins()
        let logins: any SnmpLogins = store
        #expect(logins.get(Self.printer) == nil)
        logins.save(try Self.login(Self.secret), for: Self.printer)
        #expect(logins.get(Self.printer.uppercased())?.community == Self.secret)

        logins.rename(Self.printer, to: Self.host)
        #expect(logins.get(Self.printer) == nil)
        #expect(logins.get(Self.host)?.community == Self.secret)

        logins.save(.public, for: Self.host) // public: what was kept goes, nothing takes its place
        #expect(logins.get(Self.host) == nil)
        #expect(store.count == 0)
    }

    @Test func renamingNeverOverwritesALoginKeptUnderTheNewId() throws {
        let logins: any SnmpLogins = MemorySnmpLogins()
        logins.save(try Self.login("first"), for: "a")
        logins.save(try Self.login("second"), for: "b")
        logins.rename("a", to: "b")
        #expect(logins.get("b")?.community == "second")
        #expect(logins.get("a") == nil)
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
