import Foundation

/// A supply as the printer pane shows it (the Windows app's `SupplyViewModel`).
public struct SupplyText: Equatable, Sendable {
    public enum Level: String, Sendable { case ok, low, empty }

    public let supply: Consumable

    public init(_ supply: Consumable) {
        self.supply = supply
    }

    public var name: String { SupplyNames.display(supply.name) }

    /// "About 100 pages left", or the state when no estimate is available; nil for a waste box with room left.
    public var headline: String? {
        switch supply.state {
        case "missing": return loc("Missing — install it")
        case "full": return loc("Replace now")
        case "almostFull": return loc("Replace soon")
        case "out": return loc("Empty — replace now")
        default:
            if supply.isWaste { return nil }
            if let pages = supply.estimatedPagesRemaining { return loc("About {0} pages left", CoreLanguage.number(pages)) }
            return supply.isLow ? loc("Running low") : loc("OK", context: "supply")
        }
    }

    /// "Replacement: HP 136A · W1360A"; nil when the printer names no cartridge.
    public var cartridge: String? {
        // The selectability number is LEDM's (HP) only.
        let parts = [supply.selectibilityNumber.map { "HP \($0)" }, supply.productNumber].compactMap { $0 }
        return parts.isEmpty ? nil : loc("Replacement: {0}", parts.joined(separator: "  ·  "))
    }

    public var level: Level { ["out", "full", "missing"].contains(supply.state) ? .empty : supply.isLow ? .low : .ok }

    /// 0…1 for a bar; nil for waste boxes and unknown levels.
    public var fraction: Double? { supply.percentRemaining.map { Double(min(max($0, 0), 100)) / 100 } }

    /// The big figure: "45%", or for supplies without a level their state ("OK", "Almost full", "Full", "—").
    public var percentText: String {
        if let p = supply.percentRemaining { return "\(p)%" }
        switch supply.state {
        case "full": return loc("Full")
        case "almostFull": return loc("Almost full")
        case "out": return loc("Empty")
        case "missing": return loc("Missing")
        case "ok": return loc("OK", context: "supply")
        default: return "—"
        }
    }

    /// K, C, M, Y or #RRGGBB for the colour swatch; nil when the supply has no colour (a waste box).
    public var colorCode: String? { supply.colorCode }

    /// For VoiceOver: "Cyan ink, 55%, OK" or "Maintenance box, OK".
    public var accessibleText: String {
        [name, percentText, headline.flatMap { $0 == percentText ? nil : $0 }].compactMap { $0 }.joined(separator: ", ")
    }
}
