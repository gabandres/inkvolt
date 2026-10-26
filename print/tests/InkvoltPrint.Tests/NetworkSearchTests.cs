using System.Collections.Concurrent;
using System.Net;
using InkvoltPrint.Core.Discovery;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// Search my network (Add a printer): which addresses are asked, that each printer is reported once, what an address typed in
/// becomes, with a made-up network (no packets sent).
/// </summary>
public class NetworkSearchTests
{
    private static LocalNetwork Net(string address, int prefix) => new(IPAddress.Parse(address), prefix);

    /// <summary>A made-up network: the hosts listening on each port, and those whose SNMP agent answers a broadcast.</summary>
    private sealed class FakeNetwork(IReadOnlyList<LocalNetwork> networks) : INetworkScanner
    {
        public Dictionary<string, int[]> Open { get; } = [];
        public List<string> SnmpAnswers { get; } = [];
        public ConcurrentBag<string> Asked { get; } = [];
        public List<IPAddress> Broadcasts { get; } = [];
        public List<byte[]> SnmpRequests { get; } = [];

        public IReadOnlyList<LocalNetwork> LocalNetworks() => networks;

        public Task<bool> IsOpenAsync(IPAddress host, int port, TimeSpan timeout, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            if (SnmpWaits) return Forever(ct); // a slow network: the search is stopped mid-way
            Asked.Add($"{host}:{port}");
            return Task.FromResult(Open.TryGetValue(host.ToString(), out var ports) && ports.Contains(port));
        }

        private static async Task<bool> Forever(CancellationToken ct)
        {
            await Task.Delay(Timeout.Infinite, ct);
            return false;
        }

        /// <summary>The SNMP question waits for its window (until cancelled), as a real one does.</summary>
        public bool SnmpWaits { get; init; }
        public bool SnmpStopped { get; private set; }

        public async Task BroadcastSnmpAsync(IReadOnlyList<IPAddress> broadcasts, IReadOnlyList<byte[]> requests, TimeSpan window, Action<IPAddress> answered,
            CancellationToken ct)
        {
            Broadcasts.AddRange(broadcasts);
            SnmpRequests.AddRange(requests);
            foreach (var host in SnmpAnswers) answered(IPAddress.Parse(host));
            if (!SnmpWaits) return;
            try
            {
                await Task.Delay(Timeout.Infinite, ct);
            }
            finally
            {
                SnmpStopped = true;
            }
        }
    }

    private static async Task<List<string>> Search(FakeNetwork network, IProgress<SearchProgress>? progress = null, CancellationToken ct = default)
    {
        var found = new ConcurrentQueue<string>();
        await NetworkSearch.SearchAsync(network, a => found.Enqueue(a.ToString()), progress, ct);
        return [.. found];
    }

    // ------------------------------------------------------------------------------------------------ which addresses

    [Fact]
    public void AHomeNetworkIsEveryOtherAddressInIt()
    {
        var hosts = NetworkSearch.Addresses(Net("192.168.1.23", 24)).Select(a => a.ToString()).ToList();
        Assert.Equal(253, hosts.Count); // .1 to .254, not this PC
        Assert.Equal("192.168.1.1", hosts[0]);
        Assert.Equal("192.168.1.254", hosts[^1]);
        Assert.DoesNotContain("192.168.1.23", hosts);
        Assert.DoesNotContain("192.168.1.0", hosts);
        Assert.DoesNotContain("192.168.1.255", hosts);
    }

    [Fact]
    public void ASmallNetworkIsAskedWhole()
    {
        var hosts = NetworkSearch.Addresses(Net("10.0.0.5", 22)).Select(a => a.ToString()).ToList();
        Assert.Equal(1021, hosts.Count); // 10.0.0.1 to 10.0.3.254, not this PC
        Assert.Contains("10.0.3.254", hosts);
        Assert.Equal("10.0.3.255", NetworkSearch.Broadcast(Net("10.0.0.5", 22))!.ToString());
    }

    [Fact]
    public void ALargeNetworkIsAskedOnlyAroundThisPc()
    {
        // A /16 would be 65,000 addresses: only the /24 this PC is in.
        var hosts = NetworkSearch.Addresses(Net("172.16.40.7", 16)).Select(a => a.ToString()).ToList();
        Assert.Equal(253, hosts.Count);
        Assert.All(hosts, h => Assert.StartsWith("172.16.40.", h));
        Assert.Equal("172.16.255.255", NetworkSearch.Broadcast(Net("172.16.40.7", 16))!.ToString());
    }

