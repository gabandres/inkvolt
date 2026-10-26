import Foundation

/// HP CDM (Common Device Management: JSON under `/cdm/...`), the interface newer HP printers have instead of LEDM. HP
/// publishes no specification; the paths and fields here are the ones public, permissively licensed clients read and show
/// in captured replies (iDrunK65/HA-HP-printers and kou147258/ha-hp-printers-cn, both MIT, with fixtures from a Color
/// LaserJet Pro MFP 3302 and a Smart Tank 580-590; HPLIP for the supply fields, facts only). Read only: every path is a GET.
public enum CdmPaths {
    public static let identity = "/cdm/system/v1/identity"
    public static let supplies = "/cdm/supply/v1/suppliesPublic"
    public static let systemStatus = "/cdm/system/v1/status"
    public static let printStatus = "/cdm/print/v2/status"
    public static let alerts = "/cdm/alert/v1/alerts"
}

/// CDM replies → the app's model. Tolerant: fields may be missing, booleans and numbers may come as strings, unknown values
/// are humanised, and anything that isn't the expected JSON gives nil or an empty list rather than an error.
public enum CdmParsers {
    /// The printer's identity; nil when the reply has no model (not a CDM identity).
    public static func parseIdentity(_ json: String) -> ProductInfo? {
        guard let root = Json.parse(json)?.objectValue else { return nil }
        let mm = root["makeAndModel"]
        let model: String?
        switch mm {
        case .string(let s)?: model = s
        case .object(let o)?: model = str(o, "name") ?? str(o, "base")
        default: model = nil
        }
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return ProductInfo(
            makeAndModel: model.trimmingCharacters(in: .whitespacesAndNewlines),
            family: mm?.objectValue.flatMap { str($0, "family") },
            serialNumber: str(root, "serialNumber"),
            productNumber: str(root, "productNumber"),
            uuid: str(root, "deviceUuid"),
            firmwareDate: dateCode(str(root, "firmwareDateCode")),
            adminPasswordSet: nil,
            firmwareRevision: str(root, "firmwareVersion"))
    }

    /// "202607240158" or "20250918" → "2026-07-24"; anything else as given.
    private static func dateCode(_ code: String?) -> String? {
        guard let code, code.count >= 8 else { return code }
        let digits = String(code.prefix(8))
        guard digits.allSatisfy(\.isASCIIDigit), let y = Int(digits.prefix(4)), let m = Int(digits.dropFirst(4).prefix(2)),
              let d = Int(digits.suffix(2)), LedmParsers.isValidDate(y, m, d) else { return code }
        return "\(digits.prefix(4))-\(digits.dropFirst(4).prefix(2))-\(digits.suffix(2))"
    }

    /// `suppliesList` → supplies: toner, ink cartridges, ink tanks (with their printheads after them: on tank printers the
    /// `inkCartridge` slots are printheads and report no level), drums. The state is `supplyState`, made finer by
    /// `levelState` (low, very low) when the supply itself is fine.
    public static func parseSupplies(_ json: String) -> [Consumable] {
        guard let list = Json.parse(json)?["suppliesList"]?.arrayValue else { return [] }
        let items = list.compactMap(\.objectValue)
        let tanks = items.contains { str($0, "supplyType") == "inkTank" }
        var supplies: [(supply: Consumable, printhead: Bool)] = []
        for e in items {
            let kind: String
            switch str(e, "supplyType") {
            case nil: kind = "supply"
            case "toner", "tonerCartridge", "rechargeableToner": kind = "toner"
            case "inkCartridge" where tanks: kind = "printhead"
            case "ink", "inkCartridge": kind = "ink cartridge"
            case "inkTank": kind = "ink tank"
            case "printhead", "printHead": kind = "printhead"
            case "imageDrum": kind = "drum"
            case let other?: kind = LedmStatusText.humanize(other).lowercased()
            }
            let code = str(e, "supplyColorCode")
            let level = int(e, "percentLifeDisplay")
            let name = "\(colorName(code)) \(kind)".trimmingCharacters(in: .whitespaces)
            let pages = int(e, "approximatePagesRemainingDisplay")
            supplies.append((Consumable(
                name: name.prefix(1).uppercased() + name.dropFirst(),
                kind: kind,
                colorCode: code == "pK" || code == "mK" ? "K" : code,
                percentRemaining: level.flatMap { $0 >= 0 ? min($0, 100) : nil },
                state: state(str(e, "supplyState"), str(e, "levelState")),
                productNumber: str(e, "orderPartNumber") ?? str(e, "productNumber") ?? str(e, "orderSelectabilityNumber")
                    ?? str(e, "selectabilityNumber"),
                selectibilityNumber: str(e, "selectabilityNumber") ?? str(e, "orderSelectabilityNumber"),
                estimatedPagesRemaining: pages.flatMap { $0 >= 0 ? $0 : nil }), kind == "printhead"))
        }
        return supplies.filter { !$0.printhead }.map(\.supply) + supplies.filter(\.printhead).map(\.supply)
    }

