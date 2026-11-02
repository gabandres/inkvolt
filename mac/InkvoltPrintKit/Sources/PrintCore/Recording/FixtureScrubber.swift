import Foundation

/// Takes out of a printer recording what identifies the printer, its network or a person, as Report a problem does
/// (`Diagnostics.scrub`), but keeping the documents readable: every identifier gets a stand-in of the same shape, the same
/// one wherever it appears, so the identity checks still agree on replay (the UUID LEDM, eSCL and IPP report stays one UUID;
/// the serial number LEDM and SNMP report stays one serial). Serial numbers become `SN0…1` (same length), UUIDs
/// `00000000-0000-4000-8000-00000000000n`, addresses RFC 5737's (the recorded printer's is `placeholderHost`), IPv6
/// addresses RFC 3849's `2001:db8::n`, MAC addresses RFC 7042's `00:00:5E:00:53:nn`, host names `printer-n` (`.local` and
/// `.example` kept as the shape), e-mail addresses `user@example.com`. What a person typed (printer name, location,
/// contact, user and job names, Wi-Fi names) becomes a word that says what it was. Two passes: `learn` every document
/// first (identifiers from their fields: serials, UUIDs, MAC addresses, host names), then `scrub` each, so an identifier
/// learnt in one document is caught in free text in another. The Windows app's `FixtureScrubber`; its patterns in ICU's
/// syntax (a look-behind can't repeat without a bound, so the spaces after "version" take at most eight characters).
public final class FixtureScrubber {
    /// Where a recording's printer is: the demo printer's address (RFC 5737), so the fixture transport's tests read it as is.
    public static let defaultPlaceholderHost = FixtureTransport.demoHost

    public let placeholderHost: String
    private let host: String
    private let who: Diagnostics.Identity?

    private enum Kind: String, CaseIterable {
        case serial = "Serial", uuid = "Uuid", mac = "Mac", ip = "Ip", ip6 = "Ip6", host = "Host", bracket = "Bracket"
    }

    /// Kind → lower-cased value → (the value as first seen, its stand-in): the maps compare without case, as Windows' do.
    private var maps: [Kind: [String: (from: String, to: String)]] = Dictionary(uniqueKeysWithValues: Kind.allCases.map { ($0, [:]) })
    private var placeholders = Set<String>()

    public init(_ host: String, placeholderHost: String = FixtureScrubber.defaultPlaceholderHost, who: Diagnostics.Identity? = nil) {
        self.host = host
        self.placeholderHost = placeholderHost
        self.who = who
    }

    /// What was replaced, by kind, for the recording's notes (counts only, never the values), in a fixed order.
    public var counts: [(kind: String, count: Int)] {
        Kind.allCases.compactMap { kind in maps[kind]!.isEmpty ? nil : (kind.rawValue, maps[kind]!.count) }
    }

    // MARK: Learning

    /// Notes the identifiers in one document's fields (by `name`'s kind: XML, JSON, IppText, snmpwalk).
    public func learn(_ name: String, _ text: String) {
        switch Self.kindOf(name) {
        case .xml:
            for m in Self.matches(Self.xmlField, text) { learnField(m.group("n"), m.group("v")) }
        case .json:
            for m in Self.matches(Self.jsonField, text) { learnField(m.group("n"), m.group("v")) }
        case .ipp:
            for m in Self.matches(Self.ippLine, text) {
                let attribute = m.group("n"), value = m.group("v").trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if attribute == "printer-device-id" {
                    for sn in Self.matches(Self.deviceIdSerial, value) { learnField("SerialNumber", sn.group("v")) }
                } else {
                    learnField(attribute, value)
                }
            }
        case .snmp:
            for m in Self.matches(Self.snmpString, text) where m.group("oid").hasPrefix(Self.prtGeneralSerialNumber) {
                learnField("SerialNumber", m.group("v"))
            }
        case .other:
            break
        }
    }

    private func learnField(_ field: String, _ raw: String) {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // "N/A", "none", "0": nothing that identifies anyone, and too common to replace wherever it appears.
        let category = Self.category(field)
        if value.count < 4 || (!value.contains(where: \.isNumber) && category != .host) { return }
        switch category {
        case .serial: _ = map(.serial, value)
        case .uuid: _ = map(.uuid, value.replacingOccurrences(of: "urn:uuid:", with: "", options: .caseInsensitive))
        case .mac: _ = map(.mac, value)
        case .host where !value.contains(" "): _ = map(.host, value)
        default: break
        }
    }

