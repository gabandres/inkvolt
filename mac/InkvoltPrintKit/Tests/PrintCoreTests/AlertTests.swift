import Foundation
import Testing
@testable import PrintCore

/// Alerts: the conditions, the tracker's holds, quiet hours, pause and memory, polling and the menu bar text. Ported from
/// AlertTests.cs; StatusLineTests.cs follows.
struct AlertTests {
    private static let laser = "12345678-1234-4abc-8def-123456789abc", inkjet = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"
    private static let zone = TimeZone(secondsFromGMT: -4 * 3600)!
    /// 2026-10-24 12:00 at UTC-4.
    private static let t0 = Date(timeIntervalSince1970: 1_792_857_600)

    private static func minutes(_ m: Double) -> Date { t0.addingTimeInterval(m * 60) }
    private static func hours(_ h: Double) -> Date { t0.addingTimeInterval(h * 3600) }

    private static func toner(_ percent: Int?, _ state: String = "ok", name: String = "Black toner", part: String? = "W1340A") -> Consumable {
        Consumable(name: name, kind: "toner", colorCode: "K", percentRemaining: percent, state: state, productNumber: part,
                   estimatedPagesRemaining: percent.map { $0 * 15 })
    }

    private static func waste(_ state: String) -> Consumable {
        Consumable(name: "Maintenance box", kind: "wasteInk", colorCode: nil, percentRemaining: nil, state: state)
    }

    private static let ready = PrinterStatus(code: "ready", message: "Ready", severity: .info, alerts: [])

    private static func with(_ alerts: (String, Severity, String)...) -> PrinterStatus {
        PrinterStatus(code: "ready", message: alerts[0].2, severity: alerts.map(\.1).max()!,
                      alerts: alerts.map { PrinterAlert(id: $0.0, severity: $0.1, message: $0.2) })
    }

    private static func seen(_ status: PrinterStatus?, _ supplies: Consumable...) -> PrinterSnapshot {
        PrinterSnapshot(uuid: laser, name: "Office laser", reachable: true, status: status, supplies: supplies)
    }

    private static func unreachable(_ uuid: String = laser) -> PrinterSnapshot {
        PrinterSnapshot(uuid: uuid, name: "Office laser", reachable: false, status: nil, supplies: nil)
    }

    private static func tracker(_ rules: AlertRules = AlertRules()) -> AlertTracker { AlertTracker(rules: rules, timeZone: zone) }

    private static func rules(_ change: (inout AlertRules) -> Void) -> AlertRules {
        var r = AlertRules()
        change(&r)
        return r
    }

    // MARK: Supplies

