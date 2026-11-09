using System.Net;
using InkvoltPrint.Core.Drivers;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// "Get the driver": Epson's pages read (<see cref="EpsonDrivers"/>, from a trimmed copy of the real page and search answer), the
/// download bounded and kept to Epson's hosts (<see cref="BoundedHttp"/>), checked (<see cref="DriverFlow"/>) and run only as asked.
/// The page, the file and its signature are hostile.
/// </summary>
public sealed class DriverDownloadTests : IDisposable
{
    private static string FixturePath(string name) => Path.Combine(AppContext.BaseDirectory, "Fixtures", "epson", name);

    private static readonly string Page = File.ReadAllText(FixturePath("epson-v19-windows11.html"));
    private static readonly string Search = File.ReadAllText(FixturePath("epson-search-v19.json"));

    private static readonly Uri V19Page = new("https://epson.com/Support/Scanners/Perfection-Series/Epson-Perfection-V19-Photo/s/SPT_B11B231201");
    private static readonly Uri Installer = new("https://ftp.epson.com/drivers/V19_EScan_3950_AM.exe");

    private static readonly NeedsDriverPrinter V19 =
        new("usb-needs-driver:scanner-04b8-013c", "Epson Perfection V19", "Epson", null, DriverStage.NoDriver) { Kind = NeedsDriverKind.Scanner, UsbId = "04B8:013C" };

    private static DriverQuery Query(PcArch arch = PcArch.Arm64, PcWindows windows = PcWindows.Windows11) => DriverQuery.For(V19, arch, windows);

