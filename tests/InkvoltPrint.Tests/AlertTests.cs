using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Tests;

public class AlertTests
{
    private const string Laser = "12345678-1234-4abc-8def-123456789abc", Inkjet = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b";
    private static readonly DateTimeOffset T0 = new(2026, 10, 24, 12, 0, 0, TimeSpan.FromHours(-4));

    private static Consumable Toner(int? percent, string state = "ok", string name = "Black toner", string? part = "W1340A") =>
        new(name, "toner", "K", percent, state, part, null, null, percent is { } p ? p * 15 : null, null);

    private static Consumable Waste(string state) => new("Maintenance box", "wasteInk", null, null, state, null, null, null, null, null);

    private static readonly PrinterStatus Ready = new("ready", "Ready", Severity.Info, []);

    private static PrinterStatus With(params (string Id, Severity Sev, string Text)[] alerts) =>
        new("ready", alerts[0].Text, alerts.Max(a => a.Sev), alerts.Select(a => new PrinterAlert(a.Id, a.Sev, a.Text)).ToList());

    private static PrinterSnapshot Seen(PrinterStatus? status, params Consumable[] supplies) =>
        new(Laser, "Office laser", Reachable: true, status, supplies);

    private static PrinterSnapshot Unreachable(string uuid = Laser) => new(uuid, "Office laser", Reachable: false, null, null);

    private static AlertTracker Tracker(AlertRules? rules = null) => new(rules ?? new AlertRules());

    // ---------------------------------------------------------------- supplies

    [Fact]
    public void Toner_dropping_below_the_threshold_alerts_once()
    {
        var t = Tracker();
        Assert.Empty(t.Observe(Seen(Ready, Toner(40)), T0));
        var notices = t.Observe(Seen(Ready, Toner(14)), T0.AddMinutes(5));
        var n = Assert.Single(notices);
        Assert.Equal(AlertKind.SupplyLow, n.Kind);
        Assert.Equal("Black toner low (14%)", n.Title);
        Assert.Contains("Office laser", n.Body);
        Assert.Contains("W1340A", n.Body); // the part number the app already shows; no shop link
        Assert.DoesNotContain("http", n.Body);
        Assert.Empty(t.Observe(Seen(Ready, Toner(13)), T0.AddMinutes(10)));
        Assert.Empty(t.Observe(Seen(Ready, Toner(12)), T0.AddHours(5)));
        Assert.Equal(AlertLevel.Warning, t.Level(Laser));
    }

    [Fact]
    public void Threshold_is_configurable()
    {
        var t = Tracker(new AlertRules { LowPercent = 25 });
        Assert.Single(t.Observe(Seen(Ready, Toner(24)), T0));
        var u = Tracker(new AlertRules { LowPercent = 10 });
        Assert.Empty(u.Observe(Seen(Ready, Toner(24)), T0));
        Assert.Equal(AlertLevel.Ok, u.Level(Laser));
    }

    [Fact]
    public void A_level_wobbling_around_the_threshold_alerts_only_once()
    {
        var t = Tracker();
        Assert.Single(t.Observe(Seen(Ready, Toner(15)), T0));
        for (var i = 1; i < 30; i++)
            Assert.Empty(t.Observe(Seen(Ready, Toner(i % 2 == 0 ? 15 : 18)), T0.AddMinutes(5 * i)));
    }

    [Fact]
    public void A_new_cartridge_clears_the_alert_so_the_next_low_alerts_again()
    {
        var t = Tracker();
        Assert.Single(t.Observe(Seen(Ready, Toner(10)), T0));
        Assert.Empty(t.Observe(Seen(Ready, Toner(100)), T0.AddMinutes(1)));
        Assert.Empty(t.Observe(Seen(Ready, Toner(100)), T0.AddMinutes(20))); // gone for the clear hold: cleared
        Assert.Equal(AlertLevel.Ok, t.Level(Laser));
        Assert.Single(t.Observe(Seen(Ready, Toner(9)), T0.AddDays(60)));
    }

    [Fact]
    public void Running_empty_after_low_alerts_again_and_a_jump_to_empty_alerts_once()
    {
        var t = Tracker();
        Assert.Equal(AlertKind.SupplyLow, Assert.Single(t.Observe(Seen(Ready, Toner(5)), T0)).Kind);
        var empty = Assert.Single(t.Observe(Seen(Ready, Toner(0, "out")), T0.AddDays(3)));
        Assert.Equal(AlertKind.SupplyEmpty, empty.Kind);
        Assert.Equal(AlertLevel.Error, t.Level(Laser));

        var u = Tracker();
        Assert.Equal(AlertKind.SupplyEmpty, Assert.Single(u.Observe(Seen(Ready, Toner(0)), T0)).Kind);
    }

