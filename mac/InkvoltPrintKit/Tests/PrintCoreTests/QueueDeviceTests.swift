import Foundation
import Testing
@testable import PrintCore

/// Queue printers that say more than their queue (roadmap 3.6, route 1): the printer's own IPP attributes, for a USB
/// printer on a driverless (IPP over USB) queue, read with the network printers' IPP mapping; the decorator that asks, times
/// out, and stays quiet when a queue has nothing to say. Ported from QueueDeviceTests.cs. Not ported: route 2 (a maker's
/// driver over Windows' bidi, `QueueBidiTests`) and `ACallThatHangsIsNothingAndTiesUpOneThread` (`TimedCalls`, Windows'
/// blocking calls); the decorator's own time limit (`aReaderThatHangsOrThrowsIsCutOffAndTheNextAsked`) covers the Mac.
struct QueueDeviceTests {
    private static func fixtureText() throws -> String { try Fixtures.text("inkjet-demo/ipp_print.ipp.txt") }

    /// The printer-attributes group as Windows hands it over: the fixture's response without its header, operation group
    /// and end tag.
    static func attributesGroup(_ ippText: String, withTag: Bool = true) throws -> [UInt8] {
        let full = IppCodec.encodeResponse(status: 0, requestId: 1, try IppText.parse(ippText))
        var i = 9 // header, operation-attributes tag
        for _ in 0..<2 { // attributes-charset, attributes-natural-language
            let nameLength = Int(full[i + 1]) << 8 | Int(full[i + 2])
            let valueLength = Int(full[i + 3 + nameLength]) << 8 | Int(full[i + 4 + nameLength])
            i += 5 + nameLength + valueLength
        }
        #expect(full[i] == 0x04)
        return Array(full[(withTag ? i : i + 1)..<(full.count - 1)])
    }

    /// The whole Get-Printer-Attributes response, as the Mac's transport gets it from the printer.
    static func wholeResponse(_ ippText: String, status: UInt16 = 0) throws -> [UInt8] {
        IppCodec.encodeResponse(status: status, requestId: 1, try IppText.parse(ippText))
    }

    @Test(arguments: [true, false])
    func anIppUsbPrintersAttributesReadAsANetworkPrintersDo(withTag: Bool) throws {
        let r = try #require(IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText(), withTag: withTag), usb: true))

        #expect(r.from == .printerOverUsb)
        #expect(r.status?.code == "ready")
        #expect(r.status?.alerts.contains { $0.id == "marker-supply-low" && $0.severity == .warning } == true)
        #expect(r.supplies.map(\.name) == ["Black ink", "Cyan ink", "Magenta ink", "Yellow ink", "Maintenance box"])
        #expect(r.supplies.prefix(4).map(\.percentRemaining) == [72, 55, 63, 12])
        #expect(r.supplies[3].state == "low")
        #expect(r.supplies[0].colorCode == "K")
        #expect(r.supplies[4].percentRemaining == nil) // a waste box: no percentage
    }

    /// The Mac's transport hands over the printer's whole reply: read the same; a reply refusing the request is nothing.
    @Test func aWholeResponseReadsAsTheGroupDoesAndARefusalIsNothing() throws {
        let text = try Self.fixtureText()
        let whole = try #require(IppQueueReading.from(try Self.wholeResponse(text), usb: true))
        #expect(whole == IppQueueReading.from(try Self.attributesGroup(text), usb: true))
        #expect(IppQueueReading.from(try Self.wholeResponse(text, status: 0x0400), usb: true) == nil) // client-error-bad-request
        #expect(IppQueueReading.from(try Self.wholeResponse(text, status: 0x0001), usb: true) != nil) // ok, some attributes ignored
    }

    @Test func aNetworkIppQueueSaysItCameFromThePrinter() throws {
        let r = try #require(IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: false))
        #expect(r.from == .printerOverNetwork)
        #expect(QueueDeviceText.source(r.from) == "From the printer")
        #expect(QueueDeviceText.source(.printerOverUsb) == "From the printer over USB")
    }

