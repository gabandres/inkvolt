import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Ported from FirmwareWatchTests.cs. Firmware watch (roadmap 1.5): the version remembered per printer, a change noticed
/// once and alerted once, and "Keep my cartridges working", whose write is the Firmware card's own Off write. No request here
/// reaches a printer: the LEDM side runs against the M234dw's captured documents in memory. Adapted: .NET's `DateOnly` is
/// `Day`; `Assert.Same` on records is equality (they are values here); the fixture XML is edited as text (`XmlElement` is
/// read-only), as FirmwareTests does.
struct FirmwareWatchTests {
    private static let printer = "12345678-1234-4abc-8def-123456789abc"
    private static let day0 = Day(2026, 10, 1)
    private static let zone = TimeZone(identifier: "UTC")!

    /// The M234dw's own firmware reading, with the revision a firmware update would bring.
    private static func versionFromFixture(_ revision: String?) throws -> String {
        var product = LedmParsers.parseProductConfig(try DeviceXml.load(Fixtures.data("m234dw/DevMgmt_ProductConfigDyn.xml")))
        if let revision { product.firmwareRevision = revision }
        return try #require(FirmwareInfo.from(product, nil)).display
    }

    // MARK: The record

    @Test func The_first_version_seen_is_remembered_with_its_day_and_is_no_change() {
        let record = FirmwareWatch.observe(nil, "2024-08-13", Self.day0)

        #expect(record == FirmwareRecord("2024-08-13", Self.day0))
        #expect(FirmwareWatch.notice(record, Self.day0) == nil)
    }

    @Test func The_same_version_again_keeps_the_record_as_it_was() {
        let record = FirmwareWatch.observe(nil, "2024-08-13", Self.day0)

        #expect(FirmwareWatch.observe(record, "2024-08-13", Self.day0.adding(days: 40)) == record)
        #expect(FirmwareWatch.observe(record, nil, Self.day0.adding(days: 41)) == record) // not read this time: tells nothing
        #expect(FirmwareWatch.observe(record, "  ", Self.day0.adding(days: 42)) == record)
    }

    @Test func A_new_version_is_a_change_in_plain_words() throws {
        let record = FirmwareWatch.observe(FirmwareWatch.observe(nil, "05.12.XA01", Self.day0), "05.14.XB02", Self.day0.adding(days: 11))

        let notice = try #require(FirmwareWatch.notice(record, Self.day0.adding(days: 11)))

        #expect(notice == FirmwareChange("05.12.XA01", "05.14.XB02", Self.day0.adding(days: 11)))
        #expect(notice.text == "Firmware changed from 05.12.XA01 to 05.14.XB02 on \(Self.day0.adding(days: 11).longText).")
        #expect(Self.day0.adding(days: 11) == Day(2026, 10, 12))
    }

    @Test func The_notice_goes_after_thirty_days_or_when_dismissed() throws {
        let record = try #require(FirmwareWatch.observe(FirmwareWatch.observe(nil, "A", Self.day0), "B", Self.day0.adding(days: 1)))

        #expect(FirmwareWatch.notice(record, Self.day0.adding(days: FirmwareWatch.noticeDays)) != nil)
        #expect(FirmwareWatch.notice(record, Self.day0.adding(days: 1 + FirmwareWatch.noticeDays)) == nil)
        var dismissed = record
        dismissed.dismissed = true
        #expect(FirmwareWatch.notice(dismissed, Self.day0.adding(days: 2)) == nil)
    }

    @Test func A_dismissed_change_stays_dismissed_until_the_next_change() throws {
        var dismissed = try #require(FirmwareWatch.observe(FirmwareWatch.observe(nil, "A", Self.day0), "B", Self.day0.adding(days: 1)))
        dismissed.dismissed = true

        #expect(FirmwareWatch.observe(dismissed, "B", Self.day0.adding(days: 2)) == dismissed)
        let next = FirmwareWatch.observe(dismissed, "C", Self.day0.adding(days: 3))
        #expect(FirmwareWatch.notice(next, Self.day0.adding(days: 3)) == FirmwareChange("B", "C", Self.day0.adding(days: 3)))
    }

    @Test func What_a_printer_reports_is_cleaned_before_it_is_kept() throws {
        let record = try #require(FirmwareWatch.observe(nil, " 1.0\r\n" + String(repeating: "9", count: 200), Self.day0))

        #expect(!record.version.contains("\n"))
        #expect(record.version.count == 80)
    }

    /// A Mac addition: `Day` stands for .NET's `DateOnly`, so its arithmetic is checked here.
    @Test func Days_count_through_month_ends_and_leap_years() throws {
        var day = Day(1999, 12, 25)
        for _ in 0..<(366 * 5) {
            let next = day.adding(days: 1)
            #expect(next.dayNumber == day.dayNumber + 1)
            #expect(Day(dayNumber: next.dayNumber) == next)
            #expect(next.day == 1 || next.day == day.day + 1, "\(day) → \(next)")
            day = next
        }
        #expect(Day(2024, 2, 28).adding(days: 1) == Day(2024, 2, 29))
        #expect(Day(2026, 10, 1).adding(days: 30) == Day(2026, 10, 31))
        #expect(Day(1, 1, 1).dayNumber == 0)
        let json = try JSONEncoder().encode(Day(2026, 3, 7))
        #expect(String(decoding: json, as: UTF8.self) == "\"2026-03-07\"")
        #expect(try JSONDecoder().decode(Day.self, from: json) == Day(2026, 3, 7))
    }

