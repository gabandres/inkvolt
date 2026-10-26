import Foundation

/// A printer's IPP interface: Get-Printer-Attributes for status and supplies, Identify-Printer.
public final class IppClient: Sendable {
    public static let statusAttributes = [
        "printer-state", "printer-state-reasons", "printer-state-message", "printer-make-and-model", "printer-uuid",
        "printer-info", "marker-names", "marker-levels", "marker-low-levels", "marker-high-levels", "marker-types", "marker-colors",
        "document-format-supported", "printer-firmware-name", "printer-firmware-string-version",
        "printer-alert", "printer-alert-description", "printer-location", "printer-more-info", "printer-icons",
    ]

    private let http: DeviceHttp

    /// http(s) URL of the printer object, e.g. `http://host:631/ipp/print` (IPPS: https).
    public let endpoint: URL

    public init(_ http: DeviceHttp, endpoint: URL) {
        self.http = http
        self.endpoint = endpoint
    }

    /// IPP Everywhere's printer object on the host: `http://host:631/ipp/print`.
    public static func defaultEndpoint(_ http: DeviceHttp) -> URL {
        var c = URLComponents(url: http.httpBase, resolvingAgainstBaseURL: false)!
        c.port = 631
        c.path = "/ipp/print"
        return c.url!
    }

    /// The `printer-uri` operation attribute: `ipp://` (or `ipps://`) for the endpoint's host, port and path.
    public var printerUri: String {
        var c = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        c.scheme = endpoint.scheme == "https" ? "ipps" : "ipp"
        if c.port == nil { c.port = endpoint.scheme == "https" ? 443 : 80 }
        return c.url!.absoluteString
    }

    public func printerAttributes(_ requested: [String]? = nil) async throws -> IppResponse {
        try await post(IppCodec.encodeGetPrinterAttributes(printerUri, requested ?? Self.statusAttributes), timeout: .seconds(5))
    }

    /// PWG 5100.13 Identify-Printer: the printer flashes, beeps or shows a message so it can be found. Sent once, never
    /// retried; the caller reads the IPP status (a printer may want a signed-in user for it, §4.1).
    public func identifyPrinter(actions: [String], userName: String?) async throws -> IppResponse {
        try await post(IppCodec.encodeIdentifyPrinter(printerUri, userName: userName, actions: actions), timeout: .seconds(10), once: true)
    }

    private func post(_ body: [UInt8], timeout: Duration, once: Bool = false) async throws -> IppResponse {
        let request = HttpRequest("POST", endpoint, headers: ["Content-Type": "application/ipp"], body: body, timeout: timeout, once: once)
        let response = try await http.send(request)
        try DeviceHttp.ensureSuccess(response, "POST", endpoint)
        return try IppCodec.decode(response.body)
    }

