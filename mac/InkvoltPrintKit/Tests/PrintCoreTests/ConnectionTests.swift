import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// The printer status module (`PrinterConnection.read`): one read, one fallback order (LEDM, CDM, IPP, SNMP) and one
/// error rule, over fixture printers whose requests can be made to fail. Ported from PrinterReadingTests.cs.
struct PrinterReadingTests {
    @Test func anIppPrinterIsReadWithOneRequest() async throws {
        let network = Network(Printers.ippOnly())
        let conn = try await PrinterConnection.open("192.0.2.11", transport: network)
        network.fail = true
        network.clear()

        let reading = try await conn.read()

        #expect(reading.status.alerts.map(\.message) == ["Yellow ink is low."])
        #expect(reading.supplies?.count == 5)
        #expect(reading.usage == nil) // page counts are LEDM's
        #expect(network.count(\.isIpp) == 1)
    }

    @Test func anLedmPrinterGivesStatusSuppliesAndUsageWithoutAskingIpp() async throws {
        let network = Network(Printers.ledmAndIpp())
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true
        #expect(conn.probe.interfaces.contains("IPP"))
        network.clear()

        let reading = try await conn.read()

        #expect(reading.status.message == "Ready")
        #expect(reading.supplies?.count == 1) // the laser's one toner, not the inkjet's five inks
        #expect(reading.usage?.totalImpressions != nil)
        #expect(network.count(\.isIpp) == 0)
        #expect(network.count { $0.is("/ProductUsageDyn.xml") } == 1) // counters and page estimates: one read
    }

    @Test func suppliesThatLedmAnswersWithAnErrorComeFromIpp() async throws {
        let network = Network(Printers.ledmAndIpp()) { $0.is("/ConsumableConfigDyn.xml") ? Network.status(500) : nil }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true
        network.clear()

        let reading = try await conn.read()

        #expect(reading.status.message == "Ready") // still LEDM's
        #expect(reading.supplies?.count == 5)
        #expect(network.count(\.isIpp) == 1)
        #expect(try await conn.supplies().count == 5)
    }

    @Test func statusAndSuppliesBothFallingBackToIppTakeOneRequest() async throws {
        let network = Network(Printers.ledmAndIpp()) { $0.is("/ProductStatusDyn.xml") || $0.is("/ConsumableConfigDyn.xml") ? Network.status(503) : nil }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true
        network.clear()

        let reading = try await conn.read()

        #expect(reading.status.alerts.map(\.message) == ["Yellow ink is low."])
        #expect(reading.supplies?.count == 5)
        #expect(network.count(\.isIpp) == 1)
    }

    @Test func aPrinterThatAnswersOnlyWithErrorsIsUnavailableAndItsSuppliesUnknown() async throws {
        let network = Network(Printers.ledmAndIpp()) {
            $0.is("/ProductStatusDyn.xml") || $0.is("/ConsumableConfigDyn.xml") || $0.isIpp ? Network.status(503) : nil
        }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        #expect(conn.probe.interfaces.contains("IPP")) // answered while it was probed
        network.fail = true

        let reading = try await conn.read()

        #expect(reading.status.isUnavailable)
        #expect(!reading.isOffline)
        #expect(reading.supplies == nil) // not "none": the last known levels stay on screen
        #expect(try await conn.supplies().isEmpty)
    }

    @Test func aNetworkFailureIsOfflineAndNothingMoreIsAsked() async throws {
        let network = Network(Printers.ledmAndIpp()) { $0.is("/ProductStatusDyn.xml") ? Network.refuse() : nil }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true
        network.clear()

        let reading = try await conn.read()

        #expect(reading.isOffline)
        #expect(reading.supplies == nil)
        #expect(network.count(\.isIpp) == 0) // the same host: no second timeout
        #expect(try await conn.status().code == "offline")
    }

    @Test func suppliesThatTimeOutAfterTheStatusAnsweredKeepTheStatus() async throws {
        let network = Network(Printers.ledmAndIpp()) { $0.is("/ConsumableConfigDyn.xml") ? Network.refuse() : nil }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true
        network.clear()

        let reading = try await conn.read()

        #expect(reading.status.message == "Ready")
        #expect(reading.supplies == nil)
        #expect(network.count(\.isIpp) == 0)
    }

