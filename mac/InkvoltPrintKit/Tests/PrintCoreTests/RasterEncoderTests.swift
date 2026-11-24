import Foundation
import Testing
@testable import PrintCore

/// Ported from DirectPrintTests.cs's RasterEncoderTests (roadmap 2.1, driverless printing): the three raster encoders byte for
/// byte against their specs (PWG 5102.4's header table and compression, Apple raster's header as CUPS reads it, PCLm's PDF
/// structure), read back by decoders written here from the specs (`SpecDecoder`), not from the encoders. PCLm's Flate strips
/// are read with BlackAndWhitePdfTests' inflater (RFC 1950/1951). macOS's own readers check the same files in PrintMacTests'
/// RasterCupsTests: libcups' raster reader for PWG and Apple raster, Core Graphics for PCLm, and ippeveprinter end to end.
/// Mac difference: `Noise` comes from a seeded generator of its own (.NET's Random(seed) sequence isn't Swift's), with the
/// same mix of runs and literals.
struct RasterEncoderTests {
    static func letter(_ format: RasterFormat, _ color: RasterColor = .gray8, pages: Int = 1, dpi: Int = 300) -> RasterJob {
        RasterJob(format, dpi: dpi, color: color, mediaName: "na_letter_8.5x11in", widthHmm: 21590, heightHmm: 27940, pages: pages)
    }

    static func job(_ format: RasterFormat, _ color: RasterColor, _ w: Int, _ h: Int, pages: Int = 1, dpi: Int = 100) -> RasterJob {
        RasterJob(format, dpi: dpi, color: color, mediaName: "custom", widthHmm: w, heightHmm: h, pages: pages)
    }

    // ---- the compression PWG raster and Apple raster share (PWG 5102.4 §4.3.1.2) ----

    private static func packed(_ line: [UInt8], _ bpp: Int) -> [UInt8] {
        var into = [UInt8](repeating: 0, count: line.count * 2 + 8)
        let n = RasterLines.pack(line, bpp, &into)
        return Array(into[0..<n])
    }

    @Test func aLinePacksIntoRepeatAndLiteralRuns() {
        // 0x02: next pixel 3 times; 0xFE (257-3): 3 pixels as they are; 0x01: next pixel twice; 0x00: one pixel (the last).
        #expect(Self.packed([5, 5, 5, 1, 2, 3, 9, 9, 7], 1) == [0x02, 5, 0xFE, 1, 2, 3, 0x01, 9, 0x00, 7])
    }

    @Test func runsStopAt128PixelsAnd128IsNeverWritten() {
        #expect(Self.packed([UInt8](repeating: 7, count: 300), 1) == [127, 7, 127, 7, 43, 7]) // 128 + 128 + 44
        let packed = Self.packed((0..<200).map { UInt8($0) }, 1)
        #expect(packed[0] == 129) // 257 - 128
        #expect(packed[129] == 257 - 72)
        #expect(packed.count == 1 + 128 + 1 + 72)
    }

    @Test func rgbPixelsRunAsThreeBytes() {
        #expect(Self.packed([1, 2, 3, 1, 2, 3, 4, 5, 6], 3) == [0x01, 1, 2, 3, 0x00, 4, 5, 6])
    }

    @Test func identicalLinesShareARepeatCountUpTo256() throws {
        var out: [UInt8] = []
        RasterLines.write(&out, try RasterPage.blank(width: 4, height: 300, color: .gray8), (1, 1))
        // 256 white lines, then 44: each line is one run of 4 white pixels.
        #expect(out == [0xFF, 0x03, 0xFF, 43, 0x03, 0xFF])
    }

    // ---- PWG raster (PWG 5102.4-2012) ----

