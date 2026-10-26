import Foundation

/// One row of prtMarkerSuppliesTable (RFC 3805): what it is, how much it holds and how much is left.
public struct SnmpSupply: Equatable, Sendable {
    public var index: Int
    public var supplyClass: Int
    public var type: Int
    public var description: String?
    public var maxCapacity: Int
    public var level: Int
    public var colorantIndex: Int

    public init(_ index: Int, supplyClass: Int, type: Int, description: String?, maxCapacity: Int, level: Int, colorantIndex: Int) {
        self.index = index
        self.supplyClass = supplyClass
        self.type = type
        self.description = description
        self.maxCapacity = maxCapacity
        self.level = level
        self.colorantIndex = colorantIndex
    }

    /// A receptacle that fills up (waste toner or ink), whose level is the room left in it (RFC 3805 prtMarkerSuppliesLevel).
    public var isReceptacle: Bool { supplyClass == PrinterMib.classReceptacle || PrinterMib.supplyKind(type).hasPrefix("waste") }
}

/// One row of prtAlertTable (RFC 3805): severity, which sub-unit (group and its row), the code and the printer's words.
public struct SnmpAlert: Equatable, Sendable {
    public var index: Int
    public var severity: Int
    public var group: Int
    public var groupIndex: Int
    public var code: Int
    public var description: String?

    public init(_ index: Int, severity: Int, group: Int, groupIndex: Int, code: Int, description: String?) {
        self.index = index
        self.severity = severity
        self.group = group
        self.groupIndex = groupIndex
        self.code = code
        self.description = description
    }
}

/// One read of a printer's status objects (Host Resources MIB and Printer MIB), before turning them into plain words.
public struct SnmpReading: Equatable, Sendable {
    public var deviceStatus: Int?
    public var printerStatus: Int?
    public var detectedErrorState: [UInt8]
    public var alerts: [SnmpAlert]
    public var supplies: [SnmpSupply]
    public var colorants: [Int: String]

    public init(deviceStatus: Int?, printerStatus: Int?, detectedErrorState: [UInt8], alerts: [SnmpAlert], supplies: [SnmpSupply],
                colorants: [Int: String]) {
        self.deviceStatus = deviceStatus
        self.printerStatus = printerStatus
        self.detectedErrorState = detectedErrorState
        self.alerts = alerts
        self.supplies = supplies
        self.colorants = colorants
    }
}

/// A printer's SNMP objects as a `PrinterStatus` and `Consumable`s. The overall state follows RFC 3805 §2.2.13.2
/// (hrDeviceStatus with hrPrinterStatus); problems come from prtAlertTable, with the alert codes mapped to IPP's
/// printer-state-reasons as PWG 5100.9 does (so they read and alert like an IPP printer's), and from the
/// hrPrinterDetectedErrorState bits (RFC 2790) that no alert already covers.
public enum SnmpPrinterStatus {
    /// hrPrinterDetectedErrorState bits, numbered from the first byte's most significant bit (RFC 2790).
    private static let errorBits: [(bit: Int, id: String, severity: Severity, message: String)] = [
        (0, "media-low", .warning, "Paper low"),
        (1, "media-empty", .error, "Out of paper"),
        (2, "toner-low", .warning, "Toner low"),
        (3, "toner-empty", .error, "Toner empty"),
        (4, "door-open", .error, "A door is open"),
        (5, "media-jam", .error, "Paper jam"),
        (6, "offline", .error, "The printer is offline"),
        (7, "service-requested", .error, "The printer needs attention"),
        (8, "input-tray-missing", .error, "Paper tray missing"),
        (9, "output-tray-missing", .error, "Output tray missing"),
        (10, "marker-supply-missing", .error, "Cartridge missing"),
        (11, "output-area-almost-full", .warning, "Output tray almost full"),
        (12, "output-area-full", .error, "Output tray full"),
        (13, "input-tray-empty", .warning, "A paper tray is empty"),
        (14, "maintenance-overdue", .warning, "Maintenance is overdue"),
    ]

    /// Reasons that say the same thing, so an error bit doesn't repeat an alert in other words.
    private static let sameProblem: [[String]] = [
        ["toner-low", "marker-supply-low"],
        ["toner-empty", "marker-supply-empty"],
        ["door-open", "cover-open", "interlock-open"],
        ["media-empty", "input-tray-empty"],
        ["marker-supply-missing"],
    ]

    /// Alert codes that report a change, not a problem (cover closed, powered up, media changed, added or removed…).
    private static let events: Set<Int> = [4, 6, 7, 19, 20, 23, 24, 25, 26, 27, 28, 502, 503, 504, 505, 506, 507, 802, 803, 804, 805, 806]

    /// PrtAlertCodeTC other(1) and unknown(2): the printer's description is all that says what the alert is.
    private static let codeOther = 1, codeUnknown = 2