    @Test func illFormedOrHostileAttributeBytesGiveNothing() throws {
        let good = try Self.attributesGroup(try Self.fixtureText())
        #expect(IppQueueReading.from([], usb: true) == nil)
        #expect(IppQueueReading.from(Array(good.dropLast(7)), usb: true) == nil) // cut short
        #expect(IppQueueReading.from([UInt8](repeating: 0, count: IppQueueReading.maxBytes + 1), usb: true) == nil) // too big to be one
        #expect(IppQueueReading.from([UInt8](repeating: 0xFF, count: 300), usb: true) == nil)
        #expect(IppQueueReading.from(try Self.attributesGroup("printer-name name Somebody's printer"), usb: true) == nil) // neither state nor supplies
        // Wrong types: a level as text, a state as a keyword. Read as unknown, never thrown.
        let odd = try #require(IppQueueReading.from(try Self.attributesGroup("printer-state keyword idle\nmarker-names name Black\nmarker-levels keyword full"), usb: true))
        #expect(odd.status == nil) // no state it can read: macOS's stands (aPrinterWithNoStateLeavesMacOSHeadline)
        #expect(odd.supplies.count == 1)
        #expect(odd.supplies.first?.state == "unknown")
        #expect(odd.supplies.first?.percentRemaining == nil)
    }

    @Test func aHostilePrintersFloodOfSuppliesAndProblemsIsCut() throws {
        let names = (0..<1500).map { "marker-names name Supply \($0)" }.joined(separator: "\n")
        let reasons = (0..<1500).map { "printer-state-reasons keyword made-up-\($0)-error" }.joined(separator: "\n")
        let alerts = (0..<1500).map { "printer-alert octetString code=made-up-alert-\($0);severity=critical" }.joined(separator: "\n")
        let text = "printer-state enum 3\n" + names + "\n" + reasons + "\n" + alerts

        let r = try #require(IppQueueReading.from(try Self.attributesGroup(text), usb: true))

        #expect(r.supplies.count == IppClient.maxSupplies)
        #expect(r.supplies[0].name == "Supply 0")
        let status = try #require(r.status)
        #expect(status.alerts.count <= 2 * IppClient.maxAlerts, "\(status.alerts.count) alerts")
        #expect(status.severity == .error)
    }

