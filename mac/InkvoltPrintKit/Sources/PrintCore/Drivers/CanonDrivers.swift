import Foundation

/// Canon's drivers, from Canon's Asia site (asia.canon: Canon USA's and Canon Europe's sites refuse a program's requests), as
/// the Windows app's `CanonDrivers`: its model suggestions (`/en/support/suggest?query=`, JSON) give the model's name there;
/// its driver list for this macOS (`/en/support/{model}/get-search-result-content?fileType=DR&os=macOS 26`) lists each
/// download; the chosen one's page names its version and links Canon's download server (pdisp01.c-wss.com). A printer gets
/// its CUPS, MP or Printer Driver, a scanner its ICA driver, else its Scanner Driver, else either the Full Driver & Software
/// Package. For most current models Canon's Asia site lists no macOS driver (macOS prints and scans to them driverless, or
/// Canon serves them from the sites that refuse programs): then nothing is found, and the model's page is offered.
public struct CanonDrivers: DriverCatalog {
    static let source = MakerSource.canon
    static let site = "https://asia.canon/en/support/"
    let web: MakerWeb

    public init(_ web: MakerWeb) { self.web = web }

    public func looksUp(_ maker: String?) -> Bool { Self.source.is(maker) }

    public static func words(_ name: String) -> String { DriverPages.modelWords(name, "canon") }

    /// The driver list's filter for this macOS: "macOS 26", as the site's OS menu names it.
    public static func osFilter(_ macOS: Int) -> String { "macOS \(macOS)" }

    public func find(_ query: DriverQuery) async -> DriverLookup {
        let model = Self.words(query.model)
        guard !model.isEmpty else { return .none(.notFound) }
        do {
            let suggest = try await web.text(URL(string: Self.site + "suggest?query=" + EpsonDrivers.escape(model))!, hosts: Self.source.pageHosts)
            guard let name = Self.modelName(suggest, query.model) else { return .none(.notFound) }
            let path = Self.pathOf(name)
            let page = URL(string: Self.site + path + "/model")!
            let list = try await web.text(URL(string: Self.site + path + "/get-search-result-content?fileType=DR&os=" + EpsonDrivers.escape(Self.osFilter(query.macOS)) + "&q=")!,
                                          hosts: Self.source.pageHosts)
            let (pick, why) = DriverPages.forThisMac(Self.ranked(Self.parseList(list), query.kind), query.arch)
            guard let pick else { return .none(why, page: page) }
            let detail = try await web.text(pick.link, hosts: Self.source.pageHosts)
            // Canon's download button sits under "I have read and understood the disclaimer below": that page, at its
            // disclaimer, is the licence.
            guard let file = Self.parseDetail(detail, pick) else { return .none(.notFound, page: page) }
            var licence = URLComponents(url: pick.link, resolvingAgainstBaseURL: false)
            licence?.fragment = "disclaimer"
            return DriverPages.offer(file.download, file.url, page: page, Self.source, licence: licence?.url)
        } catch let error as FetchError {
            return .none(.unreachable, problem: error.problem)
        } catch {
            return .none(.unreachable, problem: .unreachable)
        }
    }

    /// The suggestion that is the model, as Canon names it there: one name, or several sharing a page ("imageCLASS LBP6030/
    /// LBP6030B/ LBP6030w"), each tried. nil when none is, or the answer can't be read.
    public static func modelName(_ json: String, _ model: String) -> String? {
        guard let doc = Json.parse(json), let data = doc["data"]?.arrayValue else { return nil }
        let names: [String] = data.prefix(50).compactMap { if case .string(let s) = $0, (1...200).contains(s.count) { s } else { nil } }
        let want = words(model)
        // Each name of a shared page as its own: "imageCLASS LBP6030/ LBP6030B" is "imageCLASS LBP6030" and "LBP6030B".
        let each = names.enumerated().flatMap { i, n in
            n.split(separator: "/").map { (name: $0.trimmingCharacters(in: .whitespaces), index: i) }.filter { !$0.name.isEmpty }
        }
        var best = DriverPages.bestMatch(each.map(\.name), want, words)
        // A name with its line the page leaves out ("imageCLASS LBP6030w" on the page of "… LBP6030/ LBP6030B/ LBP6030w"): its
        // model number alone, when that is a real one (letters and digits, four or more).
        let number = want.split(separator: " ").last.map(String.init) ?? ""
        if best == nil, want.contains(" "), number.count >= 4, number.contains(where: \.isNumber), number.contains(where: \.isLetter) {
            best = each.firstIndex { words($0.name) == number }
        }
        return best.map { names[each[$0].index] }
    }

