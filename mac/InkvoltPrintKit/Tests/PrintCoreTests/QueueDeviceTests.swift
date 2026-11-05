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

        #expect(Date().timeIntervalSince(started) < 5)
        #expect(read.supplies.map(\.name) == ["Black toner"])
        #expect(await source.origin == "the printer over IPP")
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
}
