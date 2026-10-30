using System.Net;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;

namespace InkvoltPrint.Tests;

/// <summary>
/// Firmware watch (roadmap 1.5): the version remembered per printer, a change noticed once and alerted once, and "Keep my
/// cartridges working", whose write is the Firmware card's own Off write. No request here reaches a printer: the LEDM side
/// runs against the M234dw's captured documents in memory.
/// </summary>
public sealed class FirmwareWatchTests
{
    private const string Printer = "12345678-1234-4abc-8def-123456789abc";
    private static readonly DateOnly Day0 = new(2026, 10, 1);

    /// <summary>The M234dw's own firmware reading, with the revision a firmware update would bring.</summary>
    private static string VersionFromFixture(string? revision)
    {
        var product = LedmParsers.ParseProductConfig(Fixture.Xml("DevMgmt_ProductConfigDyn.xml"));
        return FirmwareInfo.From(revision is null ? product : product with { FirmwareRevision = revision }, null)!.Display;
    }

    // ---------------------------------------------------------------- the record

    [Fact]
    public void The_first_version_seen_is_remembered_with_its_day_and_is_no_change()
    {
        var record = FirmwareWatch.Observe(null, "2024-08-13", Day0);

        Assert.Equal(new FirmwareRecord("2024-08-13", Day0), record);
        Assert.Null(FirmwareWatch.Notice(record, Day0));
    }

    [Fact]
    public void The_same_version_again_keeps_the_record_as_it_was()
    {
        var record = FirmwareWatch.Observe(null, "2024-08-13", Day0);

        Assert.Same(record, FirmwareWatch.Observe(record, "2024-08-13", Day0.AddDays(40)));
        Assert.Same(record, FirmwareWatch.Observe(record, null, Day0.AddDays(41))); // not read this time: tells nothing
        Assert.Same(record, FirmwareWatch.Observe(record, "  ", Day0.AddDays(42)));
    }

    [Fact]
    public void A_new_version_is_a_change_in_plain_words()
    {
        var record = FirmwareWatch.Observe(FirmwareWatch.Observe(null, "05.12.XA01", Day0), "05.14.XB02", Day0.AddDays(11));

        var notice = FirmwareWatch.Notice(record, Day0.AddDays(11))!;

        Assert.Equal(new FirmwareChange("05.12.XA01", "05.14.XB02", Day0.AddDays(11)), notice);
        Assert.Equal($"Firmware changed from 05.12.XA01 to 05.14.XB02 on {Day0.AddDays(11):d MMMM yyyy}.", notice.Text);
    }

    [Fact]
    public void The_notice_goes_after_thirty_days_or_when_dismissed()
    {
        var record = FirmwareWatch.Observe(FirmwareWatch.Observe(null, "A", Day0), "B", Day0.AddDays(1))!;

        Assert.NotNull(FirmwareWatch.Notice(record, Day0.AddDays(FirmwareWatch.NoticeDays)));
        Assert.Null(FirmwareWatch.Notice(record, Day0.AddDays(1 + FirmwareWatch.NoticeDays)));
        Assert.Null(FirmwareWatch.Notice(record with { Dismissed = true }, Day0.AddDays(2)));
    }

    [Fact]
    public void A_dismissed_change_stays_dismissed_until_the_next_change()
    {
        var dismissed = FirmwareWatch.Observe(FirmwareWatch.Observe(null, "A", Day0), "B", Day0.AddDays(1))! with { Dismissed = true };

        Assert.Same(dismissed, FirmwareWatch.Observe(dismissed, "B", Day0.AddDays(2)));
        var next = FirmwareWatch.Observe(dismissed, "C", Day0.AddDays(3));
        Assert.Equal(new FirmwareChange("B", "C", Day0.AddDays(3)), FirmwareWatch.Notice(next, Day0.AddDays(3)));
    }

    [Fact]
    public void What_a_printer_reports_is_cleaned_before_it_is_kept()
    {
        var record = FirmwareWatch.Observe(null, " 1.0\r\n" + new string('9', 200), Day0)!;

        Assert.DoesNotContain('\n', record.Version);
        Assert.Equal(80, record.Version.Length);
    }

    // ---------------------------------------------------------------- readings → one notice, one alert

