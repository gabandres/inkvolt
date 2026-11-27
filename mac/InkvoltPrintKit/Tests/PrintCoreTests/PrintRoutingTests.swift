import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Ported from PrintRoutingTests.cs: a printer's print routing (`PrintRouting`, print/GLOSSARY.md): whether it has a macOS
/// queue, can be set up, takes jobs straight and the person may choose that, the route and its note, and the one event the
/// tabs that print hear. Through the module with a fake Mac: a queue lookup that finds what `FakeMac.queue` says, and a
/// connection that takes raster when `FakeMac.raster` is set. Mac difference: each call returns the decision's task, awaited
/// here where Windows awaits the call.
@MainActor
struct PrintRoutingTests {
    static let rasterClient = client()

    /// A client the routing never asks anything (it stands for a connection that takes raster).
    static func client() -> IppClient {
        IppClient(DeviceHttp(host: "192.0.2.11", transport: NeverAnswers()), endpoint: URL(string: "http://192.0.2.11:631/ipp/print")!)
    }

    struct NeverAnswers: HttpTransport {
        func send(_ request: HttpRequest) async throws -> HttpResponse { throw DeviceNetworkError.timedOut }
    }

    final class FakeMac: @unchecked Sendable {
        var queue: String?
        var raster: IppClient?
        var lookupFails: (any Error)?
        var slow: Gate<String?>? // a lookup that answers when the test says
        var lookups = 0
        var remembered: [Bool] = []
        var logged: [String] = []

        /// A printer on this Mac: a network printer (`hasAddress`) or one known by its queue alone.
        @MainActor func printer(hasAddress: Bool = true, choseDirect: Bool = false) -> PrintRouting {
            PrintRouting(findQueue: { try await self.findQueue() }, rasterIpp: { self.raster }, hasAddress: hasAddress, choseDirect: choseDirect,
                         rememberChoice: { self.remembered.append($0) }, log: { self.logged.append($0) })
        }

        private func findQueue() async throws -> String? {
            lookups += 1
            if let slow { return await slow.wait() }
            if let lookupFails { throw lookupFails }
            return queue
        }
    }

    struct SpoolerStopped: Error, LocalizedError {
        var errorDescription: String? { "The spooler stopped." }
    }

    /// Counts the changes, as one of the tabs hears them.
    @MainActor
    final class Tab {
        var heard = 0
        init(_ routing: PrintRouting) { routing.listen { [unowned self] in self.heard += 1 } }
    }

    @Test func beforeAnythingIsSaidAPrinterHasItsQueueAndIsOfferedNoSettingUp() {
        let routing = FakeMac().printer()
        #expect(routing.hasQueue)
        #expect(routing.hasRoute)
        #expect(!routing.needsSetup)
        #expect(!routing.canChooseDirect)
        #expect(routing.route == .none)
        #expect(routing.note == .none)
    }

    @Test func itHasAQueueWhenDiscoverySawOneOrALookupFoundOne() async {
        let routing = FakeMac().printer()
        await routing.discovered(queueInstalled: false, pairs: true).value
        #expect(!routing.hasQueue)
        await routing.queueLookedUp(found: true).value
        #expect(routing.hasQueue)
        await routing.queueLookedUp(found: false).value
        #expect(!routing.hasQueue)
        await routing.discovered(queueInstalled: true, pairs: true).value
        #expect(routing.hasQueue)
    }

    @Test(arguments: [
        (true, false, true), // a network printer: macOS adds it by address
        (false, true, true), // discovery can pair it
        (false, false, false), // known by its queue alone, or a scanner on its own
    ])
    func itNeedsSettingUpWithoutAQueueWhenItCanBeSetUp(_ hasAddress: Bool, _ pairs: Bool, _ canSetUp: Bool) async {
        let routing = FakeMac().printer(hasAddress: hasAddress)
        await routing.discovered(queueInstalled: false, pairs: pairs).value
        #expect(routing.canSetUp == canSetUp)
        #expect(routing.needsSetup == canSetUp)
        await routing.queueLookedUp(found: true).value
        #expect(routing.canSetUp == canSetUp)
        #expect(!routing.needsSetup)
    }

