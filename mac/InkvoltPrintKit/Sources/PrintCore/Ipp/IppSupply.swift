import Foundation

/// One `printer-supply` value (PWG 5100.13): the Printer MIB's supply row as `key=value;` text, e.g.
/// `index=1;class=supplyThatIsConsumed;type=tonerCartridge;unit=impressions;maxcapacity=3000;level=1050;colorantname=black;`.
/// Only a supply counted in pages (`unit` impressions or sheets) gives pages: its `level` is the pages left and its
/// `maxcapacity` what a full one is rated for; a percentage or unknown unit gives neither.
public struct IppSupply: Equatable, Sendable {
    public var unit: String?
    public var maxCapacity: Int?
    public var level: Int?

    /// Longest value read (the octetString is at most 1023 octets in PWG 5100.13).
    private static let maxLength = 1023

    public init(unit: String?, maxCapacity: Int?, level: Int?) {
        self.unit = unit
        self.maxCapacity = maxCapacity
        self.level = level
    }

    /// Counted in pages: impressions or sheets (PrtMarkerSuppliesSupplyUnitTC's names).
    public var inPages: Bool { unit == "impressions" || unit == "sheets" }

    /// The pages left: the level of a supply counted in pages (RFC 3805: −1, −2 and −3 aren't counts).
    public var pagesLeft: Int? {
        guard inPages, let level, level >= 0 else { return nil }
        if let max = maxCapacity, max > 0, level > max { return nil }
        return level
    }

    /// The pages a full one is rated for: the maximum of a supply counted in pages.
    public var pageYield: Int? {
        guard inPages, let max = maxCapacity, max > 0 else { return nil }
        return max
    }

    public static func parse(_ value: String) -> IppSupply {
        var unit: String?
        var max: Int?
        var level: Int?
        for part in value.prefix(maxLength).split(separator: ";", omittingEmptySubsequences: false) {
            guard let eq = part.firstIndex(of: "="), eq > part.startIndex else { continue }
            let key = part[..<eq].trimmingCharacters(in: .whitespaces)
            let text = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "unit": unit = text
            case "maxcapacity": max = number(text)
            case "level": level = number(text)
            default: break
            }
        }
        return IppSupply(unit: unit, maxCapacity: max, level: level)
    }

    /// A whole number in 32 bits, as .NET's int.TryParse with a leading sign.
    private static func number(_ text: String) -> Int? { Int32(text).map(Int.init) }
}