    [Fact]
    public void Fixture_readings_with_a_version_change_give_one_notice_and_one_alert_never_again_for_that_change()
    {
        string old = VersionFromFixture(null), updated = VersionFromFixture("SAYPRO1N002.2101A");
        var readings = new[] { old, old, updated, updated, updated, updated };
        var tracker = new AlertTracker(new AlertRules());
        FirmwareRecord? record = null;
        var notices = new List<FirmwareChange>();
        var alerts = new List<AlertNotice>();
        var now = new DateTimeOffset(2026, 10, 1, 9, 0, 0, TimeSpan.Zero);

        for (var i = 0; i < readings.Length; i++)
        {
            var day = Day0.AddDays(i);
            var before = record;
            record = FirmwareWatch.Observe(record, readings[i], day);
            if (!ReferenceEquals(before, record) && FirmwareWatch.Notice(record, day) is { } change) notices.Add(change);
            alerts.AddRange(tracker.Observe(Snapshot(FirmwareWatch.Notice(record, day)), now.AddDays(i)));
        }

        var notice = Assert.Single(notices);
        Assert.Equal((old, updated), (notice.From, notice.To));
        var alert = Assert.Single(alerts);
        Assert.Equal(AlertKind.FirmwareChanged, alert.Kind);
        Assert.Equal("Office laser: firmware changed", alert.Title);
        Assert.StartsWith(notice.Text, alert.Body);

        // Started again (the alerts shown are kept across restarts): the same change isn't told again.
        var again = new AlertTracker(new AlertRules(), tracker.Shown());
        Assert.Empty(again.Observe(Snapshot(FirmwareWatch.Notice(record, Day0.AddDays(6))), now.AddDays(6)));
    }

    [Fact]
    public void A_firmware_change_is_news_not_a_problem_for_the_tray()
    {
        var tracker = new AlertTracker(new AlertRules());

        tracker.Observe(Snapshot(new FirmwareChange("A", "B", Day0)), DateTimeOffset.Now);

        Assert.Equal(AlertLevel.Ok, tracker.Level(Printer));
        Assert.Null(tracker.Problem(Printer));
    }

    [Fact]
    public void With_alerts_off_or_paused_the_change_isnt_told_later()
    {
        var tracker = new AlertTracker(new AlertRules { Enabled = false });
        var now = DateTimeOffset.Now;
        Assert.Empty(tracker.Observe(Snapshot(new FirmwareChange("A", "B", Day0)), now));

        tracker.Rules = new AlertRules();
        Assert.Empty(tracker.Observe(Snapshot(new FirmwareChange("A", "B", Day0)), now.AddMinutes(5)));
    }

    [Fact]
    public void An_unreachable_printer_keeps_the_change_known()
    {
        var tracker = new AlertTracker(new AlertRules());
        var now = DateTimeOffset.Now;
        Assert.Single(tracker.Observe(Snapshot(new FirmwareChange("A", "B", Day0)), now));

        tracker.Observe(new PrinterSnapshot(Printer, "Office laser", false, null, null), now.AddMinutes(1));

        Assert.DoesNotContain(tracker.Observe(Snapshot(new FirmwareChange("A", "B", Day0)), now.AddMinutes(2)),
            n => n.Kind == AlertKind.FirmwareChanged);
    }

    private static PrinterSnapshot Snapshot(FirmwareChange? change) =>
        new(Printer, "Office laser", true, new PrinterStatus("ready", "Ready", Severity.Info, []), []) { FirmwareChange = change };

    // ---------------------------------------------------------------- Keep my cartridges working

    [Fact]
    public async Task Keep_my_cartridges_working_writes_the_firmware_cards_off_byte_for_byte_and_reads_it_back()
    {
        var settingsWrite = new FakeHp(FirmwareUpdateMode.Automatic);
        using (var http = settingsWrite.Http())
        {
            var ledm = new LedmClient(http);
            var fw = (await ledm.GetFirmwareUpdateAsync())!;
            await ledm.PutPathAsync(fw.ConfigPath!, fw.BuildPut(FirmwareUpdateMode.Off)); // the Firmware card saving Off
        }

        var guarded = new FakeHp(FirmwareUpdateMode.Automatic);
        CartridgeGuardResult result;
        using (var http = guarded.Http())
        {
            var ledm = new LedmClient(http);
            result = await CartridgeGuard.KeepCartridgesWorkingAsync(ledm, (await ledm.GetFirmwareUpdateAsync())!, put => put());
        }

        var write = Assert.Single(guarded.Writes);
        Assert.Equal(Assert.Single(settingsWrite.Writes), write);
        Assert.Equal(("https", "/FirmwareUpdate/WebFWUpdate/Config"), (write.Scheme, write.Path));
        var sent = XDocument.Parse(write.Body);
        Assert.Equal(["disabled", "disabled"], sent.Root!.Elements().Select(e => e.Value));
        Assert.Equal(CartridgeGuardOutcome.Done, result.Outcome);
        Assert.Equal(FirmwareUpdateMode.Off, result.ReadBack);
        Assert.StartsWith("Done: automatic firmware updates are off", result.Text);
    }

    [Fact]
    public async Task Already_off_writes_nothing()
    {
        var printer = new FakeHp(FirmwareUpdateMode.Off);
        using var http = printer.Http();
        var ledm = new LedmClient(http);

        var result = await CartridgeGuard.KeepCartridgesWorkingAsync(ledm, (await ledm.GetFirmwareUpdateAsync())!, put => put());

        Assert.Equal(CartridgeGuardOutcome.AlreadyOff, result.Outcome);
        Assert.Empty(printer.Writes);
    }

