using System.Net;
using System.Xml.Linq;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Recording;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Tests;

/// <summary>
/// Scan from the printer's button (print/ROADMAP.md 2.2): HP's Scan to Computer over LEDM (<see cref="LedmWalkupScan"/>,
/// <see cref="ScanToComputer"/>), a Windows scanner's button (<see cref="FakeWiaSystem"/>), and what one printer's
/// <see cref="ScanButton"/> does with either. The M234dw doesn't list the walk-up interface; the "fixture printer" that does is
/// the demo HP laser: the M234dw's documents, the hand-written walk-up ones (<c>Fixtures/hp-demo</c>) and
/// <see cref="FakeScanToComputer"/>'s list and presses.
/// </summary>
public class ScanButtonTests
{
    private const string Host = "192.0.2.10", Pc = "TEST-PC", Tag = "abc123", Marker = "TEST-PC-ivabc123";
    private static readonly byte[] Page = [0xFF, 0xD8, 0xFF, 0xD9];
    private static readonly TimeSpan Wait = Timing.Limit(TimeSpan.FromSeconds(10));

    private static byte[]? Document(string[] folders, string name) => folders
        .Select(folder => Path.Combine(AppContext.BaseDirectory, "Fixtures", folder, name)).Where(File.Exists).Select(File.ReadAllBytes).FirstOrDefault();

    private static FixtureHandler Documents(params string[] folders) => new(name => Document(folders, name), () => Page);

    /// <summary>The demo HP laser: the M234dw with the walk-up interface listed (<paramref name="inTree"/>).</summary>
    private static FakeScanToComputer Panel(bool inTree = true) => new(Documents("m234dw", "hp-demo"), inTree);

    private static async Task<PrinterConnection> Connect(HttpMessageHandler printer) => await PrinterConnection.OpenAsync(Host, transport: printer);

    private static async Task Until(Func<bool> done, string what)
    {
        var limit = DateTime.UtcNow + Wait;
        while (!done())
        {
            if (DateTime.UtcNow > limit) throw new TimeoutException($"Still waiting for: {what}");
            await Task.Delay(20);
        }
    }

    /// <summary>A scan button for the printer with its choice kept here, counting presses.</summary>
    private sealed class Button
    {
        public ScanButtonChoice Saved = new();
        public int Presses;
        public readonly ScanButton It;

        public Button(ScanButtonChoice? choice = null, Action? pressed = null)
        {
            Saved = choice ?? new ScanButtonChoice(Tag: Tag);
            It = new ScanButton(Pc, Saved, c => Saved = c, () =>
            {
                Interlocked.Increment(ref Presses);
                pressed?.Invoke();
            })
            {
                DetectRetry = TimeSpan.FromMilliseconds(100),
                PanelRetry = TimeSpan.FromMilliseconds(100),
            };
        }
    }

    // ------------------------------------------------------------------ the names

