import Foundation

/// A code a reader found on a page: its kind and what it says.
public struct ReadCode: Equatable, Sendable {
    public enum Symbology: Equatable, Sendable { case qrCode, code128, code39, other }

    public var symbology: Symbology
    public var text: String?

    public init(_ symbology: Symbology, _ text: String?) {
        self.symbology = symbology
        self.text = text
    }
}

/// Reads the QR codes and barcodes on a page: Vision's barcode request in PrintMac (`VisionSeparatorCodes`), a fake in
/// tests. Windows reads them with ZXing.Net; the rules about what counts (`SeparatorCodes`) are PrintCore's.
public protocol SeparatorCodeReader: Sendable {
    /// The codes on `page`, in any direction. `qrCodes` false: QR codes aren't looked for (the page is crowded with marks
    /// shaped like their corner squares), only Code 128 and Code 39 barcodes.
    func codes(on page: GrayImage, qrCodes: Bool) -> [ReadCode]
}

/// Separator sheets marked with a code that says PATCHT: a QR code (the one on Inkvolt Print's own sheet, and
/// Paperless-ngx's separator pages, whose default text it is), or a Code 128 or Code 39 barcode. The page is read as it is,
/// so it may be fed either way round and turned; a code saying anything else (an invoice's QR code, a parcel label)
/// separates nothing. The Windows Core's `SeparatorCodes`; the reading itself is a `SeparatorCodeReader`'s.
///
/// A scan is hostile input: a copy larger than `maxSide` is read reduced, and a page crowded with marks shaped like a QR
/// code's corner squares (more than `maxFinderMarks`) isn't searched for one (ZXing's search time grows with the cube of
/// their number, and Vision's isn't promised); such a page is no separator sheet anyway.
public enum SeparatorCodes {
    /// What a separator's code says (Patch T's name, as Paperless-ngx writes it).
    public static let text = "PATCHT"

    /// The longest side read; a larger copy is reduced first (the app's analysis copy is 1,100 pixels).
    public static let maxSide = 1700

    /// Most marks shaped like a QR code's corner square (dark, light, dark three times as wide, light, dark) a page may have.
    public static let maxFinderMarks = 3000

    /// The kind of code on the page that says `text`: `.qrCode`, `.barcode`, or nil (no reader, or nothing says it).
    public static func find(_ img: GrayImage, reader: (any SeparatorCodeReader)?) -> SeparatorKind? {
        guard let reader, img.width >= 21, img.height >= 21, img.pixels.count == img.width * img.height else { return nil }
        let page = reduced(img)
        let qr = finderMarks(page) <= maxFinderMarks
        let codes = reader.codes(on: page, qrCodes: qr)
        if qr && codes.contains(where: { $0.symbology == .qrCode && says($0.text) }) { return .qrCode }
        if codes.contains(where: { ($0.symbology == .code128 || $0.symbology == .code39) && says($0.text) }) { return .barcode }
        return nil
    }

    /// The code says `text`: any case, with spaces around it, as Paperless-ngx compares; nothing longer than 64 characters.
    public static func says(_ said: String?) -> Bool {
        guard let said, said.count <= 64 else { return false }
        return said.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(text) == .orderedSame
    }

    /// The QR code of `text` as its modules, true for dark, `[row][column]`, without its quiet zone (four modules of white
    /// around it): version 1 at the highest error correction (H, 30%), so smudges and a punched hole still read. Made once with
    /// Core Image's QR generator (Windows makes it with ZXing.Net; any valid encoding reads the same).
    public static func qrModules() -> [[Bool]] { patchtQr.map { row in row.map { $0 == "1" } } }

    private static let patchtQr = [
        "111111100111101111111", "100000100000001000001", "101110100101001011101", "101110100010001011101",
        "101110101111001011101", "100000100010001000001", "111111101010101111111", "000000001101100000000",
        "001100111001111010000", "010101001100111000011", "110010111111001001110", "101010010010101111011",
        "000111111001100100110", "000000001001000001101", "111111101011110100100", "100000100001111111011",
        "101110100001010111001", "101110101100111011010", "101110101111011100000", "100000100000001001100",
        "111111100010011010010",
    ]

