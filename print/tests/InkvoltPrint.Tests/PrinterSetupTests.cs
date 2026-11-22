using System.Net;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Setup;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Setting up a new printer's Wi-Fi (roadmap 4.17) on a made-up Wi-Fi (<see cref="DemoWifi"/>; this PC's is never changed by a test):
/// which networks are a printer's, that nothing changes without a call, that a secured network goes through Windows' own list (no
/// password here), that the printer's page is only a private address it was given, and that the guide always goes back, or says how.
/// </summary>
public class PrinterSetupTests
{
    private static WifiNetwork Net(string name, bool secured = true) => DemoWifi.Net(name, 50, secured);

    [Theory]
    [InlineData("HP-Setup>5c-DeskJet 4155e", "HP", SetupNetworkKind.Setup)]
    [InlineData("HP-Print-2A-Officejet Pro 8710", "HP", SetupNetworkKind.Direct)]
    [InlineData("DIRECT-4F-HP M234 LaserJet", "HP", SetupNetworkKind.Direct)]
    [InlineData("DIRECT-7A-EPSON-ET-2850 Series", "Epson", SetupNetworkKind.Direct)]
    [InlineData("EPSON123ABC", "Epson", SetupNetworkKind.Setup)]
    [InlineData("Canon_ij_A1B2", "Canon", SetupNetworkKind.Setup)]
    [InlineData("SETUP-9C3F", "Brother", SetupNetworkKind.Setup)]
    [InlineData("DIRECT-xyHL-L2350DW_BRa1b2", "Brother", SetupNetworkKind.Direct)]
    [InlineData("DIRECT-12-Xerox B230", "Xerox", SetupNetworkKind.Direct)]
    public void A_printers_network_is_known_by_its_makers_name(string ssid, string maker, SetupNetworkKind kind)
    {
        var found = SetupNetworks.Classify(Net(ssid));
        Assert.NotNull(found);
        Assert.Equal((maker, kind), (found.Maker, found.Kind));
    }

    [Theory]
    [InlineData("DIRECT-ab-Galaxy S24")] // a phone
    [InlineData("DIRECT-Roku-123")] // a TV
    [InlineData("DIRECT-3f-[TV] Samsung 7 Series")] // a TV naming a printer maker further on
    [InlineData("DIRECT-a1-Android_HP")] // a phone
    [InlineData("Home Wi-Fi")]
    [InlineData("HPS-Office")]
    [InlineData("")]
    public void Other_networks_arent(string ssid) => Assert.Null(SetupNetworks.Classify(Net(ssid)));

    [Fact]
    public void Setup_networks_come_first_each_once_and_names_are_shown_safely()
    {
        var weak = DemoWifi.Net("HP-Setup>5c-DeskJet", 20, false);
        var strong = DemoWifi.Net("HP-Setup>5c-DeskJet", 80, false);
        var found = SetupNetworks.Find([DemoWifi.EpsonDirect, weak, strong, DemoWifi.Phone]);
        Assert.Equal(2, found.Count);
        Assert.Equal(SetupNetworkKind.Setup, found[0].Kind);
        Assert.Equal(80, found[0].Network.Signal);
        var hostile = new WifiNetwork([.. "SETUP-‮evil\r\n"u8.ToArray(), 0xFF, 0xFE], 50, false);
        Assert.Equal("SETUP-evil ��", hostile.Name);
        Assert.True(SetupNetworks.Show(new byte[64]).Length == 0);
    }

    [Fact]
    public void Only_an_open_network_gets_a_profile_and_it_holds_no_key()
    {
        Assert.Null(SetupNetworks.OpenProfile(DemoWifi.EpsonDirect));
        var xml = SetupNetworks.OpenProfile(new WifiNetwork(Encoding.UTF8.GetBytes("HP-Setup><&\"x"), 50, false))!;
        var doc = XDocument.Parse(xml); // the name is escaped: still one well-formed profile
        XNamespace ns = "http://www.microsoft.com/networking/WLAN/profile/v1";
        Assert.Equal(Convert.ToHexString(Encoding.UTF8.GetBytes("HP-Setup><&\"x")), doc.Descendants(ns + "hex").Single().Value);
        Assert.Equal("open", doc.Descendants(ns + "authentication").Single().Value);
        Assert.Equal("manual", doc.Descendants(ns + "connectionMode").Single().Value);
        Assert.Empty(doc.Descendants(ns + "sharedKey"));
    }

    [Theory]
    [InlineData("192.168.223.1", "http://192.168.223.1/")]
    [InlineData("10.0.0.1", "http://10.0.0.1/")]
    [InlineData("172.16.4.1", "http://172.16.4.1/")]
    [InlineData("169.254.1.1", "http://169.254.1.1/")]
    [InlineData("8.8.8.8", null)]
    [InlineData("172.32.0.1", null)]
    [InlineData("192.168.1.255", null)]
    [InlineData("fe80::1", null)]
    public void The_printers_page_is_only_a_private_address(string gateway, string? page) =>
        Assert.Equal(page, SetupNetworks.SetupPage(IPAddress.Parse(gateway))?.AbsoluteUri);