    /// Codes PWG 5100.9 has no printer-alert mapping for that still mean an IPP reason (RFC 3805's newer marker codes, jams).
    private static let moreReasons: [Int: String] = [
        906: "media-jam", 1306: "media-jam", 1312: "media-jam", 1322: "media-jam",
        1116: "marker-supply-missing", 1117: "marker-supply-missing", 1118: "marker-supply-missing",
        1119: "marker-supply-missing", 1120: "marker-supply-missing", 1121: "marker-supply-missing",
        1124: "marker-supply-missing", 1130: "marker-supply-missing",
        1122: "marker-supply-low", 1123: "marker-supply-empty",
        1125: "marker-waste-almost-full", 1126: "marker-waste-full",
        1127: "marker-waste-missing", 1128: "marker-waste-missing", 1129: "marker-waste-missing",
        1302: "output-area-almost-full", 1303: "output-area-full", 1323: "output-area-full",
    ]

    public static func toStatus(_ r: SnmpReading) -> PrinterStatus {
        var alerts: [PrinterAlert] = []
        var texts: [String: [String]] = [:]
        for a in r.alerts {
            guard let x = classify(a, r.supplies) else { continue }
            if let existing = alerts.firstIndex(where: { $0.id == x.id }) {
                if x.severity > alerts[existing].severity { alerts[existing].severity = x.severity }
            } else {
                let message = x.id == "other" || x.id == "unknown" ? "The printer reports a problem" : IppStatusText.describe(x.id)
                alerts.append(PrinterAlert(id: x.id, severity: x.severity, message: message))
            }
            if let d = words(a.description) {
                var list = texts[x.id] ?? []
                if !list.contains(where: { $0.lowercased() == d.lowercased() }) { list.append(d) }
                texts[x.id] = list
            }
        }
        // The printer's own descriptions name the sub-unit ("Black toner low", "Tray 2 empty"): they replace the generic words.
        for i in alerts.indices {
            if let list = texts[alerts[i].id] {
                alerts[i].message = list.map { $0.hasSuffix(".") || $0.hasSuffix("!") ? $0 : $0 + "." }.joined(separator: " ")
            }
        }

        for bit in errorBits {
            if !isSet(r.detectedErrorState, bit.bit) || covered(alerts, bit.id) { continue }
            if bit.id == "service-requested" && !alerts.isEmpty { continue } // set alongside the real problem (a jam, low toner…)
            alerts.append(PrinterAlert(id: bit.id, severity: bit.severity, message: bit.message))
        }

        let offline = isSet(r.detectedErrorState, 6)
        let (code, label) = overallState(r.deviceStatus, r.printerStatus, offline: offline)
        let severityAll = alerts.map(\.severity).max()
            ?? (code == "stopped" ? .error : r.deviceStatus == PrinterMib.deviceWarning ? .warning : .info)
        let top = alerts.first { $0.severity == .error }
        let detail = alerts.filter { $0.severity == severityAll }.lazy.compactMap { IppStatusText.explain($0.id) }.first
        // A stopped printer is best named by what stops it ("Paper jam"), as the spooler's and LEDM's headlines do.
        let message = code == "stopped" && !offline ? top?.message ?? label : label
        return PrinterStatus(code: code, message: message, severity: severityAll, alerts: alerts, detail: detail)
    }

    private static func overallState(_ device: Int?, _ printer: Int?, offline: Bool) -> (String, String) {
        if offline { return ("stopped", "Offline") }
        if printer == PrinterMib.printerPrinting { return ("processing", "Printing") }
        if printer == PrinterMib.printerWarmup { return ("warmingUp", "Warming up") }
        if device == PrinterMib.deviceDown { return ("stopped", "Stopped") }
        if printer == PrinterMib.printerIdle { return ("ready", "Ready") }
        if device == PrinterMib.deviceRunning && printer == PrinterMib.printerOther { return ("inPowerSave", "Sleeping") } // RFC 3805's "Standby"
        if device == PrinterMib.deviceRunning || device == PrinterMib.deviceWarning { return ("ready", "Ready") }
        if device == PrinterMib.deviceTesting { return ("processing", "Testing") }
        return ("unknown", "Unknown")
    }

