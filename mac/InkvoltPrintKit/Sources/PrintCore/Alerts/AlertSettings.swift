import Foundation

/// The menu bar item and its alerts, as the user set them (the Windows app's `TraySettings`). Saved in the state file; every
/// field optional there, so an older or newer file still loads. The Mac's menu bar item is on by default (1.0 shipped
/// with it), where the Windows tray icon starts off.
public struct AlertSettings: Equatable, Sendable, Codable {
    /// Show the menu bar item, and keep running there when the window is closed.
    public var menuBar = true
    public var alerts = true
    public var lowPercent = 15
    public var offlineAlerts = true
    public var quietHours = false
    /// Quiet hours, whole hours of the local clock (22 → 7).
    public var quietFrom = 22
    public var quietTo = 7
    public var pausedUntil: Date?

    public static let lowChoices = [5, 10, 15, 20, 25, 30, 40, 50]

    public init() {}

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AlertSettings()
        menuBar = try c.decodeIfPresent(Bool.self, forKey: .menuBar) ?? d.menuBar
        alerts = try c.decodeIfPresent(Bool.self, forKey: .alerts) ?? d.alerts
        lowPercent = try c.decodeIfPresent(Int.self, forKey: .lowPercent) ?? d.lowPercent
        offlineAlerts = try c.decodeIfPresent(Bool.self, forKey: .offlineAlerts) ?? d.offlineAlerts
        quietHours = try c.decodeIfPresent(Bool.self, forKey: .quietHours) ?? d.quietHours
        quietFrom = try c.decodeIfPresent(Int.self, forKey: .quietFrom) ?? d.quietFrom
        quietTo = try c.decodeIfPresent(Int.self, forKey: .quietTo) ?? d.quietTo
        pausedUntil = try c.decodeIfPresent(Date.self, forKey: .pausedUntil)
        repair()
    }

    /// Hand-edited or older files: values back in range.
    public mutating func repair() {
        if !Self.lowChoices.contains(lowPercent) { lowPercent = 15 }
        if !(0...23).contains(quietFrom) { quietFrom = 22 }
        if !(0...23).contains(quietTo) { quietTo = 7 }
    }

    /// The alert tracker's rules from these settings.
    public var rules: AlertRules {
        var r = AlertRules()
        r.enabled = menuBar && alerts
        r.lowPercent = lowPercent
        r.offline = offlineAlerts
        r.quiet = quietHours ? QuietHours(from: (quietFrom, 0), to: (quietTo, 0)) : nil
        return r
    }

    /// Alerts are paused now.
    public func isPaused(now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }

    /// "Until tomorrow morning": 8:00 the next day, on this Mac's clock.
    public static func tomorrowMorning(after now: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? today.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow.addingTimeInterval(8 * 3600)
    }

    /// "Alerts are paused until 14:30." (with "tomorrow" when it's another day), or nil when they aren't.
    public func pauseText(now: Date, calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let until = pausedUntil, until > now else { return nil }
        let time = until.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: calendar, timeZone: calendar.timeZone))
        return "Alerts are paused until \(time)\(calendar.isDate(until, inSameDayAs: now) ? "" : " tomorrow")."
    }
}
