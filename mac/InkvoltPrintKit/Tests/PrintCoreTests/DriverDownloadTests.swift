import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// A made-up web for the makers' sites (the .NET tests' `FakeWeb`): answers by exact address, records what was asked and
/// posted. Anything it doesn't know is 404.
final class FakeWeb: HttpTransport {
    private let state = Mutex<(gets: [String: HttpResponse], posts: [String: HttpResponse], asked: [URL], posted: [String])>(([:], [:], [], []))

    func text(_ url: String, _ text: String) { state.withLock { $0.gets[url] = HttpResponse(status: 200, body: Array(text.utf8)) } }
    func post(_ url: String, _ text: String) { state.withLock { $0.posts[url] = HttpResponse(status: 200, body: Array(text.utf8)) } }

    func redirect(_ url: String, to: String) {
        let r = HttpResponse(status: 302, headers: ["Location": to])
        state.withLock {
            $0.gets[url] = r
            $0.posts[url] = r
        }
    }

    func answer(_ url: String, _ response: HttpResponse) { state.withLock { $0.gets[url] = response } }

    var asked: [URL] { state.withLock { $0.asked } }
    var posted: [String] { state.withLock { $0.posted } }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        state.withLock { s in
            s.asked.append(request.url)
            if let body = request.body { s.posted.append(String(decoding: body, as: UTF8.self)) }
            let answers = request.method == "POST" ? s.posts : s.gets
            return answers[request.url.absoluteString] ?? HttpResponse(status: 404)
        }
    }
}

/// "Get the driver" for Epson, and the flow every maker's goes through on the Mac (ported from DriverDownloadTests.cs):
/// Epson's search and support page read from the .NET tests' copies of the real ones (Fixtures/epson, read in place), its
/// macOS downloads written in the page's own markup as epson.com lists them (checked live 2026-11-27: the V19's macOS 26
/// list), the lookup through a made-up web, the links the browser is given, and the steps' words. The Windows tests of the
/// download, its signature and the installer stay with Windows: the Mac App Store app never downloads or runs one.
struct DriverDownloadTests {
    static func page() throws -> String { try Fixtures.text("epson/epson-v19-windows11.html") }
    static func search() throws -> String { try Fixtures.text("epson/epson-search-v19.json") }

    static let v19 = NeedsDriverPrinter(id: "usb-needs-driver:scanner-04b8-013c", name: "Epson Perfection V19", maker: "Epson", kind: .scanner, usbId: "04B8:013C")

    static func query(_ arch: MacArch = .appleSilicon, macOS: Int = 26) -> DriverQuery { .for(v19, arch: arch, macOS: macOS) }

    /// One download as epson.com's support page writes it.
    static func panel(_ title: String, file: String, section: String = "drivers", systems: String = "macOS 27.x (Golden Gate),&nbsp;macOS 26.x (Tahoe),&nbsp;macOS 15.x (Sequoia)",
                      description: String = "This file contains the driver.", host: String = "ftp.epson.com") -> String {
        """
        <div class="panel-heading"><div class="panel-title"><ul class="details"><li>
         \(file.hasSuffix(".dmg") ? "26.2" : "1.0")&nbsp;MB</li><li>\(file)</li></ul>
        <a class="btn detail-button" data-dl_name="\(file)" data-dl_title="\(title)" href="https://\(host)/drivers/\(file)">
         Download</a></div></div>
        <div id="panel-x" class="panel-collapse collapse" data-parent="#\(section)"><div class="panel-body">
        <p class="sub-header">Description :</p><p class="sub-body">\(description)</p>
        <p class="sub-header">Compatible systems :</p><p class="sub-body">\(systems)</p></div></div>
        """
    }

    /// The V19's macOS 26 list as epson.com gave it (2026-11-27): Epson Scan 2, its ICA driver, then utilities.
    static let macPage = panel("Scanner Driver and Epson Scan 2 Utility&nbsp;v6.7.84", file: "V19_EScan2_6784_AM.dmg")
        + panel("ICA Scanner Driver v5.8.23 for Image Capture&nbsp;", file: "ESICA_5.8.23.dmg",
                description: "This file contains the ICA Scanner Driver v5.8.23 for Apple's Image Capture utility.")
        + panel("Epson Software Updater&nbsp;v3.0.0", file: "ESU_300.dmg", section: "utilities")
        + panel("Drivers and Utilities Combo Package&nbsp;v1.0", file: "V19_Combo.dmg")

