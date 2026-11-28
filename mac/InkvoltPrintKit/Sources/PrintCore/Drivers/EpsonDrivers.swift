import Foundation

/// One download as an Epson support page lists it, read from the page's own markup (all of it untrusted).
public struct EpsonDownload: Sendable, Equatable {
    public var section: String
    public var title: String
    public var sizeText: String?
    public var fileName: String
    public var href: URL
    public var description: String
    public var systems: String
}

/// Epson's drivers, from epson.com (the US site, whose pages list every macOS download), as the Windows app's
/// `EpsonDrivers`: the site's product search (`/search/autocomplete/SearchBox?term=`, JSON) gives the model's support page,
/// and that page with this Mac's macOS as its filter (`?review-filter=macOS 26.x (Tahoe)`, what its OS menu and GO do) lists
/// the downloads, each with its title, size, file, the systems it is for and a description. The driver chosen is the kind's
/// own for this macOS: for a scanner Epson's ICA Scanner Driver first (the one ImageCaptureCore, and so Inkvolt Print, scans
/// through), then its other scanner drivers; never a combo package.
public struct EpsonDrivers: DriverCatalog {
    static let source = MakerSource.epson
    let web: MakerWeb

    public init(_ web: MakerWeb) { self.web = web }

    public func looksUp(_ maker: String?) -> Bool { maker?.caseInsensitiveCompare(Self.source.maker) == .orderedSame }

    public func find(_ query: DriverQuery) async -> DriverLookup {
        let model = Self.modelWords(query.model)
        guard !model.isEmpty else { return .none(.notFound) }
        do {
            var search = URLComponents(string: "https://epson.com/search/autocomplete/SearchBox")!
            search.percentEncodedQuery = "term=" + Self.escape(model)
            let found = try await web.text(search.url!, hosts: Self.source.pageHosts, maxBytes: 2 << 20)
            guard let support = Self.supportPage(found, query.model, query.kind) else { return .none(.notFound) }
            let page = URL(string: support.absoluteString + "?review-filter=" + Self.escape(Self.osFilter(query.macOS)).replacingOccurrences(of: "%20", with: "+"))!
            let html = try await web.text(page, hosts: Self.source.pageHosts)
            return Self.choose(Self.parsePage(html), query, page: support)
        } catch let error as FetchError {
            return .none(.unreachable, problem: error.problem)
        } catch {
            return .none(.unreachable, problem: .unreachable)
        }
    }

    /// RFC 3986's unreserved characters left as they are, as .NET's `Uri.EscapeDataString`.
    static func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    /// The names macOS goes by on Epson's OS menu ("macOS 26.x (Tahoe)"), from macOS 13 on; a newer macOS than these reads the
    /// newest's list (Epson lists its drivers for every macOS they run on, so the newest it names is the closest).
    static let macNames: [Int: String] = [13: "Ventura", 14: "Sonoma", 15: "Sequoia", 26: "Tahoe", 27: "Golden Gate"]

    /// The value of the page's OS menu for this macOS.
    public static func osFilter(_ macOS: Int) -> String {
        let major = macNames[macOS] != nil ? macOS : macNames.keys.filter { $0 <= macOS }.max() ?? macNames.keys.min()!
        return "macOS \(major).x (\(macNames[major]!))"
    }

    // MARK: The search: which support page is the model's

