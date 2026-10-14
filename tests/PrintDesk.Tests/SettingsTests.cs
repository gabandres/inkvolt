using System.Xml.Linq;
using PrintDesk.Core.Ledm;

namespace PrintDesk.Tests;

public class SettingsTests
{
    private static List<LedmSetting> ReadAll() =>
    [
        .. LedmSettingCatalog.Read(LedmSettingCatalog.All, Fixture.Xml("DevMgmt_ProductConfigDyn.xml"), Fixture.Xml("DevMgmt_ProductConfigCap.xml")),
        .. LedmSettingCatalog.Read(LedmSettingCatalog.All, Fixture.Xml("DevMgmt_PrintConfigDyn.xml"), Fixture.Xml("DevMgmt_PrintConfigCap.xml")),
        .. LedmSettingCatalog.Read(LedmSettingCatalog.All, Fixture.Xml("DevMgmt_MediaHandlingDyn.xml"), Fixture.Xml("DevMgmt_MediaHandlingCap.xml")),
    ];

    [Fact]
    public void Reads_every_catalog_setting_from_the_m234dw()
    {
        var settings = ReadAll().ToDictionary(s => s.Def.Key);

        Assert.Equal(LedmSettingCatalog.All.Select(d => d.Key).Order(), settings.Keys.Order());
        Assert.Equal("1minute", settings["PowerSaveTimeout"].Value);
        Assert.Equal(["1minute", "5minutes", "15minutes", "30minutes", "1hour"], settings["PowerSaveTimeout"].Choices);
        Assert.Equal("15_minutes", settings["ShutDownDelay"].Value);
        Assert.Equal(32, settings["FriendlyName"].MaxLength);
        Assert.Equal((1, 999), (settings["DefaultPrintCopies"].Min, settings["DefaultPrintCopies"].Max));
        Assert.Equal("any", settings["MediaSizeName"].Value);
        Assert.Contains("iso_a4_210x297mm", settings["MediaSizeName"].Choices);
    }

    [Fact]
    public void Read_skips_settings_the_cap_marks_read_only()
    {
        var cap = XDocument.Parse("""<c xmlns:dd="urn:dd"><PowerSaveTimerSupport access="readOnly"><dd:PowerSaveTimeout>1minute</dd:PowerSaveTimeout></PowerSaveTimerSupport></c>""");
        var dyn = Fixture.Xml("DevMgmt_ProductConfigDyn.xml");

        Assert.DoesNotContain(LedmSettingCatalog.Read(LedmSettingCatalog.All, dyn, cap), s => s.Def.Key == "PowerSaveTimeout");
    }

    [Fact]
    public void BuildPut_contains_only_changed_leaves_with_device_namespaces()
    {
        var dyn = Fixture.Xml("DevMgmt_ProductConfigDyn.xml");
        var defs = LedmSettingCatalog.All.ToDictionary(d => d.Key);

        var body = LedmSettingCatalog.BuildPut(dyn, [(defs["PowerSaveTimeout"], "15minutes"), (defs["DeviceLocation"], "Office")]);

        XNamespace dd = "http://www.hp.com/schemas/imaging/con/dictionaries/1.0/";
        XNamespace v2 = "http://www.hp.com/schemas/imaging/con/ledm/productconfigdyn/2009/03/16";
        XNamespace v1 = "http://www.hp.com/schemas/imaging/con/ledm/productconfigdyn/2007/11/05";
        var settings = Assert.Single(body.Root!.Elements());
        Assert.Equal(v2 + "ProductConfigDyn", body.Root.Name);
        Assert.Equal(v2 + "ProductSettings", settings.Name);
        Assert.Equal("15minutes", settings.Element(dd + "PowerSaveTimeout")!.Value);
        Assert.Equal("Office", settings.Element(v1 + "DeviceInformation")!.Element(dd + "DeviceLocation")!.Value);
        Assert.Equal(2, settings.Elements().Count());
    }

    [Fact]
    public void BuildPut_includes_tray_key()
    {
        var dyn = Fixture.Xml("DevMgmt_MediaHandlingDyn.xml");
        var def = LedmSettingCatalog.All.Single(d => d.Key == "MediaSizeName");

        var tray = Assert.Single(LedmSettingCatalog.BuildPut(dyn, [(def, "iso_a4_210x297mm")]).Root!.Elements());

        Assert.Equal(["InputBin", "MediaSizeName"], tray.Elements().Select(e => e.Name.LocalName));
        Assert.Equal("Tray1", tray.Elements().First().Value);
    }

    [Theory]
    [InlineData("PowerSaveTimeout", "1minute", "1 minute")]
    [InlineData("ShutDownDelay", "15_minutes", "15 minutes")]
    [InlineData("ShutDownDelay", "2hours", "2 hours")]
    [InlineData("Duplex", "enabled", "On")]
    [InlineData("MediaSizeName", "na_letter_8.5x11in", "Letter (8.5x11in)")]
    [InlineData("MediaSizeName", "iso_a4_210x297mm", "A4 (210x297mm)")]
    [InlineData("MediaType", "extraHeavy", "Extra heavy")]
    public void Display_text(string key, string value, string expected) => Assert.Equal(expected, SettingText.Display(key, value));
}