    [Fact]
    public void Levels_without_a_percentage_use_the_printers_own_state()
    {
        var t = Tracker();
        Assert.Equal(AlertKind.SupplyLow, Assert.Single(t.Observe(Seen(Ready, Toner(null, "low")), T0)).Kind);
        Assert.Equal(AlertKind.SupplyEmpty, Assert.Single(t.Observe(Seen(Ready, Toner(null, "out")), T0.AddHours(1))).Kind);

        var w = Tracker();
        Assert.Equal(AlertKind.WasteAlmostFull, Assert.Single(w.Observe(Seen(Ready, Waste("almostFull")), T0)).Kind);
        Assert.Empty(w.Observe(Seen(Ready, Waste("almostFull")), T0.AddHours(1)));
        Assert.Equal(AlertKind.WasteFull, Assert.Single(w.Observe(Seen(Ready, Waste("full")), T0.AddHours(2))).Kind);
        Assert.Empty(Tracker().Observe(Seen(Ready, Waste("ok")), T0));
    }

    [Fact]
    public void Each_supply_is_its_own_alert()
    {
        var t = Tracker();
        var notices = t.Observe(Seen(Ready, Toner(10, name: "Cyan ink"), Toner(12, name: "Yellow ink"), Toner(80, name: "Black ink")), T0);
        Assert.Equal(["Cyan ink low (10%)", "Yellow ink low (12%)"], notices.Select(n => n.Title).Order());
    }

    // ---------------------------------------------------------------- printer errors

    [Fact]
    public void A_jam_alerts_once_it_has_lasted_the_hold_time()
    {
        var t = Tracker();
        var jam = With(("jamInPrinter", Severity.Error, "Paper jam"));
        Assert.Empty(t.Observe(Seen(jam), T0)); // could be the user clearing a jam right now
        Assert.Equal(AlertLevel.Ok, t.Level(Laser));
        Assert.Equal(T0 + new AlertRules().ErrorHold, t.NextCheck);
        Assert.Equal(T0 + new AlertRules().ErrorHold, t.PendingUntil(Laser));
        Assert.Null(t.PendingUntil(Inkjet));
        var n = Assert.Single(t.Observe(Seen(jam), T0.AddMinutes(2)));
        Assert.Equal(AlertKind.PaperJam, n.Kind);
        Assert.Equal("Paper jam", n.Title);
        Assert.Equal(AlertLevel.Error, t.Level(Laser));
        Assert.Null(t.NextCheck);
        Assert.Empty(t.Observe(Seen(jam), T0.AddMinutes(30)));
    }

    [Fact]
    public void A_condition_that_flaps_alerts_once()
    {
        var t = Tracker();
        var open = With(("cover-open", Severity.Error, "A cover is open"));
        t.Observe(Seen(open), T0);
        Assert.Single(t.Observe(Seen(open), T0.AddMinutes(2)));
        for (var i = 1; i <= 6; i++)
            Assert.Empty(t.Observe(Seen(i % 2 == 0 ? open : Ready), T0.AddMinutes(2 + 3 * i)));
        // Gone for longer than the clear hold: a new one is a new alert.
        t.Observe(Seen(Ready), T0.AddMinutes(30));
        t.Observe(Seen(Ready), T0.AddMinutes(45));
        t.Observe(Seen(open), T0.AddMinutes(60));
        Assert.Single(t.Observe(Seen(open), T0.AddMinutes(62)));
    }

    [Fact]
    public void A_condition_gone_before_its_hold_never_alerts()
    {
        var t = Tracker();
        t.Observe(Seen(With(("media-empty", Severity.Error, "Out of paper"))), T0);
        Assert.Empty(t.Observe(Seen(Ready), T0.AddSeconds(30)));
        Assert.Empty(t.Observe(Seen(Ready), T0.AddMinutes(30)));
        Assert.Null(t.NextCheck);
    }

    [Theory]
    [InlineData("jamInPrinter", AlertKind.PaperJam)] // LEDM
    [InlineData("media-jam", AlertKind.PaperJam)] // IPP
    [InlineData("trayEmptyOrOpen", AlertKind.PaperOut)]
    [InlineData("mediaPrompt", AlertKind.PaperOut)]
    [InlineData("media-empty", AlertKind.PaperOut)]
    [InlineData("media-needed", AlertKind.PaperOut)]
    [InlineData("closeDoorOrCover", AlertKind.CoverOpen)]
    [InlineData("door-open", AlertKind.CoverOpen)]
    [InlineData("interlock-open", AlertKind.CoverOpen)]
    [InlineData("cartridgeMissing", AlertKind.Error)]
    [InlineData("printerError", AlertKind.Error)]
    public void Printer_problems_are_named(string id, AlertKind kind)
    {
        var found = AlertConditions.Find(Seen(With((id, Severity.Error, "Text"))), new AlertRules(), _ => false);
        Assert.Equal(kind, Assert.Single(found).Kind);
    }