    @Test func suppliesThatTimeOutWhileLedmStatusErrsLeaveTheStatusToIppAndThePrinterOnline() async throws {
        let network = Network(Printers.ledmAndIpp()) {
            $0.is("/ProductStatusDyn.xml") ? Network.status(503) : $0.is("/ConsumableConfigDyn.xml") ? Network.refuse() : nil
        }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true

        let reading = try await conn.read()

        #expect(!reading.isOffline)
        #expect(reading.status.alerts.map(\.message) == ["Yellow ink is low."]) // IPP's status
        #expect(reading.supplies == nil) // unknown this time: the last known levels stay
    }

    @Test func usageCountersThatFailAreJustMissing() async throws {
        let network = Network(Printers.ledmAndIpp()) { $0.is("/ProductUsageDyn.xml") ? Network.refuse() : nil }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true

        let reading = try await conn.read()

        #expect(reading.status.message == "Ready")
        #expect(reading.supplies?.count == 1)
        #expect(reading.usage == nil)
    }

    @Test func theUuidComesFromTheNextInterfaceWhenOneErrsAndFromNoneWhenThePrinterIsGone() async throws {
        let network = Network(Printers.ledmAndIpp()) { $0.is("/ProductConfigDyn.xml") ? Network.status(500) : nil }
        let conn = try await PrinterConnection.open(FixtureTransport.demoHost, transport: network)
        network.fail = true

        #expect(try await conn.readUuids().map { $0.replacingOccurrences(of: "urn:uuid:", with: "") } == ["2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"])

        network.fault = { $0.is("/ProductConfigDyn.xml") ? Network.refuse() : nil }
        network.clear()
        #expect(try await conn.readUuids().isEmpty)
        #expect(network.count(\.isIpp) == 0)
    }
}

/// Printers reached only over SNMP, and printers that never are. Ported from SnmpTests.cs (the connection's priority).
struct SnmpConnectionTests {
    @Test func aPrinterThatAnswersOnlySnmpConnectsOverSnmp() async throws {
        let agent = try demoAgent("workgroup-laser.txt")
        let conn = try await PrinterConnection.open("192.0.2.14", transport: Printers.none(), snmp: SnmpRouter(["192.0.2.14": agent]))
        #expect(conn.probe.reachable)
        #expect(conn.probe.interfaces == ["SNMP"])
        #expect(conn.probe.model == "Demo Laser 5200 Series" && conn.probe.serialNumber == "DEMO0005200" && conn.probe.location == "Office, 2nd floor")
        #expect(conn.probe.uuid == nil) // SNMP has no UUID: the printer is known by its address
        #expect(try await conn.status().message == "Ready")
        #expect(try await conn.supplies().count == 3)
        #expect(try await conn.readUuids().isEmpty)
    }

    @Test func aPrinterThatAnswersIppIsNeverAskedOverSnmp() async throws {
        let agent = try demoAgent("color-mfp.txt")
        let conn = try await PrinterConnection.open("192.0.2.11", transport: HostRouter(["192.0.2.11": Printers.ippOnly()]), snmp: agent)
        #expect(conn.probe.interfaces.contains("IPP"))
        #expect(!conn.probe.interfaces.contains("SNMP"))
        _ = try await conn.status()
        _ = try await conn.supplies()
        #expect(agent.requests == 0)
    }

    @Test func withoutAnSnmpTransportNothingIsAskedOverSnmp() async throws {
        #expect(!(try await PrinterConnection.open("192.0.2.14", transport: Printers.none())).probe.reachable)
    }

    @Test func anSnmpPrinterThatStopsAnsweringIsOffline() async throws {
        let snmp = SwitchableAgent(try demoAgent("workgroup-laser.txt"))
        let conn = try await PrinterConnection.open("192.0.2.14", transport: Printers.none(), snmp: snmp)
        snmp.to = nil // turned off
        #expect(try await conn.status().code == "offline")
    }

    @Test func onlyAPrinterAddedAsSnmpOnlyIsReadOverSnmp() async throws {
        let agent = try demoAgent("workgroup-laser.txt")
        // An IPP printer waking up answers SNMP before HTTP: it is offline for a moment, not an SNMP-only printer.
        let waking = try await PrinterConnection.open("192.0.2.14", transport: Printers.none(), snmp: SnmpDevice.transport(for: nil, agent))
        #expect(!waking.probe.reachable)
        #expect(agent.requests == 0)

        let added = SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14")).identity)
        let snmpOnly = try await PrinterConnection.open("192.0.2.14", transport: Printers.none(), snmp: SnmpDevice.transport(for: added, agent))
        #expect(snmpOnly.probe.interfaces == ["SNMP"])
    }