    /// The image, reduced by a whole factor (the average of each square) until its longer side is at most `maxSide`.
    static func reduced(_ img: GrayImage) -> GrayImage {
        let k = (max(img.width, img.height) + maxSide - 1) / maxSide
        if k <= 1 { return img }
        let w = img.width / k, h = img.height / k
        var pixels = [UInt8](repeating: 0, count: w * h)
        img.pixels.withUnsafeBufferPointer { src in
            for y in 0..<h {
                for x in 0..<w {
                    var sum = 0
                    for dy in 0..<k {
                        let row = (y * k + dy) * img.width + x * k
                        for dx in 0..<k { sum += Int(src[row + dx]) }
                    }
                    pixels[y * w + x] = UInt8(sum / (k * k))
                }
            }
        }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    /// How many times a row of the page, made black and white (`blackAndWhite`), crosses a mark in a QR corner square's
    /// proportions (1:1:3:1:1, each within half a module, as ZXing's finder judges them); counting stops just past
    /// `maxFinderMarks`.
    static func finderMarks(_ img: GrayImage) -> Int {
        let dark = blackAndWhite(img)
        let w = img.width
        var count = 0
        for y in 0..<img.height {
            // The last five runs, newest first: shifted along as each run ends.
            var runs = [0, 0, 0, 0, 0]
            var filled = 0
            var x = 0
            let row = y * w
            while x < w && !dark[row + x] { x += 1 }
            while x < w {
                let isDark = dark[row + x]
                let start = x
                while x < w && dark[row + x] == isDark { x += 1 }
                runs = [x - start, runs[0], runs[1], runs[2], runs[3]]
                filled += 1
                // A mark is dark-light-dark-light-dark, so it ends on a dark run.
                if isDark && filled >= 5 && looksLikeFinder(runs) {
                    count += 1
                    if count > maxFinderMarks { return count }
                }
            }
        }
        return count
    }

    private static func looksLikeFinder(_ r: [Int]) -> Bool {
        let total = r[0] + r[1] + r[2] + r[3] + r[4]
        if total < 7 { return false }
        let module = Double(total) / 7
        let variance = module / 2
        return abs(module - Double(r[0])) < variance && abs(module - Double(r[1])) < variance
            && abs(3 * module - Double(r[2])) < 3 * variance && abs(module - Double(r[3])) < variance
            && abs(module - Double(r[4])) < variance
    }

    /// Black and white as ZXing's hybrid binarizer makes it: each 8 × 8 block's threshold the average of the 5 × 5 blocks
    /// around it, a block with too little contrast (24 levels) taken as light. True for dark.
    static func blackAndWhite(_ img: GrayImage) -> [Bool] {
        let w = img.width, h = img.height, b = 8
        let bw = (w + b - 1) / b, bh = (h + b - 1) / b
        var averages = [Int](repeating: 0, count: bw * bh)
        img.pixels.withUnsafeBufferPointer { p in
            for by in 0..<bh {
                for bx in 0..<bw {
                    var sum = 0, n = 0, lo = 255, hi = 0
                    for y in (by * b)..<min(h, by * b + b) {
                        for x in (bx * b)..<min(w, bx * b + b) {
                            let v = Int(p[y * w + x])
                            sum += v
                            n += 1
                            lo = min(lo, v)
                            hi = max(hi, v)
                        }
                    }
                    averages[by * bw + bx] = hi - lo > 24 ? sum / max(1, n) : lo / 2
                }
            }
        }
        var dark = [Bool](repeating: false, count: w * h)
        img.pixels.withUnsafeBufferPointer { p in
            for by in 0..<bh {
                for bx in 0..<bw {
                    var sum = 0, n = 0
                    for ny in max(0, by - 2)...min(bh - 1, by + 2) {
                        for nx in max(0, bx - 2)...min(bw - 1, bx + 2) {
                            sum += averages[ny * bw + nx]
                            n += 1
                        }
                    }
                    let threshold = sum / n
                    for y in (by * b)..<min(h, by * b + b) {
                        for x in (bx * b)..<min(w, bx * b + b) { dark[y * w + x] = Int(p[y * w + x]) <= threshold }
                    }
                }
            }
        }
        return dark
    }
}
