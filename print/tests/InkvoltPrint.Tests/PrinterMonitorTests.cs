using System.Text;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// The printer monitor (<see cref="PrinterMonitor"/>) over demo mode's made-up network (the fixtures on disk, as the app's
/// <c>--demo</c> serves them): coming online, offline and retried, another device at the address and "This is my printer",
/// following an announced address, the notification area's check, the firmware watch. The Mac's PrinterMonitorTests have the
/// same names; the demo printers are <see cref="DemoFleet"/>'s.
/// </summary>
public class PrinterMonitorTests
{
    private static Func<string, byte[]?> Folder(params string[] names) => file =>
    {
        foreach (var name in names)
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", name, file);
            if (File.Exists(path)) return File.ReadAllBytes(path);
        }
        return null;
    };

    private static byte[]? OfficeDocument(string file)
    {
        var bytes = Folder("m234dw", "hp-demo")(file);
        return bytes is null || file is not ("DevMgmt_ProductConfigDyn.xml" or "eSCL_ScannerCapabilities.xml") ? bytes
            : Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace("HP LaserJet MFP M234dw", "Demo office laser").Replace(DemoFleet.LaserUuid, DemoFleet.OfficeUuid));
    }

    /// <summary>The demo network: the app's <c>Demo.CreateTransport</c>, a new one for each connection.</summary>
    private static HttpMessageHandler DemoNetwork() => new HostRouter(new Dictionary<string, HttpMessageHandler>
    {
        [FixtureHandler.DemoHost] = new FixtureHandler(Folder("m234dw", "hp-demo")),
        [DemoFleet.InkjetHost] = new FixtureHandler(Folder("inkjet-demo")),
        [DemoFleet.OfficeNewHost] = new FixtureHandler(OfficeDocument),
        [DemoFleet.CdmHost] = new FixtureHandler(Folder("cdm-laser")),
    });

    private static SnmpAgent Agent(string name) =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", name))));

    /// <summary>The app's <c>Demo.Snmp</c>.</summary>
    private static readonly ISnmpTransport DemoSnmp = new SnmpRouter(new Dictionary<string, ISnmpTransport>
    {
        [DemoFleet.SnmpHost] = Agent("workgroup-laser.txt"),
        [DemoFleet.SnmpQueueHost] = Agent("color-mfp.txt"),
    });

    /// <summary>Everything a monitor told, and the UUIDs accepted for it.</summary>
    private sealed class Log
    {
        private readonly List<MonitorEvent> _events = [];
        public List<string> Accepted { get; } = [];

        public void Add(MonitorEvent e)
        {
            lock (_events) _events.Add(e);
        }

        public IReadOnlyList<MonitorEvent> Events
        {
            get { lock (_events) return _events.ToList(); }
        }

        public IReadOnlyList<PrinterSnapshot> Snapshots => Events.OfType<MonitorEvent.Observed>().Select(o => o.Snapshot).ToList();
        public IReadOnlyList<string> Connections => Events.OfType<MonitorEvent.Connected>().Select(c => c.Connection.Http.Host).ToList();
    }

    private static PrinterMonitor Monitor(InkvoltPrinter printer, Log log, FirmwareMemory? firmware = null, Func<HttpMessageHandler>? transport = null) =>
        new(printer.Uuid, () => printer.Name, new PrinterWhere(printer.Host, printer.EsclRoot, printer.IppUri, printer.Snmp),
            new PrinterRecipe(transport ?? DemoNetwork, DemoSnmp), () => log.Accepted, log.Accepted.AddRange, log.Add, firmware,
            retryDelay: TimeSpan.FromMilliseconds(50), fallbackRefresh: TimeSpan.FromMilliseconds(200));

    /// <summary>Waits (10 s at most, more on CI) for the monitor's view to satisfy <paramref name="done"/>.</summary>
    private static async Task<PrinterView> Until(PrinterMonitor m, Func<PrinterView, bool> done)
    {
        var limit = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(10));
        while (!done(m.View))
        {
            Assert.True(DateTime.UtcNow < limit, $"The monitor never got there: {m.View.StatusMessage}");
            await Task.Delay(10);
        }
        return m.View;
    }

    /// <summary>Runs the monitor until disposed.</summary>
    private sealed class Running : IAsyncDisposable
    {
        private readonly CancellationTokenSource _cts = new();
        private readonly Task _run;

        public Running(PrinterMonitor m) => _run = Task.Run(() => m.RunAsync(_cts.Token));

        public async ValueTask DisposeAsync()
        {
            await _cts.CancelAsync();
            await _run;
            _cts.Dispose();
        }
    }

    [Fact]
    public async Task The_demo_laser_comes_online_with_its_toner_and_says_where_it_is()
    {
        var log = new Log();
        using var m = Monitor(DemoFleet.Laser, log);
        await using (new Running(m))
        {
            var v = await Until(m, v => v.IsOnline);
            Assert.Equal("HP LaserJet MFP M234dw", v.Probe?.Model);
            Assert.Contains("LEDM", v.Probe!.Interfaces);
            Assert.Contains(v.Supplies, s => s.Kind.Contains("toner", StringComparison.OrdinalIgnoreCase));
            Assert.Equal(PrinterStatus.ListLine(v.StatusMessage, v.Severity, v.Alerts), v.ListLine);
            Assert.False(v.IsConnecting);
        }
        Assert.Equal(FixtureHandler.DemoHost, log.Connections[0]);
        Assert.Contains(log.Snapshots, s => s.Reachable && s.Uuid == DemoFleet.LaserUuid && s.Name == "Demo printer");
        // In order: the probe shown, then bound to; the read shown, then its reading, then its snapshot.
        var kinds = log.Events.Select(e => e.GetType().Name).ToList();
        Assert.True(kinds.IndexOf("Connected") < kinds.IndexOf("Read") && kinds.IndexOf("Read") < kinds.IndexOf("Observed"), string.Join(", ", kinds));
    }

    [Fact]
    public async Task Every_demo_printer_reads_over_its_own_interface_and_the_office_laser_is_offline()
    {
        foreach (var printer in DemoFleet.Printers)
        {
            using var m = Monitor(printer, new Log());
            PrinterView v;
            await using (new Running(m))
                v = await Until(m, v => !v.IsConnecting);
            if (printer.Uuid == DemoFleet.OfficeUuid)
            {
                Assert.False(v.IsOnline);
            }
            else
            {
                Assert.True(v.IsOnline, printer.Name);
                Assert.NotEmpty(v.Supplies);
            }
        }
    }

    [Fact]
    public async Task Nothing_answering_is_offline_says_where_and_is_tried_again()
    {
        var log = new Log();
        using var m = Monitor(DemoFleet.Office, log);
        await using (new Running(m))
        {
            var v = await Until(m, v => !v.IsConnecting);
            Assert.False(v.IsOnline);
            Assert.False(v.IsElsewhere);
            Assert.Equal("Can't reach the printer", v.StatusMessage);
            Assert.Contains(DemoFleet.OfficeOldHost, v.StatusDetail);
            Assert.Equal("Can't reach the printer", v.ListLine);
            var limit = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(5));
            while (log.Snapshots.Count < 2 && DateTime.UtcNow < limit) await Task.Delay(10);
        }
        Assert.True(log.Snapshots.Count >= 2);
        Assert.All(log.Snapshots, s => Assert.False(s.Reachable));
        Assert.Empty(log.Connections);
    }

    [Fact]
    public async Task Another_device_at_the_address_shows_nothing_of_it_until_the_user_says_it_is_this_printer()
    {
        var log = new Log();
        var mine = new InkvoltPrinter("87654321-4321-4cba-8fed-cba987654321", "My laser", null, FixtureHandler.DemoHost, null);
        using var m = Monitor(mine, log);
        await using (new Running(m))
        {
            var v = await Until(m, v => v.IsElsewhere && !v.IsConnecting);
            Assert.Empty(v.Supplies);
            Assert.Null(v.Probe);
            Assert.Equal("A different device answers at this address", v.StatusMessage);
            Assert.Contains(FixtureHandler.DemoHost, v.StatusDetail);
            Assert.True(m.CanAcceptDevice);
            Assert.Null(m.Connection); // the session let go of it
        }
        Assert.All(log.Snapshots, s => Assert.False(s.Reachable));
        Assert.Contains(log.Events, e => e is MonitorEvent.Elsewhere);
        Assert.Empty(log.Events.OfType<MonitorEvent.Read>());

        Assert.True(m.AcceptDevice());
        Assert.Contains(DemoFleet.LaserUuid, log.Accepted);
        Assert.False(m.View.IsElsewhere);
        await using (new Running(m))
            Assert.Equal("HP LaserJet MFP M234dw", (await Until(m, v => v.IsOnline)).Probe?.Model);
        Assert.False(m.AcceptDevice()); // none to accept now
    }

    [Fact]
    public async Task Announced_at_a_new_address_it_moves_there_only_when_it_is_this_printer()
    {
        var log = new Log();
        using var m = Monitor(DemoFleet.Office, log);
        await using (new Running(m))
        {
            await Until(m, v => !v.IsConnecting);

            // The demo laser announced under the office laser's UUID: another device answers there.
            Assert.False(await m.AnnouncedAsync(FixtureHandler.DemoHost, null, null, null));
            Assert.Equal(DemoFleet.OfficeOldHost, m.Target.Host);

            Assert.True(await m.AnnouncedAsync(DemoFleet.OfficeNewHost, new Uri($"http://{DemoFleet.OfficeNewHost}/eSCL/"), null, null));
            Assert.Equal(DemoFleet.OfficeNewHost, m.Target.Host);
            Assert.Equal(new Uri($"http://{DemoFleet.OfficeNewHost}/eSCL/"), m.Target.EsclHint);
        }
        Assert.Equal(DemoFleet.OfficeOldHost, Assert.Single(log.Events.OfType<MonitorEvent.Moved>()).From);
        await using (new Running(m))
            Assert.Equal("Demo office laser", (await Until(m, v => v.IsOnline)).Probe?.Model);
        Assert.Equal(DemoFleet.OfficeNewHost, log.Connections[^1]);
    }

    [Fact]
    public async Task Seen_again_at_its_address_while_offline_it_is_asked_at_once()
    {
        using var m = Monitor(DemoFleet.Office, new Log());
        await using (new Running(m))
        {
            await Until(m, v => !v.IsConnecting);
            Assert.True(await m.AnnouncedAsync(DemoFleet.OfficeOldHost, null, new Uri($"ipp://{DemoFleet.OfficeOldHost}/ipp/print"), null));
            Assert.Equal(new Uri($"ipp://{DemoFleet.OfficeOldHost}/ipp/print"), m.Target.IppHint); // its hints are taken
            Assert.False(await m.AnnouncedAsync(null, null, null, null)); // no address: nothing to ask
        }

        using var laser = Monitor(DemoFleet.Laser, new Log());
        await using (new Running(laser))
        {
            await Until(laser, v => v.IsOnline);
            Assert.False(await laser.AnnouncedAsync(FixtureHandler.DemoHost, null, null, null)); // online: no need
        }
    }

    [Fact]
    public async Task A_background_check_reads_once_and_says_whether_the_printer_answered()
    {
        var log = new Log();
        using var laser = Monitor(DemoFleet.Laser, log);
        Assert.True(await laser.CheckAsync(reconnect: false, default));
        Assert.True(laser.View.IsOnline);
        var connection = laser.Connection;
        laser.AskIdentityFirst(); // the window was hidden: asked who it is, then read, on the same connection
        Assert.True(await laser.CheckAsync(reconnect: false, default));
        Assert.Same(connection, laser.Connection);
        Assert.Equal(2, log.Snapshots.Count(s => s.Reachable));
        Assert.True(await laser.CheckAsync(reconnect: true, default)); // moved meanwhile: connected again
        Assert.NotSame(connection, laser.Connection);

        using var office = Monitor(DemoFleet.Office, new Log());
        Assert.False(await office.CheckAsync(reconnect: false, default));
        Assert.False(office.View.IsOnline);
        Assert.Equal("Can't reach the printer", office.View.StatusMessage);
    }

    /// <summary>
    /// The firmware watch (roadmap 1.5) over a kept record, as the app sets it up: the laser had an older version until this
    /// connection, so the view and every reading's snapshot carry the change until it's dismissed; the record says so, and the
    /// next connection shows nothing.
    /// </summary>
    [Fact]
    public async Task A_firmware_change_is_shown_and_in_each_snapshot_until_dismissed()
    {
        FirmwareRecord? kept = new("2023-11-02", new DateOnly(2024, 1, 15));
        var today = new DateOnly(2026, 11, 4);
        var memory = new FirmwareMemory(() => kept, r => kept = r, () => today);
        var log = new Log();
        using var laser = Monitor(DemoFleet.Laser, log, memory);
        Assert.True(await laser.CheckAsync(reconnect: false, default));
        var notice = Assert.IsType<FirmwareChange>(laser.View.FirmwareNotice);
        var version = laser.View.Probe!.Firmware!.Display;
        Assert.Equal(new FirmwareChange("2023-11-02", version, today), notice);
        Assert.Equal(new FirmwareRecord(version, today, Previous: "2023-11-02"), kept);
        Assert.Equal(notice, log.Snapshots[^1].FirmwareChange);

        laser.DismissFirmwareNotice();
        Assert.Null(laser.View.FirmwareNotice);
        Assert.True(kept!.Dismissed);
        Assert.True(await laser.CheckAsync(reconnect: false, default));
        Assert.Null(log.Snapshots[^1].FirmwareChange);

        var next = new Log();
        using var again = Monitor(DemoFleet.Laser, next, memory);
        Assert.True(await again.CheckAsync(reconnect: false, default));
        Assert.True(next.Snapshots[^1].Reachable);
        Assert.Null(next.Snapshots[^1].FirmwareChange);
        Assert.Equal(version, kept!.Version);
    }

    /// <summary>A printer waking up cuts its status and levels short: the card keeps the last good ones, and nothing is alerted.</summary>
    [Fact]
    public async Task A_printer_waking_up_keeps_its_last_status_and_levels_on_the_card()
    {
        var waking = false;
        var laser = Folder("m234dw");
        var log = new Log();
        using var m = Monitor(DemoFleet.Laser, log, transport: () => new FixtureHandler(name =>
            waking && name is "DevMgmt_ProductStatusDyn.xml" or "DevMgmt_ConsumableConfigDyn.xml" ? "<half a rep"u8.ToArray() : laser(name)));
        Assert.True(await m.CheckAsync(reconnect: false, default));
        var shown = m.View;
        Assert.Equal("Ready", shown.StatusMessage);
        Assert.NotEmpty(shown.Supplies);

        waking = true;
        Assert.True(await m.CheckAsync(reconnect: false, default));
        var read = log.Events.OfType<MonitorEvent.Read>().Last().Reading;
        Assert.True(read.Status.IsUnavailable, read.Status.ToString());
        Assert.Null(read.Supplies);
        Assert.True(m.View.IsOnline);
        Assert.Equal("Ready", m.View.StatusMessage);
        Assert.Same(shown.Supplies, m.View.Supplies);
        Assert.Null(log.Snapshots[^1].Status); // nothing to alert on
    }

    /// <summary>The window comes back: a printer online is watched again on its connection, asked who it is before the next read.</summary>
    [Fact]
    public async Task Back_from_the_notification_area_an_online_printer_keeps_its_connection()
    {
        var log = new Log();
        using var m = Monitor(DemoFleet.Laser, log);
        Assert.True(await m.CheckAsync(reconnect: false, default));
        var connection = m.Connection;
        var reads = log.Events.OfType<MonitorEvent.Read>().Count();
        var before = log.Events.Count;
        using (var cts = new CancellationTokenSource())
        {
            var run = Task.Run(() => m.RunAsync(cts.Token, reuse: true));
            var limit = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(10));
            while (log.Events.OfType<MonitorEvent.Read>().Count() == reads && DateTime.UtcNow < limit) await Task.Delay(10);
            await cts.CancelAsync();
            await run;
        }
        Assert.True(log.Events.OfType<MonitorEvent.Read>().Count() > reads);
        Assert.Same(connection, m.Connection);
        Assert.Single(log.Events.OfType<MonitorEvent.Connected>()); // not probed again
        Assert.DoesNotContain(log.Events.Skip(before), e => e is MonitorEvent.Changed { View.IsConnecting: true });
    }
}