    @Test func pwgRasterStartsWithItsSyncWordAndA1796ByteHeaderPerPage() throws {
        var job = Self.letter(.pwgRaster, .rgb8, pages: 2)
        (job.duplex, job.back, job.quality, job.mediaType) = (true, .rotated, 5, "stationery")
        let w = try RasterWriter.forJob(job)
        try w.write(try RasterPage.blank(width: 2550, height: 3300, color: .rgb8))
        try w.write(try RasterPage.blank(width: 2550, height: 3300, color: .rgb8))
        try w.finish()
        let b = w.drain()
        #expect(Array(b[0..<4]) == Array("RaS2".utf8))
        let h = Array(b[4..<1800])
        func u(_ at: Int) -> UInt32 { SpecDecoder.u32(h, at) }
        func i(_ at: Int) -> Int32 { Int32(bitPattern: u(at)) }
        func s(_ at: Int) -> String { String(decoding: h[at..<at + 64].prefix { $0 != 0 }, as: UTF8.self) }
        #expect(s(0) == "PwgRaster")                 // MediaClass
        #expect(s(128) == "stationery")              // MediaType
        #expect(u(272) == 1)                         // Duplex
        #expect([u(276), u(280)] == [300, 300] as [UInt32])      // HWResolution
        #expect([u(352), u(356)] == [612, 792] as [UInt32])      // PageSize in points
        #expect(u(368) == 0)                         // Tumble
        #expect([u(372), u(376)] == [2550, 3300] as [UInt32])    // Width, Height
        #expect([u(384), u(388), u(392)] == [8, 24, 7650] as [UInt32]) // BitsPerColor, BitsPerPixel, BytesPerLine
        #expect(u(396) == 0)                         // ColorOrder chunky
        #expect(u(400) == 19)                        // ColorSpace sRGB
        #expect(u(420) == 3)                         // NumColors
        #expect(u(452) == 2)                         // TotalPageCount
        #expect([i(456), i(460)] == [1, 1] as [Int32])          // the front is not turned
        #expect([u(464), u(468), u(472), u(476)] == [0, 0, 2550, 3300] as [UInt32]) // ImageBox
        #expect(u(480) == 0x00FF_FFFF)               // AlternatePrimary
        #expect(u(484) == 5)                         // PrintQuality
        #expect(s(1732) == "na_letter_8.5x11in")     // PageSizeName
        // Everything else is reserved: zero.
        var set = Set<Int>()
        for (at, length) in [(0, 64), (128, 64), (272, 12), (352, 8), (368, 32), (400, 4), (420, 4), (452, 36), (1732, 64)] {
            for k in 0..<length { set.insert(at + k) }
        }
        for k in 0..<1796 where !set.contains(k) { #expect(h[k] == 0, "reserved byte \(k) is \(h[k])") }
        // The back is rotated (rotated + long edge: both directions mirrored, as cupsRasterInitPWGHeader sets it).
        let back = PwgRasterWriter.header(job, job.transform(1))
        #expect(Int32(bitPattern: SpecDecoder.u32(back, 456)) == -1)
        #expect(Int32(bitPattern: SpecDecoder.u32(back, 460)) == -1)
    }

    @Test func pwgRasterReadsBackPixelForPixelWithTheBackSideTurned() throws {
        let front = try Self.noise(37, 23, .rgb8, seed: 1)
        let back = try Self.noise(37, 23, .rgb8, seed: 2)
        var job = Self.job(.pwgRaster, .rgb8, 940, 584, pages: 2)
        (job.duplex, job.tumble, job.back) = (true, true, .flipped)
        #expect([job.widthPixels, job.heightPixels] == [37, 23] as [Int])
        let w = try RasterWriter.forJob(job)
        try w.write(front)
        try w.write(back)
        try w.finish()
        let pages = try SpecDecoder.pwg(w.drain())
        #expect(pages.count == 2)
        #expect(pages[0].pixels == front.pixels)
        #expect(pages[1].transform == [-1, 1]) // flipped + short edge: across mirrored
        #expect(pages[1].pixels == Self.mirror(back, across: true, down: false))
    }

    @Test(arguments: [
        (BackSide.normal, false, 1, 1), (.normal, true, 1, 1), (.flipped, false, 1, -1), (.flipped, true, -1, 1),
        (.rotated, false, -1, -1), (.rotated, true, 1, 1), (.manualTumble, false, 1, 1), (.manualTumble, true, -1, -1),
    ] as [(BackSide, Bool, Int, Int)])
    func backsAreTurnedAsThePrinterAsks(_ back: BackSide, _ tumble: Bool, _ crossFeed: Int, _ feed: Int) {
        var job = Self.letter(.pwgRaster, pages: 2)
        (job.duplex, job.tumble, job.back) = (true, tumble, back)
        let front = job.transform(0), turned = job.transform(1)
        #expect([front.crossFeed, front.feed] == [1, 1] as [Int])
        #expect([turned.crossFeed, turned.feed] == [crossFeed, feed] as [Int])
        job.duplex = false
        let oneSided = job.transform(1)
        #expect([oneSided.crossFeed, oneSided.feed] == [1, 1] as [Int])
    }

    // ---- Apple raster ----

    @Test func urfHasItsFileHeaderPageCountAnd32BytePageHeaders() throws {
        var job = Self.letter(.urf, .gray8, pages: 3)
        (job.duplex, job.quality) = (true, 3)
        let w = try RasterWriter.forJob(job)
        for _ in 0..<3 { try w.write(try RasterPage.blank(width: 2550, height: 3300, color: .gray8)) }
        try w.finish()
        let b = w.drain()
        #expect(Array(b[0..<8]) == Array("UNIRAST".utf8) + [0])
        #expect(SpecDecoder.u32(b, 8) == 3)
        let h = Array(b[12..<44])
        #expect(Array(h[0..<12]) == [8, 0, 3, 3, 0, 0, 0, 0, 0, 0, 0, 0]) // 8 bits, sGray, long edge, draft
        #expect(SpecDecoder.u32(h, 12) == 2550)
        #expect(SpecDecoder.u32(h, 16) == 3300)
        #expect(SpecDecoder.u32(h, 20) == 300)
        #expect(h[24...].allSatisfy { $0 == 0 })
        #expect(Array(UrfWriter.header(Self.letter(.urf, .rgb8))[0..<4]) == [24, 1, 1, 4]) // sRGB, one-sided, normal
        job.tumble = true
        #expect(UrfWriter.header(job)[2] == 2)
    }

    @Test func urfReadsBackPixelForPixel() throws {
        let page = try Self.noise(61, 20, .gray8, seed: 3)
        let w = try RasterWriter.forJob(Self.job(.urf, .gray8, 1549, 508))
        try w.write(page)
        try w.finish()
        #expect(try SpecDecoder.urf(w.drain()) == [page.pixels])
    }

    // ---- PCLm ----

    @Test func pclmIsAPdfOfStripsWithAValidCrossReferenceTable() throws {
        let page = try Self.noise(40, 37, .rgb8, seed: 4)
        var job = Self.job(.pclm, .rgb8, 1016, 940, pages: 2)
        job.stripHeight = 16
        #expect([job.widthPixels, job.heightPixels] == [40, 37] as [Int])
        let w = try RasterWriter.forJob(job)
        try w.write(page)
        try w.write(page)
        try w.finish()
        let pdf = w.drain()
        let text = SpecDecoder.latin1(pdf)
        #expect(text.hasPrefix("%PDF-1.7\n%PCLm 1.0\n1 0 obj\n<</Type/Catalog/Pages 2 0 R>>\nendobj\n"))
        #expect(text.hasSuffix("%%EOF\n"))
        let decoded = try SpecDecoder.pclm(pdf)
        #expect(decoded.count == 2)
        for d in decoded {
            #expect(d.pixels == page.pixels)
            #expect(d.strips == [16, 16, 5]) // the last strip is shorter
            #expect(d.content == "0.72 0 0 0.72 0 0 cm\nq 40 0 0 16 0 21 cm /Image0 Do Q\nq 40 0 0 16 0 5 cm /Image1 Do Q\nq 40 0 0 5 0 0 cm /Image2 Do Q\n")
            #expect(d.mediaBox == "[0 0 28.8 26.6457]")
        }
        #expect(text.contains("/Type/Pages/Kids[3 0 R 8 0 R]/Count 2"))
    }

    @Test func pclmStripsCanBeRunLengthAndGrey() throws {
        let page = try Self.noise(33, 20, .gray8, seed: 5)
        var job = Self.job(.pclm, .gray8, 838, 508)
        (job.stripHeight, job.runLength) = (8, true)
        let w = try RasterWriter.forJob(job)
        try w.write(page)
        try w.finish()
        let pdf = w.drain()
        #expect(SpecDecoder.latin1(pdf).contains("/ColorSpace/DeviceGray/BitsPerComponent 8/Filter/RunLengthDecode"))
        #expect(try SpecDecoder.pclm(pdf).map(\.pixels) == [page.pixels])
    }

    @Test func runLengthFollowsPdfRunLengthDecode() {
        // 0x01: two bytes as they are; 0xFD (257-4): one byte four times; 0x00: one byte.
        #expect(RunLength.encode([1, 2, 3, 3, 3, 3, 4]) == [0x01, 1, 2, 0xFD, 3, 0x00, 4])
    }

    // ---- the writer's own checks ----

    @Test func aWriterRefusesPagesThatDontMatchAndJobsOutOfRange() throws {
        let w = try RasterWriter.forJob(Self.letter(.pwgRaster))
        #expect(throws: RasterError.pageMismatch) { try w.write(try RasterPage.blank(width: 100, height: 100, color: .gray8)) }
        #expect(throws: RasterError.pageMismatch) { try w.write(try RasterPage.blank(width: 2550, height: 3300, color: .rgb8)) }
        #expect(throws: RasterError.self) { try w.finish() }
        var noDpi = Self.letter(.urf)
        noDpi.dpi = 0
        #expect(throws: RasterError.self) { try RasterWriter.forJob(noDpi) }
        var wide = Self.letter(.urf)
        wide.widthHmm = 5_000_000
        #expect(throws: RasterError.self) { try RasterWriter.forJob(wide) }
        var noStrip = Self.letter(.pclm)
        noStrip.stripHeight = 0
        #expect(throws: RasterError.self) { try RasterWriter.forJob(noStrip) }
        #expect(throws: RasterError.self) { try RasterPage(width: 30_000, height: 30_000, color: .gray8, pixels: []) }
    }

    @Test func pagesAreMadeFromBgraEnlargedAndFitted() throws {
        let bgra: [UInt8] = [0, 0, 255, 255, 255, 255, 255, 255] // red, white
        #expect(try RasterPage.fromBgra(width: 2, height: 1, stride: 8, bgra, color: .rgb8).pixels == [255, 0, 0, 255, 255, 255])
        let grey = try RasterPage.fromBgra(width: 2, height: 1, stride: 8, bgra, color: .gray8)
        #expect(grey.pixels == [77, 255]) // BT.601: 0.299 of red
        let big = try grey.enlarged(2)
        #expect(big.pixels == [77, 77, 255, 255, 77, 77, 255, 255])
        // Cut on the right, padded with white at the bottom.
        #expect(try big.fitted(width: 3, height: 3).pixels == [77, 77, 255, 77, 77, 255, 255, 255, 255])
    }

    /// Pixels with runs and literals (a quarter white, the rest 0-3), the first four lines alike for the line repeat.
    static func noise(_ w: Int, _ h: Int, _ color: RasterColor, seed: UInt64) throws -> RasterPage {
        var state = seed &* 0x9E37_79B9_7F4A_7C15 | 1
        func next(_ n: UInt64) -> UInt8 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return UInt8(state % n)
        }
        let channels = RasterPage.channels(color)
        var pixels = (0..<w * h * channels).map { _ in next(4) == 0 ? UInt8(255) : next(4) }
        let line = w * channels
        if h > 4 { for y in 1..<4 { pixels.replaceSubrange(y * line..<(y + 1) * line, with: pixels[0..<line]) } }
        return try RasterPage(width: w, height: h, color: color, pixels: pixels)
    }