    @Test func tonerDroppingBelowTheThresholdAlertsOnce() throws {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(40)), now: Self.t0).isEmpty)
        let notices = t.observe(Self.seen(Self.ready, Self.toner(14)), now: Self.minutes(5))
        try #require(notices.count == 1)
        let n = notices[0]
        #expect(n.kind == .supplyLow)
        #expect(n.title == "Black toner low (14%)")
        #expect(n.body.contains("Office laser"))
        #expect(n.body.contains("W1340A")) // the part number the app already shows; no shop link
        #expect(!n.body.contains("http"))
        #expect(t.observe(Self.seen(Self.ready, Self.toner(13)), now: Self.minutes(10)).isEmpty)
        #expect(t.observe(Self.seen(Self.ready, Self.toner(12)), now: Self.hours(5)).isEmpty)
        #expect(t.level(Self.laser) == .warning)
    }

    @Test func thresholdIsConfigurable() {
        let t = Self.tracker(Self.rules { $0.lowPercent = 25 })
        #expect(t.observe(Self.seen(Self.ready, Self.toner(24)), now: Self.t0).count == 1)
        let u = Self.tracker(Self.rules { $0.lowPercent = 10 })
        #expect(u.observe(Self.seen(Self.ready, Self.toner(24)), now: Self.t0).isEmpty)
        #expect(u.level(Self.laser) == .ok)
    }

    @Test func aLevelWobblingAroundTheThresholdAlertsOnlyOnce() {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(15)), now: Self.t0).count == 1)
        for i in 1..<30 {
            #expect(t.observe(Self.seen(Self.ready, Self.toner(i % 2 == 0 ? 15 : 18)), now: Self.minutes(Double(5 * i))).isEmpty)
        }
    }

    @Test func aNewCartridgeClearsTheAlertSoTheNextLowAlertsAgain() {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.t0).count == 1)
        #expect(t.observe(Self.seen(Self.ready, Self.toner(100)), now: Self.minutes(1)).isEmpty)
        #expect(t.observe(Self.seen(Self.ready, Self.toner(100)), now: Self.minutes(20)).isEmpty) // gone for the clear hold: cleared
        #expect(t.level(Self.laser) == .ok)
        #expect(t.observe(Self.seen(Self.ready, Self.toner(9)), now: Self.hours(60 * 24)).count == 1)
    }

    @Test func runningEmptyAfterLowAlertsAgainAndAJumpToEmptyAlertsOnce() {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(5)), now: Self.t0).map(\.kind) == [.supplyLow])
        #expect(t.observe(Self.seen(Self.ready, Self.toner(0, "out")), now: Self.hours(72)).map(\.kind) == [.supplyEmpty])
        #expect(t.level(Self.laser) == .error)

        let u = Self.tracker()
        #expect(u.observe(Self.seen(Self.ready, Self.toner(0)), now: Self.t0).map(\.kind) == [.supplyEmpty])
    }

    @Test func levelsWithoutAPercentageUseThePrintersOwnState() {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(nil, "low")), now: Self.t0).map(\.kind) == [.supplyLow])
        #expect(t.observe(Self.seen(Self.ready, Self.toner(nil, "out")), now: Self.hours(1)).map(\.kind) == [.supplyEmpty])

        let w = Self.tracker()
        #expect(w.observe(Self.seen(Self.ready, Self.waste("almostFull")), now: Self.t0).map(\.kind) == [.wasteAlmostFull])
        #expect(w.observe(Self.seen(Self.ready, Self.waste("almostFull")), now: Self.hours(1)).isEmpty)
        #expect(w.observe(Self.seen(Self.ready, Self.waste("full")), now: Self.hours(2)).map(\.kind) == [.wasteFull])
        #expect(Self.tracker().observe(Self.seen(Self.ready, Self.waste("ok")), now: Self.t0).isEmpty)
    }

    @Test func eachSupplyIsItsOwnAlert() {
        let t = Self.tracker()
        let notices = t.observe(Self.seen(Self.ready, Self.toner(10, name: "Cyan ink"), Self.toner(12, name: "Yellow ink"), Self.toner(80, name: "Black ink")),
                                now: Self.t0)
        #expect(notices.map(\.title).sorted() == ["Cyan ink low (10%)", "Yellow ink low (12%)"])
    }

    // MARK: Printer errors

    @Test func aJamAlertsOnceItHasLastedTheHoldTime() throws {
        let t = Self.tracker()
        let jam = Self.with(("jamInPrinter", .error, "Paper jam"))
        #expect(t.observe(Self.seen(jam), now: Self.t0).isEmpty) // could be the user clearing a jam right now
        #expect(t.level(Self.laser) == .ok)
        #expect(t.nextCheck == Self.t0.addingTimeInterval(AlertRules().errorHold))
        #expect(t.pendingUntil(Self.laser) == Self.t0.addingTimeInterval(AlertRules().errorHold))
        #expect(t.pendingUntil(Self.inkjet) == nil)
        let notices = t.observe(Self.seen(jam), now: Self.minutes(2))
        try #require(notices.count == 1)
        #expect(notices[0].kind == .paperJam && notices[0].title == "Paper jam")
        #expect(t.level(Self.laser) == .error)
        #expect(t.nextCheck == nil)
        #expect(t.observe(Self.seen(jam), now: Self.minutes(30)).isEmpty)
    }

    @Test func aConditionThatFlapsAlertsOnce() {
        let t = Self.tracker()
        let open = Self.with(("cover-open", .error, "A cover is open"))
        _ = t.observe(Self.seen(open), now: Self.t0)
        #expect(t.observe(Self.seen(open), now: Self.minutes(2)).count == 1)
        for i in 1...6 { #expect(t.observe(Self.seen(i % 2 == 0 ? open : Self.ready), now: Self.minutes(Double(2 + 3 * i))).isEmpty) }
        // Gone for longer than the clear hold: a new one is a new alert.
        _ = t.observe(Self.seen(Self.ready), now: Self.minutes(30))
        _ = t.observe(Self.seen(Self.ready), now: Self.minutes(45))
        _ = t.observe(Self.seen(open), now: Self.minutes(60))
        #expect(t.observe(Self.seen(open), now: Self.minutes(62)).count == 1)
    }

    @Test func aConditionGoneBeforeItsHoldNeverAlerts() {
        let t = Self.tracker()
        _ = t.observe(Self.seen(Self.with(("media-empty", .error, "Out of paper"))), now: Self.t0)
        #expect(t.observe(Self.seen(Self.ready), now: Self.minutes(0.5)).isEmpty)
        #expect(t.observe(Self.seen(Self.ready), now: Self.minutes(30)).isEmpty)
        #expect(t.nextCheck == nil)
    }

    @Test(arguments: [
        ("jamInPrinter", AlertKind.paperJam), // LEDM
        ("media-jam", .paperJam), // IPP
        ("trayEmptyOrOpen", .paperOut), ("mediaPrompt", .paperOut), ("media-empty", .paperOut), ("media-needed", .paperOut),
        ("closeDoorOrCover", .coverOpen), ("door-open", .coverOpen), ("interlock-open", .coverOpen),
        ("cartridgeMissing", .error), ("printerError", .error),
    ] as [(String, AlertKind)])
    func printerProblemsAreNamed(_ id: String, _ kind: AlertKind) {
        #expect(AlertConditions.find(Self.seen(Self.with((id, .error, "Text"))), AlertRules()) { _ in false }.map(\.kind) == [kind])
    }

    @Test(arguments: [
        ("scannerAdfJam", Severity.error), // the scanner's feeder: only matters while someone scans
        ("scannerAdfDoorOpen", .error),
        ("replaceCartridgeOut", .error), // supply levels come from the supplies, not from status
        ("toner-empty", .error),
        ("marker-supply-low", .warning),
        ("media-low", .warning), // a warning, not an error
        ("cartridgeLow", .warning),
    ] as [(String, Severity)])
    func scannerSupplyAndWarningReasonsAreNotPrinterAlerts(_ id: String, _ severity: Severity) {
        #expect(AlertConditions.find(Self.seen(Self.with((id, severity, "Text"))), AlertRules()) { _ in false }.isEmpty)
    }

    @Test func aStatusCodeWithoutAlertsStillCounts() {
        let jam = PrinterStatus(code: "jamInPrinter", message: "Paper jam", severity: .error, alerts: [])
        #expect(AlertConditions.find(Self.seen(jam), AlertRules()) { _ in false }.map(\.kind) == [.paperJam])
        // The same problem as code and alert is one condition.
        var both = jam
        both.alerts = [PrinterAlert(id: "jamInPrinter", severity: .error, message: "Paper jam")]
        #expect(AlertConditions.find(Self.seen(both), AlertRules()) { _ in false }.count == 1)
        // IPP: "stopped" because of a jam is the jam, not a second error.
        let stopped = PrinterStatus(code: "stopped", message: "Paper jam", severity: .error, alerts: [PrinterAlert(id: "media-jam", severity: .error, message: "Paper jam")])
        #expect(AlertConditions.find(Self.seen(stopped), AlertRules()) { _ in false }.map(\.kind) == [.paperJam])
    }

    @Test func anUnusableReplyKeepsWhatWasKnown() {
        let t = Self.tracker()
        let jam = Self.with(("media-jam", .error, "Paper jam"))
        _ = t.observe(Self.seen(jam), now: Self.t0)
        #expect(t.observe(Self.seen(jam), now: Self.minutes(2)).count == 1)
        // Status unknown (printer waking up): the jam isn't counted as gone, so it doesn't alert again afterwards.
        for i in 1..<10 { _ = t.observe(Self.seen(nil), now: Self.minutes(Double(2 + 5 * i))) }
        #expect(t.level(Self.laser) == .error)
        #expect(t.observe(Self.seen(jam), now: Self.hours(1)).isEmpty)
    }

    @Test func aPendingProblemThePrinterStopsShowingIsDropped() {
        // A jam within its hold, then the printer is switched off: nothing is pending in the past (no endless re-checks).
        let t = Self.tracker()
        _ = t.observe(Self.seen(Self.with(("media-jam", .error, "Paper jam"))), now: Self.t0)
        _ = t.observe(Self.unreachable(), now: Self.minutes(5))
        #expect(t.pendingUntil(Self.laser) == Self.minutes(5).addingTimeInterval(AlertRules().offlineHold))
        #expect(t.observe(Self.unreachable(), now: Self.minutes(10)).isEmpty)
        #expect(t.nextCheck.map { $0 > Self.minutes(10) } == true)
        // An unusable reply drops it too.
        let u = Self.tracker()
        _ = u.observe(Self.seen(Self.with(("media-jam", .error, "Paper jam"))), now: Self.t0)
        _ = u.observe(Self.seen(nil), now: Self.minutes(5))
        #expect(u.pendingUntil(Self.laser) == nil)
    }

    // MARK: Offline

    @Test func offlineAlertsAfterItsLongerHoldAndKeepsWhatWasKnown() throws {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.t0).count == 1)
        #expect(t.observe(Self.unreachable(), now: Self.minutes(5)).isEmpty)
        #expect(t.observe(Self.unreachable(), now: Self.minutes(10)).isEmpty)
        #expect(t.level(Self.laser) == .warning) // the low toner from before; offline isn't confirmed yet
        let notices = t.observe(Self.unreachable(), now: Self.minutes(25))
        try #require(notices.count == 1)
        #expect(notices[0].kind == .offline && notices[0].title == "Office laser is offline")
        #expect(t.level(Self.laser) == .warning) // low toner outranks offline
        // Back: the low toner wasn't forgotten while unreachable, so it doesn't alert again.
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.minutes(30)).isEmpty)
    }

    @Test func offlineAlertsCanBeTurnedOffButTheIconStillShowsIt() {
        let t = Self.tracker(Self.rules { $0.offline = false })
        _ = t.observe(Self.unreachable(), now: Self.t0)
        #expect(t.observe(Self.unreachable(), now: Self.minutes(20)).isEmpty)
        #expect(t.level(Self.laser) == .offline)
        #expect(t.overall == .offline)
    }

    @Test func aLongGapBetweenChecksStartsTheHoldAgain() {
        // The Mac slept with the printer unreachable: waking up isn't 8 hours of "offline".
        let t = Self.tracker()
        _ = t.observe(Self.unreachable(), now: Self.t0)
        #expect(t.observe(Self.unreachable(), now: Self.hours(8)).isEmpty)
        #expect(t.observe(Self.unreachable(), now: Self.hours(8).addingTimeInterval(20 * 60)).count == 1)
    }

    @Test func resettingPendingConditionsRestartsTheirHold() {
        let t = Self.tracker()
        _ = t.observe(Self.unreachable(), now: Self.t0)
        t.resetPending()
        #expect(t.observe(Self.unreachable(), now: Self.minutes(16)).isEmpty)
        #expect(t.observe(Self.unreachable(), now: Self.minutes(32)).count == 1)
    }

    // MARK: Quiet hours, pause, off

    private static let quiet = QuietHours(from: (22, 0), to: (7, 0))

    @Test func quietHoursHoldAlertsUntilTheyEnd() {
        let t = Self.tracker(Self.rules { $0.quiet = Self.quiet })
        let night = Self.hours(11.5) // 23:30
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: night).isEmpty)
        #expect(t.level(Self.laser) == .warning) // the icon still shows it
        #expect(t.release(now: night.addingTimeInterval(2 * 3600)).isEmpty)
        #expect(t.release(now: night.addingTimeInterval(8 * 3600)).map(\.kind) == [.supplyLow]) // 7:30
        #expect(t.release(now: night.addingTimeInterval(9 * 3600)).isEmpty)
    }

    @Test func aHeldAlertThatClearedOvernightIsDropped() {
        let t = Self.tracker(Self.rules { $0.quiet = Self.quiet })
        let night = Self.hours(11) // 23:00
        let open = Self.with(("cover-open", .error, "A cover is open"))
        _ = t.observe(Self.seen(open), now: night)
        _ = t.observe(Self.seen(open), now: night.addingTimeInterval(5 * 60))
        _ = t.observe(Self.seen(Self.ready), now: night.addingTimeInterval(10 * 60))
        _ = t.observe(Self.seen(Self.ready), now: night.addingTimeInterval(30 * 60))
        #expect(t.release(now: night.addingTimeInterval(9 * 3600)).isEmpty)
    }

    @Test(arguments: [
        (22, 0, 7, 0, 23, 59, true), (22, 0, 7, 0, 3, 0, true), (22, 0, 7, 0, 7, 0, false), (22, 0, 7, 0, 12, 0, false),
        (13, 0, 14, 0, 13, 30, true), (13, 0, 14, 0, 14, 30, false),
        (9, 0, 9, 0, 9, 0, false), // empty range
    ] as [(Int, Int, Int, Int, Int, Int, Bool)])
    func quietHoursCanCrossMidnight(_ fh: Int, _ fm: Int, _ th: Int, _ tm: Int, _ h: Int, _ m: Int, _ quiet: Bool) {
        #expect(QuietHours(from: (fh, fm), to: (th, tm)).contains(minuteOfDay: h * 60 + m) == quiet)
    }

    @Test func pausedAlertsAreNotShownLater() {
        let t = Self.tracker()
        t.pausedUntil = Self.hours(1)
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.t0).isEmpty)
        #expect(t.release(now: Self.hours(2)).isEmpty)
        #expect(t.observe(Self.seen(Self.ready, Self.toner(9)), now: Self.hours(2)).isEmpty)
        #expect(t.level(Self.laser) == .warning)
        // A new problem after the pause alerts as usual.
        let jam = Self.with(("media-jam", .error, "Paper jam"))
        _ = t.observe(Self.seen(jam, Self.toner(9)), now: Self.hours(3))
        #expect(t.observe(Self.seen(jam, Self.toner(9)), now: Self.hours(3).addingTimeInterval(120)).count == 1)
    }

    @Test func alertsTurnedOffAreNotShownWhenTurnedBackOn() {
        let t = Self.tracker(Self.rules { $0.enabled = false })
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.t0).isEmpty)
        t.rules.enabled = true
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.minutes(5)).isEmpty)
        #expect(t.release(now: Self.minutes(6)).isEmpty)
    }

    // MARK: Memory, levels, printers

    @Test func alertsAlreadyShownAreNotShownAgainAfterARestart() {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.t0).count == 1)
        let remembered = t.shown()
        #expect(remembered[Self.laser]?.count == 1)

        let next = AlertTracker(rules: AlertRules(), shown: remembered, timeZone: Self.zone)
        #expect(next.level(Self.laser) == .ok) // remembered, but not seen yet
        #expect(next.observe(Self.seen(Self.ready, Self.toner(9)), now: Self.hours(24)).isEmpty)
        #expect(next.level(Self.laser) == .warning)
        // Remembered alerts that turn out to be gone are forgotten after the clear hold.
        let replaced = AlertTracker(rules: AlertRules(), shown: remembered, timeZone: Self.zone)
        _ = replaced.observe(Self.seen(Self.ready, Self.toner(100)), now: Self.hours(24))
        _ = replaced.observe(Self.seen(Self.ready, Self.toner(100)), now: Self.hours(24).addingTimeInterval(15 * 60))
        #expect(replaced.shown().isEmpty)
    }

    @Test func rememberedKeysFromAnUnknownVersionAreIgnored() {
        let t = AlertTracker(rules: AlertRules(), shown: [Self.laser: ["NotAKind|x", "", "SupplyLow|Black toner|K"]], timeZone: Self.zone)
        #expect(t.shown()[Self.laser]?.count == 1)
    }

    @Test func theIconShowsTheWorstPrinter() {
        let t = Self.tracker()
        #expect(t.overall == .ok)
        _ = t.observe(Self.seen(Self.ready, Self.toner(50)), now: Self.t0)
        _ = t.observe(Self.unreachable(Self.inkjet), now: Self.t0)
        _ = t.observe(Self.unreachable(Self.inkjet), now: Self.minutes(20))
        #expect(t.overall == .offline)
        _ = t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.minutes(20))
        #expect(t.overall == .warning)
        let jam = Self.with(("media-jam", .error, "Paper jam"))
        _ = t.observe(Self.seen(jam, Self.toner(10)), now: Self.minutes(21))
        _ = t.observe(Self.seen(jam, Self.toner(10)), now: Self.minutes(25))
        #expect(t.overall == .error)
        #expect(t.problem(Self.laser) == "Paper jam")
        #expect(t.problem(Self.inkjet) == "Offline")
        t.forget(Self.laser)
        #expect(t.overall == .offline)
        #expect(t.problem(Self.laser) == nil)
    }

    @Test func twoPrintersAreTrackedApart() {
        let t = Self.tracker()
        #expect(t.observe(Self.seen(Self.ready, Self.toner(10)), now: Self.t0).count == 1)
        #expect(t.observe(PrinterSnapshot(uuid: Self.inkjet, name: "Inkjet", reachable: true, status: Self.ready, supplies: [Self.toner(10)]),
                          now: Self.t0).count == 1)
    }

    // MARK: Polling and tooltip

    @Test(arguments: [
        (false, false, 0, 5), (true, false, 0, 15), // on battery
        (false, true, 0, 15), // a constrained (metered) network
        (false, false, 1, 10), // unreachable: back off
        (false, false, 2, 20), (false, false, 3, 40), (false, false, 9, 60), (true, false, 3, 60),
    ] as [(Bool, Bool, Int, Int)])
    func checksAreRareAndBackOff(_ battery: Bool, _ constrained: Bool, _ failures: Int, _ minutes: Int) {
        #expect(AlertPolling.interval(onBattery: battery, constrained: constrained, failures: failures) == TimeInterval(minutes * 60))
    }

    @Test func tooltipListsProblemsFirstAndFitsTheLimit() {
        let text = TrayText.tooltip([PrinterLine(name: "Office laser", level: .ok, text: "Ready"),
                                     PrinterLine(name: "Inkjet", level: .error, text: "Paper jam")], paused: false)
        #expect(text == "Inkvolt Print\nInkjet: Paper jam\nOffice laser: Ready")

        let many = (1...12).map { PrinterLine(name: "Printer number \($0) on the second floor", level: .warning, text: "Yellow ink low (12%)") }
        let cut = TrayText.tooltip(many, paused: true)
        #expect(cut.count <= TrayText.maxLength)
        #expect(cut.hasPrefix("Inkvolt Print (alerts paused)\n"))
        #expect(cut.hasSuffix("more"))
        #expect(TrayText.tooltip([], paused: false) == "Inkvolt Print")
    }
}

