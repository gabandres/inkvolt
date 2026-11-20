using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// SNMP for WSD queues: a WSD port has no address, but the printer's WSD device node does (PnP-X's IP address, or its
/// WS-Discovery transport address), so its printer is asked over SNMP as a TCP/IP port's is: only while the node is present,
/// only once the device that answers says it is this printer, and over the readings Windows' IPP class driver or the driver give.
/// </summary>
public class WsdSnmpTests
{
    private const string Wsd = @"SWD\DAFWSDProvider\urn:uuid:00000000-0000-4000-8000-000000000030";

    private static (string, IReadOnlyList<string>, IReadOnlyList<string>) Node(string id, string[]? ips = null, string[]? xaddrs = null) =>
        (id, ips ?? [], xaddrs ?? []);

    private static SpoolerQueue WsdQueue(string? address = null, bool? present = true, string name = "Demo Laser 5200 (WSD)", string? serial = null,
        string? model = null) =>
        new(name, "WSD-00000000-0000-4000-8000-000000000030", "Microsoft IPP Class Driver", 0, SpoolerFlags.AttributeLocal, 0)
        {
            PortMonitor = "WSD Port Monitor", ContainerId = "00000000-0000-4000-8000-000000000030", DeviceAddress = address, DevicePresent = present,
            DeviceSerial = serial, DeviceModel = model,
        };

    private static SnmpAgent Laser() =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", "workgroup-laser.txt"))));

    private static SnmpRouter At(string host, ISnmpTransport agent) => new(new Dictionary<string, ISnmpTransport> { [host] = agent });

    private sealed class FixedQueue(SpoolerQueue q) : IQueueStatusSource
    {
        public string Origin => "Windows and the printer's driver";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => Task.FromResult<QueueStatusRead?>(QueueStatusRead.From(SpoolerStatus.Describe(q)));
    }

    // ------------------------------------------------------------------------------------------------ the address

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
    public void The_WSD_node_s_serial_and_model_are_one_clean_line()
    {
        Assert.Equal("CNB0A00030", QueueKinds.WsdText([(@"SWD\PRINTENUM\{0A1B}", ["OTHER1"]), (Wsd, ["  ", "CNB0A00030"])]));
        Assert.Equal("Demo Laser 5200", QueueKinds.WsdText([(Wsd, ["Demo‮ Laser\r\n5200"])]));
        Assert.Null(QueueKinds.WsdText([(Wsd, [])]));
    }

    [Fact]
    public void A_WSD_queue_is_asked_over_SNMP_only_while_its_printer_is_there()
    {
        Assert.Equal("192.0.2.30", QueueKinds.SnmpAddress(WsdQueue("192.0.2.30")));
        Assert.Null(QueueKinds.SnmpAddress(WsdQueue("192.0.2.30", present: false))); // gone: its old address may be another device's now
        Assert.Null(QueueKinds.SnmpAddress(WsdQueue("192.0.2.30", present: null))); // not asked
        Assert.Null(QueueKinds.SnmpAddress(WsdQueue())); // address not known: nothing to ask
        Assert.Equal("Network (WSD, 192.0.2.30)", QueueKinds.ConnectionDetail(WsdQueue("192.0.2.30")));
        Assert.Equal("Network (WSD)", QueueKinds.ConnectionDetail(WsdQueue()));
        // A USB queue never is, whatever it carries.
        Assert.Null(QueueKinds.SnmpAddress(new SpoolerQueue("USB laser", "USB001", null, 0, SpoolerFlags.AttributeLocal, 0)
            { DeviceAddress = "192.0.2.30", DevicePresent = true }));
    }

    // ------------------------------------------------------------------------------------------------ is it this printer

    private static SnmpIdentity Said(string? serial, string? model) => new(SnmpVersion.V2c, 1, model, null, null, null, serial);

    [Theory]
    [InlineData("DEMO0005200", null, "DEMO0005200", "Anything", true)] // serial numbers agree
    [InlineData("DEMO0005200", null, "DEMO0009999", "Demo Laser 5200 Series", false)] // they disagree: the model doesn't matter
    [InlineData(null, "Demo Laser 5200", null, "Demo Laser 5200 Series", true)] // the node's model has the model number
    [InlineData(null, null, null, "Demo Laser 5200 Series", true)] // the queue's name has it
    [InlineData(null, null, null, "Demo Color MFP 4400", false)] // another model
    [InlineData(null, null, null, "Office Laser", false)] // no model number to compare
    [InlineData(null, null, null, null, false)]
    public void The_device_that_answers_must_say_it_is_this_printer(string? nodeSerial, string? nodeModel, string? serial, string? model, bool same) =>
        Assert.Equal(same, QueueKinds.SameDevice(WsdQueue("192.0.2.30", serial: nodeSerial, model: nodeModel), Said(serial, model)));