    static func mirror(_ p: RasterPage, across: Bool, down: Bool) -> [UInt8] {
        let bpp = p.bytesPerPixel
        var o = [UInt8](repeating: 0, count: p.pixels.count)
        for y in 0..<p.height {
            for x in 0..<p.width {
                let (sx, sy) = (across ? p.width - 1 - x : x, down ? p.height - 1 - y : y)
                for c in 0..<bpp { o[(y * p.width + x) * bpp + c] = p.pixels[(sy * p.width + sx) * bpp + c] }
            }
        }
        return o
    }
}

/// Decoders written from the specs, not from the encoders: PWG 5102.4 §4.3, Apple raster as CUPS reads it, PCLm's PDF.
enum SpecDecoder {
    struct Bad: Error { let why: String }

    static func u32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    /// Each byte as the character it is in ISO 8859-1, so text offsets are byte offsets.
    static func latin1(_ b: some Collection<UInt8>) -> String {
        String(String.UnicodeScalarView(b.map { Unicode.Scalar($0) }))
    }

    static func pwg(_ b: [UInt8]) throws -> [(pixels: [UInt8], transform: [Int])] {
        guard latin1(b.prefix(4)) == "RaS2" else { throw Bad(why: "no sync word") }
        var pages: [(pixels: [UInt8], transform: [Int])] = []
        var i = 4
        while i < b.count {
            let h = Array(b[i..<i + 1796])
            let (w, height, bpp) = (Int(u32(h, 372)), Int(u32(h, 376)), Int(u32(h, 388)) / 8)
            let t = [Int(Int32(bitPattern: u32(h, 456))), Int(Int32(bitPattern: u32(h, 460)))]
            i += 1796
            pages.append((try lines(b, &i, w, height, bpp), t))
        }
        return pages
    }

