import Foundation
import Testing
@testable import PrintCore

/// HP LEDM web firmware update settings, and the firmware version from LEDM. Ported from FirmwareTests.cs. Adapted:
/// - The .NET tests edit the parsed fixture (LINQ to XML); `XmlElement` is read-only, so these edit the fixture's text in
///   memory before parsing it (`dyn(check:update:)`, `cap(_:)`). The files are never changed.
/// - `Assert.Same(s, s.WithoutNotify())` (the same object) is equality: the settings are a value type.
/// - Manifest_nested_twenty_thousand_deep: `DeviceXml` refuses a document nested deeper than 64 levels before the manifest
///   walk sees it, so the 20,000-deep reply is an `XmlFormatError` (not a stack overflow), and the walk is checked on a
///   manifest as deep as `DeviceXml` lets through.
struct FirmwareTests {
    private static let fwu = "http://www.hp.com/schemas/imaging/con/ledm/firmwareupdatedyn/2010/12/12"

    private static func xml(_ name: String) throws -> XmlElement { try DeviceXml.load(Fixtures.data("m234dw/\(name)")) }

    /// The M234dw's FirmwareUpdateDyn with its two switches set (the fixture has both disabled).
    private static func dyn(check: String = "disabled", update: String = "disabled") throws -> XmlElement {
        let text = try Fixtures.text("m234dw/FirmwareUpdate_FirmwareUpdateDyn.xml")
            .replacingOccurrences(of: "<fwudyn:AutomaticCheck>disabled<", with: "<fwudyn:AutomaticCheck>\(check)<")
            .replacingOccurrences(of: "<fwudyn:AutomaticUpdate>disabled<", with: "<fwudyn:AutomaticUpdate>\(update)<")
        return try DeviceXml.load(text)
    }

    /// The M234dw's FirmwareUpdateCap, edited in memory.
    private static func cap(_ edit: (String) -> String = { $0 }) throws -> XmlElement {
        try DeviceXml.load(edit(Fixtures.text("m234dw/FirmwareUpdate_FirmwareUpdateCap.xml")))
    }