    [Fact]
    public void The_M234dws_tree_lists_no_walkup_interface()
    {
        var tree = DiscoveryTree.Parse(Fixture.Xml("DevMgmt_DiscoveryTree.xml"));

        Assert.Null(LedmWalkupScan.ManifestPath(tree));
        Assert.DoesNotContain(tree.Interfaces.Keys, k => k.Contains("Walkup", StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void The_demo_manifest_names_the_list_and_the_event_document()
    {
        var manifest = XDocument.Parse(System.Text.Encoding.UTF8.GetString(Document(["hp-demo"], "WalkupScanToComp_WalkupScanToCompManifest.xml")!));

        Assert.Equal((FakeScanToComputer.ListPath, FakeScanToComputer.EventPath), LedmWalkupScan.Paths(manifest));
    }

    [Fact]
    public void The_POST_body_is_the_destination_in_the_printers_own_namespaces()
    {
        var list = XDocument.Parse(System.Text.Encoding.UTF8.GetString(Document(["hp-demo"], "WalkupScanToComp_WalkupScanToCompDestinations.xml")!));

        var body = LedmClient.Serialize(LedmWalkupScan.Build(list, Pc, Marker));

        Assert.Equal(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?><wus:WalkupScanToCompDestination xmlns:wus=\"http://www.hp.com/schemas/imaging/con/ledm/walkupscan/2010/09/28\""
            + " xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\" xmlns:dd3=\"http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06\">"
            + "<dd:Name>TEST-PC</dd:Name><dd3:Hostname>TEST-PC-ivabc123</dd3:Hostname><wus:LinkType>Network</wus:LinkType></wus:WalkupScanToCompDestination>", body);
    }

    [Theory]
    [InlineData("TEST-PC", "TEST-PC")]
    [InlineData("  Ana's laptop <b>  ", "Anas laptop b")]
    [InlineData("<>&\"", "PC")]
    [InlineData("A-VERY-LONG-COMPUTER-NAME-THAT-GOES-ON-AND-ON", "A-VERY-LONG-COMPUTER-NAME-THAT-G")]
    public void The_panel_name_is_the_computers_cut_to_plain_letters(string computer, string shown) =>
        Assert.Equal(shown, LedmWalkupScan.PanelName(computer));

    [Theory]
    [InlineData("http://192.0.2.10/WalkupScanToComp/WalkupScanToCompDestinations/7", "/WalkupScanToComp/WalkupScanToCompDestinations/7")]
    [InlineData("/WalkupScanToComp/WalkupScanToCompDestinations/a-1", "/WalkupScanToComp/WalkupScanToCompDestinations/a-1")]
    [InlineData("/WalkupScanToComp/WalkupScanToCompDestinations/../../DevMgmt/ProductConfigDyn.xml", null)]
    [InlineData("/DevMgmt/ProductConfigDyn.xml", null)]
    [InlineData("/WalkupScanToComp/WalkupScanToCompDestinations/", null)]
    [InlineData("/WalkupScanToComp/WalkupScanToCompDestinations", null)]
    [InlineData("//elsewhere/WalkupScanToComp/WalkupScanToCompDestinations/1", null)]
    [InlineData("/WalkupScanToComp/WalkupScanToCompDestinations/1?x=y", null)]
    [InlineData(null, null)]
    public void Only_a_path_below_the_list_is_ever_this_PCs_to_delete(string? location, string? own) =>
        Assert.Equal(own, LedmWalkupScan.OwnPath(location, FakeScanToComputer.ListPath));

    [Fact]
    public void A_list_or_event_of_another_shape_offers_nothing_and_a_hostile_one_is_bounded()
    {
        Assert.Null(LedmWalkupScan.Read(XDocument.Parse("<WalkupScanDestinations/>")));
        Assert.Null(LedmWalkupScan.EventType(XDocument.Parse("<Other><WalkupScanToCompEventType>ScanRequested</WalkupScanToCompEventType></Other>")));
        Assert.Null(LedmWalkupScan.Paths(XDocument.Parse(
            "<m><ResourceMap><ResourceLink><ResourceURI>//evil</ResourceURI></ResourceLink><ResourceNode><ResourceLink><ResourceURI>/x</ResourceURI></ResourceLink>"
            + "<ResourceType><t>WalkupScanToCompDestinations</t></ResourceType></ResourceNode><ResourceNode><ResourceLink><ResourceURI>/y</ResourceURI></ResourceLink>"
            + "<ResourceType><t>WalkupScanToCompEvent</t></ResourceType></ResourceNode></ResourceMap></m>")));

        var many = new XElement("WalkupScanToCompDestinations", Enumerable.Range(0, 5000).Select(i =>
            new XElement("WalkupScanToCompDestination", new XElement("ResourceURI", $"/l/{i}"), new XElement("Name", new string('x', 10_000)))));
        var read = LedmWalkupScan.Read(new XDocument(many))!;
        Assert.Equal(LedmWalkupScan.MaxDestinations, read.Count);
        Assert.All(read, d => Assert.Equal(LedmWalkupScan.MaxNameLength, d.Name!.Length));
        Assert.Equal(LedmWalkupScan.MaxNameLength, LedmWalkupScan.EventType(XDocument.Parse(
            $"<WalkupScanToCompEvent><WalkupScanToCompEventType>{new string('S', 5000)}</WalkupScanToCompEventType></WalkupScanToCompEvent>"))!.Length);
        Assert.False(LedmWalkupScan.IsStart("HostSelected"));
        Assert.True(LedmWalkupScan.IsStart("scanrequested"));
    }

    // ------------------------------------------------------------------ the printer's panel

    [Fact]
    public async Task The_M234dw_offers_no_panel_and_nothing_is_written_to_it()
    {
        var printer = Panel(inTree: false);
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);

        Assert.Equal(ScanButtonWay.None, button.It.Way);
        Assert.Equal(CoreStrings.ScanButton_None, button.It.Text("Document"));
        Assert.Empty(printer.Writes);
    }

    [Fact]
    public async Task The_fixture_printers_list_shows_the_PC_after_connect_and_not_after_exit()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed");

        Assert.Equal(ScanButtonWay.Panel, button.It.Way);
        Assert.Equal([Pc], printer.Names);
        Assert.Equal([Marker], printer.Hosts); // its marker: a run after a crash finds it again
        Assert.Equal(string.Format(CoreStrings.ScanButton_Listed, Pc, "Document"), button.It.Text("Document"));
        Assert.Equal([$"POST {FakeScanToComputer.ListPath}"], printer.Writes);

        await button.It.CloseAsync(CancellationToken.None); // exit

        Assert.Empty(printer.Names);
        Assert.Equal($"DELETE {FakeScanToComputer.ListPath}/1", printer.Writes[^1]);
        Assert.True(button.Saved.On); // the next run adds it again
    }

    [Fact]
    public async Task Off_by_default_it_only_reads_and_turning_it_on_and_off_adds_and_removes_the_PC()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var button = new Button();

        await button.It.UsePrinterAsync(conn);
        Assert.Equal(ScanButtonWay.Panel, button.It.Way);
        Assert.Equal(string.Format(CoreStrings.ScanButton_PanelOff, Pc), button.It.Text("Document"));
        Assert.Empty(printer.Writes);

        await button.It.SetOnAsync(true);
        await Until(() => printer.Names.Count == 1, "added");
        await button.It.SetOnAsync(false);

        Assert.Empty(printer.Names);
        Assert.False(button.Saved.On);
    }

