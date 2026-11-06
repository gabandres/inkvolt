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
        let known = p.lastKnown
        let notReported = p.kind == .scanner ? loc("Pages: a scanner has no count") : loc("Pages not reported")
        let pages = p.pages.map { known ? loc("{0} pages printed (last known)", CoreLanguage.number($0)) : loc("{0} pages printed", CoreLanguage.number($0)) } ?? notReported
        let firmware = p.firmware.map { known ? loc("Firmware {0} (last known)", $0) : loc("Firmware {0}", $0) } ?? loc("Firmware not reported")
        let read = lastRead(p, now, timeZone)
        let none: String? = !supplies.isEmpty ? nil : p.kind == .scanner ? loc("No supplies: it's a scanner") : loc("Supplies not reported")
        let suppliesSaid = !supplies.isEmpty ? supplies.map { $0.isLow ? loc("{0}, low", $0.text) : $0.text }.joined(separator: ", ") : none
        let said = [p.name, troubleText(p.trouble), status, suppliesSaid, pages, firmware, read].compactMap { $0 }.joined(separator: ". ")
        return FleetRow(printer: p, statusLine: status, supplies: supplies, noSuppliesText: none, pagesText: pages, firmwareText: firmware,
                        lastReadText: read, accessibleText: said + ".")
    }

    /// "9 printers: 1 with an error, 3 needing attention, 2 can't be reached, 3 fine."
    public static func summary(_ printers: [FleetPrinter]) -> String {
        if printers.isEmpty { return loc("No printers yet.") }
        func count(_ t: FleetTrouble) -> Int { printers.filter { $0.trouble == t }.count }
        func said(_ t: FleetTrouble) -> String? {
            let n = count(t)
            guard n > 0 else { return nil }
            let one = n == 1
            switch t {
            case .error: return one ? loc("{0} with an error", n) : loc("{0} with errors", n)
            case .warning: return one ? loc("{0} needing attention", context: "one", n) : loc("{0} needing attention", context: "many", n)
            case .offline: return one ? loc("{0} can't be reached", context: "one", n) : loc("{0} can't be reached", context: "many", n)
            case .unknown: return one ? loc("{0} not known yet", context: "one", n) : loc("{0} not known yet", context: "many", n)
            case .ok: return one ? loc("{0} fine", context: "one", n) : loc("{0} fine", context: "many", n)
            }
        }
        let parts = [FleetTrouble.error, .warning, .offline, .unknown, .ok].compactMap(said).joined(separator: ", ")
        return printers.count == 1 ? loc("{0} printer: {1}.", printers.count, parts) : loc("{0} printers: {1}.", printers.count, parts)
    }

    public static func troubleText(_ trouble: FleetTrouble) -> String {
        switch trouble {
        case .error: loc("Error")
        case .warning: loc("Needs attention")
        case .offline: loc("Can't be reached")
        case .unknown: loc("Not known yet")
        case .ok: loc("Fine")
        }
    }

    private static func supplyText(_ s: FleetSupply) -> String {
        let name = SupplyNames.display(s.name)
        if let level = s.level { return "\(name) \(level)%" }
        switch s.state {
        case "full": return loc("{0}: full", name)
        case "almostFull": return loc("{0}: almost full", name)
        case "out": return loc("{0}: empty", name)
        case "missing": return loc("{0}: missing", name)
        case "low", "veryLow": return loc("{0}: low", name)
        case "ok": return loc("{0}: OK", name)
        default: return name
        }
    }

    private static func isLow(_ s: FleetSupply) -> Bool { ["low", "veryLow", "out", "almostFull", "full", "missing"].contains(s.state) }

    private static func lastRead(_ p: FleetPrinter, _ now: Date, _ timeZone: TimeZone) -> String {
        if let time = p.lastReading {
            let ago = now.timeIntervalSince(time)
            if ago < 60 { return loc("Read just now") }
            let minutes = Int(ago / 60), hours = Int(ago / 3600)
            if ago < 3600 { return minutes == 1 ? loc("Read {0} minute ago", minutes) : loc("Read {0} minutes ago", minutes) }
            if ago < 86400 { return hours == 1 ? loc("Read {0} hour ago", hours) : loc("Read {0} hours ago", hours) }
            return loc("Last read {0}", dayText(Day(time, timeZone: timeZone)))
        }
        return p.lastReadingDay.map { loc("Last read {0}", dayText($0)) } ?? loc("Not read yet")
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

extension FleetFacts {
    /// A printer as the Fleet page lists it, from what the app shows of it (the Windows app's `PrinterViewModel.FleetFacts`):
    /// nothing is read from the printer here. `known`: the supply history's last word, for one that isn't answering.
    /// Connecting counts as reachable with no usable status yet (not known yet, not "can't be reached").
    public static func shown(_ id: String, _ name: String, _ kind: FleetKind, view: PrinterView, connection: String?, firmware: String?,
                             lastReading: Date?, known: FleetLastKnown?) -> FleetFacts {
        let live = view.supplies
        let waiting = view.phase == .connecting
        var f = FleetFacts(id, name, kind)
        f.model = view.model
        f.connection = connection
        f.reachable = view.isOnline || waiting
        f.status = waiting ? .unavailable(view.statusMessage)
            : PrinterStatus(code: "", message: view.statusMessage, severity: view.severity, alerts: view.alerts)
        f.supplies = live.isEmpty ? known?.supplies ?? [] : live
        f.pages = view.usage?.totalImpressions ?? known?.pages
        f.firmware = firmware
        f.lastReading = lastReading
        f.lastReadingDay = lastReading == nil ? known?.day : nil
        let kept = !live.isEmpty || known != nil || view.usage?.totalImpressions != nil
        f.lastKnown = !view.isOnline && !waiting && kept
        f.oldSupplies = live.isEmpty
        return f
    }
}

/// Which printers' supply history the Fleet page reads, and what it read (`FleetFacts.shown`'s `known`): a printer's last word
/// is read once each time it stops answering, and again each time the page shows; it's dropped once the printer answers, so
/// its next silence reads the rows written meanwhile. A read that comes back after the printer answered is dropped too.
public struct FleetHistoryAsks: Sendable {
    public private(set) var known: [String: FleetLastKnown] = [:]
    private var asked = Set<String>()

    public init() {}

    /// The page shows again: each silent printer's history is read again.
    public mutating func showAgain() { asked = [] }

    /// `silent`: the printers not answering (not those still connecting); `answering`: those that answer. The ids whose
    /// history to read now.
    public mutating func due(silent: [String], answering: [String]) -> [String] {
        for id in answering {
            asked.remove(id)
            known[id] = nil
        }
        return silent.filter { asked.insert($0).inserted }
    }

    /// A read of `id`'s history came back: kept while it's still wanted (the printer hasn't answered since it was asked).
    public mutating func got(_ id: String, _ last: FleetLastKnown?) {
        guard asked.contains(id) else { return }
        known[id] = last
    }
}