    /// The model's words, Epson's name and the kind dropped: "Epson Perfection V19" → "perfection v19".
    public static func modelWords(_ name: String) -> String {
        var words = String(name.prefix(200).lowercased().map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : " " })
            .split(separator: " ").map(String.init).filter { $0 != "epson" }
        while let last = words.last, kindWords.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    private static let kindWords: Set<String> = ["scanner", "printer", "photo", "series", "all-in-one", "allinone", "aio", "mfp", "usb", "-"]
    private static let epsonVariants: Set<String> = ["ii", "iii", "iv", "v", "plus", "pro", "se", "xl", "wide", "max", "mini", "s", "w"]
    private static let supportPath = try! NSRegularExpression(pattern: #"^/Support/[A-Za-z0-9/_\-]{1,200}/s/SPT_[A-Za-z0-9_\-]{1,40}$"#)

    /// The support page of the product the search found for this model and kind: its name the model's words exactly (the kind
    /// and "Epson" aside), else the shortest name that has them in a row with no variant word after; never a refurbished
    /// listing's own. nil: none, or the search's answer can't be read.
    public static func supportPage(_ searchJson: String, _ model: String, _ kind: NeedsDriverKind) -> URL? {
        let want = modelWords(model)
        guard !want.isEmpty, let doc = Json.parse(searchJson), let products = doc["products"]?.arrayValue else { return nil }
        let type = kind == .scanner ? "SCANNER" : "PRINTER"
        var found: [(words: String, path: String)] = []
        for p in products.prefix(50) {
            guard let name = text(p, "name"), let path = text(p, "supportProductId"), DriverPages.has(supportPath, path) else { continue }
            if let t = text(p, "productType"), t.caseInsensitiveCompare(type) != .orderedSame { continue }
            if name.range(of: "ReNew", options: .caseInsensitive) != nil || name.range(of: "Refurbished", options: .caseInsensitive) != nil { continue }
            found.append((modelWords(name), path))
        }
        let pick = found.first { $0.words == want }?.path
            ?? found.filter { DriverPages.hasInARow($0.words, want, variants: epsonVariants) }.min { $0.words.count < $1.words.count }?.path
        return pick.flatMap { URL(string: "https://epson.com" + $0) }
    }

    static func text(_ e: Json, _ name: String) -> String? {
        guard case .string(let s)? = e[name], !s.isEmpty, s.count < 400 else { return nil }
        return s
    }

    // MARK: The support page: its downloads

    private static let titleAttr = try! NSRegularExpression(pattern: #"data-dl_title="([^"]{1,300})""#)
    private static let nameAttr = try! NSRegularExpression(pattern: #"data-dl_name="([^"]{1,200})""#)
    private static let downloadHref = try! NSRegularExpression(pattern: #"href="(https?://[^"\s]{1,500})"\s*>\s*Download"#)
    private static let sizeAttr = try! NSRegularExpression(pattern: #"([\d.]{1,8})&nbsp;(KB|MB|GB)"#, options: .caseInsensitive)
    private static let sectionAttr = try! NSRegularExpression(pattern: ##"data-parent="#([a-z_\-]{1,40})""##)
    private static let subBody = try! NSRegularExpression(pattern: #"class="sub-body">(.{0,4000}?)</p>"#, options: .dotMatchesLineSeparators)
    private static let systemsRx = try! NSRegularExpression(pattern: #"Compatible systems\s*:\s*</p>\s*<p class="sub-body">(.{0,4000}?)</p>"#, options: .dotMatchesLineSeparators)

    /// Every download the page lists, in its order, each in the section it's under ("recommended", "driver",
    /// "utilities"…). At most 200; an entry missing its title, file or https address is left out; every text shortened.
    public static func parsePage(_ html: String) -> [EpsonDownload] {
        var list: [EpsonDownload] = []
        for part in html.components(separatedBy: "<div class=\"panel-heading\">").dropFirst().prefix(200) {
            guard let title = DriverPages.first(titleAttr, part), let name = DriverPages.first(nameAttr, part),
                  let href = DriverPages.first(downloadHref, part), let section = DriverPages.first(sectionAttr, part),
                  let url = URL(string: DriverPages.htmlDecode(href[1])), url.scheme == "https" else { continue }
            let size = DriverPages.first(sizeAttr, part)
            let body = DriverPages.first(subBody, part)
            let systems = DriverPages.first(systemsRx, part)
            list.append(EpsonDownload(section: section[1], title: DriverPages.plain(title[1], 120), sizeText: size.map { "\($0[1]) \($0[2].uppercased())" },
                                      fileName: DriverPages.plain(name[1], 120), href: url, description: body.map { DriverPages.plain($0[1], 600) } ?? "",
                                      systems: systems.map { DriverPages.plain($0[1], 600) } ?? ""))
        }
        return list
    }

    private static let versionRx = try! NSRegularExpression(pattern: #"\bv(\d{1,4}(?:\.\d{1,6}){1,4})\b"#, options: .caseInsensitive)

    /// The download to offer: under "driver", the kind's own (a scanner driver for a scanner, a printer driver for a printer),
    /// not a combo package, listed for this macOS (the page's own list of systems), a Mac file on one of Epson's download hosts:
    /// for a scanner its ICA Scanner Driver first, then the others in Epson's order; for this Mac's processor
    /// (`DriverPages.forThisMac`).
    public static func choose(_ downloads: [EpsonDownload], _ query: DriverQuery, page: URL) -> DriverLookup {
        let kindWord = query.kind == .scanner ? "Scan" : "Printer"
        let os = osFilter(query.macOS)
        let fits = downloads.filter { d in
            ["driver", "drivers"].contains(d.section) && d.title.range(of: "Driver", options: .caseInsensitive) != nil
                && d.title.range(of: kindWord, options: .caseInsensitive) != nil && d.title.range(of: "Combo", options: .caseInsensitive) == nil
                && (d.systems.isEmpty || d.systems.range(of: os, options: .caseInsensitive) != nil)
                && MakerWeb.isAllowed(d.href, source.downloadHosts) && DriverPages.isMacFile(d.href)
        }
        let ica = query.kind == .scanner ? fits.filter { DriverPages.isIca($0.title) } : []
        let ranked = (ica + fits.filter { !ica.contains($0) }).map {
            MakerDownload(title: $0.title, description: $0.description, version: nil, sizeText: $0.sizeText, link: $0.href)
        }
        let (pick, why) = DriverPages.forThisMac(ranked, query.arch)
        guard let pick else { return .none(why, page: page) }
        let title = DriverPages.replace(pick.title, versionRx, "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let version = DriverPages.first(versionRx, pick.title)?[1]
        return .found(DriverOffer(title: title.isEmpty ? pick.title : title, version: version, sizeText: pick.sizeText, download: pick.link, page: page))
    }
}
