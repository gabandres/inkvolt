import Foundation
import Testing
@testable import PrintCore

/// "Get the driver" for Canon, HP, Brother and PFU on the Mac (ported from MakerDriversTests.cs): each maker's search and model
/// pages read from the .NET tests' copies of the real ones (Fixtures/drivers, read in place; the same pages whatever the
/// system), their macOS lists written in each site's own markup as it gave them (checked live 2026-11-27: Brother's
/// HL-L2350DW on macOS 26, HP's M234dw on macOS 26, PFU's fi-8170, Canon's LiDE 400 and G3010), the whole lookup through a
/// made-up web, and hostile answers. No live network. The signer and file name tests stay with Windows (the Mac neither
/// saves nor runs a file).
struct MakerDriversTests {
    static func fixture(_ name: String) throws -> String { try Fixtures.text("drivers/" + name) }

    static func device(_ name: String, _ maker: String, _ kind: NeedsDriverKind = .printer) -> NeedsDriverPrinter {
        NeedsDriverPrinter(id: "usb-needs-driver:" + name.replacingOccurrences(of: " ", with: "-"), name: name, maker: maker, kind: kind)
    }

    static func query(_ d: NeedsDriverPrinter, _ arch: MacArch = .appleSilicon, macOS: Int = 26) -> DriverQuery { .for(d, arch: arch, macOS: macOS) }

    // MARK: The makers and their hosts

