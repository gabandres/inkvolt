import Foundation
import Synchronization

/// A paper the printer offers: its PWG self-describing name (`na_letter_8.5x11in`), size and margins in hundredths of a
/// millimetre (as `media-col` has them), and where it came from (`media-source`) when the printer says.
public struct DirectPaper: Equatable, Hashable, Sendable {
    public var name: String
    public var widthHmm: Int
    public var heightHmm: Int
    public var left: Int
    public var top: Int
    public var right: Int
    public var bottom: Int
    public var source: String?

    public init(_ name: String, _ widthHmm: Int, _ heightHmm: Int, _ left: Int, _ top: Int, _ right: Int, _ bottom: Int, source: String? = nil) {
        (self.name, self.widthHmm, self.heightHmm) = (name, widthHmm, heightHmm)
        (self.left, self.top, self.right, self.bottom, self.source) = (left, top, right, bottom, source)
    }

    public var borderless: Bool { left == 0 && top == 0 && right == 0 && bottom == 0 }
    public var widthInches: Double { Double(widthHmm) / 2540 }
    public var heightInches: Double { Double(heightHmm) / 2540 }

    /// The same paper with no margins.
    public var withoutMargins: DirectPaper {
        var p = self
        (p.left, p.top, p.right, p.bottom) = (0, 0, 0, 0)
        return p
    }
}

/// One printer's `IppPrintCaps`, read once and kept for a while: each read carries `media-col-database`, and the paper
/// choice and the print itself would each ask again. A failed or cancelled read isn't kept. One read is shared by every
/// caller.
public final class IppCapsCache: Sendable {
    public static let defaultKeep: Duration = .seconds(120)

    private let read: @Sendable () async throws -> IppPrintCaps
    private let keep: Duration
    private let now: @Sendable () -> ContinuousClock.Instant
    private let state = Mutex<(task: Task<IppPrintCaps, any Error>?, at: ContinuousClock.Instant?)>((nil, nil))

    public init(_ read: @escaping @Sendable () async throws -> IppPrintCaps, keep: Duration = defaultKeep,
                now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        (self.read, self.keep, self.now) = (read, keep, now)
    }

    public func get() async throws -> IppPrintCaps {
        let at = now()
        let task: Task<IppPrintCaps, any Error> = state.withLock { s in
            if let kept = s.task, let since = s.at, at - since < keep { return kept }
            let fresh = Task { try await read() }
            s = (fresh, at)
            return fresh
        }
        do {
            return try await task.value
        } catch {
            state.withLock { s in if s.task == task { s = (nil, nil) } } // a failed read isn't kept
            throw error
        }
    }

    /// Read again next time (a setting changed at the printer, or a job was refused for one).
    public func forget() { state.withLock { $0 = (nil, nil) } }
}

/// A printer's `IppCapsCache` for its current connection: the same cache while the connection's client is the same, a new one
/// after a reconnect (a new client). Held per printer by the app; asked from any thread.
public final class IppCapsCaches: Sendable {
    private let kept = Mutex<(ipp: IppClient, cache: IppCapsCache)?>(nil)

    public init() {}

    public func cache(for ipp: IppClient) -> IppCapsCache {
        kept.withLock { k in
            if let k, k.ipp === ipp { return k.cache }
            let cache = IppCapsCache({ IppPrintCaps.from(try await ipp.printerAttributes(IppPrintCaps.requested)) })
            k = (ipp, cache)
            return cache
        }
    }
}

/// What a printer says it takes for driverless printing, read from Get-Printer-Attributes (PWG 5100.14 IPP Everywhere,
/// PWG 5102.4, Apple's `urf-supported`, Mopria's `pclm-*`). Everything a printer says is hostile input: lists are cut to a
/// few hundred values, sizes and resolutions outside what paper and printers have are left out.
public struct IppPrintCaps: Equatable, Sendable {
    /// The attributes asked for (`media-col-database` isn't part of "all" and has to be named).
    public static let requested = [
        "printer-state", "printer-state-reasons", "printer-state-message", "printer-make-and-model", "printer-name",
        "operations-supported", "document-format-supported",
        "pwg-raster-document-type-supported", "pwg-raster-document-resolution-supported", "pwg-raster-document-sheet-back",
        "urf-supported",
        "pclm-source-resolution-supported", "pclm-source-resolution-default", "pclm-strip-height-preferred",
        "pclm-compression-method-preferred", "pclm-raster-back-side",
        "media-col-database", "media-col-default", "media-col-ready", "media-default", "media-supported",
        "media-bottom-margin-supported", "media-left-margin-supported", "media-right-margin-supported", "media-top-margin-supported",
        "media-type-supported", "media-type-default",
        "sides-supported", "print-color-mode-supported", "print-color-mode-default", "copies-supported",
        "print-quality-supported", "print-quality-default", "multiple-document-handling-supported",
    ]

