import Foundation

/// What a fleet entry is: a network printer, a printer's macOS queue or a scanner, as the Fleet page and the JSON say it
/// (the Windows app's `FleetKind`).
public enum FleetKind: Sendable { case network, queue, scanner }

/// How much trouble a printer is in, in the list's order (the worst first): an error outranks a low supply, which outranks
/// a printer that's off, as the menu bar ranks them.
public enum FleetTrouble: Int, Comparable, Sendable {
    case error, warning, offline, unknown, ok

    public static func < (a: FleetTrouble, b: FleetTrouble) -> Bool { a.rawValue < b.rawValue }
}

/// One supply as the fleet shows it. `level` is 0 to 100, or nil when the printer gives none.
public struct FleetSupply: Equatable, Sendable {
    public var name: String
    public var color: String?
    public var level: Int?
    public var state: String

    public init(_ name: String, _ color: String?, _ level: Int?, _ state: String) {
        self.name = name
        self.color = color
        self.level = level
        self.state = state
    }
}

/// How a queue is connected, in words without a server's or port's name (the Windows app's `FleetReader.ConnectionWord`).
public enum FleetConnection {
    public static let usb = "USB"
    public static let network = "Network"
    /// A queue another computer shares: its name ends in that computer's name, which an export leaves out.
    public static let shared = "Shared from another computer"
    public static let other = "Other"

    /// A network printer's interfaces as the page and `status --all` both show them ("LEDM, IPP"); nil when it gave none.
    public static func interfaces(_ list: [String]) -> String? { list.isEmpty ? nil : list.joined(separator: ", ") }
}

/// What is known of a printer, as read (the sources' own text, not trusted): `FleetPrinter.of` makes the entry.
public struct FleetFacts: Sendable {
    public var id: String
    public var name: String
    public var kind: FleetKind
    public var model: String?
    /// How it's reached: its interfaces ("LEDM, eSCL") or how its queue is connected ("USB").
    public var connection: String?
    /// It answered, now. No: its status says why, and the rest is what's `lastKnown`.
    public var reachable = false
    /// Nil, or `PrinterStatus.isUnavailable`: it answered without a usable status.
    public var status: PrinterStatus?
    public var supplies: [Consumable] = []
    public var pages: Int?
    public var firmware: String?
    /// When it last gave a reading.
    public var lastReading: Date?
    /// The day it last gave a reading, when only the supply history knows (one row a day).
    public var lastReadingDay: Day?
    /// Its supplies, pages and firmware are from its last reading, not from now.
    public var lastKnown = false
    /// It answered, but its `supplies` are the supply history's: what they said then isn't trouble now.
    public var oldSupplies = false

    public init(_ id: String, _ name: String, _ kind: FleetKind) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

/// One entry of the Fleet page and the export: every text cleaned and bounded (`FleetText`), since a printer writes most of
/// it, and its trouble decided in one place. It holds no serial number, address or UUID; `id` tells entries apart on the
/// page and is never written out.
public struct FleetPrinter: Equatable, Sendable {
    public static let maxText = 240, maxItems = 16

    public var id: String
    public var name: String
    public var kind: FleetKind
    public var trouble: FleetTrouble
    public var status: String
    public var model: String?
    public var connection: String?
    public var problems: [String] = []
    public var supplies: [FleetSupply] = []
    public var pages: Int?
    public var firmware: String?
    public var lastReading: Date?
    public var lastReadingDay: Day?
    public var lastKnown = false

    public init(id: String, name: String, kind: FleetKind, trouble: FleetTrouble, status: String) {
        self.id = id
        self.name = name
        self.kind = kind
        self.trouble = trouble
        self.status = status
    }

    public static func of(_ f: FleetFacts) -> FleetPrinter {
        let usable = f.status.flatMap { $0.isUnavailable ? nil : $0 }
        var p = FleetPrinter(id: f.id, name: FleetText.clean(f.name, maxText) ?? "Printer with no name", kind: f.kind,
                             trouble: troubleOf(f, usable), status: FleetText.clean(f.status?.message, maxText) ?? "Status not available")
        p.model = FleetText.clean(f.model, maxText)
        p.connection = FleetText.clean(f.connection, maxText)
        // Worst first, keeping the printer's order among equals (a stable sort, as LINQ's OrderByDescending).
        let alerts = (usable?.alerts ?? []).filter { $0.severity != .info }.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
        var problems: [String] = []
        for alert in alerts {
            guard let text = FleetText.clean(alert.element.message, maxText), !problems.contains(text) else { continue }
            problems.append(text)
            if problems.count == maxItems { break }
        }
        p.problems = problems
        p.supplies = f.supplies.prefix(maxItems).map { s in
            FleetSupply(FleetText.clean(s.name, maxText) ?? s.kind, FleetText.clean(s.colorCode, 24),
                        s.percentRemaining.flatMap { $0 >= 0 ? min($0, 100) : nil }, FleetText.clean(s.state, 24) ?? "unknown")
        }
        p.pages = f.pages.flatMap { $0 >= 0 ? $0 : nil }
        p.firmware = FleetText.clean(f.firmware, maxText)
        p.lastReading = f.lastReading
        p.lastReadingDay = f.lastReadingDay
        p.lastKnown = f.lastKnown
        return p
    }

