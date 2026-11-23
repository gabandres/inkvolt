import Foundation

/// What turns a scanned page upright: `quarterTurns` quarters clockwise, after straightening it by `skew` degrees (measured
/// the way its lines run, so on a page lying sideways too). `sure` only when both the way its lines run and which way up they
/// are were clear; a page that isn't sure is never turned.
public struct UprightFound: Equatable, Sendable {
    public var quarterTurns: Int
    public var skew: Double
    public var sure: Bool

    public init(_ quarterTurns: Int, _ skew: Double, _ sure: Bool) {
        self.quarterTurns = quarterTurns
        self.skew = skew
        self.sure = sure
    }

    public static let unsure = UprightFound(0, 0, false)

    /// The turns to make, or 0 when not sure.
    public var turns: Int { sure ? quarterTurns : 0 }
}

/// Pages turned upright on their own (roadmap 4.3, the Windows app's `PageUpright`: a sheet fed upside down, a landscape page
/// in a portrait feeder): the way a page's lines run and which way up they are, read on the small copy of a scan the page
/// checks use (about 100 dpi), with the same steps Inkvolt PDF's text recognition takes (`ScanCleanup`'s lines, `Upright`):
/// the lines measured across the page and down it, the page straightened and its paper evened out, then the ink above and
/// below each line's middle. Latin, Greek and Cyrillic letters rise above the line more than they hang below it; scripts
/// that don't (Hebrew, Arabic, Chinese, Indian scripts…) aren't turned (`suitsLanguage`).
public enum PageUpright {
    /// - Parameters:
    ///   - small: the page in grey, about 100 dpi (a copy at more than 150 is made smaller first).
    ///   - dpi: the copy's pixels per inch.
    public static func find(_ small: GrayImage, _ dpi: Double) -> UprightFound {
        if !dpi.isFinite || dpi < 20 || small.width < 32 || small.height < 32 || small.pixels.count != small.width * small.height { return .unsure }
        let factor = dpi > 150 ? Int((min(dpi, 100_000) / 100).rounded(.toNearestOrEven)) : 1 // bounded: dpi is finite and capped
        let img = ScanCleanup.downscale(small, factor)
        let ppi = Int((dpi / Double(factor)).rounded(.toNearestOrEven)) // bounded: at most 150 once divided, or dpi itself up to 150
        let (skew, sideways, axisSure) = ScanCleanup.linesOf(img)
        if !axisSure { return .unsure }
        let (w, h) = (img.width, img.height)
        var px = skew != 0 ? PageRotate.rotate(img.pixels, w, h, w, 1, -skew) : img.pixels
        PaperLevel.whiten(&px, PaperLevel.estimate(px, w, h, ppi))
        let upright = sideways ? GrayImage(h, w, ScanCleanup.turn(px, w, h, 1, 1)) : GrayImage(w, h, px)
        let (flipped, waySure) = Upright.upsideDown(upright)
        return waySure ? UprightFound(((sideways ? 1 : 0) + (flipped ? 2 : 0)) % 4, skew, true) : .unsure
    }

    /// The scan review's check for one page, on its small copy: how far to straighten it and how many quarter turns stand it
    /// upright. `mayStraighten`: not blank-and-skipped, a separator or a scan of photos; `hasText`: that, and not looking blank
    /// either (only such a page is looked at for its way up). A page lying sideways is straightened by its lines' skew as they
    /// run (`straightenBy`), any other as `Deskew.angle` says.
    public static func orient(_ image: GrayImage, _ ppi: Double, straighten: Bool, upright: Bool, mayStraighten: Bool, hasText: Bool)
        -> (deskew: Double, quarterTurns: Int) {
        let found = upright && hasText && mayStraighten ? find(image, ppi) : .unsure
        let angle = !straighten || !mayStraighten ? 0 : found.turns % 2 == 1 ? straightenBy(found.skew) : Deskew.angle(image)
        return (angle, found.turns)
    }

    /// The straightening a scan's check gives a page by `skew` (`UprightFound.skew`): what `Deskew.angle` would, within its
    /// limits (`Deskew.minAngle` to `Deskew.maxAngle`), else none.
    public static func straightenBy(_ skew: Double) -> Double {
        skew.isFinite && abs(skew) >= Deskew.minAngle && abs(skew) <= Deskew.maxAngle ? skew : 0
    }

    /// Whether pages in `language` (a BCP-47 tag, the OCR language) can be told which way up: not a script written right to
    /// left, nor one of the scripts listed below. Unknown or empty: yes.
    public static func suitsLanguage(_ language: String?) -> Bool {
        guard let language, !language.trimmingCharacters(in: .whitespaces).isEmpty else { return true }
        let primary = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map { $0.lowercased() } ?? ""
        if otherScripts.contains(primary) { return false }
        return Locale.Language(identifier: language).characterDirection != .rightToLeft
    }

    /// Languages whose letters don't sit like Latin ones (left to right, but not Latin, Greek, Cyrillic or Armenian).
    private static let otherScripts: Set<String> = [
        "he", "iw", "yi", "ar", "fa", "ur", "ps", "sd", "ug", "ckb", "dv", "syr",
        "zh", "ja", "ko", "th", "lo", "km", "my", "bo", "dz",
        "hi", "mr", "ne", "sa", "bn", "as", "pa", "gu", "or", "ta", "te", "kn", "ml", "si", "am", "ti", "ka",
    ]
}