    /// Status from `printer-state` and `printer-state-reasons`, plus `printer-alert` entries (PWG 5100.9) that no reason
    /// covers. Alerts matching a reason lend it their `printer-alert-description`s (the printer's own words, e.g. which
    /// colors are low), joined when several map to the same reason, and their severity when it is higher. Placeholder
    /// reasons ("none", "other") and change events are not problems.
    public static func toStatus(_ r: IppResponse) -> PrinterStatus {
        var alerts: [PrinterAlert] = []
        for x in r.strs("printer-state-reasons") {
            let (id, severity) = splitReason(x)
            if id == "none" || id == "other" || alerts.contains(where: { $0.id == id }) { continue }
            alerts.append(PrinterAlert(id: id, severity: severity, message: IppStatusText.describe(id)))
        }
        let descriptions = r.strs("printer-alert-description")
        var texts: [String: [String]] = [:] // reason id → the printer's descriptions
        for (i, value) in r.strs("printer-alert").enumerated() {
            guard let alert = IppAlert.parse(value) else { continue }
            let severity: Severity? = alert.severity == "critical" ? .error : alert.severity == "warning" ? .warning : nil
            guard let severity, alert.code != "other" else { continue } // "other", "warningBinaryChangeEvent": nothing to fix
            let id = IppStatusText.reasonForAlert(alert.code) ?? alert.code
            if let existing = alerts.firstIndex(where: { $0.id == id }) {
                if severity > alerts[existing].severity { alerts[existing].severity = severity }
            } else {
                alerts.append(PrinterAlert(id: id, severity: severity, message: IppStatusText.describe(id)))
            }
            if i < descriptions.count {
                let d = descriptions[i].trimmingCharacters(in: .whitespacesAndNewlines)
                if !d.isEmpty {
                    var list = texts[id] ?? []
                    if !list.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) { list.append(d) }
                    texts[id] = list
                }
            }
        }
        for a in alerts.indices {
            if let list = texts[alerts[a].id] {
                alerts[a].message = list.map { $0.hasSuffix(".") || $0.hasSuffix("!") ? $0 : $0 + "." }.joined(separator: " ")
            }
        }
        let (code, label): (String, String)
        switch r.int("printer-state") {
        case 3: (code, label) = ("ready", "Ready")
        case 4: (code, label) = ("processing", "Printing")
        case 5: (code, label) = ("stopped", "Stopped")
        default: (code, label) = ("unknown", "Unknown")
        }
        let severity = alerts.map(\.severity).max() ?? (code == "stopped" ? .error : .info)
        let detail = alerts.filter { $0.severity == severity }.lazy.compactMap { IppStatusText.explain($0.id) }.first
        return PrinterStatus(code: code, message: headline(r.str("printer-state-message"), label), severity: severity, alerts: alerts,
                             detail: detail)
    }

    /// The status line: the printer's `printer-state-message` when it says something, else the state in the app's words.
    /// A message that only restates the state ("Idle.", "Ready", "Printing") reads as the app's label, so every brand says
    /// "Ready" as HP does; a one-sentence message loses its final period, like the app's other headlines.
    public static func headline(_ message: String?, _ label: String) -> String {
        var m = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if m.hasSuffix("."), m.firstIndex(of: ".") == m.index(before: m.endIndex) {
            m = String(m.dropLast())
            while m.last?.isWhitespace == true { m.removeLast() }
        }
        return m.isEmpty || genericStates.contains(m.lowercased()) ? label : m
    }

    private static let genericStates: Set<String> = [
        "idle", "ready", "ready to print", "online", "printer is idle", "printing", "processing", "stopped", "none",
    ]

    private static let suffixes: [(suffix: String, severity: Severity)] = [("-error", .error), ("-warning", .warning), ("-report", .info)]

    static func splitReason(_ x: String) -> (id: String, severity: Severity) {
        for (suffix, severity) in suffixes where x.count > suffix.count && x.hasSuffix(suffix) {
            return (String(x.dropLast(suffix.count)), severity)
        }
        return (x, IppStatusText.defaultSeverity(x)) // RFC 8011 §5.4.12: no suffix is an error (but "low" is a warning)
    }

    /// Supplies from PWG 5100.13's parallel `marker-*` lists. Levels: 0-100 percent, -1 unavailable, -2 unknown, -3 "some
    /// left". Waste boxes (`waste-ink`, `waste-toner`…) report how full they are on some printers and how much room is left
    /// on others (CUPS turns one into the other), so they get no percentage: their state comes from the `marker-waste-*`
    /// reasons.
    public static func toConsumables(_ r: IppResponse) -> [Consumable] {
        let levels = r.ints("marker-levels")
        let lows = r.ints("marker-low-levels")
        let types = r.strs("marker-types")
        let colors = r.strs("marker-colors")
        let waste = r.strs("printer-state-reasons").map { splitReason($0).id }.filter { $0.hasPrefix("marker-waste") }
        let wasteState = waste.contains { !$0.hasSuffix("almost-full") && $0.hasSuffix("-full") } ? "full"
            : waste.contains { $0.hasSuffix("almost-full") } ? "almostFull" : "ok"
        return r.strs("marker-names").enumerated().map { i, name in
            let kind = i < types.count ? types[i] : "supply"
            let color = i < colors.count ? colorCode(colors[i]) : nil
            if Consumable.isWasteKind(kind) {
                return Consumable(name: name, kind: kind, colorCode: color, percentRemaining: nil, state: wasteState)
            }
            let raw = i < levels.count ? levels[i] : -2
            let level = raw >= 0 ? min(raw, 100) : nil
            let low = i < lows.count && lows[i] >= 0 ? lows[i] : nil
            let state: String
            if raw == -3 {
                state = "ok"
            } else if let level {
                state = level == 0 ? "out" : low.map { level <= $0 } == true ? "low" : "ok"
            } else {
                state = "unknown"
            }
            return Consumable(name: name, kind: kind, colorCode: color, percentRemaining: level, state: state, lowThreshold: low)
        }
    }

    /// `marker-colors` value (`#RRGGBB`, several for a multi-color cartridge, or `none`) → K/C/M/Y for the process colors,
    /// `#RRGGBB` for others (the first color of a multi-color cartridge), nil when there is no color.
    public static func colorCode(_ value: String) -> String? {
        let chars = Array(value)
        guard chars.count >= 7, chars[0] == "#", chars[1...6].allSatisfy(\.isHexDigit) else { return nil }
        let hex = String(chars[0...6]).uppercased()
        if chars.count > 7 { return hex } // a multi-color cartridge: not one of the process colors
        switch hex {
        case "#000000": return "K"
        case "#00FFFF": return "C"
        case "#FF00FF": return "M"
        case "#FFFF00": return "Y"
        default: return hex
        }
    }
}