    static func urf(_ b: [UInt8]) throws -> [[UInt8]] {
        guard latin1(b.prefix(8)) == "UNIRAST\u{0}" else { throw Bad(why: "no sync word") }
        let count = Int(u32(b, 8))
        var pages: [[UInt8]] = []
        var i = 12
        for _ in 0..<count {
            let bpp = Int(b[i]) / 8
            let (w, h) = (Int(u32(b, i + 12)), Int(u32(b, i + 16)))
            i += 32
            pages.append(try lines(b, &i, w, h, bpp))
        }
        guard i == b.count else { throw Bad(why: "bytes after the last page") }
        return pages
    }

    /// Line repeat byte, then runs: 0-127 the next pixel n+1 times, 129-255 257-n pixels as they are (128 isn't expected).
    private static func lines(_ b: [UInt8], _ i: inout Int, _ w: Int, _ h: Int, _ bpp: Int) throws -> [UInt8] {
        var o = [UInt8](repeating: 0, count: w * h * bpp)
        var y = 0
        while y < h {
            let repeatCount = Int(b[i]) + 1
            i += 1
            var line = [UInt8](repeating: 0, count: w * bpp)
            var x = 0
            while x < w {
                let c = Int(b[i])
                i += 1
                guard c != 128 else { throw Bad(why: "run 128") }
                if c < 128 {
                    for k in 0...c { line.replaceSubrange((x + k) * bpp..<(x + k + 1) * bpp, with: b[i..<i + bpp]) }
                    i += bpp
                    x += c + 1
                } else {
                    let n = 257 - c
                    line.replaceSubrange(x * bpp..<(x + n) * bpp, with: b[i..<i + n * bpp])
                    i += n * bpp
                    x += n
                }
            }
            guard x == w else { throw Bad(why: "a run past the line's end") }
            for r in 0..<repeatCount { o.replaceSubrange((y + r) * line.count..<(y + r + 1) * line.count, with: line) }
            y += repeatCount
        }
        guard y == h else { throw Bad(why: "lines past the page's end") }
        return o
    }

