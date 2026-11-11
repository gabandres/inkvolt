import Foundation
@testable import PdfCore

/// Ported from RedactionCorpus.cs. The roadmap 1.1 corpus, generated: values planted line-broken, hyphenated, in split
/// text runs, on a turned page, on scanned pages (upright, turned by the page's /Rotate, on its side on the glass), in a
/// picture on a text page, under a poor text layer, and the lot again in an encrypted copy. A scan's words are what
/// `PlantedReader` says it reads, so the tests don't depend on a recognizer. Adapted: files with pictures are written byte
/// by byte (`RedactionCorpus.build`), as `Core2Pdf.build` writes its objects as UTF-8.
enum RedactionCorpus {
    static let password = "corpus-open-1"

    /// A value planted on a page.
    struct Planted {
        var page: Int
        var kind: RedactionPattern
        var value: String
    }

    static let search = RedactionPatternOptions(patterns: Set(RedactionPatterns.builtIn.filter { $0 != .zipCode }), phrases: ["Quillfeather Holdings"],
                                                expression: #"CASE-\d{4}"#)

    static let values: [Planted] = [
        // Page 1: line-broken.
        Planted(page: 0, kind: .socialSecurity, value: "123-45-6789"),
        Planted(page: 0, kind: .phone, value: "(555) 201 3434"),
        Planted(page: 0, kind: .paymentCard, value: "4111 1111 1111 1111"),
        Planted(page: 0, kind: .date, value: "October 27, 2026"),
        Planted(page: 0, kind: .phrase, value: "Quillfeather Holdings"),
        // Page 2: hyphenated at the line's end.
        Planted(page: 1, kind: .email, value: "jane.doe@example.com"),
        Planted(page: 1, kind: .socialSecurity, value: "078-05-1120"),
        Planted(page: 1, kind: .expression, value: "CASE-0412"),
        // Page 3: split text runs, kerning between digits.
        Planted(page: 2, kind: .paymentCard, value: "5555 5555 5555 4444"),
        Planted(page: 2, kind: .iban, value: "DE89 3704 0044 0532 0130 00"),
        Planted(page: 2, kind: .ipAddress, value: "192.168.1.10"),
        // Page 4: a page turned by /Rotate 90.
        Planted(page: 3, kind: .socialSecurity, value: "219-09-9999"),
        Planted(page: 3, kind: .email, value: "turned@example.org"),
        // Page 5: a scan.
        Planted(page: 4, kind: .socialSecurity, value: "457-55-5462"),
        Planted(page: 4, kind: .email, value: "scan.one@example.net"),
        Planted(page: 4, kind: .phrase, value: "Quillfeather Holdings"),
        // Page 6: a scan with /Rotate 90.
        Planted(page: 5, kind: .phone, value: "555-867-5309"),
        // Page 7: a scan on its side on the glass.
        Planted(page: 6, kind: .paymentCard, value: "3782 822463 10005"),
        // Page 8: text, with a picture of text.
        Planted(page: 7, kind: .email, value: "own.text@example.org"),
        Planted(page: 7, kind: .expression, value: "CASE-7788"),
        // Page 9: a scan under an old text layer that misses the value.
        Planted(page: 8, kind: .socialSecurity, value: "321-54-9876"),
    ]

    static let scanPages = [4, 5, 6, 8]

    /// Objects 1…n (each its bytes) with a classic cross-reference table; `trailerExtra` goes in the trailer.
    static func build(_ objects: [[UInt8]], trailerExtra: String = "") -> [UInt8] {
        var out = latin1Bytes("%PDF-1.7\n%\u{e2}\u{e3}\n")
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += latin1Bytes("\(i + 1) 0 obj\n") + o + latin1Bytes("\nendobj\n")
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R \(trailerExtra) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + latin1Bytes(table)
    }

    static func obj(_ text: String) -> [UInt8] { latin1Bytes(text) }

    static func stream(_ data: [UInt8], _ dict: String = "") -> [UInt8] {
        latin1Bytes("<< \(dict) /Length \(data.count) >>\nstream\n") + data + latin1Bytes("\nendstream")
    }

    static func stream(_ content: String, _ dict: String = "") -> [UInt8] { stream(latin1Bytes(content), dict) }

    static let helvetica = obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")

    /// A grey picture stream, deflated.
    static func grayImage(_ gray: [UInt8], _ width: Int, _ height: Int) -> [UInt8] {
        stream(Deflate.zlib(gray), "/Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /FlateDecode")
    }

    static func make() throws -> (pdf: [UInt8], reader: PlantedReader) {
        let planted = PlantedReader()
        // Each page has a height of its own: that is how the reader knows which page it was handed.
        var next = 0
        func tall() -> Double {
            defer { next += 1 }
            return 792 + 6 * Double(next)
        }
        let textPages = [
            PageDef(lines: ["Public heading", "SSN 123-45-", "6789 and phone (555) 201", "3434, card 4111 1111", "1111 1111, born October", "27, 2026 for Quillfeather", "Holdings today."], rotate: 0, height: tall()),
            PageDef(lines: ["Public heading", "Write to jane.doe@exam-", "ple.com about 078-05-", "1120 and CASE-", "0412 soon."], rotate: 0, height: tall()),
            PageDef(lines: [], rotate: 0, height: tall(), raw: "BT /F1 14 Tf 72 700 Td [(55)-5(55 55)-8(55 5555 4)-2(444)] TJ ET\n"
                + "BT /F1 14 Tf 72 676 Td (DE89 3704 ) Tj (0044 0532 ) Tj (0130 00) Tj ET\n"
                + "BT /F1 14 Tf 72 652 Td (192.) Tj (168.) Tj (1.) Tj (10) Tj ET\n"),
            PageDef(lines: ["Sideways reading", "SSN 219-09-9999 here", "Mail turned@example.org"], rotate: 90, height: tall()),
        ]
        // Redacted, these pages are pictures too: the reader knows what is on them, and reads what stays visible.
        for page in textPages {
            var upright = page
            upright.rotate = 0
            let engine = try PdfEngine.open(textPdf([upright]))
            defer { engine.close() }
            planted.plant(engine.page(0).width, engine.page(0).height, try engine.text(0))
        }
        let text = textPdf(textPages)
        let rest = [
            try scan(planted, tall(), ["Public heading on the scan", "SSN 457-55-5462 is here", "Mail scan.one@example.net now", "For Quillfeather", "Holdings today"]),
            try scan(planted, tall(), ["Please call this number soon", "Call 555-867-5309 today", "Thank you for your patience"], rotate: 90),
            try scan(planted, tall(), ["This page lay on its side", "Card 3782 822463 10005 was used", "All the lines read the same way", "So the page can be turned upright", "Before the words are read at all"], turn: 1),
            try mixed(planted, tall()),
            try layered(planted, tall()),
        ]
        let sources = [PdfSource(text, nil, "text")] + rest.enumerated().map { PdfSource($0.element, nil, "scan\($0.offset)") }
        return (try PageEditor.merge(sources, false), planted)
    }

    static func encrypted(_ plain: [UInt8]) throws -> [UInt8] {
        try PdfSecurity.protect(plain, nil, userPassword: password, ownerPassword: nil, permissions: .all)
    }

    struct PageDef {
        var lines: [String]
        var rotate: Int
        var height = 792.0
        var raw: String?
    }

    static func textPdf(_ pages: [PageDef]) -> [UInt8] {
        let n = pages.count
        var objects = [obj("<< /Type /Catalog /Pages 2 0 R >>"),
                       obj("<< /Type /Pages /Kids [\((3..<(3 + n)).map { "\($0) 0 R" }.joined(separator: " "))] /Count \(n) >>")]
        let font = 3 + 2 * n
        for (p, page) in pages.enumerated() {
            let rotate = page.rotate != 0 ? "/Rotate \(page.rotate)" : ""
            objects.append(obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 \(Int(page.height))] \(rotate) /Contents \(3 + n + p) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>"))
        }
        for page in pages {
            var content = page.raw ?? ""
            for (l, line) in page.lines.enumerated() {
                let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
                content += "BT /F1 14 Tf 72 \(700 - 24 * l) Td (\(escaped)) Tj ET\n"
            }
            objects.append(stream(content))
        }
        objects.append(helvetica)
        return build(objects)
    }

    static func n(_ v: Double) -> String { PdfNum.f2(v) }

    /// A page of grey pixels in a PDF.
    static func imagePdf(_ gray: [UInt8], _ width: Int, _ height: Int, _ pageWidth: Double, _ pageHeight: Double, rotate: Int = 0,
                         extraContent: String = "", extraResources: String = "", extraObjects: [[UInt8]] = []) -> [UInt8] {
        let rotation = rotate != 0 ? "/Rotate \(rotate)" : ""
        return build([
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(n(pageWidth)) \(n(pageHeight))] \(rotation) /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> \(extraResources) >> >>"),
            stream("q \(n(pageWidth)) 0 0 \(n(pageHeight)) 0 0 cm /Im0 Do Q\n\(extraContent)"),
            grayImage(gray, width, height),
        ] + extraObjects)
    }

