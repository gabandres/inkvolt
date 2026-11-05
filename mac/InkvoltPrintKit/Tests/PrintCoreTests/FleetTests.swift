import Foundation
import Testing
@testable import PrintCore

/// The Fleet page's list (Print roadmap 2.6): every printer's state, supplies, pages, firmware and last reading, most trouble
/// first, and its CSV and JSON. Ported from FleetTests.cs with the same names. Adapted: times are `Date`s written in UTC
/// (the export takes the Mac's time zone, the tests UTC); Swift's strings can't hold half a surrogate pair (decoding one
/// gives U+FFFD), so the two tests that plant one plant U+FFFD's neighbours instead and check the pair rule on whole pairs.
/// Left out: The_command_palette_offers_the_page (the Windows palette), The_state_file_gives_what_a_read_without_the_app_needs
/// and A_state_file_from_before_these_fields_still_reads (Windows' state.json; `status --all` on the Mac reads its own
/// state, with the Mac's half of 2.6).
struct FleetTests {
    static let now = Date(timeIntervalSince1970: 1_793_448_000) // 2026-10-31 12:00:00 UTC
    static let utc = TimeZone(identifier: "UTC")!
    static let me = Diagnostics.Identity("jdoe", "JDOE-LAPTOP")

    static func supply(_ name: String, _ level: Int?, _ state: String = "ok", color: String? = "K", kind: String = "toner") -> Consumable {
        Consumable(name: name, kind: kind, colorCode: color, percentRemaining: level, state: state)
    }

    static func status(_ message: String, _ severity: Severity = .info, _ alerts: [PrinterAlert] = []) -> PrinterStatus {
        PrinterStatus(code: "x", message: message, severity: severity, alerts: alerts)
    }

    static func printer(_ name: String, reachable: Bool = true, status: PrinterStatus? = nil, supplies: [Consumable] = [], pages: Int? = nil,
                        firmware: String? = nil, read: Date? = nil, kind: FleetKind = .network) -> FleetPrinter {
        var f = FleetFacts(name, name, kind)
        f.reachable = reachable
        f.status = status ?? Self.status("Ready")
        f.supplies = supplies
        f.pages = pages
        f.firmware = firmware
        f.lastReading = read
        return FleetPrinter.of(f)
    }

    static func csv(_ printers: [FleetPrinter]) -> String { FleetExport.csv(printers, now, me, timeZone: utc) }
    static func json(_ printers: [FleetPrinter], _ notes: [String] = []) -> String { FleetExport.json(printers, notes, now, me, timeZone: utc) }

    // ------------------------------------------------------------------ trouble and order

    @Test(arguments: [(Severity.error, FleetTrouble.error), (.warning, .warning), (.info, .ok)])
    func The_status_sets_the_trouble(_ severity: Severity, _ expected: FleetTrouble) {
        #expect(Self.printer("P", status: Self.status("Words", severity)).trouble == expected)
    }

    @Test func A_low_supply_is_a_warning_and_an_empty_one_an_error_on_a_printer_that_says_ready() {
        #expect(Self.printer("P", supplies: [Self.supply("Black", 8, "low")]).trouble == .warning)
        #expect(Self.printer("P", supplies: [Self.supply("Black", 0, "out")]).trouble == .error)
        #expect(Self.printer("P", supplies: [Self.supply("Waste", nil, "full", color: nil, kind: "wasteToner")]).trouble == .error)
        #expect(Self.printer("P", supplies: [Self.supply("Black", 80)]).trouble == .ok)
    }

    @Test func A_supply_at_zero_is_an_error_as_on_the_tray_whatever_its_state_says() {
        #expect(Self.printer("P", supplies: [Self.supply("Black", 0)]).trouble == .error)
        #expect(Self.printer("P", supplies: [Self.supply("Waste", 0, "ok", color: nil, kind: "wasteToner")]).trouble == .ok) // an empty waste box is fine
    }

