using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// SNMP for WSD queues: a WSD port has no address, but the printer's WSD device node does (PnP-X's IP address, or its
/// WS-Discovery transport address), so its printer is asked over SNMP as a TCP/IP port's is.
/// </summary>
public class WsdSnmpTests
{
    private const string Wsd = @"SWD\DAFWSDProvider\urn:uuid:00000000-0000-4000-8000-000000000030";

    private static (string, IReadOnlyList<string>, IReadOnlyList<string>) Node(string id, string[]? ips = null, string[]? xaddrs = null) =>
        (id, ips ?? [], xaddrs ?? []);

    private static SpoolerQueue WsdQueue(string? address = null) =>
        new("Demo Laser 5200 (WSD)", "WSD-00000000-0000-4000-8000-000000000030", "Microsoft IPP Class Driver", 0, SpoolerFlags.AttributeLocal, 0)
        {
            PortMonitor = "WSD Port Monitor", ContainerId = "00000000-0000-4000-8000-000000000030", DeviceAddress = address,
        };

    [Fact]
    public void The_WSD_node_s_IPv4_address_is_the_printer_s()
    {
        Assert.Equal("192.0.2.30", QueueKinds.WsdAddress([Node(Wsd, ["fe80::1c2b:3a4d:5e6f:7a8b", "192.0.2.30"])]));
        // No PnP-X address: the host of its WS-Discovery transport address.
        Assert.Equal("192.0.2.31", QueueKinds.WsdAddress([Node(Wsd, xaddrs: ["http://[fe80::1]:3911/ http://192.0.2.31:3911/7a1b2c"])]));
        // Only a WSD node says it: the print queue's own node, a USB node or another device's don't.
        Assert.Null(QueueKinds.WsdAddress([Node(@"SWD\PRINTENUM\{0A1B2C3D}", ["192.0.2.32"]), Node(@"USBPRINT\HPLaserJet\7&1", ["192.0.2.33"])]));
    }

    [Theory]
    [InlineData("127.0.0.1")]
    [InlineData("0.0.0.0")]
    [InlineData("224.0.0.251")]
    [InlineData("255.255.255.255")]
    [InlineData("192.0.2")] // written short: not as a printer says it
    [InlineData("192.0.2.300")]
    [InlineData("printer.local")]
    [InlineData("::ffff:192.0.2.30")]
    [InlineData("")]
    public void An_address_no_printer_has_is_left_alone(string address)
    {
        Assert.Null(QueueKinds.WsdAddress([Node(Wsd, [address])]));
        Assert.Null(QueueKinds.SnmpAddress(WsdQueue(address)));
    }

    [Fact]
    public void A_device_with_many_nodes_and_values_is_looked_at_only_so_far()
    {
        var many = Enumerable.Range(0, 1000).Select(_ => Node(Wsd, Enumerable.Repeat("127.0.0.1", 1000).ToArray(), [new string('x', 100_000)])).ToList();
        Assert.Null(QueueKinds.WsdAddress(many));
    }

    [Fact]
    public void A_WSD_queue_with_its_printer_s_address_is_asked_over_SNMP()
    {
        Assert.Equal("192.0.2.30", QueueKinds.SnmpAddress(WsdQueue("192.0.2.30")));
        Assert.Null(QueueKinds.SnmpAddress(WsdQueue())); // address not known: nothing to ask
        Assert.Equal("Network (WSD, 192.0.2.30)", QueueKinds.ConnectionDetail(WsdQueue("192.0.2.30")));
        Assert.Equal("Network (WSD)", QueueKinds.ConnectionDetail(WsdQueue()));
        // A USB queue never is, whatever it carries.
        Assert.Null(QueueKinds.SnmpAddress(new SpoolerQueue("USB laser", "USB001", null, 0, SpoolerFlags.AttributeLocal, 0) { DeviceAddress = "192.0.2.30" }));
    }

    private sealed class FixedQueue(SpoolerQueue q) : IQueueStatusSource
    {
        public string Origin => "Windows and the printer's driver";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => Task.FromResult<QueueStatusRead?>(QueueStatusRead.From(SpoolerStatus.Describe(q)));
    }

    [Fact]
    public async Task A_WSD_queue_s_printer_gives_its_status_and_supplies_over_SNMP()
    {
        var agent = new SnmpAgent(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))));
        var queue = WsdQueue("192.0.2.30");
        var source = new SnmpQueueStatusSource(new FixedQueue(queue), QueueKinds.SnmpAddress(queue)!, new SnmpRouter(new Dictionary<string, ISnmpTransport> { ["192.0.2.30"] = agent }));
        var read = await source.ReadAsync(default);
        Assert.Equal(3, read!.Supplies.Count);
        Assert.Equal("Tray 2 paper low.", Assert.Single(read.Status.Alerts).Message);
        Assert.Contains("SNMP", source.Origin);
    }
}