    /// Most papers kept: a real printer lists a few dozen.
    public static let maxPapers = 200
    /// Most values read from any one list attribute.
    public static let maxValues = 256

    public static let pwgRasterType = "image/pwg-raster", urfType = "image/urf", pclmType = "application/PCLm"

    /// The raster formats it takes, the most standard first (PWG raster, Apple raster, PCLm).
    public var formats: [RasterFormat] = []
    public var pwgColors: [RasterColor] = []
    public var pwgDpis: [Int] = []
    public var pwgBack: BackSide = .normal
    public var urfColors: [RasterColor] = []
    public var urfDpis: [Int] = []
    public var urfBack: BackSide = .normal
    public var pclmDpis: [Int] = []
    public var pclmStripHeight = 16
    public var pclmRunLength = false
    public var pclmBack: BackSide = .normal
    public var papers: [DirectPaper] = []
    /// The paper it uses when not told (`media-col-default`, else `media-default`), nil when it says neither.
    public var defaultPaper: DirectPaper?
    public var twoSided = false
    public var shortEdge = false
    /// It prints in color (`print-color-mode-supported` lists `color`).
    public var color = false
    /// It prints in color unless told otherwise.
    public var colorByDefault = false
    /// Most copies it makes of a document itself (`copies-supported`); 1: the pages are sent again for each copy.
    public var maxCopies = 1
    /// It collates the copies it makes (`multiple-document-handling-supported` lists `separate-documents-collated-copies`).
    public var collatedCopies = false
    /// `print-quality` values it takes: 3 draft, 4 normal, 5 high.
    public var qualities: [Int] = []
    public var defaultQuality: Int?
    /// `media-type` keywords (`stationery`, `photographic-glossy`…).
    public var mediaTypes: [String] = []
    public var defaultMediaType: String?
    /// It takes Print-Job (`operations-supported` lists 2, or doesn't say).
    public var printJob = true
    public var cancelJob = true

    public init() {}

    /// A raster format it takes and the operation to send it.
    public var canPrint: Bool { printJob && !formats.isEmpty }

    /// The papers to choose from: each name once, its bordered entry where it has one, labelled by size in the interface's
    /// words (`PhotoPaperText.paper`), a size listed under two names shown once.
    public func paperChoices() -> [(paper: DirectPaper, label: String)] {
        var names: [String] = []
        var byName: [String: DirectPaper] = [:]
        for p in papers {
            if let kept = byName[p.name] {
                if kept.borderless && !p.borderless { byName[p.name] = p }
            } else {
                names.append(p.name)
                byName[p.name] = p
            }
        }
        var labels = Set<String>()
        var out: [(paper: DirectPaper, label: String)] = []
        for name in names {
            let p = byName[name]!
            let label = PhotoPaperText.paper(nil, p.widthInches, p.heightInches)
            if labels.insert(label).inserted { out.append((p, label)) }
        }
        return out
    }

