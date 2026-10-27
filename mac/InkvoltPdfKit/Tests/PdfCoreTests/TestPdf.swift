import Foundation

/// Synthetic PDFs for the tests (the Windows tests' `TestPdf`, which draws them with PDFsharp): page N shows "Page N"
/// plus a marker word and two more lines, in Helvetica, on Letter pages. Written by hand, objects and cross-reference
/// table, so the tests need nothing but MuPDF to read them.
enum TestPdf {
    static func make(_ pages: Int, marker: String = "alpha") -> [UInt8] {
        var objects: [String] = []
        // 1 catalog, 2 page tree, 3 font, then per page: the page and its content stream.
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        let kids = (0..<pages).map { "\(4 + $0 * 2) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        for i in stride(from: 1, through: pages, by: 1) {
            let content = """
            BT /F1 20 Tf 72 692 Td (Page \(i) \(marker)) Tj ET
            BT /F1 20 Tf 72 652 Td (The quick brown fox) Tj ET
            BT /F1 20 Tf 72 622 Td (jumps over the lazy dog) Tj ET
            """
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(5 + (i - 1) * 2) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        return write(objects)
    }

    /// Objects numbered from 1, then the cross-reference table and trailer (catalog: object 1).
    static func write(_ objects: [String]) -> [UInt8] {
        var out = Array("%PDF-1.7\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n\(body)\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        out += Array(table.utf8)
        return out
    }
}
