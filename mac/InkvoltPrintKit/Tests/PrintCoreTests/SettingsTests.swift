import Testing
@testable import PrintCore

/// Device settings over LEDM: the catalog read from the M234dw's documents and the PUT bodies. Ported from SettingsTests.cs
/// (all of it). The PUT bodies are read back with `DeviceXml` (namespace and prefix per element) instead of LINQ to XML.
struct SettingsTests {
    private static func xml(_ name: String) throws -> XmlElement { try DeviceXml.load(Fixtures.data("m234dw/\(name)")) }

    private static func readAll() throws -> [LedmSetting] {
        try LedmSettingCatalog.read(LedmSettingCatalog.all, dyn: xml("DevMgmt_ProductConfigDyn.xml"), cap: xml("DevMgmt_ProductConfigCap.xml"))
            + LedmSettingCatalog.read(LedmSettingCatalog.all, dyn: xml("DevMgmt_PrintConfigDyn.xml"), cap: xml("DevMgmt_PrintConfigCap.xml"))
            + LedmSettingCatalog.read(LedmSettingCatalog.all, dyn: xml("DevMgmt_MediaHandlingDyn.xml"), cap: xml("DevMgmt_MediaHandlingCap.xml"))
    }

    private static func def(_ key: String) throws -> LedmSettingDef { try #require(LedmSettingCatalog.all.first { $0.key == key }) }

    @Test func readsEveryCatalogSettingFromTheM234dw() throws {
        let list = try Self.readAll()
        let settings = Dictionary(uniqueKeysWithValues: list.map { ($0.def.key, $0) })

        #expect(LedmSettingCatalog.all.map(\.key).sorted() == settings.keys.sorted())
        #expect(settings["PowerSaveTimeout"]?.value == "1minute")
        #expect(settings["PowerSaveTimeout"]?.choices == ["1minute", "5minutes", "15minutes", "30minutes", "1hour"])
        #expect(settings["ShutDownDelay"]?.value == "15_minutes")
        #expect(settings["FriendlyName"]?.maxLength == 32)
        #expect(settings["DefaultPrintCopies"]?.min == 1 && settings["DefaultPrintCopies"]?.max == 999)
        #expect(settings["MediaSizeName"]?.value == "any")
        #expect(settings["MediaSizeName"]?.choices.contains("iso_a4_210x297mm") == true)
    }

    @Test func readSkipsSettingsTheCapMarksReadOnly() throws {
        let cap = try DeviceXml.load("""
            <c xmlns:dd="urn:dd"><PowerSaveTimerSupport access="readOnly"><dd:PowerSaveTimeout>1minute</dd:PowerSaveTimeout></PowerSaveTimerSupport></c>
            """)
        let dyn = try Self.xml("DevMgmt_ProductConfigDyn.xml")

        #expect(!LedmSettingCatalog.read(LedmSettingCatalog.all, dyn: dyn, cap: cap).contains { $0.def.key == "PowerSaveTimeout" })
    }

    @Test func buildPutContainsOnlyChangedLeavesWithDeviceNamespaces() throws {
        let dyn = try Self.xml("DevMgmt_ProductConfigDyn.xml")
        let timeoutDef = try Self.def("PowerSaveTimeout"), locationDef = try Self.def("DeviceLocation")

        let body = try DeviceXml.load(LedmSettingCatalog.buildPut(dyn, [(timeoutDef, "15minutes"), (locationDef, "Office")]))

        let dd = "http://www.hp.com/schemas/imaging/con/dictionaries/1.0/"
        let v2 = "http://www.hp.com/schemas/imaging/con/ledm/productconfigdyn/2009/03/16"
        let v1 = "http://www.hp.com/schemas/imaging/con/ledm/productconfigdyn/2007/11/05"
        try #require(body.children.count == 1)
        let settings = body.children[0]
        #expect(body.name == "ProductConfigDyn" && body.namespace == v2)
        #expect(settings.name == "ProductSettings" && settings.namespace == v2)
        let timeout = try #require(settings.kid("PowerSaveTimeout"))
        #expect(timeout.namespace == dd && timeout.value == "15minutes")
        let info = try #require(settings.kid("DeviceInformation"))
        #expect(info.namespace == v1)
        let location = try #require(info.kid("DeviceLocation"))
        #expect(location.namespace == dd && location.value == "Office")
        #expect(settings.children.count == 2)
    }

    @Test func buildPutIncludesTrayKey() throws {
        let dyn = try Self.xml("DevMgmt_MediaHandlingDyn.xml")
        let def = try Self.def("MediaSizeName")

        let body = try DeviceXml.load(LedmSettingCatalog.buildPut(dyn, [(def, "iso_a4_210x297mm")]))
        try #require(body.children.count == 1)
        let tray = body.children[0]

        #expect(tray.children.map(\.name) == ["InputBin", "MediaSizeName"])
        #expect(tray.children.first?.value == "Tray1")
    }

    // Not in SettingsTests.cs (the Windows app's view model does this part): the client reads the catalog and writes one PUT
    // per resource over HTTPS, and a 401 asks for the admin password.
    @Test func clientReadsTheSettingsAndSavesEachResourceOverHttps() async throws {
        let network = Network(Printers.folder("m234dw"))
        let client = LedmClient(DeviceHttp(host: FixtureTransport.demoHost, transport: network))
        let settings = try await client.settings()
        #expect(settings.items.count == LedmSettingCatalog.all.count)
        network.clear()
        let timeout = try Self.def("PowerSaveTimeout"), size = try Self.def("MediaSizeName")

        try await client.save([(timeout, "15minutes"), (size, "iso_a4_210x297mm")], over: settings)

        let puts = network.seen.filter { $0.method == "PUT" }
        #expect(puts.map(\.url.absoluteString) == ["https://192.0.2.10/DevMgmt/ProductConfigDyn.xml", "https://192.0.2.10/DevMgmt/MediaHandlingDyn.xml"])
        #expect(puts.allSatisfy { $0.header("Content-Type")?.hasPrefix("text/xml") == true && $0.header("Authorization") == nil })

        network.fault = { $0.method == "PUT" ? Network.status(401) : nil }
        network.fail = true
        await #expect(throws: LedmAuthRequiredError(credentialsWereSent: false)) {
            try await client.save([(timeout, "5minutes")], over: settings)
        }
        client.http.setCredentials(user: "admin", password: "test-only")
        await #expect(throws: LedmAuthRequiredError(credentialsWereSent: true)) {
            try await client.save([(timeout, "5minutes")], over: settings)
        }
        #expect(network.seen.last?.header("Authorization")?.hasPrefix("Basic ") == true)
    }

    @Test(arguments: [
        ("PowerSaveTimeout", "1minute", "1 minute"),
        ("ShutDownDelay", "15_minutes", "15 minutes"),
        ("ShutDownDelay", "2hours", "2 hours"),
        ("Duplex", "enabled", "On"),
        ("MediaSizeName", "na_letter_8.5x11in", "Letter (8.5x11in)"),
        ("MediaSizeName", "iso_a4_210x297mm", "A4 (210x297mm)"),
        ("MediaType", "extraHeavy", "Extra heavy"),
    ] as [(String, String, String)])
    func displayText(_ key: String, _ value: String, _ expected: String) {
        #expect(SettingText.display(key, value) == expected)
    }
}
