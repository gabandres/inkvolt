import Foundation

/// HP's drivers, from support.hp.com's own services (what its driver pages ask), as the Windows app's `HpDrivers`: the
/// product search (`typeahead?q=`, JSON) gives the model's product number; its list of systems
/// (`wcc-services/swd-v2/osVersionData`) gives the ids of its "Mac OS" platform and this macOS ("macOS 26"; HP lists only
/// its newest, which stands for the rest); the driver list (`wcc-services/swd-v2/driverDetails`, a JSON post naming the
/// product and the system) lists each download by section. For a Mac HP mostly lists its app in the Mac App Store (HP's
/// "Install HP app to complete setup"): that link is offered, after a driver or installer file on ftp.hp.com when there is
/// one. Firmware never.
public struct HpDrivers: DriverCatalog {
    static let source = MakerSource.hp
    static let site = "https://support.hp.com/"
    let web: MakerWeb

    public init(_ web: MakerWeb) { self.web = web }

    public func looksUp(_ maker: String?) -> Bool { Self.source.is(maker) }

    public static func words(_ name: String) -> String { DriverPages.modelWords(name, "hp", "hewlett", "packard", "hewlett-packard") }

    /// The name HP's list of systems gives this macOS: "macOS 26".
    public static func osName(_ macOS: Int) -> String { "macOS \(macOS)" }

    public func find(_ query: DriverQuery) async -> DriverLookup {
        let model = Self.words(query.model)
        guard !model.isEmpty else { return .none(.notFound) }
        do {
            let search = URL(string: Self.site + "typeahead?q=" + EpsonDrivers.escape(model)
                + "&resultLimit=10&store=tmsstore&languageCode=en&filters=class:(pm_series_value%5E1.1%20OR%20pm_name_value%20OR%20pm_number_value)")!
            let found = try await web.text(search, hosts: Self.source.pageHosts)
            guard let product = Self.productId(found, query.model) else { return .none(.notFound) }
            let page = URL(string: Self.site + "us-en/drivers/\(product)")!
            let systems = try await web.text(URL(string: Self.site + "wcc-services/swd-v2/osVersionData?cc=us&lc=en&productOid=\(product)")!, hosts: Self.source.pageHosts)
            guard let os = Self.osIds(systems, Self.osName(query.macOS)) else { return .none(.notFound, page: page) }
            let json = Self.listRequest(product: product, platform: os.platform, version: os.version, osName: os.name)
            let list = try await web.postJson(URL(string: Self.site + "wcc-services/swd-v2/driverDetails?authState=anonymous&template=SWD_PDP_Drivers")!, json,
                                              hosts: Self.source.pageHosts)
            let (pick, why) = DriverPages.forThisMac(Self.ranked(Self.parseList(list), query.kind), query.arch)
            guard let pick else { return .none(why, page: page) }
            return DriverPages.offer(pick, pick.link, page: page, Self.source)
        } catch let error as FetchError {
            return .none(.unreachable, problem: error.problem)
        } catch {
            return .none(.unreachable, problem: .unreachable)
        }
    }

