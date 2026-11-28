import Foundation
import Testing
@testable import PrintCore

/// Printer alerts as notifications, one per printer with Open Printer and Pause Alerts. Ported from AlertToastTests.cs:
/// the grouping, the text, the tag and the pause. Not ported: the toast XML and its click arguments (macOS's notification
/// carries the printer in its user info and its buttons as a category, `Notifier` in the app), the image, and the Store
/// package's startup task (Windows only).
struct AlertToastTests {
    private static let toner = AlertNotice(uuid: "urn:uuid:aaaa-1", printerName: "Office laser", kind: .supplyLow,
                                           title: "Black toner is low", body: "About 140 pages left. Cartridge 134A.")
    private static let jam = AlertNotice(uuid: "urn:uuid:bbbb-2", printerName: "Front desk <inkjet> & co", kind: .paperJam,
                                         title: "Paper jam", body: "Clear the jam, then the printer goes on by itself.")
    private static let tray = AlertNotice(uuid: "urn:uuid:AAAA-1", printerName: "Office laser", kind: .paperOut,
                                          title: "Tray 2 is out of paper", body: "Load paper.")

    @Test func Several_alerts_for_one_printer_make_one_toast_with_a_line_each() {
        let (title, text) = AlertToasts.text([Self.toner, Self.tray])
        #expect(title == "2 alerts")
        #expect(text == "Black toner is low\nTray 2 is out of paper")
        #expect(AlertToasts.text([Self.toner]) == ("Black toner is low", "About 140 pages left. Cartridge 134A.")) // one: as it is
    }

    @Test func Alerts_read_together_are_grouped_by_printer_in_order_whatever_the_uuids_case() {
        let groups = AlertToasts.perPrinter([Self.toner, Self.jam, Self.tray])
        #expect(groups.count == 2)
        #expect(groups[0] == [Self.toner, Self.tray])
        #expect(groups[1] == [Self.jam])
        #expect(AlertToasts.perPrinter([]).isEmpty)
        // Mac: a job's notice is JobNotices' own notification, never in a printer's.
        var job = Self.jam
        job.jobKey = "7"
        #expect(AlertToasts.perPrinter([job, Self.toner]) == [[Self.toner]])
    }

    @Test func The_tag_is_short_and_the_same_for_one_printer_whatever_the_uuids_case() {
        let tag = AlertToasts.tag(Self.toner.uuid)
        #expect((1...16).contains(tag.count))
        #expect(tag.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(tag == AlertToasts.tag(Self.tray.uuid))
        #expect(tag != AlertToasts.tag(Self.jam.uuid))
    }

    @Test func The_pause_button_pauses_for_an_hour() { #expect(AlertToasts.pauseFor == 3600) }
}
