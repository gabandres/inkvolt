using InkvoltPrint.Core;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Tests;

/// <summary>
/// Supply history (roadmap 1.1): the local store (one row a day per supply), the forecast and pages per cartridge worked out
/// from it, the chart's data, and what a year of readings with two cartridge changes, a wobble at the threshold, a week
/// offline and SNMP's "some left" gives.
/// </summary>
public sealed class SupplyHistoryTests : IDisposable
{
    private const string Printer = "12345678-1234-4abc-8def-123456789abc";
    private static readonly DateOnly Day0 = new(2025, 10, 1);

    private readonly string _folder = Path.Combine(Path.GetTempPath(), "InkvoltHistoryTests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static Consumable Toner(int? percent, string state = "ok", string name = "Black toner", string? color = "K") =>
        new(name, "toner", color, percent, state, "W1340A", null, null, null, null);

    private static Consumable Box => new("Maintenance box", "wasteInk", null, null, "ok", null, null, null, null, null);

    private static SupplyRow Row(int day, int? percent, int? pages = null) =>
        new(Day0.AddDays(day), "Black toner", "K", percent, "ok", pages);

    /// <summary>
    /// The year: a first cartridge from 80% down 0.5 a day, changed on day 100; a second from 100% down to the threshold, wobbling
    /// there (14, 15, 14, 15), a week offline on the way (days 200-206: no rows), changed on day 250; a third from 100% down 0.4 a
    /// day with three days of SNMP's -3 (no level, days 300-302). 10 pages printed a day throughout.
    /// </summary>
    private static List<SupplyRow> TheYear()
    {
        var rows = new List<SupplyRow>();
        for (var day = 0; day <= 364; day++)
        {
            if (day is >= 200 and <= 206) continue;
            int? level = day switch
            {
                < 100 => (int)Math.Round(80 - 0.5 * day),
                < 246 => (int)Math.Round(100 - 85.0 * (day - 100) / 146),
                < 250 => day % 2 == 0 ? 14 : 15,
                >= 300 and <= 302 => null,
                _ => (int)Math.Round(100 - 0.4 * (day - 250)),
            };
            rows.Add(Row(day, level, 1000 + day * 10));
        }
        return rows;
    }

    // ---------------------------------------------------------------- the store

    [Fact]
    public void Rows_come_back_after_a_restart_exactly_as_kept()
    {
        var first = new SupplyHistoryStore(_folder);
        first.Record(Printer, [Toner(45), Toner(60, name: "Cyan toner", color: "C")], 1234, Day0);
        first.Record(Printer, [Toner(44), Toner(null, name: "Cyan toner", color: "C")], 1250, Day0.AddDays(1));

        var again = new SupplyHistoryStore(_folder);

        Assert.Equal(first.Rows(Printer), again.Rows(Printer));
        Assert.Equal(
        [
            new SupplyRow(Day0, "Black toner", "K", 45, "ok", 1234),
            new SupplyRow(Day0, "Cyan toner", "C", 60, "ok", 1234),
            new SupplyRow(Day0.AddDays(1), "Black toner", "K", 44, "ok", 1250),
            new SupplyRow(Day0.AddDays(1), "Cyan toner", "C", null, "ok", 1250),
        ], again.Rows(Printer));
    }

    [Fact]
    public void One_row_a_day_per_supply_the_days_last_reading_wins()
    {
        var store = new SupplyHistoryStore(_folder);

        store.Record(Printer, [Toner(45)], 100, Day0);
        store.Record(Printer, [Toner(44)], 110, Day0);
        store.Record(Printer, [Toner(43)], 120, Day0);

        var row = Assert.Single(store.Rows(Printer));
        Assert.Equal((43, 120), (row.Percent, row.Pages));
    }

    [Fact]
    public void A_reading_that_lost_its_level_or_count_keeps_what_the_day_already_knew()
    {
        var store = new SupplyHistoryStore(_folder);

        store.Record(Printer, [Toner(45)], 100, Day0);
        store.Record(Printer, [Toner(null)], null, Day0);

        var row = Assert.Single(store.Rows(Printer));
        Assert.Equal((45, 100), (row.Percent, row.Pages));
    }

    [Fact]
    public void Nothing_changed_writes_nothing()
    {
        var store = new SupplyHistoryStore(_folder);
        Assert.True(store.Record(Printer, [Toner(45)], 100, Day0));
        var file = Directory.GetFiles(_folder).Single();
        File.SetLastWriteTimeUtc(file, new DateTime(2020, 1, 1, 0, 0, 0, DateTimeKind.Utc));

        Assert.False(store.Record(Printer, [Toner(45)], 100, Day0));

        Assert.Equal(2020, File.GetLastWriteTimeUtc(file).Year);
    }

    [Theory]
    [InlineData(-1)]
    [InlineData(-2)]
    [InlineData(-3)]
    [InlineData(101)]
    public void A_special_value_is_kept_as_no_level(int special)
    {
        var store = new SupplyHistoryStore(_folder);

        store.Record(Printer, [Toner(special)], 100, Day0);

        Assert.Null(Assert.Single(store.Rows(Printer)).Percent);
    }

    [Fact]
    public void Waste_boxes_are_not_kept()
    {
        var store = new SupplyHistoryStore(_folder);

        store.Record(Printer, [Toner(45), Box], 100, Day0);

        Assert.Equal("Black toner", Assert.Single(store.Rows(Printer)).Supply);
    }

    [Fact]
    public void Old_rows_go_after_three_years()
    {
        var store = new SupplyHistoryStore(_folder);

        for (var day = 0; day < SupplyHistoryStore.MaxDays + 50; day++) store.Record(Printer, [Toner(50)], day, Day0.AddDays(day));

        var rows = store.Rows(Printer);
        Assert.Equal(SupplyHistoryStore.MaxDays + 1, rows.Count);
        Assert.Equal(Day0.AddDays(SupplyHistoryStore.MaxDays + 49), rows[^1].Day);
        Assert.Equal(new SupplyHistoryStore(_folder).Rows(Printer), rows);
    }

    [Fact]
    public void A_printer_reporting_many_supplies_or_long_names_stays_bounded()
    {
        var store = new SupplyHistoryStore(_folder);
        var many = Enumerable.Range(0, 200).Select(i => Toner(50, name: $"Supply {i}", color: null)).ToList();

        store.Record(Printer, many, 1, Day0);
        store.Record(Printer, [Toner(50, name: new string('x', 5000) + "\tsecond\ncolumn", color: null)], 1, Day0);

        var rows = store.Rows(Printer);
        Assert.Equal(SupplyHistoryStore.MaxSupplies, rows.Select(r => r.Supply).Distinct().Count());
        var other = new SupplyHistoryStore(_folder);
        other.Record("another", [Toner(50, name: new string('x', 5000) + "\tsecond\ncolumn", color: null)], 1, Day0);
        var name = Assert.Single(new SupplyHistoryStore(_folder).Rows("another")).Supply;
        Assert.Equal(SupplyHistoryStore.MaxName, name.Length);
        Assert.DoesNotContain('\t', name);
        Assert.DoesNotContain('\n', name);
    }

    [Fact]
    public void Printers_beyond_the_limit_lose_their_oldest_file()
    {
        var store = new SupplyHistoryStore(_folder);
        for (var i = 0; i < SupplyHistoryStore.MaxPrinters + 3; i++) store.Record($"printer {i}", [Toner(50)], 1, Day0);

        Assert.Equal(SupplyHistoryStore.MaxPrinters, Directory.GetFiles(_folder).Length);
        Assert.Single(new SupplyHistoryStore(_folder).Rows($"printer {SupplyHistoryStore.MaxPrinters + 2}")); // never the one just made
    }

    [Fact]
    public void A_damaged_file_gives_the_lines_it_still_can()
    {
        var store = new SupplyHistoryStore(_folder);
        store.Record(Printer, [Toner(45)], 100, Day0);
        var file = Directory.GetFiles(_folder).Single();
        File.AppendAllText(file, "not a row\n2026-13-45\tBlack toner\tK\t10\tok\t1\n2026-01-01\t\tK\t10\tok\t1\n2026-01-02\tBlack toner\tK\t900\tok\t-5\n");

        var rows = new SupplyHistoryStore(_folder).Rows(Printer);

        Assert.Equal(2, rows.Count);
        Assert.Equal((45, 100), (rows[0].Percent, rows[0].Pages));
        Assert.Equal((null, null), (rows[1].Percent, rows[1].Pages)); // out of range: no level, no count
    }

    [Fact]
    public void The_file_holds_levels_and_counts_and_no_identifiers()
    {
        var store = new SupplyHistoryStore(_folder);

        store.Record(Printer, [Toner(45)], 100, Day0);

        var text = File.ReadAllText(Directory.GetFiles(_folder).Single());
        Assert.Equal("#inkvolt-supply-history 1\n2025-10-01\tBlack toner\tK\t45\tok\t100\n", text);
    }

    [Fact]
    public void Forgetting_a_printer_removes_its_history()
    {
        var store = new SupplyHistoryStore(_folder);
        store.Record(Printer, [Toner(45)], 100, Day0);

        store.Forget(Printer);

        Assert.Empty(store.Rows(Printer));
        Assert.Empty(Directory.GetFiles(_folder));
    }

    [Fact]
    public void A_renamed_printer_id_keeps_its_history()
    {
        var store = new SupplyHistoryStore(_folder);
        store.Record("192.0.2.14", [Toner(45)], 100, Day0);

        store.Rename("192.0.2.14", Printer);

        Assert.Empty(store.Rows("192.0.2.14"));
        Assert.Single(new SupplyHistoryStore(_folder).Rows(Printer));
    }

    [Fact]
    public void In_memory_a_store_writes_nothing()
    {
        var store = new SupplyHistoryStore(null);

        store.Record(Printer, [Toner(45)], 100, Day0);

        Assert.Single(store.Rows(Printer));
        Assert.False(Directory.Exists(_folder));
    }

    // ---------------------------------------------------------------- a year, as the roadmap's test asks

    [Fact]
    public void The_year_gives_the_change_dates()
    {
        var summary = SupplyAnalysis.Summarize(TheYear(), Day0.AddDays(364));

        Assert.Equal([Day0.AddDays(100), Day0.AddDays(250)], summary.ChangeDates);
    }

    [Fact]
    public void The_year_gives_pages_per_cartridge()
    {
        var summary = SupplyAnalysis.Summarize(TheYear(), Day0.AddDays(364));

        Assert.Equal([1000, 1500, 1140], summary.Cartridges.Select(c => c.Pages));
        Assert.Equal(1140, summary.PagesOnCurrent);
        Assert.False(summary.Cartridges[0].SeenGoingIn); // history started part way through it
        Assert.True(summary.Cartridges[1].SeenGoingIn);
    }

    [Fact]
    public void The_year_gives_days_left_from_the_last_30_days_of_this_cartridge()
    {
        var forecast = SupplyAnalysis.Summarize(TheYear(), Day0.AddDays(364)).Forecast;

        Assert.Equal(ForecastState.Estimate, forecast.State);
        Assert.InRange(forecast.DaysLeft!.Value, 134, 138); // 54% at 0.4 a day
    }

    [Fact]
    public void A_wobble_at_the_threshold_is_no_change_of_cartridge()
    {
        var rows = Enumerable.Range(0, 40).Select(d => Row(d, d % 2 == 0 ? 14 : 16)).ToList();

        Assert.Empty(SupplyAnalysis.Summarize(rows, Day0.AddDays(39)).ChangeDates);
    }

    [Fact]
    public void A_week_offline_is_counted_by_the_calendar_not_by_rows()
    {
        // 1% a day, no rows for days 10-16: the slope is still 1% a day.
        var rows = Enumerable.Range(0, 30).Where(d => d is < 10 or > 16).Select(d => Row(d, 80 - d)).ToList();

        Assert.Equal(51, SupplyAnalysis.Summarize(rows, Day0.AddDays(29)).Forecast.DaysLeft);
    }

    // ---------------------------------------------------------------- days left and its honest states

    [Fact]
    public void Days_left_is_the_level_over_the_slope()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, 80 - d)).ToList();

        var forecast = SupplyAnalysis.Summarize(rows, Day0.AddDays(29)).Forecast;

        Assert.Equal(51, forecast.DaysLeft);
        Assert.Equal("About 51 days left", forecast.Text);
    }

    [Fact]
    public void Days_since_the_last_reading_come_off_the_estimate()
    {
        var rows = Enumerable.Range(0, 20).Select(d => Row(d, 80 - d)).ToList(); // 61% on day 19, 1% a day

        Assert.Equal(51, SupplyAnalysis.Summarize(rows, Day0.AddDays(29)).Forecast.DaysLeft);
    }

    [Fact]
    public void Older_rows_than_30_days_are_left_out_of_the_slope()
    {
        // Down fast long ago, 1% a day for the last 30 days.
        var rows = Enumerable.Range(0, 20).Select(d => Row(d, 99 - 2 * d))
            .Concat(Enumerable.Range(20, 40).Select(d => Row(d, 59 - (d - 20) / 2))).ToList();

        var forecast = SupplyAnalysis.Summarize(rows, Day0.AddDays(59)).Forecast;

        Assert.InRange(forecast.DaysLeft!.Value, 76, 80); // 40% at 0.5 a day
    }

    [Theory]
    [InlineData(1, 7)]
    [InlineData(3, 5)]
    [InlineData(6, 2)]
    public void Too_few_days_say_so_and_how_many_more(int days, int more)
    {
        var rows = Enumerable.Range(0, days).Select(d => Row(d, 80 - d)).ToList();

        var forecast = SupplyAnalysis.Summarize(rows, Day0.AddDays(days - 1)).Forecast;

        Assert.Equal(ForecastState.NotEnoughData, forecast.State);
        Assert.Null(forecast.DaysLeft);
        Assert.Equal(more, forecast.MoreDays);
        Assert.Contains("Not enough history", forecast.Text);
    }

    [Fact]
    public void A_new_cartridge_starts_its_forecast_again()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, 60 - d)).Append(Row(30, 100)).Append(Row(31, 99)).ToList();

        Assert.Equal(ForecastState.NotEnoughData, SupplyAnalysis.Summarize(rows, Day0.AddDays(31)).Forecast.State);
    }

    [Fact]
    public void A_level_that_doesnt_fall_gives_no_number()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, 70)).ToList();

        var forecast = SupplyAnalysis.Summarize(rows, Day0.AddDays(29)).Forecast;

        Assert.Equal(ForecastState.Steady, forecast.State);
        Assert.Null(forecast.DaysLeft);
    }

    [Fact]
    public void Very_slow_use_says_a_long_time_instead_of_a_silly_number()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, d < 15 ? 90 : 89)).ToList();

        var forecast = SupplyAnalysis.Summarize(rows, Day0.AddDays(29)).Forecast;

        Assert.Equal(ForecastState.Estimate, forecast.State);
        Assert.Null(forecast.DaysLeft);
        Assert.Equal("More than two years left", forecast.Text);
    }

    [Fact]
    public void No_reading_for_over_30_days_is_not_enough_data()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, 80 - d)).ToList();

        Assert.Equal(ForecastState.NotEnoughData, SupplyAnalysis.Summarize(rows, Day0.AddDays(90)).Forecast.State);
    }

    [Fact]
    public void An_empty_cartridge_has_no_days_left_to_count()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, Math.Max(0, 20 - d))).ToList();

        Assert.Equal(ForecastState.Empty, SupplyAnalysis.Summarize(rows, Day0.AddDays(29)).Forecast.State);
    }

    [Fact]
    public void A_supply_that_never_reports_a_level_has_no_forecast_or_cartridges()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, null, d)).ToList();

        var summary = SupplyAnalysis.Summarize(rows, Day0.AddDays(29));

        Assert.Equal(ForecastState.NoLevel, summary.Forecast.State);
        Assert.Null(summary.Forecast.Text);
        Assert.Empty(summary.Cartridges);
        Assert.Null(summary.Line);
    }

    [Fact]
    public void No_page_count_leaves_pages_unknown_not_zero()
    {
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, 80 - d)).ToList();

        var summary = SupplyAnalysis.Summarize(rows, Day0.AddDays(29));

        Assert.Null(summary.PagesOnCurrent);
        Assert.Equal("About 51 days left", summary.Line);
    }

    [Fact]
    public void A_page_counter_going_backwards_gives_no_count()
    {
        var rows = new[] { Row(0, 80, 5000), Row(1, 79, 10) };

        Assert.Null(SupplyAnalysis.Summarize(rows, Day0.AddDays(1)).PagesOnCurrent);
    }

    [Fact]
    public void The_line_says_whether_the_cartridge_was_seen_going_in()
    {
        var kept = Enumerable.Range(0, 30).Select(d => Row(d, 80 - d, 100 + d)).ToList();
        Assert.Equal("About 51 days left · 29 pages since Inkvolt Print started keeping track", SupplyAnalysis.Summarize(kept, Day0.AddDays(29)).Line);

        var changed = new[] { Row(0, 5, 100) }.Concat(Enumerable.Range(1, 30).Select(d => Row(d, 100 - d, 100 + d))).ToList();
        Assert.Equal("About 70 days left · 29 pages since this cartridge went in", SupplyAnalysis.Summarize(changed, Day0.AddDays(30)).Line);
    }

    [Fact]
    public void Each_supply_gets_its_own_summary_in_the_order_first_seen()
    {
        var cyan = Enumerable.Range(0, 30).Select(d => new SupplyRow(Day0.AddDays(d), "Cyan ink", "C", 50 - d, "ok", null));
        var rows = TheYear().Take(30).Concat(cyan).OrderBy(r => r.Day).ToList();

        var all = SupplyAnalysis.SummarizeAll(rows, Day0.AddDays(29));

        Assert.Equal(["Black toner", "Cyan ink"], all.Select(s => s.Supply));
        Assert.Equal(21, all[1].Forecast.DaysLeft);
    }

    // ---------------------------------------------------------------- the chart

    [Fact]
    public void The_charts_points_are_the_stored_rows_byte_for_byte()
    {
        var store = new SupplyHistoryStore(_folder);
        store.Import(Printer, TheYear());

        var chart = SupplyChartData.Build(store.Rows(Printer), Day0.AddDays(364));

        var stored = File.ReadAllLines(Directory.GetFiles(_folder).Single()).Skip(1)
            .Select(line => line.Split('\t')).Where(cells => cells[3].Length > 0).Select(cells => $"{cells[0]}\t{cells[3]}").ToList();
        var line = Assert.Single(chart.Lines);
        Assert.Equal(stored, line.Segments.SelectMany(s => s).Select(p => $"{p.Day:yyyy-MM-dd}\t{p.Percent}"));
    }

    [Fact]
    public void No_level_breaks_the_line_and_a_change_of_cartridge_starts_a_new_one()
    {
        var line = Assert.Single(SupplyChartData.Build(TheYear(), Day0.AddDays(364)).Lines);

        Assert.Equal(4, line.Segments.Count); // first cartridge, second (the week offline stays joined), third before and after the -3s
        Assert.Equal(Day0.AddDays(99), line.Segments[0][^1].Day);
        Assert.Equal(Day0.AddDays(100), line.Segments[1][0].Day);
        Assert.Equal(Day0.AddDays(299), line.Segments[2][^1].Day);
        Assert.Equal(Day0.AddDays(303), line.Segments[3][0].Day);
        Assert.Equal([Day0.AddDays(100), Day0.AddDays(250)], line.Changes);
        Assert.All(line.Segments.SelectMany(s => s), p => Assert.InRange(p.Percent, 0, 100));
    }

    [Fact]
    public void A_supply_with_no_level_draws_nothing()
    {
        var chart = SupplyChartData.Build(Enumerable.Range(0, 10).Select(d => Row(d, null)).ToList(), Day0.AddDays(9));

        Assert.Empty(chart.Lines);
        Assert.False(chart.HasEnoughToDraw);
    }

    [Fact]
    public void One_day_of_readings_isnt_a_chart_yet()
    {
        Assert.False(SupplyChartData.Build([Row(0, 50)], Day0).HasEnoughToDraw);
        Assert.True(SupplyChartData.Build([Row(0, 50), Row(1, 49)], Day0.AddDays(1)).HasEnoughToDraw);
    }

    [Fact]
    public void The_chart_shows_the_last_year()
    {
        var rows = Enumerable.Range(0, 600).Select(d => Row(d, 90)).ToList();

        var chart = SupplyChartData.Build(rows, Day0.AddDays(599));

        Assert.Equal(Day0.AddDays(599 - SupplyChartData.Days), chart.From);
        Assert.Equal(Day0.AddDays(599), chart.To);
        Assert.Equal(SupplyChartData.Days + 1, chart.Lines[0].Segments[0].Count);
    }

    // ---------------------------------------------------------------- what the supplies card shows

    [Fact]
    public void The_card_gets_each_supplys_line_and_the_days_left_for_the_alert()
    {
        var cyan = Enumerable.Range(0, 30).Select(d => new SupplyRow(Day0.AddDays(d), "Cyan toner", "C", 50 - d, "ok", null));
        var rows = Enumerable.Range(0, 30).Select(d => Row(d, 80 - d)).Concat(cyan).OrderBy(r => r.Day).ToList();

        var view = SupplyHistoryView.Of(rows, Day0.AddDays(29));

        Assert.Equal("About 51 days left", view.LineFor(Toner(51)));
        Assert.Equal("About 21 days left", view.LineFor(Toner(21, name: "Cyan toner", color: "C")));
        Assert.Null(view.LineFor(Toner(40, name: "Magenta toner", color: "M"))); // nothing kept for it
        Assert.Null(view.LineFor(Box));
        Assert.Equal(new Dictionary<string, int> { ["Black toner|K"] = 51, ["Cyan toner|C"] = 21 }, view.DaysLeft);
        Assert.True(view.Chart.HasEnoughToDraw);
        Assert.Null(view.ChartNote([Toner(51)]));
    }

    [Fact]
    public void A_new_printer_says_the_chart_fills_in_and_one_without_levels_says_nothing()
    {
        var store = new SupplyHistoryStore(null);
        store.Record(Printer, [Toner(45)], 100, Day0);

        var view = SupplyHistoryView.Of(store.Rows(Printer), Day0);

        Assert.False(view.Chart.HasEnoughToDraw);
        Assert.Contains("fills in as days pass", view.ChartNote([Toner(45)]));
        Assert.Null(view.ChartNote([Toner(null), Box]));
        Assert.Empty(view.DaysLeft);
        Assert.StartsWith("Not enough history for days left yet", view.LineFor(Toner(45)));
    }

    [Fact]
    public void The_low_supply_alert_finds_the_days_left_under_the_key_the_store_keeps()
    {
        var odd = Toner(10, name: " Black	toner ", color: "K");
        var store = new SupplyHistoryStore(null);
        for (var d = 0; d < 20; d++) store.Record(Printer, [odd with { PercentRemaining = 30 - d }], null, Day0.AddDays(d));

        var view = SupplyHistoryView.Of(store.Rows(Printer), Day0.AddDays(19));

        Assert.True(view.DaysLeft.ContainsKey(SupplyRow.KeyOf(odd)));
    }

    // ---------------------------------------------------------------- the low-supply alert names the days left

    [Fact]
    public void The_low_supply_alert_names_the_days_left()
    {
        var t = new AlertTracker(new AlertRules());
        var low = Toner(10) with { EstimatedPagesRemaining = 140 };
        var snap = new PrinterSnapshot(Printer, "Office laser", true, new PrinterStatus("ready", "Ready", Severity.Info, []), [low])
        {
            DaysLeft = new Dictionary<string, int> { [SupplyRow.KeyOf(low)] = 12 },
        };

        var notice = Assert.Single(t.Observe(snap, DateTimeOffset.Now));

        Assert.StartsWith("Office laser: about 140 pages left, about 12 days at this rate.", notice.Body);
    }

    [Fact]
    public void Without_a_forecast_the_low_supply_alert_reads_as_before()
    {
        var t = new AlertTracker(new AlertRules());
        var snap = new PrinterSnapshot(Printer, "Office laser", true, new PrinterStatus("ready", "Ready", Severity.Info, []), [Toner(10)]);

        var notice = Assert.Single(t.Observe(snap, DateTimeOffset.Now));

        Assert.StartsWith("Office laser: running low.", notice.Body);
    }

    [Fact]
    public void Days_left_alone_are_named_when_the_printer_gives_no_page_estimate()
    {
        var t = new AlertTracker(new AlertRules());
        var snap = new PrinterSnapshot(Printer, "Office laser", true, new PrinterStatus("ready", "Ready", Severity.Info, []), [Toner(10)])
        {
            DaysLeft = new Dictionary<string, int> { [SupplyRow.KeyOf(Toner(10))] = 1 },
        };

        Assert.StartsWith("Office laser: about 1 day left at this rate.", Assert.Single(t.Observe(snap, DateTimeOffset.Now)).Body);
    }

    // ---------------------------------------------------------------- the demo's made-up history

    [Fact]
    public void The_demo_history_is_a_believable_year_that_ends_at_the_reading()
    {
        var today = new DateOnly(2026, 10, 30);
        var store = new SupplyHistoryStore(null, DemoSupplyHistory.Seed);

        store.Record(Printer, [Toner(62), Toner(35, name: "Yellow ink", color: "Y"), Box], 18_400, today);

        var rows = store.Rows(Printer);
        Assert.Equal(["Black toner", "Yellow ink"], rows.Select(r => r.Supply).Distinct());
        Assert.DoesNotContain(rows, r => r.Supply == Box.Name);
        Assert.InRange(rows.Min(r => r.Day), today.AddDays(-366), today.AddDays(-360));
        Assert.Equal(62, rows.Last(r => r.Supply == "Black toner").Percent);
        Assert.Equal(18_400, rows.Last(r => r.Supply == "Black toner").Pages);
        Assert.All(rows, r => Assert.InRange(r.Percent ?? 50, 0, 100));

        var black = SupplyAnalysis.Summarize(rows.Where(r => r.Supply == "Black toner").ToList(), today);
        Assert.NotEmpty(black.ChangeDates);
        Assert.Equal(ForecastState.Estimate, black.Forecast.State);
        Assert.NotNull(black.Forecast.DaysLeft);
        Assert.NotNull(black.PagesOnCurrent);
        Assert.True(SupplyChartData.Build(rows, today).HasEnoughToDraw);
    }

    [Fact]
    public void The_demo_history_is_the_same_every_run_and_keeps_a_printer_without_a_count_without_one()
    {
        var today = new DateOnly(2026, 10, 30);
        var a = new SupplyHistoryStore(null, DemoSupplyHistory.Seed);
        var b = new SupplyHistoryStore(null, DemoSupplyHistory.Seed);

        a.Record(Printer, [Toner(62)], null, today);
        b.Record(Printer, [Toner(62)], null, today);

        Assert.Equal(a.Rows(Printer), b.Rows(Printer));
        Assert.All(a.Rows(Printer), r => Assert.Null(r.Pages));
    }

    [Fact]
    public void A_young_demo_printers_count_stays_above_zero_through_the_year()
    {
        var store = new SupplyHistoryStore(null, DemoSupplyHistory.Seed);

        store.Record(Printer, [Toner(20)], 387, new DateOnly(2026, 10, 30));

        var pages = store.Rows(Printer).Select(r => r.Pages!.Value).ToList();
        Assert.All(pages, p => Assert.True(p > 0));
        Assert.True(pages[0] < 387);
        Assert.Equal(pages.Order(), pages); // the counter only goes up
    }

    [Fact]
    public void The_demo_history_is_only_made_once_per_printer()
    {
        var today = new DateOnly(2026, 10, 30);
        var store = new SupplyHistoryStore(null, DemoSupplyHistory.Seed);

        store.Record(Printer, [Toner(62)], null, today);
        var count = store.Rows(Printer).Count;
        store.Record(Printer, [Toner(61)], null, today.AddDays(1));

        Assert.Equal(count + 1, store.Rows(Printer).Count);
    }
}

