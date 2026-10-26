import Foundation
import Testing
@testable import PrintCore

/// "Set up in macOS": the queue asked of cupsd for a network printer macOS has none for. Mac only (the Windows app pairs an
/// association endpoint, or makes an IPP Class Driver queue in PowerShell, neither of which has tests to port).
struct QueueSetupTests {
    private static func dest(_ name: String) -> CupsDestination { CupsDestination(name: name, options: ["printer-type": "4"]) }

    @Test func theQueuePrintsToTheBonjourHostNameSoANewAddressDoesNotBreakIt() throws {
        let plan = try #require(QueueSetup.plan(name: "HP LaserJet MFP M234dw", ippUri: URL(string: "ipp://192.0.2.23:631/ipp/print"),
                                                hostName: "NPI1A2B3C.local.", destinations: []))

        #expect(plan.deviceUri == "ipp://npi1a2b3c.local:631/ipp/print")
        #expect(plan.queueName == "HP_LaserJet_MFP_M234dw")
        #expect(plan.info == "HP LaserJet MFP M234dw")
    }

    @Test func withoutALocalNameTheAddressIsKept() throws {
        let ipps = try #require(QueueSetup.plan(name: "Demo inkjet", ippUri: URL(string: "ipps://192.0.2.31/ipp/print"), hostName: nil, destinations: []))
        #expect(ipps.deviceUri == "ipps://192.0.2.31/ipp/print")
        // A host name that isn't Bonjour's (a DNS name) is the user's own choice: the URL stays as it answered.
        let dns = QueueSetup.plan(name: "Laser", ippUri: URL(string: "ipp://192.0.2.31/ipp/print"), hostName: "printer.example", destinations: [])
        #expect(dns?.deviceUri == "ipp://192.0.2.31/ipp/print")
        // The sessions' IPP over HTTP is ipp:// (and https ipps://) to cupsd.
        #expect(QueueSetup.plan(name: "Laser", ippUri: URL(string: "http://192.0.2.31:631/ipp/print"), hostName: nil, destinations: [])?.deviceUri
            == "ipp://192.0.2.31:631/ipp/print")
        #expect(QueueSetup.plan(name: "Laser", ippUri: URL(string: "https://192.0.2.31:631/ipp/print"), hostName: nil, destinations: [])?.deviceUri
            == "ipps://192.0.2.31:631/ipp/print")
        // No path: IPP Everywhere's.
        #expect(QueueSetup.plan(name: "Laser", ippUri: URL(string: "ipp://192.0.2.31:631"), hostName: nil, destinations: [])?.deviceUri
            == "ipp://192.0.2.31:631/ipp/print")
    }

    @Test func aPrinterWithoutIppHasNoQueueToMake() {
        #expect(QueueSetup.plan(name: "Laser", ippUri: nil, hostName: "npi1a2b3c.local", destinations: []) == nil)
        #expect(QueueSetup.plan(name: "Laser", ippUri: URL(string: "socket://192.0.2.31:9100"), hostName: nil, destinations: []) == nil)
    }

    @Test(arguments: [
        ("HP LaserJet MFP M234dw", "HP_LaserJet_MFP_M234dw"),
        ("Front desk (2nd floor)", "Front_desk_2nd_floor"),
        ("  Café — laser ", "Caf_laser"),
        ("___", "Printer"),
        ("", "Printer"),
    ])
    func queueNamesAreCupsSafe(_ name: String, _ expected: String) {
        #expect(QueueSetup.queueName(name, taken: []) == expected)
    }

    @Test func aTakenNameGetsANumber() {
        let taken = [Self.dest("hp_laserjet").name, "HP_LaserJet_2"]

        #expect(QueueSetup.queueName("HP LaserJet", taken: taken) == "HP_LaserJet_3")
        #expect(QueueSetup.plan(name: "HP LaserJet", ippUri: URL(string: "ipp://192.0.2.5/ipp/print"), hostName: nil,
                                destinations: [Self.dest("HP_LaserJet")])?.queueName == "HP_LaserJet_2")
        #expect(QueueSetup.queueName(String(repeating: "a", count: 300), taken: []).count == 100)
    }

    @Test func theOutcomeSaysWhatToDoNext() {
        #expect(QueueSetup.outcome(nil, info: "Laser") == "Ready to print from any app.")
        #expect(QueueSetup.outcome(.refused, info: "Laser").contains("Only an administrator"))
        #expect(QueueSetup.outcome(.refused, info: "Laser").contains("\u{201C}Laser\u{201D}"))
        #expect(QueueSetup.outcome(.failed("The printer didn't answer."), info: "Laser").hasPrefix("macOS couldn't set up the printer: The printer didn't answer."))
    }

    @Test func demoModeAddsTheQueueToItsMadeUpMac() async throws {
        let demo = DemoOffline(delay: .zero)
        let before = try #require(await demo.destinations())
        let plan = QueueSetupPlan(queueName: "Demo_inkjet", deviceUri: "ipp://192.0.2.31/ipp/print", info: "Demo inkjet")

        try await demo.addQueue(plan)
        try await demo.addQueue(plan)

        let after = try #require(await demo.destinations())
        #expect(after.count == before.count + 1)
        let added = try #require(after.last)
        #expect(added.name == "Demo_inkjet")
        #expect(CupsQueues.isRealQueue(added))
    }
}
