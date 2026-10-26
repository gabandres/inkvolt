import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// SNMP: the BER encoder/decoder against bytes written by hand from X.690 and the message grammar of RFC 1157 §4 / RFC 3416
/// §3 (not captured from devices), the client against the made-up agent, the Printer MIB mapping (RFC 2790, RFC 3805).
/// Ported from print/tests/InkvoltPrint.Tests/SnmpTests.cs; the connection and Windows queue tests come with P4 and P7.
struct SnmpTests {
    private static func demoAgent(_ name: String, v1Only: Bool = false) throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/\(name)")), v1Only: v1Only)
    }

    // MARK: BER (X.690)

    @Test(arguments: [
        (0, "020100"), (127, "02017F"), (128, "02020080"), (256, "02020100"), (-1, "0201FF"), (-128, "020180"),
        (-129, "0202FF7F"), (2147483647, "02047FFFFFFF"), (-2147483648, "020480000000"),
    ] as [(Int64, String)])
    func integersAreShortestTwosComplement(_ value: Int64, _ bytes: String) throws {
        #expect(Ber.integer32(value) == hex(bytes))
        var r = Ber.Reader(hex(bytes))
        #expect(try r.readInteger() == value)
    }

    @Test(arguments: [
        ("1.3.6.1.2.1.1.1.0", "06082B06010201010100"),
        ("1.2.840.113549", "06062A864886F70D"), // X.690's own example arcs: 840 and 113549 take two and three bytes
        ("2.999.3", "0603883703"), // the first two arcs share one subidentifier: 80 + 999 = 1079 = 0x88 0x37
        ("1.3.6.1.2.1.43.11.1.1.9.1.1", "060C2B060102012B0B0101090101"),
    ])
    func objectIdentifiersFollowX690(_ oid: String, _ bytes: String) throws {
        #expect(Ber.objectId(Oid(stringLiteral: oid)) == hex(bytes))
        var r = Ber.Reader(hex(bytes))
        #expect(try r.readObjectId() == Oid(stringLiteral: oid))
    }

    @Test(arguments: [(0, "00"), (127, "7F"), (128, "8180"), (200, "81C8"), (1000, "8203E8"), (70000, "83011170")] as [(Int, String)])
    func lengthsUseTheLongFormFrom128(_ length: Int, _ bytes: String) {
        #expect(Ber.length(length) == hex(bytes))
    }

    @Test(arguments: [(0, "00"), (127, "7F"), (128, "0080"), (4294967295, "00FFFFFFFF")] as [(UInt64, String)])
    func unsignedValuesGetALeadingZeroWhenTheTopBitIsSet(_ value: UInt64, _ bytes: String) throws {
        #expect(Ber.unsignedContent(value) == hex(bytes))
        #expect(try Ber.unsignedValue(hex(bytes)) == value)
    }

    @Test(arguments: [
        "3080020100", // indefinite length: not allowed in SNMP
        "3005020100", // the SEQUENCE claims more than there is
        "30", // no length
        "1F0100", // multi-byte tag
        "3084FFFFFFFF", // a length no datagram has
    ])
    func malformedBerIsAFormatError(_ bytes: String) {
        #expect(throws: SnmpFormatError.self) {
            var r = Ber.Reader(hex(bytes))
            var inner = try r.enter(Ber.sequence)
            _ = try inner.readInteger()
        }
    }

    @Test(arguments: [
        "0600", // empty
        "06022B86", // ends inside a subidentifier
        "06032B8001", // a subidentifier padded with 0x80
    ])
    func malformedObjectIdentifiersAreRejected(_ bytes: String) {
        #expect(throws: SnmpFormatError.self) {
            var r = Ber.Reader(hex(bytes))
            _ = try r.readObjectId()
        }
    }

    // MARK: Messages (RFC 1157 / RFC 3416)

    /// RFC 1157 §4.1.2 GetRequest for sysDescr.0, community "public", request-id 1, built by hand: Message SEQUENCE {
    /// version 0, community, GetRequest-PDU [0] { request-id, error-status 0, error-index 0, VarBindList { VarBind { name,
    /// NULL } } } }.
    private static let getSysDescrV1 =
        "3026" + "020100" + "0406 7075626C6963" +
        "A019" + "020101" + "020100" + "020100" +
        "300E" + "300C" + "06082B06010201010100" + "0500"

    @Test func getRequestIsEncodedByteForByte() throws {
        let m = SnmpMessage(.v1, "public", .getRequest, requestId: 1, errorStatus: 0, errorIndex: 0,
                            varBinds: [SnmpVarBind("1.3.6.1.2.1.1.1.0", .null)])
        #expect(m.encode() == hex(Self.getSysDescrV1))
        #expect(try SnmpMessage.decode(hex(Self.getSysDescrV1)) == m)
    }

    /// RFC 3416 §4.2.3 GetBulkRequest (v2c, RFC 1901 version 1): request-id 0x1234, non-repeaters 0, max-repetitions 10, for
    /// prtMarkerSuppliesLevel.1 (RFC 3805), built by hand. BulkPDU has PDU's shape, tag [5].
    private static let getBulkSuppliesV2c =
        "302A" + "020101" + "0406 7075626C6963" +
        "A51D" + "02021234" + "020100" + "02010A" +
        "3011" + "300F" + "060B2B060102012B0B01010901" + "0500"

    @Test func getBulkRequestIsEncodedByteForByte() throws {
        let m = SnmpMessage(.v2c, "public", .getBulkRequest, requestId: 0x1234, errorStatus: 0, errorIndex: 10,
                            varBinds: [SnmpVarBind("1.3.6.1.2.1.43.11.1.1.9.1", .null)])
        #expect(m.encode() == hex(Self.getBulkSuppliesV2c))
        let back = try SnmpMessage.decode(hex(Self.getBulkSuppliesV2c))
        #expect(back.nonRepeaters == 0 && back.maxRepetitions == 10)
    }

    /// A v2c Response-PDU [2] written by hand from RFC 3416 §3: TimeTicks 123456 (RFC 3416's sysUpTime example), INTEGER 3
    /// (hrPrinterStatus idle), OCTET STRING 0x40 0x00 (hrPrinterDetectedErrorState: noPaper), INTEGER -2 (a supply level:
    /// unknown), an OCTET STRING description, the noSuchInstance and endOfMibView exceptions, and a Gauge32 of 2^32-1 (its
    /// leading zero byte). 152 bytes of bindings: the list's length takes the long form (0x81 0x98).
    private static let responseV2c =
        "3081B3" + "020101" + "0406 7075626C6963" +
        "A281A5" + "02021234" + "020100" + "020100" +
        "308198" +
        "300F" + "06082B06010201010300" + "430301E240" +
        "3010" + "060B2B06010201190305010101" + "020103" +
        "3011" + "060B2B06010201190305010201" + "04024000" +
        "3011" + "060C2B060102012B0B0101090101" + "0201FE" +
        "301B" + "060C2B060102012B0B0101060101" + "040B 426C61636B20546F6E6572" +
        "3010" + "060C2B060102012B1201010201 05" + "8100" +
        "3009" + "06052B06010401" + "8200" +
        "3013" + "060A2B06010201020201 0501" + "420500FFFFFFFF"

    @Test func responseIsDecodedAndEncodedBackByteForByte() throws {
        let bytes = hex(Self.responseV2c)
        let m = try SnmpMessage.decode(bytes)
        #expect(m.version == .v2c && m.community == "public" && m.type == .response)
        #expect(m.requestId == 0x1234 && m.errorStatus == 0 && m.errorIndex == 0)
        try #require(m.varBinds.count == 8)
        #expect(m.varBinds[0].name == "1.3.6.1.2.1.1.3.0")
        #expect(m.varBinds[0].value.tag == Ber.timeTicks && m.varBinds[0].value.number == 123456)
        #expect(m.varBinds[1].value.int == 3)
        #expect(m.varBinds[2].value.bytes == [0x40, 0x00])
        #expect(m.varBinds[3].value.int == -2)
        #expect(m.varBinds[4].value.text == "Black Toner")
        #expect(m.varBinds[5].value == .noSuchInstance)
        #expect(m.varBinds[6].value == .endOfMibView)
        #expect(m.varBinds[7].value.tag == Ber.gauge32 && m.varBinds[7].value.number == 4294967295)
        #expect(m.encode() == bytes)
    }

    @Test(arguments: [
        "3010 020103 0406 7075626C6963 A003020101", // SNMPv3 (version 3): not spoken here
        "3010 020100 0406 7075626C6963 A403020101", // a v1 Trap-PDU: another shape, never asked for
        "300B 020100 0406 7075626C6963", // no PDU
    ] as [String])
    func otherMessagesAreFormatErrors(_ bytes: String) {
        #expect(throws: SnmpFormatError.self) { try SnmpMessage.decode(hex(bytes)) }
    }

    @Test func octetStringsReadAsTextWithoutPaddingAndInLatin1WhenNotUtf8() {
        #expect(SnmpValue.octets(Array("Black Toner\0\0".utf8)).text == "Black Toner")
        #expect(SnmpValue.octets([0x43, 0x61, 0x66, 0xE9]).text == "Café") // Latin-1 é, not valid UTF-8
        #expect(SnmpValue.octets([0x00, 0x00]).text == nil)
    }

    // MARK: The client and the made-up agent

    /// RFC 3416 §4.2.3.1's IP net-to-media table, as the example's agent holds it.
    private static func rfc3416Agent(v1Only: Bool = false) throws -> SnmpAgent {
        SnmpAgent(try SnmpAgent.parseWalk("""
            .1.3.6.1.2.1.1.3.0 = Timeticks: (123456)
            .1.3.6.1.2.1.4.22.1.2.1.9.2.3.4 = Hex-STRING: 00 00 10 54 32 10
            .1.3.6.1.2.1.4.22.1.2.1.10.0.0.51 = Hex-STRING: 00 00 10 01 23 45
            .1.3.6.1.2.1.4.22.1.2.2.10.0.0.15 = Hex-STRING: 00 00 10 98 76 54
            .1.3.6.1.2.1.4.22.1.3.1.9.2.3.4 = IpAddress: 9.2.3.4
            .1.3.6.1.2.1.4.22.1.3.1.10.0.0.51 = IpAddress: 10.0.0.51
            .1.3.6.1.2.1.4.22.1.3.2.10.0.0.15 = IpAddress: 10.0.0.15
            .1.3.6.1.2.1.4.22.1.4.1.9.2.3.4 = INTEGER: 3
            .1.3.6.1.2.1.4.22.1.4.1.10.0.0.51 = INTEGER: 4
            .1.3.6.1.2.1.4.22.1.4.2.10.0.0.15 = INTEGER: 3
            .1.3.6.1.2.1.4.23.0 = Counter32: 2
            """), v1Only: v1Only)
    }

    private static let sysUpTime: Oid = "1.3.6.1.2.1.1.3", physAddress: Oid = "1.3.6.1.2.1.4.22.1.2", mediaType: Oid = "1.3.6.1.2.1.4.22.1.4"

    @Test func getBulkAnswersAsRfc3416sExample() async throws {
        let client = SnmpClient(transport: try Self.rfc3416Agent(), host: "192.0.2.50", version: .v2c)
        let first = try await client.getBulk(nonRepeaters: 1, maxRepetitions: 2, [Self.sysUpTime, Self.physAddress, Self.mediaType])
        #expect(first.map(\.name.description) == ["1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.4.22.1.2.1.9.2.3.4", "1.3.6.1.2.1.4.22.1.4.1.9.2.3.4",
                                                  "1.3.6.1.2.1.4.22.1.2.1.10.0.0.51", "1.3.6.1.2.1.4.22.1.4.1.10.0.0.51"])
        #expect([first[2], first[4]].map(\.value.number) == [3, 4])

        let second = try await client.getBulk(nonRepeaters: 1, maxRepetitions: 2, [Self.sysUpTime, first[3].name, first[4].name])
        // The end of the table: the fourth binding is the next column, the fifth the object after the table (as in the RFC).
        #expect(second.map(\.name.description) == ["1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.4.22.1.2.2.10.0.0.15", "1.3.6.1.2.1.4.22.1.4.2.10.0.0.15",
                                                   "1.3.6.1.2.1.4.22.1.3.1.9.2.3.4", "1.3.6.1.2.1.4.23.0"])
    }

    @Test(arguments: [SnmpVersion.v2c, .v1])
    func walkReadsColumnsSideBySideOverBothVersions(_ version: SnmpVersion) async throws {
        let agent = try Self.rfc3416Agent(v1Only: version == .v1)
        let columns = try await SnmpClient(transport: agent, host: "192.0.2.50", version: version).walk([Self.physAddress, Self.mediaType])
        let indexes: [String] = columns[0].map { $0.index.map(String.init).joined(separator: ".") }
        #expect(indexes == ["1.9.2.3.4", "1.10.0.0.51", "2.10.0.0.15"])
        #expect(columns[1].map(\.value.number) == [3, 4, 3])
        #expect(agent.received.allSatisfy { $0.type == (version == .v1 ? .getNextRequest : .getBulkRequest) })
    }

    @Test func v1NoSuchNameLeavesTheOtherObjects() async throws {
        let client = SnmpClient(transport: try Self.rfc3416Agent(v1Only: true), host: "192.0.2.50", version: .v1)
        let got = try await client.get(["1.3.6.1.2.1.1.5.0", "1.3.6.1.2.1.1.3.0"])
        #expect(got[0].value.isException)
        #expect(got[1].value.number == 123456)
        let past = try await client.getNext(["1.3.6.1.2.1.4.23.0"]) // nothing after it: noSuchName → end of MIB
        #expect(past[0].value == .endOfMibView)
    }

    @Test func aWrongCommunityGetsNoReplyAndTimesOutAfterTheRetries() async throws {
        let agent = SnmpAgent(try SnmpAgent.parseWalk(".1.3.6.1.2.1.1.3.0 = Timeticks: (1)"), community: "secret")
        let client = SnmpClient(transport: agent, host: "192.0.2.50", version: .v2c, retries: 2)
        await #expect(throws: SnmpTimeoutError.self) { try await client.get(["1.3.6.1.2.1.1.3.0"]) }
        #expect(agent.requests == 3)
    }

    @Test func theAgentRefusesSets() throws {
        let agent = try Self.rfc3416Agent()
        let set = SnmpMessage(.v2c, "public", .setRequest, requestId: 7, errorStatus: 0, errorIndex: 0,
                              varBinds: [SnmpVarBind("1.3.6.1.2.1.4.23.0", .integer(0))])
        #expect(try SnmpMessage.decode(#require(agent.respond(set.encode()))).errorStatus == 17) // notWritable
    }

    // MARK: Printers (RFC 2790, RFC 3805)

    @Test func probeFindsThePrinterEntryAndPrefersV2c() async throws {
        let printer = try #require(try await SnmpPrinterClient.probe(transport: Self.demoAgent("workgroup-laser.txt"), host: "192.0.2.14"))
        let id = printer.identity
        #expect(id.version == .v2c && id.deviceIndex == 1)
        #expect(id.model == "Demo Laser 5200 Series")
        #expect(id.serialNumber == "DEMO0005200")
        #expect(id.location == "Office, 2nd floor")
        #expect(id.systemName == "demo-laser")
    }

    @Test func aV1OnlyPrinterIsReadOverV1() async throws {
        let printer = try #require(try await SnmpPrinterClient.probe(transport: Self.demoAgent("workgroup-laser.txt", v1Only: true),
                                                                     host: "192.0.2.14"))
        #expect(printer.identity.version == .v1)
        #expect(try await printer.supplies().count == 3)
    }

    @Test func anAgentWithoutAPrinterEntryIsNoPrinter() async throws {
        // A router or a PC answering "public": MIB-II, but no hrPrinterTable.
        let agent = SnmpAgent(try SnmpAgent.parseWalk("""
            .1.3.6.1.2.1.1.1.0 = STRING: "Example router"
            .1.3.6.1.2.1.1.5.0 = STRING: "router"
            .1.3.6.1.2.1.2.1.0 = INTEGER: 2
            """))
        #expect(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.1") == nil)
        #expect(try await SnmpPrinterClient.probe(transport: SnmpRouter([:]), host: "192.0.2.1") == nil) // silence
    }

    @Test func onlyGetGetNextAndGetBulkAreEverSent() async throws {
        let agent = try Self.demoAgent("workgroup-laser.txt")
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.14"))
        _ = try await printer.status()
        var v1 = printer.identity
        v1.version = .v1
        _ = try await SnmpPrinterClient(transport: agent, host: "192.0.2.14", identity: v1).supplies()
        #expect(!agent.received.isEmpty)
        #expect(agent.received.allSatisfy { [.getRequest, .getNextRequest, .getBulkRequest].contains($0.type) })
    }

    @Test func demoLaserReadsAsReadyWithAPaperWarningAndThreeSupplies() async throws {
        let printer = try #require(try await SnmpPrinterClient.probe(transport: Self.demoAgent("workgroup-laser.txt"), host: "192.0.2.14"))
        let status = try await printer.status()
        #expect(status.code == "ready" && status.message == "Ready" && status.severity == .warning)
        // The alert's own words; the lowPaper bit says the same and isn't repeated; the cover-closed event isn't a problem.
        try #require(status.alerts.count == 1)
        #expect(status.alerts[0].id == "media-low" && status.alerts[0].message == "Tray 2 paper low.")

        let supplies = try await printer.supplies()
        #expect(supplies.map(\.name) == ["Black Toner Cartridge DT-5200", "Drum Unit DR-5200", "Waste Toner Box"])
        #expect(supplies[0].percentRemaining == 35 && supplies[0].state == "ok" && supplies[0].colorCode == "K" && supplies[0].kind == "toner-cartridge")
        #expect(supplies[1].percentRemaining == 80 && supplies[1].kind == "opc")
        #expect(supplies[1].colorCode == nil) // colorant index 0: none
        #expect(supplies[2].isWaste)
        #expect(supplies[2].percentRemaining == nil && supplies[2].state == "ok") // -3: some room left
    }

    @Test func oneReadServesStatusAndSupplies() async throws {
        let agent = try Self.demoAgent("color-mfp.txt")
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.15"))
        let before = agent.requests
        async let status = printer.status()
        async let supplies = printer.supplies()
        _ = try await (status, supplies)
        let oneRead = agent.requests - before
        _ = try await printer.supplies()
        #expect(agent.requests - before == oneRead)
    }

    private static func reading(_ device: Int = 2, _ printer: Int = 3, errors: [UInt8] = [0, 0], alerts: [SnmpAlert] = [],
                                supplies: [SnmpSupply] = [], colorants: [Int: String] = [:]) -> SnmpReading {
        SnmpReading(deviceStatus: device, printerStatus: printer, detectedErrorState: errors, alerts: alerts, supplies: supplies,
                    colorants: colorants)
    }

    @Test(arguments: [
        (2, 3, "ready", "Ready"), // RFC 3805 §2.2.13.2: Idle
        (2, 4, "processing", "Printing"), // Busy/Active
        (5, 5, "warmingUp", "Warming up"), // Moving on-line
        (2, 1, "inPowerSave", "Sleeping"), // Standby
        (5, 1, "stopped", "Stopped"), // Unavailable / critical alert
        (1, 2, "unknown", "Unknown"),
    ] as [(Int, Int, String, String)])
    func overallStateFollowsRfc3805(_ device: Int, _ printer: Int, _ code: String, _ message: String) {
        let s = SnmpPrinterStatus.toStatus(Self.reading(device, printer))
        #expect(s.code == code && s.message == message)
    }

    @Test func aJamStopsThePrinterAndNamesIt() throws {
        // Critical alert, media path group, code jam(8), no description: the IPP reason's words; down with the jammed bit set.
        let s = SnmpPrinterStatus.toStatus(Self.reading(5, 1, errors: [0x04, 0x00],
                                                        alerts: [SnmpAlert(1, severity: 3, group: 13, groupIndex: 1, code: 8, description: nil)]))
        #expect(s.code == "stopped" && s.message == "Paper jam" && s.severity == .error)
        try #require(s.alerts.count == 1)
        #expect(s.alerts[0].id == "media-jam")
        #expect(s.detail != nil) // what to do about it
    }

    @Test(arguments: [
        ([0x40], "media-empty", .error), // noPaper
        ([0x08], "door-open", .error), // doorOpen (bit 4)
        ([0x00, 0x20], "marker-supply-missing", .error), // markerSupplyMissing (bit 10)
        ([0x00, 0x02], "maintenance-overdue", .warning), // overduePreventMaint (bit 14)
    ] as [([UInt8], String, Severity)])
    func errorStateBitsCountFromTheFirstBytesTopBit(_ bits: [UInt8], _ id: String, _ severity: Severity) throws {
        let alerts = SnmpPrinterStatus.toStatus(Self.reading(3, 3, errors: bits)).alerts
        try #require(alerts.count == 1)
        #expect(alerts[0].id == id && alerts[0].severity == severity)
    }

    @Test func theOfflineBitSaysOfflineWhileTheAgentStillAnswers() {
        let s = SnmpPrinterStatus.toStatus(Self.reading(5, 1, errors: [0x02]))
        #expect(s.code == "stopped" && s.message == "Offline" && s.severity == .error) // not "offline": it answers
    }

    @Test func serviceRequestedIsLeftOutBesideTheRealProblem() {
        let s = SnmpPrinterStatus.toStatus(Self.reading(5, 1, errors: [0x41])) // noPaper + serviceRequested
        #expect(s.alerts.map(\.id) == ["media-empty"])
    }

    @Test func changeEventsAndOtherCodesAreNoProblems() {
        let alerts = [
            SnmpAlert(1, severity: 5, group: 6, groupIndex: 1, code: 3, description: "Cover opened"), // warningBinaryChangeEvent
            SnmpAlert(2, severity: 4, group: 6, groupIndex: 1, code: 4, description: "Cover closed"), // coverClosed: an event
            SnmpAlert(3, severity: 4, group: 5, groupIndex: -1, code: 503, description: nil), // powerUp
            SnmpAlert(4, severity: 1, group: 5, groupIndex: -1, code: 1, description: nil), // other, severity other
        ]
        #expect(SnmpPrinterStatus.toStatus(Self.reading(alerts: alerts)).alerts.isEmpty)
    }

    @Test func genericSubunitCodesTakeTheirGroupsMeaning() {
        let supplies = [
            SnmpSupply(1, supplyClass: 3, type: 3, description: "Black Toner", maxCapacity: 100, level: 9, colorantIndex: 1),
            SnmpSupply(2, supplyClass: 4, type: 4, description: "Waste Toner Box", maxCapacity: 100, level: 10, colorantIndex: 0),
            SnmpSupply(3, supplyClass: 3, type: 9, description: "Drum", maxCapacity: 100, level: 4, colorantIndex: 0),
        ]
        let alerts = [
            SnmpAlert(1, severity: 4, group: 11, groupIndex: 1, code: 12, description: nil), // subunitAlmostEmpty on the toner
            SnmpAlert(2, severity: 4, group: 11, groupIndex: 2, code: 14, description: nil), // subunitAlmostFull on the waste box
            SnmpAlert(3, severity: 4, group: 11, groupIndex: 3, code: 10, description: nil), // subunitLifeAlmostOver on the drum
            SnmpAlert(4, severity: 3, group: 8, groupIndex: 2, code: 13, description: nil), // subunitEmpty on input tray 2
        ]
        let r = Self.reading(alerts: alerts, supplies: supplies, colorants: [1: "black"])
        #expect(SnmpPrinterStatus.toStatus(r).alerts.map(\.id) == ["marker-supply-low", "marker-waste-almost-full", "opc-near-eol", "media-empty"])
        let c = SnmpPrinterStatus.toConsumables(r)
        #expect(c[0].state == "low" && c[0].percentRemaining == 9 && c[0].colorCode == "K")
        #expect(c[1].state == "almostFull" && c[1].percentRemaining == nil)
        #expect(c[2].state == "low")
    }

    @Test(arguments: [
        (3000, 1050, 35, "ok"),
        (100, 0, 0, "out"),
        (100, 130, 100, "ok"), // a level above the maximum is capped
        (100, -3, nil, "ok"), // RFC 3805: some remaining
        (100, -2, nil, "unknown"), // unknown
        (100, -1, nil, "unknown"), // other: no restriction, no level to show
        (-2, 40, nil, "unknown"), // unknown maximum: no share
        (-1, 40, nil, "unknown"),
        (0, 40, nil, "unknown"),
    ] as [(Int, Int, Int?, String)])
    func supplyLevelsFollowRfc3805(_ max: Int, _ level: Int, _ percent: Int?, _ state: String) throws {
        let c = SnmpPrinterStatus.toConsumables(Self.reading(supplies: [
            SnmpSupply(1, supplyClass: 3, type: 3, description: "Toner", maxCapacity: max, level: level, colorantIndex: 0),
        ]))
        try #require(c.count == 1)
        #expect(c[0].percentRemaining == percent && c[0].state == state)
    }

    @Test func aReceptacleWithNoRoomLeftIsFull() throws {
        let c = SnmpPrinterStatus.toConsumables(Self.reading(supplies: [
            SnmpSupply(1, supplyClass: 4, type: 4, description: nil, maxCapacity: 100, level: 0, colorantIndex: 0),
        ]))
        try #require(c.count == 1)
        #expect(c[0].name == "Waste toner box" && c[0].state == "full" && c[0].isWaste)
    }

    @Test func aMissingCartridgeIsMissing() {
        let c = SnmpPrinterStatus.toConsumables(Self.reading(
            alerts: [SnmpAlert(1, severity: 3, group: 11, groupIndex: 4, code: 1115, description: nil)],
            supplies: [SnmpSupply(4, supplyClass: 3, type: 21, description: "Yellow", maxCapacity: 100, level: -2, colorantIndex: 0)]))
        #expect(c.map(\.state) == ["missing"])
    }

    @Test func aDescriptionThatIsOnlyACodeIsNotShown() {
        let s = SnmpPrinterStatus.toStatus(Self.reading(alerts: [
            SnmpAlert(1, severity: 4, group: 11, groupIndex: 1, code: 1104, description: "{13.A3.D2}"),
        ]))
        #expect(s.alerts.map(\.message) == ["Toner low"])
    }

    // MARK: Review fixes

    /// Passes requests to `inner` unless `answer` replies for it (an error, garbage).
    private final class Tampered: SnmpTransport {
        private let inner: any SnmpTransport
        private let answer: @Sendable (SnmpMessage) -> [UInt8]?
        private let isOn = Mutex(true)

        init(_ inner: any SnmpTransport, _ answer: @escaping @Sendable (SnmpMessage) -> [UInt8]?) {
            self.inner = inner
            self.answer = answer
        }

        var on: Bool {
            get { isOn.withLock { $0 } }
            set { isOn.withLock { $0 = newValue } }
        }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            if on, let message = try? SnmpMessage.decode(request), let reply = answer(message) { return reply }
            return try await inner.send(request, to: host, timeout: timeout)
        }
    }

    /// A printer that can be turned off (nil: no reply) or swapped for another.
    private final class Switchable: SnmpTransport {
        private let target: Mutex<(any SnmpTransport)?>

        init(_ to: (any SnmpTransport)?) { target = Mutex(to) }

        var to: (any SnmpTransport)? {
            get { target.withLock { $0 } }
            set { target.withLock { $0 = newValue } }
        }

        func send(_ request: [UInt8], to host: String, timeout: Duration) async throws -> [UInt8]? {
            try await to?.send(request, to: host, timeout: timeout)
        }
    }

    private static func errorReply(_ request: SnmpMessage, _ status: Int, index: Int = 1) -> [UInt8] {
        SnmpMessage(request.version, request.community, .response, requestId: request.requestId, errorStatus: status, errorIndex: index,
                    varBinds: request.varBinds).encode()
    }

    @Test func anUndecodableDatagramIsIgnoredLikeAStrayReply() async throws {
        let sent = Mutex(0)
        let agent = Tampered(try Self.rfc3416Agent()) { _ in
            sent.withLock { n in
                defer { n += 1 }
                return n == 0 ? hex("3003020100") : nil // the first reply isn't SNMP
            }
        }
        let got = try await SnmpClient(transport: agent, host: "192.0.2.50", version: .v2c).get(["1.3.6.1.2.1.1.3.0"])
        #expect(got[0].value.number == 123456)
    }

    @Test func unknownValueTypesAreKeptAsOpaqueBytes() throws {
        // A Response whose one binding is 0x47 (UInteger32 of RFC 1442's SMI), which a GetBulk running past a table may meet.
        let bytes = hex("3022 020101 0406 7075626C6963 A215 020101 020100 020100 300A 3008 0603 2B0601 470105")
        let m = try SnmpMessage.decode(bytes)
        #expect(m.varBinds[0].value.tag == 0x47)
        #expect(m.varBinds[0].value.bytes == [5])
        #expect(m.varBinds[0].value.int == nil)
        #expect(m.encode() == bytes)
    }

    @Test func aWalkFallsBackToGetNextWhenGetBulkFails() async throws {
        let agent = Tampered(try Self.rfc3416Agent()) { m in m.type == .getBulkRequest ? Self.errorReply(m, SnmpMessage.genErr) : nil }
        let columns = try await SnmpClient(transport: agent, host: "192.0.2.50", version: .v2c).walk([Self.physAddress, Self.mediaType])
        #expect(columns[0].count == 3)
        #expect(columns[1].map(\.value.number) == [3, 4, 3])
    }

    @Test func aColumnTheAgentFailsOnIsEmptyAndTheOthersAreRead() async throws {
        let alertTable = PrinterMib.alertSeverity.arcs.dropLast().map(String.init).joined(separator: ".")
        let agent = Tampered(try Self.demoAgent("color-mfp.txt")) { m in
            m.varBinds.contains { $0.name.description.hasPrefix(alertTable + ".") } ? Self.errorReply(m, SnmpMessage.genErr) : nil
        }
        let printer = try #require(try await SnmpPrinterClient.probe(transport: agent, host: "192.0.2.15"))
        let reading = try await printer.read()
        #expect(reading.alerts.isEmpty) // genErr on prtAlertTable: no alerts, not a failed read
        #expect(reading.supplies.count == 5)
    }

    @Test func criticalAlertsWithOtherOrUnknownCodesAreKeptWithTheirWords() throws {
        let alerts = [
            SnmpAlert(1, severity: 3, group: 5, groupIndex: -1, code: 1, description: "Fuser error, call for service"), // critical, code other
            SnmpAlert(2, severity: 4, group: 5, groupIndex: -1, code: 2, description: nil), // warning, code unknown, no words
            SnmpAlert(3, severity: 1, group: 5, groupIndex: -1, code: 1, description: "Something"), // severity other: not a problem
            SnmpAlert(4, severity: 5, group: 5, groupIndex: -1, code: 2, description: "Changed"), // a change event
        ]
        let s = SnmpPrinterStatus.toStatus(Self.reading(alerts: alerts))
        try #require(s.alerts.count == 2)
        #expect(s.alerts[0].severity == .error && s.alerts[0].message == "Fuser error, call for service.")
        #expect(s.alerts[1].severity == .warning && s.alerts[1].message == "The printer reports a problem")
    }

    @Test func serviceRequestedIsLeftOutBesideAWarningToo() {
        let s = SnmpPrinterStatus.toStatus(Self.reading(2, 3, errors: [0x21])) // lowToner + serviceRequested
        #expect(s.alerts.map(\.id) == ["toner-low"] && s.severity == .warning)
    }

    @Test func aWasteBoxReportedAsConsumedIsntFullAtLevelZero() {
        let consumed = SnmpPrinterStatus.toConsumables(Self.reading(supplies: [
            SnmpSupply(1, supplyClass: 3, type: 4, description: "Waste Toner Box", maxCapacity: 100, level: 0, colorantIndex: 0),
        ]))
        #expect(consumed.map(\.isWaste) == [true] && consumed.map(\.state) == ["ok"])
        let other = SnmpPrinterStatus.toConsumables(Self.reading(supplies: [
            SnmpSupply(1, supplyClass: 1, type: 4, description: "Waste Toner Box", maxCapacity: 100, level: 0, colorantIndex: 0),
        ]))
        #expect(other.map(\.state) == ["full"]) // class other: a waste box's level is the room left
    }

    @Test func aSerialNumberThatDisagreesIsAnotherDevice() {
        let known = SnmpDevice(serialNumber: "DEMO0005200", model: "Demo Laser 5200 Series", systemName: "demo-laser")
        #expect(known.identify(serialNumber: "DEMO0005200") == .same)
        #expect(known.identify(serialNumber: "DEMO0004400") == .different)
        #expect(known.identify(serialNumber: nil) == .unknown)
        #expect(SnmpDevice(serialNumber: nil, model: nil, systemName: nil).identify(serialNumber: "DEMO0005200") == .unknown)
    }

    @Test func anotherSnmpPrinterAtTheAddressIsADifferentDevice() async throws {
        let snmp = Switchable(try Self.demoAgent("workgroup-laser.txt"))
        let printer = try #require(try await SnmpPrinterClient.probe(transport: snmp, host: "192.0.2.14"))
        let known = SnmpDevice.from(printer.identity)
        #expect(known.identify(try #require(try await printer.readIdentity())) == .same)

        snmp.to = try Self.demoAgent("color-mfp.txt") // DHCP gave the address to another printer
        #expect(known.identify(try #require(try await printer.readIdentity())) == .different)
        snmp.to = nil
        #expect(try await printer.readIdentity() == nil) // no answer: can't tell
        #expect(known.identify(SnmpIdentity(version: .v2c, deviceIndex: 1, deviceDescription: "Demo Laser 5200 Series", systemDescription: nil,
                                            systemName: "demo-laser", location: nil, serialNumber: "DEMO0009999")) == .different)
        #expect(known.identify(SnmpIdentity(version: .v2c, deviceIndex: 1, deviceDescription: nil, systemDescription: nil, systemName: nil,
                                            location: nil, serialNumber: nil)) == .unknown)
    }
}
