import Foundation
import Testing
@testable import PrintCore

/// Ported from SupplyHistoryTests.cs. Supply history (roadmap 1.1): the local store (one row a day per supply), the forecast
/// and pages per cartridge worked out from it, the chart's data, and what a year of readings with two cartridge changes, a
/// wobble at the threshold, a week offline and SNMP's "some left" gives. Adapted: .NET's `DateOnly` is `Day`; the demo
/// year's numbers come from a seeded generator of its own (Windows' `System.Random` can't be reproduced), so its tests check
/// the year's shape as Windows' do, not its values.
final class SupplyHistoryTests {
    private static let printer = "12345678-1234-4abc-8def-123456789abc"
    private static let day0 = Day(2025, 10, 1)
    private let folder: String

    init() { folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("InkvoltHistoryTests-\(UUID().uuidString)") }
    deinit { try? FileManager.default.removeItem(atPath: folder) }

    private var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).map { (folder as NSString).appendingPathComponent($0) }
    }

    private static func toner(_ percent: Int?, state: String = "ok", name: String = "Black toner", color: String? = "K") -> Consumable {
        Consumable(name: name, kind: "toner", colorCode: color, percentRemaining: percent, state: state, productNumber: "W1340A")
    }

    private static let box = Consumable(name: "Maintenance box", kind: "wasteInk", colorCode: nil, percentRemaining: nil, state: "ok")

    private static func row(_ day: Int, _ percent: Int?, _ pages: Int? = nil) -> SupplyRow {
        SupplyRow(day0.adding(days: day), "Black toner", "K", percent, "ok", pages)
    }

    /// The year: a first cartridge from 80% down 0.5 a day, changed on day 100; a second from 100% down to the threshold,
    /// wobbling there (14, 15, 14, 15), a week offline on the way (days 200-206: no rows), changed on day 250; a third from 100%
    /// down 0.4 a day with three days of SNMP's -3 (no level, days 300-302). 10 pages printed a day throughout.
    private static func theYear() -> [SupplyRow] {
        var rows: [SupplyRow] = []
        for day in 0...364 {
            if (200...206).contains(day) { continue }
            let level: Int? = switch day {
            case ..<100: Int((80 - 0.5 * Double(day)).rounded(.toNearestOrEven))
            case ..<246: Int((100 - 85.0 * Double(day - 100) / 146).rounded(.toNearestOrEven))
            case ..<250: day % 2 == 0 ? 14 : 15
            case 300...302: nil
            default: Int((100 - 0.4 * Double(day - 250)).rounded(.toNearestOrEven))
            }
            rows.append(row(day, level, 1000 + day * 10))
        }
        return rows
    }

    // MARK: The store

    @Test func Rows_come_back_after_a_restart_exactly_as_kept() {
        let first = SupplyHistoryStore(folder)
        first.record(Self.printer, [Self.toner(45), Self.toner(60, name: "Cyan toner", color: "C")], 1234, Self.day0)
        first.record(Self.printer, [Self.toner(44), Self.toner(nil, name: "Cyan toner", color: "C")], 1250, Self.day0.adding(days: 1))

        let again = SupplyHistoryStore(folder)

        #expect(first.rows(Self.printer) == again.rows(Self.printer))
        #expect(again.rows(Self.printer) == [
            SupplyRow(Self.day0, "Black toner", "K", 45, "ok", 1234),
            SupplyRow(Self.day0, "Cyan toner", "C", 60, "ok", 1234),
            SupplyRow(Self.day0.adding(days: 1), "Black toner", "K", 44, "ok", 1250),
            SupplyRow(Self.day0.adding(days: 1), "Cyan toner", "C", nil, "ok", 1250),
        ])
    }

    @Test func One_row_a_day_per_supply_the_days_last_reading_wins() throws {
        let store = SupplyHistoryStore(folder)

        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)
        store.record(Self.printer, [Self.toner(44)], 110, Self.day0)
        store.record(Self.printer, [Self.toner(43)], 120, Self.day0)

        let rows = store.rows(Self.printer)
        try #require(rows.count == 1)
        #expect((rows[0].percent, rows[0].pages) == (43, 120))
    }

    @Test func A_reading_that_lost_its_level_or_count_keeps_what_the_day_already_knew() throws {
        let store = SupplyHistoryStore(folder)

        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)
        store.record(Self.printer, [Self.toner(nil)], nil, Self.day0)

        let rows = store.rows(Self.printer)
        try #require(rows.count == 1)
        #expect((rows[0].percent, rows[0].pages) == (45, 100))
    }

    @Test func Nothing_changed_writes_nothing() throws {
        let store = SupplyHistoryStore(folder)
        #expect(store.record(Self.printer, [Self.toner(45)], 100, Self.day0))
        let file = try #require(files.first)
        // Adapted: Windows sets the file's date to 2020 and reads it back; swift-corelibs-foundation on Windows doesn't set it,
        // so the date before and after is compared (a second apart at least, so a rewrite would show).
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)], ofItemAtPath: file)
        let before = try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date
        let content = try Data(contentsOf: URL(fileURLWithPath: file))
        Thread.sleep(forTimeInterval: 1.1)

        #expect(!store.record(Self.printer, [Self.toner(45)], 100, Self.day0))

        #expect(try FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: file)) == content)
    }

    @Test(arguments: [-1, -2, -3, 101])
    func A_special_value_is_kept_as_no_level(_ special: Int) throws {
        let store = SupplyHistoryStore(folder)

        store.record(Self.printer, [Self.toner(special)], 100, Self.day0)

        let rows = store.rows(Self.printer)
        try #require(rows.count == 1)
        #expect(rows[0].percent == nil)
    }

    @Test func Waste_boxes_are_not_kept() {
        let store = SupplyHistoryStore(folder)

        store.record(Self.printer, [Self.toner(45), Self.box], 100, Self.day0)

        #expect(store.rows(Self.printer).map(\.supply) == ["Black toner"])
    }

    @Test func Old_rows_go_after_three_years() {
        let store = SupplyHistoryStore(folder)

        for day in 0..<(SupplyHistoryStore.maxDays + 50) { store.record(Self.printer, [Self.toner(50)], day, Self.day0.adding(days: day)) }

        let rows = store.rows(Self.printer)
        #expect(rows.count == SupplyHistoryStore.maxDays + 1)
        #expect(rows.last?.day == Self.day0.adding(days: SupplyHistoryStore.maxDays + 49))
        #expect(SupplyHistoryStore(folder).rows(Self.printer) == rows)
    }

    @Test func A_printer_reporting_many_supplies_or_long_names_stays_bounded() throws {
        let store = SupplyHistoryStore(folder)
        let many = (0..<200).map { Self.toner(50, name: "Supply \($0)", color: nil) }
        let long = String(repeating: "x", count: 5000) + "\tsecond\ncolumn"

        store.record(Self.printer, many, 1, Self.day0)
        store.record(Self.printer, [Self.toner(50, name: long, color: nil)], 1, Self.day0)

        #expect(Set(store.rows(Self.printer).map(\.supply)).count == SupplyHistoryStore.maxSupplies)
        let other = SupplyHistoryStore(folder)
        other.record("another", [Self.toner(50, name: long, color: nil)], 1, Self.day0)
        let rows = SupplyHistoryStore(folder).rows("another")
        try #require(rows.count == 1)
        #expect(rows[0].supply.count == SupplyHistoryStore.maxName)
        #expect(!rows[0].supply.contains("\t"))
        #expect(!rows[0].supply.contains("\n"))
    }

    @Test func Printers_beyond_the_limit_lose_their_oldest_file() {
        let store = SupplyHistoryStore(folder)
        for i in 0..<(SupplyHistoryStore.maxPrinters + 3) { store.record("printer \(i)", [Self.toner(50)], 1, Self.day0) }

        #expect(files.count == SupplyHistoryStore.maxPrinters)
        #expect(SupplyHistoryStore(folder).rows("printer \(SupplyHistoryStore.maxPrinters + 2)").count == 1) // never the one just made
    }

    @Test func A_damaged_file_gives_the_lines_it_still_can() throws {
        let store = SupplyHistoryStore(folder)
        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)
        let file = try #require(files.first)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
        handle.seekToEndOfFile()
        handle.write(Data("not a row\n2026-13-45\tBlack toner\tK\t10\tok\t1\n2026-01-01\t\tK\t10\tok\t1\n2026-01-02\tBlack toner\tK\t900\tok\t-5\n".utf8))
        try handle.close()

        let rows = SupplyHistoryStore(folder).rows(Self.printer)

        try #require(rows.count == 2)
        #expect((rows[0].percent, rows[0].pages) == (45, 100))
        #expect(rows[1].percent == nil && rows[1].pages == nil) // out of range: no level, no count
    }

    @Test func The_file_holds_levels_and_counts_and_no_identifiers() throws {
        let store = SupplyHistoryStore(folder)

        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)

        let text = try String(contentsOfFile: try #require(files.first), encoding: .utf8)
        #expect(text == "#inkvolt-supply-history 1\n2025-10-01\tBlack toner\tK\t45\tok\t100\n")
    }

    @Test func Forgetting_a_printer_removes_its_history() {
        let store = SupplyHistoryStore(folder)
        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)

        store.forget(Self.printer)

        #expect(store.rows(Self.printer).isEmpty)
        #expect(files.isEmpty)
    }

    @Test func A_renamed_printer_id_keeps_its_history() {
        let store = SupplyHistoryStore(folder)
        store.record("192.0.2.14", [Self.toner(45)], 100, Self.day0)

        store.rename("192.0.2.14", Self.printer)

        #expect(store.rows("192.0.2.14").isEmpty)
        #expect(SupplyHistoryStore(folder).rows(Self.printer).count == 1)
    }

    @Test func In_memory_a_store_writes_nothing() {
        let store = SupplyHistoryStore(nil)

        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)

        #expect(store.rows(Self.printer).count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder))
    }

    // MARK: A year, as the roadmap's test asks

    @Test func The_year_gives_the_change_dates() {
        let summary = SupplyAnalysis.summarize(Self.theYear(), Self.day0.adding(days: 364))

        #expect(summary.changeDates == [Self.day0.adding(days: 100), Self.day0.adding(days: 250)])
    }

    @Test func The_year_gives_pages_per_cartridge() {
        let summary = SupplyAnalysis.summarize(Self.theYear(), Self.day0.adding(days: 364))

        #expect(summary.cartridges.map(\.pages) == [1000, 1500, 1140])
        #expect(summary.pagesOnCurrent == 1140)
        #expect(!summary.cartridges[0].seenGoingIn) // history started part way through it
        #expect(summary.cartridges[1].seenGoingIn)
    }

    @Test func The_year_gives_days_left_from_the_last_30_days_of_this_cartridge() throws {
        let forecast = SupplyAnalysis.summarize(Self.theYear(), Self.day0.adding(days: 364)).forecast

        #expect(forecast.state == .estimate)
        #expect((134...138).contains(try #require(forecast.daysLeft))) // 54% at 0.4 a day
    }

    @Test func A_wobble_at_the_threshold_is_no_change_of_cartridge() {
        let rows = (0..<40).map { Self.row($0, $0 % 2 == 0 ? 14 : 16) }

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 39)).changeDates.isEmpty)
    }

    @Test func A_week_offline_is_counted_by_the_calendar_not_by_rows() {
        // 1% a day, no rows for days 10-16: the slope is still 1% a day.
        let rows = (0..<30).filter { $0 < 10 || $0 > 16 }.map { Self.row($0, 80 - $0) }

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29)).forecast.daysLeft == 51)
    }

    // MARK: Days left and its honest states

    @Test func Days_left_is_the_level_over_the_slope() {
        let rows = (0..<30).map { Self.row($0, 80 - $0) }

        let forecast = SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29)).forecast

        #expect(forecast.daysLeft == 51)
        #expect(forecast.text == "About 51 days left")
    }

    @Test func Days_since_the_last_reading_come_off_the_estimate() {
        let rows = (0..<20).map { Self.row($0, 80 - $0) } // 61% on day 19, 1% a day

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29)).forecast.daysLeft == 51)
    }

    @Test func Older_rows_than_30_days_are_left_out_of_the_slope() throws {
        // Down fast long ago, 1% a day for the last 30 days.
        let rows = (0..<20).map { Self.row($0, 99 - 2 * $0) } + (20..<60).map { Self.row($0, 59 - ($0 - 20) / 2) }

        let forecast = SupplyAnalysis.summarize(rows, Self.day0.adding(days: 59)).forecast

        #expect((76...80).contains(try #require(forecast.daysLeft))) // 40% at 0.5 a day
    }

    @Test(arguments: [(1, 7), (3, 5), (6, 2)])
    func Too_few_days_say_so_and_how_many_more(_ days: Int, _ more: Int) {
        let rows = (0..<days).map { Self.row($0, 80 - $0) }

        let forecast = SupplyAnalysis.summarize(rows, Self.day0.adding(days: days - 1)).forecast

        #expect(forecast.state == .notEnoughData)
        #expect(forecast.daysLeft == nil)
        #expect(forecast.moreDays == more)
        #expect(forecast.text?.contains("Not enough history") == true)
    }

    @Test func A_new_cartridge_starts_its_forecast_again() {
        let rows = (0..<30).map { Self.row($0, 60 - $0) } + [Self.row(30, 100), Self.row(31, 99)]

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 31)).forecast.state == .notEnoughData)
    }

    @Test func A_level_that_doesnt_fall_gives_no_number() {
        let rows = (0..<30).map { Self.row($0, 70) }

        let forecast = SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29)).forecast

        #expect(forecast.state == .steady)
        #expect(forecast.daysLeft == nil)
    }

    @Test func Very_slow_use_says_a_long_time_instead_of_a_silly_number() {
        let rows = (0..<30).map { Self.row($0, $0 < 15 ? 90 : 89) }

        let forecast = SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29)).forecast

        #expect(forecast.state == .estimate)
        #expect(forecast.daysLeft == nil)
        #expect(forecast.text == "More than two years left")
    }

    @Test func No_reading_for_over_30_days_is_not_enough_data() {
        let rows = (0..<30).map { Self.row($0, 80 - $0) }

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 90)).forecast.state == .notEnoughData)
    }

    @Test func An_empty_cartridge_has_no_days_left_to_count() {
        let rows = (0..<30).map { Self.row($0, max(0, 20 - $0)) }

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29)).forecast.state == .empty)
    }

    @Test func A_supply_that_never_reports_a_level_has_no_forecast_or_cartridges() {
        let rows = (0..<30).map { Self.row($0, nil, $0) }

        let summary = SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29))

        #expect(summary.forecast.state == .noLevel)
        #expect(summary.forecast.text == nil)
        #expect(summary.cartridges.isEmpty)
        #expect(summary.line == nil)
    }

    @Test func No_page_count_leaves_pages_unknown_not_zero() {
        let rows = (0..<30).map { Self.row($0, 80 - $0) }

        let summary = SupplyAnalysis.summarize(rows, Self.day0.adding(days: 29))

        #expect(summary.pagesOnCurrent == nil)
        #expect(summary.line == "About 51 days left")
    }

    @Test func A_page_counter_going_backwards_gives_no_count() {
        let rows = [Self.row(0, 80, 5000), Self.row(1, 79, 10)]

        #expect(SupplyAnalysis.summarize(rows, Self.day0.adding(days: 1)).pagesOnCurrent == nil)
    }

    @Test func The_line_says_whether_the_cartridge_was_seen_going_in() {
        let kept = (0..<30).map { Self.row($0, 80 - $0, 100 + $0) }
        #expect(SupplyAnalysis.summarize(kept, Self.day0.adding(days: 29)).line == "About 51 days left · 29 pages since Inkvolt Print started keeping track")

        let changed = [Self.row(0, 5, 100)] + (1...30).map { Self.row($0, 100 - $0, 100 + $0) }
        #expect(SupplyAnalysis.summarize(changed, Self.day0.adding(days: 30)).line == "About 70 days left · 29 pages since this cartridge went in")
    }

    @Test func Each_supply_gets_its_own_summary_in_the_order_first_seen() {
        let cyan = (0..<30).map { SupplyRow(Self.day0.adding(days: $0), "Cyan ink", "C", 50 - $0, "ok", nil) }
        let rows = (Array(Self.theYear().prefix(30)) + cyan).enumerated().sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }.map(\.element)

        let all = SupplyAnalysis.summarizeAll(rows, Self.day0.adding(days: 29))

        #expect(all.map(\.supply) == ["Black toner", "Cyan ink"])
        #expect(all[1].forecast.daysLeft == 21)
    }

    // MARK: The chart

    @Test func The_charts_points_are_the_stored_rows_byte_for_byte() throws {
        let store = SupplyHistoryStore(folder)
        store.importRows(Self.printer, Self.theYear())

        let chart = SupplyChartData.build(store.rows(Self.printer), Self.day0.adding(days: 364))

        let text = try String(contentsOfFile: try #require(files.first), encoding: .utf8)
        let stored = text.split(separator: "\n").dropFirst().map { $0.split(separator: "\t", omittingEmptySubsequences: false) }
            .filter { !$0[3].isEmpty }.map { "\($0[0])\t\($0[3])" }
        try #require(chart.lines.count == 1)
        let points: [String] = chart.lines[0].segments.flatMap { $0 }.map { p in "\(p.day)\t\(p.percent)" }
        #expect(points == stored)
    }

    @Test func No_level_breaks_the_line_and_a_change_of_cartridge_starts_a_new_one() throws {
        let chart = SupplyChartData.build(Self.theYear(), Self.day0.adding(days: 364))
        try #require(chart.lines.count == 1)
        let line = chart.lines[0]

        #expect(line.segments.count == 4) // first cartridge, second (the week offline stays joined), third before and after the -3s
        #expect(line.segments[0].last?.day == Self.day0.adding(days: 99))
        #expect(line.segments[1].first?.day == Self.day0.adding(days: 100))
        #expect(line.segments[2].last?.day == Self.day0.adding(days: 299))
        #expect(line.segments[3].first?.day == Self.day0.adding(days: 303))
        #expect(line.changes == [Self.day0.adding(days: 100), Self.day0.adding(days: 250)])
        #expect(line.segments.flatMap { $0 }.allSatisfy { (0...100).contains($0.percent) })
    }

    @Test func A_supply_with_no_level_draws_nothing() {
        let chart = SupplyChartData.build((0..<10).map { Self.row($0, nil) }, Self.day0.adding(days: 9))

        #expect(chart.lines.isEmpty)
        #expect(!chart.hasEnoughToDraw)
    }

    @Test func One_day_of_readings_isnt_a_chart_yet() {
        #expect(!SupplyChartData.build([Self.row(0, 50)], Self.day0).hasEnoughToDraw)
        #expect(SupplyChartData.build([Self.row(0, 50), Self.row(1, 49)], Self.day0.adding(days: 1)).hasEnoughToDraw)
    }

    @Test func The_chart_shows_the_last_year() {
        let rows = (0..<600).map { Self.row($0, 90) }

        let chart = SupplyChartData.build(rows, Self.day0.adding(days: 599))

        #expect(chart.from == Self.day0.adding(days: 599 - SupplyChartData.days))
        #expect(chart.to == Self.day0.adding(days: 599))
        #expect(chart.lines[0].segments[0].count == SupplyChartData.days + 1)
    }

    // MARK: What the supplies card shows

    @Test func The_card_gets_each_supplys_line_and_the_days_left_for_the_alert() {
        let cyan = (0..<30).map { SupplyRow(Self.day0.adding(days: $0), "Cyan toner", "C", 50 - $0, "ok", nil) }
        let rows = ((0..<30).map { Self.row($0, 80 - $0) } + cyan).enumerated()
            .sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }.map(\.element)

        let view = SupplyHistoryView.of(rows, Self.day0.adding(days: 29))

        #expect(view.line(for: Self.toner(51)) == "About 51 days left")
        #expect(view.line(for: Self.toner(21, name: "Cyan toner", color: "C")) == "About 21 days left")
        #expect(view.line(for: Self.toner(40, name: "Magenta toner", color: "M")) == nil) // nothing kept for it
        #expect(view.line(for: Self.box) == nil)
        #expect(view.daysLeft == ["Black toner|K": 51, "Cyan toner|C": 21])
        #expect(view.chart.hasEnoughToDraw)
        #expect(view.chartNote([Self.toner(51)]) == nil)
    }

    @Test func A_new_printer_says_the_chart_fills_in_and_one_without_levels_says_nothing() {
        let store = SupplyHistoryStore(nil)
        store.record(Self.printer, [Self.toner(45)], 100, Self.day0)

        let view = SupplyHistoryView.of(store.rows(Self.printer), Self.day0)

        #expect(!view.chart.hasEnoughToDraw)
        #expect(view.chartNote([Self.toner(45)])?.contains("fills in as days pass") == true)
        #expect(view.chartNote([Self.toner(nil), Self.box]) == nil)
        #expect(view.daysLeft.isEmpty)
        #expect(view.line(for: Self.toner(45))?.hasPrefix("Not enough history for days left yet") == true)
    }

    @Test func The_low_supply_alert_finds_the_days_left_under_the_key_the_store_keeps() {
        let odd = Self.toner(10, name: " Black\ttoner ", color: "K")
        let store = SupplyHistoryStore(nil)
        for d in 0..<20 {
            var reading = odd
            reading.percentRemaining = 30 - d
            store.record(Self.printer, [reading], nil, Self.day0.adding(days: d))
        }

        let view = SupplyHistoryView.of(store.rows(Self.printer), Self.day0.adding(days: 19))

        #expect(view.daysLeft[SupplyRow.keyOf(odd)] != nil)
    }

    // MARK: The low-supply alert names the days left

    private static let ready = PrinterStatus(code: "ready", message: "Ready", severity: .info, alerts: [])

    @Test func The_low_supply_alert_names_the_days_left() throws {
        let t = AlertTracker(rules: AlertRules())
        var low = Self.toner(10)
        low.estimatedPagesRemaining = 140
        let snap = PrinterSnapshot(uuid: Self.printer, name: "Office laser", reachable: true, status: Self.ready, supplies: [low],
                                   daysLeft: [SupplyRow.keyOf(low): 12])

        let notices = t.observe(snap, now: Date())

        try #require(notices.count == 1)
        #expect(notices[0].body.hasPrefix("Office laser: about 140 pages left, about 12 days at this rate."))
    }

    @Test func Without_a_forecast_the_low_supply_alert_reads_as_before() throws {
        let t = AlertTracker(rules: AlertRules())
        let snap = PrinterSnapshot(uuid: Self.printer, name: "Office laser", reachable: true, status: Self.ready, supplies: [Self.toner(10)])

        let notices = t.observe(snap, now: Date())

        try #require(notices.count == 1)
        #expect(notices[0].body.hasPrefix("Office laser: running low."))
    }

    @Test func Days_left_alone_are_named_when_the_printer_gives_no_page_estimate() throws {
        let t = AlertTracker(rules: AlertRules())
        let snap = PrinterSnapshot(uuid: Self.printer, name: "Office laser", reachable: true, status: Self.ready, supplies: [Self.toner(10)],
                                   daysLeft: [SupplyRow.keyOf(Self.toner(10)): 1])

        let notices = t.observe(snap, now: Date())

        try #require(notices.count == 1)
        #expect(notices[0].body.hasPrefix("Office laser: about 1 day left at this rate."))
    }

    // MARK: The demo's made-up history

    @Test func The_demo_history_is_a_believable_year_that_ends_at_the_reading() throws {
        let today = Day(2026, 10, 30)
        let store = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)

        store.record(Self.printer, [Self.toner(62), Self.toner(35, name: "Yellow ink", color: "Y"), Self.box], 18_400, today)

        let rows = store.rows(Self.printer)
        var names: [String] = []
        for r in rows where !names.contains(r.supply) { names.append(r.supply) }
        #expect(names == ["Black toner", "Yellow ink"])
        #expect(!rows.contains { $0.supply == Self.box.name })
        let first = try #require(rows.map(\.day).min())
        #expect(first >= today.adding(days: -366) && first <= today.adding(days: -360))
        #expect(rows.last { $0.supply == "Black toner" }?.percent == 62)
        #expect(rows.last { $0.supply == "Black toner" }?.pages == 18_400)
        #expect(rows.allSatisfy { (0...100).contains($0.percent ?? 50) })

        let black = SupplyAnalysis.summarize(rows.filter { $0.supply == "Black toner" }, today)
        #expect(!black.changeDates.isEmpty)
        #expect(black.forecast.state == .estimate)
        #expect(black.forecast.daysLeft != nil)
        #expect(black.pagesOnCurrent != nil)
        #expect(SupplyChartData.build(rows, today).hasEnoughToDraw)
    }

    @Test func The_demo_history_is_the_same_every_run_and_keeps_a_printer_without_a_count_without_one() {
        let today = Day(2026, 10, 30)
        let a = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)
        let b = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)

        a.record(Self.printer, [Self.toner(62)], nil, today)
        b.record(Self.printer, [Self.toner(62)], nil, today)

        #expect(a.rows(Self.printer) == b.rows(Self.printer))
        #expect(a.rows(Self.printer).allSatisfy { $0.pages == nil })
    }

    @Test func A_young_demo_printers_count_stays_above_zero_through_the_year() {
        let store = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)

        store.record(Self.printer, [Self.toner(20)], 387, Day(2026, 10, 30))

        let pages = store.rows(Self.printer).compactMap(\.pages)
        #expect(pages.allSatisfy { $0 > 0 })
        #expect(pages[0] < 387)
        #expect(pages.sorted() == pages) // the counter only goes up
    }

    @Test func The_demo_history_is_only_made_once_per_printer() {
        let today = Day(2026, 10, 30)
        let store = SupplyHistoryStore(nil, firstReading: DemoSupplyHistory.seed)

        store.record(Self.printer, [Self.toner(62)], nil, today)
        let count = store.rows(Self.printer).count
        store.record(Self.printer, [Self.toner(61)], nil, today.adding(days: 1))

        #expect(store.rows(Self.printer).count == count + 1)
    }

    // MARK: The feed (Mac only: the Windows app's PrinterViewModel.ShowSupplies)

    /// The day the feed asks for, set by the test.
    private final class Clock: @unchecked Sendable {
        var day: Day
        init(_ day: Day) { self.day = day }
    }

    @Test func The_feed_keeps_each_reading_in_the_file_and_works_the_card_out_again_only_when_a_row_or_the_day_changed() throws {
        let store = SupplyHistoryStore(folder)
        let clock = Clock(Self.day0)
        let feed = SupplyHistoryFeed(store, Self.printer, today: { clock.day })

        let first = try #require(feed.show([Self.toner(50), Self.box], pages: 100))
        #expect(store.rows(Self.printer) == [Self.row(0, 50, 100)])
        #expect(try String(contentsOfFile: try #require(files.first), encoding: .utf8).contains("\t50\tok\t100"))
        #expect(first.line(for: Self.toner(50))?.hasPrefix("Not enough history for days left yet") == true)

        // Rows put in behind the feed's back: the same reading on the same day changes no row, so the card is as it was.
        store.importRows(Self.printer, (0..<10).map { Self.row($0 - 9, 59 - $0, nil) })
        #expect(feed.show([Self.toner(50)], pages: nil) == first)

        clock.day = Self.day0.adding(days: 1)
        let next = try #require(feed.show([Self.toner(49)], pages: nil))
        #expect(next == SupplyHistoryView.of(store.rows(Self.printer), clock.day))
        #expect(next.daysLeft[SupplyRow.keyOf(Self.toner(49))] != nil)
    }

    /// Days left count calendar days: a reading that didn't get the supplies, or a day the printer is offline, gets the card
    /// and the alert's days left worked out for today, not the last reading's day ("About 34 days left" a week on).
    @Test func The_feed_works_the_days_left_out_again_on_a_new_day_without_a_reading_of_its_supplies() throws {
        let store = SupplyHistoryStore(nil)
        let clock = Clock(Self.day0)
        let feed = SupplyHistoryFeed(store, Self.printer, today: { clock.day })
        #expect(feed.show(nil, pages: nil) == nil) // nothing shown before the first reading of its supplies
        #expect(feed.current() == nil)
        store.importRows(Self.printer, (0..<10).map { Self.row($0 - 10, 60 - $0, nil) })
        let first = try #require(feed.show([Self.toner(50)], pages: nil))
        let key = SupplyRow.keyOf(Self.toner(50))
        let left = try #require(first.daysLeft[key])

        clock.day = Self.day0.adding(days: 3)
        let later = try #require(feed.show(nil, pages: nil))
        #expect(store.rows(Self.printer).last?.day == Self.day0) // nothing kept for a reading without its supplies
        #expect(later == SupplyHistoryView.of(store.rows(Self.printer), clock.day))
        #expect(try #require(later.daysLeft[key]) < left)

        clock.day = Self.day0.adding(days: 4)
        #expect(feed.current() == SupplyHistoryView.of(store.rows(Self.printer), clock.day))
    }

    /// The printer was removed: its file goes, and a reading still in flight (the monitor was reading when it was stopped)
    /// keeps nothing, so the file doesn't come back.
    @Test func A_forgotten_feed_keeps_nothing_from_a_reading_still_in_flight() throws {
        let store = SupplyHistoryStore(folder)
        let feed = SupplyHistoryFeed(store, Self.printer, today: { Self.day0 })
        #expect(feed.show([Self.toner(50)], pages: 100) != nil)
        #expect(files.count == 1)

        feed.forget()
        #expect(feed.show([Self.toner(49)], pages: 101) == nil)
        #expect(feed.current() == nil)
        #expect(files.isEmpty)
        #expect(store.rows(Self.printer).isEmpty)
    }

    /// Readings arriving together (a network printer's monitor and a check, a queue read on another thread) each get a view
    /// with their own reading in it, and the one cached last is the store's current rows.
    @Test func Readings_taken_together_each_get_a_view_with_their_reading() {
        let store = SupplyHistoryStore(nil)
        let feed = SupplyHistoryFeed(store, Self.printer, today: { Self.day0 })
        let views = Views()
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            let percent = 40 + i % 20
            if let v = feed.show([Self.toner(percent)], pages: nil) { views.add(percent, v) }
        }
        #expect(views.count == 200)
        #expect(feed.current() == SupplyHistoryView.of(store.rows(Self.printer), Self.day0))
        #expect(views.allMatch)
    }

    private final class Views: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [(Int, SupplyHistoryView)] = []
        func add(_ percent: Int, _ v: SupplyHistoryView) { lock.withLock { all.append((percent, v)) } }
        var count: Int { lock.withLock { all.count } }
        /// Each view's chart ends at the level its own reading kept (one row a day: the day's last reading wins).
        var allMatch: Bool {
            lock.withLock { all.allSatisfy { p, v in v.chart.lines.first?.segments.last?.last?.percent == p } }
        }
    }
}

