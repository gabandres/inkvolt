using System.Collections.Concurrent;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Core.Discovery;

/// <summary>An IPv4 network this PC is on: its own address there and the network's prefix length.</summary>
public sealed record LocalNetwork(IPAddress Address, int PrefixLength);

/// <summary>How far a search is: addresses asked so far, of how many.</summary>
public sealed record SearchProgress(int Checked, int Total);

/// <summary>What <see cref="NetworkSearch"/> needs from the network (<see cref="SocketNetworkScanner"/>, or a made-up one).</summary>
public interface INetworkScanner
{
    /// <summary>The networks this PC is on now.</summary>
    IReadOnlyList<LocalNetwork> LocalNetworks();

    /// <summary>Whether <paramref name="host"/> accepts a TCP connection on <paramref name="port"/> within <paramref name="timeout"/>.</summary>
    Task<bool> IsOpenAsync(IPAddress host, int port, TimeSpan timeout, CancellationToken ct);

    /// <summary>Sends each request to UDP port 161 at each broadcast address; <paramref name="answered"/> for each SNMP reply within <paramref name="window"/>.</summary>
    Task BroadcastSnmpAsync(IReadOnlyList<IPAddress> broadcasts, IReadOnlyList<byte[]> requests, TimeSpan window, Action<IPAddress> answered,
        CancellationToken ct);
}

/// <summary>
/// Search my network (Add a printer), for printers that don't announce themselves over mDNS or WSD: one SNMP question to the
/// whole network (an office printer's agent answers it), and every address of this PC's own networks asked whether it takes
/// print jobs (IPP 631, raw 9100, LPD 515). Only private IPv4 networks are searched (RFC 1918: home and office LANs, never a
/// public, link-local or VPN carrier range), a large one only around this PC (its /24). Finds addresses; whether each is a
/// printer, and which, the caller asks it (as for an address typed in).
/// </summary>
public static class NetworkSearch
{
    /// <summary>The ports a printer takes jobs on: IPP, raw (JetDirect), LPD. A web server alone (80, 443) is any device.</summary>
    public static IReadOnlyList<int> PrinterPorts { get; } = [631, 9100, 515];

    /// <summary>A printer on the LAN accepts a connection in a few milliseconds; nothing at an address takes this long to say so.</summary>
    public static readonly TimeSpan ConnectTimeout = TimeSpan.FromMilliseconds(600);

    /// <summary>How long SNMP replies are collected (Windows' firewall lets unicast replies to a broadcast in for 3 s).</summary>
    public static readonly TimeSpan SnmpWindow = TimeSpan.FromSeconds(2);

    // Networks this size or smaller are asked whole (a /22 is 1,022 addresses); a larger one only around this PC.
    private const int WholeNetworkPrefix = 22;
    private const int AroundThisPcPrefix = 24;
    private const int Parallel = 64;

    /// <summary>The addresses to ask on <paramref name="net"/>, in order, without this PC's: none when it isn't worth searching.</summary>
    public static IReadOnlyList<IPAddress> Addresses(LocalNetwork net)
    {
        if (!Searchable(net, out var self)) return [];
        var prefix = net.PrefixLength >= WholeNetworkPrefix ? net.PrefixLength : AroundThisPcPrefix;
        var mask = Mask(prefix);
        var first = (self & mask) + 1;
        var last = (self & mask | ~mask) - 1;
        var hosts = new List<IPAddress>((int)(last - first + 1));
        for (var a = first; a <= last; a++)
            if (a != self) hosts.Add(ToAddress(a));
        return hosts;
    }

    /// <summary>The network's broadcast address (for SNMP), or null when it isn't worth searching.</summary>
    public static IPAddress? Broadcast(LocalNetwork net) =>
        Searchable(net, out var self) ? ToAddress(self & Mask(net.PrefixLength) | ~Mask(net.PrefixLength)) : null;