    @Test func A_shared_queues_export_doesnt_name_the_pc_sharing_it() {
        var sharedFacts = FleetFacts("q", "Reception laser on FRONTDESK", .queue)
        sharedFacts.reachable = true
        sharedFacts.status = Self.status("Ready")
        sharedFacts.connection = FleetConnection.shared
        var usbFacts = FleetFacts("u", "Printer on desk", .queue)
        usbFacts.reachable = true
        usbFacts.status = Self.status("Ready")
        usbFacts.connection = "USB"
        let shared = FleetPrinter.of(sharedFacts), usb = FleetPrinter.of(usbFacts)

        let csv = Self.csv([shared, usb])
        #expect(!csv.contains("FRONTDESK"))
        #expect(csv.contains("Reception laser on [pc]"))
        #expect(csv.contains("Printer on desk"))
        #expect(!Self.json([shared]).contains("FRONTDESK"))
        // macOS names another Mac's shared queue "Name @ Computer".
        var mac = sharedFacts
        mac.name = "Reception laser @ Front Desk iMac"
        #expect(!Self.csv([FleetPrinter.of(mac)]).contains("Front Desk"))
    }

    @Test func A_printer_that_doesnt_answer_is_offline_whatever_its_last_supplies_said() {
        let p = Self.printer("P", reachable: false, status: Self.status("Can't reach the printer", .error), supplies: [Self.supply("Black", 0, "out")])
        #expect(p.trouble == .offline)
    }

    @Test func A_reply_with_no_usable_status_is_unknown_not_fine() {
        var f = FleetFacts("P", "P", .network)
        f.reachable = true
        f.status = .unavailable("Busy")
        #expect(FleetPrinter.of(f).trouble == .unknown)
    }

    @Test func Sorted_by_trouble_as_the_tray_ranks_it_then_by_name() {
        var unknown = FleetFacts("U", "Unknown", .network)
        unknown.reachable = true
        unknown.status = .unavailable("Busy")
        let sorted = FleetOrder.sort([
            Self.printer("zeta fine"), Self.printer("Beta low", supplies: [Self.supply("Black", 5, "low")]),
            Self.printer("Off", reachable: false), Self.printer("Jam", status: Self.status("Paper jam", .error)),
            FleetPrinter.of(unknown),
            Self.printer("alpha low", supplies: [Self.supply("Black", 5, "low")]), Self.printer("Alpha fine"),
        ])
        #expect(sorted.map(\.name) == ["Jam", "alpha low", "Beta low", "Off", "Unknown", "Alpha fine", "zeta fine"])
    }

    @Test func Two_printers_of_one_name_keep_one_order() {
        var fa = FleetFacts("b-id", "Same", .network), fb = FleetFacts("a-id", "Same", .network)
        (fa.reachable, fb.reachable) = (true, true)
        (fa.status, fb.status) = (Self.status("Ready"), Self.status("Ready"))
        let a = FleetPrinter.of(fa), b = FleetPrinter.of(fb)
        #expect(FleetOrder.sort([a, b]).map(\.id) == ["a-id", "b-id"])
        #expect(FleetOrder.sort([b, a]).map(\.id) == ["a-id", "b-id"])
    }

    // ------------------------------------------------------------------ what a printer may say

    @Test(arguments: [
        ("Plain", "Plain"),
        ("  spaced   out \r\n name ", "spaced out name"),
        ("left\u{202E}right\u{202C}", "leftright"), // right-to-left override: would turn the line round on screen
        ("zero\u{200B}width\u{FEFF}", "zerowidth"),
        ("bell\u{07}and\u{1B}escape", "bellandescape"),
        ("two\u{2028}lines", "two lines"),
    ])
    func Printer_supplied_text_loses_what_could_change_how_a_line_reads(_ text: String, _ expected: String) {
        #expect(FleetText.clean(text, 240) == expected)
    }

    @Test func Printer_supplied_text_is_bounded_and_keeps_surrogate_pairs_whole() {
        #expect(FleetText.clean(String(repeating: "x", count: 5000), 10)?.utf16.count == 10)
        #expect(FleetText.clean("xxxxxxxx😀😀😀", 10) == "xxxxxxxx…") // 8 + the ellipsis: the pair isn't cut in half
        // Half a pair can't reach a Swift string: decoding one gives U+FFFD, which is kept as the visible mark it is.
        #expect(FleetText.clean(String(decoding: [0x61, 0xD83D, 0x62] as [UInt16], as: UTF16.self), 240) == "a\u{FFFD}b")
        #expect(FleetText.clean("\u{07}\u{200B} ", 240) == nil)
    }

