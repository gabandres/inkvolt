import Foundation

/// Text that was taken out in one place and put back in another: old words [oldStart, oldEnd) are new words
/// [newStart, newEnd), and `inner` is the diff of the two (indices in the whole documents), so a word edited on the way is
/// a change inside the move (the Windows app's `CompareMove`).
public struct CompareMove: Sendable, Equatable {
    public var oldStart: Int
    public var oldEnd: Int
    public var newStart: Int
    public var newEnd: Int
    public var inner: [DiffOp]
}

/// Finds moved text in a word diff (the Windows app's `CompareMoves`). A diff can only say removed and inserted, so runs
/// of removed words are looked for in runs of inserted ones: the longest common stretches first (each word used once),
/// stretches a few edited words apart joined. The diff may have matched a common word of the moved text to the same word
/// elsewhere ("the", a final "."), so a stretch grows over a few such words when more of it follows, and over marks at
/// its ends. A stretch counts when it is long enough to mean something (`minWords` words with letters or digits), or is
/// everything removed and inserted there (`minWholeRunWords`). What was removed and inserted at the same place is a
/// rewording, never a move. Bounded: past `maxWords` removed or inserted words, or `maxWork` word comparisons, no more is
/// looked for.
public enum CompareMoves {
    public static let minWords = 6
    public static let minWholeRunWords = 3

    /// Stretches this few words apart on both sides are one move, the words between them edited.
    private static let maxInnerGap = 12

    private static let seed = 3            // words that must match for a stretch to be looked at
    private static let maxGrowOver = 3     // unchanged words in a row a stretch grows over
    private static let maxSeedPlaces = 32  // places kept for one seed (boilerplate repeats)
    public static let maxWords = 200_000
    public static let maxWork = 40_000_000

    private struct Stretch {
        var old: Int
        var new: Int
        var length: Int
    }

    private struct SeedKey: Hashable {
        var a: Int, b: Int, c: Int
    }

    public static func find(_ ops: [DiffOp], _ oldKeys: [String], _ newKeys: [String], cancel: CancelToken? = nil) throws -> [CompareMove] {
        try cancel?.check()
        var deleted = 0, inserted = 0
        for op in ops {
            if op.kind == .delete { deleted += op.length } else if op.kind == .insert { inserted += op.length }
        }
        if deleted == 0 || inserted == 0 || deleted > maxWords || inserted > maxWords { return [] }

        // Which unchanged stretch each removed or inserted word follows (the same one: the same place), -1 when unchanged.
        var oldPlace = [Int](repeating: -1, count: oldKeys.count)
        var newPlace = [Int](repeating: -1, count: newKeys.count)
        var place = 0
        for op in ops {
            switch op.kind {
            case .equal: place += 1
            case .delete: for k in op.a..<op.a + op.length where k < oldPlace.count { oldPlace[k] = place }
            case .insert: for k in op.b..<op.b + op.length where k < newPlace.count { newPlace[k] = place }
            }
        }

        var ids: [String: Int] = [:]
        func id(_ key: String) -> Int {
            if let known = ids[key] { return known }
            let next = ids.count
            ids[key] = next
            return next
        }
        var oldIds = [Int](repeating: 0, count: oldKeys.count)
        var newIds = [Int](repeating: 0, count: newKeys.count)
        for i in oldIds.indices where oldPlace[i] >= 0 { oldIds[i] = id(oldKeys[i]) }
        for j in newIds.indices where newPlace[j] >= 0 { newIds[j] = id(newKeys[j]) }

        let stretches = try findStretches(oldIds, newIds, oldPlace, newPlace, oldKeys, newKeys, cancel)
        var usedOld = [Bool](repeating: false, count: oldKeys.count)
        var usedNew = [Bool](repeating: false, count: newKeys.count)
        let taken = take(stretches, &usedOld, &usedNew)
        let joined = join(taken, oldPlace, newPlace)

        var moves: [CompareMove] = []
        for (o0, o1, n0, n1, matched) in joined {
            try cancel?.check()
            if oldPlace[o0] == newPlace[n0] { continue } // the same place: a rewording
            var words = 0
            for s in matched {
                for k in 0..<s.length where hasLetterOrDigit(oldKeys[s.old + k]) { words += 1 }
            }
            let whole = (o0 == 0 || oldPlace[o0 - 1] < 0) && (o1 == oldPlace.count || oldPlace[o1] < 0)
                && (n0 == 0 || newPlace[n0 - 1] < 0) && (n1 == newPlace.count || newPlace[n1] < 0)
            if words < minWords && !(whole && words >= minWholeRunWords) { continue }

            // Marks that came along, whichever word the diff matched them to: an opening one before it, a final "." after
            // it (the "." before it belongs to the sentence before).
            var a0 = o0, b0 = n0, a1 = o1, b1 = n1
            while a0 > 0 && b0 > 0 && !usedOld[a0 - 1] && !usedNew[b0 - 1] && oldKeys[a0 - 1] == newKeys[b0 - 1] && isOpening(oldKeys[a0 - 1]) {
                a0 -= 1
                b0 -= 1
            }
            while a1 < usedOld.count && b1 < usedNew.count && !usedOld[a1] && !usedNew[b1] && oldKeys[a1] == newKeys[b1]
                && !hasLetterOrDigit(oldKeys[a1]) && !isOpening(oldKeys[a1]) {
                a1 += 1
                b1 += 1
            }
            moves.append(CompareMove(oldStart: a0, oldEnd: a1, newStart: b0, newEnd: b1, inner: try inner(oldKeys, newKeys, a0, a1, b0, b1, cancel)))
        }
        return moves
    }

