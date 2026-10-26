import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// eSCL: capabilities, status, scan settings, quirks, scan jobs, and the JPEG height fix. Ported from EsclTests.cs and the
/// eSCL parts of OtherBrandsTests.cs and RobustnessTests.cs.
struct EsclTests {
    private static func m234dw() throws -> ScannerCapabilities { ScannerCapabilities.parse(try DeviceXml.load(Fixtures.data("m234dw/eSCL_ScannerCapabilities.xml"))) }
    private static func inkjet() throws -> ScannerCapabilities {
        ScannerCapabilities.parse(try DeviceXml.load(Fixtures.data("inkjet-demo/eSCL_ScannerCapabilities.xml")))
    }

    private static func caps(_ inner: String) throws -> ScannerCapabilities {
        ScannerCapabilities.parse(try DeviceXml.load("""
            <scan:ScannerCapabilities xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:Version>2.6</pwg:Version>\(inner)
            </scan:ScannerCapabilities>
            """))
    }

    private static func settings(_ request: ScanRequest, _ caps: ScannerCapabilities) throws -> XmlElement {
        try DeviceXml.load(try #require(EsclXml.buildScanSettings(request, caps)))
    }

    @Test func capabilitiesPlatenOnly() throws {
        let c = try Self.m234dw()
        #expect(c.version == "2.63")
        #expect(c.uuid == "12345678-1234-4abc-8def-123456789abc")
        #expect(c.sources == [.platen])
        #expect(c.platen?.resolutions == [200, 300, 600])
        #expect(c.platen?.colorModes == ["RGB24", "Grayscale8"])
        #expect(c.platen?.maxWidth == 2550 && c.platen?.maxHeight == 3508)
    }

    @Test func status() throws {
        let s = ScannerStatus.parse(try DeviceXml.load(Fixtures.data("m234dw/eSCL_ScannerStatus.xml")))
        #expect(s.isIdle)
        #expect(s.adfState == nil)
    }

    @Test func scanSettingsSnapsResolutionAndClampsRegion() throws {
        let s = try Self.settings(ScanRequest(color: .grayscale, resolution: 250, width: 9999), Self.m234dw())
        #expect(s.name == "ScanSettings")
        #expect(s.kidValue("XResolution") == "200")
        #expect(s.kidValue("ColorMode") == "Grayscale8")
        #expect(s.kidValue("InputSource") == "Platen")
        let region = try #require(s.kid("ScanRegions")?.kid("ScanRegion"))
        #expect(region.kidValue("Width") == "2550")
        #expect(region.kidValue("Height") == "3508")
    }

    @Test func scanSettingsRejectsMissingSource() throws {
        #expect(EsclXml.buildScanSettings(ScanRequest(source: .adf), try Self.m234dw()) == nil)
    }

    @Test func jpegFixCopiesDnlHeightIntoSof() {
        let jpeg = TestJpeg.build(width: 100, height: 0, dnlHeight: 1234)
        let fixed = JpegFix.patchZeroHeight(jpeg)
        let at = JpegFix.findSofHeightOffset(fixed)
        #expect(Int(fixed[at]) << 8 | Int(fixed[at + 1]) == 1234)
        #expect(Int(jpeg[at]) << 8 | Int(jpeg[at + 1]) == 0) // input untouched
    }

    @Test func jpegFixLeavesNormalJpegAlone() {
        let jpeg = TestJpeg.build(width: 100, height: 50, dnlHeight: nil)
        #expect(JpegFix.patchZeroHeight(jpeg) == jpeg)
    }

    @Test func truncatedJpegHeaderIsNotFoundInsteadOfCrashing() throws {
        let jpeg = TestJpeg.build(width: 100, height: 50, dnlHeight: nil)
        let sof = try #require(jpeg.indices.dropFirst(2).first { jpeg[$0] == 0xC0 }) - 1
        #expect(JpegFix.findSofHeightOffset(Array(jpeg[..<(sof + 7)])) == -1) // SOF marker present, size fields cut off
    }

    @Test func zeroHeightPageWithoutDnlIsLeftAsItIs() {
        let jpeg = TestJpeg.build(width: 100, height: 0, dnlHeight: nil)
        #expect(JpegFix.patchZeroHeight(jpeg) == jpeg)
    }

    @Test func scannerStatusListsJobs() throws {
        let s = ScannerStatus.parse(try DeviceXml.load("""
            <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:State>Processing</pwg:State>
              <scan:Jobs>
                <scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/abc</pwg:JobUri><pwg:JobState>Processing</pwg:JobState><scan:Age>3</scan:Age></scan:JobInfo>
                <scan:JobInfo><pwg:JobUri>/eSCL/ScanJobs/old</pwg:JobUri><pwg:JobState>Completed</pwg:JobState><scan:Age>300</scan:Age></scan:JobInfo>
              </scan:Jobs>
            </scan:ScannerStatus>
            """))
        #expect(s.jobs == [ScanJobInfo(uri: "/eSCL/ScanJobs/abc", state: "Processing", ageSeconds: 3),
                           ScanJobInfo(uri: "/eSCL/ScanJobs/old", state: "Completed", ageSeconds: 300)])
    }

    // MARK: Other brands

    @Test func feederProfileReferenceAndResolutionRangeAreResolved() throws {
        let c = try Self.inkjet()
        #expect(c.manufacturer == "EPSON")
        #expect(c.platen?.resolutions == [100, 200, 300, 600, 1200])
        #expect(c.adf?.resolutions == [75, 100, 150, 200, 300, 400, 600]) // 75-600 step 25: the usual values in it
        #expect(c.adf?.colorModes == ["BlackAndWhite1", "Grayscale8", "RGB24"]) // from the named profile
        #expect(c.adf?.documentFormats.contains("image/jpeg") == true)
        #expect(c.adfDuplex)
        #expect(c.adf?.hasDocumentFormatExt == true)
    }

    @Test(arguments: [
        (100, 300, 0, 300, [100, 150, 200, 300]),
        (75, 1200, 1, 300, [75, 100, 150, 200, 300, 400, 600, 1200]),
        (150, 600, 150, 300, [150, 300, 600]), // only usual values the step reaches
        (110, 130, 7, 117, [110, 117, 124]), // nothing usual fits: the step values
        (101, 999, 1, 333, [150, 200, 300, 400, 600]),
        (101, 199, 3, 150, [101, 104, 107, 110, 113, 116, 119, 122]), // many step values: the first eight
    ] as [(Int, Int, Int, Int, [Int])])
    func resolutionRanges(_ min: Int, _ max: Int, _ step: Int, _ normal: Int, _ expected: [Int]) {
        #expect(ScannerCapabilities.rangeResolutions(min: min, max: max, step: step, normal: normal) == expected)
    }

    @Test func discreteResolutionsWithUnequalXAndYAreLeftOut() throws {
        let c = try Self.caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
              <scan:ColorModes><scan:ColorMode>RGB24</scan:ColorMode></scan:ColorModes>
              <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
              <scan:SupportedResolutions><scan:DiscreteResolutions>
                <scan:DiscreteResolution><scan:XResolution>300</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
                <scan:DiscreteResolution><scan:XResolution>600</scan:XResolution><scan:YResolution>300</scan:YResolution></scan:DiscreteResolution>
              </scan:DiscreteResolutions></scan:SupportedResolutions>
            </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """)
        #expect(c.platen?.resolutions == [300])
        #expect(c.platen?.hasDocumentFormatExt == false) // only pwg:DocumentFormat listed
    }

    @Test func unknownProfileReferenceIsIgnoredNotFatal() throws {
        let c = try Self.caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile ref="missing" /></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """)
        #expect(c.platen?.resolutions == [])
    }

    @Test func scanSettingsLeaveOutDocumentFormatExtWhenTheScannerNeverListsIt() throws {
        let c = try Self.caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
              <scan:DocumentFormats><pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat></scan:DocumentFormats>
            </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """)
        let s = try Self.settings(ScanRequest(), c)
        #expect(s.kid("DocumentFormat") != nil)
        #expect(s.kid("DocumentFormatExt") == nil)
    }

    @Test func scanSettingsForTheTwoSidedFeederWithAnIntentTheFeederLacks() throws {
        let s = try Self.settings(ScanRequest(source: .adfDuplex, resolution: 300), Self.inkjet())
        #expect(s.kidValue("InputSource") == "Feeder")
        #expect(s.kidValue("Duplex") == "true")
        #expect(s.kidValue("Intent") == "TextAndGraphic") // "Document" isn't offered by this feeder
        #expect(s.kidValue("XResolution") == "300")
        #expect(s.kid("ScanRegions")?.children.first?.kidValue("Height") == "4200")
    }

    @Test func jpegIsRequired() throws {
        let c = try Self.caps("""
            <scan:Platen><scan:PlatenInputCaps><scan:SettingProfiles><scan:SettingProfile>
              <scan:DocumentFormats><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat></scan:DocumentFormats>
            </scan:SettingProfile></scan:SettingProfiles></scan:PlatenInputCaps></scan:Platen>
            """)
        #expect(c.platen?.offersJpeg == false)
        #expect(try Self.inkjet().platen?.offersJpeg == true)
    }

    @Test(arguments: [
        ("EPSON ET-0000 Series", nil, true, false),
        ("Example", "EPSON", true, false),
        ("Brother Example-0000", nil, false, true),
        ("Canon Example", "Canon", false, false),
        ("HP LaserJet MFP M234dw", "HP", false, false),
    ] as [(String, String?, Bool, Bool)])
    func scannerQuirks(_ model: String, _ manufacturer: String?, _ portInHost: Bool, _ nextLoadDelay: Bool) {
        let q = EsclQuirks.of(ScannerCapabilities(version: "2.6", makeAndModel: model, uuid: nil, platen: nil, adf: nil, adfDuplex: false,
                                                  manufacturer: manufacturer))
        #expect(q.portInHost == portInHost && q.nextLoadDelay == nextLoadDelay)
    }

    @Test(arguments: [(500, 250), (5000, 1000), (0, 0)] as [(Int, Int)])
    func brotherFeederWaitsBeforeTheNextPage(_ lastLoadMs: Int, _ waitMs: Int) {
        #expect(EsclQuirks.nextLoadWait(.milliseconds(lastLoadMs)) == .milliseconds(waitMs))
    }

    @Test(arguments: [
        ("Idle", "ScannerAdfLoaded", true, nil),
        ("Idle", "ScannerAdfEmpty", true, "Load the pages into the document feeder first."),
        ("Idle", "ScannerAdfJam", true, "The document feeder is jammed. Clear the paper and try again."),
        ("Idle", "ScannerAdfDoorOpen", true, "The document feeder's cover is open. Close it and try again."),
        ("Idle", "ScannerAdfHatchOpen", true, "The document feeder's cover is open. Close it and try again."),
        ("Idle", "ScannerAdfMispick", true, "The document feeder couldn't pick up a page. Straighten the stack and try again."),
        ("Idle", "ScannerAdfJam", false, nil), // glass scans ignore the feeder
        ("Idle", nil, true, nil), // no feeder state reported: just try
        ("Testing", nil, false, nil), // warming up: the job request waits for it
        ("Processing", nil, false, nil),
        ("Stopped", nil, false, "Scanner is stopped."),
        ("Down", nil, false, "Scanner is down."),
    ] as [(String, String?, Bool, String?)])
    func scannerStatusProblems(_ state: String, _ adf: String?, _ feeder: Bool, _ problem: String?) throws {
        let xml = """
            <scan:ScannerStatus xmlns:scan="http://schemas.hp.com/imaging/escl/2011/05/03" xmlns:pwg="http://www.pwg.org/schemas/2010/12/sm">
              <pwg:State>\(state)</pwg:State>\(adf.map { "<scan:AdfState>\($0)</scan:AdfState>" } ?? "")
            </scan:ScannerStatus>
            """
        #expect(ScannerStatus.parse(try DeviceXml.load(xml)).problem(feeder: feeder) == problem)
    }

    @Test func epsonScannerGetsThePortInTheHostHeader() async throws {
        let hosts = Mutex<[String?]>([])
        let inner = Printers.inkjet()
        let spy = CdmConnectionTests.Scripted { request in
            hosts.withLock { $0.append(request.header("Host")) }
            return try await inner.send(request)
        }
        let http = DeviceHttp(host: "192.0.2.11", transport: spy)
        let client = EsclClient(http, root: http.http("/eSCL/"))

        for try await _ in client.scan(ScanRequest()) {}

        let seen = hosts.withLock { $0 }
        #expect(seen.first == .some(nil)) // ScannerCapabilities: the scanner isn't known to be an Epson yet
        #expect(seen.count > 3)
        #expect(seen.dropFirst().allSatisfy { $0 == "192.0.2.11:80" })
    }
}
