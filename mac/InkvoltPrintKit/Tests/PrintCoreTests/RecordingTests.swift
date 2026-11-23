import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Record a printer (print/ROADMAP.md 1.2). Ported from RecordingTests.cs with the same names: the demo printers recorded
/// through the fixture transport and served again from the recording read the same; identifiers planted in a printer's
/// replies don't survive the recording. No test records a real printer. Left out:
/// A_printer_that_never_stops_answering_doesnt_fill_this_pcs_memory: on the Mac a transport hands PrintCore a reply whole,
/// so the bound sits in PrintMac's URLSession transport, not in the recorder.
struct RecordingTests {
    private static let me = Diagnostics.Identity("jdoe", "JDOE-LAPTOP")

    /// A fresh folder for one recording, removed by the caller.
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-record-\(UUID().uuidString)", isDirectory: true)
    }

    private static func fixtureDir(_ name: String) -> URL { Fixtures.root.appendingPathComponent(name, isDirectory: true) }

    private static func files(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    /// A printer's web server answering from a folder, as the demo and the tests serve fixtures.
    private static func serve(_ dir: URL, _ edit: (@Sendable (String, String) -> String)? = nil) -> FixtureTransport {
        FixtureTransport(document: { name in
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else { return nil }
            return edit.map { Array($0(name, String(decoding: data, as: UTF8.self)).utf8) } ?? Array(data)
        })
    }

    private static func at(_ host: String, _ printer: any HttpTransport) -> HostRouter { HostRouter([host: printer]) }

    private static func agent(_ text: String) throws -> SnmpAgent { SnmpAgent(try SnmpAgent.parseWalk(text)) }

    private static func options(_ transport: any HttpTransport, snmp: (any SnmpTransport)? = nil, placeholder: String? = nil) -> RecordOptions {
        var o = RecordOptions(transport: transport, snmp: snmp)
        o.who = me
        if let placeholder { o.placeholderHost = placeholder }
        return o
    }

    /// What the app shows of a printer: interfaces, model, firmware, scanner, and one reading. Identifiers left out.
    private struct Seen: Equatable {
        var interfaces: [String]
        var model: String?
        var brand: PrinterBrand
        var firmware: FirmwareInfo?
        var hasHpInterfaces: Bool
        var scanner: Scanner?
        var ipp: [String: [IppAttributeValue]]?
        var snmp: [String]?
        var reading: PrinterReading

        struct Scanner: Equatable {
            var makeAndModel: String?
            var platen: InputCaps?
            var adf: InputCaps?
            var sources: [ScanSource]
        }
    }

    private static let identifying: Set<String> = ["printer-uuid", "printer-uri-supported", "printer-more-info", "printer-supply-info-uri", "printer-name",
                                                   "printer-info", "printer-location", "printer-dns-sd-name", "printer-device-id"]

    private static func seen(_ host: String, _ transport: any HttpTransport, _ snmp: (any SnmpTransport)? = nil) async throws -> Seen {
        let c = try await PrinterConnection.open(host, transport: transport, snmp: snmp)
        let reading = try await c.read()
        let p = c.probe
        return Seen(interfaces: p.interfaces, model: p.model, brand: p.brand, firmware: p.firmware, hasHpInterfaces: p.hasHpInterfaces,
                    scanner: p.scanner.map { Seen.Scanner(makeAndModel: $0.makeAndModel, platen: $0.platen, adf: $0.adf, sources: $0.sources) },
                    // Less what identifies the printer (stand-ins now) and what a person types (printer-info, printer-location: words now).
                    ipp: p.ipp.map { $0.attributes.filter { !identifying.contains($0.key) } },
                    snmp: p.snmp.map { ["\($0.version)", "\($0.deviceIndex)", $0.model ?? ""] },
                    reading: reading)
    }

    @Test func recordingTheM234dwReadsBackAsItsFixtures() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = FixtureTransport.demoHost
        let m234dw = Self.fixtureDir("m234dw")
        let result = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, Self.serve(m234dw))))

        #expect(result.interfaces == ["LEDM", "CDM", "eSCL"]) // its DiscoveryTree lists CDM
        #expect(result.model == "HP LaserJet MFP M234dw")
        // Every document the app read is kept under the fixture's own name.
        let original = Set(Self.files(m234dw))
        let recorded = result.files.filter { $0 != PrinterRecorder.notesFile }
        #expect(recorded.allSatisfy(original.contains), "\(recorded.filter { !original.contains($0) })")
        for name in ["DevMgmt_ProductStatusDyn.xml", "DevMgmt_ConsumableConfigDyn.xml", "FirmwareUpdate_FirmwareUpdateDyn.xml", "eSCL_ScannerStatus.xml"] {
            #expect(recorded.contains(name), "\(name)")
        }

        let before = try await Self.seen(host, Self.at(host, Self.serve(m234dw)))
        let after = try await Self.seen(host, Self.at(host, Self.serve(dir)))
        #expect(before == after)

        // One printer still: LEDM's and eSCL's UUID agree, and it is a stand-in, as is the serial.
        let c = try await PrinterConnection.open(host, transport: Self.at(host, Self.serve(dir)))
        #expect(Set(c.probe.reportedUuids.compactMap { $0?.lowercased() }).count == 1)
        #expect(c.probe.uuid == "00000000-0000-4000-8000-000000000001")
        #expect(c.probe.serialNumber?.hasPrefix("SN") == true)
    }

    @Test func recordingTheDemoInkjetKeepsItsIPPAttributesAndScanner() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.11"
        let inkjet = Self.fixtureDir("inkjet-demo")
        let result = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, Self.serve(inkjet)), placeholder: host))

        #expect(result.interfaces == ["eSCL", "IPP"])
        #expect(result.files.contains("ipp_print.ipp.txt"))
        #expect(result.files.contains("eSCL_ScannerCapabilities.xml"))
        #expect(try await Self.seen(host, Self.at(host, Self.serve(inkjet))) == Self.seen(host, Self.at(host, Self.serve(dir))))
        // The printer's own pages still point back at it, so the app still offers them.
        let c = try await PrinterConnection.open(host, transport: Self.at(host, Self.serve(dir)))
        #expect(c.probe.webPage != nil)
    }

    @Test func recordingTheDemoCDMLaserKeepsItsJSON() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.13"
        let laser = Self.fixtureDir("cdm-laser")
        let result = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, Self.serve(laser)), placeholder: host))

        #expect(result.interfaces == ["CDM"])
        #expect(Self.files(laser) == result.files.filter { $0 != PrinterRecorder.notesFile }.sorted())
        #expect(try await Self.seen(host, Self.at(host, Self.serve(laser))) == Self.seen(host, Self.at(host, Self.serve(dir))))
    }

    @Test func recordingAnSNMPOnlyPrinterWritesAWalkTheMadeUpAgentServes() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.14"
        let walk = try Fixtures.text("snmp-demo/workgroup-laser.txt")
        let result = try await PrinterRecorder.record(host, to: dir, Self.options(HostRouter([:]), snmp: try Self.agent(walk), placeholder: host))

        #expect(result.interfaces == ["SNMP"])
        #expect(result.files.contains(PrinterRecorder.snmpFile))
        let recordedWalk = try String(contentsOf: dir.appendingPathComponent(PrinterRecorder.snmpFile), encoding: .utf8)
        #expect(try await Self.seen(host, HostRouter([:]), Self.agent(walk)) == Self.seen(host, HostRouter([:]), Self.agent(recordedWalk)))
        // Every object the reader walks is there, so the agent answers each GetNext as the printer did.
        let objects = try SnmpAgent.parseWalk(walk).filter { o in PrinterRecorder.snmpSubtrees.contains { o.name.isUnder($0) } }.map { $0.name.description }
        let kept = Set(try SnmpAgent.parseWalk(recordedWalk).map { $0.name.description })
        #expect(objects.allSatisfy(kept.contains), "\(objects.filter { !kept.contains($0) })")
    }

    @Test func aRecordingAsksWithThePrintersOwnLoginOnly() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.14"
        let agent = SnmpAgent(try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/workgroup-laser.txt")), community: "kx9-office")
        var options = Self.options(HostRouter([:]), snmp: agent, placeholder: host)
        options.login = try SnmpLogin.forCommunity("kx9-office")
        let result = try await PrinterRecorder.record(host, to: dir, options)
        #expect(result.files.contains(PrinterRecorder.snmpFile))
        #expect(!agent.received.isEmpty)
        #expect(agent.received.allSatisfy { $0.community == "kx9-office" }) // the connection's probe and reading too, never public
        let recorded = try String(contentsOf: dir.appendingPathComponent(PrinterRecorder.snmpFile), encoding: .utf8)
        #expect(!recorded.contains("kx9-office"))
    }

    /// The fixtures behind a network that notes each request's method and content type.
    private final class Spy: HttpTransport {
        private let inner: any HttpTransport
        private let log = Mutex<[String]>([])

        init(_ inner: any HttpTransport) { self.inner = inner }

        var sent: [String] { log.withLock { $0 } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            let type = request.header("Content-Type")?.split(separator: ";").first.map(String.init) ?? ""
            log.withLock { $0.append(type.isEmpty ? request.method : "\(request.method) \(type)") }
            return try await inner.send(request)
        }
    }

    @Test func aRecordingOnlyReads() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = FixtureTransport.demoHost
        let spy = Spy(Self.serve(Self.fixtureDir("m234dw")))
        _ = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, spy)))

        #expect(!spy.sent.isEmpty)
        #expect(spy.sent.allSatisfy { $0.hasPrefix("GET") || $0 == "POST application/ipp" }, "\(spy.sent)")
    }

    // MARK: Scrubbing

    private static let plantedHost = "10.20.30.40"
    private static let serial = "CNB7K2M9QZ", uuid = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f", mac = "a0:b1:c2:d3:e4:f5"

    /// What a real printer's replies carry about it, its network and its people: none may survive a recording.
    static let planted = [
        serial, uuid, mac, "A0B1C2D3E4F5", "A0-B1-C2-D3-E4-F5", plantedHost, "10.20.30.41", "fe80::1c2b:3a4d:5e6f:7a8b", "2a02:810d:4b3f:1200",
        "NPI7A1B2C", "jdoe-printer", "corp.lan", "HPF0A1B2", "A1B2C3", "jane", "contoso", "jdoe", "JDOE-LAPTOP", "Tax return",
        "Second floor", "Garcia family", "12345678-1234-4abc-8def-123456789abc", "CNB0A00000", "VNB3R12345",
    ]

    static func plant(_ name: String, _ text: String) -> String {
        switch name {
        case "DevMgmt_ProductConfigDyn.xml":
            return text.replacingOccurrences(of: "12345678-1234-4abc-8def-123456789abc", with: uuid).replacingOccurrences(of: "CNB0A00000", with: serial)
                .replacingOccurrences(of: "<dd:DeviceLocation ></dd:DeviceLocation>", with: "<dd:DeviceLocation>Jane's office, second floor</dd:DeviceLocation>")
        case "eSCL_ScannerCapabilities.xml":
            return text.replacingOccurrences(of: "12345678-1234-4abc-8def-123456789abc", with: uuid).replacingOccurrences(of: "CNB0A00000", with: serial)
                .replacingOccurrences(of: "</scan:ScannerCapabilities>",
                                      with: "<scan:AdminURI>http://NPI7A1B2C.local/#hId-pgDevInfo</scan:AdminURI><scan:IconURI>http://\(plantedHost)/ipp/images/printer.png</scan:IconURI></scan:ScannerCapabilities>")
        case "eSCL_ScannerStatus.xml":
            return text.replacingOccurrences(of: "</scan:ScannerStatus>", with:
                "<scan:Jobs><scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/\(uuid)</pwg:JobUri><pwg:JobUuid>\(uuid)</pwg:JobUuid><scan:Age>20</scan:Age>"
                + "<pwg:JobState>Completed</pwg:JobState><pwg:JobName>Tax return 2025.pdf</pwg:JobName><pwg:JobOriginatingUserName>jdoe</pwg:JobOriginatingUserName>"
                + "</scan:JobInfo></scan:Jobs></scan:ScannerStatus>")
        case "DevMgmt_ProductStatusDyn.xml":
            return text.replacingOccurrences(of: "</psdyn:ProductStatusDyn>", with: "<!-- seen from 10.20.30.41 at \(mac) --></psdyn:ProductStatusDyn>")
        default:
            return text
        }
    }

    static let plantedIpp = """
        printer-uri-supported uri ipp://\(plantedHost):631/ipp/print
        printer-uri-supported uri ipps://[fe80::1c2b:3a4d:5e6f:7a8b]:631/ipp/print
        printer-uri-supported uri ipps://jdoe-printer.corp.lan:631/ipp/print
        printer-name name Jane Doe's LaserJet
        printer-info text Garcia family printer
        printer-location text Jane's office, second floor
        printer-dns-sd-name name HP LaserJet MFP M234dw [A1B2C3]
        printer-make-and-model text HP LaserJet MFP M234dw
        printer-device-id text MFG:HP;MDL:LaserJet MFP M234dw;CMD:PCL,PWG,URF;SN:\(serial);
        printer-uuid uri urn:uuid:\(uuid)
        printer-more-info uri http://HPF0A1B2.local/#hId-pgDevInfo
        printer-state enum 3
        printer-state-reasons keyword none
        printer-state-message text Ready. Last job from JDOE-LAPTOP (2a02:810d:4b3f:1200::12), contact jane.doe@contoso.com, MAC A0-B1-C2-D3-E4-F5
        job-originating-user-name name jdoe
        operations-supported enum 11
        """

    static func plantedWalk() throws -> String {
        let walk = try Fixtures.text("snmp-demo/workgroup-laser.txt")
        let keep = try SnmpAgent.parseWalk(walk).filter { o in
            !o.name.description.hasPrefix("1.3.6.1.2.1.1.") && !o.name.description.hasPrefix("1.3.6.1.2.1.43.5.1.1.17.")
        }
        return SnmpAgent.formatWalk(keep) + """
            .1.3.6.1.2.1.1.1.0 = STRING: "HP LaserJet MFP M234dw, SN:\(serial), at 10.20.30.41"
            .1.3.6.1.2.1.1.4.0 = STRING: "Jane Doe <jane.doe@contoso.com>"
            .1.3.6.1.2.1.1.5.0 = STRING: "NPI7A1B2C"
            .1.3.6.1.2.1.1.6.0 = STRING: "Jane's office, second floor"
            .1.3.6.1.2.1.43.5.1.1.17.1 = STRING: "\(serial)"
            .1.3.6.1.2.1.43.5.1.1.20.1 = STRING: "Jane Doe"
            .1.3.6.1.2.1.43.5.1.1.21.1 = STRING: "jane.doe@contoso.com"
            .1.3.6.1.2.1.25.3.2.1.6.1 = Hex-STRING: A0 B1 C2 D3 E4 F5
            """
    }

    @Test func identifiersPlantedInTheRepliesDontSurviveARecording() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m234dw = Self.fixtureDir("m234dw")
        let printer = { @Sendable () -> FixtureTransport in
            FixtureTransport(document: { name in
                if name == "ipp_print.ipp.txt" { return Array(Self.plantedIpp.utf8) }
                guard let data = FileManager.default.contents(atPath: m234dw.appendingPathComponent(name).path) else { return nil }
                return Array(Self.plant(name, String(decoding: data, as: UTF8.self)).utf8)
            })
        }

        let result = try await PrinterRecorder.record(Self.plantedHost, to: dir,
                                                      Self.options(Self.at(Self.plantedHost, printer()), snmp: try Self.agent(Self.plantedWalk())))

        #expect(result.interfaces == ["LEDM", "CDM", "eSCL", "IPP", "SNMP"])
        for file in Self.files(dir) {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for planted in Self.planted {
                #expect(text.range(of: planted, options: .caseInsensitive) == nil, "\(planted) left in \(file)")
            }
        }

        // Still one printer, read as before: every interface's UUID is the one stand-in, LEDM's serial is SNMP's.
        let host = FixtureScrubber.defaultPlaceholderHost
        let c = try await PrinterConnection.open(host, transport: Self.at(host, Self.serve(dir)))
        #expect(c.probe.interfaces == ["LEDM", "CDM", "eSCL", "IPP"])
        #expect(Set(c.probe.reportedUuids.compactMap { $0?.replacingOccurrences(of: "urn:uuid:", with: "").lowercased() }).count == 1)
        let recordedWalk = try String(contentsOf: dir.appendingPathComponent(PrinterRecorder.snmpFile), encoding: .utf8)
        let snmp = try await SnmpPrinterClient.probe(transport: Self.agent(recordedWalk), host: host)
        #expect(c.probe.serialNumber == snmp?.identity.serialNumber)
        let original = try await PrinterConnection.open(Self.plantedHost, transport: Self.at(Self.plantedHost, printer()))
        #expect(try await original.read() == c.read())
        // What a person typed says what it was.
        let ipp = try String(contentsOf: dir.appendingPathComponent("ipp_print.ipp.txt"), encoding: .utf8)
        #expect(ipp.contains("printer-location text Location"))
        #expect(ipp.contains("printer-name name Printer"))
        #expect(ipp.contains("job-originating-user-name name user"))
        #expect(ipp.contains("printer-uri-supported uri ipp://\(host):631/ipp/print"))
    }

    @Test func theScrubberKeepsDocumentationAddressesVersionsAndModels() {
        let s = FixtureScrubber("192.0.2.10", who: Self.me)
        let text = "Firmware 20230913 version 1.2.3.4, mask 255.255.255.0, at 192.0.2.10 and 198.51.100.7, HP LaserJet MFP M234dw, W1340A"
        #expect(s.scrub("x.txt", text) == text)
    }

    private static func hex(_ text: String) -> String { "01" + text.utf8.map { b in (b < 16 ? "0" : "") + String(b, radix: 16, uppercase: true) }.joined() }

    @Test func whatAPrinterSaysOverSnmpDoesntSurviveInItsModelLineAHexStringOrItsPrinterName() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let walk = try Fixtures.text("snmp-demo/workgroup-laser.txt")
        let dropped = ["1.3.6.1.2.1.1.", "1.3.6.1.2.1.25.3.2.1.3.", "1.3.6.1.2.1.43.5.1.1.16.", "1.3.6.1.2.1.43.5.1.1.17.", "1.3.6.1.2.1.43.5.1.1.20."]
        let keep = try SnmpAgent.parseWalk(walk).filter { o in !dropped.contains { o.name.description.hasPrefix($0) } }
        let planted = SnmpAgent.formatWalk(keep) + """
            .1.3.6.1.2.1.1.1.0 = STRING: "HP Laser, SN:CNB7K12345, at 10.20.30.41"
            .1.3.6.1.2.1.1.5.0 = Hex-STRING: \(Self.hex("Garcia-office"))
            .1.3.6.1.2.1.1.6.0 = Hex-STRING: \(Self.hex("Janes-room"))
            .1.3.6.1.2.1.25.3.2.1.3.1 = STRING: "HP Laser, SN:CNB7K12345, at 10.20.30.41"
            .1.3.6.1.2.1.43.5.1.1.16.1 = STRING: "Garcia family printer"
            .1.3.6.1.2.1.43.5.1.1.17.1 = Hex-STRING: \(Self.hex("CNB7K12345"))
            .1.3.6.1.2.1.43.5.1.1.20.1 = Hex-STRING: \(Self.hex("Jane"))

            """
        let host = "10.20.30.41"

        _ = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, FixtureTransport(document: { _ in nil })), snmp: try Self.agent(planted)))

        for file in Self.files(dir) {
            let text = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for left in ["CNB7K12345", "10.20.30.41", "Garcia", String(Self.hex("Garcia-office").dropFirst(2)), String(Self.hex("Janes-room").dropFirst(2)),
                         String(Self.hex("CNB7K12345").dropFirst(2)), String(Self.hex("Jane").dropFirst(2))] {
                #expect(text.range(of: left, options: .caseInsensitive) == nil, "\(left) left in \(file)")
            }
        }
    }

    @Test func ippTextReadsBackWhatItWrites() throws {
        let values = try IppText.parse(Fixtures.text("inkjet-demo/ipp_print.ipp.txt"))
        let again = try IppText.parse(IppText.fromResponse(IppCodec.encodeResponse(status: 0, requestId: 7, values)))
        #expect(values == again)
    }

    @Test func aWalkReadsBackWhatItWrites() throws {
        let objects = try SnmpAgent.parseWalk(Fixtures.text("snmp-demo/color-mfp.txt"))
        #expect(objects.sorted { $0.name < $1.name } == (try SnmpAgent.parseWalk(SnmpAgent.formatWalk(objects))))
    }

    // MARK: Collections, dateTime, Counter64 and Opaque

    /// Collections (one nested, a member with two values, two of one attribute, an empty one) and a dateTime.
    private static let collections = """
        media-col-ready collection {
          media-size collection {
            x-dimension integer 21590
            y-dimension integer 27940
          }
          media-source keyword main
          media-type keyword stationery
          media-type keyword plain
        }
        media-col-ready collection {
          media-size collection {
            x-dimension integer 21000
            y-dimension integer 29700
          }
          media-source keyword by-pass-tray
        }
        printer-xri-supported collection {
          xri-uri uri ipp://192.0.2.11/ipp/print
          xri-security keyword none
          xri-authentication keyword none
        }
        job-presets-supported collection {}
        printer-current-time dateTime 2026-11-20T09:30:15.4-04:00
        printer-config-change-date-time dateTime 2016-12-31T23:59:60.0+14:00
        """

    @Test func ippTextKeepsCollectionsAndDatesAsThePrinterSentThem() throws {
        let values = try IppText.parse(Self.collections)
        let wire = IppCodec.encodeResponse(status: 0, requestId: 7, values)
        let text = try IppText.fromResponse(wire)
        #expect(!text.contains("Not kept"))
        #expect(values == (try IppText.parse(text)))
        #expect(wire == IppCodec.encodeResponse(status: 0, requestId: 7, try IppText.parse(text))) // byte for byte

        let r = try IppCodec.decode(wire)
        let ready = r.collections("media-col-ready")
        try #require(ready.count == 2)
        #expect(ready[0].collection("media-size")?.int("y-dimension") == 27940)
        #expect(ready[0].members["media-type"] == [.text("stationery"), .text("plain")])
        #expect(ready[1].str("media-source") == "by-pass-tray")
        #expect(r.collections("job-presets-supported").map(\.members.count) == [0])
        var when = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(secondsFromGMT: -4 * 3600),
                                  year: 2026, month: 11, day: 20, hour: 9, minute: 30, second: 15)
        when.nanosecond = 0
        #expect(r.attributes["printer-current-time"]?.first == .date(try #require(when.date)))
    }

    @Test(arguments: [
        "media-col collection {\nmedia-source keyword main", // not closed
        "}", // closes nothing
        "media-col collection main",
        "printer-current-time dateTime 2026-11-20T09:30:15-04:00", // no deciseconds
        "printer-current-time dateTime 2026-13-20T09:30:15.0-04:00",
        "printer-current-time dateTime 2026-11-20T09:30:15.0*04:00",
        "printer-current-time dateTime 2026-11-20T09:30:15.0+15:00",
        "printer-current-time dateTime ２026-11-20T09:30:15.0+01:00", // a digit that isn't ASCII
    ])
    func ippTextRefusesBrokenCollectionsAndDates(_ text: String) {
        #expect(throws: IppFormatError.self) { try IppText.parse(text) }
    }

    @Test func ippTextRefusesCollectionsNestedPastTheCodecsLimit() throws {
        let n = IppCodec.maxCollectionDepth
        let deep = String(repeating: "c collection {\n", count: n + 1) + String(repeating: "}\n", count: n + 1)
        #expect(throws: IppFormatError.self) { try IppText.parse(deep) }
        let deepest = String(repeating: "c collection {\n", count: n) + String(repeating: "}\n", count: n)
        let back = try IppText.fromResponse(IppCodec.encodeResponse(status: 0, requestId: 1, try IppText.parse(deepest)))
        func squeezed(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "") }
        #expect(squeezed(deepest) == squeezed(back))
    }

    @Test func whatIppTextCantHoldIsNamedAndTheRestOfACollectionKept() throws {
        // A dateTime no DateAndTime is (month 13), a member value of an unknown type (0x35, textWithLanguage), and a value with no member name.
        var b: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 7, 0x01, 0x04]
        func attr(_ tag: UInt8, _ name: String, _ value: [UInt8]) {
            let n = Array(name.utf8)
            b.append(tag)
            b += [UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n
            b += [UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
        }
        attr(0x31, "printer-current-time", [0x07, 0xEA, 13, 20, 9, 30, 15, 0, UInt8(ascii: "+"), 0, 0])
        attr(0x34, "media-col-ready", [])
        attr(0x34, "", []) // a nested collection before any member name: left out whole
        attr(0x21, "", [0, 0, 0, 1])
        attr(0x37, "", [])
        attr(0x4A, "", Array("media-source".utf8))
        attr(0x44, "", Array("main".utf8))
        attr(0x4A, "", Array("media-info".utf8))
        attr(0x35, "", [0, 2, UInt8(ascii: "e"), UInt8(ascii: "n"), 0, 1, UInt8(ascii: "x")])
        attr(0x37, "", [])
        b.append(0x03)

        let text = try IppText.fromResponse(b)
        #expect(text.hasPrefix("# Not kept (no IppText form): media-col-ready (part), printer-current-time\n"))
        #expect(text.contains("media-col-ready collection {\n  media-source keyword main\n}\n"))
        #expect(try IppText.parse(text).count == 1)
    }

    @Test func aRecordingKeepsThePrintersCollectionsAndDates() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.11"
        let inkjet = Self.fixtureDir("inkjet-demo")
        let withCollections: @Sendable (String, String) -> String = { name, text in
            name == "ipp_print.ipp.txt" ? "\(text)\n\(RecordingTests.collections)\n" : text
        }
        _ = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, Self.serve(inkjet, withCollections)), placeholder: host))

        let recorded = try String(contentsOf: dir.appendingPathComponent("ipp_print.ipp.txt"), encoding: .utf8)
        #expect(!recorded.contains("Not kept"))
        #expect(recorded.contains("printer-current-time dateTime 2026-11-20T09:30:15.4-04:00"))
        #expect(recorded.contains("  xri-security keyword none"))
        #expect(try await Self.seen(host, Self.at(host, Self.serve(inkjet, withCollections))) == Self.seen(host, Self.at(host, Self.serve(dir))))
    }

    @Test func anAddressInsideACollectionIsScrubbedLikeAnyOther() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.11"
        let planted: @Sendable (String, String) -> String = { name, text in
            name == "ipp_print.ipp.txt"
                ? "\(text)\n\(RecordingTests.collections.replacingOccurrences(of: "ipp://192.0.2.11/", with: "ipp://\(RecordingTests.plantedHost)/"))\n"
                : text
        }
        _ = try await PrinterRecorder.record(host, to: dir, Self.options(Self.at(host, Self.serve(Self.fixtureDir("inkjet-demo"), planted)), placeholder: host))

        let recorded = try String(contentsOf: dir.appendingPathComponent("ipp_print.ipp.txt"), encoding: .utf8)
        #expect(!recorded.contains(Self.plantedHost))
        #expect(recorded.contains(try Regex(#"\n  xri-uri uri ipp://[^/]+/ipp/print\n"#)))
    }

    @Test func aWalkKeepsCounter64AndOpaqueValues() throws {
        let walk = """
            .1.3.6.1.2.1.31.1.1.1.6.1 = Counter64: 18446744073709551615
            .1.3.6.1.2.1.31.1.1.1.10.1 = Counter64: 48213
            .1.3.6.1.4.1.2021.10.1.6.1 = Opaque: 9F78043FC00000
            .1.3.6.1.4.1.2021.10.1.6.2 = OPAQUE: 9F 78 04 00 00 00 00
            .1.3.6.1.4.1.2021.10.1.6.3 = Opaque:
            """
        let objects = try SnmpAgent.parseWalk(walk)
        #expect(UInt64(bitPattern: objects[0].value.number) == UInt64.max)
        #expect(objects[1].value.tag == Ber.counter64 && objects[1].value.int == 48213)
        #expect(objects[2].value.tag == Ber.opaque && SnmpValue.hexString(objects[2].value.bytes ?? []) == "9F78043FC00000")
        #expect(objects[4].value.bytes == [])

        let written = SnmpAgent.formatWalk(objects)
        #expect(!written.contains("not kept"))
        #expect(written.contains(".1.3.6.1.2.1.31.1.1.1.6.1 = Counter64: 18446744073709551615"))
        #expect(objects.sorted { $0.name < $1.name } == (try SnmpAgent.parseWalk(written)))
    }

    @Test func theMadeUpAgentServesCounter64AndOpaqueAsThePrinterDid() async throws {
        let agent = try Self.agent(".1.3.6.1.2.1.31.1.1.1.6.1 = Counter64: 18446744073709551615\n.1.3.6.1.4.1.2021.10.1.6.1 = Opaque: 9F78043FC00000\n")
        let client = SnmpClient(transport: agent, host: "192.0.2.14", version: .v2c)
        let got = try await client.get(["1.3.6.1.2.1.31.1.1.1.6.1", "1.3.6.1.4.1.2021.10.1.6.1"])
        #expect(got[0].value.tag == Ber.counter64 && UInt64(bitPattern: got[0].value.number) == UInt64.max)
        #expect(got[0].value.description == "Counter64: 18446744073709551615")
        #expect(got[1].value.tag == Ber.opaque && SnmpValue.hexString(got[1].value.bytes ?? []) == "9F78043FC00000")
    }

    @Test func recordingAnSnmpPrinterKeepsItsCounter64AndOpaqueObjects() async throws {
        let dir = Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let host = "192.0.2.14"
        let walk = try Fixtures.text("snmp-demo/workgroup-laser.txt")
            + ".1.3.6.1.2.1.43.10.2.1.5.1.1 = Counter64: 9223372036854775808\n.1.3.6.1.2.1.43.5.1.1.99.1 = Opaque: 9F78043FC00000\n"
        _ = try await PrinterRecorder.record(host, to: dir, Self.options(HostRouter([:]), snmp: try Self.agent(walk), placeholder: host))
        let recorded = try String(contentsOf: dir.appendingPathComponent(PrinterRecorder.snmpFile), encoding: .utf8)
        #expect(recorded.contains(".1.3.6.1.2.1.43.10.2.1.5.1.1 = Counter64: 9223372036854775808"))
        #expect(recorded.contains(".1.3.6.1.2.1.43.5.1.1.99.1 = Opaque: 9F78043FC00000"))
        #expect(!recorded.contains("not kept"))
    }
}
