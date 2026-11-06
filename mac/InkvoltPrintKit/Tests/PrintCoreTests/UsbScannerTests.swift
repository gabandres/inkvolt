import Foundation
import Testing
@testable import PrintCore

/// Roadmap 2.3 on the Mac, what Inkvolt PDF's Scan dialog shares with Windows' (ported from UsbScannerTests.cs): blank pages
/// left out of a scan (`ScanRun`). The WIA and TWAIN tests stay with Windows (the Mac's scanners come through ImageCaptureCore,
/// already tested in PrintMac), and making the PDF is PdfCore's `ImageImport` (its own tests), so the page-assembly tests
/// count the pages kept instead of opening a PDF. Nothing here touches a real scanner.
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
