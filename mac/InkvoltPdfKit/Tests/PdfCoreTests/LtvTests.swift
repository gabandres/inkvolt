import Foundation
import Testing
@testable import PdfCore

/// Ported from LtvTests.cs, its "What only looks like validation data" part: a later update that only claims to be a
/// document timestamp, or writes an annotation inside a page's /Annots list, is judged as a change. The rest of
/// LtvTests.cs (PAdES B-LT and B-LTA, Check Signatures Online) waits for roadmap 3.4 on the Mac. Adapted: the
/// signatures are made by `Signing` with an ID made in memory (`SigningTests.rsaId`), not by `LtvTestPki`;
/// An_annotation_inside_the_page_s_list_when_signed_doesn_t_get_in_the_way_of_validation_data needs Add Verification
/// Information, so the Mac has its own form of it: a /DSS added after signing a page that already holds such an
/// annotation isn't read as a change to it.
struct LtvTests {
    private static func first(_ pdf: [UInt8]) throws -> SignatureInfo {
        try #require(Signatures.verify(pdf).first)
    }

    private static func signed(_ level: CertificationLevel = .none, _ pdf: [UInt8] = TestPdf.make(2)) async throws -> [UInt8] {
        try await SigningTests.sign(pdf, try SigningTests.rsaId()) { $0.certify = level }
    }

    private static func pixelsChanged(_ a: [UInt8], _ b: [UInt8]) throws -> Double {
        let ea = try PdfEngine.open(a), eb = try PdfEngine.open(b)
        defer {
            ea.close()
            eb.close()
        }
        let pa = try ea.render(0, scale: 1).pixels, pb = try eb.render(0, scale: 1).pixels
        try #require(pa.count == pb.count)
        return Double(zip(pa, pb).count { $0 != $1 }) / Double(pa.count)
    }

    private static func overlay(_ doc: MuDoc, _ subtype: String, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ flags: Int) -> PObj {
        let look = doc.addStream(Array("0 0 0 rg 0 0 300 300 re f".utf8), dict: doc.dict([
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Form")), ("BBox", doc.array([0, 0, 300, 300].map { doc.int($0) })),
        ]), deflate: false)
        return doc.dict([
            ("Type", doc.name("Annot")), ("Subtype", doc.name(subtype)), ("F", doc.int(flags)),
            ("Rect", doc.array([x1, y1, x2, y2].map { doc.int($0) })), ("AP", doc.dict([("N", look)])),
        ])
    }

    /// An update adding a signature field that says it is a document timestamp and has nothing behind that but the name.
    private static func withFakeTimestamp(_ signed: [UInt8], _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ flags: Int) throws -> [UInt8] {
        let doc = try PdfEdit.open(signed, nil)
        let page = doc.page(0)
        let widget = overlay(doc, "Widget", x1, y1, x2, y2, flags)
        widget.set("FT", doc.name("Sig"))
        widget.set("T", doc.text("Timestamp9"))
        widget.set("P", page)
        widget.set("V", doc.add(doc.dict([("SubFilter", doc.name("ETSI.RFC3161"))])))
        let ref = doc.add(widget)
        doc.annots(page).append(ref)
        try #require(doc.catalog.dict("AcroForm")?.array("Fields")).append(ref)
        return try doc.append(original: signed)
    }

    @Test(arguments: [(CertificationLevel.none, SignatureStatus.modifiedAfterSigning), (.noChanges, .disallowedChanges)])
    func aFieldDrawnOverThePageThatCallsItselfATimestampIsAChange(_ level: CertificationLevel, _ expected: SignatureStatus) async throws {
        let signed = try await Self.signed(level)
        let forged = try Self.withFakeTimestamp(signed, 50, 50, 350, 350, 4)
        #expect(try Self.pixelsChanged(signed, forged) > 0.05)
        #expect(try Self.first(forged).status == expected)
    }

    @Test(arguments: [(CertificationLevel.none, SignatureStatus.modifiedAfterSigning), (.noChanges, .disallowedChanges)])
    func anInvisibleFieldWithNoRealTimestampInItIsAChange(_ level: CertificationLevel, _ expected: SignatureStatus) async throws {
        let forged = try Self.withFakeTimestamp(try await Self.signed(level), 0, 0, 0, 0, 132)
        #expect(try Self.first(forged).status == expected)
    }

    @Test(arguments: [
        (0, 0, 0, 0, 132), // what we write
        (100, 100, 100, 400, 4), // no width
        (50, 50, 350, 350, 2), // hidden
    ])
    func whatCountsAsAnInvisibleFieldReallyDrawsNothing(_ box: (Int, Int, Int, Int, Int)) async throws {
        let signed = try await Self.signed()
        #expect(try Self.pixelsChanged(signed, Self.withFakeTimestamp(signed, box.0, box.1, box.2, box.3, box.4)) == 0)
    }

    private static func withDirectAnnotation(_ signed: [UInt8], _ subtype: String) throws -> [UInt8] {
        let doc = try PdfEdit.open(signed, nil)
        doc.annots(doc.page(0)).append(overlay(doc, subtype, 50, 50, 350, 350, 4))
        doc.catalog.set("DSS", doc.dict())
        return try doc.append(original: signed)
    }

    @Test(arguments: [
        (CertificationLevel.none, "Stamp", SignatureStatus.modifiedAfterSigning),
        (.noChanges, "Stamp", .disallowedChanges),
        (.none, "Widget", .modifiedAfterSigning),
        (.noChanges, "Widget", .disallowedChanges),
    ])
    func anAnnotationWrittenInsideThePagesListIsAChange(_ level: CertificationLevel, _ subtype: String, _ expected: SignatureStatus) async throws {
        let signed = try await Self.signed(level)
        let forged = try Self.withDirectAnnotation(signed, subtype)
        if subtype == "Stamp" { #expect(try Self.pixelsChanged(signed, forged) > 0.05) }
        #expect(try Self.first(forged).status == expected)
    }

    /// The Mac's form of An_annotation_inside_the_page_s_list_when_signed_doesn_t_get_in_the_way_of_validation_data.
    @Test func anAnnotationInsideThePagesListWhenSignedDoesntGetInTheWayOfValidationData() async throws {
        let doc = try MuDoc.open(TestPdf.make(2))
        doc.annots(doc.page(0)).append(Self.overlay(doc, "Stamp", 50, 50, 100, 100, 4))
        let signed = try await Self.signed(.noChanges, try doc.write(""))
        let later = try PdfEdit.open(signed, nil)
        later.catalog.set("DSS", later.dict())
        let s = try Self.first(try later.append(original: signed))
        #expect(s.status == .modifiedAfterSigning, "\(s.detail ?? "")")
    }
}