    @Test func anSnmpConnectionMovesToIppWhenThePrinterAnswersIt() async throws {
        let agent = try demoAgent("color-mfp.txt")
        let known = SnmpDevice.from(try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.11")).identity)
        let conn = try await PrinterConnection.open("192.0.2.11", transport: Printers.none(), snmp: agent)
        #expect(try await conn.tryRicher(known, transport: Printers.none()) == nil)
        let richer = try #require(try await conn.tryRicher(known, transport: HostRouter(["192.0.2.11": Printers.ippOnly()])))
        #expect(richer.probe.interfaces.contains("IPP"))
        #expect(!richer.probe.interfaces.contains("SNMP"))
    }
}

/// Newer HP printers over CDM, and LEDM printers that must never be taken for them. Ported from CdmTests.cs.
struct CdmConnectionTests {
    /// Records each request's method and path; answers with `reply`.
    final class Scripted: HttpTransport {
        private let seen = Mutex<[(method: String, path: String)]>([])
        private let reply: @Sendable (HttpRequest) async throws -> HttpResponse

        init(_ reply: @escaping @Sendable (HttpRequest) async throws -> HttpResponse) { self.reply = reply }

        var requests: [(method: String, path: String)] { seen.withLock { $0 } }
        var askedCdm: Bool { requests.contains { $0.path.hasPrefix("/cdm/") } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            seen.withLock { $0.append((request.method, request.url.path)) }
            return try await reply(request)
        }
    }

    @Test func aPrinterWithoutLedmConnectsOverCdm() async throws {
        let conn = try await PrinterConnection.open("192.0.2.13", transport: Printers.folder("cdm-laser"))
        #expect(conn.cdm != nil)
        #expect(conn.ledm == nil)
        #expect(conn.probe.interfaces.contains("CDM"))
        #expect(conn.probe.reachable)
        #expect(conn.probe.brand == .hp)
        #expect(!conn.probe.hasHpInterfaces) // settings, firmware updates and counters stay LEDM only
        #expect(conn.probe.model == "HP Color LaserJet Pro MFP 3302")
        #expect(conn.probe.uuid == "4d1e2c3b-0a9f-4e8d-b7c6-5a4b3c2d1e0f")
        #expect(conn.probe.firmware?.display == "6.28.3.30-202606111700 (2026-07-24)")
        #expect(try await conn.status().message == "Ready")
        #expect(try await conn.supplies().count == 4)
    }

    @Test func cdmIsOnlyAskedWhenLedmIsMissingAndOnlyWithGets() async throws {
        let ledm = Scripted { request in
            let path = request.url.path
            let file = path.hasPrefix("/cdm/") ? "cdm-laser/\(FixtureTransport.documentName(path))"
                : path.hasPrefix("/DevMgmt/DiscoveryTree") ? "m234dw/DevMgmt_DiscoveryTree.xml" : nil
            guard let file, let body = try? Fixtures.data(file) else { return HttpResponse(status: 404) }
            return HttpResponse(status: 200, body: body)
        }
        _ = try await PrinterConnection.open("192.0.2.10", transport: ledm)
        #expect(!ledm.askedCdm) // LEDM answered: CDM never asked

        let fixture = Printers.folder("cdm-laser")
        let cdm = Scripted { try await fixture.send($0) }
        let conn = try await PrinterConnection.open("192.0.2.13", transport: cdm)
        _ = try await conn.status()
        _ = try await conn.supplies()
        #expect(cdm.requests.contains { $0.path == "/cdm/system/v1/identity" })
        #expect(cdm.requests.filter { $0.path.hasPrefix("/cdm/") }.allSatisfy { $0.method == "GET" })
    }

    @Test func httpsWhenThePrinterRedirectsThere() async throws {
        let fixture = Printers.folder("cdm-laser")
        let redirecting = Scripted { request in
            if request.url.scheme == "http" && request.url.path.hasPrefix("/cdm/") {
                return HttpResponse(status: 301, headers: ["Location": "https://\(request.url.host!):443\(request.url.path)"])
            }
            return try await fixture.send(request)
        }
        let conn = try await PrinterConnection.open("192.0.2.13", transport: redirecting)
        #expect(conn.probe.model == "HP Color LaserJet Pro MFP 3302")
        #expect(conn.cdm?.root.scheme == "https")
        #expect(try await conn.supplies().count == 4)
    }

