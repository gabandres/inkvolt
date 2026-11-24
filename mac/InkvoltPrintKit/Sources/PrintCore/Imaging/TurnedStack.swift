import Foundation

/// Two-sided scanning on a one-sided feeder (roadmap 4.1, the Windows app's `TurnedStack`): the fronts of a stack, then the
/// stack turned over and its backs, put together in page order. Turned over, the stack's last sheet comes first, so the backs
/// arrive last sheet first (`backsReversed`); on a scanner whose output tray reverses the stack itself they arrive first sheet
/// first, which the review can switch to. When the counts differ (a sheet fed twice, one left behind) the backs are matched
/// from the end they began at, the sheets past it keep one side, and the review says so.
public enum TurnedStack {
    public static let backsReversed = true

    /// The pages in order, as indexes into the fronts (0 to `fronts` − 1) followed by the backs (`fronts` on), each front
    /// followed by its back. Backs with no front left over go at the end, as scanned. Negative counts are taken as none.
    /// - Parameter reversed: the backs came last sheet first (the usual way: `backsReversed`).
    public static func order(_ fronts: Int, _ backs: Int, reversed: Bool = backsReversed) -> [Int] {
        let (fronts, backs) = (max(0, fronts), max(0, backs))
        var backOf = [Int](repeating: -1, count: fronts) // the back scanned for each front, or -1
        let pairs = pairs(fronts, backs, reversed: reversed)
        for (front, back) in pairs { backOf[front] = back }
        var order: [Int] = []
        order.reserveCapacity(fronts + backs)
        for f in 0..<fronts {
            order.append(f)
            if backOf[f] >= 0 { order.append(fronts + backOf[f]) }
        }
        for j in pairs.count..<backs { order.append(fronts + j) }
        return order
    }

    /// The sheets: each front (0 to `fronts` − 1) with the back scanned for it (0 to `backs` − 1). Reversed, the first back is
    /// the last front's; fronts or backs past the shorter pass have no other side here.
    public static func pairs(_ fronts: Int, _ backs: Int, reversed: Bool = backsReversed) -> [(front: Int, back: Int)] {
        let paired = max(0, min(fronts, backs))
        return (0..<paired).map { j in (reversed ? fronts - 1 - j : j, j) }
    }

    /// The other side of each separator sheet (a patch code sheet), which belongs to the sheet: indexes as `order`'s (fronts,
    /// then backs as scanned), sorted. Only the real sheets count (`pairs`, never a guess from page positions); when the
    /// counts differ the pairing isn't sure, so only an other side that looks blank is taken. Nil when `sheet` or `blank`
    /// doesn't hold one flag a page.
    public static func separatorBacks(_ fronts: Int, _ backs: Int, reversed: Bool, sheet: [Bool], blank: [Bool]) -> [Int]? {
        guard fronts >= 0, backs >= 0, sheet.count == fronts + backs, blank.count == fronts + backs else { return nil }
        let sure = fronts == backs
        var result = Set<Int>()
        for (f, j) in pairs(fronts, backs, reversed: reversed) {
            let b = fronts + j
            if sheet[f] && !sheet[b] && (sure || blank[b]) { result.insert(b) }
            if sheet[b] && !sheet[f] && (sure || blank[f]) { result.insert(f) }
        }
        return result.sorted()
    }

    /// The pages (all the fronts, then all the backs, as scanned) put in order: `order` applied.
    public static func arrange<T>(_ fronts: [T], _ backs: [T], reversed: Bool = backsReversed) -> [T] {
        order(fronts.count, backs.count, reversed: reversed).map { $0 < fronts.count ? fronts[$0] : backs[$0 - fronts.count] }
    }

    /// The same pages in the other back order, wherever they are now: the stack's pages still in `current` (others the review
    /// deleted stay deleted, pages from other scans stay where they are) go into the places they hold now, in `arrange`'s
    /// order with `reversed`.
    public static func rearrange<T: Hashable>(_ current: [T], _ fronts: [T], _ backs: [T], reversed: Bool) -> [T] {
        inPlaces(current, arrange(fronts, backs, reversed: reversed))
    }

    /// `current` with the pages of `order` it holds put in that order, in the places they hold now; every other page stays
    /// where it is. (Undo puts a stack back as scanned with its fronts, then its backs.) A page `current` holds twice (a
    /// recovery list's hand edit) takes its place in `order` once; its other places keep it as it is.
    public static func inPlaces<T: Hashable>(_ current: [T], _ order: [T]) -> [T] {
        let here = Set(current)
        var seen = Set<T>()
        let wanted = order.filter { here.contains($0) && seen.insert($0).inserted }
        let mine = Set(wanted)
        var next = 0
        return current.map { page in
            guard mine.contains(page), next < wanted.count else { return page }
            defer { next += 1 }
            return wanted[next]
        }
    }
}
