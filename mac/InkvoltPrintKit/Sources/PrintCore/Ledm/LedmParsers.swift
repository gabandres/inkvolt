import Foundation

public struct LedmEvent: Equatable, Sendable {
    public var category: String
    public var agingStamp: String?
    public var resourceType: String?
    public var resourceUri: String?
}

/// HP LEDM documents (`/DevMgmt/…`, `/EventMgmt/…`) → the app's model.
public enum LedmParsers {
    public static func parseStatus(_ root: XmlElement) -> PrinterStatus {
        let status = root.kid("Status")
        let code = status?.kidValue("StatusCategory") ?? "unknown"
        let message = LedmStatusText.isKnown(code) ? LedmStatusText.describe(code)
            : status?.kidValue("LocString") ?? LedmStatusText.describe(code)

        let alerts = root.all("Alert").map { a -> PrinterAlert in
            let id = a.firstValue("ProductStatusAlertID") ?? "unknown"
            let severity: Severity
            switch (a.firstValue("Severity") ?? "").lowercased() {
            case "error": severity = .error
            case "warning": severity = .warning
            case "info", "informational": severity = .info
            default: severity = LedmStatusText.severityOf(id)
            }
            var text = LedmStatusText.describe(id)
            if let color = a.firstValue("AlertDetailsMarkerColor") { text = "\(text) (\(color))" }
            return PrinterAlert(id: id, severity: severity, message: text)
        }

        let severity = alerts.map(\.severity).max() ?? LedmStatusText.severityOf(code)
        let detail = LedmStatusText.explain(alerts.first { $0.severity == .error }?.id ?? code)
        return PrinterStatus(code: code, message: message, severity: severity, alerts: alerts, detail: detail)
    }

    public static func parseConsumables(_ root: XmlElement, usage: XmlElement? = nil) -> [Consumable] {
        var pagesLeft: [String: Int?] = [:]
        for c in usage?.all("Consumable") ?? [] {
            if let station = c.kidValue("ConsumableStation") { pagesLeft[station] = c.kidValue("EstimatedPagesRemaining").asInt }
        }
        return root.kids("ConsumableInfo").map { ci in
            let label = ci.kidValue("ConsumableLabelCode")
            let kind = ci.kidValue("ConsumableTypeEnum") ?? "supply"
            let station = ci.kidValue("ConsumableStation")
            return Consumable(
                name: "\(colorName(label)) \(kind)".trimmingCharacters(in: .whitespaces),
                kind: kind,
                colorCode: label,
                percentRemaining: ci.kidValue("ConsumablePercentageLevelRemaining").asInt,
                state: ci.kid("ConsumableLifeState")?.kidValue("ConsumableState") ?? "unknown",
                productNumber: ci.kidValue("ProductNumber"),
                selectibilityNumber: ci.kidValue("ConsumableSelectibilityNumber"),
                lowThreshold: ci.kidValue("ConsumableLowThreshold").asInt,
                estimatedPagesRemaining: station.flatMap { pagesLeft[$0] ?? nil },
                installed: isoDate(ci.kid("Installation")?.kidValue("Date")))
        }
    }

    public static func parseProductConfig(_ root: XmlElement) -> ProductInfo {
        let info = root.kid("ProductInformation") ?? root
        let adminPasswordSet: Bool?
        switch info.kidValue("PasswordStatus") {
        case "set": adminPasswordSet = true
        case "notSet": adminPasswordSet = false
        default: adminPasswordSet = nil
        }
        return ProductInfo(
            makeAndModel: info.kidValue("MakeAndModel") ?? "Unknown printer",
            family: info.kidValue("MakeAndModelFamily"),
            serialNumber: info.kidValue("SerialNumber"),
            productNumber: info.kidValue("ProductNumber"),
            uuid: info.kidValue("UUID"),
            firmwareDate: info.kid("Version")?.kidValue("Date"),
            adminPasswordSet: adminPasswordSet,
            firmwareRevision: info.kid("Version")?.kidValue("Revision"))
    }

    public static func parseUsage(_ root: XmlElement) -> UsageCounters {
        let printer = root.kid("PrinterSubunit")
        let scanner = root.kid("ScannerEngineSubunit")
        return UsageCounters(
            totalImpressions: printer?.kidValue("TotalImpressions").asInt,
            duplexSheets: printer?.kidValue("DuplexSheets").asInt,
            jamEvents: printer?.kidValue("JamEvents").asInt,
            mispickEvents: printer?.kidValue("MispickEvents").asInt,
            scanImages: scanner.map { $0.children.reduce(0) { $0 + ($1.value.asInt ?? 0) } })
    }

    public static func parseEventTable(_ root: XmlElement) -> [LedmEvent] {
        root.kids("Event").map { e in
            LedmEvent(category: e.kidValue("UnqualifiedEventCategory") ?? "unknown", agingStamp: e.kidValue("AgingStamp"),
                      resourceType: e.kid("Payload")?.kidValue("ResourceType"), resourceUri: e.kid("Payload")?.kidValue("ResourceURI"))
        }
    }

    static func colorName(_ code: String?) -> String {
        switch code {
        case "K": "Black"
        case "C": "Cyan"
        case "M": "Magenta"
        case "Y": "Yellow"
        case "CMY": "Tri-color"
        case nil: ""
        case let other?: other
        }
    }

    /// "2025-01-15" as a date; nil for anything else.
    static func isoDate(_ text: String?) -> DateComponents? {
        guard let parts = text?.split(separator: "-"), parts.count == 3, parts[0].count == 4,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]), isValidDate(y, m, d) else { return nil }
        return DateComponents(year: y, month: m, day: d)
    }

    static func isValidDate(_ y: Int, _ m: Int, _ d: Int) -> Bool {
        guard (1...12).contains(m), d >= 1 else { return false }
        let leap = y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1]
        return d <= days
    }
}
