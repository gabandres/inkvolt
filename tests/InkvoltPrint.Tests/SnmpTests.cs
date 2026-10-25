using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// SNMP: the BER encoder/decoder against bytes written by hand from X.690 and the message grammar of RFC 1157 §4 / RFC 3416
/// §3 (not captured from devices), the client against the made-up agent, the Printer MIB mapping (RFC 2790, RFC 3805).
/// </summary>
public class SnmpTests
{
    private static byte[] Hex(string hex) => Convert.FromHexString(hex.Replace(" ", "").Replace("\n", "").Replace("\r", ""));

    private static SnmpAgent DemoAgent(string name, bool v1Only = false) =>
        new(SnmpAgent.ParseWalk(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "snmp-demo", name))), v1Only: v1Only);

    // ------------------------------------------------------------------------------------------------ BER (X.690)

    [Theory]
    [InlineData(0L, "020100")]
    [InlineData(127L, "02017F")]
    [InlineData(128L, "02020080")]
    [InlineData(256L, "02020100")]
    [InlineData(-1L, "0201FF")]
    [InlineData(-128L, "020180")]
    [InlineData(-129L, "0202FF7F")]
    [InlineData(2147483647L, "02047FFFFFFF")]
    [InlineData(-2147483648L, "020480000000")]
    public void IntegersAreShortestTwosComplement(long value, string hex)
    {
        Assert.Equal(Hex(hex), Ber.Integer32(value));
        var r = new Ber.Reader(Hex(hex));
        Assert.Equal(value, r.ReadInteger());
    }

    [Theory]
    [InlineData("1.3.6.1.2.1.1.1.0", "06082B06010201010100")]
    [InlineData("1.2.840.113549", "06062A864886F70D")] // X.690's own example arcs: 840 and 113549 take two and three bytes
    [InlineData("2.999.3", "0603883703")] // the first two arcs share one subidentifier: 80 + 999 = 1079 = 0x88 0x37
    [InlineData("1.3.6.1.2.1.43.11.1.1.9.1.1", "060C2B060102012B0B0101090101")]
    public void ObjectIdentifiersFollowX690(string oid, string hex)
    {
        Assert.Equal(Hex(hex), Ber.ObjectId(Oid.Parse(oid)));
        Assert.Equal(Oid.Parse(oid), new Ber.Reader(Hex(hex)).ReadObjectId());
    }

    [Theory]
    [InlineData(0, "00")]
    [InlineData(127, "7F")]
    [InlineData(128, "8180")]
    [InlineData(200, "81C8")]
    [InlineData(1000, "8203E8")]
    [InlineData(70000, "83011170")]
    public void LengthsUseTheLongFormFrom128(int length, string hex) => Assert.Equal(Hex(hex), Ber.Length(length));

    [Theory]
    [InlineData(0UL, "00")]
    [InlineData(127UL, "7F")]
    [InlineData(128UL, "0080")]
    [InlineData(4294967295UL, "00FFFFFFFF")]
    public void UnsignedValuesGetALeadingZeroWhenTheTopBitIsSet(ulong value, string hex)
    {
        Assert.Equal(Hex(hex), Ber.UnsignedContent(value));
        Assert.Equal(value, Ber.UnsignedValue(Hex(hex)));
    }

    [Theory]
    [InlineData("3080020100")] // indefinite length: not allowed in SNMP
    [InlineData("3005020100")] // the SEQUENCE claims more than there is
    [InlineData("30")] // no length
    [InlineData("1F0100")] // multi-byte tag
    [InlineData("3084FFFFFFFF")] // a length no datagram has
    public void MalformedBerIsAFormatException(string hex) =>
        Assert.Throws<FormatException>(() => new Ber.Reader(Hex(hex)).Enter(Ber.Sequence).ReadInteger());

    [Theory]
    [InlineData("0600")] // empty
    [InlineData("06022B86")] // ends inside a subidentifier
    [InlineData("06032B8001")] // a subidentifier padded with 0x80
    public void MalformedObjectIdentifiersAreRejected(string hex) => Assert.Throws<FormatException>(() => new Ber.Reader(Hex(hex)).ReadObjectId());

    // ------------------------------------------------------------------------------------------------ messages (RFC 1157 / RFC 3416)

    /// <summary>
    /// RFC 1157 §4.1.2 GetRequest for sysDescr.0, community "public", request-id 1, built by hand:
    /// Message SEQUENCE { version 0, community, GetRequest-PDU [0] { request-id, error-status 0, error-index 0,
    /// VarBindList { VarBind { name, NULL } } } }.
    /// </summary>
    private const string GetSysDescrV1 =
        "3026" + "020100" + "0406 7075626C6963" +
        "A019" + "020101" + "020100" + "020100" +
        "300E" + "300C" + "06082B06010201010100" + "0500";

    [Fact]
    public void GetRequestIsEncodedByteForByte()
    {
        var m = new SnmpMessage(SnmpVersion.V1, "public", SnmpPduType.GetRequest, 1, 0, 0,
            [new SnmpVarBind(Oid.Parse("1.3.6.1.2.1.1.1.0"), SnmpValue.Null)]);
        Assert.Equal(Hex(GetSysDescrV1), m.Encode());
        Assert.Equal(m with { VarBinds = m.VarBinds }, SnmpMessage.Decode(Hex(GetSysDescrV1)) with { VarBinds = m.VarBinds });
    }

    /// <summary>
    /// RFC 3416 §4.2.3 GetBulkRequest (v2c, RFC 1901 version 1): request-id 0x1234, non-repeaters 0, max-repetitions 10, for
    /// prtMarkerSuppliesLevel.1 (RFC 3805), built by hand. BulkPDU has PDU's shape, tag [5].
    /// </summary>
    private const string GetBulkSuppliesV2c =
        "302A" + "020101" + "0406 7075626C6963" +
        "A51D" + "02021234" + "020100" + "02010A" +
        "3011" + "300F" + "060B2B060102012B0B01010901" + "0500";

    [Fact]
    public void GetBulkRequestIsEncodedByteForByte()
    {
        var m = new SnmpMessage(SnmpVersion.V2c, "public", SnmpPduType.GetBulkRequest, 0x1234, 0, 10,
            [new SnmpVarBind(Oid.Parse("1.3.6.1.2.1.43.11.1.1.9.1"), SnmpValue.Null)]);
        Assert.Equal(Hex(GetBulkSuppliesV2c), m.Encode());
        var back = SnmpMessage.Decode(Hex(GetBulkSuppliesV2c));
        Assert.Equal((0, 10), (back.NonRepeaters, back.MaxRepetitions));
    }

    /// <summary>
    /// A v2c Response-PDU [2] written by hand from RFC 3416 §3: TimeTicks 123456 (RFC 3416's sysUpTime example), INTEGER 3
    /// (hrPrinterStatus idle), OCTET STRING 0x40 0x00 (hrPrinterDetectedErrorState: noPaper), INTEGER -2 (a supply level:
    /// unknown), an OCTET STRING description, the noSuchInstance and endOfMibView exceptions, and a Gauge32 of 2^32-1 (its
    /// leading zero byte). 152 bytes of bindings: the list's length takes the long form (0x81 0x98).
    /// </summary>
    private const string ResponseV2c =
        "3081B3" + "020101" + "0406 7075626C6963" +
        "A281A5" + "02021234" + "020100" + "020100" +
        "308198" +
        "300F" + "06082B06010201010300" + "430301E240" +
        "3010" + "060B2B06010201190305010101" + "020103" +
        "3011" + "060B2B06010201190305010201" + "04024000" +
        "3011" + "060C2B060102012B0B0101090101" + "0201FE" +
        "301B" + "060C2B060102012B0B0101060101" + "040B 426C61636B20546F6E6572" +
        "3010" + "060C2B060102012B1201010201 05" + "8100" +
        "3009" + "06052B06010401" + "8200" +
        "3013" + "060A2B06010201020201 0501" + "420500FFFFFFFF";

    [Fact]
    public void ResponseIsDecodedAndEncodedBackByteForByte()
    {
        var bytes = Hex(ResponseV2c);
        var m = SnmpMessage.Decode(bytes);
        Assert.Equal((SnmpVersion.V2c, "public", SnmpPduType.Response, 0x1234, 0, 0), (m.Version, m.Community, m.Type, m.RequestId, m.ErrorStatus, m.ErrorIndex));
        Assert.Equal(8, m.VarBinds.Count);
        Assert.Equal(Oid.Parse("1.3.6.1.2.1.1.3.0"), m.VarBinds[0].Name);
        Assert.Equal((Ber.TimeTicks, 123456L), (m.VarBinds[0].Value.Tag, m.VarBinds[0].Value.Number));
        Assert.Equal(3, m.VarBinds[1].Value.Int);
        Assert.Equal(new byte[] { 0x40, 0x00 }, m.VarBinds[2].Value.Bytes);
        Assert.Equal(-2, m.VarBinds[3].Value.Int);
        Assert.Equal("Black Toner", m.VarBinds[4].Value.Text);
        Assert.Same(SnmpValue.NoSuchInstance, m.VarBinds[5].Value);
        Assert.Same(SnmpValue.EndOfMibView, m.VarBinds[6].Value);
        Assert.Equal((Ber.Gauge32, 4294967295L), (m.VarBinds[7].Value.Tag, m.VarBinds[7].Value.Number));
        Assert.Equal(bytes, m.Encode());
    }

    [Theory]
    [InlineData("3010" + "020103" + "0406 7075626C6963" + "A003020101")] // SNMPv3 (version 3): not spoken here
    [InlineData("3010" + "020100" + "0406 7075626C6963" + "A403020101")] // a v1 Trap-PDU: another shape, never asked for
    [InlineData("300B" + "020100" + "0406 7075626C6963")] // no PDU
    public void OtherMessagesAreFormatExceptions(string hex) => Assert.Throws<FormatException>(() => SnmpMessage.Decode(Hex(hex)));

    [Fact]
    public void OctetStringsReadAsTextWithoutPaddingAndInLatin1WhenNotUtf8()
    {
        Assert.Equal("Black Toner", SnmpValue.Octets("Black Toner\0\0"u8.ToArray()).Text);
        Assert.Equal("Café", SnmpValue.Octets([0x43, 0x61, 0x66, 0xE9]).Text); // Latin-1 é, not valid UTF-8
        Assert.Null(SnmpValue.Octets([0x00, 0x00]).Text);
    }

    // ------------------------------------------------------------------------------------------------ the client and the made-up agent

    /// <summary>RFC 3416 §4.2.3.1's IP net-to-media table, as the example's agent holds it.</summary>
    private static SnmpAgent Rfc3416Agent(bool v1Only = false) => new(SnmpAgent.ParseWalk("""
        .1.3.6.1.2.1.1.3.0 = Timeticks: (123456)
        .1.3.6.1.2.1.4.22.1.2.1.9.2.3.4 = Hex-STRING: 00 00 10 54 32 10
        .1.3.6.1.2.1.4.22.1.2.1.10.0.0.51 = Hex-STRING: 00 00 10 01 23 45
        .1.3.6.1.2.1.4.22.1.2.2.10.0.0.15 = Hex-STRING: 00 00 10 98 76 54
        .1.3.6.1.2.1.4.22.1.3.1.9.2.3.4 = IpAddress: 9.2.3.4
        .1.3.6.1.2.1.4.22.1.3.1.10.0.0.51 = IpAddress: 10.0.0.51
        .1.3.6.1.2.1.4.22.1.3.2.10.0.0.15 = IpAddress: 10.0.0.15
        .1.3.6.1.2.1.4.22.1.4.1.9.2.3.4 = INTEGER: 3
        .1.3.6.1.2.1.4.22.1.4.1.10.0.0.51 = INTEGER: 4
        .1.3.6.1.2.1.4.22.1.4.2.10.0.0.15 = INTEGER: 3
        .1.3.6.1.2.1.4.23.0 = Counter32: 2
        """), v1Only: v1Only);

    private static readonly Oid SysUpTime = Oid.Parse("1.3.6.1.2.1.1.3"), PhysAddress = Oid.Parse("1.3.6.1.2.1.4.22.1.2"),
        MediaType = Oid.Parse("1.3.6.1.2.1.4.22.1.4");

    [Fact]
    public async Task GetBulkAnswersAsRfc3416sExample()
    {
        var client = new SnmpClient(Rfc3416Agent(), "192.0.2.50", SnmpVersion.V2c);
        var first = await client.GetBulkAsync(1, 2, [SysUpTime, PhysAddress, MediaType]);
        Assert.Equal(["1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.4.22.1.2.1.9.2.3.4", "1.3.6.1.2.1.4.22.1.4.1.9.2.3.4",
            "1.3.6.1.2.1.4.22.1.2.1.10.0.0.51", "1.3.6.1.2.1.4.22.1.4.1.10.0.0.51"], first.Select(v => v.Name.ToString()));
        Assert.Equal([3L, 4L], new[] { first[2], first[4] }.Select(v => v.Value.Number));

        var second = await client.GetBulkAsync(1, 2, [SysUpTime, first[3].Name, first[4].Name]);
        // The end of the table: the fourth binding is the next column, the fifth the object after the table (as in the RFC).
        Assert.Equal(["1.3.6.1.2.1.1.3.0", "1.3.6.1.2.1.4.22.1.2.2.10.0.0.15", "1.3.6.1.2.1.4.22.1.4.2.10.0.0.15",
            "1.3.6.1.2.1.4.22.1.3.1.9.2.3.4", "1.3.6.1.2.1.4.23.0"], second.Select(v => v.Name.ToString()));
    }

    [Theory]
    [InlineData(SnmpVersion.V2c)]
    [InlineData(SnmpVersion.V1)]
    public async Task WalkReadsColumnsSideBySideOverBothVersions(SnmpVersion version)
    {
        var agent = Rfc3416Agent(v1Only: version == SnmpVersion.V1);
        var columns = await new SnmpClient(agent, "192.0.2.50", version).WalkAsync([PhysAddress, MediaType]);
        Assert.Equal(["1.9.2.3.4", "1.10.0.0.51", "2.10.0.0.15"], columns[0].Select(r => string.Join('.', r.Index)));
        Assert.Equal([3L, 4L, 3L], columns[1].Select(r => r.Value.Number));
        Assert.All(agent.Received, m => Assert.Equal(version == SnmpVersion.V1 ? SnmpPduType.GetNextRequest : SnmpPduType.GetBulkRequest, m.Type));
    }

    [Fact]
    public async Task V1NoSuchNameLeavesTheOtherObjects()
    {
        var client = new SnmpClient(Rfc3416Agent(v1Only: true), "192.0.2.50", SnmpVersion.V1);
        var got = await client.GetAsync([Oid.Parse("1.3.6.1.2.1.1.5.0"), Oid.Parse("1.3.6.1.2.1.1.3.0")]);
        Assert.True(got[0].Value.IsException);
        Assert.Equal(123456L, got[1].Value.Number);
        var past = await client.GetNextAsync([Oid.Parse("1.3.6.1.2.1.4.23.0")]); // nothing after it: noSuchName → end of MIB
        Assert.Same(SnmpValue.EndOfMibView, past[0].Value);
    }

    [Fact]
    public async Task AWrongCommunityGetsNoReplyAndTimesOutAfterTheRetries()
    {
        var agent = new SnmpAgent(SnmpAgent.ParseWalk(".1.3.6.1.2.1.1.3.0 = Timeticks: (1)"), community: "secret");
        var client = new SnmpClient(agent, "192.0.2.50", SnmpVersion.V2c) { Retries = 2 };
        await Assert.ThrowsAsync<TimeoutException>(() => client.GetAsync([Oid.Parse("1.3.6.1.2.1.1.3.0")]));
        Assert.Equal(3, agent.Requests);
    }

    [Fact]
    public void TheAgentRefusesSets()
    {
        var agent = Rfc3416Agent();
        var set = new SnmpMessage(SnmpVersion.V2c, "public", SnmpPduType.SetRequest, 7, 0, 0, [new SnmpVarBind(Oid.Parse("1.3.6.1.2.1.4.23.0"), SnmpValue.Integer(0))]);
        Assert.Equal(17, SnmpMessage.Decode(agent.Respond(set.Encode())!).ErrorStatus); // notWritable
    }

    // ------------------------------------------------------------------------------------------------ printers (RFC 2790, RFC 3805)

    [Fact]
    public async Task ProbeFindsThePrinterEntryAndPrefersV2c()
    {
        var agent = DemoAgent("workgroup-laser.txt");
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14");
        Assert.NotNull(printer);
        var id = printer.Identity;
        Assert.Equal((SnmpVersion.V2c, 1u), (id.Version, id.DeviceIndex));
        Assert.Equal("Demo Laser 5200 Series", id.Model);
        Assert.Equal("DEMO0005200", id.SerialNumber);
        Assert.Equal("Office, 2nd floor", id.Location);
        Assert.Equal("demo-laser", id.SystemName);
    }

    [Fact]
    public async Task AV1OnlyPrinterIsReadOverV1()
    {
        var agent = DemoAgent("workgroup-laser.txt", v1Only: true);
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14");
        Assert.Equal(SnmpVersion.V1, printer!.Identity.Version);
        Assert.Equal(3, (await printer.GetSuppliesAsync()).Count);
    }

    [Fact]
    public async Task AnAgentWithoutAPrinterEntryIsNoPrinter()
    {
        // A router or a PC answering "public": MIB-II, but no hrPrinterTable.
        var agent = new SnmpAgent(SnmpAgent.ParseWalk("""
            .1.3.6.1.2.1.1.1.0 = STRING: "Example router"
            .1.3.6.1.2.1.1.5.0 = STRING: "router"
            .1.3.6.1.2.1.2.1.0 = INTEGER: 2
            """));
        Assert.Null(await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.1"));
        Assert.Null(await SnmpPrinterClient.ProbeAsync(new SnmpRouter(new Dictionary<string, ISnmpTransport>()), "192.0.2.1")); // silence
    }

    [Fact]
    public async Task OnlyGetGetNextAndGetBulkAreEverSent()
    {
        var agent = DemoAgent("workgroup-laser.txt");
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14");
        await printer!.GetStatusAsync();
        await new SnmpPrinterClient(agent, "192.0.2.14", printer.Identity with { Version = SnmpVersion.V1 }).GetSuppliesAsync();
        Assert.NotEmpty(agent.Received);
        Assert.All(agent.Received, m => Assert.Contains(m.Type, new[] { SnmpPduType.GetRequest, SnmpPduType.GetNextRequest, SnmpPduType.GetBulkRequest }));
    }

    [Fact]
    public async Task DemoLaserReadsAsReadyWithAPaperWarningAndThreeSupplies()
    {
        var printer = await SnmpPrinterClient.ProbeAsync(DemoAgent("workgroup-laser.txt"), "192.0.2.14");
        var status = await printer!.GetStatusAsync();
        Assert.Equal(("ready", "Ready", Severity.Warning), (status.Code, status.Message, status.Severity));
        // The alert's own words; the lowPaper bit says the same and isn't repeated; the cover-closed event isn't a problem.
        var alert = Assert.Single(status.Alerts);
        Assert.Equal(("media-low", "Tray 2 paper low."), (alert.Id, alert.Message));

        var supplies = await printer.GetSuppliesAsync();
        Assert.Equal(["Black Toner Cartridge DT-5200", "Drum Unit DR-5200", "Waste Toner Box"], supplies.Select(s => s.Name));
        Assert.Equal((35, "ok", "K", "toner-cartridge"), (supplies[0].PercentRemaining, supplies[0].State, supplies[0].ColorCode, supplies[0].Kind));
        Assert.Equal((80, "opc"), (supplies[1].PercentRemaining, supplies[1].Kind));
        Assert.Null(supplies[1].ColorCode); // colorant index 0: none
        Assert.True(supplies[2].IsWaste);
        Assert.Equal((null, "ok"), (supplies[2].PercentRemaining, supplies[2].State)); // -3: some room left
    }

    [Fact]
    public async Task OneReadServesStatusAndSupplies()
    {
        var agent = DemoAgent("color-mfp.txt");
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.15");
        var before = agent.Requests;
        await Task.WhenAll(printer!.GetStatusAsync(), printer.GetSuppliesAsync());
        var oneRead = agent.Requests - before;
        await printer.GetSuppliesAsync();
        Assert.Equal(oneRead, agent.Requests - before);
    }

    private static SnmpReading Reading(int device = 2, int printer = 3, byte[]? errors = null, SnmpAlert[]? alerts = null, SnmpSupply[]? supplies = null,
        Dictionary<int, string>? colorants = null) =>
        new(device, printer, errors ?? [0, 0], alerts ?? [], supplies ?? [], colorants ?? new Dictionary<int, string>());

    [Theory]
    [InlineData(2, 3, "ready", "Ready")] // RFC 3805 §2.2.13.2: Idle
    [InlineData(2, 4, "processing", "Printing")] // Busy/Active
    [InlineData(5, 5, "warmingUp", "Warming up")] // Moving on-line
    [InlineData(2, 1, "inPowerSave", "Sleeping")] // Standby
    [InlineData(5, 1, "stopped", "Stopped")] // Unavailable / critical alert
    [InlineData(1, 2, "unknown", "Unknown")]
    public void OverallStateFollowsRfc3805(int device, int printer, string code, string message)
    {
        var s = SnmpPrinterStatus.ToStatus(Reading(device, printer));
        Assert.Equal((code, message), (s.Code, s.Message));
    }

    [Fact]
    public void AJamStopsThePrinterAndNamesIt()
    {
        // Critical alert, media path group, code jam(8), no description: the IPP reason's words; down with the jammed bit set.
        var s = SnmpPrinterStatus.ToStatus(Reading(5, 1, [0x04, 0x00], [new SnmpAlert(1, 3, 13, 1, 8, null)]));
        Assert.Equal(("stopped", "Paper jam", Severity.Error), (s.Code, s.Message, s.Severity));
        Assert.Equal("media-jam", Assert.Single(s.Alerts).Id);
        Assert.NotNull(s.Detail); // what to do about it
    }

    [Theory]
    [InlineData(new byte[] { 0x40 }, "media-empty", Severity.Error)] // noPaper
    [InlineData(new byte[] { 0x08 }, "door-open", Severity.Error)] // doorOpen (bit 4)
    [InlineData(new byte[] { 0x00, 0x20 }, "marker-supply-missing", Severity.Error)] // markerSupplyMissing (bit 10)
    [InlineData(new byte[] { 0x00, 0x02 }, "maintenance-overdue", Severity.Warning)] // overduePreventMaint (bit 14)
    public void ErrorStateBitsCountFromTheFirstBytesTopBit(byte[] bits, string id, Severity severity)
    {
        var alert = Assert.Single(SnmpPrinterStatus.ToStatus(Reading(3, 3, bits)).Alerts);
        Assert.Equal((id, severity), (alert.Id, alert.Severity));
    }

    [Fact]
    public void TheOfflineBitSaysOfflineWhileTheAgentStillAnswers()
    {
        var s = SnmpPrinterStatus.ToStatus(Reading(5, 1, [0x02]));
        Assert.Equal(("stopped", "Offline", Severity.Error), (s.Code, s.Message, s.Severity)); // not "offline": it answers
    }

    [Fact]
    public void ServiceRequestedIsLeftOutBesideTheRealProblem()
    {
        var s = SnmpPrinterStatus.ToStatus(Reading(5, 1, [0x41])); // noPaper + serviceRequested
        Assert.Equal("media-empty", Assert.Single(s.Alerts).Id);
    }

    [Fact]
    public void ChangeEventsAndOtherCodesAreNoProblems()
    {
        SnmpAlert[] alerts =
        [
            new(1, 5, 6, 1, 3, "Cover opened"), // warningBinaryChangeEvent
            new(2, 4, 6, 1, 4, "Cover closed"), // coverClosed: an event
            new(3, 4, 5, -1, 503, null), // powerUp
            new(4, 1, 5, -1, 1, null), // other, severity other
        ];
        Assert.Empty(SnmpPrinterStatus.ToStatus(Reading(alerts: alerts)).Alerts);
    }

    [Fact]
    public void GenericSubunitCodesTakeTheirGroupsMeaning()
    {
        SnmpSupply[] supplies = [new(1, 3, 3, "Black Toner", 100, 9, 1), new(2, 4, 4, "Waste Toner Box", 100, 10, 0), new(3, 3, 9, "Drum", 100, 4, 0)];
        SnmpAlert[] alerts =
        [
            new(1, 4, 11, 1, 12, null), // subunitAlmostEmpty on the toner
            new(2, 4, 11, 2, 14, null), // subunitAlmostFull on the waste box
            new(3, 4, 11, 3, 10, null), // subunitLifeAlmostOver on the drum
            new(4, 3, 8, 2, 13, null), // subunitEmpty on input tray 2
        ];
        var r = Reading(alerts: alerts, supplies: supplies, colorants: new() { [1] = "black" });
        Assert.Equal(["marker-supply-low", "marker-waste-almost-full", "opc-near-eol", "media-empty"], SnmpPrinterStatus.ToStatus(r).Alerts.Select(a => a.Id));
        var c = SnmpPrinterStatus.ToConsumables(r);
        Assert.Equal(("low", 9, "K"), (c[0].State, c[0].PercentRemaining, c[0].ColorCode));
        Assert.Equal(("almostFull", (int?)null), (c[1].State, c[1].PercentRemaining));
        Assert.Equal("low", c[2].State);
    }

    [Theory]
    [InlineData(3000, 1050, 35, "ok")]
    [InlineData(100, 0, 0, "out")]
    [InlineData(100, 130, 100, "ok")] // a level above the maximum is capped
    [InlineData(100, -3, null, "ok")] // RFC 3805: some remaining
    [InlineData(100, -2, null, "unknown")] // unknown
    [InlineData(100, -1, null, "unknown")] // other: no restriction, no level to show
    [InlineData(-2, 40, null, "unknown")] // unknown maximum: no share
    [InlineData(-1, 40, null, "unknown")]
    [InlineData(0, 40, null, "unknown")]
    public void SupplyLevelsFollowRfc3805(int max, int level, int? percent, string state)
    {
        var c = Assert.Single(SnmpPrinterStatus.ToConsumables(Reading(supplies: [new SnmpSupply(1, 3, 3, "Toner", max, level, 0)])));
        Assert.Equal((percent, state), (c.PercentRemaining, c.State));
    }

    [Fact]
    public void AReceptacleWithNoRoomLeftIsFull()
    {
        var c = Assert.Single(SnmpPrinterStatus.ToConsumables(Reading(supplies: [new SnmpSupply(1, 4, 4, null, 100, 0, 0)])));
        Assert.Equal(("Waste toner box", "full", true), (c.Name, c.State, c.IsWaste));
    }

    [Fact]
    public void AMissingCartridgeIsMissing()
    {
        var c = SnmpPrinterStatus.ToConsumables(Reading(supplies: [new SnmpSupply(4, 3, 21, "Yellow", 100, -2, 0)], alerts: [new SnmpAlert(1, 3, 11, 4, 1115, null)]));
        Assert.Equal("missing", Assert.Single(c).State);
    }

    [Fact]
    public void ADescriptionThatIsOnlyACodeIsNotShown()
    {
        var s = SnmpPrinterStatus.ToStatus(Reading(alerts: [new SnmpAlert(1, 4, 11, 1, 1104, "{13.A3.D2}")]));
        Assert.Equal("Toner low", Assert.Single(s.Alerts).Message);
    }

    // ------------------------------------------------------------------------------------------------ the connection's priority

    private static HttpMessageHandler NothingOverHttp() => new HostRouter(new Dictionary<string, HttpMessageHandler>());

    [Fact]
    public async Task APrinterThatAnswersOnlySnmpConnectsOverSnmp()
    {
        var agent = DemoAgent("workgroup-laser.txt");
        using var conn = await PrinterConnection.OpenAsync("192.0.2.14", transport: NothingOverHttp(), snmp: new SnmpRouter(new Dictionary<string, ISnmpTransport> { ["192.0.2.14"] = agent }));
        Assert.True(conn.Probe.Reachable);
        Assert.Equal(["SNMP"], conn.Probe.Interfaces);
        Assert.Equal(("Demo Laser 5200 Series", "DEMO0005200", "Office, 2nd floor"), (conn.Probe.Model, conn.Probe.SerialNumber, conn.Probe.Location));
        Assert.Null(conn.Probe.Uuid); // SNMP has no UUID: the printer is known by its address
        Assert.Equal("Ready", (await conn.GetStatusAsync()).Message);
        Assert.Equal(3, (await conn.GetSuppliesAsync()).Count);
        Assert.Empty(await conn.ReadUuidsAsync());
    }

    [Fact]
    public async Task APrinterThatAnswersIppIsNeverAskedOverSnmp()
    {
        var agent = DemoAgent("color-mfp.txt");
        var ipp = new FixtureHandler(name => name == "ipp_print.ipp.txt"
            ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name)) : null);
        using var conn = await PrinterConnection.OpenAsync("192.0.2.11", transport: new HostRouter(new Dictionary<string, HttpMessageHandler> { ["192.0.2.11"] = ipp }),
            snmp: agent);
        Assert.Contains("IPP", conn.Probe.Interfaces);
        Assert.DoesNotContain("SNMP", conn.Probe.Interfaces);
        await conn.GetStatusAsync();
        await conn.GetSuppliesAsync();
        Assert.Equal(0, agent.Requests);
    }

    [Fact]
    public async Task WithoutAnSnmpTransportNothingIsAskedOverSnmp()
    {
        using var conn = await PrinterConnection.OpenAsync("192.0.2.14", transport: NothingOverHttp());
        Assert.False(conn.Probe.Reachable);
    }

    private sealed class Switchable(ISnmpTransport to) : ISnmpTransport
    {
        public ISnmpTransport? To { get; set; } = to;

        public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct) =>
            To?.SendAsync(host, request, timeout, ct) ?? Task.FromResult<byte[]?>(null);
    }

    [Fact]
    public async Task AnSnmpPrinterThatStopsAnsweringIsOffline()
    {
        var snmp = new Switchable(DemoAgent("workgroup-laser.txt"));
        using var conn = await PrinterConnection.OpenAsync("192.0.2.14", transport: NothingOverHttp(), snmp: snmp);
        snmp.To = null; // turned off
        Assert.Equal("offline", (await conn.GetStatusAsync()).Code);
    }

    // ------------------------------------------------------------------------------------------------ queue printers with an address

    private static SpoolerQueue Queue(string port, string? monitor, uint status = 0, uint attributes = SpoolerFlags.AttributeLocal, int jobs = 0, string? address = null) =>
        new("Office color", port, "Demo Color MFP 4400 PCL6", status, attributes, jobs) { PortMonitor = monitor, PortAddress = address };

    [Theory]
    [InlineData("IP_192.0.2.15", "Standard TCP/IP Port", null, "192.0.2.15")]
    [InlineData("192.0.2.15_1", "Standard TCP/IP Port", null, "192.0.2.15")]
    [InlineData("Office printer", "Standard TCP/IP Port", "192.0.2.15", "192.0.2.15")] // a renamed port: its configured address
    [InlineData("IP_mfp.example", "Standard TCP/IP Port", null, "mfp.example")]
    [InlineData("http://192.0.2.15:631/ipp/print", "Internet Port", null, "192.0.2.15")]
    [InlineData("192.0.2.15:lp", "LPR Port", null, "192.0.2.15")]
    [InlineData("WSD-00000000-0000-4000-8000-000000000001", "WSD Port Monitor", null, null)] // WSD: no address in the port
    [InlineData("USB001", "USB Monitor", null, null)]
    [InlineData("Office printer", "Standard TCP/IP Port", null, null)] // renamed, address unknown: nothing to ask
    public void QueuesWithAnAddressCanBeAskedOverSnmp(string port, string monitor, string? address, string? expected) =>
        Assert.Equal(expected, QueueKinds.SnmpAddress(Queue(port, monitor, address: address)));

    [Fact]
    public void ARenamedTcpIpPortShowsItsAddress() =>
        Assert.Equal("Network (192.0.2.15)", QueueKinds.ConnectionDetail(Queue("Office color", "Standard TCP/IP Port", address: "192.0.2.15")));

    [Fact]
    public void ASharedQueueIsNotAskedOverSnmp() =>
        Assert.Null(QueueKinds.SnmpAddress(new SpoolerQueue(@"\192.0.2.30\Front desk", @"\192.0.2.30\Front desk", null, 0, SpoolerFlags.AttributeNetwork, 0)));

    private static async Task<SnmpReading> ColorMfpReading()
    {
        var printer = await SnmpPrinterClient.ProbeAsync(DemoAgent("color-mfp.txt"), "192.0.2.15");
        return await printer!.ReadAsync();
    }

    [Fact]
    public async Task ThePrintersOwnStatusLeadsWithWindowsJobsNote()
    {
        var windows = QueueStatusRead.From(SpoolerStatus.Describe(Queue("IP_192.0.2.15", "Standard TCP/IP Port", jobs: 2)));
        var merged = QueueSnmp.Merge(windows, await ColorMfpReading());
        Assert.Equal(("ready", "Ready", Severity.Warning, false), (merged.Status.Code, merged.Status.Message, merged.Status.Severity, merged.Offline));
        Assert.Equal("Magenta toner low.", Assert.Single(merged.Status.Alerts).Message);
        Assert.Equal("2 jobs are waiting.", merged.Status.Detail);
        Assert.Equal([71, 62, 8, 47], merged.Supplies.Where(s => !s.IsWaste).Select(s => s.PercentRemaining ?? -1));
        Assert.Equal("low", merged.Supplies[2].State);
    }

    [Fact]
    public async Task WindowsHoldingTheJobsStaysTheHeadline()
    {
        var paused = QueueStatusRead.From(SpoolerStatus.Describe(Queue("IP_192.0.2.15", "Standard TCP/IP Port", SpoolerFlags.StatusPaused)));
        var merged = QueueSnmp.Merge(paused, await ColorMfpReading());
        Assert.Equal(("paused", "Paused in Windows"), (merged.Status.Code, merged.Status.Message));
        Assert.Contains(merged.Status.Alerts, a => a.Id == "toner-low"); // markerTonerAlmostEmpty, as PWG 5100.9 maps it
        Assert.Equal(5, merged.Supplies.Count);

        var held = QueueStatusRead.From(SpoolerStatus.Describe(Queue("IP_192.0.2.15", "Standard TCP/IP Port", attributes: SpoolerFlags.AttributeLocal | SpoolerFlags.AttributeWorkOffline)));
        var stillHeld = QueueSnmp.Merge(held, await ColorMfpReading());
        Assert.Equal((SpoolerStatus.UsePrinterOfflineMessage, true), (stillHeld.Status.Message, stillHeld.Offline));
    }

    [Fact]
    public async Task APrinterThatAnswersIsntOfflineWhateverTheSpoolerSays()
    {
        var offline = QueueStatusRead.From(SpoolerStatus.Describe(Queue("IP_192.0.2.15", "Standard TCP/IP Port", SpoolerFlags.StatusOffline)));
        Assert.True(offline.Offline);
        Assert.False(QueueSnmp.Merge(offline, await ColorMfpReading()).Offline);
    }

    private sealed class FixedQueue(SpoolerQueue q) : IQueueStatusSource
    {
        public string Origin => "Windows and the printer's driver";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => Task.FromResult<QueueStatusRead?>(QueueStatusRead.From(SpoolerStatus.Describe(q)));
    }

    [Fact]
    public async Task AQueueSourceAddsTheSnmpStatusAndReadsItEvery15Seconds()
    {
        var agent = DemoAgent("color-mfp.txt");
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var source = new SnmpQueueStatusSource(new FixedQueue(Queue("IP_192.0.2.15", "Standard TCP/IP Port")), "192.0.2.15", agent) { Now = () => now };
        Assert.False(source.HasSupplyLevels);
        var read = await source.ReadAsync(default);
        Assert.Equal(5, read!.Supplies.Count);
        Assert.True(source.HasSupplyLevels);
        Assert.Contains("SNMP", source.Origin);

        var requests = agent.Requests;
        now += TimeSpan.FromSeconds(5);
        await source.ReadAsync(default);
        Assert.Equal(requests, agent.Requests); // the queue is read; the printer not yet
        now += TimeSpan.FromSeconds(15);
        await source.ReadAsync(default);
        Assert.True(agent.Requests > requests);
    }

    [Fact]
    public async Task AQueueSourceFallsBackToWindowsAndAsksAgainAMinuteLater()
    {
        var snmp = new Switchable(null!) { To = null };
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var source = new SnmpQueueStatusSource(new FixedQueue(Queue("IP_192.0.2.15", "Standard TCP/IP Port", SpoolerFlags.StatusTonerLow)), "192.0.2.15", snmp)
            { Now = () => now };
        var read = await source.ReadAsync(default);
        Assert.Equal(("toner-low", false), (Assert.Single(read!.Status.Alerts).Id, source.HasSupplyLevels));
        Assert.Empty(read.Supplies);
        Assert.Equal("Windows and the printer's driver", source.Origin);

        var agent = DemoAgent("color-mfp.txt");
        snmp.To = agent;
        now += TimeSpan.FromSeconds(30);
        await source.ReadAsync(default);
        Assert.Equal(0, agent.Requests); // not before a minute has passed
        now += TimeSpan.FromSeconds(31);
        Assert.Equal(5, (await source.ReadAsync(default))!.Supplies.Count);
    }

    [Fact]
    public async Task APrinterThatStopsAnsweringIsUnreachableThoughTheSpoolerSaysReady()
    {
        var snmp = new Switchable(DemoAgent("color-mfp.txt"));
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var source = new SnmpQueueStatusSource(new FixedQueue(Queue("IP_192.0.2.15", "Standard TCP/IP Port", jobs: 1)), "192.0.2.15", snmp) { Now = () => now };
        Assert.False((await source.ReadAsync(default))!.Offline);

        snmp.To = null; // turned off
        now += TimeSpan.FromSeconds(16);
        Assert.False((await source.ReadAsync(default))!.Offline); // one read without a reply could be a dropped datagram
        now += TimeSpan.FromSeconds(5);
        var off = (await source.ReadAsync(default))!;
        Assert.Equal(("Can't reach the printer", true), (off.Status.Message, off.Offline));
        Assert.EndsWith("1 job is waiting.", off.Status.Detail);
        now += TimeSpan.FromSeconds(5);
        Assert.True((await source.ReadAsync(default))!.Offline); // still, between the tries

        snmp.To = DemoAgent("color-mfp.txt"); // back on: asked again 20 s after it went quiet
        now += TimeSpan.FromSeconds(16);
        Assert.False((await source.ReadAsync(default))!.Offline);
    }

    [Fact]
    public async Task AQueueRemovedFromWindowsIsNullEvenWhenThePrinterAnswers()
    {
        var gone = new SnmpQueueStatusSource(new NoQueue(), "192.0.2.15", DemoAgent("color-mfp.txt"));
        Assert.Null(await gone.ReadAsync(default));
    }

    private sealed class NoQueue : IQueueStatusSource
    {
        public string Origin => "Windows";
        public bool HasSupplyLevels => false;
        public Task<QueueStatusRead?> ReadAsync(CancellationToken ct) => Task.FromResult<QueueStatusRead?>(null);
    }

    // ------------------------------------------------------------------------------------------------ review fixes

    /// <summary>Passes requests to <paramref name="inner"/> unless <paramref name="answer"/> replies for it (an error, garbage).</summary>
    private sealed class Tampered(ISnmpTransport inner, Func<SnmpMessage, byte[]?> answer) : ISnmpTransport
    {
        public bool On { get; set; } = true;

        public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct) =>
            On && answer(SnmpMessage.Decode(request)) is { } reply ? Task.FromResult<byte[]?>(reply) : inner.SendAsync(host, request, timeout, ct);
    }

    private static byte[] ErrorReply(SnmpMessage request, int status, int index = 1) =>
        new SnmpMessage(request.Version, request.Community, SnmpPduType.Response, request.RequestId, status, index, request.VarBinds).Encode();

    [Fact]
    public async Task AnUndecodableDatagramIsIgnoredLikeAStrayReply()
    {
        var sent = 0;
        var agent = new Tampered(Rfc3416Agent(), _ => sent++ == 0 ? Hex("3003020100") : null); // the first reply isn't SNMP
        var got = await new SnmpClient(agent, "192.0.2.50", SnmpVersion.V2c).GetAsync([Oid.Parse("1.3.6.1.2.1.1.3.0")]);
        Assert.Equal(123456L, got[0].Value.Number);
    }

    [Fact]
    public void UnknownValueTypesAreKeptAsOpaqueBytes()
    {
        // A Response whose one binding is 0x47 (UInteger32 of RFC 1442's SMI), which a GetBulk running past a table may meet.
        var bytes = Hex("3022 020101 0406 7075626C6963 A215 020101 020100 020100 300A 3008 0603 2B0601 470105");
        var m = SnmpMessage.Decode(bytes);
        Assert.Equal(0x47, m.VarBinds[0].Value.Tag);
        Assert.Equal(new byte[] { 5 }, m.VarBinds[0].Value.Bytes);
        Assert.Null(m.VarBinds[0].Value.Int);
        Assert.Equal(bytes, m.Encode());
    }

    [Fact]
    public async Task AWalkFallsBackToGetNextWhenGetBulkFails()
    {
        var agent = new Tampered(Rfc3416Agent(), m => m.Type == SnmpPduType.GetBulkRequest ? ErrorReply(m, SnmpMessage.GenErr) : null);
        var columns = await new SnmpClient(agent, "192.0.2.50", SnmpVersion.V2c).WalkAsync([PhysAddress, MediaType]);
        Assert.Equal(3, columns[0].Count);
        Assert.Equal([3L, 4L, 3L], columns[1].Select(r => r.Value.Number));
    }

    [Fact]
    public async Task AColumnTheAgentFailsOnIsEmptyAndTheOthersAreRead()
    {
        var alertTable = PrinterMib.AlertSeverity.ToString();
        alertTable = alertTable[..alertTable.LastIndexOf('.')];
        var agent = new Tampered(DemoAgent("color-mfp.txt"),
            m => m.VarBinds.Any(v => v.Name.ToString().StartsWith(alertTable + ".", StringComparison.Ordinal)) ? ErrorReply(m, SnmpMessage.GenErr) : null);
        var printer = await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.15");
        var reading = await printer!.ReadAsync();
        Assert.Empty(reading.Alerts); // genErr on prtAlertTable: no alerts, not a failed read
        Assert.Equal(5, reading.Supplies.Count);
    }

    [Fact]
    public async Task OneMissedReplyOrAnErrorDoesntMakeAQueuePrinterUnreachable()
    {
        var off = new Switchable(DemoAgent("color-mfp.txt"));
        var errors = new Tampered(off, m => ErrorReply(m, SnmpMessage.GenErr)) { On = false };
        var now = new DateTime(2026, 1, 1, 12, 0, 0, DateTimeKind.Utc);
        var source = new SnmpQueueStatusSource(new FixedQueue(Queue("IP_192.0.2.15", "Standard TCP/IP Port")), "192.0.2.15", errors) { Now = () => now };
        Assert.Equal(5, (await source.ReadAsync(default))!.Supplies.Count);

        errors.On = true; // the agent answers, with genErr: it is there
        now += TimeSpan.FromSeconds(16);
        var answered = (await source.ReadAsync(default))!;
        Assert.False(answered.Offline);
        Assert.Equal(5, answered.Supplies.Count); // the last reading stays
        errors.On = false;

        off.To = null; // one read without a reply (a dropped datagram, or the printer just turned off)
        now += TimeSpan.FromSeconds(16);
        var once = (await source.ReadAsync(default))!;
        Assert.False(once.Offline);
        now += TimeSpan.FromSeconds(5);
        Assert.True((await source.ReadAsync(default))!.Offline); // the second in a row: unreachable
    }

    [Fact]
    public void CriticalAlertsWithOtherOrUnknownCodesAreKeptWithTheirWords()
    {
        SnmpAlert[] alerts =
        [
            new(1, 3, 5, -1, 1, "Fuser error, call for service"), // critical, code other
            new(2, 4, 5, -1, 2, null), // warning, code unknown, no words
            new(3, 1, 5, -1, 1, "Something"), // severity other: not a problem
            new(4, 5, 5, -1, 2, "Changed"), // a change event
        ];
        var s = SnmpPrinterStatus.ToStatus(Reading(alerts: alerts));
        Assert.Equal(2, s.Alerts.Count);
        Assert.Equal((Severity.Error, "Fuser error, call for service."), (s.Alerts[0].Severity, s.Alerts[0].Message));
        Assert.Equal((Severity.Warning, "The printer reports a problem"), (s.Alerts[1].Severity, s.Alerts[1].Message));
    }

    [Fact]
    public void ServiceRequestedIsLeftOutBesideAWarningToo()
    {
        var s = SnmpPrinterStatus.ToStatus(Reading(2, 3, [0x21])); // lowToner + serviceRequested
        Assert.Equal(("toner-low", Severity.Warning), (Assert.Single(s.Alerts).Id, s.Severity));
    }

    [Fact]
    public void AWasteBoxReportedAsConsumedIsntFullAtLevelZero()
    {
        var consumed = Assert.Single(SnmpPrinterStatus.ToConsumables(Reading(supplies: [new SnmpSupply(1, 3, 4, "Waste Toner Box", 100, 0, 0)])));
        Assert.Equal((true, "ok"), (consumed.IsWaste, consumed.State));
        var other = Assert.Single(SnmpPrinterStatus.ToConsumables(Reading(supplies: [new SnmpSupply(1, 1, 4, "Waste Toner Box", 100, 0, 0)])));
        Assert.Equal("full", other.State); // class other: a waste box's level is the room left
    }

    // A printer that answered only SNMP when it was added, and the rest.

    private static HttpMessageHandler IppAt(string host) => new HostRouter(new Dictionary<string, HttpMessageHandler>
    {
        [host] = new FixtureHandler(name => name == "ipp_print.ipp.txt"
            ? File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "inkjet-demo", name)) : null),
    });

    [Fact]
    public async Task OnlyAPrinterAddedAsSnmpOnlyIsReadOverSnmp()
    {
        var agent = DemoAgent("workgroup-laser.txt");
        // An IPP printer waking up answers SNMP before HTTP: it is offline for a moment, not an SNMP-only printer.
        using var waking = await PrinterConnection.OpenAsync("192.0.2.14", transport: NothingOverHttp(), snmp: SnmpDevice.TransportFor(null, agent));
        Assert.False(waking.Probe.Reachable);
        Assert.Equal(0, agent.Requests);

        var added = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.14"))!.Identity);
        using var snmpOnly = await PrinterConnection.OpenAsync("192.0.2.14", transport: NothingOverHttp(), snmp: SnmpDevice.TransportFor(added, agent));
        Assert.Equal(["SNMP"], snmpOnly.Probe.Interfaces);
    }

    [Fact]
    public async Task AnSnmpConnectionMovesToIppWhenThePrinterAnswersIt()
    {
        var agent = DemoAgent("color-mfp.txt");
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(agent, "192.0.2.11"))!.Identity);
        using var conn = await PrinterConnection.OpenAsync("192.0.2.11", transport: NothingOverHttp(), snmp: agent);
        Assert.Null(await conn.TryRicherAsync(known, transport: NothingOverHttp()));
        using var richer = await conn.TryRicherAsync(known, transport: IppAt("192.0.2.11"));
        Assert.NotNull(richer);
        Assert.Contains("IPP", richer.Probe.Interfaces);
        Assert.DoesNotContain("SNMP", richer.Probe.Interfaces);
    }

    [Fact]
    public void ASerialNumberThatDisagreesIsAnotherDevice()
    {
        var known = new SnmpDevice("DEMO0005200", "Demo Laser 5200 Series", "demo-laser");
        Assert.Equal(DeviceIdentity.Same, known.Identify("DEMO0005200"));
        Assert.Equal(DeviceIdentity.Different, known.Identify("DEMO0004400"));
        Assert.Equal(DeviceIdentity.Unknown, known.Identify((string?)null));
        Assert.Equal(DeviceIdentity.Unknown, new SnmpDevice(null, null, null).Identify("DEMO0005200"));
    }

    [Fact]
    public async Task AnotherSnmpPrinterAtTheAddressIsADifferentDevice()
    {
        var snmp = new Switchable(DemoAgent("workgroup-laser.txt"));
        var known = SnmpDevice.From((await SnmpPrinterClient.ProbeAsync(snmp, "192.0.2.14"))!.Identity);
        using var conn = await PrinterConnection.OpenAsync("192.0.2.14", transport: NothingOverHttp(), snmp: snmp);
        Assert.Equal(DeviceIdentity.Same, known.Identify((await conn.ReadSnmpIdentityAsync())!));

        snmp.To = DemoAgent("color-mfp.txt"); // DHCP gave the address to another printer
        Assert.Equal(DeviceIdentity.Different, known.Identify((await conn.ReadSnmpIdentityAsync())!));
        snmp.To = null;
        Assert.Null(await conn.ReadSnmpIdentityAsync()); // no answer: can't tell
        Assert.Equal(DeviceIdentity.Different, known.Identify(new SnmpIdentity(SnmpVersion.V2c, 1, "Demo Laser 5200 Series", null, "demo-laser", null, "DEMO0009999")));
        Assert.Equal(DeviceIdentity.Unknown, known.Identify(new SnmpIdentity(SnmpVersion.V2c, 1, null, null, null, null, null)));
    }
}