    [Theory]
    [InlineData("scannerAdfJam", Severity.Error)] // the scanner's feeder: only matters while someone scans
    [InlineData("scannerAdfDoorOpen", Severity.Error)]
    [InlineData("replaceCartridgeOut", Severity.Error)] // supply levels come from the supplies, not from status
    [InlineData("toner-empty", Severity.Error)]
    [InlineData("marker-supply-low", Severity.Warning)]
    [InlineData("media-low", Severity.Warning)] // a warning, not an error
    [InlineData("cartridgeLow", Severity.Warning)]
    public void Scanner_supply_and_warning_reasons_are_not_printer_alerts(string id, Severity severity) =>
        Assert.Empty(AlertConditions.Find(Seen(With((id, severity, "Text"))), new AlertRules(), _ => false));

    [Fact]
    public void A_status_code_without_alerts_still_counts()
    {
        var jam = new PrinterStatus("jamInPrinter", "Paper jam", Severity.Error, []);
        Assert.Equal(AlertKind.PaperJam, Assert.Single(AlertConditions.Find(Seen(jam), new AlertRules(), _ => false)).Kind);
        // The same problem as code and alert is one condition.
        var both = jam with { Alerts = [new PrinterAlert("jamInPrinter", Severity.Error, "Paper jam")] };
        Assert.Single(AlertConditions.Find(Seen(both), new AlertRules(), _ => false));
        // IPP: "stopped" because of a jam is the jam, not a second error.
        var stopped = new PrinterStatus("stopped", "Paper jam", Severity.Error, [new PrinterAlert("media-jam", Severity.Error, "Paper jam")]);
        Assert.Equal(AlertKind.PaperJam, Assert.Single(AlertConditions.Find(Seen(stopped), new AlertRules(), _ => false)).Kind);
    }

    [Fact]
    public void An_unusable_reply_keeps_what_was_known()
    {
        var t = Tracker();
        var jam = With(("media-jam", Severity.Error, "Paper jam"));
        t.Observe(Seen(jam), T0);
        Assert.Single(t.Observe(Seen(jam), T0.AddMinutes(2)));
        // Status unknown (printer waking up): the jam isn't counted as gone, so it doesn't alert again afterwards.
        for (var i = 1; i < 10; i++) t.Observe(Seen(null), T0.AddMinutes(2 + 5 * i));
        Assert.Equal(AlertLevel.Error, t.Level(Laser));
        Assert.Empty(t.Observe(Seen(jam), T0.AddHours(1)));
    }

    // ---------------------------------------------------------------- offline

    [Fact]
    public void Offline_alerts_after_its_longer_hold_and_keeps_what_was_known()
    {
        var t = Tracker();
        Assert.Single(t.Observe(Seen(Ready, Toner(10)), T0));
        Assert.Empty(t.Observe(Unreachable(), T0.AddMinutes(5)));
        Assert.Empty(t.Observe(Unreachable(), T0.AddMinutes(10)));
        Assert.Equal(AlertLevel.Warning, t.Level(Laser)); // the low toner from before; offline isn't confirmed yet
        var n = Assert.Single(t.Observe(Unreachable(), T0.AddMinutes(25)));
        Assert.Equal(AlertKind.Offline, n.Kind);
        Assert.Equal("Office laser is offline", n.Title);
        Assert.Equal(AlertLevel.Warning, t.Level(Laser)); // low toner outranks offline
        // Back: the low toner wasn't forgotten while unreachable, so it doesn't alert again.
        Assert.Empty(t.Observe(Seen(Ready, Toner(10)), T0.AddMinutes(30)));
    }

    [Fact]
    public void Offline_alerts_can_be_turned_off_but_the_icon_still_shows_it()
    {
        var t = Tracker(new AlertRules { Offline = false });
        t.Observe(Unreachable(), T0);
        Assert.Empty(t.Observe(Unreachable(), T0.AddMinutes(20)));
        Assert.Equal(AlertLevel.Offline, t.Level(Laser));
        Assert.Equal(AlertLevel.Offline, t.Overall);
    }

