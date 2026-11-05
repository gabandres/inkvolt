import Foundation

/// How ready a printer is to print now.
public enum Readiness: Sendable, Equatable {
    case ready, sleeping, busy, attention, error, offline, unknown
}

/// A printer's state reduced to what matters before printing: ready / sleeping / busy / needs attention / error / offline,
/// toner level and paper problems, built from Inkvolt Print's protocol-neutral status and supplies (shared/
/// InkvoltPrint.Core/Suite/PrinterHealth.cs, ported with its tests). Inkvolt PDF shows it in its print panel.
public struct PrinterHealth: Sendable, Equatable {
    public var state: Readiness
    public var text: String
    public var tonerPercent: Int?
    public var paperProblems: [String]
    public var problems: [String]
    public var supplies: [String]

    public init(state: Readiness, text: String, tonerPercent: Int? = nil, paperProblems: [String] = [], problems: [String] = [],
                supplies: [String] = []) {
        self.state = state
        self.text = text
        self.tonerPercent = tonerPercent
        self.paperProblems = paperProblems
        self.problems = problems
        self.supplies = supplies
    }

    /// Printing now would likely fail or wait: offline, or an error (jam, no paper, door open, empty toner).
    public var shouldWarn: Bool { state == .offline || state == .error }

    public static func offline(_ why: String) -> PrinterHealth { PrinterHealth(state: .offline, text: why) }

    /// One line: "Ready · toner 45%", "Sleeping · toner 8% (low)", "Tray empty or open".
    public var summary: String {
        var parts = [text]
        for p in paperProblems + problems where !parts.contains(where: { $0.caseInsensitiveCompare(p) == .orderedSame }) {
            parts.append(p)
        }
        if let t = tonerPercent { parts.append("toner \(t)%") }
        return parts.joined(separator: " · ")
    }

    public static func from(_ status: PrinterStatus, _ supplies: [Consumable]) -> PrinterHealth {
        let warnings = status.alerts.filter { $0.severity >= .warning }
        let paper = distinct(warnings.filter { isPaper($0.id) }.map(\.message))
        let problems = distinct(warnings.filter { !isPaper($0.id) }.map(\.message))
        func has(_ s: String, _ word: String) -> Bool { s.range(of: word, options: .caseInsensitive) != nil }
        var toners = supplies.filter { has($0.kind, "toner") || has($0.name, "toner") }
        if toners.isEmpty { toners = supplies.filter { has($0.kind, "ink") || has($0.kind, "cartridge") } }
        let toner = toners.compactMap(\.percentRemaining).min()
        let supplyText = supplies.compactMap { c in c.percentRemaining.map { "\(c.name): \($0)%\(c.isLow ? " (low)" : "")" } }
        let state = readiness(status)
        let text: String
        switch state {
        case .sleeping: text = "Sleeping"
        case .ready: text = "Ready"
        default: text = status.message
        }
        return PrinterHealth(state: state, text: text, tonerPercent: toner, paperProblems: paper, problems: problems, supplies: supplyText)
    }

    private static let busyCodes: Set<String> = ["processing", "copying", "scanProcessing", "initializing", "coolDownMode", "cancelJob",
                                                 "upgrading", "connectingToWeb", "deviceInteraction", "waitingForSupplyAssessment"]

    private static func readiness(_ status: PrinterStatus) -> Readiness {
        let code = status.code
        if code == "offline" { return .offline }
        if (code == "unavailable" || code == "unknown") && status.alerts.isEmpty { return .unknown }
        if status.severity == .error { return .error }
        if code == "inPowerSave" { return .sleeping }
        if code == "ready" || code == "idle" { return status.severity == .warning ? .attention : .ready }
        if code == "stopped" { return .error }
        if status.severity == .warning { return .attention }
        return busyCodes.contains(code) ? .busy : .unknown
    }

    private static func distinct(_ items: [String]) -> [String] {
        var seen = Set<String>()
        return items.filter { seen.insert($0).inserted }
    }

    /// Paper path problems (LEDM ids and IPP printer-state-reasons), not the scanner's document feeder.
    static func isPaper(_ id: String) -> Bool {
        if id.range(of: "scanner", options: [.caseInsensitive, .anchored]) != nil { return false }
        return ["media", "tray", "jam", "mispick", "paper", "feed"].contains { id.range(of: $0, options: .caseInsensitive) != nil }
    }
}