    [Theory]
    [InlineData("8.8.4.4", 24)]      // a public address: never swept
    [InlineData("169.254.3.4", 16)]  // no DHCP answer (link-local): nothing there to find
    [InlineData("127.0.0.1", 8)]
    [InlineData("192.168.1.1", 31)]  // a point-to-point link
    [InlineData("192.168.1.1", 32)]
    [InlineData("100.64.1.2", 24)]   // carrier-grade NAT (a VPN like Tailscale): not this site's network
    public void NetworksNotWorthAskingAreSkipped(string address, int prefix)
    {
        Assert.Empty(NetworkSearch.Addresses(Net(address, prefix)));
        Assert.Null(NetworkSearch.Broadcast(Net(address, prefix)));
    }

    [Theory]
    [InlineData("Ethernet 3", "Cisco AnyConnect Secure Mobility Client Virtual Miniport Adapter for Windows x64")]
    [InlineData("Ethernet 2", "PANGP Virtual Ethernet Adapter Secure")] // GlobalProtect
    [InlineData("Local Area Connection", "TAP-Windows Adapter V9")] // OpenVPN
    [InlineData("OpenVPN Data Channel Offload", "OpenVPN Data Channel Offload")]
    [InlineData("Ethernet 4", "Fortinet SSL VPN Virtual Ethernet Adapter")]
    [InlineData("WireGuard Tunnel", "WireGuard Tunnel")]
    [InlineData("Tailscale", "Tailscale Tunnel")]
    [InlineData("vEthernet (WSL)", "Hyper-V Virtual Ethernet Adapter")]
    [InlineData("ZeroTier One", "ZeroTier Virtual Port")]
    [InlineData("Ethernet 5", "Juniper Networks Virtual Adapter")]
    [InlineData("NordLynx", "NordLynx Tunnel")]
    public void VpnAndVirtualAdaptersAreNotSearched(string name, string description) =>
        Assert.False(NetworkSearch.IsLan(name, description));

    [Theory]
    [InlineData("Wi-Fi", "Intel(R) Wi-Fi 6E AX211 160MHz")]
    [InlineData("Ethernet", "Realtek USB GbE Family Controller")]
    [InlineData("Wi-Fi", "Qualcomm FastConnect 7800 Wi-Fi 7 High Band Simultaneous (HBS) Network Adapter")]
    public void HomeAndOfficeAdaptersAreSearched(string name, string description) => Assert.True(NetworkSearch.IsLan(name, description));