    @Test func A_name_of_nothing_still_names_the_printer() {
        let p = Self.printer("\u{200B}\u{07}")
        #expect(!p.name.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func A_printers_lists_and_numbers_are_bounded() {
        var f = FleetFacts("P", "P", .network)
        f.reachable = true
        f.status = Self.status("Words", .warning, (0..<100).map { PrinterAlert(id: "a\($0)", severity: .warning, message: "Alert \($0)") })
        f.supplies = (0..<100).map { Self.supply("Supply \($0)", 50) } + [Self.supply("Over", 250), Self.supply("Under", -3)]
        f.pages = -5
        let p = FleetPrinter.of(f)
        #expect(p.problems.count == 16)
        #expect(p.supplies.count == 16)
        #expect(p.pages == nil)
        var g = FleetFacts("P", "P", .network)
        g.reachable = true
        g.status = Self.status("R")
        g.supplies = [Self.supply("Over", 250), Self.supply("Under", -3)]
        #expect(FleetPrinter.of(g).supplies.map(\.level) == [100, nil])
    }

    @Test func Information_alerts_arent_problems() {
        let p = Self.printer("P", status: Self.status("Ready", .warning, [PrinterAlert(id: "a", severity: .info, message: "Genuine HP supply"),
                                                                         PrinterAlert(id: "b", severity: .warning, message: "Tray 2 is low on paper")]))
        #expect(p.problems == ["Tray 2 is low on paper"])
    }

    // ------------------------------------------------------------------ CSV

