import Foundation
import Testing
@testable import PrintCore

/// Roadmap 2.3 on the Mac, what Inkvolt PDF's Scan dialog shares with Windows' (ported from UsbScannerTests.cs): blank pages
/// left out of a scan (`ScanRun`), presets from the dialog's choices (`ScanPresets.fromChoices`, matched by `PresetPlan`),
/// and the list's network scanners, Inkvolt Print's remembered ones first (`ScannerList`). The WIA and TWAIN tests stay with
/// Windows (the Mac's scanners come through ImageCaptureCore, already tested in PrintMac), and making the PDF is PdfCore's
/// `ImageImport` (its own tests), so the page-assembly tests count the pages kept instead of opening a PDF. Nothing here
/// touches a real scanner.
struct UsbScannerTests {
    /// A real JPEG header with the page number in a comment segment, so each page differs and the test can tell which it is.
    static func page(_ number: Int) -> [UInt8] {
        let jpeg = TestJpeg.build(width: 40, height: 52, dnlHeight: nil)
        let comment: [UInt8] = [0xFF, 0xFE, 0, 4, UInt8(number >> 8 & 0xFF), UInt8(number & 0xFF)]
        return Array(jpeg[0..<2]) + comment + Array(jpeg[2...])
    }

    static let jam = ScanError("The document feeder is jammed. Clear the paper and try again.")

    static func numberOf(_ page: [UInt8]) -> Int { Int(page[6]) << 8 | Int(page[7]) }

    /// The analysis copy of page n: blank paper when `blank` says so, else paper with a line of "text".
    static func analysis(_ blank: @escaping @Sendable (Int) -> Bool) -> ScanRun.Analysis {
        { jpeg in
            let w = 200, h = 260
            var pixels = [UInt8](repeating: 245, count: w * h)
            if !blank(numberOf(jpeg)) {
                for y in 120..<130 {
                    for x in 40..<160 { pixels[y * w + x] = 20 }
                }
            }
            return GrayImage(width: w, height: h, pixels: pixels)
        }
    }

    /// A feeder that sends `pages` (both sides of each sheet when asked: side n is page n), or fails after `failAt` pages.
    struct ListScanner: ScanDevice {
        var pages: [[UInt8]]
        var failAt: Int?

        func capabilities() async throws -> ScannerCapabilities? { nil }

