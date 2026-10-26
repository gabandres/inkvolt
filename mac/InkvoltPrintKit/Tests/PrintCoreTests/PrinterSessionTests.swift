import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// The printer session: connecting with one recipe, asking who answers before reading, upgrading an SNMP-only printer, and
/// checking an address the printer is announced at, over fixture printers and a clock of its own. Ported from
/// PrinterSessionTests.cs.
struct PrinterSessionTests {
    private static let printer = "12345678-1234-4abc-8def-123456789abc", other = "87654321-4321-4cba-8fed-cba987654321"
    private static let host = FixtureTransport.demoHost, newHost = "192.0.2.23"

    /// The demo laser (m234dw's fixtures) reporting `uuid`; every document asked for is recorded.
    final class Laser: Sendable {
        private let state = Mutex<(uuid: String, seen: [String])>((PrinterSessionTests.printer, []))

        init(uuid: String = PrinterSessionTests.printer) { state.withLock { $0.uuid = uuid } }

        var uuid: String {
            get { state.withLock { $0.uuid } }
            set { state.withLock { $0.uuid = newValue } }
        }

        var seen: [String] { state.withLock { $0.seen } }
        func clear() { state.withLock { $0.seen.removeAll() } }

        func transport() -> FixtureTransport {
            FixtureTransport(document: { [self] name in
                let uuid = state.withLock { s in
                    s.seen.append(name)
                    return s.uuid
                }
                guard let bytes = try? Fixtures.data("m234dw/\(name)") else { return nil }
                guard name == "DevMgmt_ProductConfigDyn.xml" || name == "eSCL_ScannerCapabilities.xml" else { return bytes }
                return Array(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: PrinterSessionTests.printer, with: uuid).utf8)
            })
        }
    }

    final class Clock: Sendable {
        private let time = Mutex(Date(timeIntervalSince1970: 1_792_918_800)) // 2026-10-25 09:00 UTC
        var now: Date { time.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
    }

    final class Accepted: Sendable {
        private let list = Mutex<[String]>([])
        var all: [String] { list.withLock { $0 } }
        func add(_ uuids: [String]) { list.withLock { $0 += uuids } }
    }

    private static func session(_ transport: @escaping HttpTransportFactory, _ clock: Clock, accepted: Accepted = Accepted(), id: String = printer,
                                snmp: (any SnmpTransport)? = nil) -> PrinterSession {
        PrinterSession(id: id, recipe: PrinterRecipe(transport: transport, snmp: snmp ?? SnmpRouter([:]), now: { clock.now }),
                       accepted: { accepted.all }, acceptUuids: { accepted.add($0) })
    }

    private static func one(_ t: any HttpTransport) -> HttpTransportFactory { { _, _ in t } }

    @Test func connectsAndReadsThisPrinter() async throws {
        let laser = Laser()
        let session = Self.session(Self.one(laser.transport()), Clock())
        guard case .connected(let connection, _) = try await session.connect(PrinterWhere(Self.host)) else { Issue.record("not connected"); return }
        #expect(await session.connection === connection)
        guard case .read(let reading) = try await session.read(PrinterWhere(Self.host)) else { Issue.record("not read"); return }
        #expect(reading.status.message == "Ready")
    }

    @Test func anotherDeviceAtTheAddressIsFoundBeforeAnythingOfItIsRead() async throws {
        let laser = Laser()
        let clock = Clock()
        let session = Self.session(Self.one(laser.transport()), clock)
        _ = try await session.connect(PrinterWhere(Self.host))

        laser.uuid = Self.other // DHCP gave the address to another device of the same kind
        clock.advance(PrinterSession.identityInterval + 1)
        laser.clear()
        let step = try await session.read(PrinterWhere(Self.host))

        guard case .elsewhere(let uuids, _) = step else { Issue.record("not elsewhere"); return }
        #expect(uuids == [Self.other])
        #expect(await session.connection == nil)
        #expect(!laser.seen.contains("DevMgmt_ProductStatusDyn.xml")) // its status was never read
    }

    @Test func identityIsAskedEvery30SecondsAndAtOnceAfterAPause() async throws {
        let laser = Laser()
        let clock = Clock()
        let session = Self.session(Self.one(laser.transport()), clock)
        _ = try await session.connect(PrinterWhere(Self.host))
        func identityReads() -> Int { laser.seen.filter { $0 == "DevMgmt_ProductConfigDyn.xml" }.count }

        laser.clear()
        _ = try await session.read(PrinterWhere(Self.host))
        clock.advance(20)
        _ = try await session.read(PrinterWhere(Self.host))
        #expect(identityReads() == 0) // asked when connecting, a moment ago

        clock.advance(15)
        _ = try await session.read(PrinterWhere(Self.host))
        #expect(identityReads() == 1)

        await session.askIdentityFirst() // the window was hidden: the reused connection is asked first
        _ = try await session.read(PrinterWhere(Self.host))
        #expect(identityReads() == 2)
    }

    @Test func connectingToAnotherDeviceKeepsNothingAndAnAcceptedUuidCountsAsThisPrinter() async throws {
        let laser = Laser(uuid: Self.other)
        let accepted = Accepted()
        let session = Self.session(Self.one(laser.transport()), Clock(), accepted: accepted)

        guard case .elsewhere(let uuids, _) = try await session.connect(PrinterWhere(Self.host)) else { Issue.record("not elsewhere"); return }
        #expect(uuids == [Self.other])
        #expect(await session.connection == nil)

        accepted.add([Self.other]) // "This is my printer"
        guard case .connected = try await session.connect(PrinterWhere(Self.host)) else { Issue.record("not connected"); return }
    }

    @Test func anAnnouncedAddressIsFollowedOnlyWhenItIsThisPrinterAndARefusalIsRememberedAWhile() async throws {
        let here = Laser()
        let there = Laser(uuid: Self.other)
        let clock = Clock()
        let network: HttpTransportFactory = { _, _ in HostRouter([Self.host: here.transport(), Self.newHost: there.transport()]) }
        let session = Self.session(network, clock)
        _ = try await session.connect(PrinterWhere(Self.host))

        #expect(try await session.checkAddress(current: PrinterWhere(Self.host), candidate: PrinterWhere(Self.newHost), currentAnswers: true,
                                               announcedModel: nil) == .anotherDevice)
        there.uuid = Self.printer
        there.clear()
        #expect(try await session.checkAddress(current: PrinterWhere(Self.host), candidate: PrinterWhere(Self.newHost), currentAnswers: true,
                                               announcedModel: nil) == .skipped)
        #expect(there.seen.isEmpty) // announced again and again: not asked every time

        clock.advance(PrinterSession.refusedFor)
        #expect(try await session.checkAddress(current: PrinterWhere(Self.host), candidate: PrinterWhere(Self.newHost), currentAnswers: true,
                                               announcedModel: nil) == .move)
    }

    @Test func anAddressThatCanNotTellIsFollowedOnlyWhenTheOneInUseStopsAnsweringAsThisPrinter() async throws {
        let here = Laser()
        let network: HttpTransportFactory = { _, _ in HostRouter([Self.host: here.transport()]) }
        let session = Self.session(network, Clock())
        _ = try await session.connect(PrinterWhere(Self.host))

        #expect(try await session.checkAddress(current: PrinterWhere(Self.host), candidate: PrinterWhere(Self.newHost), currentAnswers: true,
                                               announcedModel: "HP LaserJet MFP M234dw") == .noAnswer)
        let other = Self.session(network, Clock())
        #expect(try await other.checkAddress(current: PrinterWhere(Self.host), candidate: PrinterWhere(Self.newHost), currentAnswers: false,
                                             announcedModel: "HP LaserJet MFP M234dw") == .move)
    }

    @Test func anSnmpOnlyPrinterAnnouncedElsewhereIsToldApartByItsSerialNumber() async throws {
        let agent = try demoAgent("workgroup-laser.txt")
        let known = SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: agent, host: Self.newHost)).identity)
        let snmp = SnmpRouter([Self.newHost: agent])
        let session = Self.session(Self.one(Printers.none()), Clock(), snmp: snmp)

        #expect(try await session.checkAddress(current: PrinterWhere(Self.host, snmp: known), candidate: PrinterWhere(Self.newHost),
                                               currentAnswers: true, announcedModel: nil) == .move)
        var otherSerial = known
        otherSerial.serialNumber = "DEMO0004400"
        let other = Self.session(Self.one(Printers.none()), Clock(), snmp: snmp)
        #expect(try await other.checkAddress(current: PrinterWhere(Self.host, snmp: otherSerial), candidate: PrinterWhere(Self.newHost),
                                             currentAnswers: true, announcedModel: nil) == .anotherDevice)
    }

    @Test func anSnmpOnlyPrinterIsUpgradedWhenItAnswersIppAndItsUuidIsRemembered() async throws {
        let host = "192.0.2.11"
        let agent = try demoAgent("color-mfp.txt")
        let known = SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: agent, host: host)).identity)
        let awake = Mutex(false)
        let network: HttpTransportFactory = { _, _ in
            awake.withLock { $0 } ? HostRouter([host: Printers.ippOnly()]) : Printers.none()
        }
        let clock = Clock()
        let accepted = Accepted()
        let session = Self.session(network, clock, accepted: accepted, id: PrinterId.normalize(nil, host: host), snmp: agent)
        let target = PrinterWhere(host, snmp: known)

        guard case .connected(let first, _) = try await session.connect(target) else { Issue.record("not connected"); return }
        #expect(first.overSnmp)
        awake.withLock { $0 = true }
        #expect(try await session.tryUpgrade(target) == nil) // asked again only after a while

        clock.advance(PrinterSession.upgradeInterval)
        guard case .connected(let upgraded, let isUpgrade) = try await session.tryUpgrade(target) else { Issue.record("not upgraded"); return }
        #expect(isUpgrade)
        #expect(await session.connection === upgraded)
        #expect(!upgraded.overSnmp)
        #expect(accepted.all == ["2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"])
    }

    @Test func anotherDeviceThatAnswersIppAtAnSnmpOnlyPrintersAddressIsNeverUpgradedTo() async throws {
        // An SNMP-only printer added by address (no UUID: its id comes from the address); the window was hidden for a while,
        // and DHCP gave the address to an IPP device with another SNMP serial number, whose IPP reports no serial at all.
        let host = "192.0.2.50"
        let printer = try demoAgent("workgroup-laser.txt")
        let otherAgent = try demoAgent("color-mfp.txt")
        let known = SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: printer, host: host)).identity)
        #expect(known.identify(try #require(try await SnmpPrinterClient.probe(transport: otherAgent, host: host)).identity) == .different)
        let snmp = SwitchableAgent(printer)
        let ippThere = Mutex(false)
        let network: HttpTransportFactory = { _, _ in
            ippThere.withLock { $0 } ? HostRouter([host: Printers.ippOnly()]) : Printers.none()
        }
        let clock = Clock()
        let accepted = Accepted()
        let session = Self.session(network, clock, accepted: accepted, id: PrinterId.normalize(nil, host: host), snmp: snmp)
        let target = PrinterWhere(host, snmp: known)
        guard case .connected(let first, _) = try await session.connect(target) else { Issue.record("not connected"); return }
        #expect(first.overSnmp)

        await session.askIdentityFirst() // hidden, then shown again
        clock.advance(PrinterSession.upgradeInterval + 60)
        snmp.to = otherAgent
        ippThere.withLock { $0 = true }
        let step = try await session.tryUpgrade(target)

        guard case .elsewhere? = step else { Issue.record("not elsewhere"); return }
        #expect(accepted.all.isEmpty) // its UUIDs never became this printer's
        #expect(await session.connection == nil)
    }
}
