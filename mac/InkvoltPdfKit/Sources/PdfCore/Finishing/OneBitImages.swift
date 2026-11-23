import Foundation
import PrintCore

/// Black-and-white pictures made smaller (roadmap 4.8, the Windows app's `OneBitImages`), for Reduce File Size and
/// Recognize Text's cleaned pages. A picture already at 1 bit (a black-and-white scan, a stencil) is coded again,
/// losslessly, as JBIG2's generic region, CCITT G4 or Flate (PrintCore's `PdfWriter.oneBitData`), whichever is smallest,
/// only when that is smaller than it is now, and only after the new coding is drawn back the same pixel for pixel. A grey
/// picture that is a scan of text (`looksBlackAndWhite`) becomes 1 bit only when the user asks for black and white: that is
/// the one loss, the thresholding (PrintCore's `Bilevel`); never JBIG2's symbol matching, which can put one digit in place of
/// another.
///
/// Mac difference: MuPDF's objects belong to the document's thread, so the work is in three steps where Windows has two:
/// `job` reads what a picture needs on the document's thread, `run` draws and codes it (several pictures at once, each in
/// an engine of its own), and `apply` makes the change, back on the document's thread.
enum OneBitImages {
    /// A picture this large is left as it is (its drawing alone would take over a gigabyte).
    static let maxPixels = 120_000_000
    /// The smallest grey picture taken for a scanned page: about a third of a letter page at 150 dpi.
    static let minScanPixels = 700_000
    /// The smallest 1-bit picture coded again, in bytes as stored.
    static let minRecodedBytes = 4096

    /// Draws a one-image page (the picture's dictionary entries and stream) at one pixel a sample, as RGB; nil when it can't.
    typealias Draw = @Sendable (_ dict: String, _ stream: [UInt8], _ width: Int, _ height: Int) -> [UInt8]?

    /// What a picture's change needs, read from the document.
    struct Job: Sendable {
        enum Kind: Sendable {
            /// A 1-bit picture coded again: its /Filter and /DecodeParms written out.
            case recode(filterEntries: String)
            /// A grey or colour scan made black and white: its dictionary entries to draw it on its own, the resolution it
            /// is shown at.
            case threshold(source: String, dpi: Int)
        }

        var kind: Kind
        var raw: [UInt8]
        var width: Int, height: Int
    }

    /// The new samples: how they are coded, and whether the picture became 1 bit (`threshold`).
    struct Coded: Sendable {
        var coding: PdfWriter.OneBitCoding
        var data: [UInt8]
        var madeOneBit: Bool
    }

    /// The image stream's filter entries for `coding` (any older parameters removed).
    static func setCoding(_ image: PObj, _ coding: PdfWriter.OneBitCoding, _ width: Int, _ height: Int) {
        let doc = image.doc
        image.remove("DecodeParms")
        switch coding {
        case .ccittG4:
            image.set("Filter", doc.name("CCITTFaxDecode"))
            image.set("DecodeParms", doc.dict([("K", doc.int(-1)), ("Columns", doc.int(width)), ("Rows", doc.int(height))]))
        case .jbig2:
            image.set("Filter", doc.name("JBIG2Decode"))
        case .flate:
            image.set("Filter", doc.name("FlateDecode"))
        }
    }

    /// A 1-bit picture to code again (Windows' `Recode`, its reading half): nil when it isn't 1 bit, is too small or too
    /// large, is JBIG2 already (perhaps with shared symbols) or encrypted on its own, or its filters can't be written out.
    /// Its colours, decode array and mask stay as they are: only how its samples are packed changes.
    static func recodeJob(_ image: PObj) -> Job? {
        // A small picture (an icon, a rule) has little to save and costs two drawings: left as it is.
        guard image.isStream, let raw = image.rawStreamData, raw.count >= minRecodedBytes else { return nil }
        let bpc = image.int("BitsPerComponent")
        let stencil = isStencil(image)
        if bpc != 1 && !(stencil && bpc == nil) { return nil }
        // One sample a pixel only: a 1-bit RGB or CMYK picture has three or four, which a grey drawing would mix up.
        if !stencil && !oneComponent(image["ColorSpace"]) { return nil }
        let w = image.int("Width") ?? 0, h = image.int("Height") ?? 0
        guard w > 0, h > 0, w <= maxPixels / h, w * h <= BitImage.maxPixels else { return nil }
        guard let filters = Optimizer.filters(image),
              !filters.contains(where: { ["JBIG2Decode", "JPXDecode", "DCTDecode", "Crypt"].contains($0) }),
              let entries = filterEntries(image) else { return nil }
        return Job(kind: .recode(filterEntries: entries), raw: raw, width: w, height: h)
    }

