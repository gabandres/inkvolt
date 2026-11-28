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

    /// <summary>
    /// A link-local IPv6 address with its zone (the network interface after "%", typed "%25" as RFC 6874 has it, or "%"
    /// as ipconfig shows it) keeps it (the Mac's tests): the host holds it, and the IPP and web addresses keep it where a
    /// connection reads it (<see cref="Uri.IdnHost"/>), written "%25" (<see cref="PrinterAddress.UrlText"/>).
    /// </summary>
    [Theory]
    [InlineData("ipp://[fe80::1%25en0]/", "fe80::1%en0", "http://[fe80::1%25en0]:631/ipp/print", null)]
    [InlineData("ipps://[fe80::1%25en0]:8631/ipp/print", "fe80::1%en0", "https://[fe80::1%25en0]:8631/ipp/print", null)]
    [InlineData("[fe80::1%25a]:8080", "fe80::1%a", "http://[fe80::1%25a]:8080/ipp/print", null)]
    [InlineData("http://[fe80::1%25a]:8080", "fe80::1%a", "http://[fe80::1%25a]:8080/ipp/print", "http://[fe80::1%25a]:8080/")]
    [InlineData("[fe80::1%25en0]", "fe80::1%en0", null, null)]
    [InlineData("ipp://[fe80::1%12]/", "fe80::1%12", "http://[fe80::1%2512]:631/ipp/print", null)] // Windows' zones are numbers
    // "%25" with nothing after it is interface 25 (ipconfig's "%25"), not an escaped empty zone; "%2512" is still interface 12.
    [InlineData("[fe80::1%25]", "fe80::1%25", null, null)]
    [InlineData("ipp://[fe80::1%25]/", "fe80::1%25", "http://[fe80::1%2525]:631/ipp/print", null)]
    [InlineData("[fe80::1%25]:8080", "fe80::1%25", "http://[fe80::1%2525]:8080/ipp/print", null)]
    [InlineData("ipp://[fe80::1%2512]/", "fe80::1%12", "http://[fe80::1%2512]:631/ipp/print", null)]
    public void A_zoned_IPv6_address_keeps_its_zone(string typed, string host, string? ipp, string? web)
    {
        var a = PrinterAddress.Parse(typed);
        Assert.Null(a.Error);
        Assert.Equal(host, a.Host?.Trim('[', ']'));
        Assert.Equal(ipp, a.Ipp is { } i ? PrinterAddress.UrlText(i) : null);
        if (a.Ipp is { } u) Assert.Equal(host, u.IdnHost);
        Assert.Equal(web, a.Web is { } w ? PrinterAddress.UrlText(w) : null);
        // Kept and read back (the remembered printer's IPP address), the zone is still there.
        if (ipp is not null) Assert.Equal(host, PrinterAddress.ReadUrl(ipp)?.IdnHost);
    }

    /// <summary>
    /// Set up for a printer added by a zoned address (the pre-release review): the queue's IPP URL is the one typed, port and path
    /// kept (the URL's bracketed host never equalled the zoned host, so it fell back to port 631's /ipp/print), and the text given to
    /// the clipboard, the message and Add-Printer keeps the zone.
    /// </summary>
    [Theory]
    [InlineData("ipp://[fe80::1%2512]:8631/printers/x", "http://[fe80::1%2512]:8631/printers/x")]
    [InlineData("ipp://[fe80::1%25en0]/printers/x", "http://[fe80::1%25en0]:631/printers/x")]
    [InlineData("[fe80::1%12]:8080", "http://[fe80::1%2512]:8080/ipp/print")]
    [InlineData("ipp://[2001:db8::5]:8631/printers/x", "http://[2001:db8::5]:8631/printers/x")]
    [InlineData("ipp://printer.local:8631/printers/x", "http://printer.local:8631/printers/x")]
    public void Set_up_by_a_zoned_address_keeps_the_IPP_URL_typed(string typed, string queueUrl)
    {
        var a = PrinterAddress.Parse(typed);
        Assert.Equal(queueUrl, PrinterAddress.UrlText(PrinterAddress.SetupUrl(a.Ipp, a.Host!)));
    }

    [Fact]
    public void Set_up_without_an_IPP_URL_on_the_host_asks_631_keeping_the_zone()
    {
        Assert.Equal("http://[fe80::1%2512]:631/ipp/print", PrinterAddress.UrlText(PrinterAddress.SetupUrl(null, "fe80::1%12")));
        // A URL on another host, or over https, isn't the one: IPP Everywhere's on the printer's own host.
        Assert.Equal("http://[fe80::1%2512]:631/ipp/print",
            PrinterAddress.UrlText(PrinterAddress.SetupUrl(PrinterAddress.ReadUrl("http://[fe80::1%253]:8631/x"), "fe80::1%12")));
        Assert.Equal("http://192.0.2.10:631/ipp/print",
            PrinterAddress.UrlText(PrinterAddress.SetupUrl(new Uri("https://192.0.2.10:8631/x"), "192.0.2.10")));
    }

    /// <summary>Add-Printer's http form of an ipp:// URL keeps the zone (a UriBuilder made from the URL drops it).</summary>
    [Theory]
    [InlineData("ipp://[fe80::1%2512]/printers/x", "http://[fe80::1%2512]:631/printers/x")]
    [InlineData("ipps://[fe80::1%25en0]:8631/ipp/print", "https://[fe80::1%25en0]:8631/ipp/print")]
    [InlineData("ipp://192.0.2.10/ipp/print", "http://192.0.2.10:631/ipp/print")]
    [InlineData("http://192.0.2.10:8631/ipp/print", "http://192.0.2.10:8631/ipp/print")]
    public void The_http_form_of_an_IPP_URL_keeps_its_zone(string ipp, string http) =>
        Assert.Equal(http, PrinterAddress.UrlText(PrinterAddress.HttpForm(PrinterAddress.ReadUrl(ipp)!)));

    [Fact]
    public void Recreating_an_IPP_queue_at_a_zoned_address_gives_Add_Printer_the_zone()
    {
        var url = PrinterAddress.ReadUrl("http://[fe80::1%2512]:8631/printers/x")!;
        var repair = new Core.Offline.Repair(Core.Offline.RepairKind.RecreateIppQueue, "t", "") { Queue = "q", TargetUrl = url };
        var script = Core.Offline.RepairScripts.For(repair, temporaryName: "q (new address)", httpUrl: PrinterAddress.HttpForm(url))!;
        Assert.Equal("http://[fe80::1%2512]:8631/printers/x", script.Values[2]);
    }

    /// <summary>A zone that isn't one (empty, or a character a zone can't hold) is no address, never a URL made from it.</summary>
    [Theory]
    [InlineData("ipp://[fe80::1%]/")]
    [InlineData("ipp://[fe80::1%25a%2Fb]/")]
    [InlineData("[fe80::1%25a%2Fb]:8080")]
    [InlineData("[fe80::1%]:8080")]
    public void A_zone_that_isnt_one_is_no_address(string typed)
    {
        var a = PrinterAddress.Parse(typed);
        Assert.NotNull(a.Error);
        Assert.Null(a.Ipp);
    }

    [Fact]
    public void A_URL_host_writes_an_IPv6_zone_as_an_escape()
    {
        Assert.Equal("[fe80::1%25en0]", PrinterAddress.UrlHost("fe80::1%en0"));
        Assert.Equal("[fe80::1%25en0]", PrinterAddress.UrlHost("[fe80::1%en0]"));
        Assert.Equal("[2001:db8::1]", PrinterAddress.UrlHost("2001:db8::1"));
        Assert.Equal("printer.local", PrinterAddress.UrlHost("printer.local"));
        Assert.Null(PrinterAddress.UrlHost("fe80::1%e/n"));
        Assert.Null(PrinterAddress.UrlHost("fe80::1%"));
        Assert.Null(PrinterAddress.ReadUrl("http://[fe80::1%25a%2Fb]/"));
        Assert.Equal("http://192.0.2.10:631/ipp/print", PrinterAddress.UrlText(new Uri("http://192.0.2.10:631/ipp/print")));
    }
}