    static func choose(_ html: String, _ arch: MacArch = .appleSilicon) -> DriverLookup {
        EpsonDrivers.choose(EpsonDrivers.parsePage(html), query(arch), page: URL(string: "https://epson.com/Support/x")!)
    }

    // MARK: Epson's pages

    @Test func The_support_page_lists_its_downloads_in_order_with_their_sections() throws {
        let all = EpsonDrivers.parsePage(try Self.page())
        #expect(all.count == 9)
        #expect(all[0].section == "recommended")
        #expect(all[0].title == "Scanner Driver and EPSON Scan Utility v3.9.5.0")
        #expect(all[0].sizeText == "29.5 MB")
        #expect(all[0].description.contains("ARM"))
        #expect(all[0].systems.contains("Windows 10 64-bit"))
        #expect(all.allSatisfy { $0.href.host == "ftp.epson.com" })
    }

    @Test(arguments: [("Epson Perfection V19", "SPT_B11B231201"), ("EPSON Perfection V19 Scanner", "SPT_B11B231201"), ("Epson Perfection V19 II", "SPT_B11B267201")])
    func The_search_gives_the_models_own_page_never_a_variants(_ model: String, _ sku: String) throws {
        let page = try #require(EpsonDrivers.supportPage(try Self.search(), model, .scanner))
        #expect(page.path.hasSuffix("/s/" + sku))
    }

    @Test(arguments: ["Epson Perfection V39", "Epson"])
    func A_model_the_search_doesnt_have_has_no_page(_ model: String) throws {
        #expect(EpsonDrivers.supportPage(try Self.search(), model, .scanner) == nil)
    }

    @Test(arguments: [
        "", "not json", "[1,2,3]",
        #"{"products":[{"name":"Perfection V19 Scanner","productType":"SCANNER","supportProductId":"https://evil.example/s/SPT_X"}]}"#,
        #"{"products":[{"name":"Perfection V19 Scanner","productType":"SCANNER","supportProductId":"/Support/../../x/s/SPT_X?a=b"}]}"#,
        #"{"products":[{"name":"Perfection V19 Scanner","productType":"PRINTER","supportProductId":"/Support/Printers/x/s/SPT_X"}]}"#,
    ])
    func A_hostile_or_odd_search_answer_gives_no_page(_ json: String) {
        #expect(EpsonDrivers.supportPage(json, "Epson Perfection V19", .scanner) == nil)
    }

    @Test func On_ARM64_the_ARM_scanner_driver_is_offered_never_the_combo_package() throws {
        // On the Mac: the ICA driver (what ImageCaptureCore scans through) before Epson Scan 2, on Apple silicon and Intel.
        for arch in [MacArch.appleSilicon, .intel] {
            let offer = try #require(Self.choose(Self.macPage, arch).offer)
            #expect(offer.title == "ICA Scanner Driver for Image Capture")
            #expect(offer.version == "5.8.23")
            #expect(offer.download.absoluteString == "https://ftp.epson.com/drivers/ESICA_5.8.23.dmg")
            #expect(offer.sizeText == "26.2 MB")
        }
        let comboOnly = Self.panel("Drivers and Utilities Combo Package&nbsp;v1.0", file: "V19_Combo.dmg")
        #expect(Self.choose(comboOnly).why == .notFound)
    }

    @Test func On_x64_a_download_only_for_ARM_is_never_offered() {
        // An Intel Mac: a driver only for Apple silicon isn't one.
        let page = Self.panel("ICA Scanner Driver v6.0 for Apple silicon", file: "ica-as.dmg", description: "For Macs with Apple silicon (M1 and later).")
        #expect(Self.choose(page, .intel).offer == nil)
        #expect(Self.choose(page, .intel).why == .notFound)
        #expect(Self.choose(page, .appleSilicon).offer != nil)
    }

