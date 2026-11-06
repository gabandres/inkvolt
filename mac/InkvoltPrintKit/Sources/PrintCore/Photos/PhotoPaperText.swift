import Foundation

/// Plain names for what a print queue offers: paper sizes (by their size, since drivers name the same paper in different
/// ways), paper types, print quality and color modes (the Print Schema names, e.g. PhotographicGlossy).
public enum PhotoPaperText {
    private static let known: [(w: Double, h: Double, name: LocKey)] = [
        (8.5, 11, LocKey("Letter (8.5 × 11 in)")),
        (8.5, 14, LocKey("Legal (8.5 × 14 in)")),
        (11, 17, LocKey("Tabloid (11 × 17 in)")),
        (7.25, 10.5, LocKey("Executive (7.25 × 10.5 in)")),
        (210 / 25.4, 297 / 25.4, LocKey(verbatim: "A4 (21 × 29.7 cm)")),
        (148 / 25.4, 210 / 25.4, LocKey(verbatim: "A5 (14.8 × 21 cm)")),
        (105 / 25.4, 148 / 25.4, LocKey(verbatim: "A6 (10.5 × 14.8 cm)")),
        (297 / 25.4, 420 / 25.4, LocKey(verbatim: "A3 (29.7 × 42 cm)")),
        (182 / 25.4, 257 / 25.4, LocKey(verbatim: "B5 (18.2 × 25.7 cm)")),
        (100 / 25.4, 148 / 25.4, LocKey("Hagaki postcard (10 × 14.8 cm)")),
        (3.5, 5, LocKey("3.5 × 5 in photo")),
        (4, 6, LocKey("4 × 6 in photo")),
        (5, 7, LocKey("5 × 7 in photo")),
        (8, 10, LocKey("8 × 10 in photo")),
        (100 / 25.4, 150 / 25.4, LocKey("10 × 15 cm photo")),
        (130 / 25.4, 180 / 25.4, LocKey("13 × 18 cm photo")),
        (5, 8, LocKey(verbatim: "5 × 8 in")),
    ]

    /// "Letter (8.5 × 11 in)", "4 × 6 in photo"; otherwise its size in inches. `name` is the driver's (unused for now:
    /// sizes are what count).
    public static func paper(_ name: String?, _ widthIn: Double, _ heightIn: Double) -> String {
        let (a, b) = (min(widthIn, heightIn), max(widthIn, heightIn))
        for k in known where abs(a - k.w) < 0.04 && abs(b - k.h) < 0.04 { return k.name.text }
        return loc("{0} × {1} in", number(a), number(b))
    }

    /// Print Schema media type → "Photo paper, glossy", "Plain paper"…
    public static func mediaType(_ name: String) -> String {
        switch name {
        case "Plain": loc("Plain paper")
        case "AutoSelect": loc("Let the printer choose")
        case "Photographic": loc("Photo paper")
        case "PhotographicGlossy": loc("Photo paper, glossy")
        case "PhotographicHighGloss": loc("Photo paper, high gloss")
        case "PhotographicSemiGloss": loc("Photo paper, semi-gloss")
        case "PhotographicMatte": loc("Photo paper, matte")
        case "PhotographicSatin": loc("Photo paper, satin")
        case "PhotographicFilm": loc("Photo film")
        default: words(name)
        }
    }

    public static func isPhotoMedia(_ name: String) -> Bool { name.hasPrefix("Photographic") }

    /// Print Schema output quality → a plain word.
    public static func quality(_ name: String) -> String {
        switch name {
        case "Photographic": loc("Photo (best)")
        case "Draft": loc("Draft")
        case "Normal": loc("Normal")
        case "High": loc("High")
        default: words(name)
        }
    }

    /// Print Schema output color → a plain word.
    public static func color(_ name: String) -> String {
        switch name {
        case "Grayscale": loc("Shades of grey")
        case "Monochrome": loc("Black and white")
        case "Color": loc("Color")
        case "Automatic": loc("Automatic")
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
