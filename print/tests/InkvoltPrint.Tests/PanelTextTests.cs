using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// The front panel's text in the printer's status: the Printer MIB's prtConsoleDisplayBufferText lines, IPP's
/// <c>printer-state-message</c>, LEDM's status text; shown only when it says more than the status line, as one clean, short line.
/// </summary>
public class PanelTextTests
{
    private static string Walk(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", name));

    private static PrinterStatus Status(string message, string? panel) => new("ready", message, Severity.Info, []) { PanelText = panel };

    [Theory]
    [InlineData("Ready", "Order magenta toner", "Order magenta toner")]
    [InlineData("Ready", "Ready", null)] // says nothing more
    [InlineData("Ready", "ready.", null)]
    [InlineData("Ready", "Idle.", null)] // a plain "Idle" under the app's own word for it
    [InlineData("Sleeping", "Sleep mode is on.", "Sleep mode is on")]
    [InlineData("Ready", "  ", null)]
    [InlineData("Ready", null, null)]
    [InlineData("Ready", "Tray 2\r\nLoad A4\tplain", "Tray 2 Load A4 plain")] // one line
    [InlineData("Ready", "‮regnad‬ ok", "regnad ok")] // no right-to-left override turning it round
    public void The_panel_s_text_shows_when_it_says_more_than_the_status(string message, string? panel, string? shown) =>
        Assert.Equal(shown, Status(message, panel).PanelNote);

    [Fact]
    public void A_long_panel_text_is_cut_to_one_line()
    {
        var note = Status("Ready", new string('x', 10_000)).PanelNote!;
        Assert.True(note.Length <= PrinterStatus.MaxPanelText, $"{note.Length}");
        Assert.EndsWith("…", note);
    }

    [Fact]
    public async Task SNMP_reads_the_panel_s_lines()
    {
        var mfp = await SnmpPrinterClient.ProbeAsync(new SnmpAgent(SnmpAgent.ParseWalk(Walk("color-mfp.txt"))), "192.0.2.15");
        var status = await mfp!.GetStatusAsync();
        Assert.Equal("Ready · Order magenta toner", status.PanelText);
        Assert.Equal("Ready · Order magenta toner", status.PanelNote);

        var laser = await SnmpPrinterClient.ProbeAsync(new SnmpAgent(SnmpAgent.ParseWalk(Walk("workgroup-laser.txt"))), "192.0.2.14");
        var ready = await laser!.GetStatusAsync();
        Assert.Equal(("Ready", null), (ready.PanelText, ready.PanelNote)); // the panel says "Ready" too
    }

    [Fact]
    public async Task A_panel_of_hundreds_of_lines_keeps_the_first_few_with_words()
    {
        var lines = string.Concat(Enumerable.Range(1, 300).Select(i => $".1.3.6.1.2.1.43.16.5.1.2.1.{i} = STRING: \"{(i % 2 == 0 ? $"Line {i}" : " ")}\"\n"));
        var printer = await SnmpPrinterClient.ProbeAsync(new SnmpAgent(SnmpAgent.ParseWalk(Walk("workgroup-laser.txt").Replace(
            ".1.3.6.1.2.1.43.16.5.1.2.1.1 = STRING: \"Ready\"\n", lines).Replace(".1.3.6.1.2.1.43.16.5.1.2.1.1 = STRING: \"Ready\"\r\n", lines))), "192.0.2.14");
        var reading = await printer!.ReadAsync();
        Assert.Equal(SnmpReading.MaxPanelLines, reading.Panel.Count);
        Assert.Equal("Line 2", reading.Panel[0]); // the blank lines are left out
    }

    [Fact]
    public void IPP_s_state_message_is_the_panel_s_text()
    {
        var r = IppCodec.Decode(IppCodec.EncodeResponse(0, 1, IppText.Parse("printer-state enum 3\nprinter-state-message text Ready to print, tray 1 low")));
        var status = IppClient.ToStatus(r);
        Assert.Equal("Ready to print, tray 1 low", status.PanelText);
        Assert.Null(status.PanelNote); // already the status line
    }

    [Fact]
    public void LEDM_s_status_text_is_the_panel_s_when_the_status_is_in_the_app_s_words()
    {
        var status = LedmParsers.ParseStatus(Fixture.Xml("DevMgmt_ProductStatusDyn.xml")); // inPowerSave, "Sleep mode is on."
        Assert.Equal("Sleep mode is on.", status.PanelText);
        Assert.Equal("Sleep mode is on", status.PanelNote);
    }

    [Fact]
    public async Task The_monitor_shows_the_panel_s_text()
    {
        var demo = new Core.Net.HostRouter(new Dictionary<string, HttpMessageHandler>
        {
            [Core.Net.FixtureHandler.DemoHost] = new Core.Net.FixtureHandler(name =>
                File.Exists(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name))
                    ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name)) : null),
        });
        using var m = new PrinterMonitor(DemoFleet.Laser.Uuid, () => "Laser", new PrinterWhere(DemoFleet.Laser.Host),
            new PrinterRecipe(() => demo, new SnmpRouter(new Dictionary<string, ISnmpTransport>())), () => [], _ => { }, _ => { },
            retryDelay: TimeSpan.FromMilliseconds(50), fallbackRefresh: TimeSpan.FromMilliseconds(200));
        using var cts = new CancellationTokenSource();
        var run = Task.Run(() => m.RunAsync(cts.Token));
        try
        {
            var limit = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(10));
            while (m.View.StatusPanel is null && DateTime.UtcNow < limit) await Task.Delay(10);
            Assert.Equal("Sleep mode is on", m.View.StatusPanel);
        }
        finally
        {
            await cts.CancelAsync();
            await run;
        }
    }
}
