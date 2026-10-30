using System.Xml.Linq;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Alerts as toast notifications (Core/Alerts/AlertToasts: the XML, the buttons' arguments, the per-printer grouping and
/// tag) and the Store package's startup task in the manifest template. The alert rules themselves (AlertTracker) are
/// untouched by toasts: AlertTests cover them.
/// </summary>
public class AlertToastTests
{
    private static readonly AlertNotice Toner = new("urn:uuid:aaaa-1", "Office laser", AlertKind.SupplyLow, "Black toner is low", "About 140 pages left. Cartridge 134A.");
    private static readonly AlertNotice Jam = new("urn:uuid:bbbb-2", "Front desk <inkjet> & co", AlertKind.PaperJam, "Paper jam", "Clear the jam, then the printer goes on by itself.");
    private static readonly AlertNotice Tray = new("urn:uuid:AAAA-1", "Office laser", AlertKind.PaperOut, "Tray 2 is out of paper", "Load paper.");

    [Fact]
    public void One_toast_per_printer_with_the_two_buttons_and_the_printer_as_attribution()
    {
        var xml = XDocument.Parse(AlertToasts.Xml([Toner]));
        var toast = xml.Root!;
        Assert.Equal("open:urn:uuid:aaaa-1", toast.Attribute("launch")!.Value);
        Assert.Equal("foreground", toast.Attribute("activationType")!.Value);
        var binding = toast.Element("visual")!.Element("binding")!;
        Assert.Equal("ToastGeneric", binding.Attribute("template")!.Value);
        var texts = binding.Elements("text").ToList();
        Assert.Equal(["Black toner is low", "About 140 pages left. Cartridge 134A.", "Office laser"], texts.Select(t => t.Value));
        Assert.Equal("attribution", texts[2].Attribute("placement")!.Value);
        Assert.Null(binding.Element("image"));
        var actions = toast.Element("actions")!.Elements("action").ToList();
        Assert.Equal([("Open printer", "open:urn:uuid:aaaa-1"), ("Pause alerts", "pause:urn:uuid:aaaa-1")],
            actions.Select(a => (a.Attribute("content")!.Value, a.Attribute("arguments")!.Value)));
        Assert.All(actions, a => Assert.Equal("foreground", a.Attribute("activationType")!.Value));
    }

    [Fact]
    public void Printer_names_and_text_are_escaped_so_the_xml_stays_well_formed()
    {
        var xml = XDocument.Parse(AlertToasts.Xml([Jam]));
        Assert.Equal("Front desk <inkjet> & co", xml.Root!.Element("visual")!.Element("binding")!.Elements("text").Last().Value);
    }

    [Fact]
    public void Several_alerts_for_one_printer_make_one_toast_with_a_line_each()
    {
        var (title, text) = AlertToasts.Text([Toner, Tray]);
        Assert.Equal("2 alerts", title);
        Assert.Equal("Black toner is low\nTray 2 is out of paper", text);
        var xml = XDocument.Parse(AlertToasts.Xml([Toner, Tray]));
        Assert.Equal("2 alerts", xml.Root!.Element("visual")!.Element("binding")!.Elements("text").First().Value);
    }

    [Fact]
    public void Alerts_read_together_are_grouped_by_printer_in_order_whatever_the_uuids_case()
    {
        var groups = AlertToasts.PerPrinter([Toner, Jam, Tray]);
        Assert.Equal(2, groups.Count);
        Assert.Equal([Toner, Tray], groups[0]);
        Assert.Equal([Jam], groups[1]);
        Assert.Empty(AlertToasts.PerPrinter([]));
    }

    [Fact]
    public void An_image_is_added_only_when_asked_for()
    {
        var xml = XDocument.Parse(AlertToasts.Xml([Jam], @"C:\icons\warning.png"));
        var image = xml.Root!.Element("visual")!.Element("binding")!.Element("image")!;
        Assert.Equal("appLogoOverride", image.Attribute("placement")!.Value);
        Assert.Equal(@"C:\icons\warning.png", image.Attribute("src")!.Value);
    }

    [Theory]
    [InlineData("open:urn:uuid:aaaa-1", ToastAction.OpenPrinter, "urn:uuid:aaaa-1")]
    [InlineData("pause:urn:uuid:bbbb-2", ToastAction.PauseAlerts, "urn:uuid:bbbb-2")]
    public void A_clicks_arguments_say_what_to_do_and_for_which_printer(string arguments, ToastAction action, string uuid) =>
        Assert.Equal((action, uuid), AlertToasts.ParseArguments(arguments));

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("open:")]
    [InlineData("pause")]
    [InlineData("print:urn:uuid:aaaa-1")]
    public void Arguments_that_arent_ours_parse_as_nothing(string? arguments) => Assert.Null(AlertToasts.ParseArguments(arguments));

    [Fact]
    public void The_tag_is_short_and_the_same_for_one_printer_whatever_the_uuids_case()
    {
        var tag = AlertToasts.Tag(Toner.Uuid);
        Assert.InRange(tag.Length, 1, 16);
        Assert.Matches("^[0-9a-f]+$", tag);
        Assert.Equal(tag, AlertToasts.Tag(Tray.Uuid));
        Assert.NotEqual(tag, AlertToasts.Tag(Jam.Uuid));
    }

    [Fact]
    public void An_empty_toast_is_refused() => Assert.Throws<ArgumentException>(() => AlertToasts.Xml([]));

    [Fact]
    public void The_pause_button_pauses_for_an_hour() => Assert.Equal(TimeSpan.FromHours(1), AlertToasts.PauseFor);

    // ───────────── the Store package's startup task ─────────────

    private static string RepoFile(params string[] parts)
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null && !File.Exists(Path.Combine(dir.FullName, "Inkvolt.slnx"))) dir = dir.Parent;
        Assert.NotNull(dir);
        return Path.Combine([dir.FullName, .. parts]);
    }

    [Fact]
    public void The_manifest_declares_the_startup_task_off_by_default_under_the_id_the_app_asks_for()
    {
        var manifest = XDocument.Load(RepoFile("print", "packaging", "AppxManifest.template.xml"));
        XNamespace uap5 = "http://schemas.microsoft.com/appx/manifest/uap/windows10/5";
        var extension = Assert.Single(manifest.Descendants(uap5 + "Extension"), e => e.Attribute("Category")?.Value == "windows.startupTask");
        Assert.Equal("InkvoltPrint.exe", extension.Attribute("Executable")!.Value);
        Assert.Equal("Windows.FullTrustApplication", extension.Attribute("EntryPoint")!.Value);
        var task = extension.Element(uap5 + "StartupTask")!;
        Assert.Equal(ShellRegistration.StartupTaskId, task.Attribute("TaskId")!.Value);
        Assert.Equal("false", task.Attribute("Enabled")!.Value);
        Assert.Equal("Inkvolt Print", task.Attribute("DisplayName")!.Value);
    }
}