    /// The raster formats in `document-format-supported` alone (the status reading has that much).
    public static func formatsIn(_ documentFormats: [String]) -> [RasterFormat] {
        let listed = Set(documentFormats.prefix(maxValues).map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
        var formats: [RasterFormat] = []
        if listed.contains(pwgRasterType) { formats.append(.pwgRaster) }
        if listed.contains(urfType) { formats.append(.urf) }
        if listed.contains(pclmType.lowercased()) { formats.append(.pclm) }
        return formats
    }

    public static func from(_ r: IppResponse) -> IppPrintCaps {
        let ops = Array(r.ints("operations-supported").prefix(maxValues))
        let pwgColors = colors(r.strs("pwg-raster-document-type-supported"), gray: "sgray_8", rgb: "srgb_8")
        let pwgDpis = dpis(r.resolutions("pwg-raster-document-resolution-supported"))
        let urf = Array(r.strs("urf-supported").prefix(maxValues))
        let urfColors = colors(urf, gray: "W8", rgb: "SRGB24")
        let urfDpis = readUrfDpis(urf)
        var pclmDpis = dpis(r.resolutions("pclm-source-resolution-supported"))
        if pclmDpis.isEmpty { pclmDpis = dpis(r.resolutions("pclm-source-resolution-default")) }

        // A format counts only when the printer also says how to make it.
        let formats = formatsIn(r.strs("document-format-supported")).filter { f in
            switch f {
            case .pwgRaster: !pwgColors.isEmpty && !pwgDpis.isEmpty
            case .urf: !urfColors.isEmpty && !urfDpis.isEmpty
            case .pclm: !pclmDpis.isEmpty
            }
        }
        let papers = readPapers(r)
        let sides = Array(r.strs("sides-supported").prefix(maxValues))
        let colorModes = Array(r.strs("print-color-mode-supported").prefix(maxValues))
        let pclmPreferred = Array(r.strs("pclm-compression-method-preferred").prefix(maxValues))

        var c = IppPrintCaps()
        c.formats = formats
        (c.pwgColors, c.pwgDpis, c.pwgBack) = (pwgColors, pwgDpis, back(r.str("pwg-raster-document-sheet-back")))
        (c.urfColors, c.urfDpis) = (urfColors, urfDpis)
        c.urfBack = urf.contains("DM4") ? .manualTumble : urf.contains("DM3") ? .rotated : urf.contains("DM2") ? .flipped : .normal
        c.pclmDpis = pclmDpis
        if let strip = r.int("pclm-strip-height-preferred"), (1...4096).contains(strip) { c.pclmStripHeight = strip }
        // Flate unless the printer puts run-length before it (JPEG, its other choice, would blur text).
        if let rle = pclmPreferred.firstIndex(of: "rle") {
            let flate = pclmPreferred.firstIndex(of: "flate")
            c.pclmRunLength = flate.map { rle < $0 } ?? true
        }
        c.pclmBack = back(r.str("pclm-raster-back-side"))
        c.papers = papers
        c.defaultPaper = readDefaultPaper(r, papers)
        c.twoSided = sides.contains("two-sided-long-edge")
        c.shortEdge = sides.contains("two-sided-short-edge")
        c.color = colorModes.contains("color") || (colorModes.isEmpty && (pwgColors.contains(.rgb8) || urfColors.contains(.rgb8)))
        c.colorByDefault = ["color", "auto"].contains(r.str("print-color-mode-default") ?? "") && colorModes.contains("color")
        if let copies = r.range("copies-supported"), copies.upper >= 1 { c.maxCopies = min(copies.upper, 999) }
        c.collatedCopies = r.strs("multiple-document-handling-supported").prefix(maxValues).contains("separate-documents-collated-copies")
        var qualities: [Int] = []
        for q in r.ints("print-quality-supported").prefix(maxValues) where (3...5).contains(q) && !qualities.contains(q) { qualities.append(q) }
        c.qualities = qualities.sorted()
        if let dq = r.int("print-quality-default"), (3...5).contains(dq) { c.defaultQuality = dq }
        var types: [String] = []
        for t in r.strs("media-type-supported").prefix(maxValues) where keyword(t) && !types.contains(t) { types.append(t) }
        c.mediaTypes = types
        if let mt = r.str("media-type-default"), keyword(mt) { c.defaultMediaType = mt }
        c.printJob = ops.isEmpty || ops.contains(Int(IppCodec.printJob))
        c.cancelJob = ops.isEmpty || ops.contains(Int(IppCodec.cancelJob))
        return c
    }

    private static func colors(_ values: [String], gray: String, rgb: String) -> [RasterColor] {
        let list = values.prefix(maxValues)
        var colors: [RasterColor] = []
        if list.contains(gray) { colors.append(.gray8) }
        if list.contains(rgb) { colors.append(.rgb8) }
        return colors
    }

    private static func dpis(_ values: [IppResolution]) -> [Int] {
        Array(Set(values.prefix(maxValues).compactMap(\.dpi).filter { (72...2400).contains($0) })).sorted()
    }

    /// `RS300`, `RS300-600`: the resolutions in an `urf-supported` list.
    static func readUrfDpis(_ urf: [String]) -> [Int] {
        var dpis = Set<Int>()
        for value in urf where value.hasPrefix("RS") {
            for part in value.dropFirst(2).split(separator: "-", omittingEmptySubsequences: false).prefix(16) {
                if part.count <= 9, part.allSatisfy({ ("0"..."9").contains($0) }), let dpi = Int(part), (72...2400).contains(dpi) { dpis.insert(dpi) }
            }
        }
        return dpis.sorted()
    }

    private static func back(_ keyword: String?) -> BackSide {
        switch keyword {
        case "flipped": .flipped
        case "rotated": .rotated
        case "manual-tumble": .manualTumble
        default: .normal
        }
    }

    private static func keyword(_ s: String) -> Bool {
        (1...255).contains(s.utf8.count) && s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    /// The papers: `media-col-database`'s entries with a fixed size (ranges are custom sizes, left out), with their margins;
    /// without it, `media-supported`'s self-describing names with the smallest margins in `media-*-margin-supported`. A
    /// paper with no margins is also listed with the smallest non-zero ones, so it can print with margins.
    private static func readPapers(_ r: IppResponse) -> [DirectPaper] {
        var papers: [DirectPaper] = []
        for col in r.collections("media-col-database").prefix(maxPapers * 2) {
            if let paper = fromCollection(col) { papers.append(paper) }
        }
        if papers.isEmpty {
            func margin(_ name: String, zero: Bool) -> Int {
                r.ints(name).prefix(maxValues).filter { (0...5000).contains($0) && (zero || $0 > 0) }.min() ?? (zero ? 0 : 635)
            }
            let borderless = ["bottom", "left", "right", "top"].allSatisfy { r.ints("media-\($0)-margin-supported").contains(0) }
            for name in r.strs("media-supported").prefix(maxPapers) {
                guard let size = size(name) else { continue }
                papers.append(DirectPaper(name, size.w, size.h, margin("media-left-margin-supported", zero: false), margin("media-top-margin-supported", zero: false),
                                          margin("media-right-margin-supported", zero: false), margin("media-bottom-margin-supported", zero: false)))
                if borderless { papers.append(DirectPaper(name, size.w, size.h, 0, 0, 0, 0)) }
            }
        }
        var seen = Set<DirectPaper>()
        var unique: [DirectPaper] = []
        for p in papers {
            var key = p
            key.source = nil
            if seen.insert(key).inserted { unique.append(p) }
            if unique.count == maxPapers { break }
        }
        return unique
    }

    /// One `media-col` value as a paper, or nil when it has no fixed size in range.
    public static func fromCollection(_ col: IppCollection) -> DirectPaper? {
        guard let size = col.collection("media-size"), let w = size.int("x-dimension"), let h = size.int("y-dimension") else { return nil }
        guard (500...200_000).contains(w), (500...500_000).contains(h) else { return nil } // 5 mm to 2 m wide, 5 m long: past that, not paper
        func m(_ name: String) -> Int { col.int(name).flatMap { (0...5000).contains($0) ? $0 : nil } ?? 0 }
        let name = col.str("media-size-name").flatMap { keyword($0) ? $0 : nil } ?? Self.name(w, h)
        let source = col.str("media-source").flatMap { keyword($0) ? $0 : nil }
        return DirectPaper(name, w, h, m("media-left-margin"), m("media-top-margin"), m("media-right-margin"), m("media-bottom-margin"), source: source)
    }

    private static func readDefaultPaper(_ r: IppResponse, _ papers: [DirectPaper]) -> DirectPaper? {
        if let col = r.collections("media-col-default").first, let fromCol = fromCollection(col) {
            return papers.first { same($0, fromCol) && $0.left == fromCol.left && $0.top == fromCol.top } ?? papers.first { same($0, fromCol) } ?? fromCol
        }
        if let name = r.str("media-default"), let size = size(name) {
            return papers.first { $0.widthHmm == size.w && $0.heightHmm == size.h && !$0.borderless }
                ?? papers.first { $0.widthHmm == size.w && $0.heightHmm == size.h }
        }
        return nil
    }

    /// The same size within half a millimetre.
    public static func same(_ a: DirectPaper, _ b: DirectPaper) -> Bool { abs(a.widthHmm - b.widthHmm) <= 50 && abs(a.heightHmm - b.heightHmm) <= 50 }

    /// A PWG 5101.1 self-describing media name's size in hundredths of a millimetre (`iso_a4_210x297mm`), nil for custom
    /// ranges or others.
    public static func size(_ name: String) -> (w: Int, h: Int)? {
        if name.utf8.count > 128 || name.hasPrefix("custom_min") || name.hasPrefix("custom_max") { return nil }
        // ^[a-z0-9-]+_[a-z0-9.-]*_(\d{1,4}(\.\d{1,4})?)x(\d{1,5}(\.\d{1,4})?)(in|mm)$
        let parts = name.split(separator: "_", omittingEmptySubsequences: false)
        guard parts.count >= 3 else { return nil }
        let class_ = parts[0], last = parts[parts.count - 1]
        let middle = parts[1..<parts.count - 1].joined(separator: "_")
        func chars(_ s: Substring, _ extra: String) -> Bool { s.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || extra.unicodeScalars.contains($0) } }
        guard !class_.isEmpty, chars(class_, "-"), chars(Substring(middle), ".-"), !middle.contains("_") else { return nil }
        let unit: Double
        if last.hasSuffix("in") { unit = 2540 } else if last.hasSuffix("mm") { unit = 100 } else { return nil }
        let dims = last.dropLast(2).split(separator: "x", omittingEmptySubsequences: false)
        guard dims.count == 2, let w = number(dims[0], whole: 4), let h = number(dims[1], whole: 5) else { return nil }
        let (wh, hh) = (w * unit, h * unit)
        guard (500...200_000).contains(wh), (500...500_000).contains(hh) else { return nil }
        return (wh.rounded(.toNearestOrEven).clampedInt, hh.rounded(.toNearestOrEven).clampedInt)
    }

    /// `\d{1,whole}(\.\d{1,4})?` as a number.
    private static func number(_ s: Substring, whole: Int) -> Double? {
        let halves = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(halves.count) else { return nil }
        func digits(_ d: Substring, _ most: Int) -> Bool { (1...most).contains(d.count) && d.allSatisfy { ("0"..."9").contains($0) } }
        guard digits(halves[0], whole), halves.count == 1 || digits(halves[1], 4) else { return nil }
        return Double(s)
    }

    private static let known: [(name: String, w: Int, h: Int)] = [
        ("na_letter_8.5x11in", 21590, 27940), ("na_legal_8.5x14in", 21590, 35560), ("iso_a4_210x297mm", 21000, 29700),
        ("iso_a5_148x210mm", 14800, 21000), ("iso_a6_105x148mm", 10500, 14800), ("na_index-4x6_4x6in", 10160, 15240),
        ("na_5x7_5x7in", 12700, 17780), ("na_govt-letter_8x10in", 20320, 25400), ("om_small-photo_100x150mm", 10000, 15000),
        ("oe_photo-l_3.5x5in", 8890, 12700), ("na_executive_7.25x10.5in", 18415, 26670), ("iso_a3_297x420mm", 29700, 42000),
        ("jpn_hagaki_100x148mm", 10000, 14800), ("na_ledger_11x17in", 27940, 43180), ("iso_b5_176x250mm", 17600, 25000),
    ]

    /// The PWG name for a size: a known one when it matches within half a millimetre, else `custom_WxHmm`.
    public static func name(_ w: Int, _ h: Int) -> String {
        for k in known where abs(k.w - w) <= 50 && abs(k.h - h) <= 50 { return k.name }
        func mm(_ v: Int) -> String {
            let whole = v / 100, frac = v % 100
            if frac == 0 { return String(whole) }
            return frac % 10 == 0 ? "\(whole).\(frac / 10)" : "\(whole).\(frac < 10 ? "0" : "")\(frac)"
        }
        return "custom_\(mm(w))x\(mm(h))mm_\(mm(w))x\(mm(h))mm"
    }
}
