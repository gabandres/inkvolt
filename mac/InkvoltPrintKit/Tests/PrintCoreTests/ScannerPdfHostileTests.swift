import Foundation
import Testing
import TestTiming
@testable import PrintCore

/// A scanner's PDF is what a device on the network sends: lengths that overflow, files of hundreds of thousands of empty
/// objects, unbalanced arrays megabytes long and deeply nested values are read in time, without a trap, and give no pages
/// (the renderer then says what it can). The time limit fits a debug build in the full parallel suite on a busy PC (4 MB:
/// about half a second alone, up to a few seconds there); before, these took from minutes to hours.
struct ScannerPdfHostileTests {
    private static func latin1(_ s: String) -> [UInt8] { s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } }

    /// One page whose picture (object 4) has `length` as its /Length and `extra` objects after it.
    private static func onePicture(length: String, extra: String = "") -> [UInt8] {
        let jpeg = TestJpeg.build(width: 100, height: 200, dnlHeight: nil)
        var pdf = latin1("%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n2 0 obj\n<</Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n")
        pdf += latin1("3 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 24 48]/Resources<</XObject<</Im0 4 0 R>>>>>>\nendobj\n")
        pdf += latin1("4 0 obj\n<</Type/XObject/Subtype/Image/Width 100/Height 200/Filter/DCTDecode/Length \(length)>>\nstream\n")
        pdf += jpeg
        pdf += latin1("\nendstream\nendobj\n\(extra)trailer\n<</Root 1 0 R>>\n%%EOF\n")
        return pdf
    }

    @Test(arguments: ["9223372036854775807", "9223372036854775806", "-9223372036854775808"])
    func A_length_near_Ints_limit_gives_no_pages_instead_of_a_trap(_ length: String) {
        #expect(ScannerPdf.jpegPages(Self.onePicture(length: length)) == nil)
    }

    @Test(arguments: ["9223372036854775807", "9223372036854775000", "-1"])
    func An_indirect_length_near_Ints_limit_gives_no_pages_instead_of_a_trap(_ length: String) {
        #expect(ScannerPdf.jpegPages(Self.onePicture(length: "5 0 R", extra: "5 0 obj\n\(length)\nendobj\n")) == nil)
    }

    @Test func Four_megabytes_of_empty_objects_are_read_in_a_moment() {
        let one = Array("1 0 obj\nendobj\n".utf8)
        var pdf = Array("%PDF-1.7\n".utf8)
        pdf.reserveCapacity(4 * 1024 * 1024 + 64)
        while pdf.count < 4 * 1024 * 1024 { pdf += one }
        let started = Date()

        #expect(ScannerPdf.jpegPages(pdf) == nil)
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    @Test func Four_megabytes_of_empty_stream_objects_are_read_in_a_moment() {
        let one = Array("1 0 obj\n<</Length 0>>\nstream\n\nendstream\nendobj\n".utf8)
        var pdf = Array("%PDF-1.7\n".utf8)
        pdf.reserveCapacity(4 * 1024 * 1024 + 64)
        while pdf.count < 4 * 1024 * 1024 { pdf += one }
        let started = Date()

        #expect(ScannerPdf.jpegPages(pdf) == nil)
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    @Test(arguments: ["[", "<<", "[[[[", "<<<<"])
    func An_unbalanced_value_megabytes_long_is_read_in_a_moment(_ open: String) {
        let dict = "/Type/Pages/Kids " + open + String(repeating: " ", count: 2 * 1024 * 1024)
        let started = Date()

        #expect(MiniPdf.value(dict, "Kids") == nil)
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    @Test func A_page_tree_with_kids_megabytes_long_is_read_in_a_moment() {
        let tree = "2 0 obj\n<</Type/Pages/Kids[" + String(repeating: " ", count: 2 * 1024 * 1024) + "\nendobj\n"
        let file = Self.latin1("%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n" + tree + "trailer\n<</Root 1 0 R>>\n%%EOF\n")
        let started = Date()

        #expect(ScannerPdf.jpegPages(file) == nil)
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    @Test func Values_nested_deeper_than_any_scanner_writes_are_refused() {
        let deep = String(repeating: "[", count: 100_000) + String(repeating: "]", count: 100_000)
        #expect(MiniPdf.value("/Kids " + deep, "Kids") == nil)
        let shallow = "[[[1 0 R]]]"
        #expect(MiniPdf.value("/Kids " + shallow + "/Count 1", "Kids") == shallow)
    }

    @Test func A_key_named_many_times_over_is_found_in_a_moment() {
        let dict = String(repeating: "/Lengthy ", count: 300_000) + "/Length 12"
        let started = Date()

        #expect(MiniPdf.value(dict, "Length") == "12")
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    @Test func Fifty_thousand_pages_are_walked_in_a_moment() {
        let count = 50_000
        var text = "%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n"
        text += "2 0 obj\n<</Type/Pages/Count \(count)/Kids[" + (0..<count).map { "\($0 + 10) 0 R" }.joined(separator: " ") + "]>>\nendobj\n"
        for i in 0..<count { text += "\(i + 10) 0 obj\n<</Type/Page/Parent 2 0 R>>\nendobj\n" }
        text += "trailer\n<</Root 1 0 R>>\n%%EOF\n"
        let pdf = Self.latin1(text)
        let started = Date()

        let pages = MiniPdf(pdf)?.pages()
        #expect(pages?.count == count)
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }
}