    private static func withoutCheckSupport(_ text: String) -> String {
        text.replacingOccurrences(of: #"<fwucap:AutomaticCheckSupport[\s\S]*?</fwucap:AutomaticCheckSupport>"#, with: "", options: .regularExpression)
    }

    private static func captured() throws -> FirmwareUpdateSettings {
        try #require(FirmwareUpdateSettings.parse(xml("FirmwareUpdate_FirmwareUpdateDyn.xml"), cap: xml("FirmwareUpdate_FirmwareUpdateCap.xml"),
                                                  configPath: "/FirmwareUpdate/WebFWUpdate/Config"))
    }

    @Test func manifestPathsNestBelowTheRootLink() throws {
        let map = LedmManifest.parse(try Self.xml("FirmwareUpdate_FirmwareUpdateManifest.xml"))

        #expect(map["FirmwareUpdateDyn"] == "/FirmwareUpdate/FirmwareUpdateDyn.xml")
        #expect(map["FirmwareUpdateCap"] == "/FirmwareUpdate/FirmwareUpdateCap.xml")
        #expect(map["FirmwareUpdate"] == "/FirmwareUpdate/WebFWUpdate")
        #expect(map["FirmwareUpdateConfig"] == "/FirmwareUpdate/WebFWUpdate/Config")
        #expect(map["FirmwareUpdateState"] == "/FirmwareUpdate/WebFWUpdate/State")
    }

    @Test func treePointsToTheFirmwareManifest() throws {
        let tree = DiscoveryTree.parse(try Self.xml("DevMgmt_DiscoveryTree.xml"))

        #expect(tree.manifest(for: LedmResource.firmwareUpdateManifest) == "/FirmwareUpdate/FirmwareUpdateManifest.xml")
    }

    @Test func readsTheM234dwAutoUpdateSettings() throws {
        let s = try Self.captured()

        #expect(s.mode == .off)
        #expect(s.choices == [.automatic, .notify, .off])
        #expect(s.canChange)
        #expect(s.checkWritable)
        #expect(s.status == "idle")
        #expect(s.statusMessage == nil)
    }

    @Test(arguments: [
        ("enabled", "enabled", FirmwareUpdateMode.automatic),
        ("enabled", "disabled", .notify),
        ("disabled", "disabled", .off),
        ("disabled", "enabled", .automatic), // installs whatever it's told about: treat as automatic
    ] as [(String, String, FirmwareUpdateMode)])
    func modeFromTheTwoSwitches(_ check: String, _ update: String, _ expected: FirmwareUpdateMode) throws {
        let dyn = try Self.dyn(check: check, update: update)

        #expect(FirmwareUpdateSettings.parse(dyn, cap: try Self.cap(), configPath: "/c")?.mode == expected)
    }

    @Test func readOnlyCapOffersNoChoices() throws {
        let cap = try Self.cap {
            $0.replacingOccurrences(of: #"<fwucap:AutomaticUpdateSupport access="readWrite">"#, with: #"<fwucap:AutomaticUpdateSupport access="readOnly">"#)
        }

        let s = try #require(FirmwareUpdateSettings.parse(try Self.dyn(), cap: cap, configPath: "/c"))

        #expect(s.choices.isEmpty)
        #expect(!s.canChange)
    }

    @Test func checkSwitchAloneIsNotEnoughForNotify() throws {
        let cap = try Self.cap(Self.withoutCheckSupport)

        let s = try #require(FirmwareUpdateSettings.parse(try Self.dyn(), cap: cap, configPath: "/c"))

        #expect(s.choices == [.automatic, .off])
    }

    @Test func noFirmwareUpdateSettingsWithoutAConfig() throws {
        let dyn = try DeviceXml.load(#"<d:FirmwareUpdateDyn xmlns:d="urn:x"><d:FirmwareUpdate><d:Class>WebFWUpdate</d:Class></d:FirmwareUpdate></d:FirmwareUpdateDyn>"#)

        #expect(FirmwareUpdateSettings.parse(dyn, cap: nil, configPath: "/c") == nil)
    }

    @Test(arguments: [
        (FirmwareUpdateMode.automatic, "enabled", "enabled"),
        (.notify, "enabled", "disabled"),
        (.off, "disabled", "disabled"),
    ] as [(FirmwareUpdateMode, String, String)])
    func buildPutWritesBothSwitchesInTheDeviceNamespace(_ mode: FirmwareUpdateMode, _ check: String, _ update: String) throws {
        let body = try DeviceXml.load(try Self.captured().buildPut(mode))

        #expect(body.name == "FirmwareUpdateConfig" && body.namespace == Self.fwu)
        #expect(body.children.map(\.name) == ["AutomaticCheck", "AutomaticUpdate"])
        #expect(body.children.allSatisfy { $0.namespace == Self.fwu })
        #expect(body.kid("AutomaticCheck")?.value == check)
        #expect(body.kid("AutomaticUpdate")?.value == update)
        #expect(body.prefix == "fwudyn")
    }

    @Test func buildPutLeavesOutAReadOnlyCheckSwitch() throws {
        let cap = try Self.cap {
            $0.replacingOccurrences(of: #"<fwucap:AutomaticCheckSupport access="readWrite">"#, with: #"<fwucap:AutomaticCheckSupport access="readOnly">"#)
        }

        let s = try #require(FirmwareUpdateSettings.parse(try Self.dyn(), cap: cap, configPath: "/c"))

        #expect(!s.checkWritable)
        #expect(s.choices == [.automatic, .off])
        #expect(try DeviceXml.load(s.buildPut(.automatic)).children.map(\.name) == ["AutomaticUpdate"])
    }

    @Test func withoutNotifyKeepsTheOtherChoices() throws {
        let s = try Self.captured().withoutNotify()

        #expect(s.choices == [.automatic, .off])
        #expect(s.canChange)
        #expect(s.withoutNotify() == s)
    }

    @Test(arguments: [
        ("HP LaserJet MFP M234dw", true),
        ("HP LaserJet MFP M232-M237", true),
        ("HP LaserJet MFP M237sdwe", true),
        ("HP LaserJet MFP M140we", false),
        ("HP LaserJet Pro MFP M227fdw", false),
        ("HP OfficeJet Pro 9010", false),
        (nil, false),
    ] as [(String?, Bool)])
    func knownModelsThatDoNotKeepNotify(_ model: String?, _ expected: Bool) {
        #expect(FirmwareUpdateSettings.knownNotToKeepNotify(model) == expected)
    }

    @Test(arguments: [
        (FirmwareUpdateMode.notify, FirmwareUpdateMode.notify, FirmwareUpdateWriteResult.kept),
        (.off, .off, .kept),
        (.notify, .automatic, .notifyInstalls), // the M234dw
        (.notify, .off, .other),
        (.off, .automatic, .other),
    ] as [(FirmwareUpdateMode, FirmwareUpdateMode, FirmwareUpdateWriteResult)])
    func judgesTheReadBack(_ chosen: FirmwareUpdateMode, _ readBack: FirmwareUpdateMode, _ expected: FirmwareUpdateWriteResult) {
        #expect(FirmwareUpdateSettings.judge(chosen, readBack) == expected)
    }

    @Test func m234dwReadBackAfterNotifyIsAutomatic() throws {
        // What the M234dw stores after AutomaticCheck=enabled is written (with or without AutomaticUpdate=disabled).
        let readBack = try #require(FirmwareUpdateSettings.parse(try Self.dyn(check: "enabled", update: "enabled"), cap: try Self.cap(), configPath: "/c"))

        #expect(FirmwareUpdateSettings.judge(.notify, readBack.mode) == .notifyInstalls)
    }

    @Test func configPathIsTheWebUpdateClassesOne() throws {
        // Another update class's Config listed first must not win (parse keeps the first of each type).
        let doc = try DeviceXml.load("""
            <man:Manifest xmlns:man="urn:man" xmlns:map="urn:map" xmlns:dd="urn:dd" xmlns:f="urn:f"><map:ResourceMap>
              <map:ResourceLink><dd:ResourceURI>/FirmwareUpdate</dd:ResourceURI></map:ResourceLink>
              <map:ResourceNode><map:ResourceLink><dd:ResourceURI>/USBFWUpdate</dd:ResourceURI></map:ResourceLink>
                <map:ResourceType><f:T>FirmwareUpdate</f:T></map:ResourceType>
                <map:ResourceMap><map:ResourceNode><map:ResourceLink><dd:ResourceURI>/Config</dd:ResourceURI></map:ResourceLink>
                  <map:ResourceType><f:T>FirmwareUpdateConfig</f:T></map:ResourceType></map:ResourceNode></map:ResourceMap></map:ResourceNode>
              <map:ResourceNode><map:ResourceLink><dd:ResourceURI>/WebFWUpdate</dd:ResourceURI></map:ResourceLink>
                <map:ResourceType><f:T>FirmwareUpdate</f:T></map:ResourceType>
                <map:ResourceMap><map:ResourceNode><map:ResourceLink><dd:ResourceURI>/Config</dd:ResourceURI></map:ResourceLink>
                  <map:ResourceType><f:T>FirmwareUpdateConfig</f:T></map:ResourceType></map:ResourceNode></map:ResourceMap></map:ResourceNode>
            </map:ResourceMap></man:Manifest>
            """)

        #expect(LedmManifest.parse(doc)["FirmwareUpdateConfig"] == "/FirmwareUpdate/USBFWUpdate/Config")
        #expect(FirmwareUpdateSettings.configPath(in: LedmManifest.entries(doc)) == "/FirmwareUpdate/WebFWUpdate/Config")
        #expect(FirmwareUpdateSettings.configPath(in: [("FirmwareUpdateConfig", "/x/Config")]) == "/x/Config") // no web class: the only one
        #expect(FirmwareUpdateSettings.configPath(in: []) == nil)
    }

    private static func nestedManifest(_ depth: Int) -> String {
        "<Manifest><ResourceMap><ResourceLink><ResourceURI>/Base</ResourceURI></ResourceLink>"
            + String(repeating: "<ResourceNode><ResourceLink><ResourceURI>/a</ResourceURI></ResourceLink><ResourceType><T>Level</T></ResourceType><ResourceMap>",
                     count: depth)
            + String(repeating: "</ResourceMap></ResourceNode>", count: depth)
            + "</ResourceMap></Manifest>"
    }

    @Test func manifestNestedTwentyThousandDeepIsCutOffNotAStackOverflow() throws {
        // A reply arrives over plain HTTP before the device is identified: one recursion per nested map would let it end the process.
        #expect(throws: XmlFormatError.self) { try DeviceXml.load(Self.nestedManifest(20_000)) }

        // As deep as DeviceXml lets through (64 elements: two per level, and the leaves' three).
        let depth = (DeviceXml.maxDepth - 4) / 2
        let entries = LedmManifest.entries(try DeviceXml.load(Self.nestedManifest(depth)))
        #expect((16...64).contains(entries.count)) // the levels a real manifest uses (three or four), and no further
        #expect(entries[0] == ("Level", "/Base/a"))
        #expect(entries[1] == ("Level", "/Base/a/a"))
    }

    @Test(arguments: [
        ("available", "A firmware update is available."),
        ("downloading", "Downloading an update…"),
        ("checkFailed", "The printer's last update check failed."),
    ])
    func statusWords(_ status: String, _ expected: String) throws {
        var s = try Self.captured()
        s.status = status
        #expect(s.statusMessage == expected)
    }

    @Test func clientFindsTheSettingsThroughTheManifest() async throws {
        let client = LedmClient(DeviceHttp(host: FixtureTransport.demoHost, transport: Printers.folder("m234dw")))

        let s = try #require(try await client.firmwareUpdate())

        #expect(s.configPath == "/FirmwareUpdate/WebFWUpdate/Config")
        #expect(s.mode == .off)
    }

    // Not in FirmwareTests.cs (the Windows app's view model sends it): the mode goes to the manifest's Config over HTTPS.
    @Test func clientWritesTheModeToTheConfigOverHttps() async throws {
        let network = Network(Printers.folder("m234dw"))
        let client = LedmClient(DeviceHttp(host: FixtureTransport.demoHost, transport: network))
        let s = try #require(try await client.firmwareUpdate())
        network.clear()

        try await client.setFirmwareUpdate(.automatic, in: s)

        let put = try #require(network.seen.first)
        #expect(network.seen.count == 1 && put.method == "PUT")
        #expect(put.url.absoluteString == "https://192.0.2.10/FirmwareUpdate/WebFWUpdate/Config")
        #expect(try DeviceXml.load(put.body ?? []).kid("AutomaticUpdate")?.value == "enabled")
    }

    @Test func firmwareFromLedmIsTheReleaseDate() throws {
        var product = LedmParsers.parseProductConfig(try Self.xml("DevMgmt_ProductConfigDyn.xml"))

        let fw = try #require(FirmwareInfo.from(product, nil))

        #expect(fw.version == nil && fw.date == "2024-08-13")
        #expect(fw.display == "2024-08-13")
        product.firmwareRevision = "SAYPRO1N001.2045A"
        #expect(FirmwareInfo.from(product, nil)?.display == "SAYPRO1N001.2045A (2024-08-13)")
        #expect(FirmwareInfo.from(nil, nil) == nil)
    }
}
