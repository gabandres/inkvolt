using System.Xml.Linq;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;

namespace InkvoltPrint.Tests;

public class FirmwareTests
{
    private static readonly XNamespace Fwu = "http://www.hp.com/schemas/imaging/con/ledm/firmwareupdatedyn/2010/12/12";

    private static FirmwareUpdateSettings Captured() =>
        FirmwareUpdateSettings.Parse(Fixture.Xml("FirmwareUpdate_FirmwareUpdateDyn.xml"), Fixture.Xml("FirmwareUpdate_FirmwareUpdateCap.xml"),
            "/FirmwareUpdate/WebFWUpdate/Config")!;

    [Fact]
    public void Manifest_paths_nest_below_the_root_link()
    {
        var map = LedmManifest.Parse(Fixture.Xml("FirmwareUpdate_FirmwareUpdateManifest.xml"));

        Assert.Equal("/FirmwareUpdate/FirmwareUpdateDyn.xml", map["FirmwareUpdateDyn"]);
        Assert.Equal("/FirmwareUpdate/FirmwareUpdateCap.xml", map["FirmwareUpdateCap"]);
        Assert.Equal("/FirmwareUpdate/WebFWUpdate", map["FirmwareUpdate"]);
        Assert.Equal("/FirmwareUpdate/WebFWUpdate/Config", map["FirmwareUpdateConfig"]);
        Assert.Equal("/FirmwareUpdate/WebFWUpdate/State", map["FirmwareUpdateState"]);
    }

    [Fact]
    public void Tree_points_to_the_firmware_manifest()
    {
        var tree = DiscoveryTree.Parse(Fixture.Xml("DevMgmt_DiscoveryTree.xml"));

        Assert.Equal("/FirmwareUpdate/FirmwareUpdateManifest.xml", tree.ManifestFor(LedmResource.FirmwareUpdateManifest));
    }

    [Fact]
    public void Reads_the_m234dw_auto_update_settings()
    {
        var s = Captured();

        Assert.Equal(FirmwareUpdateMode.Off, s.Mode);
        Assert.Equal([FirmwareUpdateMode.Automatic, FirmwareUpdateMode.Notify, FirmwareUpdateMode.Off], s.Choices);
        Assert.True(s.CanChange);
        Assert.True(s.HasCheck);
        Assert.Equal("idle", s.Status);
        Assert.Null(s.StatusMessage);
    }

    [Theory]
    [InlineData("enabled", "enabled", FirmwareUpdateMode.Automatic)]
    [InlineData("enabled", "disabled", FirmwareUpdateMode.Notify)]
    [InlineData("disabled", "disabled", FirmwareUpdateMode.Off)]
    [InlineData("disabled", "enabled", FirmwareUpdateMode.Automatic)] // installs whatever it's told about: treat as automatic
    public void Mode_from_the_two_switches(string check, string update, FirmwareUpdateMode expected)
    {
        var dyn = Fixture.Xml("FirmwareUpdate_FirmwareUpdateDyn.xml");
        dyn.Descendants(Fwu + "AutomaticCheck").Single().Value = check;
        dyn.Descendants(Fwu + "AutomaticUpdate").Single().Value = update;

        Assert.Equal(expected, FirmwareUpdateSettings.Parse(dyn, Fixture.Xml("FirmwareUpdate_FirmwareUpdateCap.xml"), "/c")!.Mode);
    }

    [Fact]
    public void Read_only_cap_offers_no_choices()
    {
        var cap = Fixture.Xml("FirmwareUpdate_FirmwareUpdateCap.xml");
        foreach (var support in cap.Descendants().Where(e => e.Name.LocalName is "AutomaticUpdateSupport"))
            support.SetAttributeValue("access", "readOnly");

        var s = FirmwareUpdateSettings.Parse(Fixture.Xml("FirmwareUpdate_FirmwareUpdateDyn.xml"), cap, "/c")!;

        Assert.Empty(s.Choices);
        Assert.False(s.CanChange);
    }

    [Fact]
    public void Check_switch_alone_is_not_enough_for_notify()
    {
        var cap = Fixture.Xml("FirmwareUpdate_FirmwareUpdateCap.xml");
        cap.Descendants().Single(e => e.Name.LocalName == "AutomaticCheckSupport").Remove();

        var s = FirmwareUpdateSettings.Parse(Fixture.Xml("FirmwareUpdate_FirmwareUpdateDyn.xml"), cap, "/c")!;

        Assert.Equal([FirmwareUpdateMode.Automatic, FirmwareUpdateMode.Off], s.Choices);
    }

    [Fact]
    public void No_firmware_update_settings_without_a_config()
    {
        var dyn = XDocument.Parse("""<d:FirmwareUpdateDyn xmlns:d="urn:x"><d:FirmwareUpdate><d:Class>WebFWUpdate</d:Class></d:FirmwareUpdate></d:FirmwareUpdateDyn>""");

        Assert.Null(FirmwareUpdateSettings.Parse(dyn, null, "/c"));
    }

    [Theory]
    [InlineData(FirmwareUpdateMode.Automatic, "enabled", "enabled")]
    [InlineData(FirmwareUpdateMode.Notify, "enabled", "disabled")]
    [InlineData(FirmwareUpdateMode.Off, "disabled", "disabled")]
    public void BuildPut_writes_both_switches_in_the_device_namespace(FirmwareUpdateMode mode, string check, string update)
    {
        var body = Captured().BuildPut(mode);

        Assert.Equal(Fwu + "FirmwareUpdateConfig", body.Root!.Name);
        Assert.Equal(["AutomaticCheck", "AutomaticUpdate"], body.Root.Elements().Select(e => e.Name.LocalName));
        Assert.Equal(check, body.Root.Element(Fwu + "AutomaticCheck")!.Value);
        Assert.Equal(update, body.Root.Element(Fwu + "AutomaticUpdate")!.Value);
        Assert.Equal("fwudyn", body.Root.GetPrefixOfNamespace(Fwu));
    }

    [Theory]
    [InlineData("available", "A firmware update is available.")]
    [InlineData("downloading", "Downloading an update…")]
    [InlineData("checkFailed", "The printer's last update check failed.")]
    public void Status_words(string status, string expected) =>
        Assert.Equal(expected, (Captured() with { Status = status }).StatusMessage);

    [Fact]
    public async Task Client_finds_the_settings_through_the_manifest()
    {
        using var http = new DeviceHttp(FixtureHandler.DemoHost, new FixtureHandler(name =>
        {
            var path = Path.Combine(AppContext.BaseDirectory, "Fixtures", "m234dw", name);
            return File.Exists(path) ? File.ReadAllBytes(path) : null;
        }));

        var s = await new LedmClient(http).GetFirmwareUpdateAsync();

        Assert.NotNull(s);
        Assert.Equal("/FirmwareUpdate/WebFWUpdate/Config", s.ConfigPath);
        Assert.Equal(FirmwareUpdateMode.Off, s.Mode);
    }

    [Fact]
    public void Firmware_from_ledm_is_the_release_date()
    {
        var product = LedmParsers.ParseProductConfig(Fixture.Xml("DevMgmt_ProductConfigDyn.xml"));

        var fw = FirmwareInfo.From(product, null)!;

        Assert.Equal((null, "2024-08-13"), (fw.Version, fw.Date));
        Assert.Equal("2024-08-13", fw.Display);
        Assert.Equal("SAYPRO1N001.2045A (2024-08-13)", FirmwareInfo.From(product with { FirmwareRevision = "SAYPRO1N001.2045A" }, null)!.Display);
        Assert.Null(FirmwareInfo.From(null, null));
    }
}
