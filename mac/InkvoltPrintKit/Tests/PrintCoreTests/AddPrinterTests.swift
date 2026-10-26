import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Add a printer: what the search turns up becomes a list of printers (those listed marked so, things that aren't printers
/// left out), each address asked once and a few at a time, and what the window says. On demo mode's made-up network. New
/// for the Mac: the Windows app keeps these rules in `AddPrinterViewModel`, which has no tests of its own.
struct AddPrinterTests {
    private static let network = Demo.network(fixtures: Fixtures.root)

    private static func identify(_ host: String, listed: [String: (id: String, name: String)] = [:]) async -> FoundPrinter? {
        await AddPrinter.identify(host, transport: { _, _ in network.http }, snmp: network.snmp, listed: { _, h in listed[h] })
    }

    @Test func theDemoSearchFindsTheUnlistedLaserBesideTheListedOnes() async throws {
        let found = Mutex<[FoundPrinter]>([])
        let listed = [FixtureTransport.demoHost: (id: Demo.uuid, name: "Demo printer"),
                      Demo.snmpHost: (id: PrinterId.normalize(nil, host: Demo.snmpHost), name: "Demo Laser 5200 Series")]
        let total = try await AddPrinter.run(skip: [], search: { f, p in try await Demo.searchNetwork(found: f, progress: p) },
                                             identify: { h in await Self.identify(h, listed: listed) },
                                             progress: { _ in }, checking: {}, found: { f in found.withLock { AddPrinter.insert(f, into: &$0) } })
        let list = found.withLock { $0 }
        #expect(total == 253)
        #expect(list.map(\.host) == [Demo.unlistedHost, Demo.snmpHost, FixtureTransport.demoHost]) // to add first, then by name
        #expect(list.map(\.state) == [.canAdd, .listed, .listed])
        #expect(list[2].printerId == Demo.uuid)
        #expect(list[2].name == "Demo printer") // as the list calls it
        #expect(AddPrinterText.done(total: total, found: list) == "Found a printer you can add.")
    }

    @Test func anSnmpOnlyPrinterIsNamedByItsModelWithWhereItSaysItIs() async throws {
        let f = try #require(await Self.identify(Demo.unlistedHost))
        #expect(f.name == "Demo Laser 3100")
        #expect(f.detail == "\(Demo.unlistedHost) · Basement")
        #expect(f.state == .canAdd)
        let known = AddPrinter.knownPrinter(try #require(f.probe), host: f.host)
        #expect(known.uuid == PrinterId.normalize(nil, host: Demo.unlistedHost)) // no UUID: known by its address
        #expect(known.snmp?.model == "Demo Laser 3100")
        #expect(known.snmp?.serialNumber == "DEMO0003100")
    }

    @Test func aPrinterWithLedmIsAddedUnderItsUuidWithItsScanner() async throws {
        let f = try #require(await Self.identify(FixtureTransport.demoHost))
        let known = AddPrinter.knownPrinter(try #require(f.probe), host: f.host)
        #expect(known.uuid == Demo.uuid)
        #expect(known.snmp == nil)
        #expect(known.esclRoot != nil)
        #expect(known.model == f.name)
    }

    @Test func somethingThatIsNotAPrinterIsLeftOut() async {
        #expect(await Self.identify("192.0.2.99") == nil)
    }

    @Test func eachAddressIsAskedOnceAndAFewAtATime() async throws {
        let asked = Mutex<(all: [String], now: Int, most: Int)>(([], 0, 0))
        let hosts = (1...40).map { "192.0.2.\($0)" }
        let total = try await AddPrinter.run(skip: ["192.0.2.1"], search: { f, p in
            for h in hosts + hosts { f(h) } // twice: the SNMP question and the sweep both report a printer
            p(SearchProgress(checked: 40, total: 40))
        }, identify: { h in
            asked.withLock { a in
                a.all.append(h)
                a.now += 1
                a.most = max(a.most, a.now)
            }
            try? await Task.sleep(for: .milliseconds(5))
            asked.withLock { $0.now -= 1 }
            return nil
        }, progress: { _ in }, checking: {}, found: { _ in })
        let a = asked.withLock { $0 }
        #expect(total == 40)
        #expect(a.all.count == 39) // the removed printer already offered isn't asked
        #expect(Set(a.all).count == 39)
        #expect(a.most <= AddPrinter.identifyingAtOnce)
    }

    @Test func stoppingTheSearchStopsIt() async {
        let task = Task {
            try await AddPrinter.run(skip: [], search: { _, _ in try await Task.sleep(for: .seconds(3600)) }, identify: { _ in nil },
                                     progress: { _ in }, checking: {}, found: { _ in })
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func printersToAddComeFirstThenThoseListedByName() {
        var list: [FoundPrinter] = []
        for (name, state) in [("b listed", FoundState.listed), ("Zeta", .canAdd), ("a listed", .listed), ("alpha", .canAdd)] {
            AddPrinter.insert(FoundPrinter(name: name, host: name, detail: name, state: state), into: &list)
        }
        #expect(list.map(\.name) == ["alpha", "Zeta", "a listed", "b listed"])
    }

    @Test func aPrinterRemovedEarlierIsOfferedWithWhy() throws {
        let d = DiscoveredPrinter(uuid: Demo.uuid, name: "Office laser", model: nil, host: "192.0.2.40", hostName: nil, esclRoot: nil, hasScanner: false,
                                  ippUri: nil, txt: [:], addresses: ["192.0.2.40"])
        let f = try #require(AddPrinter.removed(d))
        #expect(f.detail == "192.0.2.40 · Removed from your list earlier")
        #expect(f.state == .canAdd)
        var noHost = d
        noHost.host = nil
        #expect(AddPrinter.removed(noHost) == nil)
    }

    @Test(arguments: [
        (0, 0, 0, "This Mac isn't on a home or office network that can be searched."),
        (253, 0, 0, "No printers answered on your network."),
        (253, 0, 1, "The printer that answered is in your list already."),
        (253, 0, 2, "The 2 printers that answered are in your list already."),
        (253, 1, 2, "Found a printer you can add."),
        (253, 3, 0, "Found 3 printers you can add."),
    ])
    func theWindowSaysWhatTheSearchFound(_ total: Int, _ toAdd: Int, _ listed: Int, _ text: String) {
        let found = (0..<toAdd).map { FoundPrinter(name: "a\($0)", host: "a\($0)", detail: "") }
            + (0..<listed).map { FoundPrinter(name: "l\($0)", host: "l\($0)", detail: "", state: .listed) }
        #expect(AddPrinterText.done(total: total, found: found) == text)
        #expect(AddPrinterText.nothingFound(found) == (toAdd == 0))
    }
}