    [Fact]
    public async Task A_printer_that_wont_let_apps_change_it_gets_its_web_page_named_and_nothing_written()
    {
        var printer = new FakeHp(FirmwareUpdateMode.Automatic, readOnly: true);
        using var http = printer.Http();
        var ledm = new LedmClient(http);

        var result = await CartridgeGuard.KeepCartridgesWorkingAsync(ledm, (await ledm.GetFirmwareUpdateAsync())!, put => put());

        Assert.Equal(CartridgeGuardOutcome.CantChange, result.Outcome);
        Assert.Contains("web page", result.Text);
        Assert.Empty(printer.Writes);
    }

    [Fact]
    public async Task A_printer_that_keeps_installing_is_reported_as_it_reads_back()
    {
        var printer = new FakeHp(FirmwareUpdateMode.Automatic) { IgnoresWrites = true };
        using var http = printer.Http();
        var ledm = new LedmClient(http);

        var result = await CartridgeGuard.KeepCartridgesWorkingAsync(ledm, (await ledm.GetFirmwareUpdateAsync())!, put => put());

        Assert.Equal(CartridgeGuardOutcome.NotKept, result.Outcome);
        Assert.Equal(FirmwareUpdateMode.Automatic, result.ReadBack);
        Assert.Contains("\"install automatically\"", result.Text);
    }

    [Fact]
    public async Task The_write_goes_through_the_password_step()
    {
        var printer = new FakeHp(FirmwareUpdateMode.Notify) { WantsPassword = true };
        using var http = printer.Http();
        var ledm = new LedmClient(http);
        var asked = 0;

        var result = await CartridgeGuard.KeepCartridgesWorkingAsync(ledm, (await ledm.GetFirmwareUpdateAsync())!, async put =>
        {
            try { await put(); }
            catch (LedmAuthRequiredException)
            {
                asked++;
                printer.WantsPassword = false; // the password was given
                await put();
            }
        });

        Assert.Equal(1, asked);
        Assert.Equal(CartridgeGuardOutcome.Done, result.Outcome);
    }

    /// <summary>
    /// The M234dw's captured LEDM documents with its firmware update mode set to <paramref name="mode"/>: GETs answered from
    /// them, a PUT to the Config remembered (and taken in, unless <see cref="IgnoresWrites"/>). Nothing leaves the process.
    /// </summary>
    private sealed class FakeHp(FirmwareUpdateMode mode, bool readOnly = false) : HttpMessageHandler
    {
        private static readonly XNamespace Fwu = "http://www.hp.com/schemas/imaging/con/ledm/firmwareupdatedyn/2010/12/12";
        private FirmwareUpdateMode _mode = mode;

        public List<(string Scheme, string Path, string Body)> Writes { get; } = [];
        public bool IgnoresWrites { get; init; }
        public bool WantsPassword { get; set; }

        public DeviceHttp Http() => new(FixtureHandler.DemoHost, this);

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var path = request.RequestUri!.AbsolutePath;
            if (request.Method == HttpMethod.Put)
            {
                if (WantsPassword) return new HttpResponseMessage(HttpStatusCode.Unauthorized) { RequestMessage = request };
                var body = await request.Content!.ReadAsStringAsync(ct);
                Writes.Add((request.RequestUri.Scheme, path, body));
                if (!IgnoresWrites)
                {
                    var sent = XDocument.Parse(body).Root!;
                    var update = sent.Elements().FirstOrDefault(e => e.Name.LocalName == "AutomaticUpdate")?.Value;
                    var check = sent.Elements().FirstOrDefault(e => e.Name.LocalName == "AutomaticCheck")?.Value;
                    _mode = update == "enabled" ? FirmwareUpdateMode.Automatic : check == "enabled" ? FirmwareUpdateMode.Notify : FirmwareUpdateMode.Off;
                }
                return new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request };
            }
            var name = FixtureHandler.DocumentName(path);
            var file = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
            if (!File.Exists(file)) return new HttpResponseMessage(HttpStatusCode.NotFound) { RequestMessage = request };
            var doc = XDocument.Load(file);
            if (name == "FirmwareUpdate_FirmwareUpdateDyn.xml")
            {
                doc.Descendants(Fwu + "AutomaticCheck").Single().Value = _mode == FirmwareUpdateMode.Off ? "disabled" : "enabled";
                doc.Descendants(Fwu + "AutomaticUpdate").Single().Value = _mode == FirmwareUpdateMode.Automatic ? "enabled" : "disabled";
            }
            if (name == "FirmwareUpdate_FirmwareUpdateCap.xml" && readOnly)
                foreach (var support in doc.Descendants().Where(e => e.Name.LocalName.EndsWith("Support", StringComparison.Ordinal)))
                    support.SetAttributeValue("access", "readOnly");
            return new HttpResponseMessage(HttpStatusCode.OK)
            {
                RequestMessage = request,
                Content = new ByteArrayContent(Encoding.UTF8.GetBytes(doc.ToString())) { Headers = { ContentType = new("text/xml") } },
            };
        }
    }
}
