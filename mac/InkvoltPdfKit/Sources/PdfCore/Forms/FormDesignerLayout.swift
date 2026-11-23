import Foundation
import PrintCore

/// How several fields line up with the first one picked: by an edge, or by their centers (in a column) or middles (in a
/// row), as the page is shown.
public enum DesignAlign: Sendable { case left, right, top, bottom, center, middle }

/// Which side several fields take from the first one picked.
public enum DesignSameSize: Sendable { case width, height, both }

/// Spacing several fields evenly: left to right, or top to bottom, as the page is shown.
public enum DesignSpread: Sendable { case across, down }

/// A page as the arrangements see it: its size in points (unturned by the view) and the view's turn (0, 90, 180, 270), so
/// "left" is the page as shown. (The Mac's designer takes the page's size with each press instead.)
public struct DesignPage: Equatable, Sendable {
    public var width: Double
    public var height: Double
    public var rotation: Int

    public init(_ width: Double, _ height: Double, rotation: Int = 0) {
        self.width = width
        self.height = height
        self.rotation = rotation
    }
}

/// Calculated fields (roadmap 4.12): the panel's Calculate list and what a pick does.
extension FormDesignRules {
    /// The Calculate list (parallel to `calcLabels`): not calculated, sum, product, average, minimum, maximum, simplified
    /// field notation.
    public static let calcKinds: [CalcKind] = [.notCalculated, .sum, .product, .average, .minimum, .maximum, .notation]

    /// The Calculate list's labels, in the interface's language.
    public static var calcLabels: [String] {
        [loc("Not calculated"), loc("Sum (+)"), loc("Product (×)"), loc("Average"), loc("Minimum"), loc("Maximum"),
         loc("Simplified field notation")]
    }

    /// The entry of `calcKinds` a field's calculation is, or -1 for a custom script (the list then shows one more entry,
    /// "kept").
    public static func calcIndex(_ f: DesignField) -> Int {
        guard let c = f.calculation else { return 0 }
        if c.kind == .custom { return -1 }
        return calcKinds.firstIndex(of: c.kind) ?? 0
    }

    /// The fields a calculation of `f` can read: every other text field, combo box and list box (a name once; radio
    /// buttons' and check boxes' values aren't numbers), by name in the person's language's order.
    public static func calcSources(_ f: DesignField, _ fields: [DesignField]) -> [String] {
        var seen = Set<String>(), names: [String] = []
        for o in fields where o.name != f.name && (o.kind == .text || o.kind == .comboBox || o.kind == .listBox) {
            if seen.insert(o.name).inserted { names.append(o.name) }
        }
        return names.sorted { $0.compare($1, options: .caseInsensitive, locale: .current) == .orderedAscending }
    }