    // MARK: Readings → one notice, one alert

    private static func snapshot(_ change: FirmwareChange?) -> PrinterSnapshot {
        PrinterSnapshot(uuid: printer, name: "Office laser", reachable: true, status: PrinterStatus(code: "ready", message: "Ready", severity: .info, alerts: []),
                        supplies: [], firmwareChange: change)
    }

    @Test func Fixture_readings_with_a_version_change_give_one_notice_and_one_alert_never_again_for_that_change() throws {
        let old = try Self.versionFromFixture(nil), updated = try Self.versionFromFixture("SAYPRO1N002.2101A")
        let readings = [old, old, updated, updated, updated, updated]
        let tracker = AlertTracker(rules: AlertRules(), timeZone: Self.zone)
        var record: FirmwareRecord?
        var notices: [FirmwareChange] = []
        var alerts: [AlertNotice] = []
        let now = Date(timeIntervalSince1970: 1_790_845_200) // 2026-10-01 09:00 UTC

        for (i, reading) in readings.enumerated() {
            let day = Self.day0.adding(days: i)
            let before = record
            record = FirmwareWatch.observe(record, reading, day)
            if before != record, let change = FirmwareWatch.notice(record, day) { notices.append(change) }
            alerts += tracker.observe(Self.snapshot(FirmwareWatch.notice(record, day)), now: now.addingTimeInterval(Double(i) * 86_400))
        }

        try #require(notices.count == 1)
        #expect((notices[0].from, notices[0].to) == (old, updated))
        try #require(alerts.count == 1)
        #expect(alerts[0].kind == .firmwareChanged)
        #expect(alerts[0].title == "Office laser: firmware changed")
        #expect(alerts[0].body.hasPrefix(notices[0].text))

        // Started again (the alerts shown are kept across restarts): the same change isn't told again.
        let again = AlertTracker(rules: AlertRules(), shown: tracker.shown(), timeZone: Self.zone)
        #expect(again.observe(Self.snapshot(FirmwareWatch.notice(record, Self.day0.adding(days: 6))), now: now.addingTimeInterval(6 * 86_400)).isEmpty)
    }

    @Test func A_firmware_change_is_news_not_a_problem_for_the_tray() {
        let tracker = AlertTracker(rules: AlertRules(), timeZone: Self.zone)

        _ = tracker.observe(Self.snapshot(FirmwareChange("A", "B", Self.day0)), now: Date())

        #expect(tracker.level(Self.printer) == .ok)
        #expect(tracker.problem(Self.printer) == nil)
    }

    @Test func With_alerts_off_or_paused_the_change_isnt_told_later() {
        var off = AlertRules()
        off.enabled = false
        let tracker = AlertTracker(rules: off, timeZone: Self.zone)
        let now = Date()
        #expect(tracker.observe(Self.snapshot(FirmwareChange("A", "B", Self.day0)), now: now).isEmpty)

        tracker.rules = AlertRules()
        #expect(tracker.observe(Self.snapshot(FirmwareChange("A", "B", Self.day0)), now: now.addingTimeInterval(300)).isEmpty)
    }

    @Test func An_unreachable_printer_keeps_the_change_known() {
        let tracker = AlertTracker(rules: AlertRules(), timeZone: Self.zone)
        let now = Date()
        #expect(tracker.observe(Self.snapshot(FirmwareChange("A", "B", Self.day0)), now: now).count == 1)

        _ = tracker.observe(PrinterSnapshot(uuid: Self.printer, name: "Office laser", reachable: false, status: nil, supplies: nil), now: now.addingTimeInterval(60))

        #expect(!tracker.observe(Self.snapshot(FirmwareChange("A", "B", Self.day0)), now: now.addingTimeInterval(120)).contains { $0.kind == .firmwareChanged })
    }

    // MARK: Keep my cartridges working

    private static func run(_ hp: FakeHp, _ withAuth: (@Sendable () async throws -> Void) async throws -> Void = { try await $0() }) async throws -> CartridgeGuardResult {
        let ledm = LedmClient(hp.http())
        let settings = try #require(try await ledm.firmwareUpdate())
        return try await CartridgeGuard.keepCartridgesWorking(ledm, settings, withAuth: withAuth)
    }