    /// The DiscoveryTree answers with `status` (and a Location for redirects); CDM from the laser fixtures.
    private static func probeWithTree(_ status: Int, location: String? = nil) async throws -> (askedCdm: Bool, probe: ProbeResult) {
        let handler = Scripted { request in
            let path = request.url.path
            if path == "/DevMgmt/DiscoveryTree.xml" { return HttpResponse(status: status, headers: location.map { ["Location": $0] } ?? [:]) }
            if path.hasPrefix("/cdm/"), let body = try? Fixtures.data("cdm-laser/\(FixtureTransport.documentName(path))") {
                return HttpResponse(status: 200, body: body)
            }
            return HttpResponse(status: 404)
        }
        let probe = try await PrinterConnection.probe(DeviceHttp(host: "192.0.2.13", transport: handler))
        return (handler.askedCdm, probe)
    }

    @Test(arguments: [503, 500, 401, 400]) // 503: an LEDM printer waking up
    func anLedmErrorPageIsLedmBusyNotACdmPrinter(_ status: Int) async throws {
        let (askedCdm, probe) = try await Self.probeWithTree(status)
        #expect(!askedCdm)
        #expect(probe.cdm == nil)
    }

    @Test(arguments: [
        ("/hp/device/webAccess/index.htm", true), // the web page instead: no LEDM
        ("https://192.0.2.13/DevMgmt/DiscoveryTree.xml", false), // LEDM over HTTPS: LEDM, not CDM
        ("/DevMgmt/DiscoveryTree.xml?x=1", false),
    ] as [(String, Bool)])
    func aRedirectCountsAsNoLedmOnlyAwayFromLedm(_ location: String, _ cdm: Bool) async throws {
        let (askedCdm, probe) = try await Self.probeWithTree(301, location: location)
        #expect(askedCdm == cdm)
        #expect((probe.cdm != nil) == cdm)
    }

    @Test func aMissingDiscoveryTreeIsNoLedm() async throws {
        let (askedCdm, probe) = try await Self.probeWithTree(404)
        #expect(askedCdm)
        #expect(probe.model == "HP Color LaserJet Pro MFP 3302")
    }

    @Test func cdmPathsMapToJsonFixtures() {
        #expect(FixtureTransport.documentName("/cdm/supply/v1/suppliesPublic") == "cdm_supply_v1_suppliesPublic.json")
    }
}

/// IPP Everywhere / eSCL printers of other brands: connecting, the IPP probe, web page and icons. Ported from
/// OtherBrandsTests.cs.
struct OtherBrandsConnectionTests {
    private static func ipp(_ text: String) throws -> IppResponse {
        try IppCodec.decode(IppCodec.encodeResponse(status: 0, requestId: 1, IppText.parse(text)))
    }

    @Test func demoInkjetConnectsOverIppAndEscl() async throws {
        let conn = try await PrinterConnection.open("192.0.2.11", transport: Printers.inkjet())
        let p = conn.probe
        #expect(p.interfaces == ["eSCL", "IPP"])
        #expect(p.brand == .epson)
        #expect(!p.hasHpInterfaces)
        #expect(p.model == "EPSON ET-0000 Series")
        #expect(p.uuid == "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b")
        #expect(p.firmware?.display == "05.12.XA01")
        #expect(p.location == "Office, second floor")
        #expect(p.webPage == URL(string: "http://192.0.2.11/PRESENTATION/BONJOUR"))
        #expect(try await conn.status().alerts.map(\.message) == ["Yellow ink is low."])
        #expect(try await conn.supplies().count == 5)
        #expect(p.scanner?.sources == [.platen, .adf, .adfDuplex])
    }

    @Test func printerWithoutAnEventFeedIsReadRightAwayNotAfterTheFirstInterval() async throws {
        let conn = try await PrinterConnection.open("192.0.2.11", transport: Printers.inkjet())
        var events = conn.watch(fallbackInterval: .seconds(600)).makeAsyncIterator()
        #expect(await events.next() == "start")
    }

    @Test(arguments: [
        ("http://192.0.2.11/PRESENTATION/BONJOUR", "http://192.0.2.11/PRESENTATION/BONJOUR"),
        ("https://192.0.2.11:443/", "https://192.0.2.11/"),
        ("http://example.com/phish", nil), // another host: not the printer's page
        ("file:///C:/Windows", nil),
        ("javascript:alert(1)", nil),
    ] as [(String, String?)])
    func webPageMustBeOnThePrinter(_ moreInfo: String, _ expected: String?) throws {
        let p = ProbeResult(host: "192.0.2.11", ipp: try Self.ipp("printer-more-info uri \(moreInfo)"))
        #expect(p.webPage?.absoluteString == expected)
    }