    /// A page drawn to grey pixels at `scale` pixels a point.
    static func gray(_ engine: PdfEngine, _ page: Int, scale: Double, region: RectD? = nil) throws -> (gray: [UInt8], width: Int, height: Int) {
        let image = try engine.render(page, scale: scale, region: region)
        return (ScanCleanup.toGray(image.pixels, image.width, image.height), image.width, image.height)
    }

    /// The lines typeset, drawn to pixels at 150 dpi, laid on the glass; the reader told where their words are.
    private static func scan(_ reader: PlantedReader, _ height: Double, _ lines: [String], rotate: Int = 0, turn: Int = 0) throws -> [UInt8] {
        let engine = try PdfEngine.open(textPdf([PageDef(lines: lines, rotate: 0, height: height)]))
        defer { engine.close() }
        var (pixels, w, h) = try gray(engine, 0, scale: 150.0 / 72)
        reader.plant(612, height, try engine.text(0))
        let quarters = turn - rotate / 90 // stored so that /Rotate shows it upright, or on its side
        pixels = ScanCleanup.turn(pixels, w, h, 1, quarters)
        if quarters % 2 != 0 { (w, h) = (h, w) }
        return imagePdf(pixels, w, h, Double(w) * 72 / 150, Double(h) * 72 / 150, rotate: rotate)
    }

