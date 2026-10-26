import Foundation

/// Quiet hours, local clock, in minutes after midnight; may cross midnight (22:00–07:00). From == to is an empty range.
public struct QuietHours: Equatable, Sendable, Codable {
    public var from: Int
    public var to: Int

    public init(from: (hour: Int, minute: Int), to: (hour: Int, minute: Int)) {
        self.from = from.hour * 60 + from.minute
        self.to = to.hour * 60 + to.minute
    }

    public func contains(minuteOfDay t: Int) -> Bool { from <= to ? t >= from && t < to : t >= from || t < to }
}

/// Alert settings and timing.
public struct AlertRules: Equatable, Sendable {
    /// Show alerts at all (off: the menu bar icon still shows each printer's state).
    public var enabled = true

    /// A supply at or under this percentage is low.
    public var lowPercent = 15

    /// A low supply stays low until it is this many points above `lowPercent`.
    public var hysteresis = 5

    /// Alert when a printer stops answering.
    public var offline = true

    public var quiet: QuietHours?

    /// A jam, open cover or empty tray must last this long: someone at the printer is fixing it already.
    public var errorHold: TimeInterval = 60

    /// A printer must stay unreachable this long (sleep, Wi-Fi hiccups, a restart).
    public var offlineHold: TimeInterval = 15 * 60

    /// A problem must be gone this long to count as over; if it comes back sooner it's the same one, no new alert.
    public var clearHold: TimeInterval = 10 * 60

    /// A longer gap between two checks (the Mac slept) starts the holds again.
    public var maxGap: TimeInterval = 2 * 3600

    public init() {}

    public func hold(for kind: AlertKind) -> TimeInterval {
        AlertCondition.isSupply(kind) ? 0 : kind == .offline ? offlineHold : errorHold
    }
}

/// An alert to show now. `uuid` picks the printer to open when it's clicked.
public struct AlertNotice: Equatable, Sendable {
    public var uuid: String
    public var printerName: String
    public var kind: AlertKind
    public var title: String
    public var body: String

    public var level: AlertLevel { AlertCondition.level(of: kind) }
}

/// The alert rules as a state machine, one per app: fed each printer's latest `PrinterSnapshot`, it says which alerts to show
/// now. Alerts fire on transitions only: a problem is told once while it lasts, after its hold time (`AlertRules.hold`), and
/// only again once it has been gone for `AlertRules.clearHold` and comes back (so a flapping cover or a level wobbling around
/// the threshold alerts once). Quiet hours hold alerts until they end (`release`), dropping those that cleared meanwhile; a
/// pause or alerts turned off drop them. Alerts already shown are remembered across restarts (`shown`), so starting at login
/// doesn't repeat yesterday's low toner. Pure: the caller supplies the time.
public final class AlertTracker {
    private final class Track {
        let kind: AlertKind
        var condition: AlertCondition?
        var firstSeen = Date.distantPast
        var absentSince: Date?
        var seen = false, confirmed = false, notified = false

        init(_ kind: AlertKind) { self.kind = kind }

        var present: Bool { seen && absentSince == nil }
        var due: Bool { present && confirmed && !notified }
    }

    private final class Printer {
        var name = ""
        var lastObserved: Date?
        var tracks: [String: Track] = [:]
        /// Keys in the order they were first tracked (a dictionary has none), so notices come out in a stable order.
        var order: [String] = []

        func track(_ key: String, _ kind: AlertKind) -> Track {
            if let t = tracks[key] { return t }
            let t = Track(kind)
            tracks[key] = t
            order.append(key)
            return t
        }

        func remove(_ key: String) {
            tracks[key] = nil
            order.removeAll { $0 == key }
        }
    }

    private var printers: [String: Printer] = [:]
    private var printerOrder: [String] = []
    private let timeZone: TimeZone

    public var rules: AlertRules

    /// "Pause alerts": nothing is shown until then, and what came up meanwhile isn't shown later.
    public var pausedUntil: Date?

    /// - Parameters:
    ///   - shown: keys of alerts already shown, per printer (`shown()` from the last run).
    ///   - timeZone: the local clock quiet hours are read on.
    public init(rules: AlertRules, shown: [String: [String]] = [:], timeZone: TimeZone = .current) {
        self.rules = rules
        self.timeZone = timeZone
        for (uuid, keys) in shown.sorted(by: { $0.key < $1.key }) {
            for key in keys {
                guard let kind = AlertCondition.kind(of: key) else { continue }
                let t = printer(uuid).track(key, kind)
                t.notified = true
                t.confirmed = true
            }
        }
    }