    private static func troubleOf(_ f: FleetFacts, _ status: PrinterStatus?) -> FleetTrouble {
        if !f.reachable { return .offline }
        var trouble: FleetTrouble
        switch status?.severity {
        case nil: trouble = .unknown
        case .error: trouble = .error
        case .warning: trouble = .warning
        case .info: trouble = .ok
        }
        for s in f.oldSupplies ? [] : f.supplies {
            // An empty supply, as the menu bar has it (AlertConditions).
            if ["out", "full", "missing"].contains(s.state) || (!s.isWaste && (s.percentRemaining.map { $0 <= 0 } ?? false)) { return .error }
            if s.isLow && trouble > .warning { trouble = .warning }
        }
        return trouble
    }
}

/// The list's order: most trouble first, then by name and id, so it doesn't jump about between reads.
public enum FleetOrder {
    public static func sort(_ printers: [FleetPrinter]) -> [FleetPrinter] {
        printers.sorted { a, b in
            if a.trouble != b.trouble { return a.trouble < b.trouble }
            let na = a.name.uppercased(), nb = b.name.uppercased()
            if na != nb { return na.unicodeScalars.lexicographicallyPrecedes(nb.unicodeScalars) }
            return a.id.uppercased().unicodeScalars.lexicographicallyPrecedes(b.id.uppercased().unicodeScalars)
        }
    }
}

/// Text a printer or a driver wrote, made fit to show and write out.
public enum FleetText {
    /// One line at most `max` UTF-16 units long, or nil when nothing is left: no control or invisible characters (a
    /// right-to-left override turns a line round on screen, a line break forges a row), single spaces. Swift's strings hold
    /// no half surrogate pairs (decoding one gives U+FFFD), so that part of the Windows rule has nothing to do here.
    public static func clean(_ text: String?, _ max: Int) -> String? {
        guard let text else { return nil }
        var clean: [UInt16] = []
        var space = false
        var units = 0
        // Past this nothing would be kept: a printer's megabyte of text costs no more than its first few hundred characters.
        let end = Swift.min(text.utf16.count, max * 4 + 64)
        for scalar in text.unicodeScalars {
            if units >= end || clean.count > max + 1 { break }
            units += scalar.utf16.count
            switch scalar.properties.generalCategory {
            case .control where isWhiteSpaceControl(scalar), .spaceSeparator, .lineSeparator, .paragraphSeparator:
                space = true
            case .control, .format, .surrogate, .privateUse, .unassigned:
                break
            default:
                if space && !clean.isEmpty { clean.append(32) }
                space = false
                clean.append(contentsOf: scalar.utf16)
            }
        }
        if clean.isEmpty { return nil }
        if clean.count <= max { return String(decoding: clean, as: UTF16.self) }
        var cut = max - 1 // room for the ellipsis, and never half a pair
        if UTF16.isTrailSurrogate(clean[cut]) { cut -= 1 }
        var kept = String(decoding: clean[..<cut], as: UTF16.self)
        while kept.last?.isWhitespace == true { kept.removeLast() }
        return kept + "…"
    }

    /// .NET's `char.IsWhiteSpace` for a control character: tab, line feed, vertical tab, form feed, carriage return, NEL.
    private static func isWhiteSpaceControl(_ s: Unicode.Scalar) -> Bool { (9...13).contains(s.value) || s.value == 0x85 }
}

/// What the supply history says of a printer that isn't answering: its last day's levels and page count.
public struct FleetLastKnown: Equatable, Sendable {
    public var day: Day
    public var pages: Int?
    public var supplies: [Consumable]

    public static func from(_ rows: [SupplyRow]) -> FleetLastKnown? {
        guard let day = rows.map(\.day).max() else { return nil }
        // The last row with a count, by day (a stable sort keeps the store's order within one).
        let counted = rows.enumerated().filter { $0.element.pages != nil }
            .sorted { $0.element.day != $1.element.day ? $0.element.day < $1.element.day : $0.offset < $1.offset }
        return FleetLastKnown(day: day, pages: counted.last?.element.pages,
                              supplies: rows.filter { $0.day == day }.map { Consumable(name: $0.supply, kind: "", colorCode: $0.color, percentRemaining: $0.percent, state: $0.state) })
    }
}