    /// <summary>
    /// Searches every network this PC is on; <paramref name="found"/> once for each address that takes print jobs or answered
    /// SNMP (from any thread). Throws <see cref="OperationCanceledException"/> when cancelled.
    /// </summary>
    public static async Task SearchAsync(INetworkScanner scanner, Action<IPAddress> found, IProgress<SearchProgress>? progress = null,
        CancellationToken ct = default)
    {
        ct.ThrowIfCancellationRequested();
        var networks = scanner.LocalNetworks().Distinct().ToList();
        var hosts = networks.SelectMany(Addresses).Distinct().ToList();
        var own = networks.Select(n => n.Address).ToHashSet();
        var reported = new ConcurrentDictionary<IPAddress, bool>();
        void Report(IPAddress a)
        {
            if (reported.TryAdd(a, true)) found(a);
        }

        var broadcasts = networks.Select(Broadcast).OfType<IPAddress>().Distinct().ToList();
        // A reply from outside these networks (or this PC's own agent) isn't one of the printers looked for.
        var snmp = broadcasts.Count == 0 ? Task.CompletedTask : scanner.BroadcastSnmpAsync(broadcasts,
            [Question(SnmpVersion.V2c), Question(SnmpVersion.V1)], SnmpWindow,
            a => { if (!own.Contains(a) && networks.Any(n => Within(n, a))) Report(a); }, ct);

        var done = 0;
        try
        {
            await System.Threading.Tasks.Parallel.ForEachAsync(hosts, new ParallelOptions { MaxDegreeOfParallelism = Parallel, CancellationToken = ct },
                async (host, token) =>
                {
                    var open = await Task.WhenAll(PrinterPorts.Select(port => scanner.IsOpenAsync(host, port, ConnectTimeout, token))).ConfigureAwait(false);
                    if (open.Any(o => o)) Report(host);
                    progress?.Report(new SearchProgress(Interlocked.Increment(ref done), hosts.Count));
                }).ConfigureAwait(false);
        }
        finally
        {
            // Stopped or failed: the SNMP question ends with it (its window is cancelled), and is awaited, never left unobserved.
            try
            {
                await snmp.ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
            }
        }
    }

    /// <summary>
    /// Whether an adapter is a home or office LAN worth searching: not a VPN's or a virtual switch's. A full-tunnel VPN client
    /// (AnyConnect, GlobalProtect, OpenVPN's TAP…) shows as an Ethernet adapter with a gateway on the company's private network,
    /// which a search must never sweep; they're told by name.
    /// </summary>
    public static bool IsLan(string name, string description) =>
        !VpnWords.Any(w => name.Contains(w, StringComparison.OrdinalIgnoreCase) || description.Contains(w, StringComparison.OrdinalIgnoreCase));

    private static readonly string[] VpnWords =
    [
        "VPN", "Virtual", "TAP-", "Tunnel", "AnyConnect", "PANGP", "GlobalProtect", "Fortinet", "FortiClient", "Juniper", "Pulse", "WireGuard",
        "Wintun", "Tailscale", "ZeroTier", "NordLynx", "Hamachi", "OpenVPN", "Data Channel Offload", "Hyper-V", "VMware", "VirtualBox", "WSL",
    ];

    /// <summary>GetNext of sysDescr and hrPrinterStatus: any agent answers the first, a printer's has the second.</summary>
    private static byte[] Question(SnmpVersion version) =>
        new SnmpMessage(version, SnmpClient.DefaultCommunity, SnmpPduType.GetNextRequest, Random.Shared.Next(1, int.MaxValue), 0, 0,
            [new SnmpVarBind(PrinterMib.SysDescr, SnmpValue.Null), new SnmpVarBind(PrinterMib.HrPrinterStatus, SnmpValue.Null)]).Encode();

    private static bool Searchable(LocalNetwork net, out uint self)
    {
        self = 0;
        if (net.Address.AddressFamily != AddressFamily.InterNetwork || net.PrefixLength is < 8 or > 30) return false;
        self = ToNumber(net.Address);
        return IsPrivate(self);
    }

