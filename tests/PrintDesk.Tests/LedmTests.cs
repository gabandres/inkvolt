using System.Xml.Linq;
using PrintDesk.Core.Ledm;
using PrintDesk.Core.Model;

namespace PrintDesk.Tests;

public class LedmTests
{
    [Fact]
    public void DiscoveryTree_maps_resource_types_and_interfaces()
    {
        var tree = DiscoveryTree.Parse(Fixture.Xml("DevMgmt_DiscoveryTree.xml"));

        Assert.Equal("/DevMgmt/ProductStatusDyn.xml", tree.UriFor(LedmResource.ProductStatusDyn));
        Assert.Equal("/EventMgmt/EventTable.xml", tree.UriFor(LedmResource.EventTable));
        Assert.Equal("/ipp/print", tree.UriFor("pwg:hpIPPPrint"));
        Assert.True(tree.HasCdm);
        Assert.True(tree.HasEscl);
        Assert.True(tree.HasEvents);
    }

    [Fact]
    public void Status_sleeping_printer_is_ready()
    {
        var s = LedmParsers.ParseStatus(Fixture.Xml("DevMgmt_ProductStatusDyn.xml"));

        Assert.Equal("inPowerSave", s.Code);
        Assert.Equal("Ready (sleeping)", s.Message);
        Assert.Equal(Severity.Info, s.Severity);
        Assert.Empty(s.Alerts);
    }

    [Fact]
    public void Status_with_alerts_takes_worst_severity()
    {
        var doc = XDocument.Parse("""
            <psdyn:ProductStatusDyn xmlns:psdyn="urn:psdyn" xmlns:pscat="urn:pscat" xmlns:ad="urn:ad" xmlns:dd="urn:dd">
              <psdyn:Status><pscat:StatusCategory>jamInPrinter</pscat:StatusCategory></psdyn:Status>
              <psdyn:AlertTable>
                <psdyn:Alert><ad:ProductStatusAlertID>cartridgeLow</ad:ProductStatusAlertID><dd:Severity>Warning</dd:Severity>
                  <ad:AlertDetails><ad:AlertDetailsMarkerColor>Black</ad:AlertDetailsMarkerColor></ad:AlertDetails></psdyn:Alert>
                <psdyn:Alert><ad:ProductStatusAlertID>jamInPrinter</ad:ProductStatusAlertID><dd:Severity>Error</dd:Severity></psdyn:Alert>
              </psdyn:AlertTable>
            </psdyn:ProductStatusDyn>
            """);

        var s = LedmParsers.ParseStatus(doc);

        Assert.Equal("Paper jam", s.Message);
        Assert.Equal(Severity.Error, s.Severity);
        Assert.Equal(["Toner low (Black)", "Paper jam"], s.Alerts.Select(a => a.Message));
    }

    [Fact]
    public void Consumables_merge_pages_remaining_from_usage()
    {
        var c = Assert.Single(LedmParsers.ParseConsumables(
            Fixture.Xml("DevMgmt_ConsumableConfigDyn.xml"), Fixture.Xml("DevMgmt_ProductUsageDyn.xml")));

        Assert.Equal("Black toner", c.Name);
        Assert.Equal(20, c.PercentRemaining);
        Assert.Equal("ok", c.State);
        Assert.Equal("W1340A", c.ProductNumber);
        Assert.Equal("134A", c.SelectibilityNumber);
        Assert.Equal(100, c.EstimatedPagesRemaining);
        Assert.Equal(new DateOnly(2025, 9, 29), c.Installed);
        Assert.False(c.IsLow);
    }

    [Fact]
    public void ProductConfig_identity()
    {
        var p = LedmParsers.ParseProductConfig(Fixture.Xml("DevMgmt_ProductConfigDyn.xml"));

        Assert.Equal("HP LaserJet MFP M234dw", p.MakeAndModel);
        Assert.Equal("12345678-1234-4abc-8def-123456789abc", p.Uuid);
        Assert.Equal("6GW99A", p.ProductNumber);
        Assert.True(p.AdminPasswordSet);
    }

    [Fact]
    public void Usage_counters()
    {
        var u = LedmParsers.ParseUsage(Fixture.Xml("DevMgmt_ProductUsageDyn.xml"));

        Assert.Equal(387, u.TotalImpressions);
        Assert.Equal(9, u.DuplexSheets);
        Assert.Equal(39, u.ScanImages);
    }

    [Fact]
    public void EventTable()
    {
        var e = Assert.Single(LedmParsers.ParseEventTable(Fixture.Xml("EventMgmt_EventTable.xml")));

        Assert.Equal("PowerUpEvent", e.Category);
        Assert.Equal("34-1", e.AgingStamp);
        Assert.Equal(LedmResource.ProductStatusDyn, e.ResourceType);
    }

    [Theory]
    [InlineData("subscribedPagesLow", "Subscribed pages low")]
    [InlineData("na_letter", "Na letter")]
    [InlineData("ADFJam", "ADFJam")]
    public void Humanize(string id, string expected) => Assert.Equal(expected, StatusText.Humanize(id));
}
