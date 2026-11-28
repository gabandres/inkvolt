import Foundation

/// Brother's drivers, from support.brother.com (the US site), as the Windows app's `BrotherDrivers`: its product search
/// (`productlist.aspx?q=`) opens the model's own downloads page when it knows the model, which names its product code; the
/// download list for this macOS (`downloadlist.aspx?prod=…&os=`, 10083 macOS 15, 10088 macOS 26, 10094 macOS 27) lists each
/// download by section; the chosen one's page past the licence (`downloadhowto.aspx`) names the file on download.brother.com.
/// The kind's own driver is chosen (Printer Driver; a scanner's ICA driver, then its Scanner Driver), else Brother's Full
/// Software Package (what most models list for a Mac now).
public struct BrotherDrivers: DriverCatalog {
    static let source = MakerSource.brother
    static let site = "https://support.brother.com/g/b/"
    let web: MakerWeb

    public init(_ web: MakerWeb) { self.web = web }

    public func looksUp(_ maker: String?) -> Bool { Self.source.is(maker) }

    public static func words(_ name: String) -> String { DriverPages.modelWords(name, "brother") }

    /// Brother's codes for macOS on its download lists (read from its OS menu, 2026-11-27); a newer macOS than these reads
    /// the newest's list.
    static let osCodes: [Int: String] = [15: "10083", 26: "10088", 27: "10094"]

    /// The download list's code for this macOS.
    public static func osCode(_ macOS: Int) -> String {
        if let code = osCodes[macOS] { return code }
        let major = osCodes.keys.filter { $0 <= macOS }.max() ?? osCodes.keys.min()!
        return osCodes[major]!
    }

    public func find(_ query: DriverQuery) async -> DriverLookup {
        let model = Self.words(query.model)
        guard !model.isEmpty else { return .none(.notFound) }
        do {
            let search = try await web.text(URL(string: Self.site + "productlist.aspx?c=us&lang=en&content=dl&q=" + EpsonDrivers.escape(model))!,
                                            hosts: Self.source.pageHosts)
            guard let prod = Self.productCode(search, query.model) else { return .none(.notFound) }
            let page = URL(string: Self.site + "downloadtop.aspx?c=us&lang=en&prod=" + prod)!
            let list = try await web.text(URL(string: Self.site + "downloadlist.aspx?c=us&lang=en&prod=\(prod)&os=\(Self.osCode(query.macOS))")!,
                                          hosts: Self.source.pageHosts)
            let (pick, why) = DriverPages.forThisMac(Self.ranked(Self.parseList(list), query.kind), query.arch)
            guard let pick else { return .none(why, page: page) }
            let howto = try await web.text(pick.link, hosts: Self.source.pageHosts)
            // The licence the "Agree to the EULA and Download" button accepts is on the download's own page.
            guard let file = Self.fileOf(howto), DriverPages.isMacFile(file) else { return .none(.notFound, page: page) }
            return DriverPages.offer(pick, file, page: page, Self.source, licence: Self.licencePage(pick.link))
        } catch let error as FetchError {
            return .none(.unreachable, problem: error.problem)
        } catch {
            return .none(.unreachable, problem: .unreachable)
        }
    }

