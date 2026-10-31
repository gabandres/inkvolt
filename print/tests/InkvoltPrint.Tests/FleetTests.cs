using System.Text.Json;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>The Fleet page's list (roadmap 2.6): every printer's state, supplies, pages, firmware and last reading, most trouble first, and its CSV and JSON.</summary>
public class FleetTests
{
    private static readonly DateTimeOffset Now = new(2026, 10, 31, 12, 0, 0, TimeSpan.Zero);
    private static readonly Diagnostics.Identity Me = new("jdoe", "JDOE-LAPTOP");

    private static Consumable Supply(string name, int? level, string state = "ok", string? color = "K", string kind = "toner") =>
        new(name, kind, color, level, state, null, null, null, null, null);

    private static PrinterStatus Status(string message, Severity severity = Severity.Info, params PrinterAlert[] alerts) => new("x", message, severity, alerts);

    private static FleetPrinter Printer(string name, bool reachable = true, PrinterStatus? status = null, IEnumerable<Consumable>? supplies = null,
        int? pages = null, string? firmware = null, DateTimeOffset? read = null, FleetKind kind = FleetKind.Network) =>
        FleetPrinter.Of(new FleetFacts(name, name, kind)
        {
            Reachable = reachable, Status = status ?? Status("Ready"), Supplies = supplies?.ToList() ?? [], Pages = pages, Firmware = firmware, LastReading = read,
        });

    // ------------------------------------------------------------------ trouble and order

    [Theory]
    [InlineData(Severity.Error, FleetTrouble.Error)]
    [InlineData(Severity.Warning, FleetTrouble.Warning)]
    [InlineData(Severity.Info, FleetTrouble.Ok)]
    public void The_status_sets_the_trouble(Severity severity, FleetTrouble expected) =>
        Assert.Equal(expected, Printer("P", status: Status("Words", severity)).Trouble);

    [Fact]
    public void A_low_supply_is_a_warning_and_an_empty_one_an_error_on_a_printer_that_says_ready()
    {
        Assert.Equal(FleetTrouble.Warning, Printer("P", supplies: [Supply("Black", 8, "low")]).Trouble);
        Assert.Equal(FleetTrouble.Error, Printer("P", supplies: [Supply("Black", 0, "out")]).Trouble);
        Assert.Equal(FleetTrouble.Error, Printer("P", supplies: [Supply("Waste", null, "full", null, "wasteToner")]).Trouble);
        Assert.Equal(FleetTrouble.Ok, Printer("P", supplies: [Supply("Black", 80)]).Trouble);
    }

    [Fact]
    public void A_printer_that_doesnt_answer_is_offline_whatever_its_last_supplies_said()
    {
        var p = Printer("P", reachable: false, status: Status("Can't reach the printer", Severity.Error), supplies: [Supply("Black", 0, "out")]);
        Assert.Equal(FleetTrouble.Offline, p.Trouble);
    }

    [Fact]
    public void A_reply_with_no_usable_status_is_unknown_not_fine()
    {
        var p = FleetPrinter.Of(new FleetFacts("P", "P", FleetKind.Network) { Reachable = true, Status = PrinterStatus.Unavailable("Busy") });
        Assert.Equal(FleetTrouble.Unknown, p.Trouble);
    }

    [Fact]
    public void Sorted_by_trouble_as_the_tray_ranks_it_then_by_name()
    {
        var sorted = FleetOrder.Sort(
        [
            Printer("zeta fine"), Printer("Beta low", supplies: [Supply("Black", 5, "low")]),
            Printer("Off", reachable: false), Printer("Jam", status: Status("Paper jam", Severity.Error)),
            FleetPrinter.Of(new FleetFacts("U", "Unknown", FleetKind.Network) { Reachable = true, Status = PrinterStatus.Unavailable("Busy") }),
            Printer("alpha low", supplies: [Supply("Black", 5, "low")]), Printer("Alpha fine"),
        ]);
        Assert.Equal(["Jam", "alpha low", "Beta low", "Off", "Unknown", "Alpha fine", "zeta fine"], sorted.Select(p => p.Name));
    }

    [Fact]
    public void Two_printers_of_one_name_keep_one_order()
    {
        var a = FleetPrinter.Of(new FleetFacts("b-id", "Same", FleetKind.Network) { Reachable = true, Status = Status("Ready") });
        var b = FleetPrinter.Of(new FleetFacts("a-id", "Same", FleetKind.Network) { Reachable = true, Status = Status("Ready") });
        Assert.Equal(["a-id", "b-id"], FleetOrder.Sort([a, b]).Select(p => p.Id));
        Assert.Equal(["a-id", "b-id"], FleetOrder.Sort([b, a]).Select(p => p.Id));
    }

