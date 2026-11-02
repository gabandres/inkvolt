import Foundation

/// One supply on a row of the Fleet page: "Black 42%", its bar and whether it's low.
public struct FleetSupplyRow: Equatable, Sendable {
    public var text: String
    public var level: Int?
    public var color: String?
    public var isLow: Bool
}

/// One row of the Fleet page, in words: what the view shows and VoiceOver reads.
public struct FleetRow: Equatable, Sendable {
    public var printer: FleetPrinter
    public var statusLine: String
    public var supplies: [FleetSupplyRow]
    public var noSuppliesText: String?
    public var pagesText: String
    public var firmwareText: String
    public var lastReadText: String
    public var accessibleText: String
}

/// What the Fleet page says: a row per printer and the line above them (the Windows app's `FleetPage`). Pure, so the words
/// are tested without a window.
public enum FleetPage {
    public static func rows(_ printers: [FleetPrinter], _ now: Date, timeZone: TimeZone = .current) -> [FleetRow] {
        FleetOrder.sort(printers).map { row($0, now, timeZone: timeZone) }
    }

    public static func row(_ p: FleetPrinter, _ now: Date, timeZone: TimeZone = .current) -> FleetRow {
        let supplies = p.supplies.map { FleetSupplyRow(text: supplyText($0), level: $0.level, color: $0.color, isLow: isLow($0)) }
        let status: String
        if p.problems.isEmpty {
            status = p.status
        } else if p.problems[0].lowercased() == p.status.lowercased() {
            status = p.problems.joined(separator: " · ")
        } else {
            status = "\(p.status) · \(p.problems.joined(separator: " · "))"
        }
        let known = p.lastKnown ? " (last known)" : ""
        let pages = p.pages.map { "\(grouped($0)) pages printed\(known)" } ?? (p.kind == .scanner ? "Pages: a scanner has no count" : "Pages not reported")
        let firmware = p.firmware.map { "Firmware \($0)\(known)" } ?? "Firmware not reported"
        let read = lastRead(p, now, timeZone)
        let none: String? = !supplies.isEmpty ? nil : p.kind == .scanner ? "No supplies: it's a scanner" : "Supplies not reported"
        let suppliesSaid = !supplies.isEmpty ? supplies.map { $0.isLow ? "\($0.text), low" : $0.text }.joined(separator: ", ") : none
        let said = [p.name, troubleText(p.trouble), status, suppliesSaid, pages, firmware, read].compactMap { $0 }.joined(separator: ". ")
        return FleetRow(printer: p, statusLine: status, supplies: supplies, noSuppliesText: none, pagesText: pages, firmwareText: firmware,
                        lastReadText: read, accessibleText: said + ".")
    }

    /// "9 printers: 1 with an error, 3 needing attention, 2 can't be reached, 3 fine."
    public static func summary(_ printers: [FleetPrinter]) -> String {
        if printers.isEmpty { return "No printers yet." }
        func count(_ t: FleetTrouble) -> Int { printers.filter { $0.trouble == t }.count }
        let parts: [(Int, String)] = [
            (count(.error), count(.error) == 1 ? "with an error" : "with errors"),
            (count(.warning), "needing attention"),
            (count(.offline), "can't be reached"),
            (count(.unknown), "not known yet"),
            (count(.ok), "fine"),
        ]
        let said = parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
        return "\(printers.count) \(printers.count == 1 ? "printer" : "printers"): \(said)."
    }

    public static func troubleText(_ trouble: FleetTrouble) -> String {
        switch trouble {
        case .error: "Error"
        case .warning: "Needs attention"
        case .offline: "Can't be reached"
        case .unknown: "Not known yet"
        case .ok: "Fine"
        }
    }

    private static func supplyText(_ s: FleetSupply) -> String {
        if let level = s.level { return "\(s.name) \(level)%" }
        switch s.state {
        case "full": return "\(s.name): full"
        case "almostFull": return "\(s.name): almost full"
        case "out": return "\(s.name): empty"
        case "missing": return "\(s.name): missing"
        case "low", "veryLow": return "\(s.name): low"
        case "ok": return "\(s.name): OK"
        default: return s.name
        }
    }

    private static func isLow(_ s: FleetSupply) -> Bool { ["low", "veryLow", "out", "almostFull", "full", "missing"].contains(s.state) }

    /// .NET's "N0" with the invariant culture: 12,345.
    static func grouped(_ n: Int) -> String {
        let digits = String(n.magnitude)
        var out = ""
        for (i, c) in digits.enumerated() {
            if i > 0 && (digits.count - i) % 3 == 0 { out.append(",") }
            out.append(c)
        }
        return (n < 0 ? "-" : "") + out
    }

    private static func lastRead(_ p: FleetPrinter, _ now: Date, _ timeZone: TimeZone) -> String {
        if let time = p.lastReading {
            let ago = now.timeIntervalSince(time)
            if ago < 60 { return "Read just now" }
            if ago < 3600 { return Int(ago / 60) == 1 ? "Read 1 minute ago" : "Read \(Int(ago / 60)) minutes ago" }
            if ago < 86400 { return Int(ago / 3600) == 1 ? "Read 1 hour ago" : "Read \(Int(ago / 3600)) hours ago" }
            return "Last read \(dayText(Day(time, timeZone: timeZone)))"
        }
        return p.lastReadingDay.map { "Last read \(dayText($0))" } ?? "Not read yet"
    }

    /// "29 Oct 2026", in the Mac's language.
    private static func dayText(_ day: Day) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.setLocalizedDateFormatFromTemplate("dMMMyyyy")
        var c = DateComponents()
        (c.year, c.month, c.day) = (day.year, day.month, day.day)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: c).map { formatter.string(from: $0) } ?? day.description
    }
}
