import Foundation
import Testing
@testable import PrintCore

/// HP LEDM documents against the M234dw fixtures, and the hardened XML reader. Ported from LedmTests.cs.
struct LedmTests {
    private static func xml(_ name: String) throws -> XmlElement { try DeviceXml.load(Fixtures.data("m234dw/\(name)")) }

    @Test func discoveryTreeMapsResourceTypesAndInterfaces() throws {
        let tree = DiscoveryTree.parse(try Self.xml("DevMgmt_DiscoveryTree.xml"))
        #expect(tree.uri(for: LedmResource.productStatusDyn) == "/DevMgmt/ProductStatusDyn.xml")
        #expect(tree.uri(for: LedmResource.eventTable) == "/EventMgmt/EventTable.xml")
        #expect(tree.uri(for: "pwg:hpIPPPrint") == "/ipp/print")
        #expect(tree.hasCdm && tree.hasEscl && tree.hasEvents)
    }

    @Test func statusSleepingPrinterIsReady() throws {
        let s = LedmParsers.parseStatus(try Self.xml("DevMgmt_ProductStatusDyn.xml"))
        #expect(s.code == "inPowerSave")
        #expect(s.message == "Ready")
        #expect(s.detail?.hasPrefix("Sleeping to save power") == true)
        #expect(s.severity == .info)
        #expect(s.alerts.isEmpty)
    }

    @Test func statusWithAlertsTakesWorstSeverity() throws {
        let doc = try DeviceXml.load("""
            <psdyn:ProductStatusDyn xmlns:psdyn="urn:psdyn" xmlns:pscat="urn:pscat" xmlns:ad="urn:ad" xmlns:dd="urn:dd">
              <psdyn:Status><pscat:StatusCategory>jamInPrinter</pscat:StatusCategory></psdyn:Status>
              <psdyn:AlertTable>
                <psdyn:Alert><ad:ProductStatusAlertID>cartridgeLow</ad:ProductStatusAlertID><dd:Severity>Warning</dd:Severity>
                  <ad:AlertDetails><ad:AlertDetailsMarkerColor>Black</ad:AlertDetailsMarkerColor></ad:AlertDetails></psdyn:Alert>
                <psdyn:Alert><ad:ProductStatusAlertID>jamInPrinter</ad:ProductStatusAlertID><dd:Severity>Error</dd:Severity></psdyn:Alert>
              </psdyn:AlertTable>
            </psdyn:ProductStatusDyn>
            """)
        let s = LedmParsers.parseStatus(doc)
        #expect(s.message == "Paper jam")
        #expect(s.severity == .error)
        #expect(s.alerts.map(\.message) == ["Toner low (Black)", "Paper jam"])
    }

    @Test func consumablesMergePagesRemainingFromUsage() throws {
        let c = LedmParsers.parseConsumables(try Self.xml("DevMgmt_ConsumableConfigDyn.xml"), usage: try Self.xml("DevMgmt_ProductUsageDyn.xml"))
        try #require(c.count == 1)
        #expect(c[0].name == "Black toner")
        #expect(c[0].percentRemaining == 20)
        #expect(c[0].state == "ok")
        #expect(c[0].productNumber == "W1340A")
        #expect(c[0].selectibilityNumber == "134A")
        #expect(c[0].estimatedPagesRemaining == 100)
        #expect(c[0].installed == DateComponents(year: 2025, month: 1, day: 15))
        #expect(!c[0].isLow)
    }

    @Test func productConfigIdentity() throws {
        let p = LedmParsers.parseProductConfig(try Self.xml("DevMgmt_ProductConfigDyn.xml"))
        #expect(p.makeAndModel == "HP LaserJet MFP M234dw")
        #expect(p.uuid == "12345678-1234-4abc-8def-123456789abc")
        #expect(p.productNumber == "6GW99A")
        #expect(p.adminPasswordSet == true)
    }

    @Test func usageCounters() throws {
        let u = LedmParsers.parseUsage(try Self.xml("DevMgmt_ProductUsageDyn.xml"))
        #expect(u.totalImpressions == 387)
        #expect(u.duplexSheets == 9)
        #expect(u.scanImages == 39)
    }

    @Test func eventTable() throws {
        let events = LedmParsers.parseEventTable(try Self.xml("EventMgmt_EventTable.xml"))
        try #require(events.count == 1)
        #expect(events[0].category == "PowerUpEvent")
        #expect(events[0].agingStamp == "34-1")
        #expect(events[0].resourceType == LedmResource.productStatusDyn)
    }

    @Test(arguments: [("subscribedPagesLow", "Subscribed pages low"), ("na_letter", "Na letter"), ("ADFJam", "ADFJam")] as [(String, String)])
    func humanize(_ id: String, _ expected: String) {
        #expect(LedmStatusText.humanize(id) == expected)
    }

    @Test func deviceXmlNestedDeeperThanAnyPrinterWritesIsRefusedNotAStackOverflow() throws {
        let depth = 200_000
        let xml = String(repeating: "<a>", count: depth) + String(repeating: "</a>", count: depth)
        #expect(throws: XmlFormatError.self) { try DeviceXml.load(xml) }
        _ = try Self.xml("DevMgmt_DiscoveryTree.xml")
    }

    @Test func deviceXmlWithADtdIsRefused() {
        #expect(throws: XmlFormatError.self) { try DeviceXml.load("<?xml version=\"1.0\"?><!DOCTYPE a [<!ENTITY e \"x\">]><a>&e;</a>") }
    }

    @Test func firmwareUpdateManifestPathsNest() throws {
        let map = LedmManifest.parse(try Self.xml("FirmwareUpdate_FirmwareUpdateManifest.xml"))
        #expect(!map.isEmpty)
        #expect(map.values.allSatisfy { $0.hasPrefix("/") && !$0.contains("//") })
    }
}