    /// The supply table as consumables. Levels are a share of the maximum (RFC 3805: -1 other, -2 unknown, -3 "some left";
    /// a maximum of -1, -2 or 0 gives no percentage). Waste boxes report the room left (not how full they are), so they get
    /// no percentage, as with IPP: their state comes from the level (no room: full) and the waste alerts. A supply's alerts
    /// (marker supplies group, its row) make it low, empty or missing.
    public static func toConsumables(_ r: SnmpReading) -> [Consumable] {
        var list: [Consumable] = []
        for s in r.supplies.sorted(by: { $0.index < $1.index }) {
            let reasons = Set(r.alerts.filter { $0.group == PrinterMib.groupMarkerSupplies && $0.groupIndex == s.index }
                .compactMap { classify($0, r.supplies)?.id })
            let name = words(s.description) ?? PrinterMib.supplyName(s.type)
            var kind = PrinterMib.supplyKind(s.type)
            if s.isReceptacle {
                if !kind.hasPrefix("waste") { kind = "waste-" + kind }
                // A waste box the printer calls consumed (class 3) doesn't say its level is the room left: only alerts make it full.
                let full = (s.level == 0 && s.supplyClass != PrinterMib.classConsumed)
                    || reasons.contains { $0.hasSuffix("-full") && !$0.hasSuffix("almost-full") }
                let state = full ? "full" : reasons.contains { $0.hasSuffix("almost-full") } ? "almostFull" : s.level == -2 ? "unknown" : "ok"
                list.append(Consumable(name: name, kind: kind, colorCode: nil, percentRemaining: nil, state: state))
                continue
            }
            // Math.Round's default, to match the Windows app: halves go to the even neighbour.
            let percent = s.level >= 0 && s.maxCapacity > 0
                ? Int((100.0 * Double(min(s.level, s.maxCapacity)) / Double(s.maxCapacity)).rounded(.toNearestOrEven)) : nil
            let state: String
            if reasons.contains("marker-supply-missing") {
                state = "missing"
            } else if !reasons.isDisjoint(with: ["marker-supply-empty", "toner-empty", "opc-life-over"]) || (s.level == 0 && s.maxCapacity > 0) {
                state = "out"
            } else if !reasons.isDisjoint(with: ["marker-supply-low", "toner-low", "opc-near-eol", "developer-low"]) {
                state = "low"
            } else if s.level == -3 || percent != nil {
                state = "ok"
            } else {
                state = "unknown"
            }
            let color = r.colorants[s.colorantIndex].flatMap(colorCode)
            list.append(Consumable(name: name, kind: kind, colorCode: color, percentRemaining: percent, state: state))
        }
        return list
    }

    /// prtMarkerColorantValue ("black", "cyan"…: RFC 3805 names them in lowercase English) → K, C, M, Y; nil for other colors.
    public static func colorCode(_ colorant: String) -> String? {
        switch colorant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "black": "K"
        case "cyan": "C"
        case "magenta": "M"
        case "yellow": "Y"
        default: nil
        }
    }

    /// An alert as an IPP reason with a severity; nil for change events and alerts that need no attention (an "other" or
    /// "unknown" code counts only as a critical or warning alert, named by the printer's description). Codes PWG 5100.9
    /// maps (by their PrtAlertCodeTC label) use its reason; the generic sub-unit codes take the meaning of their group (a
    /// supply, a tray, an output bin). A warning or critical alert with no known meaning is kept under its own label, so
    /// nothing the printer flags is dropped.
    static func classify(_ a: SnmpAlert, _ supplies: [SnmpSupply]) -> (id: String, severity: Severity)? {
        if a.severity == PrinterMib.severityBinaryChangeEvent || events.contains(a.code) { return nil }
        let flagged = a.severity == PrinterMib.severityCritical || a.severity == PrinterMib.severityWarning
        if (a.code == codeOther || a.code == codeUnknown) && !flagged { return nil }
        let label = PrinterMib.alertLabel(a.code)
        let reason = label.flatMap(IppStatusText.reasonForAlert) ?? moreReasons[a.code] ?? fromGroup(a, supplies)
        let severity: Severity?
        switch a.severity {
        case PrinterMib.severityCritical: severity = .error
        case PrinterMib.severityWarning: severity = .warning
        default: severity = reason.map(IppStatusText.defaultSeverity) // severity "other": go by what it is
        }
        guard let severity else { return nil }
        return (reason ?? label ?? "alert-\(a.code)", severity)
    }

    private static func fromGroup(_ a: SnmpAlert, _ supplies: [SnmpSupply]) -> String? {
        switch a.group {
        case PrinterMib.groupMarkerSupplies:
            let supply = supplies.first { $0.index == a.groupIndex }
            let drum = supply?.type == 9
            switch a.code {
            case 9: return supply?.isReceptacle == true ? "marker-waste-missing" : "marker-supply-missing"
            case 10: return drum ? "opc-near-eol" : "marker-supply-low"
            case 11: return drum ? "opc-life-over" : "marker-supply-empty"
            case 12, 16: return "marker-supply-low"
            case 13, 17: return "marker-supply-empty"
            case 14: return "marker-waste-almost-full"
            case 15: return "marker-waste-full"
            default: return nil
            }
        case PrinterMib.groupInput:
            return [9: "input-tray-missing", 12: "media-low", 13: "media-empty", 8: "media-jam"][a.code]
        case PrinterMib.groupOutput:
            return [9: "output-tray-missing", 14: "output-area-almost-full", 15: "output-area-full", 8: "media-jam"][a.code]
        case PrinterMib.groupCover:
            return a.code == 18 ? "cover-open" : nil
        default:
            return nil
        }
    }

    private static func covered(_ alerts: [PrinterAlert], _ id: String) -> Bool {
        alerts.contains { $0.id == id } || sameProblem.contains { group in group.contains(id) && alerts.contains { group.contains($0.id) } }
    }

    static func isSet(_ bits: [UInt8], _ bit: Int) -> Bool { bit / 8 < bits.count && bits[bit / 8] & (0x80 >> UInt8(bit % 8)) != 0 }

    /// The printer's own words when they are words (some printers put only a code like "{13.A3.D2}" there).
    private static func words(_ text: String?) -> String? {
        guard let s = text?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, s.count <= 160,
              s.filter(\.isLetter).count >= 3 else { return nil }
        return s
    }
}
