import Foundation

/// PFU's scanner drivers (fi and SP series, sold as Fujitsu's and now Ricoh's), from www.pfu.ricoh.com's global download
/// pages, as the Windows app's `PfuDrivers`: the list of models (`/global/scanners/fisp/dl/`) links each model's page, which
/// carries its downloads as JSON (each section's downloads for each system: "mac-2600" is macOS 26, with the file on
/// origin.pfultd.com). The Mac's driver is PFU's Image Scanner Driver for macOS (an ImageCaptureCore driver, what Inkvolt
/// Print scans through). ScanSnap models have no page there (their software comes through ScanSnap's own site): none is
/// found. Each download is accepted under PFU's licence, named on the download's own page: opened instead of the file.
public struct PfuDrivers: DriverCatalog {
    static let source = MakerSource.pfu
    static let site = "https://www.pfu.ricoh.com/global/scanners/fisp/dl/"
    let web: MakerWeb

    public init(_ web: MakerWeb) { self.web = web }

    public func looksUp(_ maker: String?) -> Bool { Self.source.is(maker) }

    public static func words(_ name: String) -> String { DriverPages.modelWords(name, "pfu", "fujitsu", "ricoh", "image", "imaging") }

    /// The page's system for this macOS: "mac-2600" for macOS 26, "mac-1500" for macOS 15.
    public static func osId(_ macOS: Int) -> String { "mac-\(macOS)00" }

    public func find(_ query: DriverQuery) async -> DriverLookup {
        let model = Self.words(query.model)
        guard !model.isEmpty, query.kind == .scanner else { return .none(.notFound) }
        do {
            let index = try await web.text(URL(string: Self.site)!, hosts: Self.source.pageHosts)
            guard let page = Self.modelPage(index, query.model) else { return .none(.notFound) }
            let html = try await web.text(page, hosts: Self.source.pageHosts)
            let (pick, why) = DriverPages.forThisMac(Self.ranked(Self.parsePage(html, Self.osId(query.macOS))), query.arch)
            guard let pick else { return .none(why, page: page) }
            return DriverPages.offer(pick, pick.link, page: page, Self.source, licence: pick.licence)
        } catch let error as FetchError {
            return .none(.unreachable, problem: error.problem)
        } catch {
            return .none(.unreachable, problem: .unreachable)
        }
    }

    private static let card = try! NSRegularExpression(
        pattern: #"<a href="/global/scanners/fisp/dl/([a-z0-9\-]{2,40})\.html" class="product-card" data-product-id="([a-z0-9\-]{2,40})""#)

    /// The model's page in the list of models (its product id the model's own words: "fi-8170", "sp-1130n"); nil when none is.
    public static func modelPage(_ html: String, _ model: String) -> URL? {
        let want = words(model).replacingOccurrences(of: " ", with: "-")
        guard !want.isEmpty else { return nil }
        for m in DriverPages.all(card, html, max: 1000) where m[1] == m[2] && m[1] == want { return URL(string: site + want + ".html") }
        return nil
    }

    private static let data = try! NSRegularExpression(pattern: #"<script type="application/json" data-support-app-json>(.{1,4000000}?)</script>"#, options: .dotMatchesLineSeparators)
    private static let fileUrl = try! NSRegularExpression(pattern: #"https://origin\.pfultd\.com/[A-Za-z0-9/_.\-]{1,300}"#)
    private static let versionRx = try! NSRegularExpression(pattern: #"(\d{1,3}(?:\.\d{1,4}){1,3})\s*(?:\(|$)"#)

    /// The scanner-driver section's downloads for this system (`os`), in PFU's order: at most 200.
    public static func parsePage(_ html: String, _ os: String) -> [MakerDownload] {
        guard let m = DriverPages.first(data, html), let doc = Json.parse(m[1]),
              let downloads = doc["sections"]?["software-scanner-driver"]?["downloadsByOs"]?[os]?.arrayValue else { return [] }
        var list: [MakerDownload] = []
        for d in downloads.prefix(200) {
            guard let title = HpDrivers.text(d, "title"), let onclick = HpDrivers.text(d["action"], "onclick", max: 2000),
                  let url = DriverPages.first(fileUrl, onclick), let file = URL(string: url[0]) else { continue }
            list.append(MakerDownload(title: DriverPages.plain(title, 160), description: DriverPages.plain(HpDrivers.text(d, "description", max: 2000) ?? "", 600),
                                      version: DriverPages.first(versionRx, title)?[1], sizeText: HpDrivers.text(d, "fileSize", max: 20).flatMap(DriverPages.size),
                                      link: file, licence: licencePage(HpDrivers.text(d, "moreHref", max: 300))))
        }
        return list
    }

    private static let morePath = try! NSRegularExpression(pattern: #"^/global/scanners/fisp/dl/[A-Za-z0-9/_\-]{1,200}\.html$"#)

    /// The download's own page on PFU's site (its "more" link: target systems, readme and PFU's END-USER LICENSE AGREEMENT),
    /// the licence the download is accepted under; nil for anything but a page of PFU's download pages.
    public static func licencePage(_ moreHref: String?) -> URL? {
        guard let moreHref, DriverPages.has(morePath, moreHref) else { return nil }
        return URL(string: "https://www.pfu.ricoh.com" + moreHref)
    }

    /// PFU's macOS scanner driver (a .dmg or .pkg whose title says scanner driver); its manuals, utilities and the rest never.
    public static func ranked(_ list: [MakerDownload]) -> [MakerDownload] {
        list.filter { DriverPages.isMacFile($0.link) && $0.title.localizedCaseInsensitiveContains("Scanner Driver") }
    }
}