    @Test func aScannerOnItsOwnHasNowhereToPrintAndNothingToSetUp() async {
        let routing = FakeMac().printer(hasAddress: false)
        await routing.queueLookedUp(found: false).value
        #expect(!routing.hasQueue)
        #expect(!routing.hasRoute)
        #expect(!routing.needsSetup)
        #expect(routing.route == .none)
    }

    @Test func withoutAQueueAPrinterTakingRasterPrintsStraightAndTheNoteSaysSo() async {
        let mac = FakeMac()
        mac.raster = Self.rasterClient
        let routing = mac.printer()
        await routing.discovered(queueInstalled: false, pairs: false).value
        #expect(routing.route == .direct)
        #expect(routing.note == .direct)
        #expect(routing.hasRoute) // Copy has somewhere to print
        #expect(!routing.canChooseDirect) // nothing to choose between
        #expect(routing.needsSetup) // other apps still can't print to it

        mac.raster = nil // disconnected, or a reconnect that no longer offers raster
        await routing.decide().value
        #expect(routing.route == .none)
        #expect(routing.note == .none)
        #expect(!routing.hasRoute)
    }

    @Test func withAQueueTooThePersonMayChooseStraightAndTheChoiceIsKeptAndFollowed() async throws {
        let mac = FakeMac()
        (mac.queue, mac.raster) = ("Office_inkjet", Self.rasterClient)
        let routing = mac.printer()
        await routing.decide().value
        #expect(routing.route == .queue)
        #expect(routing.canChooseDirect)
        #expect(routing.note == .none)

        await routing.chooseDirect(true).value
        #expect(routing.choseDirect)
        #expect(mac.remembered == [true])
        #expect(routing.route == .direct)
        #expect(routing.note == .directChosen)
        #expect(try await routing.router.choose().route == .direct) // every print follows the choice

        await routing.chooseDirect(false).value
        #expect(mac.remembered == [true, false])
        #expect(routing.route == .queue)
        #expect(routing.note == .none)
    }

    @Test func aChoiceRememberedFromBeforeIsFollowedAndNeedsRaster() async {
        let mac = FakeMac()
        mac.queue = "Office_inkjet"
        let routing = mac.printer(choseDirect: true)
        #expect(routing.choseDirect)
        await routing.decide().value
        #expect(routing.route == .queue) // the printer doesn't take raster: the queue, and no choice offered
        #expect(!routing.canChooseDirect)
        mac.raster = Self.rasterClient
        await routing.decide().value
        #expect(routing.route == .direct)
        #expect(routing.note == .directChosen)
        #expect(mac.remembered.isEmpty) // nothing new to keep
    }

    @Test func everyTabHearsAChangeOfRouteOnce() async {
        let mac = FakeMac()
        (mac.queue, mac.raster) = ("Office_inkjet", Self.rasterClient)
        let routing = mac.printer()
        let tabs = [Tab(routing), Tab(routing), Tab(routing), Tab(routing)] // print, copy, photos, jobs

        await routing.decide().value // connected: through the queue, the choice offered
        #expect(tabs.allSatisfy { $0.heard == 1 })
        await routing.chooseDirect(true).value // the person: straight
        #expect(tabs.allSatisfy { $0.heard == 2 })
        mac.raster = nil
        await routing.decide().value // reconnected without raster: back to the queue
        #expect(tabs.allSatisfy { $0.heard == 3 })
        mac.queue = nil
        await routing.queueLookedUp(found: false).value // the queue was removed: told at once, then the route (nowhere)
        #expect(routing.route == .none)
        #expect(tabs.allSatisfy { $0.heard == 5 })
    }