    [Fact]
    public void A_long_gap_between_checks_starts_the_hold_again()
    {
        // The PC slept with the printer unreachable: waking up isn't 8 hours of "offline".
        var t = Tracker();
        t.Observe(Unreachable(), T0);
        Assert.Empty(t.Observe(Unreachable(), T0.AddHours(8)));
        Assert.Single(t.Observe(Unreachable(), T0.AddHours(8).AddMinutes(20)));
    }

    [Fact]
    public void Resetting_pending_conditions_restarts_their_hold()
    {
        var t = Tracker();
        t.Observe(Unreachable(), T0);
        t.ResetPending();
        Assert.Empty(t.Observe(Unreachable(), T0.AddMinutes(16)));
        Assert.Single(t.Observe(Unreachable(), T0.AddMinutes(32)));
    }

    // ---------------------------------------------------------------- quiet hours, pause, off

    [Fact]
    public void Quiet_hours_hold_alerts_until_they_end()
    {
        var t = Tracker(new AlertRules { Quiet = new QuietHours(new TimeOnly(22, 0), new TimeOnly(7, 0)) });
        var night = new DateTimeOffset(2026, 10, 24, 23, 30, 0, T0.Offset);
        Assert.Empty(t.Observe(Seen(Ready, Toner(10)), night));
        Assert.Equal(AlertLevel.Warning, t.Level(Laser)); // the icon still shows it
        Assert.Empty(t.Release(night.AddHours(2)));
        var n = Assert.Single(t.Release(night.AddHours(8))); // 7:30
        Assert.Equal(AlertKind.SupplyLow, n.Kind);
        Assert.Empty(t.Release(night.AddHours(9)));
    }

    [Fact]
    public void A_held_alert_that_cleared_overnight_is_dropped()
    {
        var t = Tracker(new AlertRules { Quiet = new QuietHours(new TimeOnly(22, 0), new TimeOnly(7, 0)) });
        var night = new DateTimeOffset(2026, 10, 24, 23, 0, 0, T0.Offset);
        var open = With(("cover-open", Severity.Error, "A cover is open"));
        t.Observe(Seen(open), night);
        t.Observe(Seen(open), night.AddMinutes(5));
        t.Observe(Seen(Ready), night.AddMinutes(10));
        t.Observe(Seen(Ready), night.AddMinutes(30));
        Assert.Empty(t.Release(night.AddHours(9)));
    }

    [Theory]
    [InlineData(22, 0, 7, 0, 23, 59, true)]
    [InlineData(22, 0, 7, 0, 3, 0, true)]
    [InlineData(22, 0, 7, 0, 7, 0, false)]
    [InlineData(22, 0, 7, 0, 12, 0, false)]
    [InlineData(13, 0, 14, 0, 13, 30, true)]
    [InlineData(13, 0, 14, 0, 14, 30, false)]
    [InlineData(9, 0, 9, 0, 9, 0, false)] // empty range
    public void Quiet_hours_can_cross_midnight(int fh, int fm, int th, int tm, int h, int m, bool quiet) =>
        Assert.Equal(quiet, new QuietHours(new TimeOnly(fh, fm), new TimeOnly(th, tm)).Contains(new TimeOnly(h, m)));

    [Fact]
    public void Paused_alerts_are_not_shown_later()
    {
        var t = Tracker();
        t.PausedUntil = T0.AddHours(1);
        Assert.Empty(t.Observe(Seen(Ready, Toner(10)), T0));
        Assert.Empty(t.Release(T0.AddHours(2)));
        Assert.Empty(t.Observe(Seen(Ready, Toner(9)), T0.AddHours(2)));
        Assert.Equal(AlertLevel.Warning, t.Level(Laser));
        // A new problem after the pause alerts as usual.
        t.Observe(Seen(With(("media-jam", Severity.Error, "Paper jam")), Toner(9)), T0.AddHours(3));
        Assert.Single(t.Observe(Seen(With(("media-jam", Severity.Error, "Paper jam")), Toner(9)), T0.AddHours(3).AddMinutes(2)));
    }

    [Fact]
    public void Alerts_turned_off_are_not_shown_when_turned_back_on()
    {
        var t = Tracker(new AlertRules { Enabled = false });
        Assert.Empty(t.Observe(Seen(Ready, Toner(10)), T0));
        t.Rules = t.Rules with { Enabled = true };
        Assert.Empty(t.Observe(Seen(Ready, Toner(10)), T0.AddMinutes(5)));
        Assert.Empty(t.Release(T0.AddMinutes(6)));
    }

    // ---------------------------------------------------------------- memory, levels, printers