/// The printer list's one line: the state, and the reason for a warning or error the state's own words don't give. Ported
/// from StatusLineTests.cs.
struct StatusLineTests {
    private static func a(_ severity: Severity, _ text: String) -> PrinterAlert { PrinterAlert(id: text, severity: severity, message: text) }

    @Test func aPrinterWithoutProblemsShowsItsState() {
        #expect(PrinterStatus.listLine("Ready", .info, []) == "Ready")
        #expect(PrinterStatus.listLine("Sleeping", .info, [Self.a(.info, "Genuine HP supply")]) == "Sleeping")
    }

    @Test func aWarningNamesItsReasonAfterTheState() {
        #expect(PrinterStatus.listLine("Ready", .warning, [Self.a(.warning, "Yellow ink is low.")]) == "Ready · Yellow ink is low")
    }

    @Test func theWorstAlertIsNamedAndTheOthersCounted() {
        let alerts = [Self.a(.warning, "Yellow ink is low."), Self.a(.error, "Paper jam in tray 2."), Self.a(.warning, "Tray 1 is low on paper.")]
        #expect(PrinterStatus.listLine("Error", .error, alerts) == "Error · Paper jam in tray 2 · +2")
    }

    @Test func anAlertThatRepeatsOrExtendsTheStateReplacesIt() {
        #expect(PrinterStatus.listLine("Paper jam", .error, [Self.a(.error, "Paper jam.")]) == "Paper jam")
        #expect(PrinterStatus.listLine("Paper jam", .error, [Self.a(.error, "Paper jam in tray 2")]) == "Paper jam in tray 2")
    }

    @Test func aWarningWithoutAlertsKeepsTheState() {
        #expect(PrinterStatus.listLine("Toner low", .warning, []) == "Toner low")
    }
}
