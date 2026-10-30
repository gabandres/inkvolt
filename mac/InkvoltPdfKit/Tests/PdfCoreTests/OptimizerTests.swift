import Foundation
import Testing
@testable import PdfCore

/// Ported from OptimizerTests.cs (same names). Adapted: the bloated fixture is written as bytes (its image samples
/// aren't text); EncryptedFilesNeedTheOwnerPassword doesn't expect `OpenPasswordUnknown` (MuPDF keeps an AES-256 file's
/// open password through a rewrite without knowing it); SignedFilesNeedConsent uses the signed-looking fixture.
struct OptimizerTests {
    private static let side = 1200

    /// A stream object as bytes (binary samples kept as they are).
    private static func stream(_ data: [UInt8], _ dict: String = "") -> [UInt8] {
        Array("<< \(dict) /Length \(data.count) >>\nstream\n".utf8) + data + Array("\nendstream".utf8)
    }

    /// Objects 1…n with a classic xref table, as `Core1TestPdf.build` writes them, from bytes.
    private static func build(_ objects: [[UInt8]]) -> [UInt8] {
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n".utf8) + o + Array("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    /// Page 1: text (ASCIIHex-encoded content) and a 1200x1200 uncompressed gradient shown 300 pt wide (288 dpi), plus a
    /// thumbnail. Page 2: two byte-identical small images (72 dpi). Object 13: an unreferenced 100 KB stream.
    static func bloated() -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: side * side * 3)
        for y in 0..<side {
            for x in 0..<side {
                let o = (y * side + x) * 3
                pixels[o] = UInt8(x * 255 / (side - 1))
                pixels[o + 1] = UInt8(y * 255 / (side - 1))
                pixels[o + 2] = 128
            }
        }
        let small: [UInt8] = (0..<(64 * 64)).map { (i: Int) -> UInt8 in UInt8(i * 7 % 256) }
        let text = "BT /F1 24 Tf 72 720 Td (Hello optimizer) Tj ET q 300 0 0 300 72 300 cm /Big Do Q"
        let hex = Array(text.utf8).map { String(format: "%02X", $0) }.joined() + ">"
        func s(_ t: String) -> [UInt8] { Array(t.utf8) }
        return build([
            s("<< /Type /Catalog /Pages 2 0 R >>"),
            s("<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 >>"),
            s("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Thumb 12 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Big 6 0 R >> >> >>"),
            stream(Array(hex.utf8), "/Filter /ASCIIHexDecode"),
            s("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"),
            stream(pixels, "/Type /XObject /Subtype /Image /Width \(side) /Height \(side) /ColorSpace /DeviceRGB /BitsPerComponent 8"),
            s("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 8 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im1 9 0 R /Im2 10 0 R >> >> >>"),
            stream(s("BT /F1 24 Tf 72 720 Td (Second page) Tj ET q 64 0 0 64 72 400 cm /Im1 Do Q q 64 0 0 64 200 400 cm /Im2 Do Q")),
            stream(small, "/Type /XObject /Subtype /Image /Width 64 /Height 64 /ColorSpace /DeviceGray /BitsPerComponent 8"),
            stream(small, "/Type /XObject /Subtype /Image /Width 64 /Height 64 /ColorSpace /DeviceGray /BitsPerComponent 8"),
            s("<< /Producer (test) >>"),
            stream([UInt8](repeating: 120, count: 3 * 20 * 20), "/Width 20 /Height 20 /ColorSpace /DeviceRGB /BitsPerComponent 8"),
            stream([UInt8](repeating: 122, count: 100_000)),
        ])
    }

    private static func xobject(_ doc: MuDoc, _ page: Int, _ name: String) throws -> PObj {
        try #require(doc.page(page).dict("Resources")?.dict("XObject")?[name])
    }

    private static func text(_ pdf: [UInt8], _ page: Int, password: String? = nil) throws -> String {
        let engine = try PdfEngine.open(pdf, password: password)
        defer { engine.close() }
        return try engine.text(page).text
    }

    @Test func shrinksAndKeepsTheContent() throws {
        let pdf = Self.bloated()
        let result = try Optimizer.optimize(pdf, nil)
        #expect(result.sizeBefore == pdf.count)
        #expect(result.sizeAfter == result.data.count)
        #expect(result.sizeAfter * 20 < result.sizeBefore, "\(result.sizeBefore) -> \(result.sizeAfter)")
        #expect(result.imagesDownsampled == 1)
        #expect(result.duplicatesRemoved >= 1)
        #expect(result.streamsCompressed >= 2)

        let engine = try PdfEngine.open(result.data)
        #expect(engine.pageCount == 2)
        #expect(try engine.text(0).text.contains("Hello optimizer"))
        #expect(try engine.text(1).text.contains("Second page"))
        engine.close()

        let doc = try Core2Pdf.open(result.data)
        let big = try Self.xobject(doc, 0, "Big")
        #expect(big.name("Filter") == "DCTDecode")
        let width = big.int("Width") ?? 0
        #expect(width >= 620 && width <= 630) // 1200 px * 150 / 288
        #expect(doc.page(0)["Thumb"] == nil)
        // The duplicates share one object now.
        let r1 = try Self.xobject(doc, 1, "Im1"), r2 = try Self.xobject(doc, 1, "Im2")
        #expect(r1.isRef && r2.isRef && r1.num == r2.num)
        // Small images aren't touched, only compressed.
        #expect(r1.int("Width") == 64)
        #expect(r1.name("Filter") == "FlateDecode")
        // The unreferenced stream is gone.
        #expect(!doc.allObjects().contains { $0.isStream && ($0.rawStreamData?.count ?? 0) >= 100_000 })

        // The gradient still looks the same: center of the image ≈ (128, 128, 128); left edge red ≈ 0, right edge ≈ 255.
        let center = TestImages.pixelAt(result.data, 0, 72 + 150, 792 - 300 - 150)
        #expect(center.r >= 115 && center.r <= 141)
        #expect(center.g >= 115 && center.g <= 141)
        #expect(TestImages.pixelAt(result.data, 0, 74, 792 - 450).r <= 20)
        #expect(TestImages.pixelAt(result.data, 0, 370, 792 - 450).r >= 235)
    }

    @Test func optionsTurnStepsOff() throws {
        let pdf = Self.bloated()
        let result = try Optimizer.optimize(pdf, nil, OptimizeOptions(deduplicateStreams: false, removeThumbnails: false, maxImageDpi: nil))
        #expect(result.imagesDownsampled == 0)
        #expect(result.duplicatesRemoved == 0)
        let doc = try Core2Pdf.open(result.data)
        #expect(try Self.xobject(doc, 0, "Big").int("Width") == Self.side)
        #expect(doc.page(0)["Thumb"] != nil)
        #expect(result.sizeAfter < result.sizeBefore) // compression alone helps (the gradient deflates well)
    }

    @Test func removesMetadataWhenAsked() throws {
        let withXmp = try PageEditor.writeMetadata(TestPdf.make(1), nil, "Secret title", "Me", "", "")
        let kept = try Optimizer.optimize(withXmp, nil)
        #expect(try PageEditor.readMetadata(kept.data, nil).title == "Secret title")
        let stripped = try Optimizer.optimize(withXmp, nil, OptimizeOptions(removeMetadata: true))
        // The Info title stays.
        #expect(try PageEditor.readMetadata(stripped.data, nil).title == "Secret title")
    }

    @Test func signedFilesNeedConsent() throws {
        let signed = SignedEditTests.signed()
        #expect(throws: SignaturesWouldBreak.self) { try Optimizer.optimize(signed, nil) }
        let (data, report) = try SignedEdits.run({ try Optimizer.optimize(signed, nil).data }, allowRewrite: true)
        #expect(!report.appended)
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        #expect(engine.pageCount == 2)
    }

    @Test func encryptedFilesNeedTheOwnerPassword() throws {
        let pdf = try PdfSecurity.protect(Self.bloated(), nil, userPassword: "open", ownerPassword: "owner")
        #expect(throws: OwnerPasswordRequired.self) { try Optimizer.optimize(pdf, "open") }
        // The open password stays through the rewrite without being known here (MuPDF keeps the encryption as it was).
        let result = try Optimizer.optimize(pdf, "owner")
        #expect(result.sizeAfter * 10 < result.sizeBefore)
        #expect(result.imagesDownsampled == 1)
        // Like every Core edit of an encrypted file, the result keeps the protection.
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(result.data).close() }
        #expect(try PdfSecurity.readSecurity(result.data, "open").method == .aes256)
        #expect(try Self.text(result.data, 0, password: "open").contains("Hello optimizer"))
    }
}
