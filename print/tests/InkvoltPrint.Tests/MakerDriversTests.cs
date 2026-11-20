using System.Net;
using InkvoltPrint.Core.Drivers;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Tests;

/// <summary>
/// "Get the driver" for Canon, HP, Brother and PFU (<see cref="CanonDrivers"/>, <see cref="HpDrivers"/>, <see cref="BrotherDrivers"/>,
/// <see cref="PfuDrivers"/>): each maker's pages and answers read from trimmed copies of the real ones (Fixtures/drivers, fetched
/// 2026-11-20), the whole lookup through a made-up web that serves them, and hostile answers. No live network.
/// </summary>
public sealed class MakerDriversTests
{
    private static string Fixture(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "drivers", name));

    private static NeedsDriverPrinter Device(string name, string maker, NeedsDriverKind kind = NeedsDriverKind.Printer) =>
        new("usb-needs-driver:" + name.Replace(' ', '-'), name, maker, null, DriverStage.NoDriver) { Kind = kind };

    private static DriverQuery Query(NeedsDriverPrinter d, PcArch arch = PcArch.X64, PcWindows windows = PcWindows.Windows11) => DriverQuery.For(d, arch, windows);

    // ---------------------------------------------------------------- the makers and their hosts

    [Theory]
    [InlineData("Canon", "Canon")]
    [InlineData("HP", "HP")]
    [InlineData("Brother", "Brother")]
    [InlineData("Fujitsu", "PFU")]
    [InlineData("PFU", "PFU")]
    [InlineData("epson", "Epson")]
    public void Each_maker_has_its_source(string maker, string source) => Assert.Equal(source, MakerSource.For(maker)?.Maker);

    [Theory]
    [InlineData("Ricoh")]  // Ricoh's printers aren't PFU's scanners
    [InlineData("Xerox")]
    [InlineData(null)]
    public void Other_makers_have_none(string? maker) => Assert.Null(MakerSource.For(maker));

    [Theory]
    [InlineData("Canon", "Canon Inc.")]
    [InlineData("HP", "HP Inc.")]
    [InlineData("HP", "Hewlett-Packard  Company")]
    [InlineData("Brother", "Brother Industries, Ltd.")]
    [InlineData("PFU", "PFU Limited")]
    public void The_installers_signers_are_the_makers_own(string maker, string signer) => Assert.True(MakerSource.For(maker)!.IsSigner(signer));

    [Theory]
    [InlineData("Canon", "Canon U.S.A., Inc.")]
    [InlineData("HP", "HP Inc. Partner")]
    [InlineData("Brother", "Epson America, Inc.")]
    [InlineData("PFU", "Fujitsu Limited")]
    public void Someone_elses_signature_isnt(string maker, string signer) => Assert.False(MakerSource.For(maker)!.IsSigner(signer));

    [Fact]
    public void The_app_looks_up_all_five_makers()
    {
        var catalogs = new MakerCatalogs(new EpsonDrivers(new BoundedHttp(new FakeWeb())), new CanonDrivers(new BoundedHttp(new FakeWeb())),
            new HpDrivers(new BoundedHttp(new FakeWeb())), new BrotherDrivers(new BoundedHttp(new FakeWeb())), new PfuDrivers(new BoundedHttp(new FakeWeb())));
        foreach (var maker in new[] { "Epson", "Canon", "HP", "Brother", "Fujitsu" }) Assert.True(catalogs.LooksUp(maker), maker);
        Assert.False(catalogs.LooksUp("Lexmark"));
    }

    // ---------------------------------------------------------------- Brother

    private static readonly NeedsDriverPrinter HlL2350 = Device("Brother HL-L2350DW series", "Brother");
    private static readonly NeedsDriverPrinter Ads1200 = Device("Brother ADS-1200", "Brother", NeedsDriverKind.Scanner);

    [Fact]
    public void Brothers_search_opens_the_models_page_with_its_product_code()
    {
        Assert.Equal("hll2350dw_us_eu_as", BrotherDrivers.ProductCode(Fixture("brother-search-hll2350dw.html"), HlL2350.Name));
        Assert.Null(BrotherDrivers.ProductCode(Fixture("brother-search-hll2350dw.html"), "Brother HL-L2350"));      // another model the search guessed
        Assert.Null(BrotherDrivers.ProductCode("<html>Several products</html>", HlL2350.Name));
        // Brother's "(XL)" bundles are the model.
        Assert.Equal("mfcl2750dw_us_eu_as", BrotherDrivers.ProductCode(
            "<h3 class=\"title\"><a href=\"/g/b/producttop.aspx?c=us&lang=en&prod=mfcl2750dw_us_eu_as\">MFC-L2750DW(XL)</a></h3>", "Brother MFC-L2750DW series"));
    }

    [Fact]
    public void Brothers_list_gives_a_printer_its_printer_driver_then_the_full_package()
    {
        var list = BrotherDrivers.ParseList(Fixture("brother-hll2350dw-windows11.html"));
        Assert.Contains(list, e => e.Section == "Utilities" && e.Download.Title == "Wireless Setup Helper");
        var ranked = BrotherDrivers.Ranked(list, NeedsDriverKind.Printer);
        Assert.Equal(["Printer Driver", "XML Paper Specification Printer Driver", "Full Driver & Software Package"], ranked.Select(d => d.Title));
        Assert.Equal(("1.12.0.0", "30.16 MB"), (ranked[0].Version, ranked[0].SizeText));
        Assert.Equal("/g/b/downloadhowto.aspx", ranked[0].Link.AbsolutePath);
        Assert.Contains("dlid=dlf106853_000", ranked[0].Link.Query);
    }

    [Fact]
    public void A_Brother_scanner_with_only_the_full_package_gets_that()
    {
        var ranked = BrotherDrivers.Ranked(BrotherDrivers.ParseList(Fixture("brother-ads1200-windows11.html")), NeedsDriverKind.Scanner);
        Assert.Equal("Full Driver & Software Package", Assert.Single(ranked).Title);
        Assert.DoesNotContain(BrotherDrivers.Ranked(BrotherDrivers.ParseList(Fixture("brother-hll2350dw-windows11.html")), NeedsDriverKind.Scanner),
            d => d.Title.Contains("Printer"));
    }

    [Fact]
    public async Task Brothers_lookup_reads_four_pages_and_offers_the_file_on_download_brother_com()
    {
        var web = new FakeWeb();
        web.Text("https://support.brother.com/g/b/productlist.aspx?c=us&lang=en&content=dl&q=hl-l2350dw", Fixture("brother-search-hll2350dw.html"));
        web.Text("https://support.brother.com/g/b/downloadlist.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068", Fixture("brother-hll2350dw-windows11.html"));
        web.Text("https://support.brother.com/g/b/downloadhowto.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068&dlid=dlf106853_000&flang=4&type3=408",
            Fixture("brother-howto-printer-driver.html"));
        var found = await new BrotherDrivers(new BoundedHttp(web)).FindAsync(Query(HlL2350), CancellationToken.None);
        var offer = found.Offer!;
        Assert.Equal(new Uri("https://download.brother.com/welcome/dlf106853/Y17B_C1-hostm-1120.EXE"), offer.Download);
        Assert.Equal(("Printer Driver", "1.12.0.0", "Y17B_C1-hostm-1120.EXE"), (offer.Title, offer.Version, offer.FileName));
        Assert.Equal("https://support.brother.com/g/b/downloadtop.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as", offer.Page.AbsoluteUri);
        Assert.All(web.Asked, u => Assert.Equal("support.brother.com", u.Host));
    }

    [Fact]
    public async Task On_ARM64_Brothers_x64_drivers_arent_offered()
    {
        var web = new FakeWeb();
        web.Text("https://support.brother.com/g/b/productlist.aspx?c=us&lang=en&content=dl&q=hl-l2350dw", Fixture("brother-search-hll2350dw.html"));
        web.Text("https://support.brother.com/g/b/downloadlist.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068", Fixture("brother-hll2350dw-windows11.html"));
        var found = await new BrotherDrivers(new BoundedHttp(web)).FindAsync(Query(HlL2350, PcArch.Arm64), CancellationToken.None);
        Assert.Equal(NoOffer.NoArm64, found.Why);
        Assert.NotNull(found.Page);
    }

    [Theory]
    [InlineData("https://downloads.example/driver.exe")]
    [InlineData("http://download.brother.com/welcome/dlf106853/Y17B_C1-hostm-1120.EXE")]
    [InlineData("https://download.brother.com.example/x.exe")]
    public async Task A_Brother_file_off_its_download_host_is_no_offer(string href)
    {
        var web = new FakeWeb();
        web.Text("https://support.brother.com/g/b/productlist.aspx?c=us&lang=en&content=dl&q=hl-l2350dw", Fixture("brother-search-hll2350dw.html"));
        web.Text("https://support.brother.com/g/b/downloadlist.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068", Fixture("brother-hll2350dw-windows11.html"));
        web.Text("https://support.brother.com/g/b/downloadhowto.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068&dlid=dlf106853_000&flang=4&type3=408",
            Fixture("brother-howto-printer-driver.html").Replace("https://download.brother.com/welcome/dlf106853/Y17B_C1-hostm-1120.EXE", href, StringComparison.Ordinal));
        var found = await new BrotherDrivers(new BoundedHttp(web)).FindAsync(Query(HlL2350), CancellationToken.None);
        Assert.Null(found.Offer);
        Assert.Equal(NoOffer.NotFound, found.Why);
    }

    // ---------------------------------------------------------------- HP

    private static readonly NeedsDriverPrinter M234 = Device("HP LaserJet MFP M234dw", "HP");
    private const string HpSearch = "https://support.hp.com/typeahead?q=laserjet%20mfp%20m234dw&resultLimit=10&store=tmsstore&languageCode=en&filters=class:(pm_series_value%5E1.1%20OR%20pm_name_value%20OR%20pm_number_value)";
    private const string HpSystems = "https://support.hp.com/wcc-services/swd-v2/osVersionData?cc=us&lc=en&productOid=30836604";
    private const string HpList = "https://support.hp.com/wcc-services/swd-v2/driverDetails?authState=anonymous&template=SWD_PDP_Drivers";

    [Fact]
    public void HPs_search_gives_the_models_product_not_its_trade_or_e_variant()
    {
        Assert.Equal(30836604, HpDrivers.ProductId(Fixture("hp-search-m234dw.json"), M234.Name));
        Assert.Equal(30836604, HpDrivers.ProductId(Fixture("hp-search-m234dw.json"), "HP LaserJet MFP M234dw Printer"));
        Assert.Equal(36120178, HpDrivers.ProductId(Fixture("hp-search-m234dw.json"), "HP LaserJet MFP M234dwe"));
        Assert.Null(HpDrivers.ProductId(Fixture("hp-search-m234dw.json"), "HP OfficeJet Pro 9015"));
        // Asked without HP's printFields, as the app asks, the search names its products "productname".
        Assert.Equal(30836604, HpDrivers.ProductId(Fixture("hp-search-m234dw.json").Replace("\"name\"", "\"productname\"", StringComparison.Ordinal), M234.Name));
    }

    [Theory]
    [InlineData(PcWindows.Windows11, PcArch.X64, "1117042031711110499111149613201312551119131")]
    [InlineData(PcWindows.Windows11, PcArch.Arm64, "16144137901514415411821122407512213166102")]
    [InlineData(PcWindows.Windows10, PcArch.X64, "792898937266030878164166465223921")]
    public void HPs_systems_give_this_windows_ids(PcWindows windows, PcArch arch, string version)
    {
        var ids = HpDrivers.OsIds(Fixture("hp-systems-m234dw.json"), HpDrivers.OsName(windows, arch))!.Value;
        Assert.Equal(("487192269364721453674728010296573", version), ids);
    }

    [Fact]
    public void HPs_list_gives_a_printer_the_offline_installer_and_a_scanner_the_scan_driver()
    {
        var list = HpDrivers.ParseList(Fixture("hp-drivers-m234dw-windows11.json"));
        var printer = HpDrivers.Ranked(list, NeedsDriverKind.Printer);
        Assert.StartsWith("HP LaserJet MFP M232dw", printer[0].Title);
        Assert.Equal(("52.3.4930", "297.7 MB"), (printer[0].Version, printer[0].SizeText));
        Assert.DoesNotContain(printer, d => d.Title.Contains("Universal Scan") || d.Title.Contains("Firmware") || d.Link.AbsolutePath.EndsWith(".zip"));
        Assert.DoesNotContain(printer, d => d.Link.Host == "apps.microsoft.com");
        var scanner = HpDrivers.Ranked(list, NeedsDriverKind.Scanner);
        Assert.Contains("Basic Feature", scanner[0].Title);
        Assert.Equal("HP Universal Scan - Basic Feature Software and Driver", DriverPages.ForThisPc(scanner, PcArch.X64, out _)!.Title);
        Assert.Equal("HP Universal Scan - Basic Feature Software and Driver (ARM 64)", DriverPages.ForThisPc(scanner, PcArch.Arm64, out _)!.Title);
    }

    [Fact]
    public async Task HPs_lookup_asks_its_search_systems_and_list_and_offers_the_file_on_ftp_hp_com()
    {
        var web = new FakeWeb();
        web.Text(HpSearch, Fixture("hp-search-m234dw.json"));
        web.Text(HpSystems, Fixture("hp-systems-m234dw.json"));
        web.Post(HpList, Fixture("hp-drivers-m234dw-windows11.json"));
        var found = await new HpDrivers(new BoundedHttp(web)).FindAsync(Query(M234), CancellationToken.None);
        Assert.Equal(new Uri("https://ftp.hp.com/pub/softlib/software13/printers/LJM232-M237/HPEasyStart-16.2.4-LJM232-M237_UWWL_52_3_4930_Webpack.exe"), found.Offer!.Download);
        Assert.Equal("https://support.hp.com/us-en/drivers/30836604", found.Offer.Page.AbsoluteUri);
        // The post names the product and this Windows, nothing else.
        var sent = Assert.Single(web.Posted);
        Assert.Contains("\"productNameOid\":30836604", sent);
        Assert.Contains("\"osTMSId\":\"1117042031711110499111149613201312551119131\"", sent);
        Assert.Contains("\"osName\":\"Windows 11\"", sent);
    }

    [Fact]
    public async Task HPs_list_redirecting_is_not_posted_again()
    {
        var web = new FakeWeb();
        web.Text(HpSearch, Fixture("hp-search-m234dw.json"));
        web.Text(HpSystems, Fixture("hp-systems-m234dw.json"));
        web.Redirect(HpList, "https://support.hp.com/elsewhere");
        var found = await new HpDrivers(new BoundedHttp(web)).FindAsync(Query(M234), CancellationToken.None);
        Assert.Equal((NoOffer.Unreachable, FetchProblem.Unreachable), (found.Why, found.Problem));
        Assert.DoesNotContain(web.Asked, u => u.AbsolutePath == "/elsewhere");
    }

    [Theory]
    [InlineData("https://ftp.hp.com.example/pub/x.exe")]
    [InlineData("http://ftp.hp.com/pub/softlib/x.exe")]
    [InlineData("https://hp.example/driver.exe")]
    public void An_HP_file_off_its_hosts_is_no_offer(string url)
    {
        var json = Fixture("hp-drivers-m234dw-windows11.json")
            .Replace("https://ftp.hp.com/pub/softlib/software13/printers/LJM232-M237/HPEasyStart-16.2.4-LJM232-M237_UWWL_52_3_4930_Webpack.exe", url, StringComparison.Ordinal);
        var pick = DriverPages.ForThisPc(HpDrivers.Ranked(HpDrivers.ParseList(json), NeedsDriverKind.Printer), PcArch.X64, out _)!;
        Assert.Null(DriverPages.Offer(pick, pick.Link, new Uri("https://support.hp.com/"), MakerSource.Hp).Offer);
    }

    // ---------------------------------------------------------------- Canon

    private static readonly NeedsDriverPrinter Lide400 = Device("Canon CanoScan LiDE 400", "Canon", NeedsDriverKind.Scanner);

    [Fact]
    public void Canons_suggestions_give_the_models_name_there()
    {
        Assert.Equal("CanoScan LiDE 400", CanonDrivers.ModelName(Fixture("canon-suggest-lide400.json"), Lide400.Name));
        // A page several models share, by any of their names; the line left out of the device's name or not.
        Assert.Equal("imageCLASS LBP6030/ LBP6030B/ LBP6030w", CanonDrivers.ModelName(Fixture("canon-suggest-lbp6030w.json"), "Canon LBP6030w"));
        Assert.Equal("imageCLASS LBP6030/ LBP6030B/ LBP6030w", CanonDrivers.ModelName(Fixture("canon-suggest-lbp6030w.json"), "Canon imageCLASS LBP6030w"));
        Assert.Null(CanonDrivers.ModelName(Fixture("canon-suggest-lbp6030w.json"), "Canon LBP6030dn"));
        Assert.Null(CanonDrivers.ModelName("{\"success\":true,\"data\":[]}", Lide400.Name));
        Assert.Equal("imageCLASS%20LBP6030__%20LBP6030B__%20LBP6030w", CanonDrivers.PathOf("imageCLASS LBP6030/ LBP6030B/ LBP6030w"));
    }

    [Fact]
    public void Canons_list_gives_a_scanner_its_driver_and_a_printer_its_MP_drivers()
    {
        var scanner = CanonDrivers.Ranked(CanonDrivers.ParseList(Fixture("canon-lide400-windows11.html")), NeedsDriverKind.Scanner);
        Assert.Equal(["CanoScan LiDE 400 Scanner Driver Ver.1.01 (Windows)", "CanoScan LiDE 400 Full Driver & Software Package (Windows)"], scanner.Select(d => d.Title));
        Assert.Equal("58.46 MB", scanner[0].SizeText);
        var printer = CanonDrivers.Ranked(CanonDrivers.ParseList(Fixture("canon-g3010-windows11.html")), NeedsDriverKind.Printer);
        Assert.Equal("G3010 MP Drivers Ver.1.04 (Windows)", printer[0].Title);
        Assert.DoesNotContain(printer, d => d.Title.Contains("security patch"));
        Assert.Equal("https://asia.canon/en/support/0100911616?model=PIXMA+G3010", printer[0].Link.AbsoluteUri);
    }

    [Fact]
    public async Task Canons_lookup_reads_the_list_and_the_files_page_and_offers_canons_download_link()
    {
        var web = new FakeWeb();
        web.Text("https://asia.canon/en/support/suggest?query=canoscan%20lide%20400", Fixture("canon-suggest-lide400.json"));
        web.Text("https://asia.canon/en/support/CanoScan%20LiDE%20400/get-search-result-content?fileType=DR&os=Windows%2011&q=", Fixture("canon-lide400-windows11.html"));
        web.Text("https://asia.canon/en/support/0100963702?model=CanoScan+LiDE+400", Fixture("canon-lide400-scanner-driver.html"));
        var offer = (await new CanonDrivers(new BoundedHttp(web)).FindAsync(Query(Lide400), CancellationToken.None)).Offer!;
        Assert.Equal("https://pdisp01.c-wss.com/gdl/WWUFORedirectTarget.do?id=MDEwMDAwOTYzNzAy&cmp=ACB&lang=EN", offer.Download.AbsoluteUri);
        Assert.Equal(("1.01", "sc68-win-lide400-1_01-ea34_2.exe"), (offer.Version, offer.FileName));
        Assert.Equal("https://asia.canon/en/support/CanoScan%20LiDE%20400/model", offer.Page.AbsoluteUri);
        // Canon's link sends the file on from its other server, which is Canon's too.
        Assert.True(BoundedHttp.IsAllowed(new Uri("https://gdlp01.c-wss.com/gds/7/0100009637/02/sc68-win-lide400-1_01-ea34_2.exe"), MakerSource.Canon.DownloadHosts));
    }

    [Fact]
    public void A_canon_page_whose_link_isnt_canons_has_no_file()
    {
        var hostile = Fixture("canon-lide400-scanner-driver.html").Replace("https://pdisp01.c-wss.com/gdl/", "https://pdisp01.c-wss.com.example/gdl/", StringComparison.Ordinal);
        Assert.Null(CanonDrivers.ParseDetail(hostile, new MakerDownload("x", "", null, null, new Uri("https://asia.canon/"))));
    }

    // ---------------------------------------------------------------- PFU

    private static readonly NeedsDriverPrinter Fi8170 = Device("fi-8170", "Fujitsu", NeedsDriverKind.Scanner);

    [Fact]
    public void PFUs_list_of_models_has_the_models_page()
    {
        Assert.Equal("https://www.pfu.ricoh.com/global/scanners/fisp/dl/fi-8170.html", PfuDrivers.ModelPage(Fixture("pfu-models.html"), "Fujitsu fi-8170")!.AbsoluteUri);
        Assert.Null(PfuDrivers.ModelPage(Fixture("pfu-models.html"), "Fujitsu ScanSnap iX1600")); // ScanSnap: not there
        Assert.Null(PfuDrivers.ModelPage(Fixture("pfu-models.html"), "fi-81"));
    }

    [Theory]
    [InlineData(PcArch.X64, "PaperStream IP (TWAIN x64) 3.40.2", "PSIPTWAIN64-3_40_2.exe")]
    [InlineData(PcArch.Arm64, "PaperStream IP (TWAIN) 3.40.3 (for ARM-based PCs)", "PSIPTWAIN-3_40_3.exe")]
    public void PFUs_page_gives_PaperStream_IP_for_this_processor(PcArch arch, string title, string file)
    {
        var ranked = PfuDrivers.Ranked(PfuDrivers.ParsePage(Fixture("pfu-fi8170.html"), "win-11"));
        Assert.DoesNotContain(ranked, d => d.Link.AbsolutePath.EndsWith(".iso"));
        var pick = DriverPages.ForThisPc(ranked, arch, out _)!;
        var offer = DriverPages.Offer(pick, pick.Link, new Uri("https://www.pfu.ricoh.com/"), MakerSource.Pfu).Offer!;
        Assert.Equal((title, file), (offer.Title, offer.FileName));
        Assert.Equal("origin.pfultd.com", offer.Download.Host);
    }

    [Fact]
    public async Task PFUs_lookup_reads_the_list_of_models_then_the_models_page()
    {
        var web = new FakeWeb();
        web.Text("https://www.pfu.ricoh.com/global/scanners/fisp/dl/", Fixture("pfu-models.html"));
        web.Text("https://www.pfu.ricoh.com/global/scanners/fisp/dl/fi-8170.html", Fixture("pfu-fi8170.html"));
        var found = await new PfuDrivers(new BoundedHttp(web)).FindAsync(Query(Fi8170, windows: PcWindows.Windows10), CancellationToken.None);
        Assert.Equal("https://origin.pfultd.com/downloads/IMAGE/fi/psip-twain64/3402/PSIPTWAIN64-3_40_2.exe", found.Offer!.Download.AbsoluteUri);
        Assert.Equal("3.40.2", found.Offer.Version);
    }

    // ---------------------------------------------------------------- the review's findings: processors, systems, names, licences

    [Fact]
    public void On_x64_only_TWAIN_x64_is_offered_and_never_32_bit_TWAIN_or_ISIS()
    {
        var withoutX64 = PfuDrivers.ParsePage(Fixture("pfu-fi8170.html"), "win-11").Where(d => !d.Title.Contains("TWAIN x64")).ToList();
        var ranked = PfuDrivers.Ranked(withoutX64);
        Assert.All(ranked, d => Assert.Contains("ARM", d.Title));
        Assert.Null(DriverPages.ForThisPc(ranked, PcArch.X64, out var why));
        Assert.Equal(NoOffer.NotFound, why); // ARM builds only: not "no ARM driver" on an x64 PC
        Assert.DoesNotContain(PfuDrivers.Ranked(PfuDrivers.ParsePage(Fixture("pfu-fi8170.html"), "win-11")), d => d.Title.Contains("ISIS"));
    }

    [Theory]
    [InlineData(PcArch.Arm64, true, NoOffer.NoArm64)]
    [InlineData(PcArch.X64, true, NoOffer.NotFound)]
    [InlineData(PcArch.Arm64, false, NoOffer.NotFound)]
    public void No_ARM64_driver_is_said_only_on_ARM64(PcArch arch, bool listed, NoOffer why) => Assert.Equal(why, DriverPages.WhyNone(listed, arch));

    [Theory]
    [InlineData(PcWindows.Windows11, PcArch.X64, "10068", "Windows 11", "Windows 11", "win-11")]
    [InlineData(PcWindows.Windows10, PcArch.X64, "10013", "Windows 10 (x64)", "Windows 10 (64-bit)", "win-10")]
    [InlineData(PcWindows.Windows11, PcArch.Arm64, "10068", "Windows 11", "Windows 11 on ARM (64-bit)", "win-11")]
    [InlineData(PcWindows.Windows10, PcArch.Arm64, "10068", "Windows 11", "Windows 11 on ARM (64-bit)", "win-11")]
    public void ARM64_asks_each_site_for_the_list_its_ARM_builds_are_in(PcWindows windows, PcArch arch, string brother, string canon, string hp, string pfu)
    {
        // Checked on the sites 2026-11-20: HP has an ARM system; Brother, Canon and PFU list theirs (if any) under Windows 11.
        Assert.Equal(brother, BrotherDrivers.OsCode(windows, arch));
        Assert.Equal(canon, CanonDrivers.OsFilter(windows, arch));
        Assert.Equal(hp, HpDrivers.OsName(windows, arch));
        Assert.Equal(pfu, PfuDrivers.OsId(windows, arch));
    }

    [Fact]
    public async Task HPs_ARM_list_gives_a_scanner_its_ARM_scan_driver_and_a_printer_none()
    {
        var web = new FakeWeb();
        web.Text(HpSearch, Fixture("hp-search-m234dw.json"));
        web.Text(HpSystems, Fixture("hp-systems-m234dw.json"));
        web.Post(HpList, Fixture("hp-drivers-m234dw-windows11-arm.json"));
        var scanner = await new HpDrivers(new BoundedHttp(web)).FindAsync(Query(Device(M234.Name, "HP", NeedsDriverKind.Scanner), PcArch.Arm64), CancellationToken.None);
        Assert.Equal("HP Universal Scan - Basic Feature Software and Driver (ARM 64)", scanner.Offer!.Title);
        Assert.Contains("\"osName\":\"Windows 11 on ARM (64-bit)\"", web.Posted[0]);
        Assert.Contains("\"osTMSId\":\"16144137901514415411821122407512213166102\"", web.Posted[0]);
        var printer = await new HpDrivers(new BoundedHttp(web)).FindAsync(Query(M234, PcArch.Arm64), CancellationToken.None);
        Assert.Equal(NoOffer.NotFound, printer.Why); // HP lists nothing for the printer itself on ARM
    }

    [Theory]
    [InlineData("V19_EScan_3950_AM.exe", "https://ftp.epson.com/drivers/x.exe", "Title", "V19_EScan_3950_AM.exe")]  // the page's name
    [InlineData("Scanner Driver and EPSON Scan Utility", "https://ftp.epson.com/drivers/V19.exe", "Title", "V19.exe")] // a display name: the address's
    [InlineData(null, "https://pdisp01.c-wss.com/gdl/WWUFORedirectTarget.do?id=1", "LiDE 400 Scanner Driver (Windows)", "LiDE_400_Scanner_Driver__Windows_.exe")]
    [InlineData("", "https://pdisp01.c-wss.com/gdl/WWUFORedirectTarget.do", "", "driver.exe")]
    public void The_saved_name_is_the_pages_exe_name_else_the_addresss_else_the_title(string? page, string url, string title, string expected) =>
        Assert.Equal(expected, DriverPages.SafeFileName(page, new Uri(url), title));

    [Fact]
    public void A_canon_page_without_a_file_name_is_saved_by_its_title_not_canons_redirect()
    {
        var page = string.Join('\n', Fixture("canon-lide400-scanner-driver.html").Split('\n').Where(l => !l.Contains("File name")));
        var file = CanonDrivers.ParseDetail(page, new MakerDownload("CanoScan LiDE 400 Scanner Driver Ver.1.01 (Windows)", "", null, null, new Uri("https://asia.canon/")))!.Value;
        var offer = DriverPages.Offer(file.Download, file.Url, new Uri("https://asia.canon/"), MakerSource.Canon).Offer!;
        Assert.Equal("CanoScan_LiDE_400_Scanner_Driver_Ver.1.01__Windows_.exe", offer.FileName);
    }

    [Fact]
    public async Task Brothers_and_canons_offers_carry_the_licence_the_click_accepts()
    {
        var web = new FakeWeb();
        web.Text("https://support.brother.com/g/b/productlist.aspx?c=us&lang=en&content=dl&q=hl-l2350dw", Fixture("brother-search-hll2350dw.html"));
        web.Text("https://support.brother.com/g/b/downloadlist.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068", Fixture("brother-hll2350dw-windows11.html"));
        web.Text("https://support.brother.com/g/b/downloadhowto.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068&dlid=dlf106853_000&flang=4&type3=408",
            Fixture("brother-howto-printer-driver.html"));
        web.Text("https://asia.canon/en/support/suggest?query=canoscan%20lide%20400", Fixture("canon-suggest-lide400.json"));
        web.Text("https://asia.canon/en/support/CanoScan%20LiDE%20400/get-search-result-content?fileType=DR&os=Windows%2011&q=", Fixture("canon-lide400-windows11.html"));
        web.Text("https://asia.canon/en/support/0100963702?model=CanoScan+LiDE+400", Fixture("canon-lide400-scanner-driver.html"));
        var brother = (await new BrotherDrivers(new BoundedHttp(web)).FindAsync(Query(HlL2350), CancellationToken.None)).Offer!;
        var canon = (await new CanonDrivers(new BoundedHttp(web)).FindAsync(Query(Lide400), CancellationToken.None)).Offer!;

        Assert.Equal("https://support.brother.com/g/b/downloadend.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10068&dlid=dlf106853_000&flang=4&type3=408",
            brother.Licence!.AbsoluteUri);
        Assert.Equal("https://asia.canon/en/support/0100963702?model=CanoScan+LiDE+400#disclaimer", canon.Licence!.AbsoluteUri);

        // A Store copy opens the maker's page with the licence, not the file; with no licence, the file.
        var flow = new DriverFlow(new MakerCatalogs(), new BoundedHttp(web), new NoSignatures(), new NoPc(), Path.GetTempPath(), PcArch.X64, PcWindows.Windows11, DriverMode.OpenLink);
        Assert.Equal(brother.Licence, flow.LinkFor(brother, HlL2350));
        Assert.Equal(canon.Licence, flow.LinkFor(canon, Lide400));
        Assert.Equal(brother.Download, flow.LinkFor(brother with { Licence = null }, HlL2350));
        // A licence off the maker's site is never kept nor opened.
        Assert.Null(DriverPages.Offer(new MakerDownload("x", "", null, null, brother.Download), brother.Download, brother.Page, MakerSource.Brother,
            new Uri("https://eula.example/agree")).Offer!.Licence);
        Assert.Null(flow.LinkFor(brother with { Licence = new Uri("https://eula.example/agree") }, HlL2350));
        Assert.False(string.IsNullOrWhiteSpace(DriverText.LicenceNote(HlL2350)));
    }

    private sealed class NoSignatures : ISignatureCheck
    {
        public SignatureFacts Check(string path) => new(SignatureState.NotSigned, null);
    }

    private sealed class NoPc : IDriverPc
    {
        public Task<InstallerProcess?> StartInstallerAsync(string path, CancellationToken ct) => Task.FromResult<InstallerProcess?>(null);
        public IReadOnlyList<ProcessLink> Processes() => [];
        public DateTime? StartedAt(int id) => null;
        public Task<bool> RescanAsUserAsync(CancellationToken ct) => Task.FromResult(false);
        public Task<bool> RescanElevatedAsync(CancellationToken ct) => Task.FromResult(false);
    }

    // ---------------------------------------------------------------- hostile answers

    public static TheoryData<string> Junk => new()
    {
        "", "not json", "{\"data\":", "[1,2,3]", "{\"matches\":\"x\"}", new string('[', 5000), "<html>" + new string('<', 100_000),
        "{\"data\":{\"softwareTypes\":[{\"softwareDriversList\":[{\"latestVersionDriver\":{\"title\":\"x\",\"fileUrl\":\"javascript:alert(1)\"}}]}]}}",
    };

    [Theory]
    [MemberData(nameof(Junk))]
    public void Junk_answers_give_nothing(string junk)
    {
        Assert.Null(BrotherDrivers.ProductCode(junk, HlL2350.Name));
        Assert.Empty(BrotherDrivers.ParseList(junk));
        Assert.Null(BrotherDrivers.FileOf(junk));
        Assert.Null(HpDrivers.ProductId(junk, M234.Name));
        Assert.Null(HpDrivers.OsIds(junk, "Windows 11"));
        Assert.Empty(HpDrivers.Ranked(HpDrivers.ParseList(junk), NeedsDriverKind.Printer));
        Assert.Null(CanonDrivers.ModelName(junk, Lide400.Name));
        Assert.Empty(CanonDrivers.ParseList(junk));
        Assert.Null(PfuDrivers.ModelPage(junk, Fi8170.Name));
        Assert.Empty(PfuDrivers.ParsePage(junk, "win-11"));
    }

    [Fact]
    public void A_flood_of_entries_is_cut_short()
    {
        var row = "<h3 class=\"h3\">Drivers</h3>" + string.Concat(Enumerable.Repeat(
            "<tr><td><em><a href=\"/g/b/downloadend.aspx?c=us&lang=en&prod=p&os=10068&dlid=dlf1_000\">Printer Driver</a></em></td></tr>", 5000));
        Assert.Equal(100, BrotherDrivers.ParseList(row).Count); // a section's first 100 rows
        Assert.True(BrotherDrivers.ParseList(string.Concat(Enumerable.Repeat(row, 10))).Count <= 200);
        var cards = string.Concat(Enumerable.Repeat("<div class=\"softwareCard\"><h3 class=\"softwareCard__content--title\"><a href=\"/en/support/0100963702?model=X\">Scanner Driver</a></h3>", 5000));
        Assert.Equal(200, CanonDrivers.ParseList(cards).Count);
    }

    [Theory]
    [InlineData(@"..\..\Windows\evil.bat")]
    [InlineData("C:/x/../../evil")]
    [InlineData("")]
    public void A_hostile_file_name_is_made_safe(string name)
    {
        var page = Fixture("canon-lide400-scanner-driver.html").Replace("sc68-win-lide400-1_01-ea34_2.exe", name, StringComparison.Ordinal);
        var file = CanonDrivers.ParseDetail(page, new MakerDownload("x", "", null, null, new Uri("https://asia.canon/")))!.Value;
        var offer = DriverPages.Offer(file.Download, file.Url, new Uri("https://asia.canon/"), MakerSource.Canon).Offer!;
        Assert.DoesNotContain("..", offer.FileName);
        Assert.DoesNotContain('\\', offer.FileName);
        Assert.DoesNotContain('/', offer.FileName);
        Assert.EndsWith(".exe", offer.FileName);
    }

    [Fact]
    public void Model_words_drop_the_maker_and_the_kind()
    {
        Assert.Equal("hl-l2350dw", BrotherDrivers.Words("Brother HL-L2350DW series"));
        Assert.Equal("laserjet mfp m234dw", HpDrivers.Words("HP LaserJet MFP M234dw Printer"));
        Assert.Equal("canoscan lide 400", CanonDrivers.Words("Canon CanoScan LiDE 400"));
        Assert.Equal("fi-8170", PfuDrivers.Words("FUJITSU fi-8170"));
        Assert.Equal("", HpDrivers.Words("HP Printer"));
        Assert.True(DriverPages.ModelWords(new string('a', 10_000)).Length <= 200);
    }

    private sealed class FakeWeb : HttpMessageHandler
    {
        private readonly Dictionary<string, Func<HttpResponseMessage>> _answers = new(StringComparer.Ordinal);
        private readonly Dictionary<string, Func<HttpResponseMessage>> _posts = new(StringComparer.Ordinal);
        public List<Uri> Asked { get; } = [];
        public List<string> Posted { get; } = [];

        public void Text(string uri, string text) => _answers[new Uri(uri).AbsoluteUri] = () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text) };

        public void Post(string uri, string text) => _posts[new Uri(uri).AbsoluteUri] = () => new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent(text) };

        public void Redirect(string uri, string to) => _posts[new Uri(uri).AbsoluteUri] = _answers[new Uri(uri).AbsoluteUri] = () =>
        {
            var r = new HttpResponseMessage(HttpStatusCode.Found);
            r.Headers.Location = new Uri(to);
            return r;
        };

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            Asked.Add(request.RequestUri!);
            var answers = request.Method == HttpMethod.Post ? _posts : _answers;
            if (request.Content is { } body) Posted.Add(await body.ReadAsStringAsync(ct));
            return answers.TryGetValue(request.RequestUri!.AbsoluteUri, out var a) ? a() : new HttpResponseMessage(HttpStatusCode.NotFound);
        }
    }
}
