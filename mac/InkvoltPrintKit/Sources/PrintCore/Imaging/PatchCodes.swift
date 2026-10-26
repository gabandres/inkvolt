import Foundation

/// The six Kodak patch codes. Each is four bars, two wide and two narrow, read in order across the bars (W wide, N narrow):
/// Patch 1 WWNN, Patch 2 WNNW, Patch 3 WNWN, Patch 4 (toggle) NWWN, Patch 6 NNWW, Patch T (transfer) NWNW. Kodak's software
/// uses 2, 3 and T to separate documents and batches; 1, 4 and 6 control the image and separate nothing.
public enum PatchCode: String, CaseIterable, Hashable, Sendable, Codable {
    case patch1, patch2, patch3, patch4, patch6, patchT
}

/// Finds a patch code on a scanned page (a separator sheet). Geometry from Kodak's patch code information (A-61801, as
/// summarised by barcode font vendors and Wikipedia): wide bars 0.20 in, narrow bars and the three spaces 0.08 in, so a patch
/// is 0.80 in across; bars at least 2 in long; a clear zone of about ten narrow bars around it. Read along every row and every
/// column of the analysis copy, so the sheet may be fed either way round and a few degrees crooked; widths are judged against
/// the patch's own size (toner spread and photocopies change them), and the patch must keep reading the same over an inch of
/// its length, so text, rules, tables and barcodes don't pass for one. Read backwards (the sheet upside down) Patch T is
/// Patch 3 and Patch 1 is Patch 6; 2 and 4 read the same either way.
public enum PatchCodes {
    /// Narrow bar and space width, in inches.
    public static let narrow = 0.08

    /// Wide bar width, in inches.
    public static let wide = 0.20

    /// Across the four bars and three spaces, in inches.
    public static let size: Double = 2 * wide + 2 * narrow + 3 * narrow

    /// How much of a bar's length must read the same (half the spec's 2 in minimum, for sheets fed off the edge).
    public static let minLength = 1.0

    private static let inkContrast = 80

    /// The narrow / wide pattern of each code, in reading order.
    static func pattern(_ code: PatchCode) -> String {
        switch code {
        case .patch1: "WWNN"
        case .patch2: "WNNW"
        case .patch3: "WNWN"
        case .patch4: "NWWN"
        case .patch6: "NNWW"
        case .patchT: "NWNW"
        }
    }

    private static func fromPattern(_ pattern: String) -> PatchCode? {
        PatchCode.allCases.first { Self.pattern($0) == pattern }
    }

    /// Patch 2, 3 and T separate documents (Kodak's use); 1, 4 and 6 don't.
    public static func separates(_ code: PatchCode) -> Bool { code == .patch2 || code == .patch3 || code == .patchT }

    public static func name(_ code: PatchCode) -> String {
        switch code {
        case .patch1: "Patch 1"
        case .patch2: "Patch 2"
        case .patch3: "Patch 3"
        case .patch4: "Patch 4"
        case .patch6: "Patch 6"
        case .patchT: "Patch T"
        }
    }

    /// The patch on the page, or nil. `pixelsPerInch`: the resolution of `img`.
    public static func find(_ img: GrayImage, pixelsPerInch: Double) -> PatchCode? {
        // A narrow bar under 2.4 px can't be told from a wide one.
        if pixelsPerInch < 30 || img.width < 16 || img.height < 16 { return nil }
        let paper = GrayImage.median(img, 0, 0, img.width, img.height)
        if paper < 128 { return nil }
        let ink = UInt8(paper - inkContrast)

        var best: PatchCode?
        var bestLength: Double = minLength * pixelsPerInch
        img.pixels.withUnsafeBufferPointer { px in
            for rows in [true, false] {
                let lines = rows ? img.height : img.width
                let length = rows ? img.width : img.height
                var runs: [Int] = []
                runs.reserveCapacity(64)
                var chains: [Chain] = []
                for line in 0..<lines {
                    // Along a row: pixels `step` 1 apart from the row's start; along a column: a row's width apart.
                    let (first, step) = rows ? (line * img.width, 1) : (line, img.width)
                    readRuns(px, first: first, step: step, length: length, ink: ink, into: &runs)
                    for match in matches(runs, pixelsPerInch) {
                        extend(&chains, match.code, line, match.centre, pixelsPerInch)
                    }
                }
                for chain in chains {
                    let read = Double(chain.last - chain.first + 1)
                    if read >= bestLength { (best, bestLength) = (chain.code, read) }
                }
            }
        }
        return best
    }

    /// A patch read on neighbouring lines at about the same place.
    private struct Chain {
        let code: PatchCode
        let first: Int
        var last: Int
        var centre: Double
    }

    private static func extend(_ chains: inout [Chain], _ code: PatchCode, _ line: Int, _ centre: Double, _ ppi: Double) {
        let gap: Double = max(2, 0.08 * ppi) // a line or two may miss (specks, a JPEG block)
        let drift: Double = max(2, 0.06 * ppi) // crooked sheets move the patch along the line a little per line
        for i in chains.indices {
            let chain = chains[i]
            if chain.code == code && Double(line - chain.last) <= gap && abs(centre - chain.centre) <= drift {
                if chain.last == line { return }
                chains[i].last = line
                chains[i].centre = centre
                return
            }
        }
        chains.append(Chain(code: code, first: line, last: line, centre: centre))
    }

    /// Run lengths along one row or column, starting with a light run (possibly 0 long), alternating.
    private static func readRuns(_ px: UnsafeBufferPointer<UInt8>, first: Int, step: Int, length: Int, ink: UInt8,
                                 into runs: inout [Int]) {
        runs.removeAll(keepingCapacity: true)
        var dark = false
        var run = 0
        var at = first
        for _ in 0..<length {
            let isDark = px[at] < ink
            at += step
            if isDark == dark {
                run += 1
                continue
            }
            runs.append(run)
            dark = isDark
            run = 1
        }
        runs.append(run)
    }

    /// Patches on one line: four dark runs and three light ones between clear zones, in the patch's proportions.
    private static func matches(_ runs: [Int], _ ppi: Double) -> [(code: PatchCode, centre: Double)] {
        var found: [(code: PatchCode, centre: Double)] = []
        let (minTotal, maxTotal): (Double, Double) = (0.75 * size * ppi, 1.3 * size * ppi)
        // Runs alternate light, dark, light… with light at even indexes: a patch starts at an odd index.
        var start = 0 // where run i begins
        for i in stride(from: 1, to: runs.count - 7, by: 2) {
            start += runs[i - 1] + (i > 1 ? runs[i - 2] : 0) // past the previous dark run and this light one
            var total = 0
            for k in 0..<7 { total += runs[i + k] }
            if Double(total) < minTotal || Double(total) > maxTotal { continue }
            let unit = Double(total) / 10 // 2 × 2.5 + 2 × 1 + 3 × 1 narrow widths
            if Double(runs[i - 1]) < 1.5 * unit || Double(runs[i + 7]) < 1.5 * unit { continue } // clear before and after
            var pattern = ""
            var ok = true
            for k in 0..<7 where ok {
                let r = Double(runs[i + k]) / unit
                if k % 2 == 1 {
                    ok = r >= 0.45 && r <= 1.75 // a space
                } else if r >= 0.45 && r <= 1.6 {
                    pattern.append("N")
                } else if r >= 1.8 && r <= 3.6 {
                    pattern.append("W")
                } else {
                    ok = false
                }
            }
            guard ok, let code = fromPattern(pattern) else { continue }
            found.append((code, Double(start) + Double(total) / 2))
        }
        return found
    }
}