    // ------------------------------------------------------------------ what a printer may say

    [Theory]
    [InlineData("Plain", "Plain")]
    [InlineData("  spaced   out \r\n name ", "spaced out name")]
    [InlineData("left\u202Eright\u202C", "leftright")]             // right-to-left override: would turn the line round on screen
    [InlineData("zero\u200Bwidth\uFEFF", "zerowidth")]
    [InlineData("bell\u0007and\u001Bescape", "bellandescape")]
    [InlineData("two\u2028lines", "two lines")]
    public void Printer_supplied_text_loses_what_could_change_how_a_line_reads(string text, string expected) =>
        Assert.Equal(expected, FleetText.Clean(text, 240));

    [Fact]
    public void Printer_supplied_text_is_bounded_and_keeps_surrogate_pairs_whole()
    {
        Assert.Equal(10, FleetText.Clean(new string('x', 5000), 10)!.Length);
        Assert.Equal("xxxxxxxx…", FleetText.Clean("xxxxxxxx😀😀😀", 10)); // 8 + the ellipsis: the pair isn't cut in half
        Assert.Equal("ab", FleetText.Clean("a\uD83Db", 240));              // half a pair goes
        Assert.Null(FleetText.Clean("\u0007\u200B ", 240));
    }

    [Fact]
    public void A_name_of_nothing_still_names_the_printer()
    {
        var p = Printer("\u200B\u0007");
        Assert.False(string.IsNullOrWhiteSpace(p.Name));
    }

    [Fact]
    public void A_printers_lists_and_numbers_are_bounded()
    {
        var p = FleetPrinter.Of(new FleetFacts("P", "P", FleetKind.Network)
        {
            Reachable = true,
            Status = Status("Words", Severity.Warning, [.. Enumerable.Range(0, 100).Select(i => new PrinterAlert($"a{i}", Severity.Warning, $"Alert {i}"))]),
            Supplies = [.. Enumerable.Range(0, 100).Select(i => Supply($"Supply {i}", 50)), Supply("Over", 250), Supply("Under", -3)],
            Pages = -5,
        });
        Assert.Equal(16, p.Problems.Count);
        Assert.Equal(16, p.Supplies.Count);
        Assert.Null(p.Pages);
        var levels = FleetPrinter.Of(new FleetFacts("P", "P", FleetKind.Network) { Reachable = true, Status = Status("R"), Supplies = [Supply("Over", 250), Supply("Under", -3)] });
        Assert.Equal([100, null], levels.Supplies.Select(s => s.Level));
    }

    [Fact]
    public void Information_alerts_arent_problems()
    {
        var p = Printer("P", status: Status("Ready", Severity.Warning, new PrinterAlert("a", Severity.Info, "Genuine HP supply"), new PrinterAlert("b", Severity.Warning, "Tray 2 is low on paper")));
        Assert.Equal(["Tray 2 is low on paper"], p.Problems);
    }

    // ------------------------------------------------------------------ CSV

    [Theory]
    [InlineData("=HYPERLINK(\"http://x\")")]
    [InlineData("+1+1")]
    [InlineData("-2+3")]
    [InlineData("@SUM(A1)")]
    [InlineData("\t=1+1")]
    [InlineData("\r=1+1")]
    [InlineData(" =1+1")]
    [InlineData("\u200B=1+1")]
    [InlineData("\uFF1D1+1")] // fullwidth =, which some spreadsheets take for one
    [InlineData("\uFF0B1")]
    [InlineData("\uFF0D1")]
    [InlineData("\uFF201")]
    public void Nothing_a_printer_says_reaches_a_spreadsheet_as_a_formula(string evil)
    {
        var printer = FleetPrinter.Of(new FleetFacts("P", evil, FleetKind.Network)
        {
            Model = evil,
            Reachable = true,
            Status = new PrinterStatus("error", evil, Severity.Error, [new PrinterAlert("a", Severity.Error, evil)]),
            Supplies = [Supply(evil, 50, color: evil)],
            Firmware = evil,
        });

        var csv = FleetExport.Csv([printer], Now, Me);

        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal(2, lines.Length);
        foreach (var cell in Cells(lines[1]))
            Assert.False(cell.Length > 0 && "=+-@\t\r\n\uFF1D\uFF0B\uFF0D\uFF20".Contains(cell[0]) && !IsNumber(cell), $"A formula's start: {cell}");
    }