    /// The driver list's request: the product and the system, nothing else (as the Windows app's, its keys in HP's order).
    static func listRequest(product: Int64, platform: String, version: String, osName: String) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        return "{\"lc\":\"en\",\"cc\":\"us\",\"osTMSId\":\(q(version)),\"osPlatformId\":\(q(platform)),\"productNameOid\":\(product),"
            + "\"osName\":\(q(osName)),\"platformId\":\(q(platform))}"
    }

    static func text(_ e: Json?, _ name: String, max: Int = 400) -> String? {
        guard case .string(let s)? = e?[name], !s.isEmpty else { return nil }
        return String(s.prefix(max))
    }

    /// The product number of the search's product that is the model ("HP LaserJet MFP M234dw Printer", not its "Trade
    /// Printer"); nil when none is.
    public static func productId(_ json: String, _ model: String) -> Int64? {
        guard let doc = Json.parse(json), let matches = doc["matches"]?.arrayValue else { return nil }
        var found: [(name: String, id: Int64)] = []
        for m in matches.prefix(50) {
            guard let name = text(m, "productname") ?? text(m, "name"), case .number(let raw)? = m["productId"],
                  let n = Int64(raw), n > 0, n < 1_000_000_000_000 else { continue }
            found.append((name, n))
        }
        return DriverPages.bestMatch(found.map(\.name), words(model), words).map { found[$0].id }
    }

    /// This macOS's ids in HP's list of systems: the "Mac OS" platform's and the version's named `osName` ("macOS 26"),
    /// else its newest macOS (HP lists only that one), with the name it has there.
    public static func osIds(_ json: String, _ osName: String) -> (platform: String, version: String, name: String)? {
        guard let doc = Json.parse(json), let platforms = doc["data"]?["osAvailablePlatformsAnsOS"]?["osPlatforms"]?.arrayValue else { return nil }
        for p in platforms.prefix(50) {
            guard let name = text(p, "name"), name.lowercased().hasPrefix("mac"), let platform = text(p, "id", max: 64),
                  platform.allSatisfy(\.isASCII), platform.allSatisfy(\.isNumber), let versions = p["osVersions"]?.arrayValue else { continue }
            var listed: [(number: Int, name: String, id: String)] = []
            for v in versions.prefix(200) {
                guard let vName = text(v, "name"), let id = text(v, "id", max: 64), id.allSatisfy(\.isASCII), id.allSatisfy(\.isNumber) else { continue }
                if vName.caseInsensitiveCompare(osName) == .orderedSame { return (platform, id, vName) }
                if vName.lowercased().hasPrefix("macos "), let n = Int(vName.dropFirst(6).prefix { $0.isNumber }) { listed.append((n, vName, id)) }
            }
            if let newest = listed.max(by: { $0.number < $1.number }) { return (platform, newest.id, newest.name) }
        }
        return nil
    }

    /// Every download HP lists, with its section, in its order: at most 200, each file's address as HP gives it.
    public static func parseList(_ json: String) -> [(section: String, download: MakerDownload)] {
        var list: [(String, MakerDownload)] = []
        guard let doc = Json.parse(json), let types = doc["data"]?["softwareTypes"]?.arrayValue else { return list }
        for t in types.prefix(50) {
            let section = text(t, "accordionNameEn") ?? text(t, "accordionName") ?? ""
            guard let drivers = t["softwareDriversList"]?.arrayValue else { continue }
            for d in drivers.prefix(50) {
                guard let l = d["latestVersionDriver"], let title = text(l, "title"), let raw = text(l, "fileUrl", max: 600),
                      let file = URL(string: raw), file.scheme != nil, file.host != nil else { continue }
                let detail = l["detailInformation"]
                let version = text(l, "version", max: 40).flatMap { $0 == "N/A" ? nil : $0 }
                list.append((DriverPages.plain(section, 160), MakerDownload(title: DriverPages.plain(title, 160),
                    description: DriverPages.plain(text(detail, "description", max: 2000) ?? "", 600), version: version,
                    sizeText: text(l, "fileSize", max: 20).flatMap(DriverPages.size), link: file)))
                if list.count >= 200 { return list }
            }
        }
        return list
    }

    /// HP's app in the Mac App Store, as its list links it (`apps.apple.com/…/app/…`).
    static func isAppStoreApp(_ url: URL) -> Bool {
        url.host?.lowercased() == "apps.apple.com" && url.path.contains("/app/")
    }

    /// The candidates for the kind, best first, only Mac files (.dmg, .pkg) on HP's servers or HP's app in the App Store: a
    /// printer gets HP's full or basic installers' section, then its other driver sections that aren't for scanning, then
    /// HP's app; a scanner HP's scan driver, then the installers, then HP's app. Firmware never.
    public static func ranked(_ list: [(section: String, download: MakerDownload)], _ kind: NeedsDriverKind) -> [MakerDownload] {
        func rank(_ section: String, _ d: MakerDownload) -> Int? {
            let app = isAppStoreApp(d.link)
            guard app || DriverPages.isMacFile(d.link), !section.localizedCaseInsensitiveContains("Firmware") else { return nil }
            let installers = section.localizedCaseInsensitiveContains("Full/Basic")
            let scan = section.localizedCaseInsensitiveContains("Scan") || d.title.localizedCaseInsensitiveContains("Scan")
            let driver = section.lowercased().hasPrefix("driver")
            let online = section.lowercased().hasPrefix("installation software and driver")
            if app { return online || driver || installers ? 4 : nil }
            if kind == .scanner { return scan && driver ? 0 : installers ? 2 : online ? 3 : nil }
            return installers ? 0 : driver && !scan ? 1 : online ? 2 : nil
        }
        return DriverPages.byRank(list.map { e in (e.download, rank(e.section, e.download)) })
    }
}