    private static let product = try! NSRegularExpression(
        pattern: #"<h3 class="title"><a href="/g/b/producttop\.aspx\?c=us&(?:amp;)?lang=en&(?:amp;)?prod=([a-z0-9_]{1,60})">([^<]{1,100})</a>"#)
    private static let aside = try! NSRegularExpression(pattern: #"\([^)]{0,20}\)"#)

    /// The product code of the model's page the search opened: its title's model the model's own (Brother's "(XL)" and the
    /// like aside). nil: the search listed several products, or another model, or nothing.
    public static func productCode(_ html: String, _ model: String) -> String? {
        guard let m = DriverPages.first(product, html) else { return nil }
        let name = DriverPages.replace(DriverPages.htmlDecode(m[2]), aside, " ")
        let want = words(model)
        return !want.isEmpty && words(name) == want ? m[1] : nil
    }

    private static let section = try! NSRegularExpression(pattern: #"<h3 class="h3">([^<]{1,80})</h3>"#)
    private static let entry = try! NSRegularExpression(pattern: #"<a href="(/g/b/downloadend\.aspx\?[A-Za-z0-9_=&;.%\-]{1,300})">([^<]{1,200})</a>"#)
    private static let comment = try! NSRegularExpression(pattern: #"class="type3comment">(.{0,3000}?)</div>"#, options: .dotMatchesLineSeparators)
    private static let versionCell = try! NSRegularExpression(pattern: #"<br>\(([^)<]{1,40})\)</em>"#, options: .caseInsensitive)
    private static let sizeCell = try! NSRegularExpression(pattern: #"<em>([\d.,]{1,10})<BR>(KB|MB|GB)</em>"#, options: .caseInsensitive)

    /// Every download the list shows, in its order, with the section it's under ("Drivers", "Full Software Package"…). At
    /// most 200 (a section's first 100 rows), every text shortened; the link is the download's page past the licence.
    public static func parseList(_ html: String) -> [(section: String, download: MakerDownload)] {
        var list: [(String, MakerDownload)] = []
        let sections = DriverPages.ranges(section, html, max: 200)
        for (s, found) in sections.enumerated() where list.count < 200 {
            let end = s + 1 < sections.count ? sections[s + 1].range.lowerBound : html.endIndex
            let name = DriverPages.plain(found.groups[1], 80)
            for row in html[found.range.lowerBound..<end].components(separatedBy: "<tr>").dropFirst().prefix(100) {
                guard let e = DriverPages.first(entry, row) else { continue }
                let howto = "https://support.brother.com" + DriverPages.htmlDecode(e[1]).replacingOccurrences(of: "/downloadend.aspx", with: "/downloadhowto.aspx")
                guard let link = URL(string: howto) else { continue }
                let version = DriverPages.first(versionCell, row).map { $0[1].trimmingCharacters(in: .whitespaces) }
                let size = DriverPages.first(sizeCell, row).map { "\($0[1]) \($0[2].uppercased())" }
                list.append((name, MakerDownload(title: DriverPages.plain(e[2], 120), description: DriverPages.first(comment, row).map { DriverPages.plain($0[1], 600) } ?? "",
                                                 version: version, sizeText: size, link: link)))
                if list.count >= 200 { break }
            }
        }
        return list
    }

    /// The candidates for the kind, best first: under Drivers the kind's own driver (a scanner's ICA driver before its others),
    /// then the Full Driver & Software Package or the Full Software Package. Firmware, utilities and the rest never.
    public static func ranked(_ list: [(section: String, download: MakerDownload)], _ kind: NeedsDriverKind) -> [MakerDownload] {
        func rank(_ section: String, _ d: MakerDownload) -> Int? {
            let t = d.title
            if section.caseInsensitiveCompare("Drivers") == .orderedSame {
                if kind == .scanner && DriverPages.isIca(t) { return 0 }
                if kind == .scanner && (t.localizedCaseInsensitiveContains("Scanner Driver") || t.localizedCaseInsensitiveContains("TWAIN")) { return 1 }
                if kind == .printer && (t.localizedCaseInsensitiveContains("Printer Driver") || t.localizedCaseInsensitiveContains("CUPS")) { return 0 }
            }
            let full = t.localizedCaseInsensitiveContains("Full Driver") || t.localizedCaseInsensitiveContains("Full Software Package")
            return full ? 2 : nil
        }
        return DriverPages.byRank(list.map { e in (e.download, rank(e.section, e.download)) })
    }

    /// The download's page that shows Brother's EULA and its "Agree to the EULA and Download" button.
    public static func licencePage(_ howto: URL) -> URL? {
        URL(string: howto.absoluteString.replacingOccurrences(of: "/downloadhowto.aspx", with: "/downloadend.aspx"))
    }

    private static let downloadFile = try! NSRegularExpression(pattern: #"<a id="downloadfile" href="(https://[^"\s]{1,500})""#)

    /// The file the page past the licence starts (its "click here" link); nil when it names none.
    public static func fileOf(_ html: String) -> URL? {
        DriverPages.first(downloadFile, html).flatMap { URL(string: DriverPages.htmlDecode($0[1])) }
    }
}
