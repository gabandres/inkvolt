import Foundation
@testable import PdfCore

/// Synthetic PDFs for the tests (the Windows tests' `TestPdf`, which draws them with PDFsharp): page N shows "Page N"
/// plus a marker word and two more lines, in Helvetica, on Letter pages. Written by hand, objects and cross-reference
/// table, so the tests need nothing but MuPDF to read them.
enum TestPdf {
    /// `catalogExtra`: more catalog entries (the Windows tests add them with PDFsharp, e.g. /PageLabels).
    static func make(_ pages: Int, marker: String = "alpha", catalogExtra: String = "") -> [UInt8] {
        var objects: [String] = []
        // 1 catalog, 2 page tree, 3 font, then per page: the page and its content stream.
        objects.append("<< /Type /Catalog /Pages 2 0 R \(catalogExtra)>>")
        let kids = (0..<pages).map { "\(4 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for i in stride(from: 1, through: pages, by: 1) {
            // Baselines 100, 140 and 170 points from the top, as the Windows TestPdf draws them.
            let content = """
            BT /F1 20 Tf 72 692 Td (Page \(i) \(marker)) Tj ET
            BT /F1 20 Tf 72 652 Td (The quick brown fox) Tj ET
            BT /F1 20 Tf 72 622 Td (jumps over the lazy dog) Tj ET
            """
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(5 + (i - 1) * 2) 0 R >>")
            objects.append(Core1TestPdf.stream(content))
        }
        return Core1TestPdf.build(Dictionary(uniqueKeysWithValues: objects.enumerated().map { ($0.offset + 1, $0.element) }))
    }

    /// The same document protected with a user password (and `password + "-owner"` as its permissions password).
    static func encrypted(_ pages: Int, _ userPassword: String) -> [UInt8] {
        let engine = try! PdfEngine.open(make(pages))
        defer { engine.close() }
        return try! engine.write(options: "encrypt=aes-256,user-password=\(userPassword),owner-password=\(userPassword)-owner")
    }

