import Foundation

/// What a batch reads from a macOS print queue, in words and numbers (PrintMac's `CupsBatchQueue` asks cupsd; these rules are
/// here so the PC tests them): whether the queue may take a batch now, a paper's size from its IPP name, and what the job's
/// options came to when cupsd read them back (Windows' `MergeAndValidatePrintTicket`, compared by `BatchTicketCheck`).
public enum BatchQueueReading {
    /// Why nothing should be sent now, or nil. `state` is IPP's `printer-state` (3 idle, 4 processing, 5 stopped; nil: no such
    /// queue); `reasons` its `printer-state-reasons`. As Windows' `ProblemAsync`: an error or an offline printer stops the
    /// batch; a warning (toner low) doesn't, nor does a paused queue, which takes the jobs.
    public static func problem(state: Int?, accepting: Bool?, reasons: [String]) -> String? {
        // A paused queue (5, stopped) takes the jobs and prints them when it's resumed, as Windows' paused queue does.
        guard state != nil else { return "macOS has no such print queue now." }
        if accepting == false { return "The printer's queue isn't taking jobs: resume it in System Settings › Printers & Scanners." }
        for raw in reasons where raw != "none" && !raw.hasSuffix("-warning") {
            var bare = raw
            for suffix in ["-error", "-report"] where bare.hasSuffix(suffix) { bare = String(bare.dropLast(suffix.count)) }
            if bare.hasPrefix("cups-") || ["paused", "moving-to-paused", "connecting-to-device"].contains(bare) { continue }
            if raw.hasSuffix("-error") || Self.stops.contains(bare) { return "\(IppStatusText.describe(bare))." }
        }
        return nil
    }

    /// Reasons that stop paper whether or not the printer says "-error".
    private static let stops: Set<String> = ["media-empty", "media-needed", "media-jam", "media-path-jam", "cover-open", "door-open", "interlock-open",
                                             "toner-empty", "marker-supply-empty", "marker-supply-missing", "input-tray-missing", "offline", "shutdown"]

    /// A paper's size in points from its IPP self-describing name ("na_letter_8.5x11in", "iso_a4_210x297mm",
    /// "om_photo_100x150mm", with ".borderless" and other suffixes); nil for a name without one (a PPD's "Letter").
    public static func size(_ media: String) -> (width: Double, height: Double)? {
        guard let last = media.split(separator: "_").last else { return nil }
        // "8.5x11in.borderless": the dimensions end at the unit; what follows it is a variant.
        let inch = last.range(of: "in"), mm = last.range(of: "mm")
        let unit: Double
        let dims: Substring
        if let inch, mm.map({ inch.lowerBound < $0.lowerBound }) ?? true {
            unit = 72
            dims = last[..<inch.lowerBound]
        } else if let mm {
            unit = 72 / 25.4
            dims = last[..<mm.lowerBound]
        } else {
            return nil
        }
        let parts = dims.split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0, w < 10_000, h < 10_000 else { return nil }
        return (w * unit, h * unit)
    }

    /// The size in a `media-col` as libcups writes it out ("{media-size={x-dimension=21590 y-dimension=27940} …}", hundredths
    /// of a millimetre), in points; nil when it has none.
    public static func mediaColSize(_ text: String) -> (width: Double, height: Double)? {
        func number(after key: String) -> Double? {
            guard let at = text.range(of: key + "=") else { return nil }
            let digits = text[at.upperBound...].prefix { $0.isNumber }
            return Double(digits)
        }
        guard let x = number(after: "x-dimension"), let y = number(after: "y-dimension"), x > 0, y > 0 else { return nil }
        return (x / 2540 * 72, y / 2540 * 72)
    }

    /// Two-sided from IPP's `sides`: nil when the job doesn't say.
    public static func twoSided(_ sides: String?) -> Bool? {
        switch sides {
        case "one-sided"?: false
        case "two-sided-long-edge"?, "two-sided-short-edge"?: true
        default: nil
        }
    }

    /// A paper's words for a list: the queue's own when it has some, else from the IPP name ("iso_a4_210x297mm" → "A4").
    public static func label(_ media: String, localized: String?) -> String {
        if let localized, !localized.isEmpty, localized != media { return localized }
        let parts = media.split(separator: "_")
        guard parts.count >= 3 else { return media }
        let name = parts[1...(parts.count - 2)].joined(separator: " ")
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
