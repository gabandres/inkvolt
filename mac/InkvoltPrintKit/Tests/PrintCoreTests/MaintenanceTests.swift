import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Printer maintenance: what a printer offers (HP LEDM internal pages and alignment, IPP Identify-Printer, the supply page)
/// and the exact requests sent. Every request goes to a recording fake; nothing reaches a network. The HP documents below
/// are written by hand from public sources (HPLIP's base/maint.py, published LEDM dumps), never captured from a device.
/// Ported from MaintenanceTests.cs. Elsewhere or left out:
/// - Identify_printer_request_is_encoded_byte_for_byte and Identify_printer_without_actions_or_user_leaves_them_out are in
///   IppTests (identifyPrinterRequestIsEncodedByteForByte, identifyPrinterWithoutActionsOrUserLeavesThemOut).
/// - A_dropped_connection_never_makes_a_maintenance_write_arrive_twice and
///   The_one_use_connection_also_stops_the_resend_dotnet_does_on_a_reused_connection: they test .NET's HttpClient against a
///   loopback server (its connection pool and resend rule). PrintCore opens no sockets; a one-use request is `once`
///   (checked in maintenanceWritesAskForAConnectionOfTheirOwn), which PrintMac's URLSession transport sends on a session
///   of its own.
/// - Whether_a_failed_request_was_sent ("tls"): `DeviceNetworkError` has no TLS case (a failed handshake is `.failed`, as
///   is a lost answer), so it counts as maybe sent: "may have started", never "Not sent".
struct MaintenanceTests {
    private static let host = "192.0.2.10", inkjetHost = "192.0.2.11"

    // MARK: Request bodies

    @Test func internalPrintBodyIsTheLedmInternalPrintDynDocument() throws {
        #expect(try MaintenanceRequests.internalPrint("configurationPage")
            == #"<?xml version="1.0" encoding="UTF-8"?><ipdyn:InternalPrintDyn xmlns:ipdyn="http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21"><ipdyn:JobType>configurationPage</ipdyn:JobType></ipdyn:InternalPrintDyn>"#)
    }

    @Test func internalPrintRefusesJobTypesOutsideTheCatalog() {
        #expect(throws: UnknownJobType.self) { try MaintenanceRequests.internalPrint("demoPage</ipdyn:JobType><x>") }
    }

    @Test func alignmentBodyAsksTheCalibrationSessionToPrint() {
        #expect(MaintenanceRequests.startAlignment()
            == #"<?xml version="1.0" encoding="UTF-8"?><cal:CalibrationState xmlns:cal="http://www.hp.com/schemas/imaging/con/cnx/markingagentcalibration/2009/04/08">Printing</cal:CalibrationState>"#)
    }

    // MARK: Parsing what the printer advertises