    @Test func aQueueSetUpIsToldAtOnceAndTheRouteWhenItIsDecided() async {
        let mac = FakeMac()
        let routing = mac.printer()
        await routing.discovered(queueInstalled: false, pairs: true).value
        var told: [(Bool, PrintRoute)] = []
        routing.listen { told.append((routing.needsSetup, routing.route)) }

        let slow = Gate<String?>()
        mac.slow = slow
        let setUp = routing.queueSetUp(made: true)
        await until { mac.lookups > 0 } // the lookup takes its time...
        #expect(told.map(\.0) == [false]) // ...the setup banner doesn't wait for it
        #expect(told.map(\.1) == [.none])
        slow.open("Office_inkjet")
        await setUp.value
        #expect(told.map(\.0) == [false, false])
        #expect(told.map(\.1) == [.none, .queue])
    }

    @Test func whetherItTakesJobsStraightComesFromTheDecisionItGoesWith() async {
        let mac = FakeMac()
        let routing = mac.printer()
        await routing.discovered(queueInstalled: false, pairs: false).value
        #expect(!routing.hasRoute)

        let slow = Gate<String?>()
        mac.slow = slow
        let deciding = routing.decide() // started before the connection...
        await until { mac.lookups > 0 }
        mac.raster = Self.rasterClient // ...which offers raster before the lookup ends: the router sees it
        slow.open(nil)
        await deciding.value
        #expect(routing.route == .direct)
        #expect(routing.hasRoute)
    }

    struct TabBroke: Error, LocalizedError {
        var errorDescription: String? { "A tab broke." }
    }

    @Test func aTabThatFailsToFollowDoesntStopTheOthersOrTheSetup() async {
        let mac = FakeMac()
        mac.queue = "Office_inkjet"
        let routing = mac.printer()
        routing.listen { throw TabBroke() }
        let other = Tab(routing)
        await routing.queueSetUp(made: true).value // completes: the queue was made whatever a tab does
        #expect(other.heard == 2) // the queue at once, then its route
        #expect(mac.logged.contains { $0.contains("A tab broke.") })
    }

    @Test func nothingChangedIsNotToldAndTheQueueIsLookedUpAgainOnlyWhenHavingOneChanged() async {
        let mac = FakeMac()
        mac.queue = "Office_inkjet"
        let routing = mac.printer(hasAddress: false)
        let tab = Tab(routing)
        await routing.decide().value
        #expect(tab.heard == 1)
        await routing.decide().value // a reconnect with the same route
        await routing.chooseDirect(false).value // the choice it had
        #expect(tab.heard == 1)
        #expect(mac.remembered.isEmpty)

        let lookups = mac.lookups
        await routing.queueLookedUp(found: true).value // it had one
        await routing.discovered(queueInstalled: true, pairs: false).value
        #expect(mac.lookups == lookups)
        #expect(tab.heard == 1)

        await routing.discovered(queueInstalled: true, pairs: true).value // now it can pair: told, nothing decided
        #expect(tab.heard == 2)
        #expect(mac.lookups == lookups)
    }

    @Test func aQueueSetUpOrMadeAgainIsAlwaysToldAndDecidedAgain() async {
        let mac = FakeMac()
        let routing = mac.printer()
        let tab = Tab(routing)
        await routing.discovered(queueInstalled: false, pairs: true).value
        #expect(routing.needsSetup)
        #expect(tab.heard == 1) // no queue; the route stays nowhere

        mac.queue = "Office_inkjet"
        await routing.queueSetUp(made: true).value // Set Up: the queue, then its route
        #expect(!routing.needsSetup)
        #expect(routing.route == .queue)
        #expect(tab.heard == 3)

        let lookups = mac.lookups
        await routing.queueSetUp(made: true).value // made again: the same facts, a new queue
        #expect(tab.heard == 4)
        #expect(mac.lookups == lookups + 1)

        mac.queue = nil
        await routing.queueSetUp(made: false).value // removed and not made again: told, then the route (nowhere)
        #expect(routing.needsSetup)
        #expect(routing.route == .none)
        #expect(tab.heard == 6)
    }

