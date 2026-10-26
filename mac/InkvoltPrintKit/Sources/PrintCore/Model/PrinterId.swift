import Foundation

/// Printer identities arrive from the network (mDNS TXT, HTTP replies), so they are untrusted text. Everything the app
/// stores or builds paths from is normalised to a GUID here.
public enum PrinterId {
    /// The printer's UUID if it is one; otherwise a stable GUID derived from its address.
    public static func normalize(_ uuid: String?, host: String) -> String {
        var raw = uuid?.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        if let r = raw, r.lowercased().hasPrefix("urn:uuid:") { raw = String(r.dropFirst(9)) }
        return raw.flatMap(guid) ?? fromHost(host)
    }

    public static func isValid(_ uuid: String?) -> Bool { uuid.flatMap(guid) != nil }

    /// Whether the device answering at `host` is the printer known as `id`, from the UUIDs it reports
    /// (`ProbeResult.reportedUuids`). Same when any of them is the id, or one the user accepted ("This is my printer", after a
    /// repair or reset gave it a new one); different when it reports UUIDs and none is; unknown when it reports none, or the
    /// id was made from the address (a printer without a UUID).
    public static func identify(_ id: String, accepted: [String] = [], host: String, reported: [String?]) -> DeviceIdentity {
        if id.caseInsensitiveCompare(fromHost(host)) == .orderedSame { return .unknown }
        let uuids = valid(reported, host: host)
        if uuids.isEmpty { return .unknown }
        let known = Set((accepted + [id]).map { normalize($0, host: host).lowercased() })
        return uuids.contains { known.contains($0.lowercased()) } ? .same : .different
    }

    /// The real UUIDs among `reported`, normalised (blank and malformed ones left out).
    public static func valid(_ reported: [String?], host: String) -> [String] {
        var seen = Set<String>()
        return reported.compactMap { $0 }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .map { normalize($0, host: host) }.filter { $0 != fromHost(host) && seen.insert($0.lowercased()).inserted }
    }

    /// mDNS announces a known printer at a new address while it's used at another (perhaps typed by the user). Move when the
    /// new address answers with the printer's UUID; never when it answers as another device. When the new address can't
    /// tell (no answer, or no UUID), keep the address in use only if it answers as the same kind of device (its model
    /// matches the announced one, or nothing was announced); otherwise move, as discovery always did.
    public static func shouldMove(_ atNew: DeviceIdentity, currentAnswers: Bool, currentModel: String?, announcedModel: String?) -> Bool {
        switch atNew {
        case .same: true
        case .different: false
        case .unknown: !(currentAnswers && sameKind(currentModel, announcedModel))
        }
    }

    /// Same model, loosely: case, spaces and punctuation ignored, and one name may extend the other ("M234dw" / "MFP M234dw").
    public static func sameKind(_ model: String?, _ announced: String?) -> Bool {
        guard let announced, !announced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true } // nothing to compare against
        guard let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        func key(_ s: String) -> String { String(s.filter { $0.isLetter || $0.isNumber }).lowercased() }
        let (a, b) = (key(model), key(announced))
        return !a.isEmpty && !b.isEmpty && (a.contains(b) || b.contains(a))
    }

    /// The Windows app's id for a printer added by address (MD5 of "printdesk-host:" + host, as a .NET Guid), so the two
    /// apps agree. The salt keeps the app's pre-rename name on purpose.
    static func fromHost(_ host: String) -> String {
        let hash = Digest.md5(Array(("printdesk-host:" + host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()).utf8))
        // .NET's Guid(byte[]) reads the first three fields little-endian.
        let ordered = [3, 2, 1, 0, 5, 4, 7, 6].map { hash[$0] } + hash[8...]
        return format(Array(ordered))
    }

    /// Safe file name for per-printer caches (never contains path characters).
    public static func fileName(_ uuid: String) -> String {
        if let g = guid(uuid) { return g.replacingOccurrences(of: "-", with: "") }
        return String(Digest.hex(Digest.sha256(Array(uuid.utf8)), uppercase: true).prefix(32))
    }

    /// A GUID in .NET's accepted forms (32 hex digits, or 8-4-4-4-12, optionally in braces or parentheses), as lower-case
    /// "D" form; nil otherwise.
    static func guid(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if (t.hasPrefix("{") && t.hasSuffix("}")) || (t.hasPrefix("(") && t.hasSuffix(")")) { t = String(t.dropFirst().dropLast()) }
        let parts = t.split(separator: "-", omittingEmptySubsequences: false)
        let digits: String
        if parts.count == 1 {
            digits = t
        } else if parts.map(\.count) == [8, 4, 4, 4, 12] {
            digits = parts.joined()
        } else {
            return nil
        }
        guard digits.count == 32, digits.allSatisfy(\.isHexDigit) else { return nil }
        var bytes: [UInt8] = []
        var i = digits.startIndex
        while i < digits.endIndex {
            let next = digits.index(i, offsetBy: 2)
            bytes.append(UInt8(digits[i..<next], radix: 16)!)
            i = next
        }
        return format(bytes)
    }

    private static func format(_ b: [UInt8]) -> String {
        let h = Array(Digest.hex(b))
        let groups: [Range<Int>] = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32]
        var parts: [String] = []
        for g in groups { parts.append(String(h[g])) }
        return parts.joined(separator: "-")
    }
}