    private static let inkjetCap = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ipcap:InternalPrintCap xmlns:ipcap="http://www.hp.com/schemas/imaging/con/ledm/internalprintcap/2008/03/21"
                                xmlns:ipdyn="http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21">
          <ipdyn:JobType>cleaningPage</ipdyn:JobType>
          <ipdyn:JobType>cleaningPageLevel1</ipdyn:JobType>
          <ipdyn:JobType>cleaningPageLevel2</ipdyn:JobType>
          <ipdyn:JobType>cleaningVerificationPage</ipdyn:JobType>
          <ipdyn:JobType>pqDiagnosticsPage</ipdyn:JobType>
          <ipdyn:JobType>configurationPage</ipdyn:JobType>
          <ipdyn:JobType>demoPage</ipdyn:JobType>
          <ipdyn:JobType>  configurationPage </ipdyn:JobType>
        </ipcap:InternalPrintCap>
        """

    @Test func jobTypesAreReadFromInternalPrintCapInAnySpelling() throws {
        #expect(MaintenanceRequests.parseJobTypes(try DeviceXml.load(Self.inkjetCap))
            == ["cleaningPage", "cleaningPageLevel1", "cleaningPageLevel2", "cleaningVerificationPage", "pqDiagnosticsPage", "configurationPage", "demoPage"])
        #expect(MaintenanceRequests.parseJobTypes(try DeviceXml.load(
            #"<InternalPrintCap><jobType>cleaningPage</jobType><x:InternalPrintJobType xmlns:x="urn:x">networkSummary</x:InternalPrintJobType><Other>configurationPage</Other></InternalPrintCap>"#))
            == ["cleaningPage", "networkSummary"])
    }

    private static let inkjetConsumables = """
        <ccdyn:ConsumableConfigDyn xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:ccdyn="http://www.hp.com/schemas/imaging/con/ledm/consumableconfigdyn/2007/11/19">
          <ccdyn:ProductConsumableInfo><dd:AlignmentMode>semiAutomatic</dd:AlignmentMode></ccdyn:ProductConsumableInfo>
          <ccdyn:ConsumableInfo><dd:ConsumableTypeEnum>ink</dd:ConsumableTypeEnum></ccdyn:ConsumableInfo>
        </ccdyn:ConsumableConfigDyn>
        """

    @Test func alignmentModeAndMarkingComeFromConsumableConfigDyn() throws {
        #expect(MaintenanceRequests.parseAlignmentMode(try DeviceXml.load(Self.inkjetConsumables)) == "semiAutomatic")
        #expect(MaintenanceRequests.parseMarking(try DeviceXml.load(Self.inkjetConsumables)) == .ink)
        // The M234dw (a laser) reports toner and no alignment mode.
        let m234dw = try DeviceXml.load(Fixtures.data("m234dw/DevMgmt_ConsumableConfigDyn.xml"))
        #expect(MaintenanceRequests.parseAlignmentMode(m234dw) == nil)
        #expect(MaintenanceRequests.parseMarking(m234dw) == .toner)
    }

    @Test(arguments: [
        (#"<cal:CalibrationState xmlns:cal="urn:cal">Printing</cal:CalibrationState>"#, CalibrationStatus.running),
        ("<State><CalibrationState>Scanning</CalibrationState></State>", .running),
        (#"<cal:CalibrationState xmlns:cal="urn:cal">ParmsRequested</cal:CalibrationState>"#, .awaitingParameters),
        ("<State><ParmsRequested/></State>", .awaitingParameters),
        (#"<cal:CalibrationState xmlns:cal="urn:cal">CalibrationValid</cal:CalibrationState>"#, .idle),
        (#"<cal:CalibrationState xmlns:cal="urn:cal">CalibrationRequired</cal:CalibrationState>"#, .idle),
    ] as [(String, CalibrationStatus)])
    func theCalibrationStateSaysWhetherAnAlignmentCanStart(_ xml: String, _ expected: CalibrationStatus) throws {
        #expect(MaintenanceRequests.readCalibration(try DeviceXml.load(xml)) == expected)
    }

    // MARK: The catalog: only what the printer advertises

    private static func hp(_ jobs: [String]?, _ alignment: String? = nil, marking: Marking = .ink) -> MaintenanceSources {
        MaintenanceSources(host: host, hasLedm: true, ledmJobTypes: jobs, ledmDynPath: "/DevMgmt/InternalPrintDyn.xml", alignmentMode: alignment,
                           marking: marking)
    }

    @Test func hpActionsFollowTheAdvertisedJobTypesInAFixedOrder() throws {
        let options = MaintenanceCatalog.detect(Self.hp(MaintenanceRequests.parseJobTypes(try DeviceXml.load(Self.inkjetCap))))

        #expect(options.actions.map(\.id) == ["ledm:configurationPage", "ledm:pqDiagnosticsPage", "ledm:cleaningPage", "ledm:cleaningPageLevel1",
                                              "ledm:cleaningPageLevel2", "ledm:cleaningVerificationPage"])
        #expect(options.actions.allSatisfy { $0.brand == "HP" })
        #expect(options.actions.allSatisfy { $0.target == "/DevMgmt/InternalPrintDyn.xml" })
        #expect(!options.actions.contains { $0.jobType == "demoPage" }) // not maintenance: never offered
        let cleaning = options.actions.filter { $0.kind == .cleaning }
        #expect(cleaning.map(\.level) == [1, 2, 3])
        #expect(cleaning[0].label == "Clean printhead (HP)")
        #expect(cleaning[1].label == "Clean printhead, level 2 (HP)")
        #expect(cleaning[1].uses.contains("more ink"))
        #expect(options.actions.allSatisfy { $0.printsPage })
        #expect(options.actions[0].uses.contains("plain paper"))
    }

    @Test func cleaningLevelsAreRankedWhateverTheFirmwareCallsThem() {
        let options = MaintenanceCatalog.detect(Self.hp(["cleaningPageLevel3", "cleaningPage", "cleaningPageLevel2"]))
        #expect(options.actions.map(\.jobType) == ["cleaningPage", "cleaningPageLevel2", "cleaningPageLevel3"])
        #expect(options.actions.map(\.level) == [1, 2, 3])
    }

    @Test func aTonerPrinterGetsTonerWordingAndNoInkOnlyActions() {
        let options = MaintenanceCatalog.detect(Self.hp(["configurationPage", "cleaningPage", "ribSmearCleaningPage"], marking: .toner))
        #expect(options.actions.map(\.id) == ["ledm:configurationPage", "ledm:cleaningPage"])
        #expect(options.actions[1].label == "Print cleaning page (HP)")
        #expect(options.actions[1].uses.contains("toner"))
        #expect(!options.actions[1].uses.contains("ink"))
    }

    @Test(arguments: [("automatic", nil), ("semiAutomatic", nil), ("manual", "control panel")] as [(String, String?)])
    func alignmentIsOfferedWhenTheCalibrationInterfaceAndAModeAreThere(_ mode: String, _ reason: String?) throws {
        let actions = MaintenanceCatalog.detect(Self.hp(nil, mode)).actions
        try #require(actions.count == 1)
        let align = actions[0]
        #expect(align.kind == .alignment)
        #expect(align.label == "Align printhead (HP)")
        #expect(align.target == MaintenanceRequests.calibrationSessionPath)
        if let reason { #expect(align.unavailable?.contains(reason) == true) } else { #expect(align.unavailable == nil) }
        if mode == "semiAutomatic" { #expect(align.uses.contains("scanner glass")) }
    }

    @Test func anHpPrinterWithoutMaintenanceInterfacesGetsNoActionsAndSaysWhy() {
        var sources = Self.hp(nil)
        sources.ledmDynPath = nil
        let options = MaintenanceCatalog.detect(sources)
        #expect(options.actions.isEmpty)
        #expect(options.note?.contains("web page") == true)
    }

    private static func ipp(_ text: String) throws -> IppResponse {
        try IppCodec.decode(IppCodec.encodeResponse(status: 0, requestId: 1, IppText.parse(text)))
    }

    @Test func identifyIsOfferedOnlyWhenOperationsSupportedListsIt() throws {
        let with = MaintenanceCatalog.detect(MaintenanceSources(host: Self.inkjetHost, ipp: try Self.ipp("""
            operations-supported enum 11
            operations-supported enum 60
            identify-actions-supported keyword flash
            identify-actions-supported keyword speak
            identify-actions-supported keyword sound
            printer-supply-info-uri uri http://192.0.2.11/supplies
            """)))
        try #require(with.actions.count == 1)
        let identify = with.actions[0]
        #expect(identify.kind == .identify)
        #expect(identify.brand == nil) // standard IPP, not one maker's
        #expect(identify.identifyActions == ["flash", "sound"]) // what Inkvolt Print asks for, in its order
        #expect(!identify.printsPage)
        #expect(identify.uses.contains("flashes its lights and makes a sound"))
        #expect(identify.summary == "Lights and sound · no paper or ink")
        #expect(with.supplyPage == URL(string: "http://192.0.2.11/supplies"))
        #expect(with.note?.contains("aren't part of the IPP printing standard") == true)

        let without = MaintenanceCatalog.detect(MaintenanceSources(host: Self.inkjetHost, ipp: try Self.ipp("operations-supported enum 11")))
        #expect(without.actions.isEmpty)
    }

    @Test func identifyWithNoKnownActionLetsThePrinterChoose() throws {
        let actions = MaintenanceCatalog.detect(MaintenanceSources(host: Self.inkjetHost,
                                                                   ipp: try Self.ipp("operations-supported enum 60\nidentify-actions-supported keyword speak"))).actions
        try #require(actions.count == 1)
        #expect(actions[0].identifyActions.isEmpty)
    }

    @Test(arguments: [
        "http://192.0.2.99/supplies", // another host: never followed
        "ftp://192.0.2.11/supplies",
        "http://user@192.0.2.11/supplies",
    ])
    func theSupplyPageMustBeOnThePrinterItself(_ uri: String) throws {
        #expect(MaintenanceCatalog.detect(MaintenanceSources(host: Self.inkjetHost, ipp: try Self.ipp("printer-supply-info-uri uri \(uri)"))).supplyPage == nil)
    }

    // MARK: When an action can run

    private static func config() -> MaintenanceAction { MaintenanceCatalog.detect(hp(["configurationPage"])).actions[0] }

    private static func identifyAction() throws -> MaintenanceAction {
        MaintenanceCatalog.detect(MaintenanceSources(host: inkjetHost, ipp: try ipp("operations-supported enum 60"))).actions[0]
    }

    private static func status(_ code: String, _ severity: Severity, _ message: String = "Ready") -> PrinterStatus {
        PrinterStatus(code: code, message: message, severity: severity, alerts: [])
    }

    @Test func actionsWaitForAnOnlineIdlePrinterWithReasons() throws {
        let config = Self.config(), identify = try Self.identifyAction()
        #expect(MaintenanceAvailability.whyNot(config, online: true, status: Self.status("ready", .info), busy: false) == nil)
        #expect(MaintenanceAvailability.whyNot(config, online: true, status: Self.status("lowToner", .warning), busy: false) == nil)
        #expect(MaintenanceAvailability.whyNot(config, online: false, status: nil, busy: false)?.contains("isn't answering") == true)
        #expect(MaintenanceAvailability.whyNot(config, online: true, status: Self.status("ready", .info), busy: true)?.contains("Waiting") == true)
        #expect(MaintenanceAvailability.whyNot(config, online: true, status: Self.status("jam", .error, "Paper jam"), busy: false)?.contains("Paper jam") == true)
        #expect(MaintenanceAvailability.whyNot(config, online: true, status: Self.status("processing", .info, "Printing"), busy: false)?.contains("printing") == true)
        #expect(MaintenanceAvailability.whyNot(config, online: true, status: Self.status("upgrading", .info, "Updating firmware"), busy: false)?
            .contains("Updating firmware") == true)
        // Identify prints nothing: a jam or a job doesn't stop it.
        #expect(MaintenanceAvailability.whyNot(identify, online: true, status: Self.status("jam", .error, "Paper jam"), busy: false) == nil)
        #expect(MaintenanceAvailability.whyNot(identify, online: true, status: Self.status("processing", .info), busy: false) == nil)
        let manual = MaintenanceCatalog.detect(Self.hp(nil, "manual")).actions[0]
        #expect(MaintenanceAvailability.whyNot(manual, online: true, status: Self.status("ready", .info), busy: false) == manual.unavailable)
    }

    @Test func eachActionAsksFirstAndSaysWhatItUses() throws {
        let actions = MaintenanceCatalog.detect(Self.hp(["configurationPage", "pqDiagnosticsPage", "cleaningPage", "networkSummary"], "automatic")).actions
            + [try Self.identifyAction()]
        for a in actions {
            #expect(a.confirmText.contains(a.uses))
            #expect(!a.confirmButton.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!a.summary.trimmingCharacters(in: .whitespaces).isEmpty)
            #expect(!a.sent.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    // MARK: The client against recording fakes

    /// Answers from `respond`, else from `inner` (404 without one); never opens a socket. Wrapped in `Network` to record.
    private struct Responder: HttpTransport {
        let respond: @Sendable (HttpRequest) throws -> HttpResponse?
        var inner: (any HttpTransport)?

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            if let answer = try respond(request) { return answer }
            return try await inner?.send(request) ?? HttpResponse(status: 404)
        }
    }

    private static func xml(_ text: String) -> HttpResponse { HttpResponse(status: 200, headers: ["Content-Type": "text/xml"], body: Array(text.utf8)) }

    private static func isGetPrinterAttributes(_ r: HttpRequest) -> Bool {
        r.header("Content-Type") == "application/ipp" && (try? IppCodec.readRequestHeader(r.body ?? []).operation) == IppCodec.getPrinterAttributes
    }

    private static func isReading(_ r: HttpRequest) -> Bool { r.method == "GET" || isGetPrinterAttributes(r) }

    @Test func detectingOnTheM234dwOnlyReadsAndFindsNothingToOffer() async throws {
        let recorder = Network(Printers.folder("m234dw"))
        let conn = try await PrinterConnection.open(Self.host, transport: recorder)
        recorder.clear()

        let options = try await MaintenanceClient(conn).detect()

        #expect(options.actions.isEmpty) // the real M234dw answers 404 for InternalPrintCap and lists no calibration interface
        #expect(options.note?.contains("web page") == true)
        let detection = recorder.seen
        #expect(!detection.isEmpty)
        #expect(detection.allSatisfy { Self.isReading($0) }, "\(detection.filter { !Self.isReading($0) }.map { "\($0.method) \($0.url)" })")
        #expect(detection.contains { $0.url.path == MaintenanceRequests.internalPrintCapPath })
    }

    @Test func detectingOnTheDemoInkjetFindsIdentifyAndTheSupplyPageByReadingOnly() async throws {
        let recorder = Network(Printers.folder("inkjet-demo"))
        let conn = try await PrinterConnection.open(Self.inkjetHost, transport: recorder)
        recorder.clear()

        let options = try await MaintenanceClient(conn).detect()

        #expect(options.actions.map(\.kind) == [.identify])
        #expect(options.supplyPage != nil)
        #expect(recorder.seen.allSatisfy { Self.isReading($0) })
    }

    private static let treeWithMaintenance = """
        <ledm:DiscoveryTree xmlns:ledm="http://www.hp.com/schemas/imaging/con/ledm/2007/09/21" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/">
          <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ProductStatusDyn.xml</dd:ResourceURI><dd:ResourceType>ledm:hpLedmProductStatusDyn</dd:ResourceType></ledm:SupportedTree>
          <ledm:SupportedTree><dd:ResourceURI>/DevMgmt/ConsumableConfigDyn.xml</dd:ResourceURI><dd:ResourceType>ledm:hpLedmConsumableConfigDyn</dd:ResourceType></ledm:SupportedTree>
          <ledm:SupportedIfc><ledm:ManifestURI>/DevMgmt/InternalPrintManifest.xml</ledm:ManifestURI><dd:ResourceType>ledm:hpLedmInternalPrintManifest</dd:ResourceType></ledm:SupportedIfc>
          <ledm:SupportedIfc><ledm:ManifestURI>/Calibration/CalibrationManifest.xml</ledm:ManifestURI><dd:ResourceType>ledm:hpCnxCalibrationManifest</dd:ResourceType></ledm:SupportedIfc>
        </ledm:DiscoveryTree>
        """

    private static let internalPrintManifest = """
        <man:Manifest xmlns:man="http://www.hp.com/schemas/imaging/con/ledm/manifest/2009/03/24" xmlns:map="http://www.hp.com/schemas/imaging/con/ledm/resourcemap/2009/01/27" xmlns:dd="http://www.hp.com/schemas/imaging/con/dictionaries/1.0/" xmlns:ip="urn:example:internalprint">
          <map:ResourceMap>
            <map:ResourceLink><dd:ResourceURI>/Maint</dd:ResourceURI></map:ResourceLink>
            <map:ResourceNode><map:ResourceLink><dd:ResourceURI>/PrintCap.xml</dd:ResourceURI></map:ResourceLink><map:ResourceType><ip:ResourceType>InternalPrintCap</ip:ResourceType></map:ResourceType></map:ResourceNode>
            <map:ResourceNode><map:ResourceLink><dd:ResourceURI>/PrintDyn.xml</dd:ResourceURI></map:ResourceLink><map:ResourceType><ip:ResourceType>InternalPrintDyn</ip:ResourceType></map:ResourceType></map:ResourceNode>
          </map:ResourceMap>
        </man:Manifest>
        """

    private static let m234dwStatus = (try? Fixtures.text("m234dw/DevMgmt_ProductStatusDyn.xml")) ?? ""

    /// A made-up HP inkjet: the tree lists both interfaces; its manifest moves the internal-print documents.
    private static func hpInkjet(post: (@Sendable (HttpRequest) throws -> HttpResponse)? = nil, calibrationState: String? = nil) -> Network {
        Network(Responder(respond: { r in
            if r.method == "POST" && r.header("Content-Type") != "application/ipp" { return try post?(r) ?? HttpResponse(status: 201) }
            switch r.url.path {
            case DiscoveryTree.path: return xml(treeWithMaintenance)
            case "/DevMgmt/InternalPrintManifest.xml": return xml(internalPrintManifest)
            case "/Maint/PrintCap.xml": return xml(inkjetCap)
            case "/DevMgmt/ConsumableConfigDyn.xml": return xml(inkjetConsumables)
            case "/DevMgmt/ProductStatusDyn.xml": return xml(m234dwStatus)
            case "/Calibration/State": return calibrationState.map(xml)
            default: return nil
            }
        }))
    }

    /// Requests that would change something on the printer (the IPP probe's Get-Printer-Attributes is a read).
    private static func ledmPosts(_ printer: Network) -> [HttpRequest] { printer.seen.filter { $0.method == "POST" && !isGetPrinterAttributes($0) } }

    private static func cleaningAction(_ client: MaintenanceClient) async throws -> MaintenanceAction {
        try #require(try await client.detect().actions.first { $0.kind == .cleaning })
    }

    @Test func theManifestDecidesWhereInternalPagesAreReadAndSent() async throws {
        let printer = Self.hpInkjet()
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let options = try await client.detect()

        let config = try #require(options.actions.first { $0.jobType == "configurationPage" })
        #expect(config.target == "/Maint/PrintDyn.xml")
        #expect(!printer.seen.contains { $0.url.path == MaintenanceRequests.internalPrintCapPath })
        #expect(options.actions.contains { $0.kind == .alignment && $0.unavailable == nil })
        #expect(printer.seen.allSatisfy { Self.isReading($0) })

        printer.clear()
        let result = try await client.run(config)

        #expect(result.ok, "\(result.message)")
        try #require(printer.seen.count == 1)
        let post = printer.seen[0]
        #expect(post.method == "POST")
        #expect(post.url == URL(string: "https://\(Self.host)/Maint/PrintDyn.xml")) // HTTPS: an admin password never crosses in clear text
        #expect(post.header("Content-Type")?.split(separator: ";").first == "text/xml")
        let expected = try MaintenanceRequests.internalPrint("configurationPage")
        #expect(String(decoding: post.body ?? [], as: UTF8.self) == expected)
        #expect(post.header("Origin") == "https://\(Self.host)")
        #expect(post.header("X-Requested-With") == "XMLHttpRequest")
    }

    @Test func alignmentChecksTheCalibrationStateThenStartsOneSession() async throws {
        let printer = Self.hpInkjet(calibrationState: #"<cal:CalibrationState xmlns:cal="urn:cal">CalibrationValid</cal:CalibrationState>"#)
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let align = try #require(try await client.detect().actions.first { $0.kind == .alignment })
        printer.clear()

        #expect(try await client.run(align).ok)

        let sent = printer.seen
        #expect(sent.map { "\($0.method) \($0.url.absoluteString)" } == ["GET http://\(Self.host)/Calibration/State", "POST https://\(Self.host)/Calibration/Session"])
        #expect(sent.count == 2 && String(decoding: sent[1].body ?? [], as: UTF8.self) == MaintenanceRequests.startAlignment())
    }

    @Test func anAlignmentAlreadyRunningIsNotStartedAgain() async throws {
        let printer = Self.hpInkjet(calibrationState: #"<cal:CalibrationState xmlns:cal="urn:cal">Printing</cal:CalibrationState>"#)
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let align = try #require(try await client.detect().actions.first { $0.kind == .alignment })

        let result = try await client.run(align)

        #expect(!result.ok)
        #expect(result.message.contains("already"))
        #expect(Self.ledmPosts(printer).isEmpty)
    }

    @Test func aPendingAlignmentSessionIsNotStartedOver() async throws {
        let printer = Self.hpInkjet(calibrationState: #"<cal:CalibrationState xmlns:cal="urn:cal">ParmsRequested</cal:CalibrationState>"#)
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let align = try #require(try await client.detect().actions.first { $0.kind == .alignment })

        let result = try await client.run(align)

        #expect(!result.ok)
        #expect(result.message.contains("turn the printer off and on"))
        #expect(Self.ledmPosts(printer).isEmpty)
    }

    @Test func maintenanceWritesAskForAConnectionOfTheirOwn() async throws {
        let printer = Self.hpInkjet()
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        _ = try await client.run(try await Self.cleaningAction(client))
        let posts = Self.ledmPosts(printer)
        #expect(posts.count == 1 && posts[0].once && posts[0].header("Connection") == "close")

        let recorder = Network(Printers.folder("inkjet-demo"))
        let inkjet = try await PrinterConnection.open(Self.inkjetHost, transport: recorder)
        let identifying = MaintenanceClient(inkjet)
        _ = try await identifying.run(try #require(try await identifying.detect().actions.first))
        let identify = Self.ledmPosts(recorder)
        #expect(identify.count == 1 && identify[0].once && identify[0].header("Connection") == "close")
    }

    @Test(arguments: [("refused", "Not sent"), ("tls", "may have started"), ("reset", "may have started")])
    func whetherAFailedRequestWasSentComesFromItsOwnError(_ failure: String, _ says: String) async throws {
        let error: DeviceNetworkError = switch failure {
        case "refused": .refused
        case "tls": .failed("An SSL error has occurred and a secure connection to the server cannot be made.")
        default: .failed("The network connection was lost.")
        }
        let printer = Self.hpInkjet(post: { _ in throw error })
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let clean = try await Self.cleaningAction(client)

        let result = try await client.run(clean)

        #expect(!result.ok)
        #expect(result.message.contains(says))
    }

    private final class Pins: CertificatePin {
        private let pins = Mutex<[Int: String]>([:])

        func get(_ port: Int) -> String? { pins.withLock { $0[port] } }

        func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String {
            pins.withLock { p in
                if let known = p[port] { return known }
                p[port] = sha256Hex
                return sha256Hex
            }
        }
    }

    @Test func aChangedCertificateOnAnotherPortDoesntMakeALostAnswerLookUnsent() async throws {
        let printer = Self.hpInkjet(post: { _ in throw DeviceNetworkError.failed("connection reset") })
        let pins = Pins()
        _ = pins.setIfAbsent(631, "00") // IPPS pinned to another certificate earlier
        let conn = try await PrinterConnection.open(Self.host, transport: printer, pin: pins)
        #expect(!conn.http.certificates.accept(sha256Hex: "11", port: 631))
        #expect(conn.http.certificateChanged) // sticky, and set by port 631

        let client = MaintenanceClient(conn)
        let result = try await client.run(try await Self.cleaningAction(client))

        #expect(result.message.contains("may have started")) // the cleaning POST on 443 may have arrived: never invite a second one
    }

    @Test(arguments: [(404, "doesn't offer"), (405, "doesn't offer"), (409, "busy"), (503, "busy"), (500, "HTTP 500")])
    func aRefusalIsReportedAndNeverRetried(_ status: Int, _ says: String) async throws {
        let printer = Self.hpInkjet(post: { _ in HttpResponse(status: status) })
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let clean = try await Self.cleaningAction(client)

        let result = try await client.run(clean)

        #expect(!result.ok)
        #expect(result.message.contains(says))
        #expect(Self.ledmPosts(printer).count == 1)
    }

    @Test func aPasswordProtectedPrinterAsksForTheAdminPassword() async throws {
        let printer = Self.hpInkjet(post: { _ in HttpResponse(status: 401) })
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let clean = try await Self.cleaningAction(client)

        await #expect(throws: LedmAuthRequiredError(credentialsWereSent: false)) { try await client.run(clean) }
    }

    @Test func aRequestLostOnTheWayBackSaysItMayHaveStarted() async throws {
        let printer = Self.hpInkjet(post: { _ in throw DeviceNetworkError.failed("connection reset") })
        let conn = try await PrinterConnection.open(Self.host, transport: printer)
        let client = MaintenanceClient(conn)
        let clean = try await Self.cleaningAction(client)

        let result = try await client.run(clean)

        #expect(!result.ok)
        #expect(result.message.contains("may have started"))
        #expect(Self.ledmPosts(printer).count == 1)
    }

    @Test func identifySendsOneIdentifyPrinterRequestToThePrintersIppAddress() async throws {
        let recorder = Network(Printers.folder("inkjet-demo"))
        let conn = try await PrinterConnection.open(Self.inkjetHost, transport: recorder)
        let client = MaintenanceClient(conn, userName: "alex")
        let identify = try #require(try await client.detect().actions.first)
        recorder.clear()

        let result = try await client.run(identify)

        #expect(result.ok, "\(result.message)")
        try #require(recorder.seen.count == 1)
        let sent = recorder.seen[0]
        #expect(sent.url == URL(string: "http://\(Self.inkjetHost):631/ipp/print"))
        #expect(sent.body == IppCodec.encodeIdentifyPrinter("ipp://\(Self.inkjetHost):631/ipp/print", userName: "alex", actions: identify.identifyActions,
                                                            requestId: 1))
    }

    @Test(arguments: [(0x0401, "signed-in"), (0x0402, "signed-in"), (0x0403, "signed-in"), (0x0501, "doesn't offer"), (0x0500, "0x0500")] as [(UInt16, String)])
    func identifyRefusalsAreExplained(_ status: UInt16, _ says: String) async throws {
        let recorder = Network(Responder(respond: { r in
            r.header("Content-Type") == "application/ipp" && (try? IppCodec.readRequestHeader(r.body ?? []).operation) == IppCodec.identifyPrinter
                ? HttpResponse(status: 200, headers: ["Content-Type": "application/ipp"], body: IppCodec.encodeResponse(status: status, requestId: 1, []))
                : nil
        }, inner: Printers.folder("inkjet-demo")))
        let conn = try await PrinterConnection.open(Self.inkjetHost, transport: recorder)
        let client = MaintenanceClient(conn)
        let identify = try #require(try await client.detect().actions.first)

        let result = try await client.run(identify)

        #expect(!result.ok)
        #expect(result.message.contains(says))
    }

    @Test func detectionSurvivesAPrinterThatAnswersGarbage() async throws {
        let printer = Network(Responder(respond: { r in
            switch r.url.path {
            case DiscoveryTree.path: return Self.xml(Self.treeWithMaintenance)
            case "/DevMgmt/InternalPrintManifest.xml": return Self.xml("<not xml")
            case MaintenanceRequests.internalPrintCapPath: return HttpResponse(status: 500)
            case "/DevMgmt/ConsumableConfigDyn.xml": return Self.xml("<also not xml")
            case "/DevMgmt/ProductStatusDyn.xml": return Self.xml(Self.m234dwStatus)
            default: return nil
            }
        }))
        let conn = try await PrinterConnection.open(Self.host, transport: printer)

        let options = try await MaintenanceClient(conn).detect()

        #expect(options.actions.isEmpty)
    }

    // MARK: Demo printers (FixtureTransport)

    @Test func theFixtureServerAnswersIdentifyPrinterOnlyForPrintersThatListIt() async throws {
        let inkjet = Printers.folder("inkjet-demo")
        let laser = FixtureTransport(document: { $0 == "ipp_print.ipp.txt" ? Array("printer-state enum 3".utf8) : nil })
        for (transport, expected) in [(inkjet, UInt16(0)), (laser, 0x0501)] {
            let request = HttpRequest("POST", URL(string: "http://\(Self.inkjetHost):631/ipp/print")!, headers: ["Content-Type": "application/ipp"],
                                      body: IppCodec.encodeIdentifyPrinter("ipp://\(Self.inkjetHost):631/ipp/print", userName: nil, actions: ["flash"]))
            let response = try await transport.send(request)
            #expect(try IppCodec.decode(response.body).statusCode == expected)
        }
    }

    @Test func theFixtureServerAcceptsAnLedmMaintenancePost() async throws {
        let request = HttpRequest("POST", URL(string: "https://\(Self.host)/DevMgmt/InternalPrintDyn.xml")!, headers: ["Content-Type": "text/xml; charset=utf-8"],
                                  body: Array(try MaintenanceRequests.internalPrint("configurationPage").utf8))
        #expect(try await Printers.folder("m234dw").send(request).status == 201)
    }
}
