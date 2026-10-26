import Foundation

/// How a page is sized on the paper.
public enum PageSizing: Sendable {
    /// Print at the page's own size; only pages larger than the paper shrink to fit.
    case actualSize

    /// Shrink or enlarge every page to fill the paper.
    case fitToPaper
}

/// Where a page goes on the paper (its box after turning) and whether it's turned a quarter clockwise to get there.
public struct PagePlacement: Equatable, Sendable {
    public var at: Placement
    public var rotated: Bool

    public init(_ at: Placement, _ rotated: Bool) {
        self.at = at
        self.rotated = rotated
    }
}

/// Pages on paper the way they print: turned to the paper's orientation, sized, centred. Printing and the copy preview
/// both use it.
public enum PageFit {
    /// A page on the paper the way it prints: a landscape page on portrait paper (or the reverse) is turned a quarter
    /// rather than shrunk, then sized per `sizing` and centred.
    public static func place(_ pageW: Double, _ pageH: Double, _ paperW: Double, _ paperH: Double, _ sizing: PageSizing) -> PagePlacement {
        let rotated = (pageW > pageH) != (paperW > paperH)
        var (w, h) = rotated ? (pageH, pageW) : (pageW, pageH)
        let s = scale(w, h, paperW, paperH, sizing)
        (w, h) = (w * s, h * s)
        return PagePlacement(Placement((paperW - w) / 2, (paperH - h) / 2, w, h), rotated)
    }

    /// The factor that sizes a page (already turned to the paper's orientation) on the paper, keeping its proportions.
    /// Any units, as long as page and paper use the same ones.
    public static func scale(_ pageW: Double, _ pageH: Double, _ paperW: Double, _ paperH: Double, _ sizing: PageSizing) -> Double {
        if pageW <= 0 || pageH <= 0 { return 1 }
        let fit = min(paperW / pageW, paperH / pageH)
        if sizing == .actualSize || (fit > 1 && fit < 1.03) { return min(1, fit) } // same paper size: actual size
        return fit
    }
}