    @Test(arguments: [("Canon", "Canon"), ("HP", "HP"), ("Brother", "Brother"), ("Fujitsu", "PFU"), ("PFU", "PFU"), ("epson", "Epson")])
    func Each_maker_has_its_source(_ maker: String, _ source: String) { #expect(MakerSource.for(maker)?.maker == source) }

    @Test(arguments: ["Ricoh", "Xerox", nil] as [String?]) // Ricoh's printers aren't PFU's scanners
    func Other_makers_have_none(_ maker: String?) { #expect(MakerSource.for(maker) == nil) }

    @Test func The_app_looks_up_all_five_makers() {
        let catalogs = MakerCatalogs.all(MakerWeb(FakeWeb()))
        for maker in ["Epson", "Canon", "HP", "Brother", "Fujitsu"] { #expect(catalogs.looksUp(maker), "\(maker)") }
        #expect(!catalogs.looksUp("Lexmark"))
    }

    // MARK: Brother

    static let hlL2350 = device("Brother HL-L2350DW series", "Brother")
    static let ads1200 = device("Brother ADS-1200", "Brother", .scanner)
    static let brotherSearch = "https://support.brother.com/g/b/productlist.aspx?c=us&lang=en&content=dl&q=hl-l2350dw"
    static let brotherMacList = "https://support.brother.com/g/b/downloadlist.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10088"
    static let brotherHowto = "https://support.brother.com/g/b/downloadhowto.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10088&dlid=dlf107315_000&flang=4&type3=583"

    static func brotherRow(_ title: String, dlid: String, type3: Int, version: String, size: String) -> String {
        """
        <tr>
        <td><em><a href="/g/b/downloadend.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10088&dlid=\(dlid)&flang=4&type3=\(type3)">\(title)</a></em></td>
        <td><div class="moreView-more"><div class="type3comment">We recommend this download to get the most functionality out of your Brother machine.</div></div></td>
        <td class="text-center"><em>11/04/2026<br>(\(version))</em></td>
        <td class="text-center"><em>\(size)<BR>MB</em></td>
        </tr>
        """
    }

    /// The HL-L2350DW's macOS 26 list as Brother gave it (2026-11-27): its full package, firmware tool and a utility.
    static let brotherMac = "<h3 class=\"h3\">Full Software Package</h3><table><tbody>"
        + brotherRow("Full Software Package", dlid: "dlf107315_000", type3: 583, version: "1.0.0", size: "246.56") + "</tbody></table>"
        + "<h3 class=\"h3\">Firmware</h3><table><tbody>" + brotherRow("Firmware Update Tool", dlid: "dlf107199_000", type3: 375, version: "1.83", size: "20.31")
        + "</tbody></table><h3 class=\"h3\">Utilities</h3><table><tbody>"
        + brotherRow("Wireless Setup Wizard", dlid: "dlf104859_000", type3: 70, version: "1.18.1", size: "2.04") + "</tbody></table>"

    static func brotherHowtoPage(_ href: String = "https://download.brother.com/welcome/dlf107315/Brother_PrinterDrivers_MonochromeLaser_1_0_0.dmg") throws -> String {
        try fixture("brother-howto-printer-driver.html").replacingOccurrences(of: "https://download.brother.com/welcome/dlf106853/Y17B_C1-hostm-1120.EXE", with: href)
    }

    @Test func Brothers_search_opens_the_models_page_with_its_product_code() throws {
        #expect(BrotherDrivers.productCode(try Self.fixture("brother-search-hll2350dw.html"), Self.hlL2350.name) == "hll2350dw_us_eu_as")
        #expect(BrotherDrivers.productCode(try Self.fixture("brother-search-hll2350dw.html"), "Brother HL-L2350") == nil) // another model the search guessed
        #expect(BrotherDrivers.productCode("<html>Several products</html>", Self.hlL2350.name) == nil)
        // Brother's "(XL)" bundles are the model.
        #expect(BrotherDrivers.productCode(#"<h3 class="title"><a href="/g/b/producttop.aspx?c=us&lang=en&prod=mfcl2750dw_us_eu_as">MFC-L2750DW(XL)</a></h3>"#,
                                           "Brother MFC-L2750DW series") == "mfcl2750dw_us_eu_as")
    }

    @Test func Brothers_list_gives_a_printer_its_printer_driver_then_the_full_package() throws {
        // Windows' list read with the Mac's rules: the same markup, the same order.
        let list = BrotherDrivers.parseList(try Self.fixture("brother-hll2350dw-windows11.html"))
        #expect(list.contains { $0.section == "Utilities" && $0.download.title == "Wireless Setup Helper" })
        let ranked = BrotherDrivers.ranked(list, .printer)
        #expect(ranked.map(\.title) == ["Printer Driver", "XML Paper Specification Printer Driver", "Full Driver & Software Package"])
        #expect(ranked[0].version == "1.12.0.0")
        #expect(ranked[0].sizeText == "30.16 MB")
        #expect(ranked[0].link.path == "/g/b/downloadhowto.aspx")
        #expect(ranked[0].link.query?.contains("dlid=dlf106853_000") == true)
        // macOS's list: the full package only, never its firmware tool.
        let mac = BrotherDrivers.ranked(BrotherDrivers.parseList(Self.brotherMac), .printer)
        #expect(mac.map(\.title) == ["Full Software Package"])
        #expect(mac[0].sizeText == "246.56 MB")
    }

    @Test func A_Brother_scanner_with_only_the_full_package_gets_that() throws {
        let ranked = BrotherDrivers.ranked(BrotherDrivers.parseList(try Self.fixture("brother-ads1200-windows11.html")), .scanner)
        #expect(ranked.map(\.title) == ["Full Driver & Software Package"])
        #expect(!BrotherDrivers.ranked(BrotherDrivers.parseList(try Self.fixture("brother-hll2350dw-windows11.html")), .scanner).contains { $0.title.contains("Printer") })
        // A scanner's ICA driver before its others.
        let ica = "<h3 class=\"h3\">Drivers</h3><table>" + Self.brotherRow("Scanner Driver (TWAIN)", dlid: "a", type3: 1, version: "1", size: "1")
            + Self.brotherRow("ICA Scanner Driver", dlid: "b", type3: 2, version: "1", size: "1") + "</table>"
        #expect(BrotherDrivers.ranked(BrotherDrivers.parseList(ica), .scanner).map(\.title) == ["ICA Scanner Driver", "Scanner Driver (TWAIN)"])
    }

    @Test func Brothers_lookup_reads_four_pages_and_offers_the_file_on_download_brother_com() async throws {
        let web = FakeWeb()
        web.text(Self.brotherSearch, try Self.fixture("brother-search-hll2350dw.html"))
        web.text(Self.brotherMacList, Self.brotherMac)
        web.text(Self.brotherHowto, try Self.brotherHowtoPage())
        let offer = try #require(await BrotherDrivers(MakerWeb(web)).find(Self.query(Self.hlL2350)).offer)
        #expect(offer.download.absoluteString == "https://download.brother.com/welcome/dlf107315/Brother_PrinterDrivers_MonochromeLaser_1_0_0.dmg")
        #expect(offer.title == "Full Software Package")
        #expect(offer.version == "1.0.0")
        #expect(offer.page.absoluteString == "https://support.brother.com/g/b/downloadtop.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as")
        #expect(web.asked.allSatisfy { $0.host == "support.brother.com" })
    }

    @Test(arguments: [
        "https://downloads.example/driver.dmg", "http://download.brother.com/welcome/dlf107315/x.dmg", "https://download.brother.com.example/x.dmg",
        "https://download.brother.com/welcome/dlf106853/Y17B_C1-hostm-1120.EXE", // Windows' program: no Mac file
    ])
    func A_Brother_file_off_its_download_host_is_no_offer(_ href: String) async throws {
        let web = FakeWeb()
        web.text(Self.brotherSearch, try Self.fixture("brother-search-hll2350dw.html"))
        web.text(Self.brotherMacList, Self.brotherMac)
        web.text(Self.brotherHowto, try Self.brotherHowtoPage(href))
        let found = await BrotherDrivers(MakerWeb(web)).find(Self.query(Self.hlL2350))
        #expect(found.offer == nil)
        #expect(found.why == .notFound)
    }

    // MARK: HP

    static let m234 = device("HP LaserJet MFP M234dw", "HP")
    static let hpSearch = "https://support.hp.com/typeahead?q=laserjet%20mfp%20m234dw&resultLimit=10&store=tmsstore&languageCode=en&filters=class:(pm_series_value%5E1.1%20OR%20pm_name_value%20OR%20pm_number_value)"
    static let hpSystems = "https://support.hp.com/wcc-services/swd-v2/osVersionData?cc=us&lc=en&productOid=30836604"
    static let hpList = "https://support.hp.com/wcc-services/swd-v2/driverDetails?authState=anonymous&template=SWD_PDP_Drivers"

    static func hpEntry(_ section: String, _ title: String, _ url: String, version: String = "N/A", description: String = "") -> String {
        #"{"accordionNameEn":"\#(section)","softwareDriversList":[{"latestVersionDriver":{"title":"\#(title)","version":"\#(version)","fileUrl":"\#(url)","fileSize":"","detailInformation":{"description":"\#(description)"}}}]}"#
    }

    /// The M234dw's macOS 26 list as HP gave it (2026-11-27): only HP's app, in the Mac App Store.
    static let hpMac = #"{"data":{"softwareTypes":["#
        + hpEntry("Installation Software and Driver-Includes print, scan, latest features, and solutions", "Install HP app to complete setup and support",
                  "https://apps.apple.com/us/app/hp-print-and-support/id1474276998?mt=12", description: "<p><b>HP app will help you:</b></p><ul><li>Install printer software and drivers</li></ul>")
        + "]}}"

    @Test func HPs_search_gives_the_models_product_not_its_trade_or_e_variant() throws {
        let search = try Self.fixture("hp-search-m234dw.json")
        #expect(HpDrivers.productId(search, Self.m234.name) == 30836604)
        #expect(HpDrivers.productId(search, "HP LaserJet MFP M234dw Printer") == 30836604)
        #expect(HpDrivers.productId(search, "HP LaserJet MFP M234dwe") == 36120178)
        #expect(HpDrivers.productId(search, "HP OfficeJet Pro 9015") == nil)
        // Asked without HP's printFields, as the app asks, the search names its products "productname".
        #expect(HpDrivers.productId(search.replacingOccurrences(of: "\"name\"", with: "\"productname\""), Self.m234.name) == 30836604)
    }

    @Test(arguments: [26, 15, 27])
    func HPs_systems_give_this_windows_ids(_ macOS: Int) throws {
        // HP lists only its newest macOS ("macOS 26"): an older or newer macOS reads its list.
        let ids = try #require(HpDrivers.osIds(try Self.fixture("hp-systems-m234dw.json"), HpDrivers.osName(macOS)))
        #expect(ids.platform == "275027708611380099388405694207665")
        #expect(ids.version == "11212138891547151401399116411012148103724130")
        #expect(ids.name == "macOS 26")
    }

    @Test func HPs_list_gives_a_printer_the_offline_installer_and_a_scanner_the_scan_driver() throws {
        // Windows' list has nothing for a Mac (its programs, its Microsoft Store links); macOS's has HP's app.
        let windows = HpDrivers.parseList(try Self.fixture("hp-drivers-m234dw-windows11.json"))
        #expect(!windows.isEmpty)
        #expect(HpDrivers.ranked(windows, .printer).isEmpty)
        #expect(HpDrivers.ranked(windows, .scanner).isEmpty)
        let mac = HpDrivers.ranked(HpDrivers.parseList(Self.hpMac), .printer)
        #expect(mac.map(\.link.host) == ["apps.apple.com"])
        // A driver file on HP's servers comes before the app; firmware never.
        let both = #"{"data":{"softwareTypes":["# + Self.hpEntry("Firmware", "Firmware Update", "https://ftp.hp.com/pub/fw.dmg") + ","
            + Self.hpEntry("Driver-Product Installation Software", "HP Easy Start", "https://ftp.hp.com/pub/softlib/HP_Easy_Start.app.zip", version: "2.15") + ","
            + Self.hpEntry("Installation Software and Driver-Includes print, scan", "Install HP app", "https://apps.apple.com/us/app/hp-smart/id1474276998") + "]}}"
        let ranked = HpDrivers.ranked(HpDrivers.parseList(both), .printer)
        #expect(ranked.map(\.title) == ["HP Easy Start", "Install HP app"])
        #expect(ranked[0].version == "2.15")
    }

    @Test func HPs_lookup_asks_its_search_systems_and_list_and_offers_the_file_on_ftp_hp_com() async throws {
        let web = FakeWeb()
        web.text(Self.hpSearch, try Self.fixture("hp-search-m234dw.json"))
        web.text(Self.hpSystems, try Self.fixture("hp-systems-m234dw.json"))
        web.post(Self.hpList, Self.hpMac)
        let found = await HpDrivers(MakerWeb(web)).find(Self.query(Self.m234))
        let offer = try #require(found.offer)
        #expect(offer.download.absoluteString == "https://apps.apple.com/us/app/hp-print-and-support/id1474276998?mt=12")
        #expect(offer.title == "Install HP app to complete setup and support")
        #expect(offer.page.absoluteString == "https://support.hp.com/us-en/drivers/30836604")
        // The post names the product and this macOS, nothing else.
        #expect(web.posted.count == 1)
        let sent = try #require(web.posted.first)
        #expect(sent.contains(#""productNameOid":30836604"#))
        #expect(sent.contains(#""osTMSId":"11212138891547151401399116411012148103724130""#))
        #expect(sent.contains(#""osPlatformId":"275027708611380099388405694207665""#))
        #expect(sent.contains(#""osName":"macOS 26""#))
    }

    @Test func HPs_list_redirecting_is_not_posted_again() async throws {
        let web = FakeWeb()
        web.text(Self.hpSearch, try Self.fixture("hp-search-m234dw.json"))
        web.text(Self.hpSystems, try Self.fixture("hp-systems-m234dw.json"))
        web.redirect(Self.hpList, to: "https://support.hp.com/elsewhere")
        let found = await HpDrivers(MakerWeb(web)).find(Self.query(Self.m234))
        #expect(found.why == .unreachable)
        #expect(found.problem == .unreachable)
        #expect(!web.asked.contains { $0.path == "/elsewhere" })
    }

    @Test(arguments: ["https://ftp.hp.com.example/pub/x.dmg", "http://ftp.hp.com/pub/softlib/x.dmg", "https://hp.example/driver.dmg",
                      "https://apps.apple.com.example/us/app/x/id1", "https://apps.apple.com/us/story/id1"])
    func An_HP_file_off_its_hosts_is_no_offer(_ url: String) {
        let json = #"{"data":{"softwareTypes":["# + Self.hpEntry("Driver-Product Installation Software", "HP Easy Start", url) + "]}}"
        let ranked = HpDrivers.ranked(HpDrivers.parseList(json), .printer)
        let offered = ranked.first.map { DriverPages.offer($0, $0.link, page: URL(string: "https://support.hp.com/")!, .hp).offer }
        #expect(offered == nil || offered! == nil)
    }

    // MARK: Canon

    static let lide400 = device("Canon CanoScan LiDE 400", "Canon", .scanner)
    static let canonSuggest = "https://asia.canon/en/support/suggest?query=canoscan%20lide%20400"
    static let canonMacList = "https://asia.canon/en/support/CanoScan%20LiDE%20400/get-search-result-content?fileType=DR&os=macOS%2026&q="

    @Test func Canons_suggestions_give_the_models_name_there() throws {
        #expect(CanonDrivers.modelName(try Self.fixture("canon-suggest-lide400.json"), Self.lide400.name) == "CanoScan LiDE 400")
        // A page several models share, by any of their names; the line left out of the device's name or not.
        let lbp = try Self.fixture("canon-suggest-lbp6030w.json")
        #expect(CanonDrivers.modelName(lbp, "Canon LBP6030w") == "imageCLASS LBP6030/ LBP6030B/ LBP6030w")
        #expect(CanonDrivers.modelName(lbp, "Canon imageCLASS LBP6030w") == "imageCLASS LBP6030/ LBP6030B/ LBP6030w")
        #expect(CanonDrivers.modelName(lbp, "Canon LBP6030dn") == nil)
        #expect(CanonDrivers.modelName(#"{"success":true,"data":[]}"#, Self.lide400.name) == nil)
        #expect(CanonDrivers.pathOf("imageCLASS LBP6030/ LBP6030B/ LBP6030w") == "imageCLASS%20LBP6030__%20LBP6030B__%20LBP6030w")
    }

    /// Windows' list with its titles as a Mac download's would say: the same cards, for the Mac.
    static func canonMac() throws -> String { try fixture("canon-lide400-windows11.html").replacingOccurrences(of: "(Windows)", with: "(Mac)") }

    @Test func Canons_list_gives_a_scanner_its_driver_and_a_printer_its_MP_drivers() throws {
        let scanner = CanonDrivers.ranked(CanonDrivers.parseList(try Self.canonMac()), .scanner)
        #expect(scanner.map(\.title) == ["CanoScan LiDE 400 Scanner Driver Ver.1.01 (Mac)", "CanoScan LiDE 400 Full Driver & Software Package (Mac)"])
        #expect(scanner[0].sizeText == "58.46 MB")
        // Windows' downloads are never a Mac's.
        #expect(CanonDrivers.ranked(CanonDrivers.parseList(try Self.fixture("canon-lide400-windows11.html")), .scanner).isEmpty)
        let printer = CanonDrivers.ranked(CanonDrivers.parseList(try Self.fixture("canon-g3010-windows11.html").replacingOccurrences(of: "(Windows)", with: "(Mac)")), .printer)
        #expect(printer.first?.title == "G3010 MP Drivers Ver.1.04 (Mac)")
        #expect(!printer.contains { $0.title.contains("security patch") })
        #expect(printer.first?.link.absoluteString == "https://asia.canon/en/support/0100911616?model=PIXMA+G3010")
    }

    @Test func Canons_lookup_reads_the_list_and_the_files_page_and_offers_canons_download_link() async throws {
        let web = FakeWeb()
        web.text(Self.canonSuggest, try Self.fixture("canon-suggest-lide400.json"))
        web.text(Self.canonMacList, try Self.canonMac())
        web.text("https://asia.canon/en/support/0100963702?model=CanoScan+LiDE+400", try Self.fixture("canon-lide400-scanner-driver.html"))
        let offer = try #require(await CanonDrivers(MakerWeb(web)).find(Self.query(Self.lide400)).offer)
        #expect(offer.download.absoluteString == "https://pdisp01.c-wss.com/gdl/WWUFORedirectTarget.do?id=MDEwMDAwOTYzNzAy&cmp=ACB&lang=EN")
        #expect(offer.version == "1.01")
        #expect(offer.page.absoluteString == "https://asia.canon/en/support/CanoScan%20LiDE%20400/model")
        // Canon's link sends the file on from its other server, which is Canon's too.
        #expect(MakerWeb.isAllowed(URL(string: "https://gdlp01.c-wss.com/gds/7/0100009637/02/x.dmg")!, MakerSource.canon.downloadHosts))
    }

    @Test func A_model_canon_lists_no_macos_driver_for_has_its_page() async throws {
        // What asia.canon answered for the LiDE 400 and the G3010 on macOS 26 (2026-11-27).
        let web = FakeWeb()
        web.text(Self.canonSuggest, try Self.fixture("canon-suggest-lide400.json"))
        web.text(Self.canonMacList, #"<div class="alertsCard__text"><p>There is no driver for the OS Version you selected. The driver may be included in your OS or you may not need a driver.</p></div>"#)
        let found = await CanonDrivers(MakerWeb(web)).find(Self.query(Self.lide400))
        #expect(found.why == .notFound)
        #expect(found.page?.absoluteString == "https://asia.canon/en/support/CanoScan%20LiDE%20400/model")
    }

    @Test func A_canon_page_whose_link_isnt_canons_has_no_file() throws {
        let hostile = try Self.fixture("canon-lide400-scanner-driver.html").replacingOccurrences(of: "https://pdisp01.c-wss.com/gdl/", with: "https://pdisp01.c-wss.com.example/gdl/")
        #expect(CanonDrivers.parseDetail(hostile, MakerDownload(title: "x", description: "", version: nil, sizeText: nil, link: URL(string: "https://asia.canon/")!)) == nil)
    }

    // MARK: PFU

    static let fi8170 = device("fi-8170", "Fujitsu", .scanner)

    static func pfuEntry(_ title: String, _ file: String, more: String, os: String = "mac-2600") -> String {
        #"{"title":"\#(title)","fileName":"x","fileSize":"23.4 MB","description":"macOS-compatible scanner driver.","moreHref":"\#(more)","action":{"onclick":"wdlDownloadCheck('mac', 'mac', '2.4.1', 'SetupProgram', 'Free', '\#(file)', '');"}}"#
    }

    /// The fi-8170's page as PFU gave it (2026-11-27), its data cut to the macOS 26 scanner driver and its manual.
    static let pfuMac = #"<html><script type="application/json" data-support-app-json>{"slug":"fi-8170","sections":{"software-scanner-driver":{"downloadsByOs":{"mac-2600":["#
        + pfuEntry("Image Scanner Driver for macOS 2.4.1", "https://origin.pfultd.com/downloads/IMAGE/macos/241/pfufs-macOS_2.4.1.dmg", more: "/global/scanners/fisp/dl/mac/mac-driver-241.html")
        + #"]}},"manuals":{"downloadsByOs":{"mac-2600":[{"title":"fi Series Image Scanner Driver for macOS User's Guide"}]}}}}</script></html>"#

    @Test func PFUs_list_of_models_has_the_models_page() throws {
        let models = try Self.fixture("pfu-models.html")
        #expect(PfuDrivers.modelPage(models, "Fujitsu fi-8170")?.absoluteString == "https://www.pfu.ricoh.com/global/scanners/fisp/dl/fi-8170.html")
        #expect(PfuDrivers.modelPage(models, "Fujitsu ScanSnap iX1600") == nil) // ScanSnap: not there
        #expect(PfuDrivers.modelPage(models, "fi-81") == nil)
    }

    @Test func PFUs_page_gives_PaperStream_IP_for_this_processor() throws {
        // Windows' page read in place: its systems' lists, and nothing for a Mac.
        let windows = PfuDrivers.parsePage(try Self.fixture("pfu-fi8170.html"), "win-11")
        #expect(windows.contains { $0.title == "PaperStream IP (TWAIN x64) 3.40.2" && $0.link.host == "origin.pfultd.com" })
        #expect(PfuDrivers.ranked(windows).isEmpty)
        #expect(PfuDrivers.parsePage(try Self.fixture("pfu-fi8170.html"), "mac-2600").isEmpty)
        // macOS's: its Image Scanner Driver, on Apple silicon and Intel.
        let mac = PfuDrivers.ranked(PfuDrivers.parsePage(Self.pfuMac, "mac-2600"))
        for arch in [MacArch.appleSilicon, .intel] {
            let pick = try #require(DriverPages.forThisMac(mac, arch).pick)
            let offer = try #require(DriverPages.offer(pick, pick.link, page: URL(string: "https://www.pfu.ricoh.com/")!, .pfu).offer)
            #expect(offer.title == "Image Scanner Driver for macOS 2.4.1")
            #expect(offer.version == "2.4.1")
            #expect(offer.download.host == "origin.pfultd.com")
        }
    }

    @Test func PFUs_lookup_reads_the_list_of_models_then_the_models_page() async throws {
        let web = FakeWeb()
        web.text("https://www.pfu.ricoh.com/global/scanners/fisp/dl/", try Self.fixture("pfu-models.html"))
        web.text("https://www.pfu.ricoh.com/global/scanners/fisp/dl/fi-8170.html", Self.pfuMac)
        let offer = try #require(await PfuDrivers(MakerWeb(web)).find(Self.query(Self.fi8170)).offer)
        #expect(offer.download.absoluteString == "https://origin.pfultd.com/downloads/IMAGE/macos/241/pfufs-macOS_2.4.1.dmg")
        #expect(offer.version == "2.4.1")
        // PFU's licence, on the download's own page: what opens.
        #expect(offer.licence?.absoluteString == "https://www.pfu.ricoh.com/global/scanners/fisp/dl/mac/mac-driver-241.html")
        let flow = DriverFlow(catalog: MakerCatalogs([]), arch: .appleSilicon, macOS: 26)
        #expect(flow.linkFor(offer, Self.fi8170) == offer.licence)
        // A printer isn't PFU's: nothing is asked.
        let none = await PfuDrivers(MakerWeb(web)).find(Self.query(Self.device("fi-8170", "Fujitsu")))
        #expect(none.why == .notFound)
    }

    // MARK: Processors, systems, licences

    @Test(arguments: [(MacArch.appleSilicon, true, NoOffer.noArm64), (.intel, true, .notFound), (.appleSilicon, false, .notFound)])
    func No_ARM64_driver_is_said_only_on_ARM64(_ arch: MacArch, _ listed: Bool, _ why: NoOffer) {
        #expect(DriverPages.whyNone(listed, arch) == why)
    }

    @Test(arguments: [
        (15, "10083", "macOS 15", "macOS 15", "mac-1500", "macOS 15.x (Sequoia)"),
        (26, "10088", "macOS 26", "macOS 26", "mac-2600", "macOS 26.x (Tahoe)"),
        (27, "10094", "macOS 27", "macOS 27", "mac-2700", "macOS 27.x (Golden Gate)"),
        (28, "10094", "macOS 28", "macOS 28", "mac-2800", "macOS 27.x (Golden Gate)"),
    ])
    func ARM64_asks_each_site_for_the_list_its_ARM_builds_are_in(_ macOS: Int, _ brother: String, _ canon: String, _ hp: String, _ pfu: String, _ epson: String) {
        // Each site's name for this macOS, read from their OS menus on 2026-11-27.
        #expect(BrotherDrivers.osCode(macOS) == brother)
        #expect(CanonDrivers.osFilter(macOS) == canon)
        #expect(HpDrivers.osName(macOS) == hp)
        #expect(PfuDrivers.osId(macOS) == pfu)
        #expect(EpsonDrivers.osFilter(macOS) == epson)
    }

    @Test func Brothers_and_canons_offers_carry_the_licence_the_click_accepts() async throws {
        let web = FakeWeb()
        web.text(Self.brotherSearch, try Self.fixture("brother-search-hll2350dw.html"))
        web.text(Self.brotherMacList, Self.brotherMac)
        web.text(Self.brotherHowto, try Self.brotherHowtoPage())
        web.text(Self.canonSuggest, try Self.fixture("canon-suggest-lide400.json"))
        web.text(Self.canonMacList, try Self.canonMac())
        web.text("https://asia.canon/en/support/0100963702?model=CanoScan+LiDE+400", try Self.fixture("canon-lide400-scanner-driver.html"))
        let brother = try #require(await BrotherDrivers(MakerWeb(web)).find(Self.query(Self.hlL2350)).offer)
        let canon = try #require(await CanonDrivers(MakerWeb(web)).find(Self.query(Self.lide400)).offer)
        #expect(brother.licence?.absoluteString == "https://support.brother.com/g/b/downloadend.aspx?c=us&lang=en&prod=hll2350dw_us_eu_as&os=10088&dlid=dlf107315_000&flang=4&type3=583")
        #expect(canon.licence?.absoluteString == "https://asia.canon/en/support/0100963702?model=CanoScan+LiDE+400#disclaimer")
        // The maker's page with the licence opens, not the file; with no licence, the file.
        let flow = DriverFlow(catalog: MakerCatalogs([]), arch: .appleSilicon, macOS: 26)
        #expect(flow.linkFor(brother, Self.hlL2350) == brother.licence)
        #expect(flow.linkFor(canon, Self.lide400) == canon.licence)
        var bare = brother
        bare.licence = nil
        #expect(flow.linkFor(bare, Self.hlL2350) == brother.download)
        // A licence off the maker's site is never kept nor opened.
        let off = DriverPages.offer(MakerDownload(title: "x", description: "", version: nil, sizeText: nil, link: brother.download), brother.download,
                                    page: brother.page, .brother, licence: URL(string: "https://eula.example/agree")!)
        #expect(off.offer?.licence == nil)
        var hostile = brother
        hostile.licence = URL(string: "https://eula.example/agree")
        #expect(flow.linkFor(hostile, Self.hlL2350) == nil)
        #expect(!DriverText.licenceLinkNote(Self.hlL2350).isEmpty)
    }

    @Test(arguments: ["https://eula.example/agree.html", "//eula.example/global/scanners/fisp/dl/x.html", "/global/scanners/fisp/dl/../../../evil.html",
                      "/global/scanners/other/x.html", "javascript:void(0)"])
    func A_PFU_more_link_off_its_download_pages_is_no_licence(_ moreHref: String) throws {
        #expect(PfuDrivers.licencePage(moreHref) == nil)
        let page = Self.pfuMac.replacingOccurrences(of: "/global/scanners/fisp/dl/mac/mac-driver-241.html", with: moreHref)
        #expect(try #require(PfuDrivers.parsePage(page, "mac-2600").first).licence == nil)
    }

    // MARK: Hostile answers

    static let junk = [
        "", "not json", #"{"data":"#, "[1,2,3]", #"{"matches":"x"}"#, String(repeating: "[", count: 5000), "<html>" + String(repeating: "<", count: 100_000),
        #"{"data":{"softwareTypes":[{"softwareDriversList":[{"latestVersionDriver":{"title":"x","fileUrl":"javascript:alert(1)"}}]}]}}"#,
    ]

    @Test(arguments: junk)
    func Junk_answers_give_nothing(_ junk: String) {
        #expect(BrotherDrivers.productCode(junk, Self.hlL2350.name) == nil)
        #expect(BrotherDrivers.parseList(junk).isEmpty)
        #expect(BrotherDrivers.fileOf(junk) == nil)
        #expect(HpDrivers.productId(junk, Self.m234.name) == nil)
        #expect(HpDrivers.osIds(junk, "macOS 26") == nil)
        #expect(HpDrivers.ranked(HpDrivers.parseList(junk), .printer).isEmpty)
        #expect(CanonDrivers.modelName(junk, Self.lide400.name) == nil)
        #expect(CanonDrivers.parseList(junk).isEmpty)
        #expect(PfuDrivers.modelPage(junk, Self.fi8170.name) == nil)
        #expect(PfuDrivers.parsePage(junk, "mac-2600").isEmpty)
        #expect(EpsonDrivers.parsePage(junk).isEmpty)
        #expect(EpsonDrivers.supportPage(junk, "Epson Perfection V19", .scanner) == nil)
    }

    @Test func A_flood_of_entries_is_cut_short() {
        let row = "<h3 class=\"h3\">Drivers</h3>" + String(repeating:
            #"<tr><td><em><a href="/g/b/downloadend.aspx?c=us&lang=en&prod=p&os=10088&dlid=dlf1_000">Printer Driver</a></em></td></tr>"#, count: 5000)
        #expect(BrotherDrivers.parseList(row).count == 100) // a section's first 100 rows
        #expect(BrotherDrivers.parseList(String(repeating: row, count: 10)).count <= 200)
        let cards = String(repeating: #"<div class="softwareCard"><h3 class="softwareCard__content--title"><a href="/en/support/0100963702?model=X">Scanner Driver</a></h3>"#, count: 5000)
        #expect(CanonDrivers.parseList(cards).count == 200)
    }

    @Test func Model_words_drop_the_maker_and_the_kind() {
        #expect(BrotherDrivers.words("Brother HL-L2350DW series") == "hl-l2350dw")
        #expect(HpDrivers.words("HP LaserJet MFP M234dw Printer") == "laserjet mfp m234dw")
        #expect(CanonDrivers.words("Canon CanoScan LiDE 400") == "canoscan lide 400")
        #expect(PfuDrivers.words("FUJITSU fi-8170") == "fi-8170")
        #expect(HpDrivers.words("HP Printer") == "")
        #expect(DriverPages.modelWords(String(repeating: "a", count: 10_000)).count <= 200)
    }
}