    /// The calculation picked in the panel: `kind` of the fields `picked` (in the form's order), or the notation typed. A
    /// field can't use its own value; a notation can only name the form's fields. Switching from a list of fields to the
    /// notation starts the notation with them (added, "a + b"), and back.
    public static func withCalculation(_ f: DesignField, _ kind: CalcKind, _ picked: [String], _ notation: String,
                                       _ fields: [DesignField]) throws -> DesignField {
        if f.calculation?.kind == .custom {
            throw DesignRefusal(loc("This field's calculation is a script of the form's own: it stays as it is."))
        }
        if kind == .notCalculated { return f.with { $0.calculation = nil } }
        let names = Set(fields.map(\.name))
        let itself = DesignRefusal(loc("A field can't use its own value in its calculation."))
        if kind == .notation {
            var text = notation.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty && !picked.isEmpty { text = picked.map(FormCalculations.nameInNotation).joined(separator: " + ") }
            _ = try FormCalculations.compile(text) // nothing typed is refused too
            let used = FormCalculations.notationFields(text)
            if used.contains(f.name) { throw itself }
            if let unknown = used.first(where: { n in !names.contains(n) && !names.contains { $0.hasPrefix(n + ".") } }) {
                throw DesignRefusal(loc("The form has no field named \"{0}\".", unknown))
            }
            return f.with { $0.calculation = FieldCalc(.notation, used, notation: text) }
        }
        let list = picked.isEmpty && f.calculation?.kind == .notation ? f.calculation?.fields ?? [] : picked
        if list.contains(f.name) { throw itself }
        var order: [String: Int] = [:]
        for (i, n) in fields.map(\.name).enumerated() where order[n] == nil { order[n] = i }
        var seen = Set<String>()
        let unique = list.filter { seen.insert($0).inserted }
        // A stable sort by the form's order (names it doesn't hold last, as picked).
        let sorted = unique.enumerated().sorted { a, b in
            let x = order[a.element] ?? Int.max, y = order[b.element] ?? Int.max
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
        return f.with { $0.calculation = FieldCalc(kind, sorted) }
    }

    /// The calculation order with the field at `index` moved by `step`; refused when it is already at that end.
    public static func movedInOrder(_ order: [String], _ index: Int, _ step: Int) throws -> [String] {
        let j = index + step
        guard order.indices.contains(index), order.indices.contains(j) else {
            throw DesignRefusal(step < 0 ? loc("This field is already filled first on its page.") : loc("This field is already filled last on its page."))
        }
        var list = order
        list.swapAt(index, j)
        return list
    }

    // MARK: Several fields

    /// `selected` (the first is the anchor, as Acrobat's: it stays where it is) lined up by `how` on the page as shown
    /// (`page`: its size and the view's turn). Only
    /// the fields on the anchor's page that aren't signed move; each stays on the page. Returns the fields that moved.
    public static func aligned(_ selected: [DesignField], _ how: DesignAlign, _ page: DesignPage) throws -> [DesignField] {
        try arranged(selected, page) { anchor, r in
            var r = r
            switch how {
            case .left: r.x = anchor.x
            case .right: r.x = anchor.right - r.width
            case .top: r.y = anchor.y
            case .bottom: r.y = anchor.bottom - r.height
            case .center: r.x = anchor.centerX - r.width / 2
            case .middle: r.y = anchor.centerY - r.height / 2
            }
            return r
        }
    }

    /// `selected` given the first one's width, height or both (as the page is shown), each keeping its top-left corner. A
    /// check box or radio button stays square, its side the one asked for.
    public static func sizedAlike(_ selected: [DesignField], _ side: DesignSameSize, _ page: DesignPage) throws -> [DesignField] {
        try arranged(selected, page, square: side) { anchor, r in
            var r = r
            if side != .height { r.width = anchor.width }
            if side != .width { r.height = anchor.height }
            return r
        }
    }

    /// `selected` spaced evenly `way`: the first and last (left to right, or top to bottom, as shown) stay, the ones
    /// between get equal gaps. Refused for fewer than three.
    public static func spread(_ selected: [DesignField], _ way: DesignSpread, _ page: DesignPage) throws -> [DesignField] {
        let movable = movable(selected)
        if movable.count < 3 { throw DesignRefusal(loc("Select three fields or more to space them evenly (⌘-click adds one).")) }
        let across = way == .across
        let shown = movable.map { (field: $0, rect: toView($0.rect, page)) }.enumerated().sorted { a, b in
            let p = across ? (a.element.rect.x, a.element.rect.y) : (a.element.rect.y, a.element.rect.x)
            let q = across ? (b.element.rect.x, b.element.rect.y) : (b.element.rect.y, b.element.rect.x)
            return p != q ? p < q : a.offset < b.offset
        }.map(\.element)
        let first = shown[0].rect, last = shown[shown.count - 1].rect
        let span = across ? last.right - first.x : last.bottom - first.y
        let total = shown.reduce(0.0) { $0 + (across ? $1.rect.width : $1.rect.height) }
        let gap = (span - total) / Double(shown.count - 1)
        var at = across ? first.right + gap : first.bottom + gap
        var moved: [DesignField] = []
        for s in shown[1..<(shown.count - 1)] {
            var to = s.rect
            if across { to.x = at } else { to.y = at }
            at += (across ? s.rect.width : s.rect.height) + gap
            if let done = placed(s.field, to, page) { moved.append(done) }
        }
        return moved
    }

    /// The selected fields an arrangement may move: on the anchor's page, not signed.
    private static func movable(_ selected: [DesignField]) -> [DesignField] {
        guard let anchor = selected.first else { return [] }
        var seen = Set<String>()
        return selected.filter { $0.pageIndex == anchor.pageIndex && !$0.signed && seen.insert($0.id).inserted }
    }

    private static func arranged(_ selected: [DesignField], _ page: DesignPage, square: DesignSameSize? = nil,
                                 _ arrange: (RectD, RectD) -> RectD) throws -> [DesignField] {
        if selected.count < 2 { throw DesignRefusal(loc("Select two fields or more (⌘-click adds one); the first one picked stays put.")) }
        let anchor = toView(selected[0].rect, page)
        var moved: [DesignField] = []
        for f in movable(selected) where f.id != selected[0].id {
            var r = arrange(anchor, toView(f.rect, page))
            if let side = square, f.kind == .checkBox || f.kind == .radio {
                let s = side == .height ? r.height : r.width
                r = RectD(r.x, r.y, s, s)
            }
            if let done = placed(f, r, page) { moved.append(done) }
        }
        return moved
    }

    /// The field at `view` (as shown), kept on the page and no smaller than the designer allows; nil when that doesn't
    /// change it.
    private static func placed(_ f: DesignField, _ view: RectD, _ page: DesignPage) -> DesignField? {
        let minSize = FormDesigner.minSize
        let (vw, vh) = RotatedView.size(page.width, page.height, page.rotation)
        let w = min(max(view.width, minSize), max(minSize, vw))
        let h = min(max(view.height, minSize), max(minSize, vh))
        let kept = RectD(min(max(view.x, 0), max(0, vw - w)), min(max(view.y, 0), max(0, vh - h)), w, h)
        let rect = RotatedView.fromView(kept, page.width, page.height, page.rotation)
        let near = abs(rect.x - f.rect.x) < 0.01 && abs(rect.y - f.rect.y) < 0.01 && abs(rect.width - f.rect.width) < 0.01
            && abs(rect.height - f.rect.height) < 0.01
        return near ? nil : f.with { $0.rect = rect }
    }

    private static func toView(_ r: RectD, _ page: DesignPage) -> RectD { RotatedView.toView(r, page.width, page.height, page.rotation) }
}