    private static func isOpening(_ key: String) -> Bool {
        guard key.utf16.count == 1, let u = key.unicodeScalars.first else { return false }
        let cat = u.properties.generalCategory
        return cat == .openPunctuation || cat == .initialPunctuation
    }

    static func hasLetterOrDigit(_ key: String) -> Bool { key.unicodeScalars.contains(where: CompareScan.isLetterOrDigit) }

    /// The longest runs of the same words among removed (old) and inserted (new) ones that start at a shared seed.
    private static func findStretches(_ oldIds: [Int], _ newIds: [Int], _ oldPlace: [Int], _ newPlace: [Int], _ oldKeys: [String], _ newKeys: [String],
                                      _ cancel: CancelToken?) throws -> [Stretch] {
        var seeds: [SeedKey: [Int]] = [:]
        var i = 0
        while i + seed <= oldIds.count {
            defer { i += 1 }
            if oldPlace[i] < 0 || oldPlace[i + 1] < 0 || oldPlace[i + 2] < 0 { continue }
            let key = SeedKey(a: oldIds[i], b: oldIds[i + 1], c: oldIds[i + 2])
            if seeds[key, default: []].count < maxSeedPlaces { seeds[key, default: []].append(i) }
        }

        var found: [Stretch] = []
        var work = 0
        var j = 0
        while j + seed <= newIds.count {
            defer { j += 1 }
            if j & 1023 == 0 { try cancel?.check() }
            if newPlace[j] < 0 || newPlace[j + 1] < 0 || newPlace[j + 2] < 0 { continue }
            guard let at = seeds[SeedKey(a: newIds[j], b: newIds[j + 1], c: newIds[j + 2])] else { continue }
            for i in at {
                // Only where a run starts: inside one it was found already.
                if i > 0 && j > 0 && oldPlace[i - 1] >= 0 && newPlace[j - 1] >= 0 && oldIds[i - 1] == newIds[j - 1] { continue }
                let length = grow(i, j, oldIds, newIds, oldPlace, newPlace, oldKeys, newKeys)
                found.append(Stretch(old: i, new: j, length: length))
                work += length
                if work > maxWork { return found }
            }
        }
        return found
    }

    /// How far a stretch starting at old `i` and new `j` goes: over the same changed words, and over a few words the diff
    /// matched elsewhere when the same words go on after them.
    private static func grow(_ i: Int, _ j: Int, _ oldIds: [Int], _ newIds: [Int], _ oldPlace: [Int], _ newPlace: [Int], _ oldKeys: [String],
                             _ newKeys: [String]) -> Int {
        var length = seed
        while true {
            while i + length < oldIds.count && j + length < newIds.count && oldPlace[i + length] >= 0 && newPlace[j + length] >= 0
                && oldIds[i + length] == newIds[j + length] { length += 1 }
            var over = 0
            while over < maxGrowOver && i + length + over < oldIds.count && j + length + over < newIds.count
                && (oldPlace[i + length + over] < 0 || newPlace[j + length + over] < 0)
                && oldKeys[i + length + over] == newKeys[j + length + over] { over += 1 }
            let a = i + length + over, b = j + length + over
            if over == 0 || a >= oldIds.count || b >= newIds.count || oldPlace[a] < 0 || newPlace[b] < 0 || oldIds[a] != newIds[b] { break }
            length += over
        }
        return length
    }

