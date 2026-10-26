import Foundation

/// An SNMP object identifier (`1.3.6.1.2.1.1.1.0`): its arcs, ordered as SNMP walks them (lexicographically).
public struct Oid: Hashable, Comparable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public let arcs: [UInt32]

    /// Nil unless the first arc is 0, 1 or 2 (X.690 §8.19.4: the first two arcs share one subidentifier, 40 × first +
    /// second, so under 0 and 1 the second is below 40) and there are 2 to 128 arcs (RFC 2578 §3.5).
    public init?(arcs: [UInt32]) {
        guard arcs.count >= 2, arcs.count <= 128, arcs[0] <= 2, arcs[0] == 2 || arcs[1] < 40 else { return nil }
        self.arcs = arcs
    }

    /// "1.3.6.1.2.1.1.1.0" or ".1.3.6.1.2.1.1.1.0" (net-snmp's numeric form).
    public init?(_ text: String) {
        var t = Substring(text.trimmingCharacters(in: .whitespaces))
        while t.first == "." { t = t.dropFirst() }
        var arcs: [UInt32] = []
        for part in t.split(separator: ".", omittingEmptySubsequences: false) {
            guard !part.isEmpty, part.allSatisfy(\.isASCIIDigit), let arc = UInt32(part) else { return nil }
            arcs.append(arc)
        }
        self.init(arcs: arcs)
    }

    /// For constants written in the code; a bad literal is a programming error.
    public init(stringLiteral value: String) {
        guard let oid = Oid(value) else { preconditionFailure("Not an object identifier: \(value)") }
        self = oid
    }

    public var count: Int { arcs.count }

    public func appending(_ more: UInt32...) -> Oid { appending(more) }

    public func appending(_ more: [UInt32]) -> Oid {
        guard let oid = Oid(arcs: arcs + more) else { preconditionFailure("SNMP allows at most 128 arcs.") }
        return oid
    }

    /// Strictly under `prefix` (longer, and starting with all of its arcs).
    public func isUnder(_ prefix: Oid) -> Bool { arcs.count > prefix.arcs.count && arcs.starts(with: prefix.arcs) }

    /// The arcs after `prefix` (a table row's index), or nil when this isn't under it.
    public func after(_ prefix: Oid) -> [UInt32]? { isUnder(prefix) ? Array(arcs[prefix.arcs.count...]) : nil }

    public static func < (lhs: Oid, rhs: Oid) -> Bool {
        for (a, b) in zip(lhs.arcs, rhs.arcs) where a != b { return a < b }
        return lhs.arcs.count < rhs.arcs.count
    }

    public var description: String { arcs.map(String.init).joined(separator: ".") }
}

extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
