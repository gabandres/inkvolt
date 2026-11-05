import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// The printer monitor over demo mode's made-up network (the fixtures in place): coming online, offline and retried,
/// another device at the address and "This is my printer", following an announced address. The same names as the Windows
/// app's PrinterMonitorTests.cs (shared/InkvoltPrint.Core/Probe/PrinterMonitor.cs); the demo printers are DemoTests.cs's.
struct PrinterMonitorTests {
    private static let network = Demo.network(fixtures: Fixtures.root)

    /// Everything a monitor told, and the UUIDs accepted for it.
    final class Log: Sendable {
        private let state = Mutex<(events: [MonitorEvent], accepted: [String])>(([], []))
        var events: [MonitorEvent] { state.withLock { $0.events } }
        var accepted: [String] { state.withLock { $0.accepted } }
        func add(_ e: MonitorEvent) { state.withLock { $0.events.append(e) } }
        func accept(_ uuids: [String]) { state.withLock { $0.accepted += uuids } }

        var snapshots: [PrinterSnapshot] { events.compactMap { if case .observed(let s) = $0 { s } else { nil } } }
        var connections: [PrinterWhere] { events.compactMap { if case .connected(let w, _) = $0 { w } else { nil } } }
    }

    private static func monitor(_ printer: KnownPrinter, id: String? = nil, _ log: Log) -> PrinterMonitor {
        let recipe = PrinterRecipe(transport: { _, _ in network.http }, snmp: network.snmp)
        return PrinterMonitor(id: id ?? printer.uuid, name: printer.name, target: printer.target, recipe: recipe, accepted: { log.accepted },
                              acceptUuids: { log.accept($0) }, retryDelay: .milliseconds(50), fallbackRefresh: .milliseconds(200),
                              onEvent: { log.add($0) })
    }

    private static func demo(_ uuid: String) -> KnownPrinter { Demo.state().printers.first { $0.uuid == uuid }! }