    private func printer(_ uuid: String) -> Printer {
        let key = uuid.lowercased()
        if let p = printers[key] { return p }
        let p = Printer()
        printers[key] = p
        printerOrder.append(key)
        return p
    }

    /// Takes in one printer's latest state; returns the alerts to show now.
    public func observe(_ snap: PrinterSnapshot, now: Date) -> [AlertNotice] {
        let p = printer(snap.uuid)
        p.name = snap.name
        if let last = p.lastObserved, now.timeIntervalSince(last) > rules.maxGap {
            for t in p.tracks.values where !t.confirmed { t.seen = false } // its hold starts again below
        }
        p.lastObserved = now

        let found = AlertConditions.find(snap, rules) { key in p.tracks[key].map { $0.present && $0.confirmed } ?? false }
        for c in found {
            let t = p.track(c.key, c.kind)
            if !t.seen { t.firstSeen = now }
            t.seen = true
            t.absentSince = nil
            t.condition = c
            if now.timeIntervalSince(t.firstSeen) >= rules.hold(for: c.kind) { t.confirmed = true }
        }
        for key in p.order where !found.contains(where: { $0.key == key }) {
            guard let t = p.tracks[key] else { continue }
            if !Self.observable(t.kind, snap) {
                // Can't be seen now (printer off, unusable reply): a problem still within its hold is dropped, since its hold
                // can't run out unseen (and must not keep asking for a check); a confirmed one stands as known.
                if !t.confirmed { p.remove(key) }
                continue
            }
            if !t.seen && !t.notified {
                p.remove(key)
                continue
            }
            if t.absentSince == nil { t.absentSince = now }
            if now.timeIntervalSince(t.absentSince!) >= rules.clearHold || !t.confirmed { p.remove(key) }
        }
        return release(now: now)
    }

    /// Whether a snapshot shows this kind of problem at all (else what was known stands).
    private static func observable(_ kind: AlertKind, _ snap: PrinterSnapshot) -> Bool {
        kind == .offline || (snap.reachable && (AlertCondition.isSupply(kind) ? snap.supplies != nil : snap.status != nil))
    }

    /// Alerts due and not shown yet: called after each check and on a timer (quiet hours ending).
    public func release(now: Date) -> [AlertNotice] {
        var due: [(uuid: String, name: String, track: Track)] = []
        for uuid in printerOrder {
            guard let p = printers[uuid] else { continue }
            for key in p.order { if let t = p.tracks[key], t.due { due.append((uuid, p.name, t)) } }
        }
        if due.isEmpty { return [] }
        let silent = !rules.enabled || (pausedUntil.map { $0 > now } ?? false)
        if !silent, let quiet = rules.quiet, quiet.contains(minuteOfDay: minuteOfDay(now)) { return [] } // held till morning
        var notices: [AlertNotice] = []
        for (uuid, name, t) in due {
            t.notified = true
            if silent || (t.kind == .offline && !rules.offline) || outranked(uuid, t) { continue }
            notices.append(AlertNotice(uuid: uuid, printerName: name, kind: t.kind, title: t.condition!.title, body: t.condition!.body))
        }
        return notices
    }

