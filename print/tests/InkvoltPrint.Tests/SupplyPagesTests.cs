using InkvoltPrint.Core.Cdm;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Tests;

/// <summary>
/// Pages per cartridge beyond LEDM: the pages left and what a full cartridge is rated for (CDM's capacity, IPP's
/// <c>printer-supply</c>, the Printer MIB's supplies counted in impressions or sheets) and the lifetime page count the supply
/// history counts pages per cartridge with (IPP's <c>printer-impressions-completed</c>, prtMarkerLifeCount).
/// </summary>
public class SupplyPagesTests
{
    private static string Read(string folder, string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", folder, name));

    private static SnmpAgent Laser(Func<string, string>? edit = null) =>
        new(SnmpAgent.ParseWalk((edit ?? (t => t))(Read("snmp-demo", "workgroup-laser.txt"))));

    // ------------------------------------------------------------------------------------------------ CDM

    [Fact]
    public void A_CDM_toner_s_capacity_in_pages_is_its_yield()
    {
        var s = CdmParsers.ParseSupplies(Read("cdm-laser", "cdm_supply_v1_suppliesPublic.json"));
        Assert.Equal([3150, 2200, 2200, 2200], s.Select(c => c.PageYield));
        Assert.Equal((200, 2200), (s[1].EstimatedPagesRemaining, s[1].PageYield));
    }

    [Theory]
    [InlineData("""{"suppliesList":[{"supplyType":"toner","capacity":3000,"capacityUnit":"milliliters"}]}""")] // not pages
    [InlineData("""{"suppliesList":[{"supplyType":"toner","capacity":3000}]}""")] // no unit: can't tell
    [InlineData("""{"suppliesList":[{"supplyType":"toner","capacity":-1,"capacityUnit":"pages"}]}""")]
    [InlineData("""{"suppliesList":[{"supplyType":"toner","capacity":"lots","capacityUnit":"pages"}]}""")]
    [InlineData("""{"suppliesList":[{"supplyType":"toner","capacity":99999999999,"capacityUnit":"pages"}]}""")]
    public void A_CDM_capacity_that_isn_t_pages_gives_no_yield(string json) =>
        Assert.Null(Assert.Single(CdmParsers.ParseSupplies(json)).PageYield);

    [Fact]
    public void Ink_tanks_say_no_yield_when_they_give_none() =>
        Assert.All(CdmParsers.ParseSupplies(Read("cdm-tank", "cdm_supply_v1_suppliesPublic.json")), c => Assert.Null(c.PageYield));

    // ------------------------------------------------------------------------------------------------ IPP

    private static IppResponse Ipp(params string[] lines) =>
        IppCodec.Decode(IppCodec.EncodeResponse(0, 1, IppText.Parse(string.Join('\n', lines))));

    private static readonly string[] TwoToners =
    [
        "marker-names name Black toner", "marker-names name Drum",
        "marker-types keyword toner-cartridge", "marker-types keyword opc",
        "marker-levels integer 35", "marker-levels integer 80",
    ];

    [Fact]
    public void IPP_printer_supply_in_impressions_gives_pages_left_and_yield()
    {
        var r = Ipp([.. TwoToners,
            "printer-supply octetString index=1;class=supplyThatIsConsumed;type=tonerCartridge;unit=impressions;maxcapacity=3000;level=1050;colorantname=black;",
            "printer-supply octetString index=2;class=supplyThatIsConsumed;type=opc;unit=sheets;maxcapacity=30000;level=24000;colorantname=unknown;"]);
        var c = IppClient.ToConsumables(r);
        Assert.Equal((1050, 3000), (c[0].EstimatedPagesRemaining, c[0].PageYield));
        Assert.Equal((24000, 30000), (c[1].EstimatedPagesRemaining, c[1].PageYield));
        Assert.Equal(35, c[0].PercentRemaining); // the level still comes from marker-levels
    }

    [Fact]
    public void IPP_printer_supply_in_percent_or_of_another_length_gives_no_pages()
    {
        var percent = IppClient.ToConsumables(Ipp([.. TwoToners,
            "printer-supply octetString type=tonerCartridge;unit=percent;maxcapacity=100;level=35;",
            "printer-supply octetString type=opc;unit=percent;maxcapacity=100;level=80;"]));
        Assert.All(percent, c => Assert.Equal((null, null), (c.EstimatedPagesRemaining, c.PageYield)));

        // One printer-supply for two markers: which supply it is can't be told, so neither gets it.
        var one = IppClient.ToConsumables(Ipp([.. TwoToners, "printer-supply octetString unit=impressions;maxcapacity=3000;level=1050;"]));
        Assert.All(one, c => Assert.Null(c.EstimatedPagesRemaining));

        Assert.All(IppClient.ToConsumables(Ipp(TwoToners)), c => Assert.Null(c.PageYield));
    }

    [Theory]
    [InlineData("unit=impressions;maxcapacity=3000;level=-3;", null, 3000)] // some left: no count
    [InlineData("unit=impressions;maxcapacity=3000;level=4000;", null, 3000)] // more left than it holds: not believed
    [InlineData("unit=impressions;maxcapacity=-2;level=500;", 500, null)] // unknown maximum
    [InlineData("unit=impressions;maxcapacity=x;level=99999999999;", null, null)]
    [InlineData("unit=impressions", null, null)]
    [InlineData("", null, null)]
    [InlineData(";;==;level;=5;unit=;", null, null)]
    [InlineData(" unit = sheets ; maxcapacity = 200 ; level = 150 ", 150, 200)]
    public void IPP_printer_supply_values_are_read_strictly(string value, int? left, int? yield)
    {
        var s = IppSupply.Parse(value);
        Assert.Equal((left, yield), (s.PagesLeft, s.PageYield));
    }

    [Fact]
    public void A_huge_printer_supply_value_is_read_only_so_far()
    {
        var s = IppSupply.Parse("unit=impressions;maxcapacity=3000;" + new string('x', 100_000) + ";level=10;");
        Assert.Equal((null, 3000), (s.PagesLeft, s.PageYield));
    }

    [Theory]
    [InlineData("printer-impressions-completed integer 48213", 48213)]
    [InlineData("printer-impressions-completed integer -1", null)]
    [InlineData("printer-info text no page count", null)]
    public void IPP_s_page_count_is_printer_impressions_completed(string line, int? pages) =>
        Assert.Equal(pages, IppClient.ToUsage(Ipp(line))?.TotalImpressions);

    [Fact]
    public void The_status_request_asks_for_printer_supply_and_the_page_count()
    {
        Assert.Contains("printer-supply", IppClient.StatusAttributes);
        Assert.Contains("printer-impressions-completed", IppClient.StatusAttributes);
    }

    // ------------------------------------------------------------------------------------------------ SNMP (Printer MIB)

    [Fact]
    public async Task The_demo_laser_s_supplies_count_impressions()
    {
        var printer = await SnmpPrinterClient.ProbeAsync(Laser(), "192.0.2.14");
        var supplies = await printer!.GetSuppliesAsync();
        Assert.Equal((1050, 3000), (supplies[0].EstimatedPagesRemaining, supplies[0].PageYield));
        Assert.Equal((24000, 30000), (supplies[1].EstimatedPagesRemaining, supplies[1].PageYield));
        Assert.Equal((null, null), (supplies[2].EstimatedPagesRemaining, supplies[2].PageYield)); // the waste box, in percent
        Assert.Equal(48213, (await printer.ReadAsync()).PageCount);
    }

    [Theory]
    [InlineData(19, 3000, 1050, null, null)] // percent
    [InlineData(2, 3000, 1050, null, null)] // unknown unit
    [InlineData(0, 3000, 1050, null, null)] // no unit read
    [InlineData(8, 3000, 1050, 1050, 3000)] // sheets
    [InlineData(7, 3000, -3, null, 3000)] // some left
    [InlineData(7, -2, 1050, 1050, null)] // unknown maximum
    [InlineData(7, 3000, 3100, null, 3000)] // more than it holds
    public void SNMP_supplies_give_pages_only_in_impressions_or_sheets(int unit, int max, int level, int? left, int? yield)
    {
        var reading = new SnmpReading(2, 3, [0, 0], [], [new SnmpSupply(1, 3, 3, "Toner", max, level, 0) { Unit = unit }], new Dictionary<int, string>());
        var c = Assert.Single(SnmpPrinterStatus.ToConsumables(reading));
        Assert.Equal((left, yield), (c.EstimatedPagesRemaining, c.PageYield));
    }

    [Theory]
    [InlineData(".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 7", ".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 3", null)] // ten-thousandths of an inch
    [InlineData(".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 7", ".1.3.6.1.2.1.43.10.2.1.3.1.1 = INTEGER: 8", 48213)] // sheets
    [InlineData(".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 48213", ".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 4294967295", null)] // past int: not pages
    [InlineData(".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 48213", ".1.3.6.1.2.1.43.10.2.1.4.1.1 = STRING: \"48213\"", null)] // not a number
    [InlineData(".1.3.6.1.2.1.43.10.2.1.4.1.1 = Counter32: 48213", "", null)] // no life count
    public async Task SNMP_s_page_count_is_the_marker_s_life_count_in_pages(string line, string with, int? pages)
    {
        var printer = await SnmpPrinterClient.ProbeAsync(Laser(t => t.Replace(line, with)), "192.0.2.14");
        Assert.Equal(pages, (await printer!.ReadAsync()).PageCount);
    }

    [Fact]
    public async Task A_printer_read_over_SNMP_gives_its_page_count_with_the_reading()
    {
        using var conn = await PrinterConnection.OpenAsync("192.0.2.14", transport: new FixtureHandler(_ => null), snmp: Laser());
        Assert.True(conn.OverSnmp);
        var reading = await conn.ReadAsync();
        Assert.Equal(48213, reading.Usage?.TotalImpressions);
        Assert.Equal(1050, reading.Supplies![0].EstimatedPagesRemaining);
    }
}