    /// Longest first; a stretch keeps its longest part no earlier stretch has used.
    private static func take(_ stretches: [Stretch], _ usedOld: inout [Bool], _ usedNew: inout [Bool]) -> [Stretch] {
        var taken: [Stretch] = []
        let ordered = stretches.sorted { ($0.length, -$0.old, -$0.new) > ($1.length, -$1.old, -$1.new) }
        for s in ordered {
            var bestStart = 0, bestLength = 0, start = -1
            for k in 0...s.length {
                let free = k < s.length && !usedOld[s.old + k] && !usedNew[s.new + k]
                if free && start < 0 {
                    start = k
                } else if !free && start >= 0 {
                    if k - start > bestLength {
                        bestStart = start
                        bestLength = k - start
                    }
                    start = -1
                }
            }
            if bestLength < seed { continue }
            for k in 0..<bestLength {
                usedOld[s.old + bestStart + k] = true
                usedNew[s.new + bestStart + k] = true
            }
            taken.append(Stretch(old: s.old + bestStart, new: s.new + bestStart, length: bestLength))
        }
        return taken.sorted { $0.old < $1.old }
    }

    /// Stretches a few edited words apart, in order on both sides, are one move.
    private static func join(_ stretches: [Stretch], _ oldPlace: [Int], _ newPlace: [Int]) -> [(Int, Int, Int, Int, [Stretch])] {
        func allChanged(_ place: [Int], _ from: Int, _ to: Int) -> Bool {
            for i in from..<max(from, to) where place[i] < 0 { return false }
            return true
        }
        var joined: [(Int, Int, Int, Int, [Stretch])] = []
        var k = 0
        while k < stretches.count {
            let first = stretches[k]
            k += 1
            var matched = [first]
            var o1 = first.old + first.length, n1 = first.new + first.length
            while k < stretches.count {
                let next = stretches[k]
                let gapOld = next.old - o1, gapNew = next.new - n1
                if gapOld < 0 || gapNew < 0 || gapOld > maxInnerGap || gapNew > maxInnerGap { break }
                if !allChanged(oldPlace, o1, next.old) || !allChanged(newPlace, n1, next.new) { break }
                matched.append(next)
                o1 = next.old + next.length
                n1 = next.new + next.length
                k += 1
            }
            joined.append((first.old, o1, first.new, n1, matched))
        }
        return joined
    }

    private static func inner(_ oldKeys: [String], _ newKeys: [String], _ o0: Int, _ o1: Int, _ n0: Int, _ n1: Int, _ cancel: CancelToken?) throws -> [DiffOp] {
        try WordDiff.diff(Array(oldKeys[o0..<o1]), Array(newKeys[n0..<n1]), cancel: cancel).map { DiffOp($0.kind, $0.a + o0, $0.b + n0, $0.length) }
    }
}

/// Running headers and footers (the Windows app's `CompareRunningLines`): a line at the top or bottom of most pages, the
/// same but for its page number. Where both documents have the same one it is left out of the word diff, since page
/// numbers land between other words wherever the text flows differently. A number that stays the same on every page
/// isn't a page number ("Contract 123"): it must match too, and so does one that differs without counting up with the
/// page ("Subtotal: 1,234.56"), which makes the line text. A line only one document has, or that differs, is compared as
/// text, so it is reported.
public enum CompareRunningLines {
    private static let edgeLines = 2       // lines looked at on each edge of a page
    private static let minPageLines = 3    // a page with less is all text, no furniture
    private static let minShare = 0.6
    private static let minCountingShare = 0.8 // of a line's steps from page to page: a section may start its numbering again

    private struct Edge {
        var raw: String
        var masked: String
        var start: Int
        var end: Int
    }

    private struct Seen {
        var pages = 0
        var texts: Set<String> = []
        var places: [(page: Int, raw: String)] = []
    }

    /// For each page of each document, the [start, end) ranges of its text to leave out of the diff.
    public static func find(_ oldPages: [PageText], _ newPages: [PageText], cancel: CancelToken? = nil) throws
        -> (old: [[(start: Int, end: Int)]], new: [[(start: Int, end: Int)]]) {
        let (oldLines, oldRunning) = try running(oldPages, cancel)
        let (newLines, newRunning) = try running(newPages, cancel)
        let keep = oldRunning.intersection(newRunning)
        func ranges(_ lines: [[(key: String, start: Int, end: Int)]]) -> [[(start: Int, end: Int)]] {
            lines.map { page in page.filter { keep.contains($0.key) }.map { ($0.start, $0.end) } }
        }
        return (ranges(oldLines), ranges(newLines))
    }