        func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
            let (pages, failAt) = (pages, failAt)
            return AsyncThrowingStream { continuation in
                for (i, p) in pages.enumerated() {
                    if i == failAt { return continuation.finish(throwing: UsbScannerTests.jam) }
                    continuation.yield(p)
                }
                continuation.finish()
            }
        }
    }

    static func run(_ scanner: any ScanDevice, _ request: ScanRequest = ScanRequest(), _ analysis: ScanRun.Analysis? = nil) async throws -> [ScanRunPage] {
        var list: [ScanRunPage] = []
        for try await p in ScanRun.pages(scanner, request, analysis: analysis) { list.append(p) }
        return list
    }

    static func kept(_ pages: [ScanRunPage]) -> [Int] { pages.filter { $0.fate == .kept }.map { numberOf($0.jpeg) } }

    // ---- Page assembly ----------------------------------------------------------------------------------------------------------

    @Test func Both_sides_of_10_sheets_with_blank_backs_drop_to_10_pages() async throws {
        let scanner = ListScanner(pages: (0..<20).map(Self.page))
        let request = ScanChoices.request(.adfDuplex, .grayscale, 200, nil)

        let pages = try await Self.run(scanner, request, Self.analysis { $0 % 2 == 1 }) // every back (odd side) is empty
        #expect(pages.count == 20)
        #expect(pages.filter { $0.fate == .blank }.count == 10)
        #expect(Self.kept(pages) == (0..<10).map { $0 * 2 })

        let all = try await Self.run(scanner, request) // not asked: every side stays
        #expect(all.filter { $0.fate == .kept }.count == 20)
    }

    @Test func Blank_dropping_keeps_a_page_with_a_little_ink_and_reports_unreadable_ones() async throws {
        let scanner = ListScanner(pages: [Self.page(0), Self.page(1), [0xFF, 0xD8, 0xFF, 0xD9], Self.page(3)])
        let pages = try await Self.run(scanner, ScanRequest(), Self.analysis { $0 == 1 })
        #expect(pages.map(\.fate) == [.kept, .blank, .unreadable, .kept])

        // A page the check can't judge is kept: no page is lost to it.
        struct CantDecode: Error {}
        let unsure = try await Self.run(scanner, ScanRequest()) { _ in throw CantDecode() }
        #expect(unsure.filter { $0.fate == .kept }.count == 3)
    }

    @Test func The_done_line_counts_pages_and_blanks() {
        #expect(ScanRun.doneText(kept: 10, blank: 10, unreadable: 0, glass: false, finish: "Create PDF")
            == "Done: 10 pages from the feeder (10 blank pages left out).")
        #expect(ScanRun.doneText(kept: 1, blank: 0, unreadable: 0, glass: false, finish: "x") == "Done: 1 page from the feeder.")
        #expect(ScanRun.doneText(kept: 1, blank: 1, unreadable: 0, glass: true, finish: "Insert Pages")
            .hasPrefix("Done (1 blank page left out). For another page, put it on the glass"))
        #expect(ScanRun.doneText(kept: 0, blank: 3, unreadable: 0, glass: false, finish: "x").contains("Clear \"Leave out blank pages\""))
        #expect(ScanRun.doneText(kept: 0, blank: 0, unreadable: 1, glass: false, finish: "x")
            == "The scanner returned no pages (1 page that couldn't be read left out).")
    }

    // ---- Presets ----------------------------------------------------------------------------------------------------------------

    static func input(_ dpi: [Int], maxHeight: Int, modes: [String]) -> InputCaps {
        InputCaps(minWidth: 16, maxWidth: 2550, minHeight: 16, maxHeight: maxHeight, colorModes: modes, resolutions: dpi)
    }

    /// Glass and a duplex feeder (legal sheets), 75-600 dpi, color and grey; and a flatbed (A4-long glass), 150/300/600 dpi.
    static let duplexScanner = ScannerCapabilities(version: "2.6", makeAndModel: "Example DocScan 10", uuid: nil,
                                                   platen: input([75, 150, 200, 300, 600], maxHeight: 3508, modes: ["RGB24", "Grayscale8"]),
                                                   adf: input([75, 150, 200, 300, 600], maxHeight: 4200, modes: ["RGB24", "Grayscale8"]), adfDuplex: true)
    static let flatbed = ScannerCapabilities(version: "2.6", makeAndModel: "Example Flatbed", uuid: nil,
                                             platen: input([150, 300, 600], maxHeight: 3508, modes: ["RGB24", "Grayscale8"]), adf: nil, adfDuplex: false)

    @Test func A_preset_saves_the_choices_and_is_matched_to_each_scanner() throws {
        let preset = ScanPresets.fromChoices([], name: "Contracts", source: .adfDuplex, color: .grayscale, dpi: 300, pageSize: "legal",
                                             ocr: true, skipBlank: true)
        #expect(preset.source == .feeder && preset.twoSided && !preset.color)
        #expect(preset.resolution == 300 && preset.pageSize == "legal" && preset.fileType == .searchablePdf && preset.skipBlank)

        // Saved with the app's settings and read back.
        let stored = try JSONDecoder().decode(ScanPresetSettings.self, from: JSONEncoder().encode(ScanPresetSettings(items: [preset])))
        let list = ScanPresets.normalize(stored)
        var expected = preset
        expected.unknown = list.first?.unknown
        #expect(list == [expected])

        let plan = PresetPlan.plan(list[0], Self.duplexScanner, feederLoaded: nil, ocrAvailable: true, metric: false)
        #expect(plan.request == ScanRequest(source: .adfDuplex, color: .grayscale, resolution: 300, width: 2550, height: 4200))
        #expect(plan.sizeKey == "legal") // the dialog picks the size by its key, not by matching width and height
        #expect(plan.ocr)
        #expect(plan.notes.isEmpty)

        let flatbed = PresetPlan.plan(list[0], Self.flatbed, feederLoaded: nil, ocrAvailable: false, metric: true)
        #expect(flatbed.sizeKey == "a4")
        #expect(flatbed.request.source == .platen)
        #expect(flatbed.request.color == .grayscale)
        #expect(!flatbed.ocr)
        #expect(flatbed.notes.contains("This scanner has no document feeder: scanning from the glass."))
        #expect(flatbed.notes.contains { $0.hasPrefix("Legal (8.5 × 14 in) doesn't fit this source") })
        #expect(flatbed.notes.contains { $0.hasPrefix("Text recognition isn't available") })

        let second = ScanPresets.fromChoices(list, name: "Contracts", source: .platen, color: .color, dpi: 150, pageSize: nil, ocr: false, skipBlank: false)
        #expect(second.name == "Contracts (2)")
        #expect(second.source == .glass && second.color && second.fileType == .pdf)
        #expect(ScanPresets.nameProblem(list, "", "contracts") == "Another preset is already called \"Contracts\".")
    }

    /// The Mac's own: a hostile name and resolution are made safe (trimmed and cut, clamped), an unknown page size dropped.
    @Test func A_preset_from_odd_choices_is_made_safe() {
        let long = "  " + String(repeating: "x", count: 200) + "  "
        let p = ScanPresets.fromChoices([], name: long, source: .adf, color: .color, dpi: 99_999, pageSize: "tabloid", ocr: false, skipBlank: true)
        #expect(p.name.count == ScanPresets.maxNameLength && !p.name.hasPrefix(" "))
        #expect(p.resolution == 1200 && p.pageSize == nil && p.source == .feeder && !p.twoSided)
        #expect(ScanPresets.isValidId(p.id))
        #expect(ScanPresets.fromChoices([], name: "a", source: .platen, color: .color, dpi: -5, pageSize: nil, ocr: false, skipBlank: true).resolution == 75)
    }

    // ---- The list ---------------------------------------------------------------------------------------------------------------

    static let office = "12345678-1234-4abc-8def-123456789abc"

    static func found(_ uuid: String, _ name: String, _ host: String, scanner: Bool = true) -> DiscoveredPrinter {
        DiscoveredPrinter(uuid: uuid, name: name, model: nil, host: host, hostName: nil, esclRoot: URL(string: "http://\(host)/eSCL/"),
                          hasScanner: scanner, ippUri: nil, txt: [:], addresses: [host])
    }

    /// The Mac's list has no driver scanners to double (ImageCaptureCore lists USB ones only); its network part, as Windows'.
    @Test func Driver_scanners_are_listed_beside_network_ones_without_doubles() {
        let root = URL(string: "http://192.0.2.5/eSCL/")!
        let found = EsclScanner(key: ScannerList.key(Self.office), name: "Office MFP", host: "192.0.2.5", esclRoot: root, remembered: false)
        #expect(ScannerList.label(found) == "Office MFP  (192.0.2.5) · found on the network")
        var known = found
        known.remembered = true
        #expect(ScannerList.label(known) == "Office MFP  (192.0.2.5)")
        #expect(ScannerList.usbLabel("Example DocScan 10") == "Example DocScan 10  (USB)")
        #expect(ScannerList.key("{12345678-1234-4ABC-8DEF-123456789ABC}") == "escl:" + Self.office)

        // A printer found on the network twice (its UUID written two ways) is listed once.
        let list = ScannerList.network(remembered: .empty, found: [Self.found(Self.office, "Office MFP", "192.0.2.5"),
                                                                    Self.found("{" + Self.office.uppercased() + "}", "Office MFP", "192.0.2.5")])
        #expect(list.count == 1)
    }

    /// Inkvolt Print's remembered scanners (its hand-off, `printers.json`) are listed before Bonjour answers; one found again
    /// takes its new address and keeps its name; a printer without eSCL, or with a root that isn't http(s), isn't a scanner.
    @Test func The_scanners_Inkvolt_Print_remembers_are_listed_first_and_found_ones_refresh_them() {
        let json = """
            { "version": 1, "printers": [
                { "id": "\(Self.office)", "name": "Office MFP", "host": "192.0.2.10", "esclRoot": "http://192.0.2.10:8080/eSCL/" },
                { "id": "b", "name": "Label printer", "host": "192.0.2.20" },
                { "id": "c", "name": "Odd", "host": "192.0.2.30", "esclRoot": "file:///etc/passwd" },
                { "id": "\(Self.office.uppercased())", "name": "Office MFP again", "host": "192.0.2.10", "esclRoot": "http://192.0.2.10/eSCL/" } ] }
            """
        let handed = SuitePrinters.parse(Data(json.utf8))
        let before = ScannerList.network(remembered: handed, found: [])
        #expect(before.map(\.name) == ["Office MFP"])
        #expect(before.map(\.remembered) == [true])
        #expect(before.first?.esclRoot.absoluteString == "http://192.0.2.10:8080/eSCL/")

        let found = [Self.found(Self.office, "HP Color LaserJet MFP", "192.0.2.11"),
                     Self.found("aaaaaaaa-1111-4222-8333-444444444444", "Hall MFP", "192.0.2.40"),
                     Self.found("bbbbbbbb-1111-4222-8333-444444444444", "Printer only", "192.0.2.50", scanner: false)]
        let after = ScannerList.network(remembered: handed, found: found)
        #expect(after.map(\.name) == ["Office MFP", "Hall MFP"])
        #expect(after.map(\.host) == ["192.0.2.11", "192.0.2.40"])
        #expect(after.map(ScannerList.label) == ["Office MFP  (192.0.2.11)", "Hall MFP  (192.0.2.40) · found on the network"])
        #expect(after.first?.esclRoot.absoluteString == "http://192.0.2.11/eSCL/")
    }

    /// The Mac's own, as Inkvolt Print joins them: a remembered printer found under a UUID the user accepted for it ("This is
    /// my printer"), or one remembered by its address (no UUID) found at one of its hosts, is listed once, under its
    /// remembered key, at its new address. A printer with a UUID of its own is never joined to another by address.
    @Test func A_remembered_scanner_found_under_an_accepted_uuid_or_at_its_host_is_listed_once() {
        let renewed = "aaaaaaaa-1111-4222-8333-444444444444"
        let byAddress = PrinterId.normalize(nil, host: "192.0.2.60")
        let handed = SuitePrinters([
            SuitePrinter(id: Self.office, name: "Office MFP", host: "192.0.2.10", esclRoot: "http://192.0.2.10/eSCL/",
                         acceptedUuids: ["{" + renewed.uppercased() + "}"]),
            SuitePrinter(id: byAddress, name: "Front desk", host: "192.0.2.60", esclRoot: "http://192.0.2.60/eSCL/",
                         hosts: ["192.0.2.60", "NPIFRONT.local."]),
            SuitePrinter(id: "cccccccc-1111-4222-8333-444444444444", name: "Hall MFP", host: "192.0.2.70", esclRoot: "http://192.0.2.70/eSCL/"),
        ])
        var front = Self.found("dddddddd-1111-4222-8333-444444444444", "Front desk MFP", "192.0.2.61")
        front.hostName = "npifront.local"
        let found = [Self.found(renewed, "HP Color LaserJet MFP", "192.0.2.11"), front,
                     Self.found("eeeeeeee-1111-4222-8333-444444444444", "Another MFP", "192.0.2.70")] // the hall's old address
        let list = ScannerList.network(remembered: handed, found: found)
        #expect(list.map(\.name) == ["Office MFP", "Front desk", "Hall MFP", "Another MFP"])
        #expect(list.map(\.key) == [ScannerList.key(Self.office), ScannerList.key(byAddress), ScannerList.key("cccccccc-1111-4222-8333-444444444444"),
                                    ScannerList.key("eeeeeeee-1111-4222-8333-444444444444")])
        #expect(list.map(\.host) == ["192.0.2.11", "192.0.2.61", "192.0.2.70", "192.0.2.70"])
        #expect(list.map(\.remembered) == [true, true, true, false])
    }

    /// The Mac's own: the list keeps the scanner chosen in it; the saved one is chosen when it's listed, also when it turns up
    /// after another was chosen in its place (a USB scanner ImageCaptureCore reports after the remembered network ones); and
    /// a choice made only because the saved one wasn't there yet is a fallback, never saved over it.
    @Test func The_saved_scanner_is_chosen_when_it_turns_up_and_a_fallback_isnt_saved() {
        let saved = "icc:usb-1"
        #expect(ScannerList.pick([], current: nil, fallback: false, saved: saved) == nil)
        let early = ScannerList.pick(["escl:a", "escl:b"], current: nil, fallback: false, saved: saved)
        #expect(early?.index == 0 && early?.fallback == true)
        let later = ScannerList.pick(["escl:a", "escl:b", saved], current: "escl:a", fallback: true, saved: saved)
        #expect(later?.index == 2 && later?.fallback == false)
        // Chosen by the user: kept when the saved one turns up.
        let kept = ScannerList.pick(["escl:a", "escl:b", saved], current: "escl:b", fallback: false, saved: saved)
        #expect(kept?.index == 1 && kept?.fallback == false)
        // A fallback still listed stays chosen (no reconnect) while the saved one is missing.
        let still = ScannerList.pick(["escl:b", "escl:a"], current: "escl:a", fallback: true, saved: saved)
        #expect(still?.index == 1 && still?.fallback == true)
        // Nothing saved yet: the first is simply the choice.
        let first = ScannerList.pick(["escl:a"], current: nil, fallback: false, saved: nil)
        #expect(first?.index == 0 && first?.fallback == false)
    }

    // ---- What goes wrong ----------------------------------------------------------------------------------------------------------

    @Test func A_jam_mid_stack_says_so_and_keeps_the_pages_before_it() async {
        let scanner = ListScanner(pages: (0..<10).map(Self.page), failAt: 3)
        var got: [ScanRunPage] = []
        do {
            for try await p in ScanRun.pages(scanner, ScanRequest(source: .adf), analysis: nil) { got.append(p) }
            Issue.record("the jam wasn't thrown")
        } catch {
            #expect((error as? ScanError)?.description == "The document feeder is jammed. Clear the paper and try again.")
        }
        #expect(got.count == 3)
    }

    /// The Mac's own: stopping the scan (cancelling the caller's task) stops the device's job too.
    @Test func Stopping_the_scan_stops_the_device() async throws {
        let stopped = Stopped()
        let device = EndlessScanner(stopped: stopped)
        let task = Task {
            var n = 0
            for try await _ in ScanRun.pages(device, ScanRequest(source: .adf), analysis: Self.analysis { _ in false }) {
                n += 1
                if n == 2 { break }
            }
            return n
        }
        #expect(try await task.value == 2)
        for _ in 0..<100 where !stopped.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stopped.value)
    }

    /// The Mac's own: Stop while a page is being checked for blankness ends the scan and the device's job at once, not when
    /// the check (seconds on a big page or a busy Mac) finishes; the check's verdict is dropped.
    @Test func Stopping_while_a_page_is_checked_stops_the_device_at_once() async throws {
        let stopped = Stopped()
        let checking = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let slow: ScanRun.Analysis = { jpeg in
            checking.signal()
            Self.wait(release, seconds: 5)
            return try Self.analysis { _ in false }(jpeg)
        }
        let task = Task {
            for try await _ in ScanRun.pages(EndlessScanner(stopped: stopped), ScanRequest(source: .adf), analysis: slow) {}
        }
        await Task.detached { Self.wait(checking, seconds: 5) }.value
        let started = ContinuousClock.now
        task.cancel()
        for _ in 0..<300 where !stopped.value { try await Task.sleep(for: .milliseconds(10)) }
        #expect(stopped.value)
        #expect(ContinuousClock.now - started < .seconds(2), "took \(ContinuousClock.now - started)")
    }

    /// Blocks the calling thread (a check, a detached task) until signalled, at most `seconds`.
    static func wait(_ semaphore: DispatchSemaphore, seconds: Double) { _ = semaphore.wait(timeout: .now() + seconds) }

    final class Stopped: @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        var value: Bool { lock.withLock { stopped } }
        func set() { lock.withLock { stopped = true } }
    }

    struct EndlessScanner: ScanDevice {
        let stopped: Stopped
        func capabilities() async throws -> ScannerCapabilities? { nil }
        func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
            let stopped = stopped
            return AsyncThrowingStream { continuation in
                let task = Task {
                    var n = 0
                    while !Task.isCancelled {
                        continuation.yield(UsbScannerTests.page(n))
                        n += 1
                        try? await Task.sleep(for: .milliseconds(5))
                    }
                }
                continuation.onTermination = { _ in
                    task.cancel()
                    stopped.set()
                }
            }
        }
    }
}