    [Fact]
    public async Task Looking_changes_nothing()
    {
        var wifi = new DemoWifi();
        var guide = new PrinterSetupGuide(wifi);
        await guide.LookAsync();
        Assert.Equal(SetupStep.Choose, guide.Step);
        Assert.Equal(["HP", "Epson"], guide.Candidates.Select(c => c.Maker));
        Assert.Equal(["scan"], wifi.Calls);
        Assert.True(wifi.Now.IsOn(DemoWifi.Home));
        Assert.False(guide.IsAway);
    }

    [Fact]
    public async Task An_open_setup_network_is_joined_on_the_click_its_page_found_and_done_goes_home()
    {
        var wifi = new DemoWifi();
        var guide = new PrinterSetupGuide(wifi);
        await guide.LookAsync();
        await guide.ConnectAsync(guide.Candidates[0], () => Assert.Fail("an open network never needs Windows' list"));
        Assert.Equal(SetupStep.OnPrinter, guide.Step);
        Assert.Equal("http://192.168.223.1/", guide.Page?.AbsoluteUri);
        Assert.True(guide.IsAway);
        await guide.ReturnAsync();
        Assert.Equal(SetupStep.Back, guide.Step);
        Assert.True(wifi.Now.IsOn(DemoWifi.Home));
        Assert.Equal(["scan", "join HP-Setup>5c-DeskJet 4155e", "profile Home Wi-Fi"], wifi.Calls);
        Assert.Equal("Home Wi-Fi", guide.HomeName);
        Assert.Null(guide.Page);
    }

    [Fact]
    public async Task A_secured_network_is_joined_in_windows_own_list_never_here()
    {
        var wifi = new DemoWifi();
        var time = new ManualTime();
        var guide = new PrinterSetupGuide(wifi, time: time);
        await guide.LookAsync();
        var opened = 0;
        var connecting = guide.ConnectAsync(guide.Candidates[1], () => opened++);
        await WaitFor(() => guide.Step == SetupStep.InWindows);
        Assert.Equal(1, opened);
        Assert.Contains("DIRECT-7A-EPSON", guide.Problem);
        wifi.JoinInWindows(DemoWifi.EpsonDirect); // the person, in Windows' list
        for (var i = 0; i < 40 && !connecting.IsCompleted; i++)
        {
            time.Advance(TimeSpan.FromSeconds(1));
            await Task.Delay(10);
        }
        await connecting.WaitAsync(Timing.Limit(TimeSpan.FromSeconds(5)));
        Assert.Equal(SetupStep.OnPrinter, guide.Step);
        Assert.DoesNotContain(wifi.Calls, c => c.StartsWith("join", StringComparison.Ordinal)); // nothing joined it here
    }

    [Fact]
    public async Task A_network_never_joined_goes_back_by_itself_and_says_so()
    {
        var wifi = new DemoWifi { JoinFails = true };
        var time = new ManualTime();
        var guide = new PrinterSetupGuide(wifi, time: time);
        await guide.LookAsync();
        var connecting = guide.ConnectAsync(guide.Candidates[0], () => { });
        for (var i = 0; i < 40 && !connecting.IsCompleted; i++)
        {
            time.Advance(TimeSpan.FromSeconds(1));
            await Task.Delay(10);
        }
        await connecting.WaitAsync(Timing.Limit(TimeSpan.FromSeconds(5)));
        Assert.Equal(SetupStep.Back, guide.Step); // never left: already home
        Assert.Equal(CoreStrings.Setup_NotJoined, guide.Problem);
    }

    [Fact]
    public async Task When_it_cant_go_back_it_says_how_and_checks_again()
    {
        var wifi = new DemoWifi { ReturnFails = true };
        var time = new ManualTime();
        var guide = new PrinterSetupGuide(wifi, time: time);
        await guide.LookAsync();
        await guide.ConnectAsync(guide.Candidates[0], () => { });
        var returning = guide.ReturnAsync();
        for (var i = 0; i < 40 && !returning.IsCompleted; i++)
        {
            time.Advance(TimeSpan.FromSeconds(1));
            await Task.Delay(10);
        }
        await returning.WaitAsync(Timing.Limit(TimeSpan.FromSeconds(5)));
        Assert.Equal(SetupStep.CouldNotReturn, guide.Step);
        Assert.Equal(string.Format(CoreStrings.Setup_CouldNotReturn, "Home Wi-Fi"), guide.Problem);
        Assert.True(guide.IsAway);
        wifi.JoinInWindows(DemoWifi.Home); // the person, in Windows' list
        await guide.CheckBackAsync();
        Assert.Equal(SetupStep.Back, guide.Step);
    }