    @Test func On_x64_a_download_for_both_ARM_and_x64_is_offered() throws {
        let page = Self.panel("ICA Scanner Driver v6.0 (Universal)", file: "ica-u.dmg", description: "For Macs with Apple silicon or an Intel processor.")
        #expect(try #require(Self.choose(page, .intel).offer).download.lastPathComponent == "ica-u.dmg")
        #expect(try #require(Self.choose(page, .appleSilicon).offer).download.lastPathComponent == "ica-u.dmg")
    }

    @Test func On_ARM64_a_page_with_no_ARM_driver_says_so_and_x64_still_gets_one() throws {
        let page = Self.panel("ICA Scanner Driver v5.0", file: "ica-intel.dmg", description: "For Intel-based Macs only.")
        let arm = Self.choose(page, .appleSilicon)
        #expect(arm.offer == nil)
        #expect(arm.why == .noArm64)
        #expect(arm.page != nil)
        #expect(try #require(Self.choose(page, .intel).offer).download.lastPathComponent == "ica-intel.dmg")
    }

    @Test func A_page_with_no_driver_offers_nothing() throws {
        // Windows' page (its programs) has nothing for a Mac; nor has a page of utilities, or one for other systems.
        #expect(Self.choose(try Self.page()).why == .notFound)
        #expect(Self.choose(Self.panel("Epson Software Updater v3.0.0", file: "ESU.dmg", section: "utilities")).why == .notFound)
        #expect(Self.choose(Self.panel("ICA Scanner Driver v5.8.23", file: "ica.dmg", systems: "macOS 12.x (Monterey)")).why == .notFound)
    }

    @Test(arguments: ["ftp.epson.com.example", "evil.example", "download.epson.com:8443"])
    func A_page_pointing_off_Epsons_hosts_is_never_offered(_ host: String) {
        #expect(Self.choose(Self.panel("ICA Scanner Driver v5.8.23", file: "ica.dmg", host: host)).offer == nil)
    }

    static let searchUrl = "https://epson.com/search/autocomplete/SearchBox?term=perfection%20v19"
    static let macPageUrl = "https://epson.com/Support/Scanners/Perfection-Series/Epson-Perfection-V19-Photo/s/SPT_B11B231201?review-filter=macOS+26.x+%28Tahoe%29"

    @Test func The_lookup_reads_the_search_then_the_page_filtered_for_this_windows() async throws {
        let web = FakeWeb()
        web.text(Self.searchUrl, try Self.search())
        web.text(Self.macPageUrl, Self.macPage)
        let found = await EpsonDrivers(MakerWeb(web)).find(Self.query())
        #expect(try #require(found.offer).download.lastPathComponent == "ESICA_5.8.23.dmg")
        #expect(found.offer?.page.absoluteString == "https://epson.com/Support/Scanners/Perfection-Series/Epson-Perfection-V19-Photo/s/SPT_B11B231201")
        #expect(web.asked.map(\.absoluteString) == [Self.searchUrl, Self.macPageUrl])
    }

    @Test(arguments: [(15, "macOS 15.x (Sequoia)"), (26, "macOS 26.x (Tahoe)"), (27, "macOS 27.x (Golden Gate)"), (28, "macOS 27.x (Golden Gate)")])
    func The_page_is_filtered_for_this_macos(_ macOS: Int, _ filter: String) {
        #expect(EpsonDrivers.osFilter(macOS) == filter)
    }

    @Test func A_search_that_redirects_off_Epsons_site_is_not_followed() async {
        let web = FakeWeb()
        web.redirect(Self.searchUrl, to: "https://evil.example/search")
        let found = await EpsonDrivers(MakerWeb(web)).find(Self.query())
        #expect(found.why == .unreachable)
        #expect(found.problem == .notMakersSite)
        #expect(!web.asked.contains { $0.host == "evil.example" })
    }

    // MARK: Reading a maker's page (MakerWeb, Windows' BoundedHttp)

    static let hosts = MakerSource.epson.pageHosts

    @Test func A_redirect_off_Epsons_hosts_is_never_followed() async {
        let web = FakeWeb()
        web.redirect("https://epson.com/a", to: "http://epson.com/b")
        await #expect(throws: FetchError(.notMakersSite)) { try await MakerWeb(web).text(URL(string: "https://epson.com/a")!, hosts: Self.hosts) }
        #expect(web.asked.count == 1)
    }