    /// A grey or colour picture of a scanned page of text to make black and white (Windows' `Threshold`, its reading
    /// half). Only on the user's request. Nil when it has a mask, or is too small or too large.
    /// - Parameters:
    ///   - source: the picture's dictionary entries to draw it on its own (8 bits, a device colour space).
    ///   - dpi: the resolution it is shown at, for the cleanup's speck size.
    static func thresholdJob(_ image: PObj, source: String, dpi: Int) -> Job? {
        guard image.isStream, !image.has("SMask"), !image.has("Mask"), let raw = image.rawStreamData else { return nil }
        let w = image.int("Width") ?? 0, h = image.int("Height") ?? 0
        guard w > 0, h > 0, w <= maxPixels / h, w * h >= minScanPixels, w * h <= BitImage.maxPixels else { return nil }
        return Job(kind: .threshold(source: source, dpi: dpi), raw: raw, width: w, height: h)
    }

    /// The job's new samples, or nil when nothing would be saved (or the picture can't be drawn, or a recoding doesn't draw
    /// back the same). Reads nothing of the document: safe on any thread.
    static func run(_ job: Job, _ draw: Draw) throws -> Coded? {
        let (w, h) = (job.width, job.height)
        switch job.kind {
        case .recode(let entries):
            // The samples as they are (whatever the colours, the decode array or the stencil make of them): drawn as grey at 1 bit.
            guard let bits = samples(entries, job.raw, w, h, draw) else { return nil }
            let (coding, data) = try PdfWriter.oneBitData(bits, jbig2: true)
            if data.count >= job.raw.count { return nil }
            // Proves it: the new coding drawn back, pixel for pixel.
            guard let back = samples(codingEntries(coding, w, h), data, w, h, draw), back.bits == bits.bits else { return nil }
            return Coded(coding: coding, data: data, madeOneBit: false)
        case .threshold(let source, let dpi):
            guard let rgb = draw(source, job.raw, w, h), rgb.count >= w * h * 3,
                  let gray = gray(rgb, w, h), looksBlackAndWhite(gray, w, h) else { return nil }
            let bits = try Bilevel.fromScan(gray, w, h, dpi: min(max(dpi, 50), 2400))
            let (coding, data) = try PdfWriter.oneBitData(bits, jbig2: true)
            if data.count >= job.raw.count { return nil }
            return Coded(coding: coding, data: data, madeOneBit: true)
        }
    }

    /// Makes the change `run` worked out, on the document's thread.
    static func apply(_ image: PObj, _ job: Job, _ coded: Coded) {
        let doc = image.doc
        image.setStream(coded.data, deflate: false)
        if coded.madeOneBit {
            image.set("BitsPerComponent", doc.int(1))
            image.set("ColorSpace", doc.name("DeviceGray"))
            image.remove("Decode")
            image.remove("Intent")
        }
        setCoding(image, coded.coding, job.width, job.height)
    }

    /// The grey pixels are ink on paper: two clear groups (Otsu's split) far apart, few pixels between them (a scan's soft
    /// letter edges, not a photo's or a drawing's shades). A grey page of text passes; a photo, a gradient, a page on strongly
    /// tinted paper doesn't. Judged on the page smoothed as `Bilevel.fromScan` smooths it, so a scanner's noise doesn't count
    /// as shades.
    /// - Parameter gray: rows of `width` bytes, 0 black.
    static func looksBlackAndWhite(_ gray: [UInt8], _ width: Int, _ height: Int) -> Bool {
        guard width >= 1, height >= 1, width <= Int.max / height, gray.count >= width * height,
              let smooth = try? CleanupSmooth.median3(gray, width, height, nil) else { return false }
        var histogram = [Int](repeating: 0, count: 256)
        for v in smooth { histogram[Int(v)] += 1 }
        let total = smooth.count
        var sumAll = 0
        for v in 0..<256 { sumAll += v * histogram[v] }
        var below = 0, sumBelow = 0, bestBelow = 0, bestSumBelow = 0
        var best = -1.0
        for t in 0..<255 {
            below += histogram[t]
            sumBelow += t * histogram[t]
            let above = total - below
            if below == 0 || above == 0 { continue }
            let d = Double(sumBelow) / Double(below) - Double(sumAll - sumBelow) / Double(above)
            let between = Double(below) * Double(above) * d * d
            if between > best { (best, bestBelow, bestSumBelow) = (between, below, sumBelow) }
        }
        if best < 0 { return true } // one shade: a blank page
        let ink = Double(bestSumBelow) / Double(bestBelow)
        let paper = Double(sumAll - bestSumBelow) / Double(total - bestBelow)
        if paper - ink < 100 || paper < 150 || bestBelow > total / 2 { return false }
        // Between a quarter and three quarters of the way from ink to paper: edges of letters, or a picture's shades.
        let low = Int((ink + (paper - ink) / 4).rounded(.up)), high = Int((paper - (paper - ink) / 4).rounded(.down)) // bounded: means of 0...255 values
        var between = 0
        if max(0, low) <= min(255, high) { for v in max(0, low)...min(255, high) { between += histogram[v] } }
        return Double(between) <= Double(total) * 0.05
    }