/// <summary>The one CSV across all printers: its content, and the Pro check in front of it.</summary>
[Collection("Pro")]
public sealed class SupplyHistoryCsvTests : IDisposable
{
    private const string Laser = "12345678-1234-4abc-8def-123456789abc", Inkjet = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b";
    private static readonly DateOnly Day0 = new(2026, 1, 1);

    public SupplyHistoryCsvTests()
    {
        Pro.Store = new Core.Suite.MemoryProStore();
        Pro.Enforced = false;
    }

    public void Dispose()
    {
        Pro.Store = new Core.Suite.MemoryProStore();
        Pro.Enforced = false;
    }

    private static SupplyHistoryStore Store()
    {
        var store = new SupplyHistoryStore(null);
        store.Import(Laser,
        [
            new(Day0, "Black toner", "K", 5, "low", 1000),
            new(Day0.AddDays(1), "Black toner", "K", 100, "ok", 1010),
            new(Day0.AddDays(2), "Black toner", "K", null, "ok", 1030),
            new(Day0.AddDays(3), "Black toner", "K", 99, "ok", 1050),
        ]);
        store.Import(Inkjet, [new(Day0, "Cyan, light", "#00FFFF", 40, "ok", null)]);
        return store;
    }

    private static readonly (string Id, string Name)[] Printers = [(Laser, "Office laser"), (Inkjet, "=Kitchen \"inkjet\"")];

