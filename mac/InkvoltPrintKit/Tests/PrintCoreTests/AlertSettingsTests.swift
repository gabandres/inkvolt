import Foundation
import Testing
@testable import PrintCore

/// The menu bar item's alert settings: what a new install starts with, how they become the tracker's rules, an older or
/// hand-edited state file, and pausing. New for the Mac (the Windows app keeps `TraySettings` in its app project).
struct AlertSettingsTests {
    @Test func aNewInstallHasTheMenuBarItemAndAlertsOn() {
        let s = AlertSettings()
        #expect(s.menuBar && s.alerts && s.offlineAlerts)
        #expect(s.rules.enabled)
        #expect(s.rules.lowPercent == 15)
        #expect(s.rules.quiet == nil)
    }

    @Test func settingsBecomeTheTrackersRules() {
        var s = AlertSettings()
        s.lowPercent = 25
        s.offlineAlerts = false
        s.quietHours = true
        #expect(s.rules.lowPercent == 25)
        #expect(!s.rules.offline)
        #expect(s.rules.quiet == QuietHours(from: (22, 0), to: (7, 0)))
        s.menuBar = false // no menu bar item: no alerts either
        #expect(!s.rules.enabled)
    }

    @Test func anOlderOrHandEditedFileLoadsWithValuesBackInRange() throws {
        let s = try JSONDecoder().decode(AlertSettings.self, from: Data(#"{"lowPercent": 17, "quietFrom": 30, "alerts": false}"#.utf8))
        #expect(s.lowPercent == 15)
        #expect(s.quietFrom == 22)
        #expect(!s.alerts)
        #expect(s.menuBar) // missing: the default
        let state = try JSONDecoder().decode(PrintState.self, from: Data(#"{"printers": []}"#.utf8))
        #expect(state.alertSettings == AlertSettings())
    }

    @Test func pausingUntilTomorrowMorningIsEightOClockTheNextDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Puerto_Rico"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 21, minute: 15)))
        let until = AlertSettings.tomorrowMorning(after: now, calendar: calendar)
        #expect(calendar.dateComponents([.day, .hour, .minute], from: until) == DateComponents(day: 27, hour: 8, minute: 0))

        var s = AlertSettings()
        #expect(s.pauseText(now: now, calendar: calendar) == nil)
        s.pausedUntil = until
        #expect(s.isPaused(now: now))
        #expect(s.pauseText(now: now, calendar: calendar, locale: Locale(identifier: "en_GB"))?.hasSuffix("8:00 tomorrow.") == true)
        #expect(!s.isPaused(now: until.addingTimeInterval(1)))
    }
}
