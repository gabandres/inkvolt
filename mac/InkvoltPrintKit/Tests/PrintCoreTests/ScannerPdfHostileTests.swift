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

    // MARK: Pages that share a picture

    /// `count` pages inheriting one resources object (3) whose one picture (4) is `jpeg`; both dictionaries carry a literal
    /// string of `padding` spaces.
    private static func sharedPicture(pages count: Int, jpeg: [UInt8], padding: Int = 0) -> [UInt8] {
        let pad = "/Pad(" + String(repeating: " ", count: padding) + ")"
        var text = "%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n"
        text += "2 0 obj\n<</Type/Pages/Count \(count)/Resources 3 0 R/Kids["
        text += (0..<count).map { "\($0 + 10) 0 R" }.joined(separator: " ") + "]>>\nendobj\n"
        text += "3 0 obj\n<<" + pad + "/XObject<</Im0 4 0 R>>>>\nendobj\n"
        text += "4 0 obj\n<</Type/XObject/Subtype/Image" + pad
        text += "/Width 100/Height 200/BitsPerComponent 8/Filter/DCTDecode/Length \(jpeg.count)>>\nstream\n"
        let head = latin1(text)
        text = "\nendstream\nendobj\n"
        for i in 0..<count { text += "\(i + 10) 0 obj\n<</Type/Page/Parent 2 0 R/MediaBox[0 0 24 48]>>\nendobj\n" }
        text += "trailer\n<</Root 1 0 R>>\n%%EOF\n"
        return head + jpeg + latin1(text)
    }

    @Test func A_thousand_pages_sharing_a_padded_picture_are_read_in_a_moment() {
        let jpeg = TestJpeg.build(width: 100, height: 200, dnlHeight: nil)
        let pdf = Self.sharedPicture(pages: ScannerPdf.maxPages, jpeg: jpeg, padding: 2 * 1024 * 1024)
        let started = Date()

        let pages = ScannerPdf.jpegPages(pdf)
        #expect(pages?.count == ScannerPdf.maxPages)
        #expect(pages?.allSatisfy { $0 == jpeg } == true)
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    @Test func More_pages_than_a_scan_holds_are_refused_in_words() async throws {
        let pdf = Self.sharedPicture(pages: ScannerPdf.maxPages + 1, jpeg: TestJpeg.build(width: 100, height: 200, dnlHeight: nil))

        #expect(ScannerPdf.jpegPages(pdf) == nil)
        let tooMany = ScanError(loc("The scanner sent a PDF of more than {0} pages.", CoreLanguage.number(ScannerPdf.maxPages)))
        await #expect(throws: tooMany) { _ = try await ScannerPdf.pages(pdf, dpi: 300) }
    }

    @Test func Sixty_thousand_pages_sharing_one_picture_are_refused_in_a_moment() async throws {
        let jpeg = TestJpeg.build(width: 100, height: 200, dnlHeight: nil) + [UInt8](repeating: 0, count: 64 * 1024)
        let pdf = Self.sharedPicture(pages: 60_000, jpeg: jpeg)
        let started = Date()

        await #expect(throws: ScanError.self) { _ = try await ScannerPdf.pages(pdf, dpi: 300) }
        #expect(Date().timeIntervalSince(started) < Timing.limit(5.0))
    }

    // MARK: Objects and dictionaries

    @Test func An_object_number_beyond_Int_is_skipped_not_the_whole_file() {
        let jpeg = TestJpeg.build(width: 100, height: 200, dnlHeight: nil)
        let pdf = Self.onePicture(length: "\(jpeg.count)", extra: "99999999999999999999 0 obj\n<</Type/Page>>\nendobj\n")
        #expect(ScannerPdf.jpegPages(pdf) == [jpeg])
    }

    /// A Pages node whose resources (with a /Type of their own) come before its /Type, and a page whose resources hold a
    /// /Rotate of their own: only a dictionary's own keys count.
    @Test func A_pages_node_whose_resources_come_first_is_still_a_pages_node() {
        let jpeg = TestJpeg.build(width: 100, height: 200, dnlHeight: nil)
        var pdf = Self.latin1("%PDF-1.7\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n")
        pdf += Self.latin1("2 0 obj\n<</Resources<</Font<</F1<</Type/Font>>>>>>/Type/Pages/Kids[3 0 R]/Count 1>>\nendobj\n")
        pdf += Self.latin1("3 0 obj\n<</Type/Page/Parent 2 0 R/Resources<</XObject<</Im0 4 0 R>>/Properties<</MC0<</Rotate 90>>>>>>>>\nendobj\n")
        pdf += Self.latin1("4 0 obj\n<</Subtype/Image/Type/XObject/Width 100/Height 200/Filter/DCTDecode/Length \(jpeg.count)>>\nstream\n")
        pdf += jpeg + Self.latin1("\nendstream\nendobj\ntrailer\n<</Root 1 0 R>>\n%%EOF\n")

        #expect(ScannerPdf.jpegPages(pdf) == [jpeg])
    }

    @Test(arguments: [
        ("<</DecodeParms<</Length 0>>/Length 52341>>", "Length", "52341"), // a nested dictionary's key isn't the dictionary's
        ("<</Resources<</Rotate 90>>/Type/Page>>", "Rotate", nil),
        ("<</Kids[/Length 5]/Length 7>>", "Length", "7"), // nor an array's
        ("<</T(/Length 5)/Length 7>>", "Length", "7"), // nor a string's
        (#"<</T(a\)/Length 5)/Length 7>>"#, "Length", "7"), // an escaped parenthesis doesn't end it
        ("<</T(a(/Length 5))/Length 7>>", "Length", "7"), // nor a nested one
        ("<</T<2F4C656E677468>/Length 7>>", "Length", "7"),
        ("<</A 1 % /Length 5\n/Length 7>>", "Length", "7"), // nor a comment's
        ("<</Name/Length/Length 7>>", "Length", "7"), // a value that is the key's name isn't the key
        ("<</K <</X<ab>>>/Count 1>>", "K", "<</X<ab>>>"), // a hex string's > doesn't close the dictionary
        ("<</K <</S(>>)>>/Count 1>>", "K", "<</S(>>)>>"),
        (#"<</K [(a]b\)c(d)e) 1 0 R]/N 2>>"#, "K", #"[(a]b\)c(d)e) 1 0 R]"#),
        ("<</K [1 0 R %]\n2 0 R]/N 2>>", "K", "[1 0 R %]\n2 0 R]"),
        ("<</K [<5d> 1]/N 2>>", "K", "[<5d> 1]"),
        ("/Length 52341%len\n", "Length", "52341"), // a token ends at any delimiter or white space
        ("/Rotate 90\u{0C}/Type/Page", "Rotate", "90"),
        ("/Rotate 90\u{00}/Type/Page", "Rotate", "90"),
        ("/Length 7(x)", "Length", "7"),
        ("/Length 7{x}", "Length", "7"),
        ("/Length 7]", "Length", "7"),
    ] as [(String, String, String?)])
    func A_value_is_read_from_the_dictionarys_own_keys(_ dict: String, _ key: String, _ value: String?) {
        #expect(MiniPdf.value(dict, key) == value)
    }
}