    [Fact]
    public void One_table_across_all_printers_with_the_cartridge_each_row_belongs_to()
    {
        var csv = SupplyHistoryCsv.Build(Store(), Printers);

        Assert.Equal(
            "Printer,Supply,Color,Date,Level %,State,Pages printed,Cartridge seen since,Pages on this cartridge\r\n" +
            "Office laser,Black toner,K,2026-01-01,5,low,1000,2026-01-01,0\r\n" +
            "Office laser,Black toner,K,2026-01-02,100,ok,1010,2026-01-02,0\r\n" +
            "Office laser,Black toner,K,2026-01-03,,ok,1030,2026-01-02,20\r\n" +
            "Office laser,Black toner,K,2026-01-04,99,ok,1050,2026-01-02,40\r\n" +
            "\"'=Kitchen \"\"inkjet\"\"\",\"Cyan, light\",#00FFFF,2026-01-01,40,ok,,2026-01-01,\r\n", csv);
    }

    [Fact]
    public void A_supply_that_never_gave_a_level_still_has_its_rows()
    {
        var store = new SupplyHistoryStore(null);
        store.Import(Laser, [new(Day0, "Black toner", "K", null, "ok", 500), new(Day0.AddDays(1), "Black toner", "K", null, "ok", 510)]);

        Assert.EndsWith(
            "Office laser,Black toner,K,2026-01-01,,ok,500,2026-01-01,0\r\n" +
            "Office laser,Black toner,K,2026-01-02,,ok,510,2026-01-01,10\r\n", SupplyHistoryCsv.Build(store, Printers));
    }

    [Fact]
    public void A_printer_without_rows_adds_nothing()
    {
        var csv = SupplyHistoryCsv.Build(new SupplyHistoryStore(null), Printers);

        Assert.Single(csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries));
    }

    [Fact]
    public void While_the_gate_is_off_export_runs_for_everyone()
    {
        Assert.Equal(SupplyHistoryCsv.Build(Store(), Printers), SupplyHistoryCsv.Export(Store(), Printers));
    }

    [Fact]
    public void With_the_gate_on_export_needs_a_licence_and_the_chart_data_doesnt()
    {
        Pro.Enforced = true;

        Assert.Null(SupplyHistoryCsv.Export(Store(), Printers));
        Assert.NotEmpty(SupplyChartData.Build(Store().Rows(Laser), Day0.AddDays(3)).Lines); // the chart and days left stay free
    }
}
