using System.Text;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// The printer session (<see cref="PrinterSession"/>): connecting with one recipe, asking who answers before reading, upgrading
/// an SNMP-only printer, and checking an address the printer is announced at, over fixture printers and a clock of its own.
/// </summary>
public class PrinterSessionTests
{
    private const string Printer = "12345678-1234-4abc-8def-123456789abc", Other = "87654321-4321-4cba-8fed-cba987654321";
    private const string Host = FixtureHandler.DemoHost, NewHost = "192.0.2.23";

    /// <summary>The demo laser (m234dw's fixtures) reporting <see cref="Uuid"/>; every request is recorded.</summary>
    private sealed class Laser
    {
        public string Uuid { get; set; } = Printer;
        public List<string> Seen { get; } = [];

        public FixtureHandler Handler() => new(name =>
        {
            lock (Seen) Seen.Add(name);
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
            if (!File.Exists(path)) return null;
            var bytes = File.ReadAllBytes(path);
            return name is "DevMgmt_ProductConfigDyn.xml" or "eSCL_ScannerCapabilities.xml"
                ? Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(bytes).Replace(Printer, Uuid)) : bytes;
        });
    }

    private sealed class Clock : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = new(2026, 10, 25, 9, 0, 0, TimeSpan.Zero);
        public override DateTimeOffset GetUtcNow() => Now;
    }

    private static HttpMessageHandler NothingOverHttp() => new HostRouter(new Dictionary<string, HttpMessageHandler>());

    private static SnmpAgent Agent(string name) =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", name))));

    private static PrinterSession Session(Func<HttpMessageHandler> transport, Clock clock, List<string>? accepted = null, ISnmpTransport? snmp = null)
    {
        accepted ??= [];
        return new PrinterSession(Printer, new PrinterRecipe(transport, snmp ?? new SnmpRouter(new Dictionary<string, ISnmpTransport>()), Clock: clock),
            () => accepted, accepted.AddRange);
    }

    [Fact]
    public async Task Connects_and_reads_this_printer()
    {
        var laser = new Laser();
        using var session = Session(laser.Handler, new Clock());

        var connected = Assert.IsType<SessionStep.Connected>(await session.ConnectAsync(new PrinterWhere(Host), default));
        Assert.Same(connected.Connection, session.Connection);
        var read = Assert.IsType<SessionStep.Read>(await session.ReadAsync(new PrinterWhere(Host), default));
        Assert.Equal("Ready", read.Reading.Status.Message);
    }

    [Fact]
    public async Task Another_device_at_the_address_is_found_before_anything_of_it_is_read()
    {
        var laser = new Laser();
        var clock = new Clock();
        using var session = Session(laser.Handler, clock);
        await session.ConnectAsync(new PrinterWhere(Host), default);

        laser.Uuid = Other; // DHCP gave the address to another device of the same kind
        clock.Now += PrinterSession.IdentityInterval + TimeSpan.FromSeconds(1);
        laser.Seen.Clear();
        var step = await session.ReadAsync(new PrinterWhere(Host), default);

        Assert.Equal([Other], Assert.IsType<SessionStep.Elsewhere>(step).Uuids);
        Assert.Null(session.Connection);
        Assert.DoesNotContain("DevMgmt_ProductStatusDyn.xml", laser.Seen); // its status was never read
    }

    [Fact]
    public async Task Identity_is_asked_every_30_seconds_and_at_once_after_a_pause()
    {
        var laser = new Laser();
        var clock = new Clock();
        using var session = Session(laser.Handler, clock);
        await session.ConnectAsync(new PrinterWhere(Host), default);
        int IdentityReads() => laser.Seen.Count(n => n == "DevMgmt_ProductConfigDyn.xml");

        laser.Seen.Clear();
        await session.ReadAsync(new PrinterWhere(Host), default);
        clock.Now += TimeSpan.FromSeconds(20);
        await session.ReadAsync(new PrinterWhere(Host), default);
        Assert.Equal(0, IdentityReads()); // asked when connecting, a moment ago

        clock.Now += TimeSpan.FromSeconds(15);
        await session.ReadAsync(new PrinterWhere(Host), default);
        Assert.Equal(1, IdentityReads());

        session.AskIdentityFirst(); // the window was hidden: the reused connection is asked first
        await session.ReadAsync(new PrinterWhere(Host), default);
        Assert.Equal(2, IdentityReads());
    }

    [Fact]
    public async Task Connecting_to_another_device_keeps_nothing_and_an_accepted_UUID_counts_as_this_printer()
    {
        var laser = new Laser { Uuid = Other };
        var accepted = new List<string>();
        using var session = Session(laser.Handler, new Clock(), accepted);

        Assert.Equal([Other], Assert.IsType<SessionStep.Elsewhere>(await session.ConnectAsync(new PrinterWhere(Host), default)).Uuids);
        Assert.Null(session.Connection);

        accepted.Add(Other); // "This is my printer"
        Assert.IsType<SessionStep.Connected>(await session.ConnectAsync(new PrinterWhere(Host), default));
    }

    [Fact]
    public async Task An_announced_address_is_followed_only_when_it_is_this_printer_and_a_refusal_is_remembered_a_while()
    {
        var here = new Laser();
        var there = new Laser { Uuid = Other };
        var clock = new Clock();
        HttpMessageHandler Network() => new HostRouter(new Dictionary<string, HttpMessageHandler> { [Host] = here.Handler(), [NewHost] = there.Handler() });
        using var session = Session(Network, clock);
        await session.ConnectAsync(new PrinterWhere(Host), default);

        Assert.Equal(AddressCheck.AnotherDevice, await session.CheckAddressAsync(new PrinterWhere(Host), new PrinterWhere(NewHost), true, null));
        there.Uuid = Printer;
        there.Seen.Clear();
        Assert.Equal(AddressCheck.Skipped, await session.CheckAddressAsync(new PrinterWhere(Host), new PrinterWhere(NewHost), true, null));
        Assert.Empty(there.Seen); // announced again and again: not asked every time

        clock.Now += PrinterSession.RefusedFor;
        Assert.Equal(AddressCheck.Move, await session.CheckAddressAsync(new PrinterWhere(Host), new PrinterWhere(NewHost), true, null));
    }

    [Fact]
    public async Task An_address_that_can_not_tell_is_followed_only_when_the_one_in_use_stops_answering_as_this_printer()
    {
        var here = new Laser();
        HttpMessageHandler Network() => new HostRouter(new Dictionary<string, HttpMessageHandler> { [Host] = here.Handler() });
        using var session = Session(Network, new Clock());
        await session.ConnectAsync(new PrinterWhere(Host), default);

        Assert.Equal(AddressCheck.NoAnswer, await session.CheckAddressAsync(new PrinterWhere(Host), new PrinterWhere(NewHost), true, "HP LaserJet MFP M234dw"));
        using var other = Session(Network, new Clock());
        Assert.Equal(AddressCheck.Move, await other.CheckAddressAsync(new PrinterWhere(Host), new PrinterWhere(NewHost), false, "HP LaserJet MFP M234dw"));
    }

    [Fact]
    public async Task An_SNMP_only_printer_announced_elsewhere_is_told_apart_by_its_serial_number()
    {
        // Before, the other address was probed without SNMP, so an SNMP-only printer there never told who it was.
        var agent = Agent("workgroup-laser.txt");
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, NewHost))!.Identity);
        var snmp = new SnmpRouter(new Dictionary<string, ISnmpTransport> { [NewHost] = agent });
        using var session = Session(NothingOverHttp, new Clock(), snmp: snmp);

        Assert.Equal(AddressCheck.Move, await session.CheckAddressAsync(new PrinterWhere(Host, Snmp: known), new PrinterWhere(NewHost), true, null));
        using var other = Session(NothingOverHttp, new Clock(), snmp: snmp);
        Assert.Equal(AddressCheck.AnotherDevice,
            await other.CheckAddressAsync(new PrinterWhere(Host, Snmp: known with { SerialNumber = "DEMO0004400" }), new PrinterWhere(NewHost), true, null));
    }

    [Fact]
    public async Task An_SNMP_only_printer_is_upgraded_when_it_answers_IPP_and_its_UUID_is_remembered()
    {
        const string host = "192.0.2.11";
        var agent = Agent("color-mfp.txt");
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, host))!.Identity);
        var awake = false;
        HttpMessageHandler Network() => awake
            ? new HostRouter(new Dictionary<string, HttpMessageHandler>
            {
                [host] = new FixtureHandler(name => name == "ipp_print.ipp.txt"
                    ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name)) : null),
            })
            : NothingOverHttp();
        var clock = new Clock();
        var accepted = new List<string>();
        using var session = new PrinterSession(Core.Model.PrinterId.Normalize(null, host), new PrinterRecipe(Network, agent, Clock: clock),
            () => accepted, accepted.AddRange);
        var where = new PrinterWhere(host, Snmp: known);

        Assert.True(Assert.IsType<SessionStep.Connected>(await session.ConnectAsync(where, default)).Connection.OverSnmp);
        awake = true;
        Assert.Null(await session.TryUpgradeAsync(where, default)); // asked again only after a while

        clock.Now += PrinterSession.UpgradeInterval;
        var upgraded = await session.TryUpgradeAsync(where, default);

        Assert.True(upgraded?.Upgraded);
        Assert.Same(upgraded!.Connection, session.Connection);
        Assert.False(session.Connection!.OverSnmp);
        Assert.Equal(["2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b"], accepted);
    }
}