    private static func running(_ pages: [PageText], _ cancel: CancelToken?) throws -> (lines: [[(key: String, start: Int, end: Int)]], running: Set<String>) {
        var edges = [[Edge]](repeating: [], count: pages.count)
        var eligible = 0
        var seen: [String: Seen] = [:]
        for p in pages.indices {
            if p & 63 == 0 { try cancel?.check() }
            edges[p] = edgesOf(pages[p])
            if edges[p].isEmpty { continue }
            eligible += 1
            var counted = Set<String>()
            for e in edges[p] {
                var entry = seen[e.masked] ?? Seen()
                entry.texts.insert(e.raw)
                entry.places.append((p, e.raw))
                if counted.insert(e.masked).inserted { entry.pages += 1 }
                seen[e.masked] = entry
            }
        }

        let needed = max(2, Int((Double(eligible) * minShare).rounded(.up))) // bounded: at most the page count
        var counting: [String: [Bool]?] = [:]
        var running = Set<String>()
        var lines = [[(key: String, start: Int, end: Int)]](repeating: [], count: pages.count)
        for p in pages.indices {
            for e in edges[p] {
                guard let entry = seen[e.masked], entry.pages >= needed else { continue }
                // A number that counts up with the page is a page number; any other number must match, on every page: a
                // line whose numbers just differ ("Subtotal: 1,234.56") is text, and is compared.
                let slots: [Bool]?
                if let known = counting[e.masked] {
                    slots = known
                } else {
                    slots = countingNumbers(entry.places)
                    counting[e.masked] = .some(slots)
                }
                if entry.texts.count > 1 && slots == nil { continue }
                let key = entry.texts.count > 1 ? keyOf(e.raw, slots ?? []) : e.raw
                running.insert(key)
                lines[p].append((key, e.start, e.end))
            }
        }
        return (lines, running)
    }

    /// Which of a line's numbers count up with the page across the pages it is on; nil when all the differing ones don't.
    private static func countingNumbers(_ places: [(page: Int, raw: String)]) -> [Bool]? {
        let numbers = places.map { numbersIn($0.raw) }
        let count = numbers[0].count
        var slots = [Bool](repeating: false, count: count)
        var any = false
        for k in 0..<count {
            var steps = 0, counted = 0
            var same = true
            for i in places.indices.dropFirst() {
                if places[i].page == places[i - 1].page { continue }
                steps += 1
                // A line with fewer numbers (a different masked line can't be here: same masks, same count).
                guard k < numbers[i].count, k < numbers[i - 1].count else {
                    same = false
                    continue
                }
                if numbers[i][k] != numbers[i - 1][k] { same = false }
                if let b = Int64(numbers[i][k]), let a = Int64(numbers[i - 1][k]), b &- a == Int64(places[i].page - places[i - 1].page) { counted += 1 }
            }
            if same { continue } // stays as it is, and must match
            if steps == 0 || Double(counted) < Double(steps) * minCountingShare { return nil }
            slots[k] = true
            any = true
        }
        return any ? slots : nil
    }

    /// Runs of decimal digits (`\d+`, any script's digits, as .NET's regex reads them).
    private static func numberRanges(_ raw: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var i = raw.startIndex
        while i < raw.endIndex {
            guard isDigit(raw[i]) else {
                i = raw.index(after: i)
                continue
            }
            let start = i
            while i < raw.endIndex && isDigit(raw[i]) { i = raw.index(after: i) }
            ranges.append(start..<i)
        }
        return ranges
    }

    private static func isDigit(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c.unicodeScalars.first?.properties.generalCategory == .decimalNumber
    }

    private static func numbersIn(_ raw: String) -> [String] { numberRanges(raw).map { String(raw[$0]) } }

    /// The line with the numbers whose slot is set replaced by "#", the others as they are.
    private static func keyOf(_ raw: String, _ slots: [Bool]) -> String {
        var out = ""
        var at = raw.startIndex
        for (k, r) in numberRanges(raw).enumerated() {
            out += raw[at..<r.lowerBound]
            out += k < slots.count && slots[k] ? "#" : String(raw[r])
            at = r.upperBound
        }
        return out + raw[at...]
    }

    /// The topmost and bottommost lines of a page, by where they are, not where the file stores them.
    private static func edgesOf(_ page: PageText) -> [Edge] {
        let units = Array(page.text.utf16)
        var all: [(start: Int, end: Int, top: Double)] = []
        var start = 0
        while start < units.count {
            var end = start
            while end < units.count && units[end] != 10 { end += 1 }
            if end > start { all.append((start, end, page.boxAt(start).y)) }
            start = end + 1
        }
        if all.count < minPageLines { return [] }
        let byTop = all.enumerated().sorted { ($0.element.top, $0.offset) < ($1.element.top, $1.offset) }.map(\.element)
        let edge = Array(byTop.prefix(edgeLines)) + Array(byTop.dropFirst(max(edgeLines, byTop.count - edgeLines)))
        return edge.map { l in
            let raw = String(decoding: units[l.start..<l.end], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return Edge(raw: raw, masked: keyOf(raw, [Bool](repeating: true, count: numberRanges(raw).count)), start: l.start, end: l.end)
        }
    }
}
