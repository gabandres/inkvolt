import Foundation
import Testing
@testable import PrintCore

/// Pages per cartridge beyond LEDM: the pages left and what a full cartridge is rated for (CDM's capacity, IPP's
/// `printer-supply`, the Printer MIB's supplies counted in impressions or sheets) and the lifetime page count the supply
/// history counts pages per cartridge with (IPP's `printer-impressions-completed`, prtMarkerLifeCount). Ported from
/// SupplyPagesTests.cs.
struct SupplyPagesTests {
    private static func laser(_ edit: (String) -> String = { $0 }) throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk(edit(try Fixtures.text("snmp-demo/workgroup-laser.txt"))))
    }

    private static func pair(_ c: Consumable) -> [Int?] { [c.estimatedPagesRemaining, c.pageYield] }

    // MARK: CDM

    @Test func aCdmTonersCapacityInPagesIsItsYield() throws {
        let s = CdmParsers.parseSupplies(try Fixtures.text("cdm-laser/cdm_supply_v1_suppliesPublic.json"))
        #expect(s.map(\.pageYield) == [3150, 2200, 2200, 2200])
        #expect(Self.pair(s[1]) == [200, 2200])
    }

    @Test(arguments: [
        #"{"suppliesList":[{"supplyType":"toner","capacity":3000,"capacityUnit":"milliliters"}]}"#, // not pages
        #"{"suppliesList":[{"supplyType":"toner","capacity":3000}]}"#, // no unit: can't tell
        #"{"suppliesList":[{"supplyType":"toner","capacity":-1,"capacityUnit":"pages"}]}"#,
        #"{"suppliesList":[{"supplyType":"toner","capacity":"lots","capacityUnit":"pages"}]}"#,
        #"{"suppliesList":[{"supplyType":"toner","capacity":99999999999,"capacityUnit":"pages"}]}"#,
    ])
    func aCdmCapacityThatIsntPagesGivesNoYield(_ json: String) throws {
        let s = CdmParsers.parseSupplies(json)
        try #require(s.count == 1)
        #expect(s[0].pageYield == nil)
    }

    @Test func inkTanksSayNoYieldWhenTheyGiveNone() throws {
        #expect(CdmParsers.parseSupplies(try Fixtures.text("cdm-tank/cdm_supply_v1_suppliesPublic.json")).allSatisfy { $0.pageYield == nil })
    }

    // MARK: IPP

    private static func ipp(_ lines: [String]) throws -> IppResponse {
        try IppCodec.decode(IppCodec.encodeResponse(status: 0, requestId: 1, IppText.parse(lines.joined(separator: "\n"))))
    }

    private static let twoToners: [String] = [
        "marker-names name Black toner", "marker-names name Drum",
        "marker-types keyword toner-cartridge", "marker-types keyword opc",
        "marker-levels integer 35", "marker-levels integer 80",
    ]

    @Test func ippPrinterSupplyInImpressionsGivesPagesLeftAndYield() throws {
        let r = try Self.ipp(Self.twoToners + [
            "printer-supply octetString index=1;class=supplyThatIsConsumed;type=tonerCartridge;unit=impressions;maxcapacity=3000;level=1050;colorantname=black;",
            "printer-supply octetString index=2;class=supplyThatIsConsumed;type=opc;unit=sheets;maxcapacity=30000;level=24000;colorantname=unknown;",
        ])
        let c = IppClient.toConsumables(r)
        #expect(Self.pair(c[0]) == [1050, 3000])
        #expect(Self.pair(c[1]) == [24000, 30000])
        #expect(c[0].percentRemaining == 35) // the level still comes from marker-levels
    }

    @Test func ippPrinterSupplyInPercentOrOfAnotherLengthGivesNoPages() throws {
        let percent = IppClient.toConsumables(try Self.ipp(Self.twoToners + [
            "printer-supply octetString type=tonerCartridge;unit=percent;maxcapacity=100;level=35;",
            "printer-supply octetString type=opc;unit=percent;maxcapacity=100;level=80;",
        ]))
        #expect(percent.allSatisfy { Self.pair($0) == [nil, nil] })

        // One printer-supply for two markers: which supply it is can't be told, so neither gets it.
        let one = IppClient.toConsumables(try Self.ipp(Self.twoToners + ["printer-supply octetString unit=impressions;maxcapacity=3000;level=1050;"]))
        #expect(one.allSatisfy { $0.estimatedPagesRemaining == nil })

        #expect(IppClient.toConsumables(try Self.ipp(Self.twoToners)).allSatisfy { $0.pageYield == nil })
    }

    @Test(arguments: [
        ("unit=impressions;maxcapacity=3000;level=-3;", nil, 3000), // some left: no count
        ("unit=impressions;maxcapacity=3000;level=4000;", nil, 3000), // more left than it holds: not believed
        ("unit=impressions;maxcapacity=-2;level=500;", 500, nil), // unknown maximum
        ("unit=impressions;maxcapacity=x;level=99999999999;", nil, nil),
        ("unit=impressions", nil, nil),
        ("", nil, nil),
        (";;==;level;=5;unit=;", nil, nil),
        (" unit = sheets ; maxcapacity = 200 ; level = 150 ", 150, 200),
    ] as [(String, Int?, Int?)])
    func ippPrinterSupplyValuesAreReadStrictly(_ value: String, _ left: Int?, _ yield: Int?) {
        let s = IppSupply.parse(value)
        #expect(s.pagesLeft == left)
        #expect(s.pageYield == yield)
    }

    @Test func aHugePrinterSupplyValueIsReadOnlySoFar() {
        let s = IppSupply.parse("unit=impressions;maxcapacity=3000;" + String(repeating: "x", count: 100_000) + ";level=10;")
        #expect(s.pagesLeft == nil)
        #expect(s.pageYield == 3000)
    }

    @Test(arguments: [
        ("printer-impressions-completed integer 48213", 48213),
        ("printer-impressions-completed integer -1", nil),
        ("printer-info text no page count", nil),
    ] as [(String, Int?)])
    func ippsPageCountIsPrinterImpressionsCompleted(_ line: String, _ pages: Int?) throws {
        #expect(IppClient.toUsage(try Self.ipp([line]))?.totalImpressions == pages)
    }

    @Test func theStatusRequestAsksForPrinterSupplyAndThePageCount() {
        #expect(IppClient.statusAttributes.contains("printer-supply"))
        #expect(IppClient.statusAttributes.contains("printer-impressions-completed"))
    }

    // MARK: SNMP (Printer MIB)

    @Test func theDemoLasersSuppliesCountImpressions() async throws {
        let printer = try #require(try await SnmpPrinterClient.probe(transport: try Self.laser(), host: "192.0.2.14"))
        let supplies = try await printer.supplies()
        #expect(Self.pair(supplies[0]) == [1050, 3000])
        #expect(Self.pair(supplies[1]) == [24000, 30000])
        #expect(Self.pair(supplies[2]) == [nil, nil]) // the waste box, in percent
        #expect(try await printer.read().pageCount == 48213)
    }

    @Test(arguments: [
        (19, 3000, 1050, nil, nil), // percent
        (2, 3000, 1050, nil, nil), // unknown unit
        (0, 3000, 1050, nil, nil), // no unit read
        (8, 3000, 1050, 1050, 3000), // sheets
        (7, 3000, -3, nil, 3000), // some left
        (7, -2, 1050, 1050, nil), // unknown maximum
        (7, 3000, 3100, nil, 3000), // more than it holds
    ] as [(Int, Int, Int, Int?, Int?)])
    func snmpSuppliesGivePagesOnlyInImpressionsOrSheets(_ unit: Int, _ max: Int, _ level: Int, _ left: Int?, _ yield: Int?) throws {
        var supply = SnmpSupply(1, supplyClass: 3, type: 3, description: "Toner", maxCapacity: max, level: level, colorantIndex: 0)
        supply.unit = unit
        let reading = SnmpReading(deviceStatus: 2, printerStatus: 3, detectedErrorState: [0, 0], alerts: [], supplies: [supply], colorants: [:])
        let c = SnmpPrinterStatus.toConsumables(reading)
        try #require(c.count == 1)
        #expect(Self.pair(c[0]) == [left, yield])
    }

    @Test(arguments: [
        (".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 7", ".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 3", nil), // ten-thousandths of an inch
        (".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 7", ".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 8", 48213), // sheets
        (".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 48213", ".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 4294967295", nil), // past int: not pages
        (".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 48213", ".1.3.6.1.2.1.43.10.2.1.4.1.1 = STRING: \"48213\"", nil), // not a number
        (".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 48213", "", nil), // no life count
    ] as [(String, String, Int?)])
    func snmpsPageCountIsTheMarkersLifeCountInPages(_ line: String, _ with: String, _ pages: Int?) async throws {
        let agent = try Self.laser { $0.replacingOccurrences(of: line, with: with) }
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14"))
        #expect(try await printer.read().pageCount == pages)
    }

    /// The demo laser, answering an error (or garbage) to any request about the marker table or the panel's lines.
    private struct OddExtras: SnmpTransport {
        let agent: SnmpAgent
        let garbage: Bool
        private static let markers: Oid = "1.3.6.1.2.1.43.10", console: Oid = "1.3.6.1.2.1.43.16"

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            var m = try SnmpMessage.decode(request)
            guard m.varBinds.contains(where: { $0.name.isUnder(Self.markers) || $0.name.isUnder(Self.console) }) else {
                return try await agent.send(request, to: host, timeout: timeout)
            }
            if garbage { return [0x30, 0x03, 0x02, 0x01] }
            m.type = .response
            m.errorStatus = SnmpMessage.genErr
            m.errorIndex = 1
            return m.encode()
        }
    }

    @Test(arguments: [false, true])
    func aPrinterThatErrsOnThePageCountOrThePanelStillGivesItsStatusAndSupplies(_ garbage: Bool) async throws {
        let printer = try #require(try await SnmpPrinterClient.probe(transport: OddExtras(agent: try Self.laser(), garbage: garbage), host: "192.0.2.14"))
        let reading = try await printer.read()
        #expect(reading.supplies.count == 3)
        #expect(reading.pageCount == nil)
        #expect(SnmpPrinterStatus.toStatus(reading).message == "Ready")
    }

    @Test func aPrinterReadOverSnmpGivesItsPageCountWithTheReading() async throws {
        let conn = try await PrinterConnection.open("192.0.2.14", transport: Printers.none(), snmp: try Self.laser())
        #expect(conn.probe.interfaces == ["SNMP"])
        let reading = try await conn.read()
        #expect(reading.usage?.totalImpressions == 48213)
        #expect(reading.supplies?.first?.estimatedPagesRemaining == 1050)
    }
}