    /// Waits up to 10 s for the monitor's view to satisfy `done`.
    private static func until(_ m: PrinterMonitor, _ done: @Sendable (PrinterView) -> Bool) async throws -> PrinterView {
        for _ in 0..<1000 {
            let v = await m.view
            if done(v) { return v }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("The monitor never got there: \(await m.view.phase), \(await m.view.statusMessage)")
        return await m.view
    }

    @Test func theDemoLaserComesOnlineWithItsTonerAndSaysWhereItIs() async throws {
        let log = Log()
        let m = Self.monitor(Self.demo(Demo.uuid), log)
        let run = Task { await m.run() }
        defer { run.cancel() }
        let v = try await Self.until(m) { $0.isOnline }
        #expect(v.model == "HP LaserJet MFP M234dw")
        #expect(v.interfaces.contains("LEDM"))
        #expect(v.supplies.contains { $0.kind.lowercased().contains("toner") })
        #expect(v.listLine == PrinterStatus.listLine(v.statusMessage, v.severity, v.alerts))
        #expect(log.connections.first?.host == FixtureTransport.demoHost)
        #expect(log.snapshots.contains { $0.reachable && $0.uuid == Demo.uuid })
    }

    @Test func everyDemoPrinterReadsOverItsOwnInterfaceAndTheOfficeLaserIsOffline() async throws {
        for printer in Demo.state().printers {
            let log = Log()
            let m = Self.monitor(printer, log)
            let run = Task { await m.run() }
            let v = try await Self.until(m) { $0.phase != .connecting }
            run.cancel()
            if printer.uuid == Demo.officeUuid {
                #expect(v.phase == .offline)
            } else {
                #expect(v.phase == .online, "\(printer.name)")
                #expect(!v.supplies.isEmpty, "\(printer.name)")
            }
        }
    }

    @Test func nothingAnsweringIsOfflineSaysWhereAndIsTriedAgain() async throws {
        let log = Log()
        let m = Self.monitor(Self.demo(Demo.officeUuid), log)
        let run = Task { await m.run() }
        defer { run.cancel() }
        let v = try await Self.until(m) { $0.phase == .offline }
        #expect(v.statusMessage == "Can't reach the printer")
        #expect(v.statusDetail?.contains(Demo.officeOldHost) == true)
        #expect(v.listLine == "Can't reach the printer")
        for _ in 0..<500 where log.snapshots.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(log.snapshots.count >= 2)
        #expect(log.snapshots.allSatisfy { !$0.reachable })
    }

    @Test func anotherDeviceAtTheAddressShowsNothingOfItUntilTheUserSaysItIsThisPrinter() async throws {
        let log = Log()
        let mine = KnownPrinter(uuid: "87654321-4321-4cba-8fed-cba987654321", name: "My laser", host: FixtureTransport.demoHost)
        let m = Self.monitor(mine, log)
        var run = Task { await m.run() }
        let v = try await Self.until(m) { $0.phase == .elsewhere }
        #expect(v.supplies.isEmpty)
        #expect(v.model == nil)
        #expect(await m.foreignUuids.contains(Demo.uuid))
        #expect(log.snapshots.allSatisfy { !$0.reachable })
        run.cancel()

        #expect(await m.acceptDevice { log.accept($0) })
        #expect(log.accepted.contains(Demo.uuid))
        run = Task { await m.run() }
        defer { run.cancel() }
        #expect(try await Self.until(m) { $0.isOnline }.model == "HP LaserJet MFP M234dw")
    }

    @Test func announcedAtANewAddressItMovesThereOnlyWhenItIsThisPrinter() async throws {
        let log = Log()
        let m = Self.monitor(Self.demo(Demo.officeUuid), log)
        var run = Task { await m.run() }
        _ = try await Self.until(m) { $0.phase == .offline }

        // The demo laser announced under the office laser's UUID: another device answers there.
        #expect(!(await m.announced(Self.found(Demo.officeUuid, host: FixtureTransport.demoHost))))
        #expect(await m.target.host == Demo.officeOldHost)

        #expect(await m.announced(Self.found(Demo.officeUuid, host: Demo.officeNewHost)))
        #expect(await m.target.host == Demo.officeNewHost)
        run.cancel()
        run = Task { await m.run() }
        defer { run.cancel() }
        #expect(try await Self.until(m) { $0.isOnline }.model == "Demo office laser")
        #expect(log.connections.last?.host == Demo.officeNewHost)
    }

    @Test func seenAgainAtItsAddressWhileOfflineItIsAskedAtOnce() async throws {
        let log = Log()
        let m = Self.monitor(Self.demo(Demo.officeUuid), log)
        let run = Task { await m.run() }
        defer { run.cancel() }
        _ = try await Self.until(m) { $0.phase == .offline }
        #expect(await m.announced(Self.found(Demo.officeUuid, host: Demo.officeOldHost)))
    }

    private static func found(_ uuid: String, host: String) -> DiscoveredPrinter {
        DiscoveredPrinter(uuid: uuid, name: "Office", model: nil, host: host, hostName: nil, esclRoot: nil, hasScanner: false, ippUri: nil, txt: [:],
                          addresses: [host])
    }

    @Test func aBackgroundCheckReadsOnceAndSaysWhetherThePrinterAnswered() async throws {
        let log = Log()
        let laser = Self.monitor(Self.demo(Demo.uuid), log)
        #expect(await laser.check())
        #expect(await laser.view.isOnline)
        #expect(await laser.check()) // connected already: asked who it is, then read
        #expect(log.snapshots.filter { $0.reachable }.count == 2)

        let office = Self.monitor(Self.demo(Demo.officeUuid), Log())
        #expect(await !office.check())
        #expect(await office.view.phase == .offline)
    }

    /// The firmware watch (roadmap 1.5) over the state file's record, as the app sets it up: demo mode's laser had an older
    /// version until this connection, so the view and every reading's snapshot carry the change until it's dismissed; the
    /// record says so, and the next connection shows nothing.
    @Test func aFirmwareChangeIsShownAndInEachSnapshotUntilDismissed() async throws {
        let store = StateStore(memory: Demo.state())
        let today = Day(2026, 11, 4)
        let memory = FirmwareMemory(get: { store.firmware(Demo.uuid) }, set: { store.setFirmware(Demo.uuid, $0) }, today: { today })
        let log = Log()
        let recipe = PrinterRecipe(transport: { _, _ in Self.network.http }, snmp: Self.network.snmp)
        let printer = Self.demo(Demo.uuid)
        func monitor(_ log: Log) -> PrinterMonitor {
            PrinterMonitor(id: printer.uuid, name: printer.name, target: printer.target, recipe: recipe, accepted: { [] }, acceptUuids: { _ in },
                           firmware: memory, onEvent: { log.add($0) })
        }
        let laser = monitor(log)
        #expect(await laser.check())
        let notice = try #require(await laser.view.firmwareNotice)
        let version = try #require(await laser.view.firmware?.display)
        #expect(notice == FirmwareChange("2023-11-02", version, today))
        #expect(store.firmware(Demo.uuid) == FirmwareRecord(version, today, previous: "2023-11-02"))
        #expect(log.snapshots.last?.firmwareChange == notice)

        await laser.dismissFirmwareNotice()
        #expect(await laser.view.firmwareNotice == nil)
        #expect(store.firmware(Demo.uuid)?.dismissed == true)
        #expect(await laser.check())
        #expect(log.snapshots.last?.firmwareChange == nil)

        let next = Log()
        #expect(await monitor(next).check())
        #expect(next.snapshots.last?.reachable == true)
        #expect(next.snapshots.last?.firmwareChange == nil)
        #expect(store.firmware(Demo.uuid)?.version == version)
    }

    /// The supply history (roadmap 1.1) as the app sets it up in demo mode: the first reading of the demo laser makes up its
    /// year, then is kept as today's row with the page count; the view carries each supply's line and the chart, and the
    /// reading's snapshot the days left the low-supply alert names. The Windows app's PrinterViewModel.ShowSupplies.
    @Test func eachReadingIsKeptInTheSupplyHistoryAndTheCardAndTheAlertGetWhatItSays() async throws {
        let store = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)
        let today = Day(2026, 11, 4)
        let log = Log()
        let recipe = PrinterRecipe(transport: { _, _ in Self.network.http }, snmp: Self.network.snmp)
        let printer = Self.demo(Demo.uuid)
        let laser = PrinterMonitor(id: printer.uuid, name: printer.name, target: printer.target, recipe: recipe, accepted: { [] },
                                   acceptUuids: { _ in }, history: SupplyHistoryFeed(store, printer.uuid, today: { today }),
                                   onEvent: { log.add($0) })
        #expect(await laser.check())

        let v = await laser.view
        let history = try #require(v.supplyHistory)
        let toner = try #require(v.supplies.first { !$0.isWaste && $0.percentRemaining != nil })
        let kept = try #require(store.rows(printer.uuid).last { $0.key == SupplyRow.keyOf(toner) })
        #expect(kept.day == today)
        #expect(kept.percent == toner.percentRemaining)
        #expect(kept.pages == v.usage?.totalImpressions)
        #expect(history.chart.hasEnoughToDraw) // the made-up year behind the first reading
        #expect(history.line(for: toner) != nil)
        #expect(history == SupplyHistoryView.of(store.rows(printer.uuid), today))
        #expect(log.snapshots.last?.daysLeft == history.daysLeft)

        let without = Self.monitor(printer, Log())
        #expect(await without.check())
        #expect(await without.view.supplyHistory == nil)
    }
}