    @Test func Keep_my_cartridges_working_writes_the_firmware_cards_off_byte_for_byte_and_reads_it_back() async throws {
        let settingsWrite = FakeHp(.automatic)
        let ledm = LedmClient(settingsWrite.http())
        let fw = try #require(try await ledm.firmwareUpdate())
        try await ledm.put(path: try #require(fw.configPath), fw.buildPut(.off)) // the Firmware card saving Off

        let guarded = FakeHp(.automatic)
        let result = try await Self.run(guarded)

        let writes = guarded.writes, cardWrites = settingsWrite.writes
        try #require(writes.count == 1 && cardWrites.count == 1)
        #expect(writes[0] == cardWrites[0])
        #expect(writes[0].scheme == "https" && writes[0].path == "/FirmwareUpdate/WebFWUpdate/Config")
        let values = try DeviceXml.load(Array(writes[0].body.utf8)).children.map(\.value)
        #expect(values == ["disabled", "disabled"])
        #expect(result.outcome == .done)
        #expect(result.readBack == .off)
        #expect(result.text.hasPrefix("Done: automatic firmware updates are off"))
    }

    @Test func Already_off_writes_nothing() async throws {
        let printer = FakeHp(.off)
        let result = try await Self.run(printer)

        #expect(result.outcome == .alreadyOff)
        #expect(printer.writes.isEmpty)
    }

    @Test func A_printer_that_wont_let_apps_change_it_gets_its_web_page_named_and_nothing_written() async throws {
        let printer = FakeHp(.automatic, readOnly: true)
        let result = try await Self.run(printer)

        #expect(result.outcome == .cantChange)
        #expect(result.text.contains("web page"))
        #expect(printer.writes.isEmpty)
    }

    @Test func A_printer_that_keeps_installing_is_reported_as_it_reads_back() async throws {
        let printer = FakeHp(.automatic, ignoresWrites: true)
        let result = try await Self.run(printer)

        #expect(result.outcome == .notKept)
        #expect(result.readBack == .automatic)
        #expect(result.text.contains("\"install automatically\""))
    }

    @Test func The_write_goes_through_the_password_step() async throws {
        let printer = FakeHp(.notify)
        printer.wantsPassword = true
        let asked = Mutex(0)

        let result = try await Self.run(printer) { put in
            do {
                try await put()
            } catch is LedmAuthRequiredError {
                asked.withLock { $0 += 1 }
                printer.wantsPassword = false // the password was given
                try await put()
            }
        }

        #expect(asked.withLock { $0 } == 1)
        #expect(result.outcome == .done)
    }

    /// The M234dw's captured LEDM documents with its firmware update mode set to `mode`: GETs answered from them, a PUT to the
    /// Config remembered (and taken in, unless `ignoresWrites`). Nothing leaves the process.
    final class FakeHp: HttpTransport {
        struct Write: Equatable {
            var scheme: String, path: String, body: String
        }

        private let state: Mutex<(mode: FirmwareUpdateMode, writes: [Write], wantsPassword: Bool)>
        private let readOnly: Bool, ignoresWrites: Bool

        init(_ mode: FirmwareUpdateMode, readOnly: Bool = false, ignoresWrites: Bool = false) {
            state = Mutex((mode, [], false))
            self.readOnly = readOnly
            self.ignoresWrites = ignoresWrites
        }

        var writes: [Write] { state.withLock { $0.writes } }
        var wantsPassword: Bool {
            get { state.withLock { $0.wantsPassword } }
            set { state.withLock { $0.wantsPassword = newValue } }
        }

        func http() -> DeviceHttp { DeviceHttp(host: FixtureTransport.demoHost, transport: self) }

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            let path = request.url.path
            if request.method == "PUT" {
                if wantsPassword { return HttpResponse(status: 401) }
                let body = String(decoding: request.body ?? [], as: UTF8.self)
                state.withLock { s in
                    s.writes.append(Write(scheme: request.url.scheme ?? "", path: path, body: body))
                    if !ignoresWrites {
                        let update = body.contains("AutomaticUpdate>enabled<"), check = body.contains("AutomaticCheck>enabled<")
                        s.mode = update ? .automatic : check ? .notify : .off
                    }
                }
                return HttpResponse(status: 200)
            }
            let name = FixtureTransport.documentName(path)
            guard var text = try? Fixtures.text("m234dw/\(name)") else { return HttpResponse(status: 404) }
            if name == "FirmwareUpdate_FirmwareUpdateDyn.xml" {
                let mode = state.withLock { $0.mode }
                text = text
                    .replacingOccurrences(of: "<fwudyn:AutomaticCheck>disabled<", with: "<fwudyn:AutomaticCheck>\(mode == .off ? "disabled" : "enabled")<")
                    .replacingOccurrences(of: "<fwudyn:AutomaticUpdate>disabled<", with: "<fwudyn:AutomaticUpdate>\(mode == .automatic ? "enabled" : "disabled")<")
            }
            if name == "FirmwareUpdate_FirmwareUpdateCap.xml" && readOnly {
                text = text
                    .replacingOccurrences(of: #"(<[A-Za-z0-9]+:[A-Za-z]*Support)\s+access="[^"]*""#, with: "$1", options: .regularExpression)
                    .replacingOccurrences(of: #"(<[A-Za-z0-9]+:[A-Za-z]*Support)(\s|>)"#, with: "$1 access=\"readOnly\"$2", options: .regularExpression)
            }
            return HttpResponse(status: 200, headers: ["Content-Type": "text/xml"], body: Array(text.utf8))
        }
    }
}