    private readonly string _folder = Path.Combine(Path.GetTempPath(), "inkvolt-driver-tests-" + Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_folder)) Directory.Delete(_folder, true);
    }

    // ---------------------------------------------------------------- Epson's pages

    [Fact]
    public void The_support_page_lists_its_downloads_in_order_with_their_sections()
    {
        var all = EpsonDrivers.ParsePage(Page);
        Assert.Equal(9, all.Count);
        Assert.Equal(("recommended", "Scanner Driver and EPSON Scan Utility v3.9.5.0", "29.5 MB"), (all[0].Section, all[0].Title, all[0].SizeText));
        Assert.Contains("ARM", all[0].Description);
        Assert.Contains("Windows 10 64-bit", all[0].Systems);
        Assert.All(all, d => Assert.Equal("ftp.epson.com", d.Href.Host));
    }

    [Theory]
    [InlineData("Epson Perfection V19", "SPT_B11B231201")]
    [InlineData("EPSON Perfection V19 Scanner", "SPT_B11B231201")]
    [InlineData("Epson Perfection V19 II", "SPT_B11B267201")]
    public void The_search_gives_the_models_own_page_never_a_variants(string model, string sku) =>
        Assert.EndsWith("/s/" + sku, EpsonDrivers.SupportPage(Search, model, NeedsDriverKind.Scanner)!.AbsolutePath);

    [Theory]
    [InlineData("Epson Perfection V39")]
    [InlineData("Epson")]
    public void A_model_the_search_doesnt_have_has_no_page(string model) => Assert.Null(EpsonDrivers.SupportPage(Search, model, NeedsDriverKind.Scanner));

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("[1,2,3]")]
    [InlineData("""{"products":[{"name":"Perfection V19 Scanner","productType":"SCANNER","supportProductId":"https://evil.example/s/SPT_X"}]}""")]
    [InlineData("""{"products":[{"name":"Perfection V19 Scanner","productType":"SCANNER","supportProductId":"/Support/../../x/s/SPT_X?a=b"}]}""")]
    [InlineData("""{"products":[{"name":"Perfection V19 Scanner","productType":"PRINTER","supportProductId":"/Support/Printers/x/s/SPT_X"}]}""")]
    public void A_hostile_or_odd_search_answer_gives_no_page(string json) => Assert.Null(EpsonDrivers.SupportPage(json, "Epson Perfection V19", NeedsDriverKind.Scanner));

    [Fact]
    public void On_ARM64_the_ARM_scanner_driver_is_offered_never_the_combo_package()
    {
        var offer = EpsonDrivers.Choose(EpsonDrivers.ParsePage(Page), Query(PcArch.Arm64, PcWindows.Windows11), V19Page).Offer!;
        Assert.Equal("Scanner Driver and EPSON Scan Utility", offer.Title);
        Assert.Equal("3.9.5.0", offer.Version);
        Assert.Equal("29.5 MB", offer.SizeText);
        Assert.Equal(Installer, offer.Download);
        Assert.Equal("V19_EScan_3950_AM.exe", offer.FileName);
    }

    [Theory]
    [InlineData(PcWindows.Windows10)]
    [InlineData(PcWindows.Windows11)]
    public void On_x64_a_download_only_for_ARM_is_never_offered(PcWindows windows)
    {
        var offer = EpsonDrivers.Choose(EpsonDrivers.ParsePage(Page), Query(PcArch.X64, windows), V19Page).Offer!;
        Assert.Equal(("Scanner Driver and Epson Scan 2 Utility", "6.6.60.0"), (offer.Title, offer.Version));
        Assert.Equal("V19_EScan2_66600_AM.exe", offer.FileName);
    }

    [Fact]
    public void On_x64_a_download_for_both_ARM_and_x64_is_offered()
    {
        var both = EpsonDrivers.ParsePage(Page.Replace("compatible with ARM devices", "compatible with x64 and ARM devices", StringComparison.Ordinal));
        Assert.Equal("3.9.5.0", EpsonDrivers.Choose(both, Query(PcArch.X64), V19Page).Offer!.Version);
    }

    [Theory]
    [InlineData("compatible with Windows on Arm devices")]
    [InlineData("compatible with Arm64 PCs")]
    [InlineData("compatible with arm-based devices")]
    public void Microsofts_spelling_of_Arm_counts_on_ARM64(string words)
    {
        var page = EpsonDrivers.ParsePage(Page.Replace("compatible with ARM devices", words, StringComparison.Ordinal));
        Assert.Equal("3.9.5.0", EpsonDrivers.Choose(page, Query(PcArch.Arm64), V19Page).Offer?.Version);
    }

    [Fact]
    public void On_ARM64_a_page_with_no_ARM_driver_says_so_and_x64_still_gets_one()
    {
        var noArm = EpsonDrivers.ParsePage(Page.Replace("ARM", "older", StringComparison.Ordinal));
        var arm = EpsonDrivers.Choose(noArm, Query(PcArch.Arm64), V19Page);
        Assert.Null(arm.Offer);
        Assert.Equal(NoOffer.NoArm64, arm.Why);
        Assert.Equal(V19Page, arm.Page);
        Assert.NotNull(EpsonDrivers.Choose(noArm, Query(PcArch.X64), V19Page).Offer);
        Assert.Contains("ARM", DriverText.Unavailable(V19, arm));
    }

    [Fact]
    public void A_page_with_no_driver_offers_nothing()
    {
        var onlyUtilities = EpsonDrivers.ParsePage(Page).Where(d => d.Section == "utilities").ToList();
        Assert.Equal(NoOffer.NotFound, EpsonDrivers.Choose(onlyUtilities, Query(), V19Page).Why);
        Assert.Empty(EpsonDrivers.ParsePage("<html><body>Downloads not available</body></html>"));
        Assert.Equal(NoOffer.NotFound, EpsonDrivers.Choose(EpsonDrivers.ParsePage(""), Query(), V19Page).Why);
    }

    [Theory]
    [InlineData("https://evil.example/drivers/V19_EScan_3950_AM.exe")]
    [InlineData("http://ftp.epson.com/drivers/V19_EScan_3950_AM.exe")]
    [InlineData("https://ftp.epson.com.evil.example/drivers/V19_EScan_3950_AM.exe")]
    [InlineData("https://user@ftp.epson.com/drivers/V19_EScan_3950_AM.exe")]
    [InlineData("https://ftp.epson.com:8443/drivers/V19_EScan_3950_AM.exe")]
    public void A_page_pointing_off_Epsons_hosts_is_never_offered(string href)
    {
        var hostile = EpsonDrivers.ParsePage(Page.Replace(Installer.AbsoluteUri, href, StringComparison.Ordinal));
        var offer = EpsonDrivers.Choose(hostile, Query(PcArch.X64, PcWindows.Windows10), V19Page).Offer;
        Assert.NotEqual(href, offer?.Download.OriginalString); // the next driver, or none
        Assert.True(offer is null || BoundedHttp.IsAllowed(offer.Download, MakerSource.Epson.DownloadHosts));
    }

    [Fact]
    public void A_file_name_from_the_page_is_never_a_path()
    {
        var hostile = EpsonDrivers.ParsePage(Page.Replace("V19_EScan_3950_AM.exe", @"..\..\Windows\evil.bat", StringComparison.Ordinal));
        var offer = EpsonDrivers.Choose(hostile, Query(), V19Page).Offer!;
        Assert.DoesNotContain("..", offer.FileName);
        Assert.DoesNotContain('\\', offer.FileName);
        Assert.EndsWith(".exe", offer.FileName);
    }

    [Fact]
    public async Task The_lookup_reads_the_search_then_the_page_filtered_for_this_windows()
    {
        var web = new FakeWeb();
        web.Text("https://epson.com/search/autocomplete/SearchBox?term=perfection%20v19", Search);
        web.Text(V19Page.AbsoluteUri + "?review-filter=Windows+11", Page);
        var found = await new EpsonDrivers(new BoundedHttp(web)).FindAsync(Query(), CancellationToken.None);
        Assert.Equal(Installer, found.Offer!.Download);
        Assert.Equal(V19Page.AbsoluteUri, found.Offer.Page.GetLeftPart(UriPartial.Path));
    }

    [Fact]
    public async Task A_search_that_redirects_off_Epsons_site_is_not_followed()
    {
        var web = new FakeWeb();
        web.Redirect("https://epson.com/search/autocomplete/SearchBox?term=perfection%20v19", "https://drivers.example/search");
        var found = await new EpsonDrivers(new BoundedHttp(web)).FindAsync(Query(), CancellationToken.None);
        Assert.Equal((NoOffer.Unreachable, FetchProblem.NotMakersSite), (found.Why, found.Problem));
        Assert.DoesNotContain(web.Asked, u => u.Host == "drivers.example");
    }

    // ---------------------------------------------------------------- the download and its checks

    private static readonly DriverOffer Offer = new("Scanner Driver and EPSON Scan Utility", "3.9.5.0", "29.5 MB", Installer, "V19_EScan_3950_AM.exe", V19Page);

    private static readonly byte[] Program = [(byte)'M', (byte)'Z', .. new byte[4000]];

    private DriverFlow Flow(FakeWeb web, Func<string, SignatureFacts>? signature = null, FakePc? pc = null, DriverMode mode = DriverMode.InstallForYou) =>
        new(new MakerCatalogs(new EpsonDrivers(new BoundedHttp(web))), new BoundedHttp(web), new FakeSignatures(signature ?? (_ => Signed("Epson America, Inc."))),
            pc ?? new FakePc(), _folder, PcArch.Arm64, PcWindows.Windows11, mode,
            new DriverTiming(TimeSpan.FromMilliseconds(200), TimeSpan.FromMilliseconds(500), TimeSpan.FromMilliseconds(5)));

    private static SignatureFacts Signed(string org) => new(SignatureState.Valid, org);

    private bool LeftNothing() => !Directory.Exists(_folder) || Directory.GetFiles(_folder, "*", SearchOption.AllDirectories).Length == 0;

    [Fact]
    public async Task A_valid_installer_signed_by_Epson_is_kept_for_the_users_click()
    {
        var web = new FakeWeb();
        web.Bytes(Installer.AbsoluteUri, Program);
        var got = await Flow(web).DownloadAsync(Offer, V19, null, CancellationToken.None);
        var ready = got.Ready!;
        Assert.Equal(("Epson America, Inc.", Program.Length), (ready.Signer, (int)ready.Bytes));
        Assert.True(File.Exists(ready.Path));
        Assert.StartsWith(_folder, ready.Path);
        Assert.Contains("Epson America, Inc.", DriverText.Facts(ready));
        Assert.Contains("3.9.5.0", DriverText.Facts(ready));
    }

    [Theory]
    [InlineData("SEIKO EPSON CORPORATION")]
    [InlineData("Seiko  Epson Corporation")]
    public void Epsons_other_signers_are_its_own(string org) => Assert.True(MakerSource.Epson.IsSigner(org));

    [Theory]
    [InlineData(SignatureState.NotSigned, null, Refusal.NotSigned)]
    [InlineData(SignatureState.Invalid, "Epson America, Inc.", Refusal.BadSignature)]
    [InlineData(SignatureState.Untrusted, "Epson America, Inc.", Refusal.Untrusted)]
    [InlineData(SignatureState.Valid, "Driver Downloads Ltd", Refusal.WrongSigner)]
    [InlineData(SignatureState.Valid, "Epson America, Inc. (not)", Refusal.WrongSigner)]
    [InlineData(SignatureState.Valid, null, Refusal.WrongSigner)]
    public async Task A_bad_missing_or_someone_elses_signature_is_refused_and_deleted(SignatureState state, string? org, Refusal why)
    {
        var web = new FakeWeb();
        web.Bytes(Installer.AbsoluteUri, Program);
        var pc = new FakePc();
        var got = await Flow(web, _ => new SignatureFacts(state, org), pc).DownloadAsync(Offer, V19, null, CancellationToken.None);
        Assert.Null(got.Ready);
        Assert.Equal(why, got.Why);
        Assert.True(LeftNothing());
        Assert.Equal(0, pc.Runs);
        Assert.False(string.IsNullOrWhiteSpace(DriverText.Refused(V19, got)));
    }

    [Fact]
    public async Task A_file_that_isnt_a_program_is_refused_before_its_signature_is_read()
    {
        var web = new FakeWeb();
        web.Bytes(Installer.AbsoluteUri, "<html>Not found</html>"u8.ToArray());
        var read = 0;
        var got = await Flow(web, _ => { read++; return Signed("Epson America, Inc."); }).DownloadAsync(Offer, V19, null, CancellationToken.None);
        Assert.Equal(Refusal.NotAnInstaller, got.Why);
        Assert.Equal(0, read);
        Assert.True(LeftNothing());
    }

    [Theory]
    [InlineData("https://downloads.example/V19.exe", FetchProblem.NotMakersSite)]
    [InlineData("http://ftp.epson.com/drivers/V19_EScan_3950_AM.exe", FetchProblem.NotMakersSite)]
    public async Task A_redirect_off_Epsons_hosts_is_never_followed(string to, FetchProblem problem)
    {
        var web = new FakeWeb();
        web.Redirect(Installer.AbsoluteUri, to);
        web.Bytes(to, Program);
        var got = await Flow(web).DownloadAsync(Offer, V19, null, CancellationToken.None);
        Assert.Equal((Refusal.Fetch, problem), (got.Why, got.Problem));
        Assert.DoesNotContain(web.Asked, u => u.AbsoluteUri == new Uri(to).AbsoluteUri);
        Assert.True(LeftNothing());
        Assert.Contains("Epson", DriverText.Refused(V19, got));
    }

    [Fact]
    public async Task A_redirect_to_another_of_Epsons_hosts_is_followed()
    {
        var web = new FakeWeb();
        web.Redirect(Installer.AbsoluteUri, "https://download.epson.com/drivers/V19.exe");
        web.Bytes("https://download.epson.com/drivers/V19.exe", Program);
        Assert.NotNull((await Flow(web).DownloadAsync(Offer, V19, null, CancellationToken.None)).Ready);
    }

    [Fact]
    public async Task Redirects_that_go_round_stop()
    {
        var web = new FakeWeb();
        web.Redirect(Installer.AbsoluteUri, "https://download.epson.com/a");
        web.Redirect("https://download.epson.com/a", Installer.AbsoluteUri);
        var got = await Flow(web).DownloadAsync(Offer, V19, null, CancellationToken.None);
        Assert.Equal(FetchProblem.TooManyRedirects, got.Problem);
        Assert.InRange(web.Asked.Count, 2, 7);
    }

    [Fact]
    public async Task A_file_said_to_be_huge_is_refused_before_a_byte_is_read()
    {
        var web = new FakeWeb();
        web.Respond(Installer.AbsoluteUri, () =>
        {
            var content = new ByteArrayContent(Program);
            content.Headers.ContentLength = DriverFlow.MaxBytes + 1;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
        });
        var got = await Flow(web).DownloadAsync(Offer, V19, null, CancellationToken.None);
        Assert.Equal(FetchProblem.TooBig, got.Problem);
        Assert.True(LeftNothing());
    }

    [Fact]
    public async Task A_file_that_keeps_coming_past_the_limit_is_stopped()
    {
        var web = new FakeWeb();
        web.Respond("https://ftp.epson.com/big", () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new Endless()) });
        var path = Path.Combine(Directory.CreateDirectory(_folder).FullName, "big.exe");
        var ex = await Assert.ThrowsAsync<FetchException>(() =>
            new BoundedHttp(web).DownloadAsync(new Uri("https://ftp.epson.com/big"), ["ftp.epson.com"], 100_000, TimeSpan.FromSeconds(30), path, null, CancellationToken.None));
        Assert.Equal(FetchProblem.TooBig, ex.Problem);
        Assert.False(File.Exists(path));
    }

    [Fact]
    public async Task A_file_cut_short_is_refused()
    {
        var web = new FakeWeb();
        web.Respond(Installer.AbsoluteUri, () =>
        {
            var content = new ByteArrayContent(Program);
            content.Headers.ContentLength = Program.Length + 1000;
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
        });
        var got = await Flow(web).DownloadAsync(Offer, V19, null, CancellationToken.None);
        Assert.Equal((Refusal.Fetch, FetchProblem.CutShort), (got.Why, got.Problem));
        Assert.True(LeftNothing());
    }

    [Fact]
    public async Task A_download_that_hangs_times_out()
    {
        var web = new FakeWeb();
        web.Respond("https://ftp.epson.com/slow", () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new Endless(TimeSpan.FromSeconds(30))) });
        var ex = await Assert.ThrowsAsync<FetchException>(() =>
            new BoundedHttp(web).GetTextAsync(new Uri("https://ftp.epson.com/slow"), ["ftp.epson.com"], 1 << 20, TimeSpan.FromMilliseconds(200), CancellationToken.None))
            .WaitAsync(Timing.Limit(TimeSpan.FromSeconds(10)));
        Assert.Equal(FetchProblem.TimedOut, ex.Problem);
    }

    [Fact]
    public async Task Only_a_maker_with_a_catalog_and_a_real_device_is_looked_up()
    {
        var flow = Flow(new FakeWeb());
        Assert.True(flow.LooksUp(V19));
        Assert.False(flow.LooksUp(V19 with { Maker = "Canon" }));
        Assert.False(flow.LooksUp(V19 with { IsMadeUp = true }));
        Assert.Equal(NoOffer.MakerNotLookedUp, (await flow.FindAsync(V19 with { Maker = "Canon" }, CancellationToken.None)).Why);
    }

    // ---------------------------------------------------------------- running it, on the user's click

    private async Task<DriverReady> ReadyAsync(DriverFlow flow, FakeWeb web)
    {
        web.Bytes(Installer.AbsoluteUri, Program);
        return (await flow.DownloadAsync(Offer, V19, null, CancellationToken.None)).Ready!;
    }

    [Fact]
    public async Task Nothing_runs_until_install_and_then_the_installer_runs_once_and_is_deleted()
    {
        var web = new FakeWeb();
        var pc = new FakePc();
        var flow = Flow(web, pc: pc);
        var ready = await ReadyAsync(flow, web);
        Assert.Equal(0, pc.Runs);
        var done = await flow.InstallAsync(ready, _ => Task.FromResult(true), CancellationToken.None);
        Assert.Equal(InstallOutcome.Done, done.Outcome);
        Assert.Equal(1, pc.Runs);
        Assert.False(done.Rescanned);
        Assert.True(LeftNothing());
    }

    [Fact]
    public async Task A_self_extractor_that_exits_before_its_setup_is_waited_for_with_its_setup_and_its_folder_kept_till_then()
    {
        var web = new FakeWeb();
        var pc = new FakePc { ChildLooks = 4 }; // the root exits at once (0); its setup.exe and that one's child run 4 more looks
        var flow = Flow(web, pc: pc);
        var ready = await ReadyAsync(flow, web);
        var folderThereWhileSetupRan = true;
        pc.OnLook = alive => { if (alive) folderThereWhileSetupRan &= File.Exists(ready.Path); };
        var askedWhileSetupRan = false;
        var done = await flow.InstallAsync(ready, _ =>
        {
            askedWhileSetupRan |= pc.ChildLooks > 0;
            return Task.FromResult(true);
        }, CancellationToken.None);
        Assert.Equal(InstallOutcome.Done, done.Outcome);
        Assert.True(folderThereWhileSetupRan);
        Assert.False(askedWhileSetupRan);
        Assert.True(pc.Looks >= 5);
        Assert.True(LeftNothing());
    }

    [Fact]
    public async Task An_installer_whose_setup_outlives_the_limit_times_out_and_leaves_its_folder()
    {
        var web = new FakeWeb();
        var pc = new FakePc { ChildLooks = int.MaxValue };
        var flow = Flow(web, pc: pc);
        var ready = await ReadyAsync(flow, web);
        var asked = 0;
        var done = await flow.InstallAsync(ready, _ => { asked++; return Task.FromResult(true); }, CancellationToken.None)
            .WaitAsync(Timing.Limit(TimeSpan.FromSeconds(20)));
        Assert.Equal(InstallOutcome.TimedOut, done.Outcome);
        Assert.Equal(0, asked);
        Assert.True(File.Exists(ready.Path)); // the next start-up's sweep takes it
    }

    [Fact]
    public async Task A_process_that_isnt_the_installers_is_never_waited_for()
    {
        var web = new FakeWeb();
        var pc = new FakePc { Others = t0 => [(500, 4, t0.AddHours(-1)), (501, 500, t0.AddMinutes(-5))] };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(true), CancellationToken.None)
            .WaitAsync(Timing.Limit(TimeSpan.FromSeconds(20)));
        Assert.Equal(InstallOutcome.Done, done.Outcome);
    }

    [Fact]
    public async Task A_process_still_naming_a_long_dead_parent_whose_pid_the_installer_got_is_not_its_child()
    {
        // explorer.exe names userinit's PID, long gone; the installer was given that PID again.
        var web = new FakeWeb();
        var pc = new FakePc { Others = t0 => [(300, 100, t0.AddDays(-1)), (301, 300, t0.AddHours(-2))] };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(true), CancellationToken.None)
            .WaitAsync(Timing.Limit(TimeSpan.FromSeconds(20)));
        Assert.Equal(InstallOutcome.Done, done.Outcome); // not TimedOut after the limit
        Assert.True(LeftNothing());
    }

    [Fact]
    public async Task A_finished_childs_pid_taken_by_a_new_process_is_not_waited_for()
    {
        // setup.exe (101) ends; a new process gets 101 (named as the installer's child, or not), and one starts under it.
        var web = new FakeWeb();
        var pc = new FakePc { ChildLooks = 2, ReusedAfterChildren = now => [(101, 100, now), (103, 101, now.AddMilliseconds(1))] };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(true), CancellationToken.None)
            .WaitAsync(Timing.Limit(TimeSpan.FromSeconds(20)));
        Assert.Equal(InstallOutcome.Done, done.Outcome);
        Assert.True(pc.Looks >= 3);
    }

    [Fact]
    public async Task A_device_that_shows_only_after_a_rescan_is_found_by_asking_as_the_user_first()
    {
        var web = new FakeWeb();
        var pc = new FakePc();
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(pc.AsUser > 0), CancellationToken.None);
        Assert.Equal((InstallOutcome.Done, true, false), (done.Outcome, done.Rescanned, done.Elevated));
        Assert.Equal(0, pc.ElevatedRuns);
    }

    [Fact]
    public async Task When_the_users_rescan_cant_one_elevated_rescan_is_asked_for()
    {
        var web = new FakeWeb();
        var pc = new FakePc { AsUserWorks = false };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(pc.ElevatedRuns > 0), CancellationToken.None);
        Assert.Equal((InstallOutcome.Done, true), (done.Outcome, done.Elevated));
        Assert.Equal(1, pc.ElevatedRuns);
    }

    [Fact]
    public async Task A_device_windows_never_shows_says_to_plug_it_in_again()
    {
        var web = new FakeWeb();
        var pc = new FakePc();
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(false), CancellationToken.None);
        Assert.Equal(InstallOutcome.NotSeen, done.Outcome);
        Assert.Equal(1, pc.ElevatedRuns);
        Assert.Contains("plug it back in", DriverText.Outcome(V19, done));
    }

    [Theory]
    [InlineData("declined", InstallOutcome.Declined)]
    [InlineData("1603", InstallOutcome.Failed)]
    [InlineData("3010", InstallOutcome.Done)]
    public async Task How_the_installer_ends_is_said_without_its_code(string how, InstallOutcome outcome)
    {
        var web = new FakeWeb();
        var pc = how == "declined" ? new FakePc { Decline = true } : new FakePc { ExitCode = int.Parse(how, System.Globalization.CultureInfo.InvariantCulture) };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(true), CancellationToken.None);
        Assert.Equal(outcome, done.Outcome);
        Assert.DoesNotContain("1603", DriverText.Outcome(V19, done));
        Assert.True(LeftNothing());
        if (outcome != InstallOutcome.Done) Assert.Equal(0, pc.AsUser + pc.ElevatedRuns);
    }

    public static TheoryData<Exception> WindowsRefusals => new()
    {
        new System.ComponentModel.Win32Exception(5), // a policy: access denied
        new System.ComponentModel.Win32Exception(225), // an antivirus: the file contains a virus
        new IOException("The process cannot access the file because it is being used by another process."),
        new InvalidOperationException("No process is associated with this object."),
    };

    [Theory]
    [MemberData(nameof(WindowsRefusals))]
    public async Task An_installer_windows_wont_start_is_said_in_words_not_a_crash(Exception refusal)
    {
        var web = new FakeWeb();
        var pc = new FakePc { StartThrows = refusal };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => Task.FromResult(true), CancellationToken.None);
        Assert.Equal(InstallOutcome.CouldntStart, done.Outcome);
        var words = DriverText.Outcome(V19, done);
        Assert.Contains("start", words);
        Assert.DoesNotContain(refusal.Message, words);
        Assert.True(LeftNothing());
    }

    [Fact]
    public async Task A_check_or_a_rescan_that_throws_is_taken_as_not_there_yet()
    {
        var web = new FakeWeb();
        var pc = new FakePc { RescanThrows = new System.Runtime.InteropServices.COMException("WIA is not answering") };
        var flow = Flow(web, pc: pc);
        var done = await flow.InstallAsync(await ReadyAsync(flow, web), _ => throw new System.Runtime.InteropServices.COMException("WIA"), CancellationToken.None);
        Assert.Equal(InstallOutcome.NotSeen, done.Outcome);
    }

    [Fact]
    public async Task A_file_swapped_after_its_check_is_never_run()
    {
        var web = new FakeWeb();
        var pc = new FakePc();
        var flow = Flow(web, path => File.ReadAllBytes(path).Length == Program.Length ? Signed("Epson America, Inc.") : Signed("Someone Else"), pc);
        var ready = await ReadyAsync(flow, web);
        File.WriteAllBytes(ready.Path, [(byte)'M', (byte)'Z', 1, 2, 3]);
        var done = await flow.InstallAsync(ready, _ => Task.FromResult(true), CancellationToken.None);
        Assert.Equal(InstallOutcome.CouldntStart, done.Outcome);
        Assert.Equal(0, pc.Runs);
        Assert.True(LeftNothing());
    }

    [Fact]
    public void Discard_never_deletes_a_folder_beside_the_download_folder()
    {
        var sibling = Directory.CreateDirectory(_folder + "-old").FullName;
        try
        {
            var inside = Directory.CreateDirectory(Path.Combine(sibling, "x")).FullName;
            File.WriteAllBytes(Path.Combine(inside, "keep.exe"), Program);
            Flow(new FakeWeb()).Discard(new DriverReady(Offer, "Epson", Path.Combine(inside, "keep.exe"), Program.Length, "Epson America, Inc."));
            Assert.True(File.Exists(Path.Combine(inside, "keep.exe")));
            Assert.False(DriverFlow.IsInside(inside, _folder));
            Assert.False(DriverFlow.IsInside(_folder, _folder));
            Assert.True(DriverFlow.IsInside(Path.Combine(_folder, "a"), _folder + Path.DirectorySeparatorChar));
        }
        finally
        {
            Directory.Delete(sibling, true);
        }
    }

    [Fact]
    public void Leftover_downloads_are_swept_at_start_up_but_not_one_in_use_now()
    {
        var old = Directory.CreateDirectory(Path.Combine(_folder, "old")).FullName;
        File.WriteAllBytes(Path.Combine(old, "V19.exe"), Program);
        Directory.SetLastWriteTimeUtc(old, DateTime.UtcNow.AddDays(-2));
        var fresh = Directory.CreateDirectory(Path.Combine(_folder, "fresh")).FullName;
        Assert.Equal(1, DriverFlow.SweepLeftovers(_folder, TimeSpan.FromHours(1), DateTime.UtcNow));
        Assert.False(Directory.Exists(old));
        Assert.True(Directory.Exists(fresh));
        Assert.Equal(0, DriverFlow.SweepLeftovers(_folder + "-missing", TimeSpan.FromHours(1), DateTime.UtcNow));
    }

    [Fact]
    public async Task Dont_install_deletes_the_download()
    {
        var web = new FakeWeb();
        var flow = Flow(web);
        flow.Discard(await ReadyAsync(flow, web));
        Assert.True(LeftNothing());
    }

    // ---------------------------------------------------------------- a Store (packaged) copy: the maker's link, nothing run

    [Theory]
    [InlineData(false, false, DriverMode.InstallForYou)]
    [InlineData(false, true, DriverMode.InstallForYou)]
    [InlineData(true, false, DriverMode.OpenLink)]
    [InlineData(true, true, DriverMode.InstallForYou)] // a sideloading package built with the flow kept
    public void A_packaged_copy_opens_the_link_unless_built_to_keep_the_flow(bool packaged, bool kept, DriverMode mode) =>
        Assert.Equal(mode, DriverModes.For(packaged, kept));

    [Fact]
    public async Task A_packaged_copy_finds_the_download_and_gives_epsons_own_link_but_never_downloads_or_runs_it()
    {
        var web = new FakeWeb();
        web.Text("https://epson.com/search/autocomplete/SearchBox?term=perfection%20v19", Search);
        web.Text(V19Page.AbsoluteUri + "?review-filter=Windows+11", Page);
        web.Bytes(Installer.AbsoluteUri, Program);
        var pc = new FakePc();
        var flow = Flow(web, pc: pc, mode: DriverMode.OpenLink);
        var offer = (await flow.FindAsync(V19, CancellationToken.None)).Offer!;
        Assert.Equal(Installer, flow.LinkFor(offer, V19));
        Assert.Equal(Refusal.NotLookedUp, (await flow.DownloadAsync(offer, V19, null, CancellationToken.None)).Why);
        Assert.Equal(InstallOutcome.CouldntStart,
            (await flow.InstallAsync(new DriverReady(offer, "Epson", Path.Combine(_folder, "x.exe"), 1, "Epson America, Inc."), _ => Task.FromResult(true), CancellationToken.None)).Outcome);
        Assert.DoesNotContain(web.Asked, u => u == Installer);
        Assert.Equal(0, pc.Runs);
        Assert.True(LeftNothing());
        Assert.Contains("ftp.epson.com", DriverText.OfferFacts(offer));
        Assert.Contains("29.5 MB", DriverText.OfferFacts(offer));
    }

    [Fact]
    public void A_link_off_the_makers_hosts_is_never_opened()
    {
        var flow = Flow(new FakeWeb(), mode: DriverMode.OpenLink);
        Assert.Null(flow.LinkFor(Offer with { Download = new Uri("https://drivers.example/V19.exe") }, V19));
        Assert.Null(flow.LinkFor(Offer with { Download = new Uri("http://ftp.epson.com/drivers/V19.exe") }, V19));
        Assert.Null(flow.LinkFor(Offer, V19 with { Maker = "Canon" }));
    }

    [Fact]
    public async Task Look_again_asks_then_has_windows_look_as_the_user_never_elevated()
    {
        var pc = new FakePc();
        var flow = Flow(new FakeWeb(), pc: pc, mode: DriverMode.OpenLink);
        Assert.True(await flow.LookAgainAsync(_ => Task.FromResult(pc.AsUser > 0), CancellationToken.None));
        Assert.Equal((1, 0), (pc.AsUser, pc.ElevatedRuns));
        Assert.False(await flow.LookAgainAsync(_ => Task.FromResult(false), CancellationToken.None));
        Assert.Equal(0, pc.ElevatedRuns);
    }

    // ---------------------------------------------------------------- fakes

    private sealed class FakeWeb : HttpMessageHandler
    {
        private readonly Dictionary<string, Func<HttpResponseMessage>> _answers = new(StringComparer.Ordinal);
        public List<Uri> Asked { get; } = [];

        public void Respond(string uri, Func<HttpResponseMessage> answer) => _answers[new Uri(uri).AbsoluteUri] = answer;

        public void Text(string uri, string text) => Respond(uri, () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text) });

        public void Bytes(string uri, byte[] bytes) => Respond(uri, () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) });

        public void Redirect(string uri, string to) => Respond(uri, () =>
        {
            var r = new HttpResponseMessage(HttpStatusCode.Found);
            r.Headers.Location = new Uri(to);
            return r;
        });

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Asked.Add(request.RequestUri!);
            return Task.FromResult(_answers.TryGetValue(request.RequestUri!.AbsoluteUri, out var a) ? a() : new HttpResponseMessage(HttpStatusCode.NotFound));
        }
    }

    /// <summary>A body with no length that never ends (or waits before each read).</summary>
    private sealed class Endless(TimeSpan? delay = null) : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => 0; set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => count;

        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken ct = default)
        {
            if (delay is { } d) await Task.Delay(d, ct);
            return buffer.Length;
        }

        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    private sealed class FakeSignatures(Func<string, SignatureFacts> check) : ISignatureCheck
    {
        public SignatureFacts Check(string path) => check(path);
    }

    /// <summary>
    /// The PC: the installer (process 100) starts at t0 and exits at once with <see cref="ExitCode"/>; its setup (101, started
    /// just after it) and that one's child (102) run for <see cref="ChildLooks"/> more looks at the processes. <see cref="Others"/>
    /// run throughout (their start times from t0); <see cref="ReusedAfterChildren"/> start once the children have ended.
    /// </summary>
    private sealed class FakePc : IDriverPc
    {
        public int ExitCode { get; init; }
        public bool Decline { get; init; }
        public Exception? StartThrows { get; init; }
        public Exception? RescanThrows { get; init; }
        public bool AsUserWorks { get; init; } = true;
        public int ChildLooks { get; set; }
        public Func<DateTime, IEnumerable<(int Id, int Parent, DateTime Started)>> Others { get; init; } = _ => [];
        public Func<DateTime, IEnumerable<(int Id, int Parent, DateTime Started)>>? ReusedAfterChildren { get; init; }
        public Action<bool>? OnLook { get; set; }
        public int Runs, AsUser, ElevatedRuns, Looks;

        private DateTime _t0;
        private DateTime? _reusedAt;
        private Dictionary<int, DateTime> _started = [];

        public Task<InstallerProcess?> StartInstallerAsync(string path, CancellationToken ct)
        {
            if (StartThrows is { } ex) throw ex;
            if (Decline) return Task.FromResult<InstallerProcess?>(null);
            Runs++;
            _t0 = DateTime.UtcNow;
            return Task.FromResult<InstallerProcess?>(new InstallerProcess(100, _t0, Task.FromResult(new InstallerExited(ExitCode, _t0.AddMilliseconds(2)))));
        }

        public IReadOnlyList<ProcessLink> Processes()
        {
            Looks++;
            var alive = ChildLooks > 0;
            OnLook?.Invoke(alive);
            if (alive && ChildLooks != int.MaxValue) ChildLooks--;
            var all = new List<(int Id, int Parent, DateTime Started)> { (4, 0, _t0.AddDays(-3)) };
            all.AddRange(Others(_t0));
            if (alive) all.AddRange([(101, 100, _t0.AddMilliseconds(1)), (102, 101, _t0.AddMilliseconds(1.5))]);
            else if (ReusedAfterChildren is { } reused) all.AddRange(reused(_reusedAt ??= DateTime.UtcNow.AddMilliseconds(50)));
            _started = all.ToDictionary(p => p.Id, p => p.Started);
            return all.Select(p => new ProcessLink(p.Id, p.Parent)).ToList();
        }

        public DateTime? StartedAt(int id) => _started.TryGetValue(id, out var t) ? t : null;

        public Task<bool> RescanAsUserAsync(CancellationToken ct)
        {
            if (RescanThrows is { } ex) throw ex;
            if (AsUserWorks) AsUser++;
            return Task.FromResult(AsUserWorks);
        }

        public Task<bool> RescanElevatedAsync(CancellationToken ct)
        {
            if (RescanThrows is { } ex) throw ex;
            ElevatedRuns++;
            return Task.FromResult(true);
        }
    }
}