    /// The RGB pixels as grey, or nil when more than a few are coloured (a colour picture isn't a black-and-white scan).
    private static func gray(_ rgb: [UInt8], _ w: Int, _ h: Int) -> [UInt8]? {
        let n = w * h
        var gray = [UInt8](repeating: 0, count: n)
        var colored = 0
        // Types spelled out and the sums split: CI's Swift gave up type-checking this closure in one piece.
        rgb.withUnsafeBufferPointer { (p: UnsafeBufferPointer<UInt8>) -> Void in
            for i in 0..<n {
                let r: Int = Int(p[3 * i]), g: Int = Int(p[3 * i + 1]), b: Int = Int(p[3 * i + 2])
                let spread: Int = max(r, g, b) - min(r, g, b)
                if spread > 48 { colored += 1 }
                let weighted: Int = r * 299 + g * 587 + b * 114
                gray[i] = UInt8((weighted + 500) / 1000)
            }
        }
        return colored > n / 200 ? nil : gray
    }

    /// The picture's samples as a `BitImage` (a 0 sample black, a set bit), drawn by MuPDF through the picture's own filters
    /// (`filterEntries`) as plain 1-bit grey.
    private static func samples(_ filterEntries: String, _ data: [UInt8], _ w: Int, _ h: Int, _ draw: Draw) -> BitImage? {
        let dict = "/Type /XObject /Subtype /Image /Width \(w) /Height \(h) /BitsPerComponent 1 /ColorSpace /DeviceGray" + filterEntries
        guard let rgb = draw(dict, data, w, h), rgb.count >= w * h * 3 else { return nil }
        var gray = [UInt8](repeating: 0, count: w * h)
        for i in gray.indices { gray[i] = rgb[3 * i + 1] }
        return try? BitImage.fromGray(gray, w, h, threshold: 128)
    }

    /// The picture's /Filter and /DecodeParms written out (each " /Key value"), or nil when one can't be.
    private static func filterEntries(_ image: PObj) -> String? {
        var text = ""
        for key in ["Filter", "DecodeParms"] {
            guard let v = image[key] else { continue }
            guard let plain = Optimizer.plain(v, 0) else { return nil }
            text += " /\(key) \(plain)"
        }
        return text
    }

    /// `setCoding`'s entries written out, to draw a coding back before it is kept.
    private static func codingEntries(_ coding: PdfWriter.OneBitCoding, _ w: Int, _ h: Int) -> String {
        switch coding {
        case .ccittG4: " /Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns \(w) /Rows \(h) >>"
        case .jbig2: " /Filter /JBIG2Decode"
        case .flate: " /Filter /FlateDecode"
        }
    }

    static func isStencil(_ image: PObj) -> Bool {
        guard let m = image["ImageMask"] else { return false }
        return m.kind == .bool && m.bool
    }

    /// A colour space of one component a pixel: DeviceGray, CalGray, ICC-based with /N 1, Indexed or Separation.
    static func oneComponent(_ item: PObj?) -> Bool {
        guard let item else { return false }
        if let n = item.name { return n == "DeviceGray" || n == "G" }
        guard item.isArray, item.count > 0, let family = item[0]?.name else { return false }
        switch family {
        case "CalGray", "Indexed", "I", "Separation": return true
        case "ICCBased":
            guard item.count > 1, let icc = item[1], icc.isDict else { return false }
            return icc.int("N") == 1
        default: return false
        }
    }
}
