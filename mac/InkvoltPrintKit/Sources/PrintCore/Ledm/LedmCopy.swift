import Foundation

/// Where a printer's copy start setting sits in its CopyConfigDyn (local names below the root) and the value that starts a copy.
public struct CopyStart: Equatable, Sendable {
    public var path: [String]
    public var value: String
}

/// HP LEDM's copy settings (`/DevMgmt/CopyConfigCap.xml`, `/DevMgmt/CopyConfigDyn.xml`, namespace `…/ledm/cpcfgdyn/2008/05/05`
/// as the LaserJet MFP M234dw's DiscoveryTree lists them; Windows' `LedmCopy`), driven the way LEDM's other writable settings
/// are: the Cap names a writable element (`access="readWrite"`, its place in `elementXPath`, its choices as child elements),
/// and a PUT of a partial Dyn document built from the printer's own element names and namespaces changes it.
///
/// **Only the start is written.** CopyConfigDyn holds the copy settings the printer keeps for its control panel (copies,
/// two-sided and the like); writing them for one copy would change everyone's walk-up defaults, and putting them back means
/// knowing when the copy has finished, which nothing captured shows. So the printer copies with its own settings.
///
/// **Unconfirmed.** No CopyConfigCap or CopyConfigDyn has been captured: the fixtures hold only the DiscoveryTree that lists
/// them. The start's element names (`startNames`) and values (`startValues`) are Windows' assumption, ported as they are and
/// kept here so a recording corrects them in one place. Only an explicit command counts as a start (a state such as
/// `processing` doesn't). A printer whose documents don't match gets nothing (`read` returns nil): nothing is sent on a guess.
public enum LedmCopy {
    public static let capResource = "ledm:hpLedmCopyConfigCap"
    public static let dynResource = "ledm:hpLedmCopyConfigDyn"

    /// Bounds on what a printer's Cap may hold: choices read per entry, a choice's length, steps in an `elementXPath`.
    private static let maxChoices = 32, maxValueLength = 64, maxPathDepth = 12, maxXPathLength = 512

    /// The Dyn element (local name) that starts a copy. Assumed: see above.
    static let startNames = ["CopyState", "StartCopy"]

    /// The Cap choices that are a command to start (compared ignoring case; the printer's own spelling is written). Assumed.
    static let startValues = ["start", "startCopy"]

    /// The tree lists both copy documents.
    public static func listed(_ tree: DiscoveryTree) -> Bool { tree.uri(for: capResource) != nil && tree.uri(for: dynResource) != nil }

    /// The printer's copy start, or nil when it can't be started from here: no Cap, no Cap entry marked `readWrite` for a
    /// start element, no start command among its choices, or no such element where the entry says it is in the Dyn.
    public static func read(_ dyn: XmlElement, _ cap: XmlElement?) -> CopyStart? {
        guard let cap else { return nil }
        for entry in descendants(cap) {
            guard entry.attributes["access"] == "readWrite", let path = locate(entry, dyn), let last = path.last, startNames.contains(last) else { continue }
            let choices = entry.children.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { (1...maxValueLength).contains($0.count) }.prefix(maxChoices)
            let start = startValues.lazy.compactMap { v in choices.first { $0.caseInsensitiveCompare(v) == .orderedSame } }.first
            if let start { return CopyStart(path: path, value: start) }
        }
        return nil
    }

    /// The PUT body that starts one copy: the start element alone, in the printer's own names and namespaces (from `dyn`,
    /// read again just before sending). Throws `CopyShapeChanged` when the Dyn no longer has the start where it was found.
    public static func build(_ dyn: XmlElement, _ start: CopyStart) throws -> String {
        var sources: [XmlElement] = []
        var node = dyn
        for name in start.path {
            guard let next = node.kid(name) else { throw CopyShapeChanged() }
            sources.append(next)
            node = next
        }
        guard let leafSource = sources.last else { throw CopyShapeChanged() }
        var built = LedmNode(like: leafSource, text: start.value)
        for source in sources.dropLast().reversed() {
            var parent = LedmNode(like: source)
            parent.children = [built]
            built = parent
        }
        var root = LedmNode(like: dyn)
        root.children = [built]
        return root.document()
    }

    /// Every element below `root`, in document order.
    private static func descendants(_ root: XmlElement) -> [XmlElement] {
        var found: [XmlElement] = []
        var stack: [XmlElement] = root.children.reversed()
        while let e = stack.popLast() {
            found.append(e)
            stack.append(contentsOf: e.children.reversed())
        }
        return found
    }

    /// The Dyn element a Cap entry is about, as local names below the root, or nil when it isn't there. With an
    /// `elementXPath`, every step is followed (prefixes dropped; the root's own name may lead; a position `[n]` picks the n-th
    /// of that name, other predicates aren't understood); without one, the root's child named like the entry less a trailing
    /// `Support` (`CopyStateSupport` → `CopyState`). The element must hold a value, not more elements, and be the one the PUT
    /// built by `build` reaches (it follows the first of each name).
    static func locate(_ capEntry: XmlElement, _ root: XmlElement) -> [String]? {
        var steps: [String]
        var positions: [Int] = []
        if let xpath = capEntry.attributes["elementXPath"] {
            guard !xpath.isEmpty, xpath.count <= maxXPathLength else { return nil }
            let trimmed = xpath.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count <= maxPathDepth + 1 else { return nil }
            var names: [String] = []
            for part in parts {
                guard case let (name, position)? = step(String(part)) else { return nil }
                names.append(name)
                positions.append(position)
            }
            if names.count > 1 && names[0] == root.name {
                names.removeFirst()
                positions.removeFirst()
            }
            steps = names
        } else {
            let name = capEntry.name
            steps = [name.hasSuffix("Support") && name.count > "Support".count ? String(name.dropLast("Support".count)) : name]
            positions.append(1)
        }
        guard !steps.isEmpty, steps.count <= maxPathDepth else { return nil }

        var node: XmlElement? = root
        for (i, name) in steps.enumerated() {
            // Only the first of each name: the PUT couldn't reach a second one.
            guard let current = node, positions[i] == 1 else { return nil }
            node = current.kid(name)
        }
        guard let node, node.children.isEmpty else { return nil }
        return steps
    }

    /// `prefix:Name[n]` → (Name, n); a position defaults to 1; anything else (another predicate, an empty name) → nil.
    private static func step(_ raw: String) -> (String, Int)? {
        var part = raw
        var position = 1
        if let bracket = part.firstIndex(of: "[") {
            guard part.hasSuffix("]"), let n = Int(part[part.index(after: bracket)..<part.index(before: part.endIndex)]), n >= 1 else { return nil }
            position = n
            part = String(part[..<bracket])
        }
        let name = (part.firstIndex(of: ":").map { String(part[part.index(after: $0)...]) } ?? part).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy(isNameChar) else { return nil }
        return (name, position)
    }

    /// As .NET's `XmlConvert.IsNCNameChar`, near enough for element names: letters, digits, `_`, `-`, `.`.
    private static func isNameChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" || c == "-" || c == "." }
}

/// The printer's copy settings no longer have the shape the start was found in.
public struct CopyShapeChanged: Error {}
