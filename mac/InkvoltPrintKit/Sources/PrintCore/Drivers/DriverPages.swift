import Foundation

/// One download a maker's page lists, as read (all of it untrusted): its title and description, version and size as the page
/// says them, and `link`: the file itself, or the maker's page that names it (Brother's and Canon's). `licence`: the maker's
/// page with the licence the download is under, when the list gives one (PFU's).
public struct MakerDownload: Sendable, Equatable {
    public var title: String
    public var description: String
    public var version: String?
    public var sizeText: String?
    public var link: URL
    public var licence: URL?

    public init(title: String, description: String, version: String?, sizeText: String?, link: URL, licence: URL? = nil) {
        self.title = title
        self.description = description
        self.version = version
        self.sizeText = sizeText
        self.link = link
        self.licence = licence
    }
}

/// What every maker's lookup does the same way (the Windows app's `DriverPages`): a model's words, which of the site's
/// products is the model, page text made plain and short, the download for this Mac's processor, and the offer built from it.
public enum DriverPages {
    /// How long one page may take, and how big a page or an answer may be.
    public static let limit: Duration = .seconds(30)
    public static let maxPage = 6 << 20

    private static let trailingWords: Set<String> = ["printer", "scanner", "series", "all-in-one", "allinone", "aio", "usb"]

    /// Words after a model's that make it another model ("V19 II" isn't the V19, a "Trade" printer isn't the printer).
    static let variantWords: Set<String> = ["ii", "iii", "iv", "v", "plus", "pro", "se", "xl", "wide", "max", "mini", "s", "w", "trade", "loyal"]

    /// A model's words, lower case: the maker's names (`makerWords`) dropped, and kind words at its end ("printer",
    /// "series"…): "Brother HL-L2350DW series" → "hl-l2350dw". At most 200 characters of the name are read.
    public static func modelWords(_ name: String, _ makerWords: String...) -> String { modelWords(name, makerWords) }