    // MARK: Scrubbing

    /// One document with every identifier replaced (see the class summary). Call after `learn` on all of them.
    public func scrub(_ name: String, _ input: String) -> String {
        var text = input
        let kind = Self.kindOf(name)
        // What a person typed, in its own field.
        switch kind {
        case .xml: text = Self.replace(text, Self.xmlField) { Self.retype($0, Self.typed($0.group("n"))) }
        case .json: text = Self.replace(text, Self.jsonField) { Self.retype($0, Self.typed($0.group("n"))) }
        case .ipp: text = Self.replace(text, Self.ippLine) { Self.retype($0, Self.typedIpp($0.group("n"))) }
        case .snmp: text = Self.replace(text, Self.snmpString) { Self.retype($0, Self.typedSnmp($0.group("oid"))) }
        case .other: break
        }

        // Versions (firmware 6.28.3.30-…, revisions) are set aside so no address pattern takes them, and put back at the end.
        var versions: [String] = []
        let aside: (Match) -> String = { m in
            guard Self.isVersion(m.group("n")), !m.group("v").contains("://") else { return m.value }
            versions.append(m.group("v"))
            return m.swap("v", "\u{1}\(versions.count - 1)\u{1}")
        }
        switch kind {
        case .xml: text = Self.replace(text, Self.xmlField, aside)
        case .json: text = Self.replace(text, Self.jsonField, aside)
        case .ipp: text = Self.replace(text, Self.ippLine, aside)
        default: break
        }

        // Identifiers learnt from the fields, wherever they appear (longest first, whole tokens only).
        for learnt in [Kind.uuid, .serial, .mac, .host] {
            for (from, to) in maps[learnt]!.values.sorted(by: { $0.from.count > $1.from.count }) where from.caseInsensitiveCompare(to) != .orderedSame {
                text = Self.replaceAll(text, #"(?<![A-Za-z0-9])"# + NSRegularExpression.escapedPattern(for: from) + #"(?![A-Za-z0-9])"#, to)
                if learnt == .mac, let hex = Self.hexOnly(from), let toHex = Self.hexOnly(to) { // also written as bare or spaced hex (SNMP)
                    let pairs = stride(from: 0, to: 12, by: 2).map { String(Array(hex)[$0..<$0 + 2]) }
                    text = Self.replaceAll(text, #"(?<![0-9A-Fa-f])"# + pairs.joined(separator: #"[\s:-]?"#) + #"(?![0-9A-Fa-f])"#, toHex)
                }
            }
        }

        // The patterns, for whatever no field named.
        if let user = who?.userName, user.count >= 3 { text = Self.replaceAll(text, #"\b"# + NSRegularExpression.escapedPattern(for: user) + #"\b"#, "user") }
        if let pc = who?.machineName, pc.count >= 3 { text = Self.replaceAll(text, #"\b"# + NSRegularExpression.escapedPattern(for: pc) + #"\b"#, "pc") }
        text = Self.replace(text, Self.email) { _ in "user@example.com" }
        text = Self.replace(text, Self.urlHost) { $0.group("s") + self.hostOrAddress($0.group("h")) }
        text = Self.replace(text, Self.localName) { self.map(.host, $0.value) }
        text = Self.replace(text, Self.uuidPattern) { self.map(.uuid, $0.value) }
        text = Self.replace(text, Self.macPattern) { self.map(.mac, $0.value) }
        text = Self.replace(text, Self.ipv6) { self.map(.ip6, $0.value) }
        text = Self.replace(text, Self.ipv4) { self.map(.ip, $0.value) }
        text = Self.replace(text, Self.hpHostName) { self.map(.host, $0.value) }
        text = Self.replace(text, Self.labelledSerial) { $0.swap("v", self.map(.serial, $0.group("v"))) }
        text = Self.replace(text, Self.bracketId) { $0.swap("v", self.map(.bracket, $0.group("v"))) }
        if Self.addressFamily(host) == nil {
            text = Self.replaceAll(text, #"(?<![\w.-])"# + NSRegularExpression.escapedPattern(for: host) + #"(?![\w-])"#, placeholderHost)
        }
        return Self.replace(text, Self.held) { versions[Int($0.group("i")) ?? 0] }
    }

    private static func isVersion(_ field: String) -> Bool {
        let f = field.lowercased()
        return f.contains("version") || f.contains("revision") || (f.contains("firmware") && !f.contains("uri"))
    }

    private func hostOrAddress(_ h: String) -> String {
        let bare = h.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare.caseInsensitiveCompare(host) == .orderedSame { return placeholderHost }
        switch Self.addressFamily(bare) {
        case .v6?: return "[\(map(.ip6, bare))]"
        case .v4?: return map(.ip, bare)
        case nil: return map(.host, h)
        }
    }

    /// The stand-in for `value`: the same one every time; placeholders and documentation values stay.
    private func map(_ kind: Kind, _ value: String) -> String {
        if kind == .ip || kind == .host, value.caseInsensitiveCompare(host) == .orderedSame { return placeholderHost }
        if placeholders.contains(value.lowercased()) || kept(kind, value) { return value }
        let key = value.lowercased()
        if let known = maps[kind]![key] { return known.to }
        let n = maps[kind]!.count + 1
        let stand: String
        switch kind {
        case .serial:
            let digits = String(n)
            stand = "SN" + String(repeating: "0", count: max(0, max(4, value.count - 2) - digits.count)) + digits
        case .uuid: stand = "00000000-0000-4000-8000-" + Self.padded(String(n), 12)
        case .mac: stand = Self.fakeMac(value, n)
        case .ip: stand = n < 200 ? "192.0.2.\(n + 20)" : "198.51.100.\(n % 250 + 1)"
        case .ip6: stand = "2001:db8::" + String(n, radix: 16)
        case .host:
            stand = value.lowercased().hasSuffix(".local") ? "printer-\(n).local" : value.contains(".") ? "printer-\(n).example" : "printer-\(n)"
        case .bracket: stand = Self.padded(String(n, radix: 16, uppercase: true), 6)
        }
        maps[kind]![key] = (value, stand)
        placeholders.insert(stand.lowercased())
        return stand
    }

    /// Not an identifier: loopback, unspecified, masks, the documentation ranges, versions that look like addresses.
    private func kept(_ kind: Kind, _ value: String) -> Bool {
        switch kind {
        case .ip:
            return ["127.", "0.", "255.", "192.0.2.", "198.51.100.", "203.0.113."].contains { value.hasPrefix($0) } || value == placeholderHost
        case .ip6:
            return value == "::" || value == "::1" || value.lowercased().hasPrefix("2001:db8:")
        case .mac:
            let upper = value.uppercased()
            return upper.hasPrefix("00:00:5E:00:53") || upper.hasPrefix("00-00-5E-00-53") || ["000000000000", "FFFFFFFFFFFF"].contains(Self.hexOnly(value) ?? "")
        case .uuid:
            return value.hasPrefix("00000000-0000-")
        case .host:
            let lower = value.lowercased()
            return lower == placeholderHost.lowercased() || lower.hasSuffix(".example") || lower == "localhost"
        default:
            return false
        }
    }

    private static func fakeMac(_ value: String, _ n: Int) -> String {
        let separator = value.contains(":") ? ":" : value.contains("-") ? "-" : value.contains(" ") ? " " : ""
        let mac = ["00", "00", "5E", "00", "53", Self.padded(String(n % 256, radix: 16, uppercase: true), 2)].joined(separator: separator)
        return value.contains(where: \.isLowercase) ? mac.lowercased() : mac
    }

    private static func padded(_ digits: String, _ width: Int) -> String {
        String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    private static func hexOnly(_ mac: String) -> String? {
        let hex = String(mac.filter(\.isHexDigit)).uppercased()
        return hex.count == 12 ? hex : nil
    }

    private enum Family { case v4, v6 }

    /// An IPv4 address (four numbers up to 255) or an IPv6 one (hex groups and colons, a zone after %); nil for a name.
    private static func addressFamily(_ text: String) -> Family? {
        let h = text.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = h.split(separator: ".", omittingEmptySubsequences: false)
        if parts.count == 4, parts.allSatisfy({ !$0.isEmpty && $0.count <= 3 && $0.allSatisfy(\.isASCIIDigit) && Int($0)! <= 255 }) { return .v4 }
        let address = h.split(separator: "%", maxSplits: 1).first.map(String.init) ?? h
        if address.contains(":"), address.filter({ $0 == ":" }).count >= 2,
           address.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) { return .v6 }
        return nil
    }

    /// A typed value replaced by `word`; an empty one stays empty.
    private static func retype(_ m: Match, _ word: String?) -> String {
        guard let word, !m.group("v").trimmingCharacters(in: .whitespaces).isEmpty else { return m.value }
        return m.swap("v", word)
    }

    // MARK: Fields

    private enum DocKind { case other, xml, json, ipp, snmp }

    private static func kindOf(_ name: String) -> DocKind {
        let n = name.lowercased()
        if n.hasSuffix(".ipp.txt") { return .ipp }
        if n.hasSuffix(".xml") { return .xml }
        if n.hasSuffix(".json") { return .json }
        if n.hasSuffix(".txt") && n.contains("snmp") { return .snmp }
        return .other
    }

    private enum Field { case none, serial, uuid, mac, host, name, place, person, mail, job, network }

    /// What an XML element, JSON key or IPP attribute holds, from its name (any case, any prefix).
    private static func category(_ field: String) -> Field {
        let f = field.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "").lowercased()
        if f.hasSuffix("serialnumber") || ["serial", "serialnum", "printerserialnumber"].contains(f) { return .serial }
        if f.hasSuffix("uuid") { return .uuid }
        if f.hasSuffix("macaddress") || f.hasSuffix("hardwareaddress") || f == "mac" { return .mac }
        if f.hasSuffix("hostname") || f.hasSuffix("domainname") || f == "fqdn" { return .host }
        if f.contains("email") { return .mail }
        if f.hasSuffix("username") || ["owner", "jobowner", "userid", "contact", "contactname", "username", "jobowneruser", "personname"].contains(f) {
            return .person
        }
        if f.hasSuffix("jobname") || ["documentname", "filename"].contains(f) { return .job }
        if ["ssid", "networkname", "wirelessnetworkname"].contains(f) || f.hasSuffix("ssid") { return .network }
        if ["location", "devicelocation", "printerlocation", "geolocation", "printergeolocation"].contains(f) { return .place }
        if ["friendlyname", "devicename", "computername", "bonjourservicename", "printerdnssdname", "printername", "printerinfo", "assetnumber",
            "printerorganization", "printerorganizationalunit", "devicedescription"].contains(f) { return .name }
        return .none
    }

    /// The word that replaces a typed value, or nil for a field that isn't typed by a person.
    private static func typed(_ field: String) -> String? {
        switch category(field) {
        case .name: "Printer"
        case .place: "Location"
        case .person: "user"
        case .mail: "user@example.com"
        case .job: "Job"
        case .network: "Network"
        default: nil
        }
    }

    private static func typedIpp(_ attribute: String) -> String? {
        switch attribute {
        case "printer-geo-location": "geo:0,0"
        case "printer-make-and-model", "printer-device-id": nil
        case "job-originating-user-name", "requesting-user-name": "user"
        case "job-name", "document-name-supplied": "Job"
        default: typed(attribute)
        }
    }

    private static let sysContact = "1.3.6.1.2.1.1.4.", sysName = "1.3.6.1.2.1.1.5.", sysLocation = "1.3.6.1.2.1.1.6."
    static let prtGeneralSerialNumber = "1.3.6.1.2.1.43.5.1.1.17."
    private static let prtGeneralCurrentOperator = "1.3.6.1.2.1.43.5.1.1.20.", prtGeneralServicePerson = "1.3.6.1.2.1.43.5.1.1.21."
    private static let prtGeneralPrinterName = "1.3.6.1.2.1.43.5.1.1.16."

    private static func typedSnmp(_ oid: String) -> String? {
        if oid.hasPrefix(sysContact) || oid.hasPrefix(prtGeneralCurrentOperator) || oid.hasPrefix(prtGeneralServicePerson) { return "user" }
        if oid.hasPrefix(sysName) { return "printer" }
        if oid.hasPrefix(sysLocation) { return "Location" }
        if oid.hasPrefix(prtGeneralPrinterName) { return "Printer" }
        return nil
    }

    /// An SNMP object that holds what a person typed or a serial number, so it's kept as text for this scrubbing to read.
    static func holdsText(_ oid: String) -> Bool { oid.hasPrefix(prtGeneralSerialNumber) || typedSnmp(oid) != nil }

    // MARK: Patterns

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // The patterns are fixed and valid.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    // An element with text only: <dd:SerialNumber attr="…">CN…</dd:SerialNumber>.
    private static let xmlField = regex(#"<(?<p>(?:[\w.-]+:)?(?<n>[A-Za-z][\w.-]*))(?:\s[^>]*)?>(?<v>[^<]*)</\k<p>\s*>"#)
    private static let jsonField = regex(#""(?<n>[A-Za-z][\w-]*)"\s*:\s*"(?<v>(?:[^"\\]|\\.)*)""#)
    private static let ippLine = regex(#"^(?<n>[a-z][a-z0-9-]*) (?<s>[A-Za-z]+) (?<v>.*?)\r?$"#, .anchorsMatchLines)
    private static let snmpString = regex(#"^\.(?<oid>[\d.]+) = STRING: "(?<v>.*)"\r?$"#, .anchorsMatchLines)
    // IEEE 1284 device ID: SN:CN123…; or SERN:…;
    private static let deviceIdSerial = regex(#"(?:^|;)\s*(?:SN|SERN|SERIALNUMBER):(?<v>[^;]{3,})"#, .caseInsensitive)
    private static let held = regex(#"\x{01}(?<i>\d+)\x{01}"#)
    private static let email = regex(#"[\w.+-]+@[\w-]+(?:\.[\w-]+)+"#)
    private static let urlHost = regex(#"(?<s>\b(?:https?|ipps?|wss?|socket|lpd)://(?:[^@/\s]*@)?)(?<h>\[[0-9A-Fa-f:.%\w]+\]|[^/\s:?#\[\]"'<>]+)"#)
    private static let localName = regex(#"(?<![\w.-])[A-Za-z0-9][\w-]*(?:\.[\w-]+)*\.local\b"#)
    private static let uuidPattern = regex(#"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b"#)
    private static let macPattern = regex(#"(?<![\w:-])[0-9A-Fa-f]{2}(?:([:-])[0-9A-Fa-f]{2})(?:\1[0-9A-Fa-f]{2}){4}(?![\w:-])"#)
    // Has "::" or at least five groups, so times (12:34:56) are left alone; the zone (%12) goes with it.
    private static let ipv6 = regex(#"(?<![\w:.])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){5})[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?::(?:\d{1,3}\.){3}\d{1,3})?(?:%\w+)?(?![\w:])"#)
    // As Report a problem: a dotted quad after "v"/"version", or all of one digit (1.0.7.0), is a version and stays; so is one
    // running on into a word or a hyphen (HP's firmware 6.28.3.30-202606…).
    private static let ipv4 = regex(#"(?<![\d.])(?<!\b(?i:v|ver|version)[\s=:]{0,8})(?!\d\.\d\.\d\.\d(?!\d))(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\w-]|\.\d)"#)
    private static let hpHostName = regex(#"\b(?:NPI|HP)[0-9A-F]{6}\b"#, .caseInsensitive)
    private static let labelledSerial = regex(#"\b(?:serial(?:\s*number)?|s/n|SN|SERN)\s*[:=#]\s*(?<v>[A-Za-z0-9-]{4,})"#, .caseInsensitive)
    // HP's network names end in the last six hex digits of the MAC address: "HP LaserJet MFP M234dw [A1B2C3]" or "(A1B2C3)".
    private static let bracketId = regex(#"[\[(](?<v>[0-9A-Fa-f]{6})[\])]"#)

    /// One match, with its named groups (.NET's Match).
    struct Match {
        let result: NSTextCheckingResult
        let text: NSString

        var value: String { text.substring(with: result.range) }

        func group(_ name: String) -> String {
            let range = result.range(withName: name)
            return range.location == NSNotFound ? "" : text.substring(with: range)
        }

        /// The match with one group's text replaced (the rest of the match kept as it was).
        func swap(_ name: String, _ replacement: String) -> String {
            let range = result.range(withName: name)
            guard range.location != NSNotFound else { return value }
            let whole = value as NSString
            let start = range.location - result.range.location
            return whole.substring(to: start) + replacement + whole.substring(from: start + range.length)
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> [Match] {
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { Match(result: $0, text: ns) }
    }

    /// Each match replaced by what `with` returns for it.
    static func replace(_ text: String, _ regex: NSRegularExpression, _ with: (Match) -> String) -> String {
        let ns = text as NSString
        var out = ""
        var at = 0
        for result in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: at, length: result.range.location - at))
            out += with(Match(result: result, text: ns))
            at = result.range.location + result.range.length
        }
        return out + ns.substring(from: at)
    }

    /// Every match of `pattern` (any case) replaced by `literal`.
    private static func replaceAll(_ text: String, _ pattern: String, _ literal: String) -> String {
        replace(text, regex(pattern, .caseInsensitive)) { _ in literal }
    }
}
