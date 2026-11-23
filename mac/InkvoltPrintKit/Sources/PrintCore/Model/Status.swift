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
    /// What the printer's control panel says now, as the printer sends it (the Printer MIB's prtConsoleDisplayBufferText
    /// lines, IPP's `printer-state-message`, LEDM's status text); nil when it says nothing or wasn't read. CDM has no such
    /// text that we know of.
    public var panelText: String?

    public init(code: String, message: String, severity: Severity, alerts: [PrinterAlert], detail: String? = nil, panelText: String? = nil) {
        self.code = code
        self.message = message
        self.severity = severity
        self.alerts = alerts
        self.detail = detail
        self.panelText = panelText
    }

    /// The longest panel text shown (a panel's few lines; a printer may send pages).
    public static let maxPanelText = 160

    /// The panel's text to show with the status: one clean line of at most `maxPanelText` characters (`FleetText.clean`),
    /// only when it says more than the status line does (not the same words, ignoring case and a final period, nor a plain
    /// "Idle" or "Ready" under the app's own word for it). A ready or idle printer's panel saying one short line of a word or
    /// two is its state in the panel's language ("Prêt", "Bereit", "Lista"): not shown either. Nil otherwise.
    public var panelNote: String? {
        guard let text = FleetText.clean(panelText, Self.maxPanelText) else { return nil }
        let said = IppClient.headline(text, message)
        if Self.trimmedEnd(said).caseInsensitiveCompare(Self.trimmedEnd(message.trimmingCharacters(in: .whitespaces))) == .orderedSame { return nil }
        if (code == "ready" || code == "idle") && Self.isStateWord(said) { return nil }
        return said
    }

    private static func trimmedEnd(_ text: String) -> String {
        var t = Substring(text)
        while t.last == "." || t.last == "!" { t.removeLast() }
        return String(t)
    }

    /// One short line of one or two words, no figures: how a panel names its state, in whatever language.
    private static func isStateWord(_ text: String) -> Bool {
        text.count <= 20 && !text.contains(" · ") && !text.contains(where: \.isNumber)
            && text.split(separator: " ", omittingEmptySubsequences: true).count <= 2
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
    /// The pages a full cartridge is rated for, when the printer says (CDM's `capacity` in pages, IPP's `printer-supply` and
    /// the Printer MIB's prtMarkerSuppliesMaxCapacity counted in impressions or sheets); nil otherwise. Beside
    /// `estimatedPagesRemaining`, the pages left in it now.
    public var pageYield: Int?

    public init(name: String, kind: String, colorCode: String?, percentRemaining: Int?, state: String,
                productNumber: String? = nil, selectibilityNumber: String? = nil, lowThreshold: Int? = nil,
                estimatedPagesRemaining: Int? = nil, installed: DateComponents? = nil, pageYield: Int? = nil) {
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
        self.pageYield = pageYield
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

public struct ProductInfo: Equatable, Sendable {
    public var makeAndModel: String
    public var family: String?
    public var serialNumber: String?
    public var productNumber: String?
    public var uuid: String?
    public var firmwareDate: String?
    public var adminPasswordSet: Bool?
    public var firmwareRevision: String?

    public init(makeAndModel: String, family: String? = nil, serialNumber: String? = nil, productNumber: String? = nil, uuid: String? = nil,
                firmwareDate: String? = nil, adminPasswordSet: Bool? = nil, firmwareRevision: String? = nil) {
        self.makeAndModel = makeAndModel
        self.family = family
        self.serialNumber = serialNumber
        self.productNumber = productNumber
        self.uuid = uuid
        self.firmwareDate = firmwareDate
        self.adminPasswordSet = adminPasswordSet
        self.firmwareRevision = firmwareRevision
    }
}

/// The firmware a printer reports. LEDM gives its release date (an HP LaserJet's firmware version is that date) and on
/// some models a revision; IPP printers give `printer-firmware-string-version`.
public struct FirmwareInfo: Equatable, Sendable {
    public var version: String?
    public var date: String?

    /// "2024-08-13", "SAYPRO1N001.2045A (2024-08-13)" or just the version.
    public var display: String {
        guard let version else { return date ?? "" }
        guard let date else { return version }
        return "\(version) (\(date))"
    }

    public static func from(_ product: ProductInfo?, _ ipp: IppResponse?) -> FirmwareInfo? {
        let version = product?.firmwareRevision ?? fromIpp(ipp)
        let date = product?.firmwareDate
        return version == nil && date == nil ? nil : FirmwareInfo(version: version, date: date)
    }

    /// IPP's firmware attributes are parallel lists (one entry per component). The first is the main firmware on the
    /// printers seen so far; prefer an entry whose name says so.
    private static func fromIpp(_ ipp: IppResponse?) -> String? {
        guard let ipp else { return nil }
        let versions = ipp.strs("printer-firmware-string-version")
        guard let first = versions.first else { return nil }
        let main = ipp.strs("printer-firmware-name").firstIndex {
            $0.range(of: "firmware", options: .caseInsensitive) != nil || $0.range(of: "system", options: .caseInsensitive) != nil
        }
        if let main, main < versions.count { return versions[main] }
        return first
    }
}

public struct UsageCounters: Equatable, Sendable {
    public var totalImpressions: Int?
    public var duplexSheets: Int?
    public var jamEvents: Int?
    public var mispickEvents: Int?
    public var scanImages: Int?

    public init(totalImpressions: Int?, duplexSheets: Int?, jamEvents: Int?, mispickEvents: Int?, scanImages: Int?) {
        self.totalImpressions = totalImpressions
        self.duplexSheets = duplexSheets
        self.jamEvents = jamEvents
        self.mispickEvents = mispickEvents
        self.scanImages = scanImages
    }
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
