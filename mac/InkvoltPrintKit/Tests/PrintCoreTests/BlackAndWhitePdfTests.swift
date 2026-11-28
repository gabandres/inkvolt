import Foundation
import Testing
import TestTiming
@testable import PrintCore

/// Ported from BlackAndWhitePdfTests.cs: small black-and-white PDFs (roadmap 4.4): `CcittG4` read back by a decoder written
/// here from T.6 alone, the code tables checked as codes, `Bilevel`'s black and white, and `PdfWriter`'s 1-bit pages.
/// Inkvolt PDF for Mac's tests render the same output through MuPDF (`CcittG4RenderTests`). Adapted: .NET's `Random` becomes
/// a fixed generator here (other images, the same kinds); a size refused throws `BitImage.SizeError`; Flate is PrintCore's
/// own (`Deflate`: one block of fixed Huffman codes), read back by an inflater written here from RFC 1951, where Windows
/// reads .NET's `ZLibStream` back with itself. Mac only: theFlateCodeReadsBackWhateverItHolds, and the preset tests at the
/// end (Windows' are in ScanPresetTests: the Mac scans no black and white, so only a smaller file saves one bit).
@Suite(.offThePool)
struct BlackAndWhitePdfTests {
    @Test func theCodeTablesAreTheStandardsSizesAndPrefixFree() {
        #expect(CcittG4.whiteTerminating.count == 64)
        #expect(CcittG4.blackTerminating.count == 64)
        #expect(CcittG4.whiteMakeUp.count == 27)
        #expect(CcittG4.blackMakeUp.count == 27)
        #expect(CcittG4.extended.count == 13)
        // Each colour's codes, with the shared make-ups and EOL, can be told apart reading left to right.
        for codes in [CcittG4.whiteTerminating + CcittG4.whiteMakeUp + CcittG4.extended + [(1, 12)],
                      CcittG4.blackTerminating + CcittG4.blackMakeUp + CcittG4.extended + [(1, 12)]] {
            let words = codes.map { c in String(repeating: "0", count: c.length - String(c.code, radix: 2).count) + String(c.code, radix: 2) }
            #expect(Set(words).count == words.count)
            for a in words { #expect(!words.contains { $0 != a && $0.hasPrefix(a) }, "\(a) begins another code") }
        }
    }

    @Test(arguments: [(1, 1), (7, 3), (8, 8), (13, 40), (200, 60), (1728, 20), (5000, 6)]) // 5000: runs past 2560, the extended make-ups twice
    func randomImagesComeBackBitForBit(_ width: Int, _ height: Int) throws {
        var rng = Rng(UInt64(width * 31 + height))
        for density in [0.0, 0.02, 0.5, 0.97, 1.0] {
            let image = try Self.random(width, height, density, &rng)
            #expect(try G4Decoder.decode(CcittG4.encode(image), width, height).bits == image.bits, "density \(density)")
        }
    }

    @Test func runsOfEveryLengthComeBack() throws {
        // Rows of one black run of each length from 0 to 2700 at a moving start: every terminating and make-up code.
        let width = 2800, rows = 2701
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * rows)
        for y in 0..<rows {
            var x = y % 50
            while x < y % 50 + y && x < width {
                bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7)
                x += 1
            }
        }
        let image = try BitImage(width, rows, bits)
        #expect(try G4Decoder.decode(CcittG4.encode(image), width, rows).bits == image.bits)
    }

    @Test func verticalEdgesAndStripesUseEveryMode() throws {
        // Edges that move by -3..+3 a row (vertical mode), by more (horizontal), and runs that end above (pass mode).
        let (width, height) = (300, 120)
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        func set(_ x: Int, _ y: Int) { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
        for y in 0..<height {
            let start = 50 + (y * 7 % 13) - 6
            for x in start..<(start + 30 + y % 5) { set(x, y) }
            if y % 2 == 0 { for x in 150..<160 { set(x, y) } }
            for x in (200 + y % 40)..<(205 + y % 40) { set(x, y) }
        }
        let image = try BitImage(width, height, bits)
        #expect(try G4Decoder.decode(CcittG4.encode(image), width, height).bits == image.bits)
    }

    @Test func aPageOfLinesIsFarSmallerThanItsBytes() throws {
        let image = try Self.textLike(2550, 3300)
        let g4 = try CcittG4.encode(image)
        #expect(g4.count * 10 < image.bits.count, "\(g4.count) bytes of G4 for \(image.bits.count) bytes of pixels")
        #expect(try G4Decoder.decode(g4, image.width, image.height).bits == image.bits)
    }

    @Test func hostileSizesAreRefusedBeforeAnythingIsAllocated() {
        #expect(throws: BitImage.SizeError.outOfRange) { try BitImage(0, 10, []) }
        #expect(throws: BitImage.SizeError.outOfRange) { try BitImage(100_000, 100_000, []) }
        #expect(throws: BitImage.SizeError.outOfRange) { try BitImage(Int.max, 2, []) }
        #expect(throws: BitImage.SizeError.tooFewBytes) { try BitImage(16, 2, [0, 0, 0]) }
        #expect(throws: BitImage.SizeError.outOfRange) { try BitImage.fromGray([UInt8](repeating: 0, count: 10), 4, 4, threshold: 128) }
        #expect(throws: BitImage.SizeError.outOfRange) { try Bilevel.fromScan([UInt8](repeating: 0, count: 10), 4, 4, dpi: 300) }
        #expect(throws: BitImage.SizeError.outOfRange) { try BitImage.white(-1, 5) }
    }

    @Test func aGreyPageOnShadedPaperIsBlackTextOnWhite() throws {
        // Paper from 240 on the left to 170 on the right (a lid's shadow), text bars of 40 on it: the shadow is paper, not ink.
        let (w, h) = (600, 400)
        var gray = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<w { gray[y * w + x] = UInt8(240 - 70 * x / w) } }
        for line in 0..<8 {
            for y in (40 + line * 40)..<(52 + line * 40) { for x in 50..<550 where x % 9 != 0 { gray[y * w + x] = 40 } }
        }
        let bits = try Bilevel.fromScan(gray, w, h, dpi: 150)
        #expect(!bits[580, 20]) // the darkest paper
        #expect(!bits[20, 20])
        #expect(bits[300, 46]) // a bar
        #expect(bits[540, 326]) // a bar on the shadow
        var black = 0
        for y in 0..<h { for x in 0..<w where bits[x, y] { black += 1 } }
        #expect((8 * 12 * 420)...(8 * 12 * 500) ~= black, "\(black)")
    }

    @Test(arguments: [([255, 255, 255, 30], 96), ([20, 20, 230, 230], 96), ([100, 100, 220, 220], 101)] as [([UInt8], Int)]) // almost all paper: never below the floor
    func theLevelPartsInkFromPaperWithinBounds(_ levels: [UInt8], _ expected: Int) {
        #expect(Bilevel.threshold(levels.flatMap { [UInt8](repeating: $0, count: 100) }) == expected)
    }

    @Test func aBlackAndWhitePageIsWrittenAtOneBitAsG4() throws {
        // Scattered runs (as a scan's specks and strokes are): G4 is the smaller.
        var rng = Rng(3)
        let image = try Self.random(850, 1100, 0.05, &rng)
        let bytes = try PdfWriter.write([.blackAndWhite(image, dpi: 100, words: [PdfWriter.Word("Hello", x: 100, y: 100, width: 200, height: 20)])], title: "Small")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("/BitsPerComponent 1 /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns 850 /Rows 1100 >>"))
        #expect(text.contains("/MediaBox [0 0 612 792]"))
        #expect(text.contains("/ColorSpace /DeviceGray"))
        #expect(text.contains("3 Tr")) // the text layer, as on a JPEG page
        #expect(!text.contains("DCTDecode"))
        // The stream holds exactly the encoder's bytes.
        let g4 = try CcittG4.encode(image)
        let marker = Array("CCITTFaxDecode".utf8), streamWord = Array("stream\n".utf8)
        guard let filterAt = Self.find(marker, in: bytes, from: 0), let streamAt = Self.find(streamWord, in: bytes, from: filterAt) else {
            Issue.record("no CCITT stream")
            return
        }
        let at = streamAt + streamWord.count
        #expect(Array(bytes[at..<(at + g4.count)]) == g4)
    }

    @Test func fineEvenPatternsGoAsFlateWhenThatIsSmaller() throws {
        // A checkerboard of single pixels: every run 1 long, G4's worst case; Flate packs the repeat in a few bytes.
        let (w, h) = (512, 256)
        var bits = [UInt8](repeating: 0, count: w / 8 * h)
        for y in 0..<h { for i in 0..<(w / 8) { bits[y * (w / 8) + i] = y % 2 == 0 ? 0xAA : 0x55 } }
        let image = try BitImage(w, h, bits)
        let (filter, data) = try PdfWriter.oneBit(image)
        #expect(filter == "/Filter /FlateDecode")
        #expect(data.count < (try CcittG4.encode(image)).count)
        // Flate holds the rows with black as 0 (DeviceGray), the bits past each row's end 0.
        #expect(try Inflater.zlib(data) == bits.map { ~$0 })

        let odd = try BitImage(5, 1, [0b1010_0000])
        #expect(odd.inverted() == [0b0101_1000])
    }

    @Test func jpegPagesAreWrittenAsBefore() throws {
        let jpeg = TestJpeg.build(width: 2550, height: 3300, dnlHeight: nil)
        let bytes = try PdfWriter.write([PdfWriter.Page(jpeg, dpi: 300), .blackAndWhite(try BitImage.white(30, 30), dpi: 300)], title: "Mixed")
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("/BitsPerComponent 8 /Filter /DCTDecode"))
        #expect(text.contains("/BitsPerComponent 1 /Filter /CCITTFaxDecode"))
    }

    @Test func theFlateCodeReadsBackWhateverItHolds() throws {
        // Mac only (Windows uses .NET's): PrintCore's own Deflate on nothing, one byte, text, noise and long repeats, read
        // back by the inflater here, its zlib header and Adler-32 checked.
        var rng = Rng(11)
        let noise = (0..<5000).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        let text = Array(String(repeating: "Inkvolt Print turns a stack over. ", count: 400).utf8)
        let runs = [UInt8](repeating: 0, count: 100_000) + [UInt8](repeating: 0xFF, count: 70_000)
        for data in [[], [7], text, noise, runs, noise + runs + text] as [[UInt8]] {
            let packed = Deflate.zlib(data)
            #expect(try Inflater.zlib(packed) == data)
        }
        #expect(Deflate.zlib(runs).count < 2000)
        #expect(Deflate.zlib(text).count < text.count / 10)
    }

    // ---- The preset's smaller file (Mac only, from ScanPresetTests.cs) ----

    private static func input() -> InputCaps {
        InputCaps(minWidth: 0, maxWidth: 2550, minHeight: 0, maxHeight: 4200, colorModes: ["RGB24", "Grayscale8"], documentFormats: ["image/jpeg"],
                  resolutions: [150, 300, 600], intents: ["Document"])
    }

    private static let caps = ScannerCapabilities(version: "2.6", makeAndModel: "Test", uuid: nil, platen: input(), adf: input(), adfDuplex: true)

    private static func doc(_ change: (inout ScanPreset) -> Void) -> ScanPreset {
        var p = ScanPresets.builtIns()[0]
        change(&p)
        return p
    }

    private static func plan(_ p: ScanPreset) -> PresetPlan {
        PresetPlan.plan(p, caps, feederLoaded: nil, ocrAvailable: true, metric: false)
    }

    @Test func aSmallerFileIsScannedGreyAndSavedAtOneBitOnlyForAPdf() {
        let small = Self.plan(Self.doc { $0.color = true; $0.smallerFile = true; $0.fileType = .pdf })
        #expect(small.request.color == .grayscale && small.oneBit)
        let jpeg = Self.plan(Self.doc { $0.color = true; $0.smallerFile = true; $0.fileType = .jpeg })
        #expect(jpeg.request.color == .color && !jpeg.oneBit)
        let photos = Self.plan(Self.doc { $0.color = true; $0.smallerFile = true; $0.findPhotos = true; $0.source = .glass })
        #expect(photos.request.color == .color && !photos.oneBit)
        // Photos are looked for on the glass only: from the feeder the pages are black and white.
        #expect(Self.plan(Self.doc { $0.smallerFile = true; $0.findPhotos = true; $0.source = .feeder }).oneBit)
        #expect(ScanPresetText.summary(Self.doc { $0.color = true; $0.smallerFile = true; $0.fileType = .jpeg }).contains("color, 300 dpi"))
        #expect(ScanPresetText.summary(Self.doc { $0.color = true; $0.smallerFile = true; $0.findPhotos = true; $0.source = .glass }).contains("color, 300 dpi"))
        #expect(ScanPresetText.summary(Self.doc { $0.smallerFile = true }).contains("black and white, 300 dpi, smaller file"))
        #expect(!Self.plan(Self.doc { _ in }).oneBit)
        // Inkvolt PDF's black-and-white presets: saved at 1 bit too.
        #expect(Self.plan(Self.doc { $0.blackAndWhite = true; $0.color = false }).oneBit)
    }

    @Test func oldPresetsHaveNoSmallerFileAndItsFieldIsWindows() throws {
        let json = #"{"Version":1,"Items":[{"Id":"abc","Name":"Old"}]}"#
        let old = ScanPresets.normalize(try JSONDecoder().decode(ScanPresetSettings.self, from: Data(json.utf8)))[0]
        #expect(!old.smallerFile)
        let written = try JSONEncoder().encode(ScanPresetSettings(items: [Self.doc { $0.smallerFile = true }]))
        #expect(String(decoding: written, as: UTF8.self).contains(#""SmallerFile":true"#))
    }

    // ---- Helpers ----

    /// A small fixed generator (xorshift), so every run makes the same images.
    struct Rng {
        var state: UInt64
        init(_ seed: UInt64) { state = seed &* 0x9E37_79B9_7F4A_7C15 | 1 }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    }

    static func random(_ width: Int, _ height: Int, _ density: Double, _ rng: inout Rng) throws -> BitImage {
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            // Runs, not single pixels: a run's colour flips with the density's chance, so long and short runs both come up.
            var black = rng.unit() < density
            for x in 0..<width {
                if rng.unit() < 0.08 { black = rng.unit() < density }
                if black { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
            }
        }
        return try BitImage(width, height, bits)
    }

    /// A page of "text": lines of short black strokes on white, letters' worth of edges.
    static func textLike(_ width: Int, _ height: Int) throws -> BitImage {
        let stride = (width + 7) / 8
        var bits = [UInt8](repeating: 0, count: stride * height)
        var rng = Rng(7)
        var top = height / 12
        while top + 30 < height * 11 / 12 {
            var x = width / 10
            while x < width * 9 / 10 {
                let letter = 10 + Int(rng.next() % 14)
                let tall = rng.next() % 3 == 0
                for y in (tall ? top : top + 10)..<(top + 30) {
                    for dx in 0..<letter where dx < 4 || dx >= letter - 4 || [10, 11, 28, 29].contains(y - top) {
                        bits[y * stride + ((x + dx) >> 3)] |= 0x80 >> UInt8((x + dx) & 7)
                    }
                }
                x += letter + 4 + (rng.next() % 6 == 0 ? 16 : 0)
            }
            top += 50
        }
        return try BitImage(width, height, bits)
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Int? {
        guard needle.count <= haystack.count else { return nil }
        var i = from
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0] && Array(haystack[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    struct DecodeError: Error { let why: String }

    /// A T.6 (Group 4) decoder written from the standard, independent of the encoder's code: only for these tests.
    enum G4Decoder {
        private static func table(_ terminating: [(code: Int, length: Int)], _ makeUp: [(code: Int, length: Int)]) -> [String: Int] {
            var table: [String: Int] = [:]
            func key(_ c: (code: Int, length: Int)) -> String { "\(c.code)/\(c.length)" }
            for i in 0..<64 { table[key(terminating[i])] = i }
            for i in 0..<27 { table[key(makeUp[i])] = (i + 1) * 64 }
            for i in 0..<13 { table[key(CcittG4.extended[i])] = (i + 28) * 64 }
            return table
        }

        private static let white = table(CcittG4.whiteTerminating, CcittG4.whiteMakeUp)
        private static let black = table(CcittG4.blackTerminating, CcittG4.blackMakeUp)

        static func decode(_ data: [UInt8], _ width: Int, _ height: Int) throws -> BitImage {
            var pos = 0
            func bit() throws -> Int {
                guard pos < data.count * 8 else { throw DecodeError(why: "ran out of data") }
                defer { pos += 1 }
                return Int(data[pos >> 3] >> UInt8(7 - (pos & 7)) & 1)
            }
            let stride = (width + 7) / 8
            var bits = [UInt8](repeating: 0, count: stride * height)
            var above = [Bool](repeating: false, count: width)
            for y in 0..<height {
                var line = [Bool](repeating: false, count: width)
                var a0 = -1
                var isBlack = false
                while a0 < width {
                    let start = max(a0, 0)
                    // b1: the first changing element on the row above, right of a0, of the colour opposite a0's (the element
                    // before it is a0's colour; before the row, white); b2: the next changing element after it.
                    var b1 = a0 + 1
                    while b1 < width && !(above[b1] != isBlack && (b1 == 0 ? false : above[b1 - 1]) == isBlack) { b1 += 1 }
                    var b2 = b1 + 1
                    if b1 >= width { b2 = width } else { while b2 < width && above[b2] == above[b1] { b2 += 1 } }
                    switch try mode(bit) {
                    case "P":
                        fill(&line, start, b2, isBlack)
                        a0 = b2
                    case "H":
                        let r1 = try run(bit, isBlack)
                        let r2 = try run(bit, !isBlack)
                        fill(&line, start, start + r1, isBlack)
                        fill(&line, start + r1, start + r1 + r2, !isBlack)
                        a0 = start + r1 + r2
                    case let offset:
                        let a1 = b1 + (Int(offset) ?? 0)
                        fill(&line, start, a1, isBlack)
                        a0 = a1
                        isBlack.toggle()
                    }
                }
                for x in 0..<width where line[x] { bits[y * stride + (x >> 3)] |= 0x80 >> UInt8(x & 7) }
                above = line
            }
            // The end: two EOLs.
            for _ in 0..<2 {
                var eol = 0
                for _ in 0..<12 { eol = eol << 1 | (try bit()) }
                if eol != 1 { throw DecodeError(why: "no EOL at the end") }
            }
            return try BitImage(width, height, bits)
        }

        private static func fill(_ line: inout [Bool], _ from: Int, _ to: Int, _ black: Bool) {
            var x = from
            while x < to && x < line.count {
                line[x] = black
                x += 1
            }
        }

        private static func mode(_ bit: () throws -> Int) throws -> String {
            var code = ""
            while code.count < 12 {
                code += String(try bit())
                switch code {
                case "1": return "0"
                case "011": return "1"
                case "000011": return "2"
                case "0000011": return "3"
                case "010": return "-1"
                case "000010": return "-2"
                case "0000010": return "-3"
                case "001": return "H"
                case "0001": return "P"
                default: continue
                }
            }
            throw DecodeError(why: "no mode code")
        }

        private static func run(_ bit: () throws -> Int, _ isBlack: Bool) throws -> Int {
            let table = isBlack ? black : white
            var total = 0
            while true {
                var code = 0, length = 0
                var found: Int?
                repeat {
                    code = code << 1 | (try bit())
                    length += 1
                    if length > 13 { throw DecodeError(why: "no run code") }
                    found = table["\(code)/\(length)"]
                } while found == nil
                total += found!
                if found! < 64 { return total }
            }
        }
    }

    /// zlib's inflate written from RFC 1950 and 1951 for these tests: stored and fixed-Huffman blocks (what `Deflate` writes;
    /// a dynamic block is refused), the header and Adler-32 checked.
    enum Inflater {
        static func zlib(_ data: [UInt8]) throws -> [UInt8] {
            guard data.count >= 6, data[0] & 0x0F == 8, (Int(data[0]) << 8 | Int(data[1])) % 31 == 0 else { throw DecodeError(why: "not zlib") }
            var pos = 16 // bits read, after the two header bytes
            func bits(_ n: Int) throws -> Int {
                var v = 0
                for i in 0..<n {
                    guard pos < (data.count - 4) * 8 else { throw DecodeError(why: "ran out of data") }
                    v |= Int(data[pos >> 3] >> UInt8(pos & 7) & 1) << i
                    pos += 1
                }
                return v
            }
            /// Each code length's symbols in order, from every symbol's length.
            func byLength(_ lengths: [Int]) -> [[Int]] { (0...15).map { len in lengths.indices.filter { lengths[$0] == len } } }
            func huffman(_ table: [[Int]]) throws -> Int {
                // Canonical codes from the lengths (RFC 1951 3.2.2), read a bit at a time.
                var code = 0, first = 0
                for len in 1...15 {
                    code |= try bits(1)
                    if code - first < table[len].count { return table[len][code - first] }
                    first = (first + table[len].count) << 1
                    code <<= 1
                }
                throw DecodeError(why: "no Huffman code")
            }
            let fixedLiteral = byLength((0..<288).map { $0 < 144 ? 8 : $0 < 256 ? 9 : $0 < 280 ? 7 : 8 })
            let fixedDistance = byLength([Int](repeating: 5, count: 30))
            var out: [UInt8] = []
            var last = 0
            repeat {
                last = try bits(1)
                switch try bits(2) {
                case 0:
                    pos = (pos + 7) / 8 * 8
                    let len = try bits(16), nlen = try bits(16)
                    if len != ~nlen & 0xFFFF { throw DecodeError(why: "stored length") }
                    for _ in 0..<len { out.append(UInt8(try bits(8))) }
                case 1:
                    while true {
                        let symbol = try huffman(fixedLiteral)
                        if symbol < 256 {
                            out.append(UInt8(symbol))
                            continue
                        }
                        if symbol == 256 { break }
                        let c = symbol - 257
                        guard c < Deflate.lengthBase.count else { throw DecodeError(why: "length code") }
                        let length = Deflate.lengthBase[c] + (try bits(Deflate.lengthExtra[c]))
                        let d = try huffman(fixedDistance)
                        let distance = Deflate.distanceBase[d] + (try bits(Deflate.distanceExtra[d]))
                        guard distance <= out.count else { throw DecodeError(why: "distance past the start") }
                        for _ in 0..<length { out.append(out[out.count - distance]) }
                    }
                default:
                    throw DecodeError(why: "a block kind this inflater doesn't read")
                }
            } while last == 0
            var (a, b): (UInt32, UInt32) = (1, 0)
            for byte in out {
                a = (a + UInt32(byte)) % 65_521
                b = (b + a) % 65_521
            }
            let tail = data.suffix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if tail != b << 16 | a { throw DecodeError(why: "Adler-32") }
            return out
        }
    }
}