    [Fact]
    public void Alerts_already_shown_are_not_shown_again_after_a_restart()
    {
        var t = Tracker();
        Assert.Single(t.Observe(Seen(Ready, Toner(10)), T0));
        var remembered = t.Shown();
        Assert.Single(remembered[Laser]);

        var next = new AlertTracker(new AlertRules(), remembered);
        Assert.Equal(AlertLevel.Ok, next.Level(Laser)); // remembered, but not seen yet
        Assert.Empty(next.Observe(Seen(Ready, Toner(9)), T0.AddDays(1)));
        Assert.Equal(AlertLevel.Warning, next.Level(Laser));
        // Remembered alerts that turn out to be gone are forgotten after the clear hold.
        var replaced = new AlertTracker(new AlertRules(), remembered);
        replaced.Observe(Seen(Ready, Toner(100)), T0.AddDays(1));
        replaced.Observe(Seen(Ready, Toner(100)), T0.AddDays(1).AddMinutes(15));
        Assert.Empty(replaced.Shown());
    }

    [Fact]
    public void Remembered_keys_from_an_unknown_version_are_ignored()
    {
        var t = new AlertTracker(new AlertRules(), new Dictionary<string, IReadOnlyList<string>> { [Laser] = ["NotAKind|x", "", "SupplyLow|Black toner|K"] });
        Assert.Single(t.Shown()[Laser]);
    }

    [Fact]
    public void The_icon_shows_the_worst_printer()
    {
        var t = Tracker();
        Assert.Equal(AlertLevel.Ok, t.Overall);
        t.Observe(Seen(Ready, Toner(50)), T0);
        t.Observe(Unreachable(Inkjet), T0);
        t.Observe(Unreachable(Inkjet), T0.AddMinutes(20));
        Assert.Equal(AlertLevel.Offline, t.Overall);
        t.Observe(Seen(Ready, Toner(10)), T0.AddMinutes(20));
        Assert.Equal(AlertLevel.Warning, t.Overall);
        var jam = With(("media-jam", Severity.Error, "Paper jam"));
        t.Observe(Seen(jam, Toner(10)), T0.AddMinutes(21));
        t.Observe(Seen(jam, Toner(10)), T0.AddMinutes(25));
        Assert.Equal(AlertLevel.Error, t.Overall);
        Assert.Equal("Paper jam", t.Problem(Laser));
        Assert.Equal("Offline", t.Problem(Inkjet));
        t.Forget(Laser);
        Assert.Equal(AlertLevel.Offline, t.Overall);
        Assert.Null(t.Problem(Laser));
    }

    [Fact]
    public void Two_printers_are_tracked_apart()
    {
        var t = Tracker();
        Assert.Single(t.Observe(Seen(Ready, Toner(10)), T0));
        Assert.Single(t.Observe(new PrinterSnapshot(Inkjet, "Inkjet", true, Ready, [Toner(10)]), T0));
    }

    // ---------------------------------------------------------------- polling and tooltip

    [Theory]
    [InlineData(false, false, 0, 5)]
    [InlineData(true, false, 0, 15)] // on battery
    [InlineData(false, true, 0, 15)] // metered network
    [InlineData(false, false, 1, 10)] // unreachable: back off
    [InlineData(false, false, 2, 20)]
    [InlineData(false, false, 3, 40)]
    [InlineData(false, false, 9, 60)]
    [InlineData(true, false, 3, 60)]
    public void Checks_are_rare_and_back_off(bool battery, bool metered, int failures, int minutes) =>
        Assert.Equal(TimeSpan.FromMinutes(minutes), AlertPolling.Interval(battery, metered, failures));

    [Fact]
    public void Tooltip_lists_problems_first_and_fits_the_shell_limit()
    {
        var text = TrayText.Tooltip(
        [
            new PrinterLine("Office laser", AlertLevel.Ok, "Ready"),
            new PrinterLine("Inkjet", AlertLevel.Error, "Paper jam"),
        ], paused: false);
        Assert.Equal("Inkvolt Print\nInkjet: Paper jam\nOffice laser: Ready", text);

        var many = Enumerable.Range(1, 12).Select(i => new PrinterLine($"Printer number {i} on the second floor", AlertLevel.Warning, "Yellow ink low (12%)")).ToList();
        var cut = TrayText.Tooltip(many, paused: true);
        Assert.True(cut.Length <= TrayText.MaxLength, cut);
        Assert.StartsWith("Inkvolt Print (alerts paused)\n", cut);
        Assert.EndsWith("more", cut);
        Assert.Equal("Inkvolt Print", TrayText.Tooltip([], paused: false));
    }
}