    /// <summary>10/8, 172.16/12, 192.168/16 (RFC 1918).</summary>
    private static bool IsPrivate(uint a) => (a >> 24) == 10 || (a >> 20) == (172u << 4 | 1) || (a >> 16) == (192u << 8 | 168);

    private static bool Within(LocalNetwork net, IPAddress a) =>
        a.AddressFamily == AddressFamily.InterNetwork && (ToNumber(a) & Mask(net.PrefixLength)) == (ToNumber(net.Address) & Mask(net.PrefixLength));

    private static uint Mask(int prefix) => prefix == 0 ? 0 : uint.MaxValue << (32 - prefix);

    private static uint ToNumber(IPAddress a)
    {
        var b = a.GetAddressBytes();
        return (uint)b[0] << 24 | (uint)b[1] << 16 | (uint)b[2] << 8 | b[3];
    }

    private static IPAddress ToAddress(uint a) => new([(byte)(a >> 24), (byte)(a >> 16), (byte)(a >> 8), (byte)a]);
}

/// <summary>
/// The real network: the IPv4 networks of adapters that are up and have a gateway (a LAN, not a virtual switch with none),
/// and no VPN's (<see cref="NetworkSearch.IsLan"/>), TCP connections, SNMP datagrams to the broadcast addresses. Nothing is sent until a search is asked for.
/// </summary>
public sealed class SocketNetworkScanner : INetworkScanner
{
    public static SocketNetworkScanner Instance { get; } = new();

    public IReadOnlyList<LocalNetwork> LocalNetworks()
    {
        var found = new List<LocalNetwork>();
        try
        {
            foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (nic.OperationalStatus != OperationalStatus.Up
                    || nic.NetworkInterfaceType is not (NetworkInterfaceType.Ethernet or NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.GigabitEthernet)
                    || !NetworkSearch.IsLan(nic.Name, nic.Description)) continue;
                var ip = nic.GetIPProperties();
                if (!ip.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any))) continue;
                foreach (var u in ip.UnicastAddresses)
                    if (u.Address.AddressFamily == AddressFamily.InterNetwork) found.Add(new LocalNetwork(u.Address, u.PrefixLength));
            }
        }
        catch (NetworkInformationException)
        {
        }
        return found;
    }

    public async Task<bool> IsOpenAsync(IPAddress host, int port, TimeSpan timeout, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(timeout);
        using var socket = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp);
        try
        {
            await socket.ConnectAsync(host, port, deadline.Token).ConfigureAwait(false);
            return true;
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return false; // nothing answered in time
        }
        catch (SocketException)
        {
            return false; // refused, or no route
        }
    }

    public async Task BroadcastSnmpAsync(IReadOnlyList<IPAddress> broadcasts, IReadOnlyList<byte[]> requests, TimeSpan window,
        Action<IPAddress> answered, CancellationToken ct)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
        deadline.CancelAfter(window);
        using var udp = new UdpClient(AddressFamily.InterNetwork) { EnableBroadcast = true };
        try
        {
            foreach (var to in broadcasts)
            foreach (var request in requests)
            {
                try
                {
                    await udp.SendAsync(request, new IPEndPoint(to, UdpSnmpTransport.Port), deadline.Token).ConfigureAwait(false);
                }
                catch (SocketException)
                {
                    // that network can't be reached now: the others are still asked
                }
            }
            while (true)
            {
                var reply = await udp.ReceiveAsync(deadline.Token).ConfigureAwait(false);
                if (reply.RemoteEndPoint.Port != UdpSnmpTransport.Port) continue;
                try
                {
                    if (SnmpMessage.Decode(reply.Buffer).Type == SnmpPduType.Response) answered(reply.RemoteEndPoint.Address);
                }
                catch (FormatException)
                {
                    // not SNMP: ignored
                }
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            // the window closed
        }
        catch (SocketException)
        {
            // no network to send on
        }
    }
}
