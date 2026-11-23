import Foundation
import Testing
@testable import PdfCore

/// Ported from AddressLinksTests.cs: Links from Addresses (roadmap 4.15, `AddressLinks`).
struct AddressLinksTests {
    private static func found(_ text: String) -> [String] {
        AddressLinks.matches(text).map { (text as NSString).substring(with: NSRange(location: $0.start, length: $0.length)) }
    }

    @Test func WebAndEmailAddressesAreFoundWithoutTheSentencesPunctuation() {
        #expect(Self.found("Visit https://example.com/help.") == ["https://example.com/help"])
        #expect(Self.found("See www.example.org, or call.") == ["www.example.org"])
        #expect(Self.found("Write to billing@example.com.") == ["billing@example.com"])
        #expect(Self.found("(see http://en.wikipedia.org/wiki/PDF_(format))") == ["http://en.wikipedia.org/wiki/PDF_(format)"])
        #expect(Self.found("\"https://example.com/a?b=1&c=2#top\"") == ["https://example.com/a?b=1&c=2#top"])
        #expect(Self.found("josé@correo.es y https://bücher.example/straße;") == ["josé@correo.es", "https://bücher.example/straße"])
        #expect(Self.found("mailto:first.last+tag@sub.example.co.uk") == ["first.last+tag@sub.example.co.uk"])
    }

    @Test func WhatOnlyLooksLikeAnAddressIsLeftAlone() {
        #expect(Self.found("a@b").isEmpty) // no domain
        #expect(Self.found("user@localhost").isEmpty)
        #expect(Self.found("x.@example.com and a..b@example.com").isEmpty)
        #expect(Self.found("www. and https:// alone").isEmpty)
        #expect(Self.found("version 1.2.3 and file.txt").isEmpty) // bare names aren't taken for addresses
        #expect(Self.found("ftp://files.example.com").isEmpty) // only web and email addresses
        #expect(Self.found("x" + String(repeating: "a", count: 5000) + "@").isEmpty)
        #expect(Self.found("go to www.example.com") == ["www.example.com"])
        // An address running on into letters or digits isn't cut short to a shorter domain.
        #expect(Self.found("support@example.com2 and help@example.org_x and a@b.c-d").isEmpty)
        #expect(Self.found("support@example.com, then") == ["support@example.com"])
    }

    @Test func ARunOfClosingBracketsIsNoAddressAndIsQuicklyPassedOver() {
        // Each bracket trimmed counted the brackets again: 500,000 took hours. Too long for an address, it is passed over
        // before any trimming; a long tail under the limit is trimmed at once.
        let clock = ContinuousClock.now
        #expect(Self.found("https://example.com/" + String(repeating: ")", count: 500_000)).isEmpty)
        #expect(Self.found("https://example.com/a(b)" + String(repeating: ")", count: 1_900)) == ["https://example.com/a(b)"])
        #expect(ContinuousClock.now - clock < .seconds(5))
    }

    private static func pdf() -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 11 Tf 72 700 Td (Visit https://example.com/help or write to billing@example.com today.) Tj 0 -20 Td (Our site www.example.org has more.) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ])
    }

    @Test func EachAddressBecomesALinkOverItsTextInOneChange() throws {
        let pdf = Self.pdf()
        let engine = try PdfEngine.open(pdf)
        let found = try AddressLinks.find(engine)
        engine.close()
        #expect(found.map(\.uri) == ["https://example.com/help", "mailto:billing@example.com", "https://www.example.org/"])
        #expect(found[1].text == "billing@example.com")
        #expect(found.allSatisfy { $0.boxes.count == 1 && (70...120).contains($0.boxes[0].y) }) // top of the page, page space

        let linked = try AddressLinks.apply(pdf, nil, found)
        let links = try Links.read(linked, nil)
        #expect(links.map(\.uri) == found.map { Optional($0.uri) })
        for i in found.indices { #expect(abs(found[i].boxes[0].centerX - links[i].rect.centerX) < 1.0) }
        let after = try PdfEngine.open(linked)
        defer { after.close() }
        #expect(try after.links(0).count == 3)

        // Run again: every address is linked already, nothing is found.
        let again = try PdfEngine.open(linked)
        defer { again.close() }
        #expect(try AddressLinks.find(again).isEmpty)
    }

    @Test func AnAddressAlreadyLinkedIsSkippedAndTheChosenOnesAreKept() throws {
        // A link the document has over the email address (its own target).
        let pdf = Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> /Annots [6 0 R] >>",
            Core2Pdf.stream("BT /F1 11 Tf 72 700 Td (Visit https://example.com/help or write to billing@example.com today.) Tj 0 -20 Td (Our site www.example.org has more.) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Annot /Subtype /Link /Rect [250 695 400 715] /A << /S /URI /URI (mailto:sales@example.com) >> >>",
        ])
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        let found = try AddressLinks.find(engine)
        #expect(found.map(\.uri) == ["https://example.com/help", "https://www.example.org/"])
        let links = try Links.read(try AddressLinks.apply(pdf, nil, [found[1]]), nil)
        #expect(links.map(\.uri) == ["mailto:sales@example.com", "https://www.example.org/"])
    }

    @Test func WhenNoAddressCanBeLinkedTheDocumentIsLeftAsItWas() throws {
        let pdf = Self.pdf()
        #expect(try AddressLinks.apply(pdf, nil, [FoundAddress(0, "x", "javascript:alert(1)", [RectD(72, 80, 50, 12)]),
                                                  FoundAddress(5, "a@b.co", "mailto:a@b.co", [RectD(72, 80, 50, 12)]),
                                                  FoundAddress(0, "a@b.co", "mailto:a@b.co", [])]) == pdf)
        #expect(try Links.putOnTexts(pdf, nil, []) == pdf)
    }

    @Test func FindingStopsWhenCancelled() throws {
        let engine = try PdfEngine.open(Self.pdf())
        defer { engine.close() }
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try AddressLinks.find(engine, cancel: cancel) }
    }
}
