import Foundation

public enum Severity: Int, Comparable, Sendable {
    case info, warning, error

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }
}

public struct PrinterAlert: Equatable, Sendable {
    public var id: String
    public var severity: Severity
    public var message: String

    public init(id: String, severity: Severity, message: String) {
        self.id = id
        self.severity = severity
        self.message = message
    }
}

/// Device status in protocol-neutral form.
public struct PrinterStatus: Equatable, Sendable {
    public var code: String
    public var message: String
    public var severity: Severity
    public var alerts: [PrinterAlert]
    public var detail: String?

    public init(code: String, message: String, severity: Severity, alerts: [PrinterAlert], detail: String? = nil) {
        self.code = code
        self.message = message
        self.severity = severity
        self.alerts = alerts
        self.detail = detail
    }

    public static func offline(_ why: String) -> PrinterStatus { PrinterStatus(code: "offline", message: why, severity: .error, alerts: []) }

    /// The printer answered but the reply was unusable (waking up, busy, malformed). Keep showing the last status.
    public static func unavailable(_ why: String) -> PrinterStatus {
        PrinterStatus(code: "unavailable", message: why, severity: .info, alerts: [])
    }

    public var isUnavailable: Bool { code == "unavailable" }

    /// One line for a list of printers: the state, then for a warning or error the worst alert's words ("Ready · Yellow ink
    /// is low") and how many more there are, so an amber or red dot is never left unexplained. An alert that repeats or
    /// extends the state's words takes its place.
    public static func listLine(_ message: String, _ severity: Severity, _ alerts: [PrinterAlert]) -> String {
        if severity == .info { return message }
        // A stable sort, worst first, as LINQ's OrderByDescending.
        let shown = alerts.filter { $0.severity != .info }.enumerated()
            .sorted { $0.element.severity != $1.element.severity ? $0.element.severity > $1.element.severity : $0.offset < $1.offset }
            .map(\.element)
        guard let worst = shown.first else { return message }
        let reason = trimmedSentence(worst.message)
        let line = reason.lowercased().hasPrefix(trimmedSentence(message).lowercased()) ? reason : "\(message) · \(reason)"
        return shown.count > 1 ? "\(line) · +\(shown.count - 1)" : line
    }

    private static func trimmedSentence(_ text: String) -> String {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(".") { t.removeLast() }
        return t
    }
}

public struct Consumable: Equatable, Sendable {
    public var name: String
    public var kind: String
    public var colorCode: String?
    public var percentRemaining: Int?
    public var state: String
    public var productNumber: String?
    public var selectibilityNumber: String?
    public var lowThreshold: Int?
    public var estimatedPagesRemaining: Int?
    public var installed: DateComponents?

    public init(name: String, kind: String, colorCode: String?, percentRemaining: Int?, state: String,
                productNumber: String? = nil, selectibilityNumber: String? = nil, lowThreshold: Int? = nil,
                estimatedPagesRemaining: Int? = nil, installed: DateComponents? = nil) {
        self.name = name
        self.kind = kind
        self.colorCode = colorCode
        self.percentRemaining = percentRemaining
        self.state = state
        self.productNumber = productNumber
        self.selectibilityNumber = selectibilityNumber
        self.lowThreshold = lowThreshold
        self.estimatedPagesRemaining = estimatedPagesRemaining
        self.installed = installed
    }

    /// Needs attention soon: low, empty, or (a waste box) almost full or full.
    public var isLow: Bool {
        if ["low", "veryLow", "out", "almostFull", "full"].contains(state) { return true }
        if let percent = percentRemaining, let threshold = lowThreshold { return percent <= threshold }
        return false
    }

    /// A box that fills up (waste ink or toner, an inkjet's maintenance box) rather than a supply that runs out.
    public var isWaste: Bool { Consumable.isWasteKind(kind) }

    public static func isWasteKind(_ kind: String) -> Bool { kind.lowercased().hasPrefix("waste") }
}

/// Whether the device answering at a printer's address is that printer.
public enum DeviceIdentity: Sendable {
    /// The printer reports no UUID (or was remembered without one): can't tell.
    case unknown
    /// It reports the remembered UUID.
    case same
    /// It reports other UUIDs only: another device has the address.
    case different
}