    @Test func itAsksForNoIdentifiers() {
        #expect(!IppQueueReading.attributes.contains { a in
            a.contains("uuid") || a.contains("serial") || a.contains("uri") || (a.contains("name") && a != "marker-names")
                || a.contains("location") || a.contains("info")
        })
    }

    // MARK: The decorator

    final class Reader: QueueDeviceReader, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private let body: @Sendable () async throws -> QueueDeviceReading?

        init(_ body: @escaping @Sendable () async throws -> QueueDeviceReading?) { self.body = body }

        var calls: Int { lock.withLock { count } }

        func read() async throws -> QueueDeviceReading? {
            lock.withLock { count += 1 }
            return try await body()
        }
    }

    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date

        init(_ value: Date) { self.value = value }

        var now: Date { lock.withLock { value } }

        func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    }

    static let ready = PrinterStatus(code: "ready", message: "Ready", severity: .info, alerts: [])

    private static func macOS(_ status: PrinterStatus, offline: Bool = false, supplies: [Consumable] = []) -> QueueStatusRead {
        QueueStatusRead(status: status, offline: offline, supplies: supplies)
    }

    private static let t0 = Date(timeIntervalSince1970: 1_767_268_800) // 2026-01-01 12:00 UTC

    @Test func aQueueWithAnIppUsbPrinterShowsItsSuppliesAndStatus() async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        var waiting = Self.ready
        waiting.detail = "2 jobs are waiting."
        let source = DeviceQueueStatus(readers: [Reader { reading }])

        let read = try #require(await source.read(QueueStatusRead(status: waiting, offline: false, supplies: [], jobsNote: "2 jobs are waiting.")))

        #expect(read.supplies.count == 5)
        #expect(read.status.severity == .warning)
        #expect(read.status.detail?.contains("2 jobs are waiting.") == true)
        #expect(await source.hasSupplyLevels)
        #expect(await source.from == .printerOverUsb)
        #expect(await source.origin == "the printer over USB (IPP)")
        #expect(await source.suppliesSource(read) == "From the printer over USB")
    }

    @Test(arguments: [
        "marker-names name Black\nmarker-levels integer 40", // no printer-state
        "printer-state keyword idle\nmarker-names name Black\nmarker-levels integer 40", // not an enum
        "printer-state enum 9\nmarker-names name Black\nmarker-levels integer 40", // not a state IPP has
    ])
    func aPrinterWithNoStateLeavesMacOSHeadline(attributes: String) async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup(attributes), usb: true)
        let jam = PrinterStatus(code: "error", message: "Paper jam", severity: .error, alerts: [], detail: "Clear the jam.")
        let source = DeviceQueueStatus(readers: [Reader { reading }])

        let read = try #require(await source.read(Self.macOS(jam)))

        #expect(read.status.message == "Paper jam") // not "Unknown", with nothing wrong
        #expect(read.status.severity == .error)
        #expect(read.supplies.count == 1)
        #expect(read.supplies.first?.percentRemaining == 40)
    }

    @Test func aProblemFromAPrinterWithNoStateIsStillAdded() async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup("printer-state-reasons keyword media-jam-error\nmarker-names name Black"), usb: true)
        let source = DeviceQueueStatus(readers: [Reader { reading }])

        let read = try #require(await source.read(Self.macOS(Self.ready)))

        #expect(read.status.message == "Ready")
        #expect(read.status.severity == .error)
        #expect(read.status.alerts.contains { $0.id == "media-jam" })
    }

    @Test func macOSHoldingTheJobsStaysTheHeadline() async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let paused = PrinterStatus(code: "paused", message: "Paused in macOS", severity: .warning, alerts: [],
                                   detail: "macOS holds print jobs until the printer is resumed.")
        let source = DeviceQueueStatus(readers: [Reader { reading }])

        let read = try #require(await source.read(Self.macOS(paused)))

        #expect(read.status.message == "Paused in macOS")
        #expect(read.status.alerts.contains { $0.id == "marker-supply-low" })
        #expect(read.supplies.count == 5)
    }

    /// "Not accepting jobs" is macOS's own hold too (the Windows spec's paused and Use Printer Offline).
    @Test func aQueueNotAcceptingJobsStaysTheHeadline() async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let rejecting = PrinterStatus(code: "rejecting", message: "Not accepting jobs", severity: .warning, alerts: [])
        let read = try #require(await DeviceQueueStatus(readers: [Reader { reading }]).read(Self.macOS(rejecting)))
        #expect(read.status.message == "Not accepting jobs")
        #expect(read.supplies.count == 5)
    }

    @Test func notReportedWhenNoRouteAnswersAndAskedAgainOnlyMinutesLater() async throws {
        let clock = Clock(Self.t0)
        let ipp = Reader { nil }
        let second = Reader { QueueDeviceReading(from: .printerOverNetwork, status: nil, alerts: [], supplies: []) }
        let source = DeviceQueueStatus(readers: [ipp, second], now: { clock.now })

        let read = try #require(await source.read(Self.macOS(Self.ready)))
        #expect(read.supplies.isEmpty)
        #expect(read.status.message == "Ready")
        #expect(await source.from == nil)
        #expect(await !source.hasSupplyLevels)
        #expect(await source.origin == "macOS's print queue")
        #expect(await source.suppliesSource(read) == "Not reported by this printer.")

        clock.advance(4 * 60)
        _ = await source.read(Self.macOS(Self.ready))
        #expect((ipp.calls, second.calls) == (1, 1))
        clock.advance(60)
        _ = await source.read(Self.macOS(Self.ready))
        #expect((ipp.calls, second.calls) == (2, 2))
    }

    /// The Mac difference: cupsd keeps its own copy of the levels (`marker-*`, from the last job). With no printer answering,
    /// those stand, and the card says nothing about where they came from (as on Windows for the spooler's own).
    @Test func cupsdsOwnLevelsStandWhenThePrinterSaysNothing() async throws {
        let cups = [Consumable(name: "Black Toner", kind: "toner", colorCode: "K", percentRemaining: 12, state: "low")]
        let source = DeviceQueueStatus(readers: [Reader { nil }])
        let read = try #require(await source.read(Self.macOS(Self.ready, supplies: cups)))
        #expect(read.supplies == cups)
        #expect(await source.hasSupplyLevels)
        #expect(await source.suppliesSource(read) == nil)

        // A printer that answers with levels wins over cupsd's older copy.
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let answered = try #require(await DeviceQueueStatus(readers: [Reader { reading }]).read(Self.macOS(Self.ready, supplies: cups)))
        #expect(answered.supplies.count == 5)
    }

    @Test func anAnsweringPrinterIsReadEvery30SecondsAndTheFirstRouteWins() async throws {
        let clock = Clock(Self.t0)
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let ipp = Reader { reading }
        let second = Reader { throw CancellationError() } // never asked
        let source = DeviceQueueStatus(readers: [ipp, second], now: { clock.now })

        _ = await source.read(Self.macOS(Self.ready))
        clock.advance(10)
        #expect(await source.read(Self.macOS(Self.ready))?.supplies.count == 5) // the last reading stands
        #expect(ipp.calls == 1)
        clock.advance(25)
        _ = await source.read(Self.macOS(Self.ready))
        #expect((ipp.calls, second.calls) == (2, 0))
    }

    struct Bidi: Error {}

    @Test func aReaderThatHangsOrThrowsIsCutOffAndTheNextAsked() async throws {
        let hangs = Reader { // ignores cancellation
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) { c.resume() }
            }
            return nil
        }
        let fails = Reader { throw Bidi() }
        let answers = Reader {
            QueueDeviceReading(from: .printerOverNetwork, status: nil, alerts: [],
                               supplies: [Consumable(name: "Black toner", kind: "toner", colorCode: "K", percentRemaining: 40, state: "ok")])
        }
        let source = DeviceQueueStatus(readers: [hangs, fails, answers], limit: .milliseconds(100))

        let started = Date()
        let read = try #require(await source.read(Self.macOS(Self.ready)))

        // 5.5 s once on CI's busy runner (2026-11-06) for two 100 ms limits: CI gets slack, as ConnectionTests does.
        let onCI = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil
        #expect(Date().timeIntervalSince(started) < (onCI ? 20 : 5))
        #expect(read.supplies.map(\.name) == ["Black toner"])
        #expect(await source.origin == "the printer over IPP")
    }

    /// The Mac's own: an actor lets a second read in while the first waits on the printer; it shares that round, never
    /// starts another, and both get the printer's reading.
    @Test func readsAtTheSameTimeShareOneRoundOfQuestions() async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let ipp = Reader {
            try? await Task.sleep(for: .milliseconds(300))
            return reading
        }
        let source = DeviceQueueStatus(readers: [ipp])
        async let a = source.read(Self.macOS(Self.ready))
        async let b = source.read(Self.macOS(Self.ready))
        let (first, second) = await (a, b)
        #expect(ipp.calls == 1)
        #expect(first?.supplies.count == 5)
        #expect(second?.supplies.count == 5)
    }

    final class Answers: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        var on: Bool {
            get { lock.withLock { value } }
            set { lock.withLock { value = newValue } }
        }
    }

    /// One round with nothing (a timeout, a printer busy for a moment) keeps the last reading for `keptFor` and asks again
    /// after `readInterval`; only after that does the card go back to macOS's view and the five-minute wait.
    @Test func oneMissedReadKeepsTheLastReadingAndAsksAgainSoon() async throws {
        let clock = Clock(Self.t0)
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let answers = Answers()
        let ipp = Reader { answers.on ? reading : nil }
        let source = DeviceQueueStatus(readers: [ipp], now: { clock.now })
        #expect(await source.read(Self.macOS(Self.ready))?.supplies.count == 5)

        answers.on = false
        clock.advance(30)
        #expect(await source.read(Self.macOS(Self.ready))?.supplies.count == 5) // kept
        #expect(await source.from == .printerOverUsb)
        clock.advance(30)
        #expect(await source.read(Self.macOS(Self.ready))?.supplies.count == 5)
        #expect(ipp.calls == 3) // asked again 30 s after a miss, not 5 minutes

        answers.on = true
        clock.advance(30)
        #expect(await source.read(Self.macOS(Self.ready))?.supplies.count == 5)
        #expect(ipp.calls == 4)

        answers.on = false
        var at = 0.0
        while at < DeviceQueueStatus.keptFor + 1 {
            clock.advance(DeviceQueueStatus.readInterval)
            at += DeviceQueueStatus.readInterval
            _ = await source.read(Self.macOS(Self.ready))
        }
        #expect(await source.read(Self.macOS(Self.ready))?.supplies.isEmpty == true) // too old: macOS's own view
        #expect(await source.from == nil)
        let calls = ipp.calls
        clock.advance(4 * 60)
        _ = await source.read(Self.macOS(Self.ready))
        #expect(ipp.calls == calls)
    }

    /// The card doesn't wait on the printer: while a round is out (up to `callLimit`), macOS's state now shows at once, with
    /// the printer's last reading merged in and its origin.
    @Test func whileThePrinterIsAskedMacOSsStateShowsAtOnceWithTheLastReading() async throws {
        let clock = Clock(Self.t0)
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let slow = Answers()
        slow.on = false
        let ipp = Reader {
            if slow.on { try? await Task.sleep(for: .seconds(1)) }
            return reading
        }
        let source = DeviceQueueStatus(readers: [ipp], now: { clock.now })
        let first = await source.current(Self.macOS(Self.ready))
        #expect(first.read == Self.macOS(Self.ready)) // nothing read yet: macOS's own
        #expect(first.origin == "macOS's print queue")
        _ = await source.read(Self.macOS(Self.ready))

        slow.on = true
        clock.advance(DeviceQueueStatus.readInterval)
        let paused = PrinterStatus(code: "paused", message: "Paused in macOS", severity: .warning, alerts: [])
        let asking = Task { await source.read(Self.macOS(paused)) }
        for _ in 0..<200 where ipp.calls < 2 { try await Task.sleep(for: .milliseconds(5)) }
        #expect(ipp.calls == 2)

        let started = Date()
        let now = await source.current(Self.macOS(paused))
        #expect(Date().timeIntervalSince(started) < 0.5)
        #expect(now.read.status.message == "Paused in macOS")
        #expect(now.read.supplies.count == 5)
        #expect(now.origin == "the printer over USB (IPP)")
        #expect(now.source == "From the printer over USB")
        #expect(await asking.value?.supplies.count == 5)
    }

    @Test func aRemovedQueueIsStillReportedRemoved() async {
        let reader = Reader { throw Bidi() }
        #expect(await DeviceQueueStatus(readers: [reader]).read(nil) == nil)
        #expect(reader.calls == 0)
    }

    @Test func anOfflineQueueKeepsItsHeadlineWithTheLastSupplies() async throws {
        let reading = IppQueueReading.from(try Self.attributesGroup(try Self.fixtureText()), usb: true)
        let offline = PrinterStatus(code: "offline", message: "Offline", severity: .error, alerts: [], detail: "macOS can't reach the printer.")
        let read = try #require(await DeviceQueueStatus(readers: [Reader { reading }]).read(Self.macOS(offline, offline: true)))
        #expect(read.offline)
        #expect(read.status.message == "Offline")
        #expect(read.status.severity == .error)
        #expect(read.supplies.count == 5)
    }

    // MARK: Which queues are asked (the Mac's own decision)

    @Test func onlyAUsbOrNetworkIppQueueIsAskedAndAUsbOneSaysSo() {
        func queue(_ uri: String) -> CupsDestination {
            CupsDestination(name: "Q", options: ["device-uri": uri, "printer-type": "4", "printer-state": "3"])
        }
        #expect(IppQueueReading.route(queue("ipp://localhost:60000/ipp/print")) == .printerOverUsb) // ippusbxd's local relay
        #expect(IppQueueReading.route(queue("ippusb://Demo%20Inkjet/ipp/print")) == .printerOverUsb) // CUPS 2.5's own
        #expect(IppQueueReading.route(queue("usb://Demo/Inkjet?serial=DEMO1")) == nil) // macOS's USB backend: no IPP to ask, cupsd's copy only
        #expect(IppQueueReading.route(queue("ipp://192.0.2.11/ipp/print")) == .printerOverNetwork)
        #expect(IppQueueReading.route(queue("dnssd://Demo%20Inkjet._ipp._tcp.local./?uuid=2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b")) == .printerOverNetwork)
        #expect(IppQueueReading.route(queue("socket://192.0.2.15")) == nil) // a raw socket: no IPP to ask (SNMP's job)
        #expect(IppQueueReading.route(queue("smb://office-pc/Laser")) == nil) // shared: the other computer's printer
        #expect(IppQueueReading.route(queue("lpd://192.0.2.15/queue")) == nil)
    }

    // MARK: Where they're asked (PrintMac's reader, its network part)

    private static func queue(_ uri: String) -> CupsDestination {
        CupsDestination(name: "Q", options: ["device-uri": uri, "printer-type": "4", "printer-state": "3"])
    }

    @Test func anIppUsbQueueIsAUsbPrinter() {
        let d = Self.queue("ippusb://Demo%20Laser%202100._ipp._tcp.local./")
        #expect(CupsQueues.connection(d) == .usb)
        #expect(CupsQueues.connectionText(d) == "USB")
        #expect(CupsQueues.address(d) == nil)
    }

    @Test(arguments: [
        ("ipp://localhost:8632/ipp/print", "http://localhost:8632/ipp/print"), // a local relay
        ("ipp://127.0.0.1:60000/ipp/print?waitprinter=false", "http://127.0.0.1:60000/ipp/print"),
        ("ipp://[::1]:60000/ipp/print", "http://[::1]:60000/ipp/print"),
        ("ipps://192.0.2.11/ipp/print", "https://192.0.2.11:631/ipp/print"), // IPP's port when none is given
        ("ipp://192.0.2.11", "http://192.0.2.11:631/"),
        ("http://192.0.2.11:8080/ipp", "http://192.0.2.11:8080/ipp"),
        ("ipp://admin:secret@192.0.2.11/ipp/print", "http://192.0.2.11:631/ipp/print"), // credentials never kept
        // One parse for host, port and path: the authority ends at `/`, `?` or `#`, so an `@` after it is no credential.
        ("ipp://printer.local#x", "http://printer.local:631/"),
        ("ipp://printer.local:8632#x@192.0.2.66/ipp", "http://printer.local:8632/"),
        ("ipp://printer.local?x@192.0.2.66/ipp", "http://printer.local:631/"),
        ("ipp://192.0.2.11/ipp/print@x", "http://192.0.2.11:631/ipp/print@x"),
    ])
    func aQueuesOwnAddressIsAskedOverHttp(uri: String, url: String) {
        #expect(IppQueueReading.target(Self.queue(uri)) == .url(URL(string: url)!))
    }

    @Test func aBonjourOrIppUsbQueueNamesTheServiceToResolve() {
        let usb = IppQueueReading.target(Self.queue("ippusb://Demo%20Laser%202100._ipp._tcp.local./"))
        #expect(usb == .service(instance: "Demo Laser 2100", type: "_ipp._tcp", domain: "local."))
        let dnssd = IppQueueReading.target(Self.queue("dnssd://Demo%20Inkjet._ipps._tcp.local./?uuid=2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"))
        #expect(dnssd == .service(instance: "Demo Inkjet", type: "_ipps._tcp", domain: "local."))
        let named = IppQueueReading.target(Self.queue("ipp://Demo%20Inkjet._ipp._tcp/"))
        #expect(named == .service(instance: "Demo Inkjet", type: "_ipp._tcp", domain: "local."))
    }

    @Test(arguments: [
        "ippusb://Demo%20Inkjet/ipp/print", // CUPS 2.5's make and model: only cupsd reaches it
        "usb://Demo/Inkjet?serial=DEMO1", "socket://192.0.2.15", "smb://office-pc/Laser",
        "ipp://192.0.2.11:99999/ipp/print", "ipp://192.0.2.11:80a/ipp/print", // not a port
        "ipp://192.0.2.11/ipp/../admin", "ipp://192.0.2.11/ipp\\print", // a path that leaves its place
        "ipp://bad%20host/ipp/print", "ipp://%0Aevil/ipp/print", // not a host
        "dnssd://Demo%20Printer._printer._tcp.local./", // LPD's service: no IPP
        "dnssd://._ipp._tcp.local./",
    ])
    func nothingIsAskedWithoutASoundAddress(uri: String) {
        #expect(IppQueueReading.target(Self.queue(uri)) == nil)
    }

    /// Asks once, read-only, for the attributes it needs, and reads the whole reply as the decorator expects.
    final class Transport: HttpTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var sent: [HttpRequest] = []
        private let reply: @Sendable (HttpRequest) throws -> HttpResponse

        init(_ reply: @escaping @Sendable (HttpRequest) throws -> HttpResponse) { self.reply = reply }

        var requests: [HttpRequest] { lock.withLock { sent } }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            lock.withLock { sent.append(request) }
            return try reply(request)
        }
    }

    private static func reader(_ transport: Transport, _ url: String?, usb: Bool = true) -> IppQueueDeviceReader {
        IppQueueDeviceReader(usb: usb, transport: { _, _ in transport }, endpoint: { url.flatMap(URL.init(string:)) })
    }

    @Test func theReaderAsksTheQueuesPrinterOnceForItsStatusAndSupplies() async throws {
        let body = try Self.wholeResponse(try Self.fixtureText())
        let transport = Transport { _ in HttpResponse(status: 200, headers: ["Content-Type": "application/ipp"], body: body) }

        let r = try #require(try await Self.reader(transport, "http://localhost:8632/ipp/print").read())

        #expect(r.from == .printerOverUsb)
        #expect(r.supplies.count == 5)
        let request = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "http://localhost:8632/ipp/print")
        #expect(request.header("Content-Type") == "application/ipp")
        #expect(request.once)
        #expect(request.replyLimit == IppQueueReading.maxBytes)
        #expect(request.body == IppCodec.encodeGetPrinterAttributes("ipp://localhost:8632/ipp/print", IppQueueReading.attributes))
    }

    /// A Bonjour queue's resolve and then its request fit in one call's limit, so a slow resolve can't leave the request cut
    /// off by `DeviceQueueStatus` with its answer on the way.
    @Test func aResolveAndItsRequestFitInOneCall() async throws {
        #expect(IppQueueReading.resolveLimit + IppQueueReading.requestLimit < DeviceQueueStatus.callLimit)
        let transport = Transport { _ in HttpResponse(status: 404) }
        _ = try await Self.reader(transport, "http://localhost:8632/ipp/print").read()
        #expect(transport.requests.first?.timeout == IppQueueReading.requestLimit)
    }

    @Test func noAddressAnErrorPageOrARefusalIsNothing() async throws {
        let refused = try Self.wholeResponse(try Self.fixtureText(), status: 0x0401)
        let pages = [HttpResponse(status: 404), HttpResponse(status: 500, body: Array("<html>".utf8)), HttpResponse(status: 200, body: refused)]
        for page in pages {
            #expect(try await Self.reader(Transport { _ in page }, "http://192.0.2.11:631/ipp/print", usb: false).read() == nil)
        }
        let unused = Transport { _ in HttpResponse(status: 200) }
        #expect(try await Self.reader(unused, nil).read() == nil)
        #expect(unused.requests.isEmpty)
    }

    @Test func aPrinterThatDoesntAnswerThrowsSoTheDecoratorAsksLater() async {
        let reader = Self.reader(Transport { _ in throw DeviceNetworkError.refused }, "http://localhost:8632/ipp/print")
        await #expect(throws: DeviceNetworkError.self) { try await reader.read() }
    }

    @Test func theSuppliesLineWithoutAReaderIsTheSameAsWithOne() {
        let none = QueueStatusRead(status: Self.ready, offline: false, supplies: [])
        let offline = QueueStatusRead(status: Self.ready, offline: true, supplies: [])
        let cupsd = QueueStatusRead(status: Self.ready, offline: false, supplies: [Consumable(name: "Black Toner", kind: "toner", colorCode: "K", percentRemaining: 40, state: "ok")])
        #expect(QueueDeviceText.suppliesSource(none, from: nil) == "Not reported by this printer.")
        #expect(QueueDeviceText.suppliesSource(offline, from: nil) == nil)
        #expect(QueueDeviceText.suppliesSource(cupsd, from: nil) == nil) // cupsd's copy: no line, as before
        #expect(QueueDeviceText.suppliesSource(cupsd, from: .printerOverUsb) == "From the printer over USB")
    }

    @Test func theQueuePrintersCardSaysWhereItsStatusAndLevelsCameFrom() async throws {
        let d = try #require(Demo.destinations.first { $0.name == DemoQueueDevice.usbLaserQueue })
        #expect(IppQueueReading.route(d) == .printerOverUsb)
        #expect(Demo.destinations.filter { !DemoQueueDevice.readers(for: $0).isEmpty }.map(\.name) == [DemoQueueDevice.usbLaserQueue])
        let source = DeviceQueueStatus(readers: DemoQueueDevice.readers(for: d))

        let read = try #require(await source.read(QueueStatusRead.of(d)))
        let v = CupsStatus.view(d, read: read, origin: await source.origin, suppliesSource: await source.suppliesSource(read))

        #expect(v.statusOrigin == "the printer over USB (IPP)")
        #expect(v.suppliesSource == "From the printer over USB")
        #expect(v.supplies.map(\.percentRemaining) == [11, 64]) // the printer's own: its drum, which cupsd doesn't have
        #expect(v.interfaces == ["USB"])
        #expect(CupsStatus.snapshot(d, id: "q", read: read).supplies?.count == 2)
    }
}