    /// The model's name in the site's paths, as its own pages write it ("/" as "__", "." as "&&"), escaped.
    public static func pathOf(_ name: String) -> String {
        EpsonDrivers.escape(name.replacingOccurrences(of: "/", with: "__").replacingOccurrences(of: ".", with: "&&").trimmingCharacters(in: .whitespaces))
    }

    private static let card = try! NSRegularExpression(
        pattern: #"softwareCard__content--title">\s*<a href="(/en/support/[0-9]{6,14}\?model=[A-Za-z0-9+%._\-]{0,200})">(.{1,300}?)</a>"#, options: .dotMatchesLineSeparators)
    private static let desc = try! NSRegularExpression(pattern: #"softwareCard__content--desc">(.{0,3000}?)</div>"#, options: .dotMatchesLineSeparators)
    private static let cardSize = try! NSRegularExpression(pattern: #"Size</div>\s*<p>([^<]{1,30})</p>"#)

    /// Every download the list shows, in its order: at most 200, each linking its page on the site.
    public static func parseList(_ html: String) -> [MakerDownload] {
        var list: [MakerDownload] = []
        for part in html.components(separatedBy: "class=\"softwareCard\"").dropFirst().prefix(200) {
            guard let c = DriverPages.first(card, part), let link = URL(string: "https://asia.canon" + DriverPages.htmlDecode(c[1])) else { continue }
            list.append(MakerDownload(title: DriverPages.plain(c[2], 160), description: DriverPages.first(desc, part).map { DriverPages.plain($0[1], 600) } ?? "",
                                      version: nil, sizeText: DriverPages.first(cardSize, part).flatMap { DriverPages.size($0[1]) }, link: link))
        }
        return list
    }

    /// The candidates for the kind, best first (see the type); patches, firmware and the rest never.
    public static func ranked(_ list: [MakerDownload], _ kind: NeedsDriverKind) -> [MakerDownload] {
        func rank(_ d: MakerDownload) -> Int? {
            let t = d.title
            // Canon names a download's system in its title ("… (Windows)", "… (Mac)"): one for Windows is never a Mac's.
            if t.localizedCaseInsensitiveContains("patch") || t.localizedCaseInsensitiveContains("Firmware") || t.localizedCaseInsensitiveContains("Windows") { return nil }
            let printer = t.localizedCaseInsensitiveContains("MP Drivers") || t.localizedCaseInsensitiveContains("Printer Driver")
                || t.localizedCaseInsensitiveContains("CUPS")
            if kind == .scanner {
                if DriverPages.isIca(t) { return 0 }
                if t.localizedCaseInsensitiveContains("Scanner Driver") { return 1 }
                if t.localizedCaseInsensitiveContains("MP Drivers") { return 2 }
            } else if printer {
                return t.localizedCaseInsensitiveContains("MP Drivers") || t.localizedCaseInsensitiveContains("CUPS") ? 0 : 1
            }
            return t.localizedCaseInsensitiveContains("Full Driver") ? 3 : nil
        }
        return DriverPages.byRank(list.map { d in (d, rank(d)) })
    }

    private static let dataUrl = try! NSRegularExpression(pattern: #"data-url="(https://pdisp01\.c-wss\.com/gdl/WWUFORedirectTarget\.do\?[A-Za-z0-9=&;%_\-]{1,300})""#)
    private static let fileVersion = try! NSRegularExpression(pattern: #"File version\s*:\s*([A-Za-z0-9._\-]{1,40})"#)

    /// The download's page: Canon's link to the file (on its download server) and the file's version. nil without the link.
    public static func parseDetail(_ html: String, _ listed: MakerDownload) -> (download: MakerDownload, url: URL)? {
        guard let m = DriverPages.first(dataUrl, html), let url = URL(string: DriverPages.htmlDecode(m[1])) else { return nil }
        var d = listed
        d.version = DriverPages.first(fileVersion, html)?[1]
        return (d, url)
    }
}