    @Test func printerIconsOnThePrinterOnly128PxFirst() throws {
        let p = ProbeResult(host: "192.0.2.11", ipp: try Self.ipp("""
            printer-icons uri https://192.0.2.11/icon-48.png
            printer-icons uri https://192.0.2.11/icon-128.png
            printer-icons uri http://example.com/icon-512.png
            printer-icons uri https://192.0.2.11/icon-512.png
            """))
        #expect(p.icons.map(\.path) == ["/icon-128.png", "/icon-512.png", "/icon-48.png"])
    }

    @Test func ippEndpointHintFromDnsSdIsTried() async throws {
        // Mac difference: the hint and the plain endpoint are asked at the same time, so which arrives first isn't fixed.
        let seen = Mutex<[String]>([])
        let handler = FixtureTransport(document: { name in
            if name.hasSuffix(".ipp.txt") { seen.withLock { $0.append(name) } }
            return name == "ipp_printer.ipp.txt" ? try? Fixtures.data("inkjet-demo/ipp_print.ipp.txt") : nil
        })
        let conn = try await PrinterConnection.open("192.0.2.11", transport: handler, ippHint: URL(string: "http://192.0.2.11:631/ipp/printer"))
        #expect(conn.ipp?.endpoint.path == "/ipp/printer")
        #expect(seen.withLock { $0 }.contains("ipp_printer.ipp.txt"))
    }

    @Test func ippsIsTriedWhenPlainIppIsRefused() async throws {
        let handler = Network(Printers.inkjet(), failNow: true) { $0.url.scheme == "http" && $0.url.port == 631 ? Network.refuse() : nil }
        let conn = try await PrinterConnection.open("192.0.2.11", transport: handler)
        #expect(conn.probe.ippEndpoint?.absoluteString == "https://192.0.2.11:631/ipp/print")
        #expect(conn.ipp?.endpoint.absoluteString == "https://192.0.2.11:631/ipp/print")
        #expect(conn.probe.brand == .epson)
    }

    // These two time the IPP step alone (the Mac port's): the whole probe also reads LEDM and eSCL, which a full parallel run
    // can slow by seconds without the IPP step waiting on anything.
    @Test func aSilentHintDoesntHoldUpThePlainIppAnswer() async throws {
        Fixtures.preload("inkjet-demo") // timed: nothing waits on the disk
        let handler = Network(Printers.inkjet(), failNow: true) { $0.url.path == "/ipp/printer" ? Network.hang() : nil }
        let http = DeviceHttp(host: "192.0.2.11", transport: handler)
        let clock = ContinuousClock()
        let started = clock.now
        let ipp = await PrinterConnection.probeIpp(http, hint: URL(string: "http://192.0.2.11:631/ipp/printer"))
        #expect(clock.now - started < PrinterConnection.ippProbeDeadline - .seconds(1)) // not the hint's deadline
        #expect(ipp?.1.path == "/ipp/print")
    }

    @Test func aPrinterThatNeverAnswersIppCostsOneDeadlineNotOnePerAttempt() async throws {
        Fixtures.preload("inkjet-demo") // timed: nothing waits on the disk
        let handler = Network(Printers.inkjet(), failNow: true) { $0.url.port == 631 ? Network.hang() : nil }
        let http = DeviceHttp(host: "192.0.2.11", transport: handler)
        let clock = ContinuousClock()
        let started = clock.now
        let ipp = await PrinterConnection.probeIpp(http, hint: URL(string: "http://192.0.2.11:631/ipp/printer"))
        #expect(clock.now - started < PrinterConnection.ippProbeDeadline * 2 - .seconds(1)) // one deadline, not one per attempt
        #expect(ipp == nil)
        let probe = try await PrinterConnection.probe(http, ippHint: URL(string: "http://192.0.2.11:631/ipp/printer"))
        #expect(probe.ipp == nil)
        #expect(probe.scanner != nil) // the other interfaces are still asked
    }

    @Test func hostRouterSendsEachDemoPrinterToItsOwnFixtures() async throws {
        let router = HostRouter([FixtureTransport.demoHost: Printers.folder("m234dw"), "192.0.2.11": Printers.inkjet()])
        #expect(try await PrinterConnection.open(FixtureTransport.demoHost, transport: router).probe.brand == .hp)
        #expect(try await PrinterConnection.open("192.0.2.11", transport: router).probe.brand == .epson)
        #expect(!(try await PrinterConnection.open("192.0.2.99", transport: router)).probe.reachable)
    }
}