    private static func state(_ supply: String?, _ level: String?) -> String {
        switch supply {
        case "ok", "inform": return ["low", "veryLow", "out"].contains(level) ? level! : "ok"
        case "low", "veryLow", "out", "missing": return supply!
        case "misinstalled": return "missing"
        default: return "unknown"
        }
    }

    private static func colorName(_ code: String?) -> String {
        switch code {
        case "K": "Black"
        case "C": "Cyan"
        case "M": "Magenta"
        case "Y": "Yellow"
        case "CMY": "Tri-color"
        case "pK": "Photo black"
        case "mK": "Matte black"
        case "G": "Gray"
        case nil: ""
        case let other?: other
        }
    }

    // MARK: Status

    private static let knownAlerts: [String: (text: String, severity: Severity, detail: String?)] = [
        "doorOpen": ("Door open", .error, "A door or cover is open. Close it to continue."),
        "trayEmpty": ("Load paper", .error, "Load paper into the tray and push it all the way in."),
        "trayOpen": ("Tray open", .error, "Push the paper tray all the way in."),
        "cartridgeLow": ("Cartridge low", .warning, "Printing goes on; have a replacement ready."),
        "cartridgeVeryLow": ("Cartridge very low", .warning, "Print quality may drop soon; replace the cartridge."),
        "cartridgeOut": ("Cartridge empty", .error, "Replace the cartridge to keep printing."),
        "cartridgeMissing": ("Cartridge missing", .error, "Put the cartridge back in and close the door."),
        "jam": ("Paper jam", .error, "Open the doors the printer shows, gently pull out the jammed paper, and close them."),
    ]

    /// `/cdm/system/v1/status` (ready, inPowerSave, processing…) with the alerts of `/cdm/alert/v1/alerts`; without a system
    /// status, the print status's `printerState`. Information alerts (such as "genuine HP supply") are left out. An error
    /// alert says what's wrong in the status line instead of "Ready".
    public static func parseStatus(system systemJson: String?, print printJson: String?, alerts alertsJson: String?) -> PrinterStatus {
        var code = Json.parse(systemJson)?.objectValue.flatMap { str($0, "status") }
        if code == nil, let print = Json.parse(printJson)?.objectValue {
            let state = str(print, "printerState")
            code = state == "idle" ? "ready" : state
        }

        var alerts: [(alert: PrinterAlert, detail: String?)] = []
        for a in Json.parse(alertsJson)?["alerts"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
            let category = str(a, "category") ?? "unknown"
            let known = knownAlerts[category.hasPrefix("jam") ? "jam" : category]
            let severity: Severity?
            switch str(a, "severity")?.lowercased() {
            case "error", "critical", "fatal": severity = .error
            case "warning": severity = .warning
            case "information", "info", "informational": severity = nil
            default: severity = known?.severity ?? .warning
            }
            guard let severity else { continue }
            var text = known?.text ?? LedmStatusText.humanize(category)
            if let color = color(a) { text = "\(text) (\(color))" }
            alerts.append((PrinterAlert(id: category, severity: severity, message: text), known?.detail))
        }

        if code == nil && alerts.isEmpty { return PrinterStatus(code: "unknown", message: "Status not available", severity: .info, alerts: []) }
        let finalCode = code ?? "unknown"
        let severity = alerts.map(\.alert.severity).max() ?? LedmStatusText.severityOf(finalCode)
        let error = alerts.first { $0.alert.severity == .error }
        return PrinterStatus(code: finalCode, message: error?.alert.message ?? LedmStatusText.describe(finalCode), severity: severity,
                             alerts: alerts.map(\.alert), detail: error.map(\.detail) ?? LedmStatusText.explain(finalCode))
    }

    /// The supply colour an alert is about (its data's `seValue` on a `…/colors` pointer), as a word.
    private static func color(_ alert: [String: Json]) -> String? {
        for d in alert["data"]?.arrayValue?.compactMap(\.objectValue) ?? [] {
            guard str(d, "propertyPointer")?.hasSuffix("/colors") == true, let v = d["value"]?.objectValue, let code = str(v, "seValue") else {
                continue
            }
            let name = colorName(code)
            return name.isEmpty ? nil : name
        }
        return nil
    }

    // MARK: JSON helpers

    private static func str(_ e: [String: Json], _ name: String) -> String? {
        switch e[name] {
        case .string(let s)?: s.isEmpty ? nil : s.trimmingCharacters(in: .whitespacesAndNewlines)
        case .number(let n)?: n
        case .bool(let b)?: b ? "true" : "false"
        default: nil
        }
    }

    private static func int(_ e: [String: Json], _ name: String) -> Int? {
        guard let s = str(e, name), let d = Double(s), d > Double(Int32.min), d < Double(Int32.max) else { return nil }
        return Int(d.rounded(.toNearestOrEven))
    }
}