    @Test func A_redirect_to_another_of_Epsons_hosts_is_followed() async throws {
        let web = FakeWeb()
        web.redirect("https://epson.com/a", to: "https://www.epson.com/b")
        web.text("https://www.epson.com/b", "page")
        #expect(try await MakerWeb(web).text(URL(string: "https://epson.com/a")!, hosts: Self.hosts) == "page")
        // A relative redirect stays on the host it came from.
        web.redirect("https://epson.com/c", to: "/b2")
        web.text("https://epson.com/b2", "page 2")
        #expect(try await MakerWeb(web).text(URL(string: "https://epson.com/c")!, hosts: Self.hosts) == "page 2")
    }

    @Test func Redirects_that_go_round_stop() async {
        let web = FakeWeb()
        web.redirect("https://epson.com/a", to: "https://epson.com/b")
        web.redirect("https://epson.com/b", to: "https://epson.com/a")
        await #expect(throws: FetchError(.tooManyRedirects)) { try await MakerWeb(web).text(URL(string: "https://epson.com/a")!, hosts: Self.hosts) }
        #expect(web.asked.count == MakerWeb.maxRedirects + 1)
    }

    @Test func A_file_said_to_be_huge_is_refused_before_a_byte_is_read() async {
        let web = FakeWeb()
        web.answer("https://epson.com/a", HttpResponse(status: 200, body: [UInt8](repeating: 65, count: 2000)))
        await #expect(throws: FetchError(.tooBig)) { try await MakerWeb(web).text(URL(string: "https://epson.com/a")!, hosts: Self.hosts, maxBytes: 1000) }
    }