    [Fact]
    public async Task A_WSD_queue_s_printer_gives_its_status_and_supplies_over_SNMP()
    {
        var queue = WsdQueue("192.0.2.30");
        var source = QueueSources.For(queue, new FixedQueue(queue), () => [], At("192.0.2.30", Laser()));
        var read = await source.ReadAsync(default);
        Assert.Equal(3, read!.Supplies.Count);
        Assert.Equal("Tray 2 paper low.", Assert.Single(read.Status.Alerts).Message);
        Assert.Contains("SNMP", source.Origin);
        Assert.True(source.HasSupplyLevels);
    }

    [Fact]
    public async Task Another_device_at_the_address_is_never_read_as_the_printer()
    {
        var queue = WsdQueue("192.0.2.30", name: "Office Color 9000 (WSD)", serial: "CNB0A00030"); // the laser took its address
        var agent = Laser();
        var source = QueueSources.For(queue, new FixedQueue(queue), () => [], At("192.0.2.30", agent));
        var read = await source.ReadAsync(default);
        Assert.Empty(read!.Supplies);
        Assert.Empty(read.Status.Alerts); // Windows' word alone, not the laser's paper warning
        Assert.DoesNotContain("SNMP", source.Origin);
        Assert.DoesNotContain(agent.Received, m => m.VarBinds.Any(v => v.Name.IsUnder(PrinterMib.SuppliesLevel))); // nothing of it was read
    }

    [Fact]
    public async Task A_new_address_gets_a_new_source_and_a_printer_that_left_none()
    {
        var latest = WsdQueue("192.0.2.30");
        var snmp = new SnmpRouter(new Dictionary<string, ISnmpTransport> { ["192.0.2.30"] = Laser(), ["192.0.2.31"] = Laser() });
        var source = Assert.IsType<WsdQueueStatusSource>(QueueSources.For(latest, new FixedQueue(latest), () => [], snmp, () => latest));
        await source.ReadAsync(default);
        Assert.Equal("192.0.2.30", Assert.IsType<SnmpQueueStatusSource>(source.Current).Host);

        latest = WsdQueue("192.0.2.31"); // DHCP moved it
        await source.ReadAsync(default);
        Assert.Equal("192.0.2.31", Assert.IsType<SnmpQueueStatusSource>(source.Current).Host);

        latest = WsdQueue("192.0.2.31", present: false); // switched off
        var read = await source.ReadAsync(default);
        Assert.IsType<FixedQueue>(source.Current);
        Assert.Empty(read!.Supplies);
    }

    [Fact]
    public async Task A_WSD_printer_that_doesn_t_answer_SNMP_keeps_its_driver_s_levels_and_where_they_came_from()
    {
        var queue = WsdQueue("192.0.2.30", name: "Demo USB laser");
        var source = QueueSources.For(queue, new FixedQueue(queue), () => DemoFleet.DeviceReaders(queue), new SnmpRouter(new Dictionary<string, ISnmpTransport>()));
        var read = await source.ReadAsync(default);
        Assert.NotEmpty(read!.Supplies); // the made-up driver's toner
        Assert.True(source.HasSupplyLevels);
        Assert.NotNull(QueueSources.SuppliesFrom(source)?.From); // "From its driver", through the SNMP source that has nothing
    }

    [Fact]
    public void Queues_with_an_address_in_the_port_stay_on_SNMP_alone_and_others_on_their_readings()
    {
        var tcp = new SpoolerQueue("Office", "IP_192.0.2.15", null, 0, SpoolerFlags.AttributeLocal, 0) { PortMonitor = "Standard TCP/IP Port" };
        var none = new SnmpRouter(new Dictionary<string, ISnmpTransport>());
        Assert.IsType<SnmpQueueStatusSource>(QueueSources.For(tcp, new FixedQueue(tcp), () => throw new InvalidOperationException("not asked"), none));
        var usb = new SpoolerQueue("Demo USB laser", "USB001", null, 0, SpoolerFlags.AttributeLocal, 0);
        Assert.IsType<DeviceQueueStatusSource>(QueueSources.For(usb, new FixedQueue(usb), () => DemoFleet.DeviceReaders(usb), none));
        Assert.IsType<FixedQueue>(QueueSources.For(usb with { Name = "Other USB" }, new FixedQueue(usb), () => [], none));
    }
}