    @Test func aDecisionThatFailsChangesNothingUntilOneSucceeds() async {
        let mac = FakeMac()
        mac.raster = Self.rasterClient
        let routing = mac.printer()
        await routing.discovered(queueInstalled: false, pairs: false).value
        #expect(routing.route == .direct)
        let tab = Tab(routing)

        mac.lookupFails = SpoolerStopped()
        mac.raster = nil // disconnected meanwhile
        await routing.decide().value
        #expect(mac.logged.contains("Print route: The spooler stopped."))
        #expect(routing.route == .direct) // as the last decision left it, all of it
        #expect(routing.note == .direct)
        #expect(routing.hasRoute)
        #expect(tab.heard == 0)

        mac.lookupFails = nil
        await routing.decide().value // the next one decides: nowhere now
        #expect(routing.route == .none)
        #expect(routing.note == .none)
        #expect(!routing.hasRoute)
        #expect(tab.heard == 1)
    }

    // ---- the Mac's queue check (Windows' QueueDriver) ----

    static func queue(_ options: [String: String]) -> CupsDestination { CupsDestination(name: "Office_laser", options: options) }

    @Test func aMacQueueWorksWhenItsListedAndPrinting() {
        #expect(PrintRoutes.queueWorks(Self.queue(["printer-state": "3", "printer-is-accepting-jobs": "true"])))
        #expect(PrintRoutes.queueWorks(Self.queue(["printer-state": "4"]))) // printing: fine
        #expect(PrintRoutes.queueWorks(Self.queue([:]))) // says nothing: taken as working
    }

    @Test func aPausedQueueIsTheQueuesRouteStill() {
        // Paused in Printers & Scanners on purpose: its jobs wait there, as on Windows; never printed around it.
        #expect(PrintRoutes.queueWorks(Self.queue(["printer-state": "5", "printer-state-reasons": "paused", "printer-state-message": "Paused"])))
    }

    @Test func aQueueSetToRejectJobsIsTheQueuesRouteStill() {
        #expect(PrintRoutes.queueWorks(Self.queue(["printer-state": "3", "printer-is-accepting-jobs": "false"]))) // cupsreject
        #expect(PrintRoutes.queueWorks(Self.queue(["printer-type": String(CupsDestination.TypeBit.rejecting)])))
    }

    @Test func aQueueStoppedByAFailedFilterGivesWay() {
        #expect(!PrintRoutes.queueWorks(Self.queue(["printer-state": "5", "printer-state-reasons": "paused,cups-missing-filter-warning"])))
        #expect(!PrintRoutes.queueWorks(Self.queue(["printer-state": "5", "printer-state-reasons": "cups-filter-failed"])))
        #expect(!PrintRoutes.queueWorks(Self.queue(["printer-state": "5", "printer-state-reasons": "paused", "printer-state-message": "Filter failed"])))
        #expect(PrintRoutes.queueWorks(Self.queue(["printer-state": "3", "printer-state-reasons": "cups-missing-filter-warning"]))) // not stopped: it prints
    }

    @Test func aQueueMacOSNoLongerListsGivesWay() {
        #expect(!PrintRoutes.queueWorks(nil))
    }
}

/// A value the test hands over when it says (.NET's TaskCompletionSource): waiting before or after it's given both work.
final class Gate<T: Sendable>: Sendable {
    private struct Given: Sendable { let value: T }
    private let state = Mutex<(given: Given?, waiting: [CheckedContinuation<T, Never>])>((nil, []))

    func wait() async -> T {
        await withCheckedContinuation { (c: CheckedContinuation<T, Never>) in
            let given: Given? = state.withLock { s in
                if let g = s.given { return g }
                s.waiting.append(c)
                return nil
            }
            if let given { c.resume(returning: given.value) }
        }
    }

    func open(_ value: T) {
        let waiting = state.withLock { s in
            s.given = Given(value: value)
            defer { s.waiting = [] }
            return s.waiting
        }
        for c in waiting { c.resume(returning: value) }
    }
}

/// Yields until `condition` holds (a task started by the code under test has reached it), at most a few seconds.
@MainActor
func until(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<5000 where !condition() { await Task.yield() }
    if !condition() { try? await Task.sleep(for: .milliseconds(100)) }
    for _ in 0..<2000 where !condition() { try? await Task.sleep(for: .milliseconds(2)) }
}
