import Foundation

/// Plain names for what a print queue offers: paper sizes (by their size, since drivers name the same paper in different
/// ways), paper types, print quality and color modes (the Print Schema names, e.g. PhotographicGlossy).
public enum PhotoPaperText {
    private static let known: [(w: Double, h: Double, name: String)] = [
        (8.5, 11, "Letter (8.5 × 11 in)"),
        (8.5, 14, "Legal (8.5 × 14 in)"),
        (11, 17, "Tabloid (11 × 17 in)"),
        (7.25, 10.5, "Executive (7.25 × 10.5 in)"),
        (210 / 25.4, 297 / 25.4, "A4 (21 × 29.7 cm)"),
        (148 / 25.4, 210 / 25.4, "A5 (14.8 × 21 cm)"),
        (105 / 25.4, 148 / 25.4, "A6 (10.5 × 14.8 cm)"),
        (297 / 25.4, 420 / 25.4, "A3 (29.7 × 42 cm)"),
        (182 / 25.4, 257 / 25.4, "B5 (18.2 × 25.7 cm)"),
        (100 / 25.4, 148 / 25.4, "Hagaki postcard (10 × 14.8 cm)"),
        (3.5, 5, "3.5 × 5 in photo"),
        (4, 6, "4 × 6 in photo"),
        (5, 7, "5 × 7 in photo"),
        (8, 10, "8 × 10 in photo"),
        (100 / 25.4, 150 / 25.4, "10 × 15 cm photo"),
        (130 / 25.4, 180 / 25.4, "13 × 18 cm photo"),
        (5, 8, "5 × 8 in"),
    ]

    /// "Letter (8.5 × 11 in)", "4 × 6 in photo"; otherwise its size in inches. `name` is the driver's (unused for now:
    /// sizes are what count).
    public static func paper(_ name: String?, _ widthIn: Double, _ heightIn: Double) -> String {
        let (a, b) = (min(widthIn, heightIn), max(widthIn, heightIn))
        for k in known where abs(a - k.w) < 0.04 && abs(b - k.h) < 0.04 { return k.name }
        return "\(number(a)) × \(number(b)) in"
    }

    /// Print Schema media type → "Photo paper, glossy", "Plain paper"…
    public static func mediaType(_ name: String) -> String {
        switch name {
        case "Plain": "Plain paper"
        case "AutoSelect": "Let the printer choose"
        case "Photographic": "Photo paper"
        case "PhotographicGlossy": "Photo paper, glossy"
        case "PhotographicHighGloss": "Photo paper, high gloss"
        case "PhotographicSemiGloss": "Photo paper, semi-gloss"
        case "PhotographicMatte": "Photo paper, matte"
        case "PhotographicSatin": "Photo paper, satin"
        case "PhotographicFilm": "Photo film"
        default: words(name)
        }
    }

    public static func isPhotoMedia(_ name: String) -> Bool { name.hasPrefix("Photographic") }

    /// Print Schema output quality → a plain word.
    public static func quality(_ name: String) -> String { name == "Photographic" ? "Photo (best)" : words(name) }

    /// Print Schema output color → a plain word.
    public static func color(_ name: String) -> String {
        switch name {
        case "Grayscale": "Shades of grey"
        case "Monochrome": "Black and white"
        default: words(name)
        }
    }

    /// "CardStockCoated" → "Card stock coated".
    private static func words(_ name: String) -> String {
        var out = ""
        var previous: Character?
        for c in name {
            if let p = previous, c.isUppercase && !p.isUppercase { out += " " + c.lowercased() } else { out.append(c) }
            previous = c
        }
        return out
    }

    /// At most two decimals, none trailing (.NET's "0.##"): 3.3, 7.25, 11.
    private static func number(_ value: Double) -> String {
        let cents = (value * 100).rounded(.toNearestOrAwayFromZero)
        guard cents.isFinite, abs(cents) < 1e15 else { return "\(value)" }
        let n = Int(cents)
        let (whole, frac) = (abs(n) / 100, abs(n) % 100)
        let sign = n < 0 ? "-" : ""
        if frac == 0 { return "\(sign)\(whole)" }
        return frac % 10 == 0 ? "\(sign)\(whole).\(frac / 10)" : "\(sign)\(whole).\(frac < 10 ? "0" : "")\(frac)"
    }
}