    [Fact]
    public async Task AStoppedSearchStopsItsSnmpQuestionToo()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24)]) { SnmpWaits = true };
        using var cts = new CancellationTokenSource();
        var search = Search(network, ct: cts.Token);
        await cts.CancelAsync();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => search);
        Assert.True(network.SnmpStopped); // awaited, not left running unobserved
    }

    [Fact]
    public void Ipv6IsNotSwept() => Assert.Empty(NetworkSearch.Addresses(new LocalNetwork(IPAddress.Parse("fe80::1"), 64)));

    // ------------------------------------------------------------------------------------------------ the search

    [Fact]
    public async Task PrinterPortsAndSnmpFindPrinters()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24)]);
        network.Open["192.168.1.40"] = [631];      // IPP
        network.Open["192.168.1.41"] = [9100];     // raw printing only
        network.Open["192.168.1.42"] = [515];      // LPD only
        network.Open["192.168.1.1"] = [80, 443];   // the router: a web server isn't a printer
        network.SnmpAnswers.Add("192.168.1.50");   // an older office printer, SNMP only
        var found = await Search(network);
        Assert.Equal(["192.168.1.40", "192.168.1.41", "192.168.1.42", "192.168.1.50"], found.Order());
        Assert.Equal(["192.168.1.255"], network.Broadcasts.Select(b => b.ToString()));
    }

    [Fact]
    public async Task EachHostIsReportedOnce()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24), Net("192.168.1.23", 24)]); // the same network on two adapters
        network.Open["192.168.1.40"] = [631, 9100, 515];
        network.SnmpAnswers.Add("192.168.1.40");
        network.SnmpAnswers.Add("192.168.1.40"); // v1 and v2c agents both answer
        Assert.Equal(["192.168.1.40"], await Search(network));
        Assert.Equal(253 * NetworkSearch.PrinterPorts.Count, network.Asked.Count); // each address and port once
    }

    [Fact]
    public async Task SnmpAnswersFromOtherNetworksAreIgnored()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24)]);
        network.SnmpAnswers.Add("8.8.8.8");
        network.SnmpAnswers.Add("192.168.1.23"); // this PC's own agent
        Assert.Empty(await Search(network));
    }

    [Fact]
    public async Task TheSnmpQuestionAsksForThePrinterTable()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24)]);
        await Search(network);
        var requests = network.SnmpRequests.Select(SnmpMessage.Decode).ToList();
        Assert.Equal([SnmpVersion.V2c, SnmpVersion.V1], requests.Select(r => r.Version)); // agents that turned one off answer the other
        Assert.All(requests, r =>
        {
            Assert.Equal(SnmpPduType.GetNextRequest, r.Type);
            Assert.Equal(SnmpClient.DefaultCommunity, r.Community);
            Assert.Contains(r.VarBinds, vb => vb.Name.Equals(PrinterMib.HrPrinterStatus));
        });
    }

    [Fact]
    public async Task ProgressCountsTheAddressesAsked()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24)]);
        var reports = new ConcurrentQueue<SearchProgress>();
        await Search(network, new SyncProgress(reports.Enqueue));
        Assert.All(reports, r => Assert.Equal(253, r.Total));
        Assert.Equal(253, reports.Max(r => r.Checked));
    }

    [Fact]
    public async Task NoNetworkFindsNothing()
    {
        var network = new FakeNetwork([Net("8.8.4.4", 24)]);
        Assert.Empty(await Search(network));
        Assert.Empty(network.Asked);
        Assert.Empty(network.Broadcasts);
    }

    [Fact]
    public async Task CancellingStops()
    {
        var network = new FakeNetwork([Net("192.168.1.23", 24)]);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Search(network, ct: cts.Token));
    }

    private sealed class SyncProgress(Action<SearchProgress> report) : IProgress<SearchProgress>
    {
        public void Report(SearchProgress value) => report(value);
    }

    // ------------------------------------------------------------------------------------------------ an address typed in

    [Theory]
    [InlineData("192.168.1.40", "192.168.1.40", null)]
    [InlineData("  192.168.1.40  ", "192.168.1.40", null)]
    [InlineData("printer.local", "printer.local", null)]
    [InlineData("NPI7A1B2C", "NPI7A1B2C", null)]
    [InlineData("http://192.168.1.40", "192.168.1.40", null)]                   // a web page address: the host
    [InlineData("http://192.168.1.40/hp/device/info", "192.168.1.40", null)]
    [InlineData("https://printer.local:443/", "printer.local", null)]
    [InlineData("ipp://printer.local/ipp/print", "printer.local", "http://printer.local:631/ipp/print")]
    [InlineData("ipps://printer.local/ipp/print", "printer.local", "https://printer.local:631/ipp/print")] // IPPS is port 631 too (RFC 7472)
    [InlineData("http://host:8631/ipp/print", "host", "http://host:8631/ipp/print")] // IPP on a port of its own
    [InlineData("ipp://host:8631/printers/office", "host", "http://host:8631/printers/office")]
    [InlineData("192.168.1.40:631", "192.168.1.40", "http://192.168.1.40:631/ipp/print")]
    [InlineData("host:8631", "host", "http://host:8631/ipp/print")]
    [InlineData("[fe80::1]", "[fe80::1]", null)]
    public void TypedAddressesBecomeAHostAndIppUrl(string typed, string host, string? ipp)
    {
        var a = PrinterAddress.Parse(typed);
        Assert.Null(a.Error);
        Assert.Equal(host, a.Host);
        Assert.Equal(ipp, a.Ipp?.AbsoluteUri);
    }

    [Theory]
    [InlineData("")]
    [InlineData("   ")]
    [InlineData("not an address")]
    [InlineData("ftp://printer.local/")]
    [InlineData("host:99999")]
    [InlineData("http://")]
    public void NonsenseIsSaidToBeNoAddress(string typed)
    {
        var a = PrinterAddress.Parse(typed);
        Assert.NotNull(a.Error);
        Assert.Null(a.Host);
    }
}