    [Fact]
    public async Task A_pc_that_wasnt_on_wifi_leaves_the_printers_network_again()
    {
        var wifi = new DemoWifi { Now = new WifiNow(true, null, null) };
        var guide = new PrinterSetupGuide(wifi);
        await guide.LookAsync();
        await guide.ConnectAsync(guide.Candidates[0], () => { });
        await guide.ReturnAsync();
        Assert.Equal(SetupStep.Back, guide.Step);
        Assert.Equal("disconnect", wifi.Calls[^1]);
        Assert.False(wifi.Now.Connected);
    }

    [Fact]
    public async Task Cancelling_a_join_goes_back()
    {
        var wifi = new DemoWifi();
        var guide = new PrinterSetupGuide(wifi);
        await guide.LookAsync();
        using var cancel = new CancellationTokenSource();
        var connecting = guide.ConnectAsync(guide.Candidates[1], () => { }, cancel.Token);
        await WaitFor(() => guide.Step == SetupStep.InWindows);
        cancel.Cancel(); // the window closing does this
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => connecting.WaitAsync(Timing.Limit(TimeSpan.FromSeconds(5))));
        Assert.Equal(SetupStep.Back, guide.Step);
        Assert.False(guide.IsAway);
        Assert.True(wifi.Now.IsOn(DemoWifi.Home));
    }

    [Fact]
    public async Task No_wifi_and_location_off_say_what_to_do()
    {
        var none = new PrinterSetupGuide(new DemoWifi { NoAdapter = true });
        await none.LookAsync();
        Assert.Equal((SetupStep.NoWifi, CoreStrings.Setup_NoWifi), (none.Step, none.Problem));
        var off = new PrinterSetupGuide(new DemoWifi { LocationOff = true });
        await off.LookAsync();
        Assert.Equal((SetupStep.LocationOff, CoreStrings.Setup_LocationOff), (off.Step, off.Problem));
        var wifi = new DemoWifi();
        wifi.InRange.RemoveAll(n => SetupNetworks.Classify(n) is not null);
        var empty = new PrinterSetupGuide(wifi);
        await empty.LookAsync();
        Assert.Equal((SetupStep.Choose, CoreStrings.Setup_NoneFound), (empty.Step, empty.Problem));
    }

    [Fact]
    public void The_new_printer_is_one_that_wasnt_listed_before_the_makers_first()
    {
        HashSet<string> before = ["a", "b"];
        Assert.Null(PrinterSetupGuide.FoundPrinter([("a", "Old laser"), ("b", "Old inkjet")], before, "HP"));
        Assert.Equal(("d", "HP DeskJet 4155e"), PrinterSetupGuide.FoundPrinter([("a", "Old laser"), ("c", "Neighbour's Canon"), ("d", "HP DeskJet 4155e")], before, "HP"));
        Assert.Equal(("c", "Neighbour's Canon"), PrinterSetupGuide.FoundPrinter([("c", "Neighbour's Canon")], before, "HP"));
    }

    [Fact]
    public void The_palette_offers_the_guide() =>
        Assert.Contains(PrintPalette.Build(null, -1, [], []), e => e.Id == "app:setupwifi");

    private static async Task WaitFor(Func<bool> condition)
    {
        var until = DateTime.UtcNow + Timing.Limit(TimeSpan.FromSeconds(5));
        while (!condition())
        {
            if (DateTime.UtcNow > until) Assert.Fail("Timed out waiting.");
            await Task.Delay(10);
        }
    }

    private sealed class ManualTime : TimeProvider
    {
        private readonly List<(DateTimeOffset At, Action Fire)> _timers = [];
        private DateTimeOffset _now = new(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);

        public override DateTimeOffset GetUtcNow()
        {
            lock (_timers) return _now;
        }

        public void Advance(TimeSpan by)
        {
            List<Action> due;
            lock (_timers)
            {
                _now += by;
                due = [.. _timers.Where(t => t.At <= _now).Select(t => t.Fire)];
                _timers.RemoveAll(t => t.At <= _now);
            }
            foreach (var fire in due) fire();
        }

        public override ITimer CreateTimer(TimerCallback callback, object? state, TimeSpan dueTime, TimeSpan period)
        {
            var timer = new Timer(this, () => callback(state));
            lock (_timers) _timers.Add((_now + dueTime, timer.Fire));
            return timer;
        }

        private sealed class Timer(ManualTime time, Action fire) : ITimer
        {
            private bool _stopped;

            public void Fire()
            {
                if (!_stopped) fire();
            }

            public bool Change(TimeSpan dueTime, TimeSpan period)
            {
                lock (time._timers) time._timers.Add((time._now + dueTime, Fire));
                return true;
            }

            public void Dispose() => _stopped = true;

            public ValueTask DisposeAsync()
            {
                _stopped = true;
                return ValueTask.CompletedTask;
            }
        }
    }
}