    private static bool IsNumber(string cell) => int.TryParse(cell, out _);

    /// <summary>RFC 4180's cells of one line.</summary>
    private static List<string> Cells(string line)
    {
        var cells = new List<string>();
        var cell = new System.Text.StringBuilder();
        var quoted = false;
        for (var i = 0; i < line.Length; i++)
        {
            var c = line[i];
            if (quoted && c == '"' && i + 1 < line.Length && line[i + 1] == '"') { cell.Append('"'); i++; }
            else if (c == '"') quoted = !quoted;
            else if (c == ',' && !quoted) { cells.Add(cell.ToString()); cell.Clear(); }
            else cell.Append(c);
        }
        cells.Add(cell.ToString());
        return cells;
    }

    [Fact]
    public void The_csv_has_a_row_per_supply_and_quotes_what_needs_it()
    {
        var csv = FleetExport.Csv(
        [
            Printer("Laser, 2nd \"floor\"", status: Status("Ready"), supplies: [Supply("Black", 42), Supply("Cyan", 7, "low", "C")], pages: 12345, firmware: "2024-08-13", read: Now),
            Printer("USB", kind: FleetKind.Queue),
        ], Now, Me);

        var lines = csv.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert.Equal("Printer,Model,Kind,State,Status,Problems,Supply,Color,Level %,Supply state,Pages printed,Firmware,Last reading", lines[0]);
        Assert.Equal(4, lines.Length);
        var cells = Cells(lines[1]);
        Assert.Equal("Laser, 2nd \"floor\"", cells[0]);
        Assert.Equal(["warning", "Black", "K", "42", "ok", "12345", "2024-08-13", "2026-10-31T12:00:00+00:00"], [cells[3], cells[6], cells[7], cells[8], cells[9], cells[10], cells[11], cells[12]]);
        Assert.Equal("USB", Cells(lines[3])[0]);
        Assert.Equal("", Cells(lines[3])[6]);
    }

    [Fact]
    public void Identifiers_in_names_and_status_strings_stay_out_of_the_csv_and_the_json()
    {
        const string serial = "CNB7K2M9QZ", uuid = "9f8e7d6c-5b4a-4c3d-8e2f-1a0b9c8d7e6f", mac = "a0:b1:c2:d3:e4:f5", ip = "10.20.30.41";
        var printer = FleetPrinter.Of(new FleetFacts(uuid, $"LaserJet {serial} [A1B2C3]", FleetKind.Network)
        {
            Model = $"LaserJet, SN:{serial}, at {ip}",
            Connection = $"LEDM at {ip}",
            Reachable = true,
            Status = new PrinterStatus("error", $"Ask jane.doe@contoso.com at {ip}", Severity.Error,
                [new PrinterAlert("a", Severity.Error, $"Job from JDOE-LAPTOP ({mac}) {uuid}")]),
            Supplies = [Supply($"Black serial {serial}", 50, color: "K"), Supply("Cyan", 50, state: serial, color: serial)],
            Firmware = $"TJP1FN2405AR {uuid}",
        });

        foreach (var text in new[] { FleetExport.Csv([printer], Now, Me), FleetExport.Json([printer], [], Now, Me) })
        {
            foreach (var secret in new[] { serial, uuid, mac, ip, "A1B2C3", "jane.doe", "contoso", "JDOE-LAPTOP" })
                Assert.DoesNotContain(secret, text, StringComparison.OrdinalIgnoreCase);
            Assert.Contains("TJP1FN2405AR", text); // a firmware version stays
        }
    }

    [Theory]
    [InlineData("2.84.1.3-202606111700 (2026-07-24)")] // four numbers: an address, to the scrubber, without the word in front of it
    [InlineData("TJP1FN2405AR")]
    [InlineData("05.12.XA01")]
    [InlineData("2024-08-13")]
    public void A_firmware_version_comes_through_as_the_printer_gave_it(string version)
    {
        var printer = Printer("P", firmware: version);
        Assert.Contains(version, FleetExport.Json([printer], [], Now, Me));
        Assert.Contains(version, FleetExport.Csv([printer], Now, Me));
    }

    // ------------------------------------------------------------------ JSON