    [Fact]
    public async Task A_simulated_walkup_press_runs_the_preset_and_saves_its_file()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var folder = Directory.CreateTempSubdirectory("inkvolt-button-");
        var preset = new ScanPreset { Id = "p1", Name = "Receipts", Source = PresetSource.Glass, FileName = "{preset} {n}" };
        var saved = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            // What a press runs: the chosen preset, matched to this printer's scanner, its pages saved under its file name.
            var button = new Button(new ScanButtonChoice(On: true, PresetId: preset.Id, Tag: Tag), () => _ = Task.Run(async () =>
            {
                var plan = PresetPlan.For(preset, conn.Probe.Scanner!, null, ocrAvailable: false, metric: false);
                var pages = new List<byte[]>();
                await foreach (var page in conn.Scanner!.ScanAsync(plan.Request)) pages.Add(page);
                var file = Path.Combine(folder.FullName, FileNameTemplate.FileName(preset.FileName, new NameContext(DateTime.Now, preset.Name, "Demo printer", 1, pages.Count)) + ".jpg");
                await File.WriteAllBytesAsync(file, pages.Single());
                saved.TrySetResult(file);
            }));
            await button.It.UsePrinterAsync(conn);
            await Until(() => button.It.PanelState == PanelState.Listed, "listed");

            Assert.True(printer.Press());