    @Test(arguments: ["=HYPERLINK(\"http://x\")", "+1+1", "-2+3", "@SUM(A1)", "\t=1+1", "\r=1+1", " =1+1", "\u{200B}=1+1",
                      "\u{FF1D}1+1", "\u{FF0B}1", "\u{FF0D}1", "\u{FF20}1"])
    func Nothing_a_printer_says_reaches_a_spreadsheet_as_a_formula(_ evil: String) {
        var f = FleetFacts("P", evil, .network)
        f.model = evil
        f.reachable = true
        f.status = PrinterStatus(code: "error", message: evil, severity: .error, alerts: [PrinterAlert(id: "a", severity: .error, message: evil)])
        f.supplies = [Self.supply(evil, 50, color: evil)]
        f.firmware = evil

        let lines = Self.csv([FleetPrinter.of(f)]).components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines.count == 2)
        for cell in Self.cells(lines[1]) {
            let starts = "=+-@\t\r\n\u{FF1D}\u{FF0B}\u{FF0D}\u{FF20}".unicodeScalars
            let first = cell.unicodeScalars.first
            #expect(!(first.map { starts.contains($0) } ?? false) || Int(cell) != nil, "A formula's start: \(cell)")
        }
    }

    /// RFC 4180's cells of one line.
    static func cells(_ line: String) -> [String] {
        var cells: [String] = []
        var cell = ""
        var quoted = false
        let chars = Array(line.unicodeScalars)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if quoted && c == "\"" && i + 1 < chars.count && chars[i + 1] == "\"" {
                cell.unicodeScalars.append("\"")
                i += 1
            } else if c == "\"" {
                quoted.toggle()
            } else if c == "," && !quoted {
                cells.append(cell)
                cell = ""
            } else {
                cell.unicodeScalars.append(c)
            }
            i += 1
        }
        cells.append(cell)
        return cells
    }

    @Test func The_csv_has_a_row_per_supply_and_quotes_what_needs_it() throws {
        let csv = Self.csv([
            Self.printer("Laser, 2nd \"floor\"", status: Self.status("Ready"), supplies: [Self.supply("Black", 42), Self.supply("Cyan", 7, "low", color: "C")],
                         pages: 12345, firmware: "2024-08-13", read: Self.now),
            Self.printer("USB", kind: .queue),
        ])
        let lines = csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        #expect(lines[0] == "Printer,Model,Kind,State,Status,Problems,Supply,Color,Level %,Supply state,Pages printed,Firmware,Last reading")
        try #require(lines.count == 4)
        let cells = Self.cells(lines[1])
        #expect(cells[0] == "Laser, 2nd \"floor\"")
        #expect([cells[3], cells[6], cells[7], cells[8], cells[9], cells[10], cells[11], cells[12]]
            == ["warning", "Black", "K", "42", "ok", "12345", "2024-08-13", "2026-10-31T12:00:00+00:00"])
        #expect(Self.cells(lines[3])[0] == "USB")
        #expect(Self.cells(lines[3])[6] == "")
    }

    @Test func Identifiers_in_names_and_status_strings_stay_out_of_the_csv_and_the_json() {
        let serial = "CNB7K2M9QZ", uuid = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f", mac = "a0:b1:c2:d3:e4:f5", ip = "10.20.30.41"
        var f = FleetFacts(uuid, "LaserJet \(serial) [A1B2C3]", .network)
        f.model = "LaserJet, SN:\(serial), at \(ip)"
        f.connection = "LEDM at \(ip)"
        f.reachable = true
        f.status = PrinterStatus(code: "error", message: "Ask jane.doe@contoso.com at \(ip)", severity: .error,
                                 alerts: [PrinterAlert(id: "a", severity: .error, message: "Job from JDOE-LAPTOP (\(mac)) \(uuid)")])
        f.supplies = [Self.supply("Black serial \(serial)", 50, color: "K"), Self.supply("Cyan", 50, serial, color: serial)]
        f.firmware = "TJP1FN2405AR \(uuid)"
        let printer = FleetPrinter.of(f)

        for text in [Self.csv([printer]), Self.json([printer])] {
            for secret in [serial, uuid, mac, ip, "A1B2C3", "jane.doe", "contoso", "JDOE-LAPTOP"] {
                #expect(text.range(of: secret, options: .caseInsensitive) == nil, "\(secret) got out")
            }
            #expect(text.contains("TJP1FN2405AR")) // a firmware version stays
        }
    }

    @Test(arguments: ["2.84.1.3-202606111700 (2026-07-24)", "TJP1FN2405AR", "05.12.XA01", "2024-08-13"])
    func A_firmware_version_comes_through_as_the_printer_gave_it(_ version: String) {
        let printer = Self.printer("P", firmware: version)
        #expect(Self.json([printer]).contains(version))
        #expect(Self.csv([printer]).contains(version))
    }

    // ------------------------------------------------------------------ JSON

    static func schema() throws -> JsonValue {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/FleetTests.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return try JsonValue.parse(String(decoding: try Data(contentsOf: url.appendingPathComponent("print/schemas/fleet-status.schema.json")), as: UTF8.self))
    }

    static func validate(_ json: String) throws -> [String] { try JsonSchemaCheck.errors(try schema(), try JsonValue.parse(json)) }

    @Test func The_json_validates_against_the_schema_in_the_repository() throws {
        var scanner = FleetFacts("S", "Scanner", .scanner)
        scanner.status = Self.status("Scanner not answering")
        scanner.lastReadingDay = Day(2026, 10, 29)
        scanner.lastKnown = true
        let json = Self.json([
            Self.printer("Jam", status: Self.status("Paper jam", .error, [PrinterAlert(id: "a", severity: .error, message: "Paper jam in tray 2")]), read: Self.now),
            Self.printer("Laser", supplies: [Self.supply("Black", 42), Self.supply("Waste", nil, "almostFull", color: nil, kind: "wasteToner")],
                         pages: 12345, firmware: "2024-08-13", read: Self.now),
            Self.printer("USB", kind: .queue),
            FleetPrinter.of(scanner),
        ], ["The Mac's scanners couldn't be read."])

        #expect(try Self.validate(json) == [])
    }

    @Test(arguments: [
        #"{"version":2,"generated":"2026-10-31T12:00:00+00:00","notes":[],"printers":[]}"#, // another version
        #"{"version":1,"generated":"yesterday","notes":[],"printers":[]}"#, // not a time
        #"{"version":1,"generated":"2026-10-31T12:00:00+00:00","notes":[]}"#, // printers missing
        #"{"version":1,"generated":"2026-10-31T12:00:00+00:00","notes":[],"printers":[],"uuid":"x"}"#, // an extra field
    ])
    func The_schema_check_refuses_what_it_should(_ json: String) throws {
        #expect(try !Self.validate(json).isEmpty)
    }

    @Test func The_schema_says_no_serial_number_or_uuid_field_exists() throws {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let names = String(decoding: try Data(contentsOf: url.appendingPathComponent("print/schemas/fleet-status.schema.json")), as: UTF8.self)
        for word in ["\"serial", "\"uuid", "\"host", "\"address", "\"mac"] {
            #expect(names.range(of: word, options: .caseInsensitive) == nil)
        }
    }

    @Test func Control_characters_and_lone_surrogates_cant_break_the_json() throws {
        let json = Self.json([Self.printer("a\"b\\c\n\u{0}\u{FFFF}</script>")])

        let doc = try JsonValue.parse(json)
        #expect(doc["printers"]?[0]?["name"]?.string == "a\"b\\c </script>")
        #expect(json.unicodeScalars.allSatisfy { $0.value < 128 }, "ASCII only, so no terminal's encoding can spoil it")
        #expect(try Self.validate(json) == [])
    }

    // ------------------------------------------------------------------ the page's words

    @Test func The_page_says_each_printers_supplies_pages_firmware_and_last_reading() throws {
        let row = FleetPage.row(Self.printer("Laser", supplies: [Self.supply("Black", 42)], pages: 12345, firmware: "2024-08-13",
                                             read: Self.now.addingTimeInterval(-180)), Self.now)

        try #require(row.supplies.count == 1)
        #expect(row.supplies[0].text == "Black 42%")
        #expect(row.supplies[0].level == 42)
        #expect(row.pagesText.contains("12,345"))
        #expect(row.firmwareText == "Firmware 2024-08-13")
        #expect(row.lastReadText == "Read 3 minutes ago")
        for part in ["Laser", "Black 42%", "12,345", "Firmware 2024-08-13", "3 minutes ago"] { #expect(row.accessibleText.contains(part)) }
    }

    @Test func The_page_says_what_a_printer_doesnt_report_rather_than_leaving_a_gap() {
        let row = FleetPage.row(Self.printer("USB", reachable: false, status: Self.status("Offline")), Self.now)

        #expect(row.pagesText == "Pages not reported")
        #expect(row.firmwareText == "Firmware not reported")
        #expect(row.lastReadText == "Not read yet")
        #expect(row.noSuppliesText == "Supplies not reported")
    }

    @Test(arguments: [(0, "Read just now"), (59, "Read just now"), (60, "Read 1 minute ago"), (45 * 60, "Read 45 minutes ago"),
                      (61 * 60, "Read 1 hour ago"), (5 * 3600, "Read 5 hours ago")] as [(Int, String)]) // typed: Xcode took 194 ms over it
    func The_last_reading_reads_as_time_ago(_ seconds: Int, _ expected: String) {
        #expect(FleetPage.row(Self.printer("P", read: Self.now.addingTimeInterval(-Double(seconds))), Self.now).lastReadText == expected)
    }

    @Test func A_clock_put_back_doesnt_say_minus_minutes() {
        #expect(FleetPage.row(Self.printer("P", read: Self.now.addingTimeInterval(7200)), Self.now).lastReadText == "Read just now")
    }

    @Test func A_reading_from_days_ago_gives_its_day() {
        var f = FleetFacts("P", "P", .network)
        f.status = Self.status("Off")
        f.lastReadingDay = Day(2026, 10, 29)
        f.lastKnown = true
        let text = FleetPage.row(FleetPrinter.of(f), Self.now).lastReadText
        #expect(text.hasPrefix("Last read "))
        #expect(text.contains("2026"))
    }

    @Test func The_summary_counts_the_trouble() {
        #expect(FleetPage.summary([Self.printer("A", status: Self.status("Jam", .error)), Self.printer("B", status: Self.status("Low", .warning)), Self.printer("C")])
            == "3 printers: 1 with an error, 1 needing attention, 1 fine.")
        #expect(FleetPage.summary([Self.printer("A", reachable: false)]) == "1 printer: 1 can't be reached.")
        #expect(FleetPage.summary([]) == "No printers yet.")
    }

    // ------------------------------------------------------------------ last known, from the supply history

    @Test func The_supply_history_gives_a_silent_printers_last_levels_day_and_page_count() throws {
        let store = SupplyHistoryStore(nil)
        _ = store.record("p", [Self.supply("Black", 80)], 100, Day(2026, 10, 20))
        _ = store.record("p", [Self.supply("Black", 70), Self.supply("Cyan", 60, color: "C")], 200, Day(2026, 10, 29))

        let known = try #require(FleetLastKnown.from(store.rows("p")))

        #expect(known.day == Day(2026, 10, 29))
        #expect(known.pages == 200)
        #expect(known.supplies.map { "\($0.name) \($0.percentRemaining ?? -1)" } == ["Black 70", "Cyan 60"])
        #expect(FleetLastKnown.from([]) == nil)
    }

    @Test func A_cartridge_taken_out_days_ago_isnt_listed_as_there_now() {
        let store = SupplyHistoryStore(nil)
        _ = store.record("p", [Self.supply("Old", 80), Self.supply("Black", 80)], nil, Day(2026, 10, 20))
        _ = store.record("p", [Self.supply("Black", 70)], nil, Day(2026, 10, 29))

        #expect(FleetLastKnown.from(store.rows("p"))?.supplies.map(\.name) == ["Black"])
    }
}
