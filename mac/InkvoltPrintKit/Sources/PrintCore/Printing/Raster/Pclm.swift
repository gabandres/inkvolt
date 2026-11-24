import Foundation

/// PCLm (`application/PCLm`, the Mopria Alliance's PCLm Technical Reference): a PDF 1.7 file with a `%PCLm 1.0` comment after
/// the header, whose pages are nothing but image strips. Each page is a Page object, then its content stream (scale to points
/// once, then each strip drawn with `q … cm /ImageN Do Q`, top strip first), then its strips: 8-bit DeviceGray or DeviceRGB
/// XObjects of `RasterJob.stripHeight` lines (the last one may be shorter), FlateDecode or RunLengthDecode. The catalog comes
/// first and the page tree after the last page (so pages stream out one at a time), then a classic cross-reference table and
/// trailer. No object streams, no compressed cross-reference. Flate is PrintCore's `Deflate` (one block of fixed Huffman
/// codes), where Windows uses .NET's ZLibStream at its fastest level.
public final class PclmWriter: RasterWriter {
    private var offsets: [Int] = [0] // object number → file offset (0: the free entry)
    private var pageObjects: [Int] = []

    override init(_ job: RasterJob) throws {
        try super.init(job)
        put("%PDF-1.7\n%PCLm 1.0\n")
        offsets += [0, 0] // 1: the catalog; 2: the page tree, written at the end
        object(1, "<</Type/Catalog/Pages 2 0 R>>")
    }

    private var strips: Int { (job.heightPixels + job.stripHeight - 1) / job.stripHeight }

    override func writePage(_ page: RasterPage, _ index: Int) {
        let pageObject = offsets.count
        let content = pageObject + 1
        let firstImage = pageObject + 2
        let strips = self.strips
        var images = ""
        for s in 0..<strips { images += "/Image\(s) \(firstImage + s) 0 R" }
        pageObjects.append(pageObject)
        offsets += [Int](repeating: 0, count: strips + 2) // the page, its content, its strips
        let box = "[0 0 \(Self.num(job.widthPoints)) \(Self.num(job.heightPoints))]"
        object(pageObject, "<</Type/Page/Parent 2 0 R/Resources<</XObject<<\(images)>>>>/MediaBox\(box)/Contents \(content) 0 R>>")

        let scale = Self.num(72.0 / Double(job.dpi))
        var draw = "\(scale) 0 0 \(scale) 0 0 cm\n"
        for s in 0..<strips {
            let h = stripLines(s)
            let y = job.heightPixels - s * job.stripHeight - h // PDF's origin is the bottom left
            draw += "q \(page.width) 0 0 \(h) 0 \(y) cm /Image\(s) Do Q\n"
        }
        stream(content, "", Array(draw.utf8))

        let transform = job.transform(index)
        var line = [UInt8](repeating: 0, count: page.bytesPerLine)
        let colorSpace = page.color == .gray8 ? "/DeviceGray" : "/DeviceRGB"
        let filter = job.runLength ? "/RunLengthDecode" : "/FlateDecode"
        for s in 0..<strips {
            let h = stripLines(s)
            var raw: [UInt8] = []
            raw.reserveCapacity(h * page.bytesPerLine)
            for y in 0..<h {
                RasterLines.line(page, s * job.stripHeight + y, transform, &line)
                raw += line
            }
            let data = job.runLength ? RunLength.encode(raw) + [128] : Deflate.zlib(raw)
            stream(firstImage + s, "/Type/XObject/Subtype/Image/Width \(page.width)/Height \(h)/ColorSpace\(colorSpace)/BitsPerComponent 8/Filter\(filter)", data)
        }
    }

    override func writeEnd() {
        object(2, "<</Type/Pages/Kids[\(pageObjects.map { "\($0) 0 R" }.joined(separator: " "))]/Count \(pageObjects.count)>>")
        let xref = at
        var table = "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for i in 1..<offsets.count { table += Self.pad10(offsets[i]) + " 00000 n \n" }
        table += "trailer\n<</Size \(offsets.count)/Root 1 0 R>>\nstartxref\n\(xref)\n%%EOF\n"
        put(table)
    }

    private func stripLines(_ strip: Int) -> Int { min(job.stripHeight, job.heightPixels - strip * job.stripHeight) }

    private func object(_ number: Int, _ body: String) {
        offsets[number] = at
        put("\(number) 0 obj\n\(body)\nendobj\n")
    }

    private func stream(_ number: Int, _ dictionary: String, _ data: [UInt8]) {
        offsets[number] = at
        put("\(number) 0 obj\n<<\(dictionary)/Length \(data.count)>>\nstream\n")
        put(data)
        put("\nendstream\nendobj\n")
    }

    private static func pad10(_ n: Int) -> String {
        let s = String(n)
        return String(repeating: "0", count: max(0, 10 - s.count)) + s
    }

    /// A PDF real: up to four decimals, no exponent, no trailing zeros (Windows' Math.Round(v, 4), half to even, as "0.####").
    static func num(_ v: Double) -> String {
        let scaled = (v * 10_000).rounded(.toNearestOrEven)
        let negative = scaled < 0
        let units = Int(abs(scaled))
        var text = String(units / 10_000)
        var fraction = String(units % 10_000)
        if fraction != "0" {
            fraction = String(repeating: "0", count: 4 - fraction.count) + fraction
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text += "." + fraction
        }
        return negative && units != 0 ? "-" + text : text
    }
}

/// PDF's RunLengthDecode (ISO 32000-1 §7.4.5) written: 0-127 is followed by that many plus one bytes as they are, 129-255 by
/// one byte repeated 257 minus it times, 128 ends the data (the caller adds it).
enum RunLength {
    static func encode(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(data.count / 2)
        data.withUnsafeBufferPointer { d in
            var i = 0
            while i < d.count {
                var run = 1
                while i + run < d.count && run < 128 && d[i + run] == d[i] { run += 1 }
                if run >= 2 {
                    out.append(UInt8(257 - run))
                    out.append(d[i])
                    i += run
                    continue
                }
                var count = 1
                while i + count < d.count && count < 128 && !(i + count + 1 < d.count && d[i + count] == d[i + count + 1]) { count += 1 }
                out.append(UInt8(count - 1))
                out += d[i..<i + count]
                i += count
            }
        }
        return out
    }
}
