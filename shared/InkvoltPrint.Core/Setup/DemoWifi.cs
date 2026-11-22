using System.Net;
using System.Text;

namespace InkvoltPrint.Core.Setup;

/// <summary>
/// A made-up Wi-Fi for demo mode and tests (roadmap 4.17): on "Home Wi-Fi" (its saved profile "Home Wi-Fi"), with a new HP printer's open
/// setup network, an Epson's secured Wi-Fi Direct network, a phone's Wi-Fi Direct and a neighbour's in range. Joining one moves this
/// made-up PC onto it (the printer's gives 192.168.223.1, as HP's setup networks do); nothing touches this PC's real Wi-Fi.
/// </summary>
public sealed class DemoWifi : IWifi
{
    public static readonly WifiNetwork Home = Net("Home Wi-Fi", 90, true);
    public static readonly WifiNetwork HpSetup = Net("HP-Setup>5c-DeskJet 4155e", 70, false);
    public static readonly WifiNetwork EpsonDirect = Net("DIRECT-7A-EPSON-ET-2850 Series", 55, true);
    public static readonly WifiNetwork Phone = Net("DIRECT-ab-Galaxy S24", 60, true);
    public static readonly WifiNetwork Neighbour = Net("Neighbour 5G", 30, true);

    private readonly Lock _gate = new();
    private WifiNow _now = new(true, Home.Ssid, "Home Wi-Fi");

    public static WifiNetwork Net(string name, int signal, bool secured) => new(Encoding.UTF8.GetBytes(name), signal, secured);

    public List<WifiNetwork> InRange { get; } = [Home, HpSetup, EpsonDirect, Phone, Neighbour];

    /// <summary>What the made-up PC did, in order (for tests: nothing changes without a call).</summary>
    public List<string> Calls { get; } = [];

    /// <summary>Joining a network fails (the printer's went away; the home profile won't connect).</summary>
    public bool JoinFails { get; set; }

    public bool ReturnFails { get; set; }

    public bool LocationOff { get; set; }

    public bool NoAdapter { get; set; }

    public WifiNow Now
    {
        get { lock (_gate) return _now; }
        set { lock (_gate) _now = value; }
    }

    public Task<WifiNow> NowAsync(CancellationToken ct) => Task.FromResult(NoAdapter ? WifiNow.NoAdapter : Now);

    public Task<IReadOnlyList<WifiNetwork>> NearbyAsync(CancellationToken ct)
    {
        lock (Calls) Calls.Add("scan");
        if (LocationOff) throw new WifiLocationException();
        return Task.FromResult<IReadOnlyList<WifiNetwork>>([.. InRange]);
    }

    public Task ConnectOpenAsync(WifiNetwork network, string profileXml, CancellationToken ct)
    {
        lock (Calls) Calls.Add($"join {network.Name}");
        if (!JoinFails) Now = new WifiNow(true, network.Ssid, null);
        return Task.CompletedTask;
    }

    /// <summary>The person connecting in Windows' own list (a secured network: demo mode and tests do it for them).</summary>
    public void JoinInWindows(WifiNetwork network) => Now = new WifiNow(true, network.Ssid, network.Name);

    public Task ConnectProfileAsync(string profile, CancellationToken ct)
    {
        lock (Calls) Calls.Add($"profile {profile}");
        if (!ReturnFails && profile == "Home Wi-Fi") Now = new WifiNow(true, Home.Ssid, "Home Wi-Fi");
        return Task.CompletedTask;
    }

    public Task DisconnectAsync(CancellationToken ct)
    {
        lock (Calls) Calls.Add("disconnect");
        Now = new WifiNow(true, null, null);
        return Task.CompletedTask;
    }

    public Task<IPAddress?> GatewayAsync(CancellationToken ct) =>
        Task.FromResult(Now.IsOn(HpSetup) || Now.IsOn(EpsonDirect) ? IPAddress.Parse("192.168.223.1") : Now.IsOn(Home) ? IPAddress.Parse("192.168.1.1") : null);
}
