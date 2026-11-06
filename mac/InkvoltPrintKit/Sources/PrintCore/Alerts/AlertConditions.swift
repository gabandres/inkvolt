import Foundation

/// What an alert is about. Supplies and waste boxes come from the supplies; `firmwareChanged` from the firmware watch (news,
/// not a problem: it never colors the menu bar icon); the rest from the printer's status. The raw values are the remembered
/// keys' first part, the same as the Windows app's.
public enum AlertKind: String, CaseIterable, Comparable, Sendable {
    case supplyLow = "SupplyLow", supplyEmpty = "SupplyEmpty", wasteAlmostFull = "WasteAlmostFull", wasteFull = "WasteFull"
    case paperJam = "PaperJam", paperOut = "PaperOut", coverOpen = "CoverOpen", error = "Error", offline = "Offline"
    case firmwareChanged = "FirmwareChanged"
    /// Your own print job (`AlertTracker.observeJobs`): never the menu bar icon's color.
    case jobFailed = "JobFailed", jobStuck = "JobStuck"

    public static func < (a: AlertKind, b: AlertKind) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }
}

/// The menu bar icon's state, in rank order: an error outranks a low supply, which outranks a printer that's off.
public enum AlertLevel: Int, Comparable, Sendable {
    case ok, offline, warning, error

    public static func < (a: AlertLevel, b: AlertLevel) -> Bool { a.rawValue < b.rawValue }
}

/// One printer as last read: reachable or not, its status (nil when the reply was unusable, e.g. the printer was waking up)
/// and its supplies (nil when unknown). Unknown parts keep what was known before; they never count as "the problem is gone".
public struct PrinterSnapshot: Sendable {
    public var uuid: String
    public var name: String
    public var reachable: Bool
    public var status: PrinterStatus?
    public var supplies: [Consumable]?
    /// The printer's last firmware change while its notice shows (`FirmwareWatch.notice`): alerted once.
    public var firmwareChange: FirmwareChange?
    /// Days left per supply (`SupplyRow.keyOf(_:)`) where the history can tell: the low-supply alert names them.
    public var daysLeft: [String: Int]?

    public init(uuid: String, name: String, reachable: Bool, status: PrinterStatus?, supplies: [Consumable]?, firmwareChange: FirmwareChange? = nil,
                daysLeft: [String: Int]? = nil) {
        self.uuid = uuid
        self.name = name
        self.reachable = reachable
        self.status = status
        self.supplies = supplies
        self.firmwareChange = firmwareChange
        self.daysLeft = daysLeft
    }
}

/// A problem seen on a printer. `key` is stable while it lasts ("SupplyLow|Black toner|K").
public struct AlertCondition: Equatable, Sendable {
    public var key: String
    public var kind: AlertKind
    public var title: String
    public var body: String

    public var level: AlertLevel { Self.level(of: kind) }

    public static func level(of kind: AlertKind) -> AlertLevel {
        switch kind {
        case .supplyLow, .wasteAlmostFull, .jobStuck: .warning
        case .offline: .offline
        case .firmwareChanged: .ok
        default: .error
        }
    }

    /// The kind a key was made for, or nil for a key this version doesn't know.
    public static func kind(of key: String) -> AlertKind? {
        AlertKind(rawValue: String(key.split(separator: "|", omittingEmptySubsequences: false).first ?? ""))
    }

    /// Kinds read from the supplies (unknown while the supplies are).
    public static func isSupply(_ kind: AlertKind) -> Bool { [.supplyLow, .supplyEmpty, .wasteAlmostFull, .wasteFull].contains(kind) }
}

/// Turns a `PrinterSnapshot` into the problems worth telling someone about: supplies at or under the threshold or empty,
/// waste boxes almost full or full, paper jams, no paper, open covers, other printer errors, and the printer not answering.
/// Warnings the printer itself raises (paper low, toner low by its own measure) aren't alerts; supply levels come from the
/// supplies, never from status reasons, so one empty cartridge is one alert. The scanner's document feeder only matters
/// while someone is scanning, so it's left out.
public enum AlertConditions {
    /// - Parameter isActive: whether a key is already an ongoing alert: a low supply then stays low until it is
    ///   `AlertRules.hysteresis` points above the threshold, so a level wobbling around it alerts once.
    public static func find(_ snap: PrinterSnapshot, _ rules: AlertRules, isActive: (String) -> Bool) -> [AlertCondition] {
        var found: [AlertCondition] = []
        if !snap.reachable {
            found.append(AlertCondition(key: "Offline", kind: .offline, title: loc("{0} is offline", snap.name),
                                        body: loc("Inkvolt Print can't reach it. It may be turned off, asleep or off the network.")))
            return found
        }
        if let status = snap.status { addStatus(&found, snap.name, status) }
        for s in snap.supplies ?? [] { addSupply(&found, snap.name, s, rules, isActive, snap.daysLeft) }
        if let fw = snap.firmwareChange {
            found.append(AlertCondition(key: "\(AlertKind.firmwareChanged.rawValue)|\(fw.key)", kind: .firmwareChanged, title: loc("{0}: firmware changed", snap.name),
                                        body: loc("{0} If it came from HP, cartridges with non-HP chips may stop working; Inkvolt Print can turn automatic updates off.", fw.text)))
        }
        return found
    }