    /// The "Page N" number on each page, in order, read back through MuPDF (0 = no number).
    static func pageNumbers(_ data: [UInt8]) -> [Int] {
        let engine = try! PdfEngine.open(data)
        defer { engine.close() }
        return (0..<engine.pageCount).map { i in
            let text = try! engine.text(i).text
            guard let r = text.range(of: #"Page (\d+)"#, options: .regularExpression) else { return 0 }
            return Int(text[r].dropFirst(5)) ?? 0
        }
    }
}

/// Hand-written PDFs with navigation and forms (the Windows tests' `Core1TestPdf`): pages show "Page N" (1-based), plus
/// an outline, named destinations, internal links and AcroForm fields spread over several pages.
enum Core1TestPdf {
    /// Five pages (612 × 792) and: outline Ch1 (p1, XYZ top 700) > [Ch1.1 (named "sec2" = p2 top 600), Ch1.2 (GoTo
    /// action p3 top 500)], Ch2 (p4, FitH 500, closed) > [Ch2.1 (p5 top 400)]; on page 1: a link to p3 (top 692), a link
    /// to named "sec4" (p4, Fit) and text field `textField`; radio group `radioField` with a widget on page 2 and one on
    /// page 3.
    static func navigation(textField: String = "name", radioField: String = "color", label: String = "Page") -> [UInt8] {
        let pages = 5
        func p(_ i: Int) -> String { "\(5 + i) 0 R" }
        var objects: [Int: String] = [
            1: "<< /Type /Catalog /Pages 2 0 R /Outlines 3 0 R /Names << /Dests << /Names [(sec2) [\(p(1)) /XYZ 0 600 0] (sec4) [\(p(3)) /Fit]] >> >> "
                + "/AcroForm << /Fields [22 0 R 23 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            2: "<< /Type /Pages /Kids [\((0..<pages).map(p).joined(separator: " "))] /Count \(pages) >>",
            3: "<< /Type /Outlines /First 15 0 R /Last 18 0 R /Count 3 >>",
            4: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            15: "<< /Title (Ch1) /Parent 3 0 R /Next 18 0 R /First 16 0 R /Last 17 0 R /Count 2 /Dest [\(p(0)) /XYZ 0 700 0] >>",
            16: "<< /Title (Ch1.1) /Parent 15 0 R /Next 17 0 R /Dest (sec2) >>",
            17: "<< /Title (Ch1.2) /Parent 15 0 R /Prev 16 0 R /A << /S /GoTo /D [\(p(2)) /XYZ 0 500 0] >> >>",
            18: "<< /Title (Ch2) /Parent 3 0 R /Prev 15 0 R /First 19 0 R /Last 19 0 R /Count -1 /Dest [\(p(3)) /FitH 500] >>",
            19: "<< /Title (Ch2.1) /Parent 18 0 R /Dest [\(p(4)) /XYZ 0 400 0] >>",
            20: "<< /Type /Annot /Subtype /Link /Rect [72 600 200 620] /Border [0 0 0] /Dest [\(p(2)) /XYZ 0 692 0] >>",
            21: "<< /Type /Annot /Subtype /Link /Rect [72 560 200 580] /Border [0 0 0] /A << /S /GoTo /D (sec4) >> >>",
            22: "<< /Type /Annot /Subtype /Widget /FT /Tx /T (\(textField)) /Rect [72 500 300 520] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P \(p(0)) >>",
            23: "<< /FT /Btn /Ff 49152 /T (\(radioField)) /Kids [24 0 R 25 0 R] /V /Off >>",
            24: "<< /Type /Annot /Subtype /Widget /Parent 23 0 R /Rect [72 400 90 418] /AS /Off /F 4 /P \(p(1)) /AP << /N << /Red 26 0 R /Off 27 0 R >> >> >>",
            25: "<< /Type /Annot /Subtype /Widget /Parent 23 0 R /Rect [72 400 90 418] /AS /Off /F 4 /P \(p(2)) /AP << /N << /Blue 26 0 R /Off 27 0 R >> >> >>",
            26: stream("q 0 g 2 2 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            27: stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        ]
        let annots = ["[20 0 R 21 0 R 22 0 R]", "[24 0 R]", "[25 0 R]", "[]", "[]"]
        for i in 0..<pages {
            objects[5 + i] = "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots \(annots[i]) /Contents \(10 + i) 0 R /Resources << /Font << /Helv 4 0 R >> >> >>"
            objects[10 + i] = stream("BT /Helv 20 Tf 72 700 Td (\(label) \(i + 1)) Tj ET")
        }
        return build(objects)
    }

    /// One page ("Page 1") with an Info dictionary and an XMP packet holding a custom property, a PDF/A id and a 2020
    /// creation date.
    static func withXmp(title: String = "Old title") -> [UInt8] {
        let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\" "
            + "xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\" xmlns:my=\"urn:example:my\" xmp:CreateDate=\"2020-01-02T03:04:05Z\" pdfaid:part=\"2\">"
            + "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(title)</rdf:li></rdf:Alt></dc:title>"
            + "<xmp:ModifyDate>2020-01-02T03:04:05Z</xmp:ModifyDate><my:Custom>keep me</my:Custom>"
            + "</rdf:Description></rdf:RDF></x:xmpmeta>\n<?xpacket end=\"w\"?>"
        return build([
            1: "<< /Type /Catalog /Pages 2 0 R /Metadata 4 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /Helv 7 0 R >> >> >>",
            4: stream(xmp, "/Type /Metadata /Subtype /XML"),
            5: "<< /Title (\(title)) /Producer (Test) /CreationDate (D:20200102030405Z) >>",
            6: stream("BT /Helv 20 Tf 72 700 Td (Page 1) Tj ET"),
            7: "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ], trailerExtra: "/Info 5 0 R")
    }

    /// One page that takes MuPDF a long time to render: many overlapping semi-transparent shapes.
    static func heavy(shapes: Int = 600) -> [UInt8] {
        var rng = SplitMix(seed: 42)
        var content = "/G gs\n"
        for _ in 0..<shapes {
            content += "\(Double(rng.next(10)) / 10) \(Double(rng.next(10)) / 10) 0.5 rg \(rng.next(560)) \(rng.next(740)) m "
                + "\(rng.next(612)) \(rng.next(792)) l \(rng.next(612)) \(rng.next(792)) l f\n"
        }
        return build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /ExtGState << /G << /ca 0.4 /BM /Multiply >> >> >> >>",
            4: stream(content),
        ])
    }

    /// Serializes numbered objects (1…max; gaps are null objects) with a classic xref table.
    static func build(_ objects: [Int: String], trailerExtra: String = "") -> [UInt8] {
        let count = objects.keys.max() ?? 0
        var out = Array("%PDF-1.7\n".utf8)
        var offsets = [Int](repeating: 0, count: count + 1)
        for n in stride(from: 1, through: count, by: 1) {
            offsets[n] = out.count
            out += Array("\(n) 0 obj\n\(objects[n] ?? "null")\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(count + 1)\n0000000000 65535 f \n"
        for n in stride(from: 1, through: count, by: 1) { table += String(format: "%010d 00000 n \n", offsets[n]) }
        table += "trailer\n<< /Size \(count + 1) /Root 1 0 R \(trailerExtra) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    /// A stream object; its content is written as UTF-8, as the whole file is.
    static func stream(_ content: String, _ dict: String = "") -> String {
        "<< \(dict) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"
    }
}

/// A seeded generator (.NET's `Random(42)` can't be reproduced here; the tests only need the same shapes every run).
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Int(z % UInt64(bound))
    }
}