    private func minuteOfDay(_ date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0) * 60 + (c.minute ?? 0)
    }

    /// An empty cartridge is also low, a full waste box also almost full: tell the worse one only.
    private func outranked(_ uuid: String, _ t: Track) -> Bool {
        let worse: AlertKind?
        switch t.kind {
        case .supplyLow: worse = .supplyEmpty
        case .wasteAlmostFull: worse = .wasteFull
        default: worse = nil
        }
        guard let worse, let key = t.condition?.key, let bar = key.firstIndex(of: "|") else { return false }
        let detail = key[key.index(after: bar)...]
        guard let w = printers[uuid]?.tracks["\(worse.rawValue)|\(detail)"] else { return false }
        return w.present && w.confirmed
    }

    /// When a problem seen but still within its hold time will be due: check again then. Nil: nothing pending.
    public var nextCheck: Date? { printerOrder.compactMap { pendingUntil($0) }.min() }

    /// `nextCheck` for one printer.
    public func pendingUntil(_ uuid: String) -> Date? {
        printers[uuid.lowercased()]?.tracks.values.filter { $0.present && !$0.confirmed }
            .map { $0.firstSeen.addingTimeInterval(rules.hold(for: $0.kind)) }.min()
    }

    /// Problems still within their hold time start it again (the Mac woke up: the time it slept doesn't count).
    public func resetPending() {
        for p in printers.values {
            for key in p.order where p.tracks[key].map({ !$0.confirmed }) ?? false { p.remove(key) }
        }
    }

    /// A printer was removed.
    public func forget(_ uuid: String) {
        printers[uuid.lowercased()] = nil
        printerOrder.removeAll { $0 == uuid.lowercased() }
    }

    private func current(_ uuid: String) -> [Track] { printers[uuid.lowercased()]?.tracks.values.filter { $0.present && $0.confirmed } ?? [] }

    /// A printer's state for the menu bar: its worst ongoing problem.
    public func level(_ uuid: String) -> AlertLevel { current(uuid).map { AlertCondition.level(of: $0.kind) }.max() ?? .ok }

    /// The menu bar icon: the worst printer.
    public var overall: AlertLevel { printerOrder.map(level).max() ?? .ok }

    /// A printer's worst ongoing problem in a few words ("Paper jam", "Offline"), or nil when there's none.
    public func problem(_ uuid: String) -> String? {
        current(uuid).sorted {
            let (a, b) = (AlertCondition.level(of: $0.kind), AlertCondition.level(of: $1.kind))
            return a != b ? a > b : $0.kind < $1.kind
        }.first.map { $0.kind == .offline ? "Offline" : $0.condition!.title }
    }

    /// Keys of the alerts shown that are still going on, per printer: kept across restarts.
    public func shown() -> [String: [String]] {
        var result: [String: [String]] = [:]
        for (uuid, p) in printers {
            let keys = p.tracks.filter { $0.value.notified }.map(\.key).sorted()
            if !keys.isEmpty { result[uuid] = keys }
        }
        return result
    }
}

/// How often the menu bar checks printers while the window is closed: rarely, less on battery or a constrained network,
/// and backing off from a printer that doesn't answer.
public enum AlertPolling {
    public static let normal: TimeInterval = 5 * 60, saving: TimeInterval = 15 * 60, longest: TimeInterval = 60 * 60

    public static func interval(onBattery: Bool, constrained: Bool, failures: Int) -> TimeInterval {
        var interval = onBattery || constrained ? saving : normal
        var i = 0
        while i < failures && interval < longest {
            interval *= 2
            i += 1
        }
        return min(interval, longest)
    }
}

/// One printer's line in the menu bar item's tooltip and menu.
public struct PrinterLine: Equatable, Sendable {
    public var name: String
    public var level: AlertLevel
    public var text: String

    public init(name: String, level: AlertLevel, text: String) {
        self.name = name
        self.level = level
        self.text = text
    }
}

public enum TrayText {
    /// The Windows tray's tooltip limit, kept so the menu bar's tooltip stays short too.
    public static let maxLength = 127

    /// "Inkvolt Print" then a line per printer, problems first, cut to fit with "+n more".
    public static func tooltip(_ printers: [PrinterLine], paused: Bool) -> String {
        var text = paused ? "Inkvolt Print (alerts paused)" : "Inkvolt Print"
        let lines = printers.enumerated().sorted { $0.element.level != $1.element.level ? $0.element.level > $1.element.level : $0.offset < $1.offset }
            .map { cut("\($0.element.name): \($0.element.text)", 60) }
        for (i, line) in lines.enumerated() {
            let rest = lines.count - i - 1
            let more = rest > 0 ? "\n+\(rest) more" : ""
            if text.count + 1 + line.count + more.count > maxLength { return text + "\n+\(lines.count - i) more" }
            text += "\n" + line
        }
        return text
    }

    private static func cut(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        var head = String(s.prefix(max - 1))
        while head.last?.isWhitespace == true { head.removeLast() }
        return head + "…"
    }
}

extension TrayText {
    /// A printer's line in the menu: the tracker's level, except that a printer not answering right now shows grey at once
    /// (the icon waits for the offline hold); its worst ongoing problem, else its status.
    public static func line(name: String, tracked: AlertLevel, problem: String?, view: PrinterView) -> PrinterLine {
        let notAnswering = view.phase == .offline || view.phase == .elsewhere
        return PrinterLine(name: name, level: max(tracked, notAnswering ? .offline : .ok), text: problem ?? view.statusMessage)
    }

    /// One alert: its own title and text. Several at once: a line each.
    public static func notice(_ notices: [AlertNotice]) -> (title: String, text: String) {
        notices.count == 1 ? (notices[0].title, notices[0].body)
            : ("\(notices.count) printer alerts", notices.map { "\($0.printerName): \($0.title)" }.joined(separator: "\n"))
    }
}