    @Test func A_download_that_hangs_times_out() async {
        struct Hangs: HttpTransport {
            func send(_ request: HttpRequest) async throws -> HttpResponse {
                try await Task.sleep(for: request.timeout)
                throw DeviceNetworkError.timedOut
            }
        }
        await #expect(throws: FetchError(.timedOut)) {
            try await MakerWeb(Hangs()).text(URL(string: "https://epson.com/a")!, hosts: Self.hosts, limit: .milliseconds(50))
        }
    }

    @Test(arguments: ["http://epson.com/a", "https://user@epson.com/a", "https://epson.com:8443/a", "https://epson.com.example/a", "ftp://epson.com/a"])
    func Only_https_on_the_makers_own_hosts_is_asked(_ url: String) async {
        let web = FakeWeb()
        await #expect(throws: FetchError(.notMakersSite)) { try await MakerWeb(web).text(URL(string: url)!, hosts: Self.hosts) }
        #expect(web.asked.isEmpty)
    }

    // MARK: The flow: the maker's link in the browser, then watching for the device

    static let flow = DriverFlow(catalog: MakerCatalogs([EpsonDrivers(MakerWeb(FakeWeb()))]), arch: .appleSilicon, macOS: 26)

    @Test func Only_a_maker_with_a_catalog_and_a_real_device_is_looked_up() async {
        #expect(Self.flow.looksUp(Self.v19))
        var madeUp = Self.v19
        madeUp.isMadeUp = true
        #expect(!Self.flow.looksUp(madeUp))
        var other = Self.v19
        other.maker = "Plustek"
        #expect(!Self.flow.looksUp(other))
        #expect(await Self.flow.find(other).why == .makerNotLookedUp)
        other.maker = nil
        #expect(!Self.flow.looksUp(other))
    }

    @Test func A_packaged_copy_finds_the_download_and_gives_epsons_own_link_but_never_downloads_or_runs_it() async throws {
        let web = FakeWeb()
        web.text(Self.searchUrl, try Self.search())
        web.text(Self.macPageUrl, Self.macPage)
        let flow = DriverFlow(catalog: MakerCatalogs.all(MakerWeb(web)), arch: .appleSilicon, macOS: 26)
        let offer = try #require(await flow.find(Self.v19).offer)
        #expect(flow.linkFor(offer, Self.v19) == offer.download)
        // Only the search and the page were asked: the file itself never.
        #expect(!web.asked.contains { $0.host == "ftp.epson.com" })
        #expect(DriverText.offerFacts(offer) == "Driver: ICA Scanner Driver for Image Capture\nVersion: 5.8.23\nSize: 26.2 MB\nFrom: ftp.epson.com")
    }

    @Test func A_link_off_the_makers_hosts_is_never_opened() throws {
        let offer = DriverOffer(title: "x", version: nil, sizeText: nil, download: URL(string: "https://evil.example/x.dmg")!, page: URL(string: "https://epson.com/")!)
        #expect(Self.flow.linkFor(offer, Self.v19) == nil)
        var other = Self.v19
        other.maker = "Plustek"
        var epsons = offer
        epsons.download = URL(string: "https://ftp.epson.com/drivers/x.dmg")!
        #expect(Self.flow.linkFor(epsons, other) == nil)
        #expect(Self.flow.linkFor(epsons, Self.v19) == epsons.download)
    }

    @Test func Look_again_asks_then_has_windows_look_as_the_user_never_elevated() async {
        // The Mac has no rescan to ask for: IOKit and ImageCaptureCore list devices as they come. A read that fails is "not yet".
        struct Fails: Error {}
        #expect(await DriverFlow.isThereNow { true })
        #expect(!(await DriverFlow.isThereNow { false }))
        #expect(!(await DriverFlow.isThereNow { throw Fails() }))
    }

    @Test func A_Store_copys_note_says_it_gives_the_makers_link_never_that_it_installs() {
        let note = DriverText.note(Self.v19)
        #expect(note.contains("download link"))
        #expect(note.contains("this Mac"))
        #expect(note.contains("doesn't download or install"))
        #expect(DriverText.openLinkButton(Self.v19) == "Download it from Epson")
        #expect(DriverText.openLinkNote(Self.v19).contains("watches for the scanner"))
    }

    @Test func A_plugged_in_device_isnt_told_to_plug_in_and_the_steps_are_numbered_in_order() {
        let present = DriverSteps.for(Self.v19, present: true, getDriver: true)
        #expect(present.map(\.number) == [1, 2])
        #expect(!present.contains { $0.text == NeedsDriverText.stepPlugIn(Self.v19) })
        let absent = DriverSteps.for(Self.v19, present: false, getDriver: true)
        #expect(absent.map(\.number) == [1, 2, 3])
        #expect(absent[1].text == "Plug the scanner in.")
    }

    @Test func The_makers_page_is_the_main_button_only_where_get_the_driver_isnt() {
        #expect(DriverSteps.for(Self.v19, present: true, getDriver: true)[0].button == .plain)
        #expect(DriverSteps.for(Self.v19, present: true, getDriver: false)[0].button == .main)
        #expect(DriverSteps.for(Self.v19, present: true, getDriver: true).dropFirst().allSatisfy { $0.button == StepButton.none })
    }

    @Test func The_install_step_says_what_this_copy_does() {
        let link = DriverSteps.for(Self.v19, present: true, getDriver: true).last!.text
        #expect(link == "Run Epson's installer. Inkvolt Print watches for the scanner and says when it's ready. If it doesn't, unplug the scanner and plug it back in, or press Look again.")
        let plain = DriverSteps.for(Self.v19, present: true, getDriver: false).last!.text
        #expect(plain == NeedsDriverText.stepInstall(Self.v19))
    }

    @Test func Why_nothing_was_offered_is_said_in_words() {
        let none = DriverLookup.none(.notFound)
        #expect(DriverText.unavailable(Self.v19, none) == "Epson's website has no driver for the Epson Perfection V19 for this version of macOS. Epson's page below may say more.")
        #expect(DriverText.unavailable(Self.v19, .none(.noArm64))?.contains("Apple silicon") == true)
        #expect(DriverText.unavailable(Self.v19, .none(.unreachable))?.contains("didn't answer") == true)
        #expect(DriverText.unavailable(Self.v19, .none(.makerNotLookedUp)) == nil)
        #expect(DriverText.englishNoOffer(Self.v19, .none(.unreachable, problem: .timedOut)) == "Epson's site didn't answer (timedOut)")
    }
}