    private static JsonElement Schema()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        return JsonDocument.Parse(File.ReadAllText(Path.Combine(dir!.FullName, "print", "schemas", "fleet-status.schema.json"))).RootElement;
    }

    private static IReadOnlyList<string> Validate(string json) => JsonSchemaCheck.Errors(Schema(), JsonDocument.Parse(json).RootElement);

    [Fact]
    public void The_json_validates_against_the_schema_in_the_repository()
    {
        var json = FleetExport.Json(
        [
            Printer("Jam", status: Status("Paper jam", Severity.Error, new PrinterAlert("a", Severity.Error, "Paper jam in tray 2")), read: Now),
            Printer("Laser", supplies: [Supply("Black", 42), Supply("Waste", null, "almostFull", null, "wasteToner")], pages: 12345, firmware: "2024-08-13", read: Now),
            Printer("USB", kind: FleetKind.Queue),
            FleetPrinter.Of(new FleetFacts("S", "Scanner", FleetKind.Scanner) { Reachable = false, Status = Status("Scanner not answering"), LastReadingDay = new DateOnly(2026, 10, 29), LastKnown = true }),
        ], ["Windows' scanners couldn't be read."], Now, Me);

        Assert.Empty(Validate(json));
    }

    [Theory]
    [InlineData("""{"version":2,"generated":"2026-10-31T12:00:00+00:00","notes":[],"printers":[]}""")]            // another version
    [InlineData("""{"version":1,"generated":"yesterday","notes":[],"printers":[]}""")]                           // not a time
    [InlineData("""{"version":1,"generated":"2026-10-31T12:00:00+00:00","notes":[]}""")]                         // printers missing
    [InlineData("""{"version":1,"generated":"2026-10-31T12:00:00+00:00","notes":[],"printers":[],"uuid":"x"}""")] // an extra field
    public void The_schema_check_refuses_what_it_should(string json) => Assert.NotEmpty(Validate(json));

    [Fact]
    public void The_schema_says_no_serial_number_or_uuid_field_exists()
    {
        var names = Schema().GetRawText();
        foreach (var word in new[] { "\"serial", "\"uuid", "\"host", "\"address", "\"mac" })
            Assert.DoesNotContain(word, names, StringComparison.OrdinalIgnoreCase);
    }

    [Fact]
    public void Control_characters_and_lone_surrogates_cant_break_the_json()
    {
        var json = FleetExport.Json([Printer("a\"b\\c\n\u0000\uD83D</script>")], [], Now, Me);

        var doc = JsonDocument.Parse(json);
        Assert.Equal("a\"b\\c </script>", doc.RootElement.GetProperty("printers")[0].GetProperty("name").GetString());
        Assert.All(json, c => Assert.True(c < 128, "ASCII only, so no console code page can spoil it"));
        Assert.Empty(Validate(json));
    }

    // ------------------------------------------------------------------ the page's words

    [Fact]
    public void The_page_says_each_printers_supplies_pages_firmware_and_last_reading()
    {
        var row = FleetPage.Row(Printer("Laser", supplies: [Supply("Black", 42)], pages: 12345, firmware: "2024-08-13", read: Now.AddMinutes(-3)), Now);

        Assert.Equal("Black 42%", Assert.Single(row.Supplies).Text);
        Assert.Equal(42, row.Supplies[0].Level);
        Assert.Contains("12,345", row.PagesText);
        Assert.Equal("Firmware 2024-08-13", row.FirmwareText);
        Assert.Equal("Read 3 minutes ago", row.LastReadText);
        Assert.Contains("Laser", row.AccessibleText);
        Assert.Contains("Black 42%", row.AccessibleText);
        Assert.Contains("12,345", row.AccessibleText);
        Assert.Contains("Firmware 2024-08-13", row.AccessibleText);
        Assert.Contains("3 minutes ago", row.AccessibleText);
    }

    [Fact]
    public void The_page_says_what_a_printer_doesnt_report_rather_than_leaving_a_gap()
    {
        var row = FleetPage.Row(Printer("USB", reachable: false, status: Status("Offline")), Now);

        Assert.Equal("Pages not reported", row.PagesText);
        Assert.Equal("Firmware not reported", row.FirmwareText);
        Assert.Equal("Not read yet", row.LastReadText);
        Assert.Equal("Supplies not reported", row.NoSuppliesText);
    }

    [Theory]
    [InlineData(0, "Read just now")]
    [InlineData(59, "Read just now")]
    [InlineData(60, "Read 1 minute ago")]
    [InlineData(45 * 60, "Read 45 minutes ago")]
    [InlineData(61 * 60, "Read 1 hour ago")]
    [InlineData(5 * 3600, "Read 5 hours ago")]
    public void The_last_reading_reads_as_time_ago(int seconds, string expected) =>
        Assert.Equal(expected, FleetPage.Row(Printer("P", read: Now.AddSeconds(-seconds)), Now).LastReadText);

    [Fact]
    public void A_clock_put_back_doesnt_say_minus_minutes() =>
        Assert.Equal("Read just now", FleetPage.Row(Printer("P", read: Now.AddHours(2)), Now).LastReadText);

    [Fact]
    public void A_reading_from_days_ago_gives_its_day()
    {
        var day = FleetPrinter.Of(new FleetFacts("P", "P", FleetKind.Network) { Reachable = false, Status = Status("Off"), LastReadingDay = new DateOnly(2026, 10, 29), LastKnown = true });
        Assert.StartsWith("Last read ", FleetPage.Row(day, Now).LastReadText);
        Assert.Contains("2026", FleetPage.Row(day, Now).LastReadText);
    }

    [Fact]
    public void The_summary_counts_the_trouble()
    {
        Assert.Equal("3 printers: 1 with an error, 1 needing attention, 1 fine.", FleetPage.Summary(
        [
            Printer("A", status: Status("Jam", Severity.Error)), Printer("B", status: Status("Low", Severity.Warning)), Printer("C"),
        ]));
        Assert.Equal("1 printer: 1 can't be reached.", FleetPage.Summary([Printer("A", reachable: false)]));
        Assert.Equal("No printers yet.", FleetPage.Summary([]));
    }

    [Fact]
    public void The_command_palette_offers_the_page() =>
        Assert.Contains(PrintPalette.Build(null, -1, [], []), e => e.Id == "app:fleet");

    // ------------------------------------------------------------------ what status --all reads from the state file

    [Fact]
    public void The_state_file_gives_what_a_read_without_the_app_needs()
    {
        var read = InkvoltPrinters.Parse("""
            {
              "Printers": [{ "Uuid": "p", "Name": "Laser", "Host": "192.0.2.10", "IppUri": "ipp://192.0.2.10/ipp/print",
                             "Snmp": { "SerialNumber": "S1", "Model": "M", "SystemName": "N" } }],
              "AcceptedUuids": { "p": ["other"] },
              "Firmware": { "p": { "Version": "2024-08-13", "Since": "2025-01-01" } },
              "ForgottenUuids": ["windows-queue:old"],
              "ProKey": "KEY"
            }
            """);

        var p = Assert.Single(read.Printers);
        Assert.Equal("ipp://192.0.2.10/ipp/print", p.IppUri!.OriginalString);
        Assert.Equal(new SnmpDevice("S1", "M", "N"), p.Snmp);
        Assert.Equal(["other"], p.AcceptedUuids);
        Assert.Equal("2024-08-13", p.Firmware);
        Assert.Equal(["windows-queue:old"], read.Forgotten);
        Assert.Equal("KEY", read.ProKey);
    }

    [Fact]
    public void A_state_file_from_before_these_fields_still_reads()
    {
        var p = Assert.Single(InkvoltPrinters.Parse("""{ "Printers": [{ "Uuid": "p", "Name": "Laser", "Host": "192.0.2.10", "Snmp": null }], "Firmware": 7, "AcceptedUuids": [] }""").Printers);
        Assert.Null(p.Snmp);
        Assert.Null(p.Firmware);
        Assert.Empty(p.AcceptedUuids);
    }

    // ------------------------------------------------------------------ last known, from the supply history

    [Fact]
    public void The_supply_history_gives_a_silent_printers_last_levels_day_and_page_count()
    {
        var store = new SupplyHistoryStore(null);
        store.Record("p", [Supply("Black", 80)], 100, new DateOnly(2026, 10, 20));
        store.Record("p", [Supply("Black", 70), Supply("Cyan", 60, color: "C")], 200, new DateOnly(2026, 10, 29));

        var known = FleetLastKnown.From(store.Rows("p"));

        Assert.Equal(new DateOnly(2026, 10, 29), known!.Day);
        Assert.Equal(200, known.Pages);
        Assert.Equal(["Black 70", "Cyan 60"], known.Supplies.Select(s => $"{s.Name} {s.PercentRemaining}"));
        Assert.Null(FleetLastKnown.From([]));
    }

    [Fact]
    public void A_cartridge_taken_out_days_ago_isnt_listed_as_there_now()
    {
        var store = new SupplyHistoryStore(null);
        store.Record("p", [Supply("Old", 80), Supply("Black", 80)], null, new DateOnly(2026, 10, 20));
        store.Record("p", [Supply("Black", 70)], null, new DateOnly(2026, 10, 29));

        Assert.Equal(["Black"], FleetLastKnown.From(store.Rows("p"))!.Supplies.Select(s => s.Name));
    }
}