    /// A text page with a picture of text: the picture's words are for the recognizer only.
    private static func mixed(_ reader: PlantedReader, _ height: Double) throws -> [UInt8] {
        let picture = try PdfEngine.open(textPdf([PageDef(lines: ["Stamped CASE-7788 received"], rotate: 0)]))
        defer { picture.close() }
        let (pixels, w, h) = try gray(picture, 0, scale: 3, region: RectD(68, 74, 200, 24))
        reader.plantWords(612, height, [("Stamped", RectD(72, 296, 60, 24)), ("CASE-7788", RectD(132, 296, 80, 24)), ("received", RectD(212, 296, 60, 24))])
        return build([
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 \(Int(height))] /Contents 4 0 R /Resources << /Font << /F1 6 0 R >> /XObject << /Im0 5 0 R >> >> >>"),
            stream("BT /F1 14 Tf 72 \(Int(height) - 92) Td (Mail own.text@example.org here) Tj ET\nq 200 0 0 24 72 \(Int(height) - 320) cm /Im0 Do Q\n"),
            grayImage(pixels, w, h),
            helvetica,
        ])
    }

    /// A scan with an invisible text layer that doesn't have the value: a poor old OCR, or a planted one.
    private static func layered(_ reader: PlantedReader, _ height: Double) throws -> [UInt8] {
        let engine = try PdfEngine.open(textPdf([PageDef(lines: ["Public heading of this scan", "SSN 321-54-9876 on file", "Nothing else is written here"], rotate: 0, height: height)]))
        defer { engine.close() }
        let (pixels, w, h) = try gray(engine, 0, scale: 150.0 / 72)
        reader.plant(612, height, try engine.text(0))
        return imagePdf(pixels, w, h, Double(w) * 72 / 150, Double(h) * 72 / 150,
                        extraContent: "BT 3 Tr /F1 14 Tf 72 700 Td (Public heading of this scan) Tj 0 -24 Td (SSN on file) Tj ET\n",
                        extraResources: "/Font << /F1 6 0 R >>", extraObjects: [helvetica])
    }
}