/// The one CSV across all printers: its content, and the Pro check in front of it. Ported from SupplyHistoryTests.cs's
/// SupplyHistoryCsvTests; with ProTests under `ProGated`, since both flip the gate.
extension ProGated {
@Suite final class SupplyHistoryCsvTests {
    private static let laser = "12345678-1234-4abc-8def-123456789abc", inkjet = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    private static let day0 = Day(2026, 1, 1)

    init() {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    deinit {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    private static func store() -> SupplyHistoryStore {
        let store = SupplyHistoryStore(nil)
        store.importRows(laser, [
            SupplyRow(day0, "Black toner", "K", 5, "low", 1000),
            SupplyRow(day0.adding(days: 1), "Black toner", "K", 100, "ok", 1010),
            SupplyRow(day0.adding(days: 2), "Black toner", "K", nil, "ok", 1030),
            SupplyRow(day0.adding(days: 3), "Black toner", "K", 99, "ok", 1050),
        ])
        store.importRows(inkjet, [SupplyRow(day0, "Cyan, light", "#00FFFF", 40, "ok", nil)])
        return store
    }

    private static let printers: [(id: String, name: String)] = [(laser, "Office laser"), (inkjet, "=Kitchen \"inkjet\"")]

    @Test func One_table_across_all_printers_with_the_cartridge_each_row_belongs_to() {
        let csv = SupplyHistoryCsv.build(Self.store(), Self.printers)

        #expect(csv ==
            "Printer,Supply,Color,Date,Level %,State,Pages printed,Cartridge seen since,Pages on this cartridge\r\n" +
            "Office laser,Black toner,K,2026-01-01,5,low,1000,2026-01-01,0\r\n" +
            "Office laser,Black toner,K,2026-01-02,100,ok,1010,2026-01-02,0\r\n" +
            "Office laser,Black toner,K,2026-01-03,,ok,1030,2026-01-02,20\r\n" +
            "Office laser,Black toner,K,2026-01-04,99,ok,1050,2026-01-02,40\r\n" +
            "\"'=Kitchen \"\"inkjet\"\"\",\"Cyan, light\",#00FFFF,2026-01-01,40,ok,,2026-01-01,\r\n")
    }

    @Test func A_supply_that_never_gave_a_level_still_has_its_rows() {
        let store = SupplyHistoryStore(nil)
        store.importRows(Self.laser, [SupplyRow(Self.day0, "Black toner", "K", nil, "ok", 500), SupplyRow(Self.day0.adding(days: 1), "Black toner", "K", nil, "ok", 510)])

        #expect(SupplyHistoryCsv.build(store, Self.printers).hasSuffix(
            "Office laser,Black toner,K,2026-01-01,,ok,500,2026-01-01,0\r\n" +
            "Office laser,Black toner,K,2026-01-02,,ok,510,2026-01-01,10\r\n"))
    }

    @Test func A_printer_without_rows_adds_nothing() {
        let csv = SupplyHistoryCsv.build(SupplyHistoryStore(nil), Self.printers)

        #expect(csv.components(separatedBy: "\r\n").filter { !$0.isEmpty }.count == 1)
    }

    @Test func While_the_gate_is_off_export_runs_for_everyone() {
        #expect(SupplyHistoryCsv.export(Self.store(), Self.printers) == SupplyHistoryCsv.build(Self.store(), Self.printers))
    }

    @Test func With_the_gate_on_export_needs_a_licence_and_the_chart_data_doesnt() {
        Pro.enforced = true

        #expect(SupplyHistoryCsv.export(Self.store(), Self.printers) == nil)
        #expect(!SupplyChartData.build(Self.store().rows(Self.laser), Self.day0.adding(days: 3)).lines.isEmpty) // the chart and days left stay free
    }
}
}