    private static func addStatus(_ found: inout [AlertCondition], _ printer: String, _ status: PrinterStatus) {
        var problems = status.alerts.filter { $0.severity == .error }.map { (id: $0.id, message: $0.message) }
        // The status code says the same as its error alerts (IPP "stopped" because of "media-jam"); alone, it counts.
        if problems.isEmpty && status.severity == .error && !status.isUnavailable && !["offline", "ready", "idle", "inPowerSave"].contains(status.code) {
            problems.append((status.code, status.message))
        }
        for (rawId, message) in problems {
            let id = reason(rawId)
            if id.lowercased().hasPrefix("scanner") || isSupplyReason(id) { continue }
            let (kind, title, body) = classify(id, message, printer)
            let key = kind == .error ? "Error|\(id)" : kind.rawValue
            if !found.contains(where: { $0.key == key }) { found.append(AlertCondition(key: key, kind: kind, title: title, body: body)) }
        }
    }

    /// IPP reasons may carry a -error / -warning / -report suffix (RFC 8011 §5.4.12).
    private static func reason(_ id: String) -> String {
        for suffix in ["-error", "-warning", "-report"] where id.lowercased().hasSuffix(suffix) { return String(id.dropLast(suffix.count)) }
        return id
    }

    private static func has(_ id: String, _ part: String) -> Bool { id.range(of: part, options: .caseInsensitive) != nil }

    /// Supply levels and waste boxes (LEDM cartridge*, IPP toner-*, marker-*): read from the supplies instead.
    private static func isSupplyReason(_ id: String) -> Bool {
        if has(id, "waste") { return true }
        let supply = has(id, "toner") || has(id, "marker") || has(id, "cartridge") || has(id, "developer") || has(id, "ink")
        return supply && (has(id, "low") || has(id, "empty") || id.lowercased().hasSuffix("out"))
    }

    private static func classify(_ id: String, _ message: String, _ printer: String) -> (AlertKind, String, String) {
        if has(id, "jam") { return (.paperJam, loc("Paper jam"), loc("{0}: clear the jam to keep printing.", printer)) }
        if ["media-empty", "media-needed", "trayEmptyOrOpen", "mediaPrompt", "input-tray-missing"].contains(id) {
            return (.paperOut, message, loc("{0}: load paper to keep printing.", printer))
        }
        if has(id, "cover") || has(id, "door") || id == "interlock-open" { return (.coverOpen, message, loc("{0}: close it to keep printing.", printer)) }
        return (.error, message, loc("{0}: check the printer.", printer))
    }

    private static func addSupply(_ found: inout [AlertCondition], _ printer: String, _ s: Consumable, _ rules: AlertRules,
                                  _ isActive: (String) -> Bool, _ daysLeft: [String: Int]?) {
        let detail = "\(s.name)|\(s.colorCode ?? "")"
        let name = SupplyNames.display(s.name)
        if s.isWaste {
            let full = s.state == "full"
            if full {
                found.append(AlertCondition(key: "WasteFull|\(detail)", kind: .wasteFull, title: loc("{0} full", name),
                                            body: loc("{0}: replace it to keep printing.", printer)))
            }
            if full || s.state == "almostFull" {
                found.append(AlertCondition(key: "WasteAlmostFull|\(detail)", kind: .wasteAlmostFull, title: loc("{0} almost full", name),
                                            body: loc("{0}: replace it soon.", printer)))
            }
            return
        }
        let lowKey = "SupplyLow|\(detail)"
        let empty = s.state == "out" || (s.percentRemaining.map { $0 <= 0 } ?? false)
        let low: Bool
        if empty {
            low = true
        } else if let p = s.percentRemaining {
            low = p <= rules.lowPercent + (isActive(lowKey) ? rules.hysteresis : 0)
        } else {
            low = s.state == "low" || s.state == "veryLow"
        }
        if empty {
            found.append(AlertCondition(key: "SupplyEmpty|\(detail)", kind: .supplyEmpty, title: loc("{0} empty", name),
                                        body: loc("{0}: replace it to keep printing.", printer)))
        }
        guard low else { return }
        var left = s.estimatedPagesRemaining.flatMap { $0 > 0 ? loc("about {0} pages left", CoreLanguage.number($0)) : nil }
        if let days = daysLeft?[SupplyRow.keyOf(s)] {
            let n = CoreLanguage.number(days)
            if let pages = left {
                left = days == 1 ? loc("{1}, about {0} day at this rate", n, pages) : loc("{1}, about {0} days at this rate", n, pages)
            } else {
                left = days == 1 ? loc("about {0} day left at this rate", n) : loc("about {0} days left at this rate", n)
            }
        }
        let part = partNumber(s).map { loc("Replacement: {0}.", $0) }
        let body = loc("{0}: {1}.", printer, left ?? loc("running low")) + (part.map { " \($0)" } ?? "")
        let title = s.percentRemaining.map { loc("{0} low ({1}%)", name, $0) } ?? loc("{0} low", name)
        found.append(AlertCondition(key: lowKey, kind: .supplyLow, title: title, body: body))
    }

    /// The cartridge number the supplies card already shows (HP's selectability number, then the product number).
    private static func partNumber(_ s: Consumable) -> String? {
        let parts = [s.selectibilityNumber.map { "HP \($0)" }, s.productNumber].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