            var path = await saved.Task.WaitAsync(Wait);
            Assert.Equal("Receipts 1.jpg", Path.GetFileName(path));
            Assert.Equal(Page, await File.ReadAllBytesAsync(path));
            await Task.Delay(200);
            Assert.Equal(1, button.Presses); // one press, one scan
            await button.It.CloseAsync(CancellationToken.None);
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }

    [Fact]
    public async Task Only_a_scan_request_for_this_PC_counts()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var other = printer.Add("OTHER-PC");
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));
        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed");
        var mine = printer.Paths[printer.Hosts.ToList().IndexOf(Marker)];

        printer.Press(other);                       // another computer chosen on the panel
        printer.Press(mine, "HostSelected");         // this PC chosen, Scan not pressed yet
        await Task.Delay(300);
        Assert.Equal(0, button.Presses);

        printer.Press(mine);
        await Until(() => button.Presses == 1, "pressed");
        await button.It.CloseAsync(CancellationToken.None);
        Assert.Equal(["OTHER-PC"], printer.Names); // only its own destination is removed
    }

    [Fact]
    public async Task A_press_from_before_it_started_is_not_run()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var mine = printer.Add(Pc, Marker); // as if added by an earlier run that crashed, and pressed since
        printer.Press(mine);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed");
        await Task.Delay(300);

        Assert.Equal(0, button.Presses);
        Assert.Empty(printer.Writes); // the remembered destination is adopted, not added again
        await button.It.CloseAsync(CancellationToken.None);
    }

    [Fact]
    public async Task After_the_printer_restarts_the_PC_goes_back_on_its_panel()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));
        await button.It.UsePrinterAsync(conn);
        await Until(() => printer.Names.Count == 1, "added");

        printer.PowerUp();

        await Until(() => printer.Names.Count == 1 && printer.Writes.Count(w => w.StartsWith("POST", StringComparison.Ordinal)) == 2, "added again");
        printer.Press();
        await Until(() => button.Presses == 1, "pressed");
        await button.It.CloseAsync(CancellationToken.None);
    }

    [Fact]
    public async Task A_PC_another_program_put_on_the_panel_is_left_alone()
    {
        var printer = Panel();
        printer.Add(Pc); // HP's software, say
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.ListedByOther, "seen");
        Assert.Equal(string.Format(CoreStrings.ScanButton_ListedByOther, Pc), button.It.Text(null));
        await button.It.CloseAsync(CancellationToken.None);

        Assert.Empty(printer.Writes);
        Assert.Equal([Pc], printer.Names);
    }

    [Theory]
    [InlineData(HttpStatusCode.Unauthorized, PanelState.NeedsPassword)]
    [InlineData(HttpStatusCode.BadRequest, PanelState.Refused)]
    public async Task A_refused_POST_is_said_and_never_sent_again_on_its_own(HttpStatusCode answer, PanelState state)
    {
        var printer = Panel();
        printer.PostAnswer = answer;
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == state, state.ToString());
        printer.PowerUp(); // a restart doesn't make it try again: turning it off and on does
        await Task.Delay(300);
        await button.It.CloseAsync(CancellationToken.None);

        Assert.Single(printer.Writes);
    }

    [Fact]
    public async Task Without_a_Location_the_list_says_where_the_PC_went()
    {
        var printer = Panel();
        printer.NoLocation = true;
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed");

        Assert.Equal([Marker], printer.Hosts);
        await button.It.CloseAsync(CancellationToken.None);
        Assert.Empty(printer.Names);
    }

    [Fact]
    public async Task Another_device_at_the_address_gets_nothing()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));
        await button.It.UsePrinterAsync(conn);
        await Until(() => printer.Names.Count == 1, "added");

        await button.It.UsePrinterAsync(null); // the session let go: another device answers there
        printer.Press();
        await Task.Delay(300);

        Assert.Equal(0, button.Presses);
        Assert.DoesNotContain(printer.Writes, w => w.StartsWith("DELETE", StringComparison.Ordinal)); // not sent to the other device either
    }

    [Fact]
    public async Task Record_a_printer_saves_the_walkup_documents()
    {
        var folder = Directory.CreateTempSubdirectory("inkvolt-record-");
        try
        {
            var printer = Panel();
            var result = await PrinterRecorder.RecordAsync(Host, folder.FullName, new RecordOptions { Transport = printer });

            Assert.Contains("WalkupScanToComp_WalkupScanToCompManifest.xml", result.Files);
            Assert.Contains("WalkupScanToComp_WalkupScanToCompDestinations.xml", result.Files);
            Assert.Contains("WalkupScanToComp_WalkupScanToCompEvent.xml", result.Files);
            Assert.Empty(printer.Writes); // reading only: the PC isn't added to the list
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }

    // ------------------------------------------------------------------ a Windows scanner's button

    private static readonly WiaDeviceInfo Wsd = new(@"{6BDD1FC6-810F-11D0-BEC7-08002BE2092F}\0007", "Example MFP", "Example", "Example MFP", "WSD");

    private static FakeWiaScanner WiaScanner(IReadOnlyList<string>? buttons) => new(Wsd,
        new WiaScannerInfo(WiaIds.CapFlat, 8500, 11690, null, null, WiaValues.Of(300, 150, 300), [WiaIds.DataColor], [WiaIds.FormatBmp], buttons), (_, _) => Page);

    [Fact]
    public async Task The_FakeWiaSystems_button_event_runs_the_preset_while_turned_on()
    {
        var scanner = WiaScanner([WiaIds.ScanButtonEvents[0]]);
        var system = new FakeWiaSystem([scanner]);
        var button = new Button();
        await button.It.UseDriverAsync(system, Wsd.Id, scanner.Info.Buttons);

        Assert.Equal(ScanButtonWay.Driver, button.It.Way);
        Assert.Equal(CoreStrings.ScanButton_DriverSwitch, button.It.SwitchText);
        scanner.Press();
        Assert.Equal(0, button.Presses); // off: not heard
        Assert.Equal(0, scanner.Listeners);

        await button.It.SetOnAsync(true);
        scanner.Press();
        scanner.Press(WiaIds.ScanButtonEvents[4]); // an event this driver doesn't list
        Assert.Equal(1, button.Presses);
        Assert.Equal(string.Format(CoreStrings.ScanButton_DriverOn, "Document"), button.It.Text("Document"));

        await button.It.CloseAsync(CancellationToken.None);
        Assert.Equal(0, scanner.Listeners);
    }

    [Fact]
    public async Task A_scanner_without_buttons_and_a_printer_without_the_panel_say_neither()
    {
        var scanner = WiaScanner(null);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));
        var printer = Panel(inTree: false);
        using var conn = await Connect(printer);

        Assert.Equal(ScanButtonWay.Unknown, button.It.Way);
        await button.It.UsePrinterAsync(conn);
        await button.It.UseDriverAsync(new FakeWiaSystem([scanner]), Wsd.Id, scanner.Info.Buttons);

        Assert.Equal(ScanButtonWay.None, button.It.Way);
        Assert.Equal(CoreStrings.ScanButton_None, button.It.Text(null));
    }

    [Fact]
    public async Task The_panel_comes_before_the_drivers_button()
    {
        var scanner = WiaScanner([WiaIds.ScanButtonEvents[0]]);
        var printer = Panel();
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UseDriverAsync(new FakeWiaSystem([scanner]), Wsd.Id, scanner.Info.Buttons);
        Assert.Equal(1, scanner.Listeners);
        await button.It.UsePrinterAsync(conn);

        Assert.Equal(ScanButtonWay.Panel, button.It.Way);
        Assert.Equal(0, scanner.Listeners); // one press, one scan: not both ways at once
        await button.It.CloseAsync(CancellationToken.None);
    }

    [Fact]
    public void The_drivers_scan_buttons_are_picked_from_its_events_in_any_spelling()
    {
        Assert.Equal([WiaIds.ScanButtonEvents[0], WiaIds.ScanButtonEvents[4]],
            WiaIds.ScanButtonsIn(["a6c5a715-8c6e-11d2-977a-0000f87a926f", "{C686DCEE-54F2-419E-9A27-2FC7F2E98F9E}", "{A28BBADE-64B6-11D2-A231-00C04FA31809}", "junk"]));
        Assert.Empty(WiaIds.ScanButtonsIn([]));
    }

    // ------------------------------------------------------------------ review findings (c32c510c)

    [Fact]
    public async Task A_forgotten_printers_choice_never_comes_back()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var kept = new Dictionary<string, ScanButtonChoice>();
        var button = new ScanButton(Pc, new ScanButtonChoice(On: true, Tag: Tag), c => kept["printer"] = c, () => { }) { PanelRetry = TimeSpan.FromMilliseconds(100) };
        await button.UsePrinterAsync(conn);
        await Until(() => button.PanelState == PanelState.Listed, "listed");

        button.Seal();           // forgetting it: first its button, then its choice
        kept.Clear();
        await button.CloseAsync(CancellationToken.None);
        await button.SetOnAsync(false);
        button.SetPreset("p2");

        Assert.Empty(kept);
        Assert.Empty(printer.Names); // still taken off the panel
    }

    [Fact]
    public async Task Once_closed_nothing_starts_again()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var scanner = WiaScanner([WiaIds.ScanButtonEvents[0]]);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.CloseAsync(CancellationToken.None);
        await button.It.UsePrinterAsync(conn);
        await button.It.UseDriverAsync(new FakeWiaSystem([scanner]), Wsd.Id, scanner.Info.Buttons);
        scanner.Press();
        await Task.Delay(300);

        Assert.Empty(printer.Writes);
        Assert.Equal(0, scanner.Listeners);
        Assert.Equal(0, button.Presses);
    }

    [Fact]
    public async Task A_busy_list_is_tried_again_not_taken_as_a_refusal()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(Tag: Tag));
        await button.It.UsePrinterAsync(conn);

        printer.ListAnswer = HttpStatusCode.ServiceUnavailable;
        await button.It.SetOnAsync(true);
        await Until(() => button.It.PanelState == PanelState.NotReached, "not reached");
        printer.ListAnswer = null; // the printer recovers; its EventTable stays quiet

        await Until(() => button.It.PanelState == PanelState.Listed, "listed after a retry");
        Assert.Equal([Pc], printer.Names);
        await button.It.CloseAsync(CancellationToken.None);
    }

    [Fact]
    public async Task A_POST_whose_answer_was_lost_is_found_by_its_marker_and_removed()
    {
        var printer = Panel();
        printer.AddedThenAnswer = HttpStatusCode.ServiceUnavailable; // added, then a 503
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed by its marker");
        await button.It.CloseAsync(CancellationToken.None);

        Assert.Single(printer.Writes, w => w.StartsWith("POST", StringComparison.Ordinal)); // never a second one
        Assert.Empty(printer.Names);
    }

    [Fact]
    public async Task Exit_removes_this_apps_destination_even_when_its_path_was_never_known()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        printer.Add(Pc, Marker); // an earlier run's, its answer lost
        var found = await ScanToComputer.DetectAsync(conn);

        Assert.True(await found.Panel!.RemoveAsync(new PanelOwner(Pc, Marker)));
        Assert.Empty(printer.Names);
    }

    [Fact]
    public void A_list_in_no_namespace_gets_a_destination_in_none()
    {
        var body = LedmClient.Serialize(LedmWalkupScan.Build(XDocument.Parse("<WalkupScanToCompDestinations/>"), Pc, Marker));

        Assert.Equal("<?xml version=\"1.0\" encoding=\"UTF-8\"?><WalkupScanToCompDestination xmlns:dd=\"http://www.hp.com/schemas/imaging/con/dictionaries/1.0/\""
            + " xmlns:dd3=\"http://www.hp.com/schemas/imaging/con/dictionaries/2009/04/06\"><dd:Name>TEST-PC</dd:Name><dd3:Hostname>TEST-PC-ivabc123</dd3:Hostname>"
            + "<LinkType>Network</LinkType></WalkupScanToCompDestination>", body);
    }

    [Fact]
    public async Task A_printer_that_couldnt_be_read_says_nothing_yet_and_is_looked_at_again()
    {
        var printer = Panel();
        printer.ListAnswer = HttpStatusCode.ServiceUnavailable;
        using var conn = await Connect(printer);
        var button = new Button();

        await button.It.UsePrinterAsync(conn);
        Assert.Equal(ScanButtonWay.Unknown, button.It.Way); // not "this printer offers no button"
        Assert.Equal("", button.It.Text(null));

        printer.ListAnswer = null;
        await Until(() => button.It.Way == ScanButtonWay.Panel, "found on a retry");
    }

    [Fact]
    public async Task The_status_and_the_panel_share_one_long_poll()
    {
        var printer = Panel();
        using var conn = await Connect(printer);
        using var stop = new CancellationTokenSource();
        var status = Task.Run(async () =>
        {
            try { await foreach (var _ in conn.WatchAsync(TimeSpan.FromMinutes(1), stop.Token)) { } }
            catch (OperationCanceledException) { }
        });
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));
        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed");

        printer.Press();
        await Until(() => button.Presses == 1, "pressed");
        await Task.Delay(300);

        Assert.Equal(1, printer.MostPolls);
        Assert.Equal(1, conn.Ledm!.Events.Polls);
        await button.It.CloseAsync(CancellationToken.None);
        await stop.CancelAsync();
        await status;
        await Until(() => conn.Ledm.Events.Polls == 0, "the poll stops when nobody watches");
    }

    [Fact]
    public async Task Events_from_before_an_outage_at_start_are_not_presses()
    {
        var printer = Panel();
        var mine = printer.Add(Pc, Marker);
        printer.Press(mine); // pressed before this app started
        printer.TableAnswer = HttpStatusCode.ServiceUnavailable; // and the EventTable isn't answering when it starts
        using var conn = await Connect(printer);
        var button = new Button(new ScanButtonChoice(On: true, Tag: Tag));

        await button.It.UsePrinterAsync(conn);
        await Until(() => button.It.PanelState == PanelState.Listed, "listed");
        printer.TableAnswer = null;
        await Task.Delay(Timing.Limit(TimeSpan.FromSeconds(3))); // the poll's first retry comes after 2 s

        Assert.Equal(0, button.Presses);
        printer.Press(mine);
        await Until(() => button.Presses == 1, "a new press");
        await button.It.CloseAsync(CancellationToken.None);
    }

    [Fact]
    public void Seen_events_roll_without_ever_forgetting_what_the_table_still_holds()
    {
        var seen = new SeenEvents();
        var old = new LedmEvent("ScanEvent", "1-1", null, null);
        Assert.Empty(seen.Take([old], start: true));

        for (var i = 0; i < 3 * SeenEvents.Max; i++)
            Assert.Single(seen.Take([old, new LedmEvent("PowerUpEvent", $"{i + 2}-1", null, null)], start: false)); // only the new one

        Assert.True(seen.Count <= SeenEvents.Max);
        Assert.Empty(seen.Take([old], start: false));
    }

    [Fact]
    public void A_registration_made_after_its_caller_gave_up_is_undone_on_its_thread()
    {
        var undone = new List<string>();
        var late = new WorkClaim<string>(undone.Add);
        Assert.Null(late.Abandon());              // timed out: nothing delivered yet
        Assert.Null(late.Deliver("registration")); // then it comes
        Assert.Equal(["registration"], undone);

        var inTime = new WorkClaim<string>(undone.Add);
        Assert.Equal("second", inTime.Deliver("second"));
        Assert.Equal("second", inTime.Abandon());  // delivered just before the caller gave up: the caller undoes it
        Assert.Single(undone);
    }
}