    public static func modelWords(_ name: String, _ makerWords: [String]) -> String {
        let text = String(name.prefix(200)).lowercased()
        var words = String(text.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? $0 : " " })
            .split(separator: " ").map(String.init).filter { $0 != "-" && !makerWords.contains($0) }
        while let last = words.last, trailingWords.contains(last) { words.removeLast() }
        return words.joined(separator: " ")
    }

    /// Which of a site's product names is the model (each made words by `words`): the first with exactly its words, else the
    /// shortest that has them in a row with no variant word after. nil: none. At most the first 100 names.
    public static func bestMatch(_ names: [String], _ want: String, _ words: (String) -> String) -> Int? {
        guard !want.isEmpty else { return nil }
        let found = names.prefix(100).enumerated().map { (words: words($0.element), index: $0.offset) }
        if let exact = found.first(where: { $0.words == want }) { return exact.index }
        return found.filter { hasInARow($0.words, want) }.min { $0.words.count < $1.words.count }?.index
    }

    static func hasInARow(_ words: String, _ want: String, variants: Set<String> = variantWords) -> Bool {
        let w = words.split(separator: " ").map(String.init), m = want.split(separator: " ").map(String.init)
        guard !m.isEmpty, m.count <= w.count else { return false }
        for i in 0...(w.count - m.count) where Array(w[i..<i + m.count]) == m {
            if i + m.count == w.count || !variants.contains(w[i + m.count]) { return true }
        }
        return false
    }

    /// A page's text without its tags and entities, spaces joined, cut at `max` characters.
    public static func plain(_ html: String, _ max: Int) -> String {
        let untagged = replace(html, tags, " ")
        let s = htmlDecode(untagged).replacingOccurrences(of: "\u{00A0}", with: " ").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return s.count > max ? String(s.prefix(max)).trimmingCharacters(in: .whitespaces) + "…" : s
    }

    private static let tags = try! NSRegularExpression(pattern: "<[^>]{0,2000}>")

    // MARK: This Mac's processor

    /// Apple silicon as the makers write it: "Apple silicon", "Apple M1", "M-series", "arm64", "Universal".
    private static let appleSilicon = try! NSRegularExpression(pattern: #"apple\s*silicon|\bapple\s+m\d|m-series|\barm\s?64\b|\barm\b|\baarch64\b|universal"#, options: .caseInsensitive)
    private static let intel = try! NSRegularExpression(pattern: #"\bintel\b|\bx86[-_]?64\b|\bx64\b"#, options: .caseInsensitive)

    public static func forAppleSilicon(_ title: String, _ description: String) -> Bool {
        has(appleSilicon, title) || has(appleSilicon, description)
    }

    /// Names Intel and not Apple silicon or a universal build: a driver that doesn't load on Apple silicon (a scanner's
    /// ImageCaptureCore module and a printer's filters are native code).
    public static func intelOnly(_ title: String, _ description: String) -> Bool {
        (has(intel, title) || has(intel, description)) && !forAppleSilicon(title, description)
    }

    /// Names Apple silicon and not Intel or a universal build.
    public static func appleSiliconOnly(_ title: String, _ description: String) -> Bool {
        forAppleSilicon(title, description) && !has(intel, title) && !has(intel, description)
            && !(title + " " + description).lowercased().contains("universal")
    }

    /// The download for this Mac among `ranked` (the maker's candidates for the kind and macOS, best first): on Apple silicon
    /// the first that isn't for Intel only, on an Intel Mac the first that isn't for Apple silicon only. Unlike Windows on
    /// ARM (where only a build that says ARM loads), a Mac download that names neither runs on both: makers' .dmg are
    /// universal, and one that mentions Apple silicon isn't preferred over the maker's own order (Epson's Scan 2 says so, its
    /// ICA driver doesn't). None: on Apple silicon `.noArm64` when there were candidates but all for Intel, else (and always
    /// on Intel) `.notFound`.
    public static func forThisMac(_ ranked: [MakerDownload], _ arch: MacArch) -> (pick: MakerDownload?, why: NoOffer) {
        let pick = arch == .appleSilicon
            ? ranked.first { !intelOnly($0.title, $0.description) }
            : ranked.first { !appleSiliconOnly($0.title, $0.description) }
        return (pick, whyNone(!ranked.isEmpty, arch))
    }

    /// Why nothing was offered: `.noArm64` only on Apple silicon when the kind's drivers were listed.
    public static func whyNone(_ listed: Bool, _ arch: MacArch) -> NoOffer { listed && arch == .appleSilicon ? .noArm64 : .notFound }

    /// The offer for `d`'s file at `file`: none when that isn't on the maker's download hosts. `licence`: the maker's page with
    /// the licence the download is under, when it asks for one to be accepted (only one on the maker's own site is kept).
    public static func offer(_ d: MakerDownload, _ file: URL, page: URL, _ source: MakerSource, licence: URL? = nil) -> DriverLookup {
        guard MakerWeb.isAllowed(file, source.downloadHosts) else { return .none(.notFound, page: page) }
        let kept = licence.flatMap { MakerWeb.isAllowed($0, source.pageHosts) ? $0 : nil }
        return .found(DriverOffer(title: plain(d.title, 120), version: d.version.flatMap { $0.isEmpty ? nil : plain($0, 40) },
                                  sizeText: d.sizeText, download: file, page: page, licence: kept))
    }

    /// "221.76 MB", "19.81 MB" as the page says it (a number and a unit), else nil.
    public static func size(_ text: String) -> String? {
        guard let m = first(sizeRx, text) else { return nil }
        return "\(m[1]) \(m[2].uppercased())"
    }

    private static let sizeRx = try! NSRegularExpression(pattern: #"(\d{1,6}(?:[.,]\d{1,3})?)\s*(KB|MB|GB)"#, options: .caseInsensitive)

    /// A Mac installer or its disk image by its address: .dmg, .pkg, or a zipped Mac app or package (HP's
    /// "HP_Easy_Start.app.zip"); any other .zip (Windows' driver packs) never.
    public static func isMacFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        if ["dmg", "pkg", "mpkg"].contains(url.pathExtension.lowercased()) { return true }
        return name.hasSuffix(".app.zip") || name.hasSuffix(".pkg.zip") || name.hasSuffix(".dmg.zip")
    }

    /// The downloads a ranking kept (its rank, nil: never), best rank first, the page's order within a rank.
    static func byRank(_ ranked: [(download: MakerDownload, rank: Int?)]) -> [MakerDownload] {
        var kept: [(download: MakerDownload, rank: Int, order: Int)] = []
        for (order, entry) in ranked.enumerated() {
            if let rank = entry.rank { kept.append((entry.download, rank, order)) }
        }
        kept.sort { a, b in a.rank != b.rank ? a.rank < b.rank : a.order < b.order }
        return kept.map(\.download)
    }

    private static let icaWord = try! NSRegularExpression(pattern: #"\bICA\b"#)

    /// An ImageCaptureCore driver by its title ("ICA Scanner Driver", "Scanner Driver (ICA)"): the word, never "Specification".
    public static func isIca(_ title: String) -> Bool { has(icaWord, title) }

    // MARK: Text helpers

    static func has(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// The first match's groups (0: the whole match; a group that didn't take part is "").
    static func first(_ re: NSRegularExpression, _ text: String) -> [String]? {
        guard let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(m, text)
    }

    static func all(_ re: NSRegularExpression, _ text: String, max: Int) -> [[String]] {
        var out: [[String]] = []
        re.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, stop in
            guard let m else { return }
            out.append(groups(m, text))
            if out.count >= max { stop.pointee = true }
        }
        return out
    }

    /// Each match's whole range (as `first`'s groups, with where it starts).
    static func ranges(_ re: NSRegularExpression, _ text: String, max: Int) -> [(range: Range<String.Index>, groups: [String])] {
        var out: [(Range<String.Index>, [String])] = []
        re.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { m, _, stop in
            guard let m, let r = Range(m.range, in: text) else { return }
            out.append((r, groups(m, text)))
            if out.count >= max { stop.pointee = true }
        }
        return out
    }

    private static func groups(_ m: NSTextCheckingResult, _ text: String) -> [String] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }

    static func replace(_ text: String, _ re: NSRegularExpression, _ with: String) -> String {
        re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }

    /// HTML's character references made characters (.NET's `WebUtility.HtmlDecode`): `&amp;`, `&quot;`, `&#39;`, `&#x2122;`,
    /// `&nbsp;` and the other common names; an unknown or malformed one stays as written.
    public static func htmlDecode(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var i = s.startIndex
        while i < s.endIndex {
            let c = s[i]
            guard c == "&", let semi = s[i...].prefix(12).firstIndex(of: ";") else {
                out.append(c)
                i = s.index(after: i)
                continue
            }
            let name = s[s.index(after: i)..<semi]
            if let ch = entity(String(name)) {
                out.append(ch)
                i = s.index(after: semi)
            } else {
                out.append(c)
                i = s.index(after: i)
            }
        }
        return out
    }

    private static let named: [String: Character] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}", "reg": "®", "trade": "™", "copy": "©",
        "ndash": "–", "mdash": "—", "rsquo": "’", "lsquo": "‘", "rdquo": "”", "ldquo": "“", "hellip": "…", "middot": "·",
    ]

    private static func entity(_ name: String) -> Character? {
        if name.hasPrefix("#x") || name.hasPrefix("#X") {
            return UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(Character.init)
        }
        if name.hasPrefix("#") { return UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map(Character.init) }
        return named[name]
    }
}