    struct PclmPage {
        var pixels: [UInt8]
        var strips: [Int]
        var content: String
        var mediaBox: String
    }

    private static func int(_ text: String, after pattern: String) throws -> Int {
        guard let r = text.range(of: pattern, options: .regularExpression) else { throw Bad(why: "no \(pattern)") }
        let digits = text[r].reversed().prefix { $0.isNumber }.reversed()
        guard let n = Int(String(digits)) else { throw Bad(why: "no number in \(pattern)") }
        return n
    }

    static func pclm(_ pdf: [UInt8]) throws -> [PclmPage] {
        let text = latin1(pdf)
        let chars = Array(text.unicodeScalars)
        func slice(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(chars[from..<to])) }
        func find(_ s: String, from: Int) -> Int? {
            let needle = Array(s.unicodeScalars)
            var k = from
            while k + needle.count <= chars.count {
                if chars[k] == needle[0] && Array(chars[k..<k + needle.count]) == needle { return k }
                k += 1
            }
            return nil
        }
        guard text.hasSuffix("%%EOF\n"), let sx = text.range(of: "startxref\n", options: .backwards) else { throw Bad(why: "no startxref") }
        guard let xref = Int(text[sx.upperBound...].prefix { $0.isNumber }) else { throw Bad(why: "no xref offset") }
        let table = slice(xref, chars.count)
        guard table.hasPrefix("xref\n0 ") else { throw Bad(why: "no xref table at startxref") }
        let count = try int(table, after: #"^xref\n0 \d+"#)
        let rows = table.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2).prefix(count).map(String.init)
        guard rows.first == "0000000000 65535 f " else { throw Bad(why: "free entry") }
        let offsets = rows.map { Int($0.prefix(10)) ?? -1 }
        for n in 1..<count where !slice(offsets[n], min(chars.count, offsets[n] + 20)).hasPrefix("\(n) 0 obj\n") { throw Bad(why: "object \(n) not at its offset") }
        guard text.contains("trailer\n<</Size \(count)/Root 1 0 R>>") else { throw Bad(why: "trailer") }
        func obj(_ n: Int) throws -> String {
            guard let end = find("endobj\n", from: offsets[n]) else { throw Bad(why: "object \(n) not ended") }
            return slice(offsets[n], end)
        }
        func stream(_ n: Int) throws -> (data: [UInt8], dict: String) {
            let o = try obj(n)
            guard let start = o.range(of: ">>\nstream\n") else { throw Bad(why: "object \(n) has no stream") }
            let dict = String(o[..<start.lowerBound])
            let length = try int(dict, after: #"/Length \d+"#)
            let at = offsets[n] + o.unicodeScalars.distance(from: o.unicodeScalars.startIndex, to: start.upperBound)
            guard slice(at + length, at + length + 11) == "\nendstream\n" else { throw Bad(why: "stream \(n)'s length") }
            return (Array(pdf[at..<at + length]), dict)
        }
        let tree = try obj(2)
        guard let kidsRange = tree.range(of: #"/Kids\[[^\]]*\]"#, options: .regularExpression) else { throw Bad(why: "no kids") }
        let kids = tree[kidsRange].dropFirst(6).dropLast().split(separator: "R").compactMap { Int($0.split(separator: " ").first ?? "") }
        var result: [PclmPage] = []
        for kid in kids {
            let page = try obj(kid)
            guard let boxRange = page.range(of: #"/MediaBox\[[^\]]*\]"#, options: .regularExpression) else { throw Bad(why: "no MediaBox") }
            let box = String(page[boxRange].dropFirst(9))
            let content = String(decoding: try stream(try int(page, after: #"/Contents \d+"#)).data, as: UTF8.self)
            var pixels: [UInt8] = []
            var strips: [Int] = []
            for line in content.split(separator: "\n") where line.hasPrefix("q ") {
                let parts = line.split(separator: " ")
                guard parts.count == 11, parts[7] == "cm", parts[9] == "Do", let h = Int(parts[4]) else { throw Bad(why: "strip line \(line)") }
                let image = try int(page, after: "/" + String(parts[8].dropFirst()) + #" \d+"#)
                let (data, dict) = try stream(image)
                guard dict.contains("/Type/XObject/Subtype/Image") else { throw Bad(why: "not an image") }
                strips.append(h)
                if dict.contains("/FlateDecode") {
                    pixels += try BlackAndWhitePdfTests.Inflater.zlib(data)
                } else {
                    var i = 0
                    while data[i] != 128 {
                        if data[i] < 128 {
                            pixels += data[i + 1..<i + 2 + Int(data[i])]
                            i += Int(data[i]) + 2
                        } else {
                            pixels += [UInt8](repeating: data[i + 1], count: 257 - Int(data[i]))
                            i += 2
                        }
                    }
                    guard i == data.count - 1 else { throw Bad(why: "bytes after the run-length end") }
                }
            }
            result.append(PclmPage(pixels: pixels, strips: strips, content: content, mediaBox: box))
        }
        return result
    }
}
