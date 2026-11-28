import Foundation

/// This Mac's processor, as a maker's download is built for it (the Windows app's `PcArch`).
public enum MacArch: Sendable { case appleSilicon, intel }

/// What to look for: a model of a maker's, for this Mac (the Windows app's `DriverQuery`, its Windows a macOS major version).
public struct DriverQuery: Sendable, Equatable {
    public var maker: String
    public var model: String
    public var kind: NeedsDriverKind
    public var arch: MacArch
    /// macOS's major version (15, 26, 27…), as the makers' pages list it.
    public var macOS: Int

    public init(maker: String, model: String, kind: NeedsDriverKind, arch: MacArch, macOS: Int) {
        self.maker = maker
        self.model = model
        self.kind = kind
        self.arch = arch
        self.macOS = macOS
    }

    public static func `for`(_ device: NeedsDriverPrinter, arch: MacArch, macOS: Int) -> DriverQuery {
        DriverQuery(maker: device.maker ?? "", model: device.name, kind: device.kind, arch: arch, macOS: macOS)
    }
}

/// A download a maker's page offers for the model: what the page shows of it, and where it comes from (the Windows app's
/// `DriverOffer`, without the file name: the Mac never saves the file itself).
public struct DriverOffer: Sendable, Equatable {
    public var title: String
    public var version: String?
    /// The size as the page says it ("29.5 MB"): shown only.
    public var sizeText: String?
    /// The maker's own link to the file (or, for HP, its app in the App Store).
    public var download: URL
    /// The maker's page for the model.
    public var page: URL
    /// The maker's page with the licence the download is under, when the maker asks for it to be accepted before
    /// downloading (Brother's EULA, Canon's disclaimer, PFU's licence): opened instead of the file, where it is accepted.
    public var licence: URL?

    public init(title: String, version: String?, sizeText: String?, download: URL, page: URL, licence: URL? = nil) {
        self.title = title
        self.version = version
        self.sizeText = sizeText
        self.download = download
        self.page = page
        self.licence = licence
    }
}

/// Why no download was offered.
public enum NoOffer: Sendable, Equatable {
    /// Inkvolt Print doesn't look up this maker's downloads (the maker's page instead).
    case makerNotLookedUp
    /// The maker's site has no page for the model, or its page no driver for this macOS.
    case notFound
    /// The model's page has drivers, none of them for Apple silicon (this Mac's processor): Windows' `NoArm64`.
    case noArm64
    /// The maker's site didn't answer, or answered something that can't be read.
    case unreachable
}

/// What a look found: a download, or why there's none (and the maker's page for the model when one was found).
public struct DriverLookup: Sendable, Equatable {
    public var offer: DriverOffer?
    public var why: NoOffer?
    public var page: URL?
    public var problem: FetchProblem?

    public static func found(_ offer: DriverOffer) -> DriverLookup { DriverLookup(offer: offer, why: nil, page: nil, problem: nil) }

    public static func none(_ why: NoOffer, page: URL? = nil, problem: FetchProblem? = nil) -> DriverLookup {
        DriverLookup(offer: nil, why: why, page: page, problem: problem)
    }
}

/// Finds a model's driver on its maker's site (the seam: `EpsonDrivers` and the others, demo mode's and the tests' fakes).
public protocol DriverCatalog: Sendable {
    func looksUp(_ maker: String?) -> Bool
    func find(_ query: DriverQuery) async -> DriverLookup
}

/// The makers whose pages Inkvolt Print may read and whose links it may open: the hosts its pages and files come from
/// (https, exactly these names). The Windows app's `MakerSource` without the signers (the Mac never runs an installer) and
/// with the Mac's download hosts: HP's app in the App Store, Epson's and PFU's .dmg on the same servers.
public struct MakerSource: Sendable {
    public let maker: String
    public let pageHosts: [String]
    public let downloadHosts: [String]
    /// Other names a device of this maker's goes by (a PFU scanner reports Fujitsu's vendor id).
    public let aliases: [String]

    public static let epson = MakerSource(maker: "Epson", pageHosts: ["epson.com", "www.epson.com"],
        downloadHosts: ["ftp.epson.com", "download.epson.com", "download.ebz.epson.net", "download2.ebz.epson.net", "download3.ebz.epson.net"], aliases: [])
    /// Canon's Asia site (the US and European sites refuse programs); the files come from Canon's download servers.
    public static let canon = MakerSource(maker: "Canon", pageHosts: ["asia.canon"], downloadHosts: ["pdisp01.c-wss.com", "gdlp01.c-wss.com"], aliases: [])
    /// HP's Mac software is its app in the Mac App Store, where its driver list links it, or a file on its servers.
    public static let hp = MakerSource(maker: "HP", pageHosts: ["support.hp.com"], downloadHosts: ["ftp.hp.com", "ftp.ext.hp.com", "apps.apple.com"], aliases: [])
    public static let brother = MakerSource(maker: "Brother", pageHosts: ["support.brother.com"], downloadHosts: ["download.brother.com"], aliases: [])
    /// PFU (a Ricoh company, formerly Fujitsu's): fi and SP series scanners.
    public static let pfu = MakerSource(maker: "PFU", pageHosts: ["www.pfu.ricoh.com"], downloadHosts: ["origin.pfultd.com"], aliases: ["Fujitsu", "Ricoh PFU"])

    public static let all: [MakerSource] = [epson, canon, hp, brother, pfu]

    public static func `for`(_ maker: String?) -> MakerSource? { all.first { $0.is(maker) } }

    /// This maker, by its name or an alias (case aside).
    public func `is`(_ maker: String?) -> Bool {
        guard let maker else { return false }
        return ([self.maker] + aliases).contains { $0.caseInsensitiveCompare(maker) == .orderedSame }
    }
}

/// The catalogs Inkvolt Print has, one per maker; a maker without one is `.makerNotLookedUp`.
public struct MakerCatalogs: DriverCatalog {
    let catalogs: [any DriverCatalog]

    public init(_ catalogs: [any DriverCatalog]) { self.catalogs = catalogs }

    /// The five makers' catalogs over one web (the app's: `MakerWeb` over a system-trust transport).
    public static func all(_ web: MakerWeb) -> MakerCatalogs {
        MakerCatalogs([EpsonDrivers(web), CanonDrivers(web), HpDrivers(web), BrotherDrivers(web), PfuDrivers(web)])
    }

    public func looksUp(_ maker: String?) -> Bool { catalogs.contains { $0.looksUp(maker) } }

    public func find(_ query: DriverQuery) async -> DriverLookup {
        guard let c = catalogs.first(where: { $0.looksUp(query.maker) }) else { return .none(.makerNotLookedUp) }
        return await c.find(query)
    }
}
