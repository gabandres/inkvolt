import Foundation

public enum DiffKind: Sendable, Equatable { case equal, delete, insert }

/// One run of a diff. Equal: a[a..<a+length] matches b[b..<b+length]. Delete: a[a..<a+length] is gone (b is where it
/// was in b). Insert: b[b..<b+length] is new (a is where it goes in a). Runs come in order and cover both sequences.
public struct DiffOp: Sendable, Equatable {
    public var kind: DiffKind
    public var a: Int
    public var b: Int
    public var length: Int

    public init(_ kind: DiffKind, _ a: Int, _ b: Int, _ length: Int) {
        self.kind = kind
        self.a = a
        self.b = b
        self.length = length
    }
}

/// Word-level diff (the Windows app's `WordDiff`): common prefix and suffix trimmed, then words that occur exactly once
/// on both sides anchor the match (patience diff, so moved boilerplate like "the" can't pull unrelated passages
/// together), and the stretches between anchors get Myers' shortest edit script. Bounded: a stretch needing more than
/// `maxEdits` edits, or a run past the overall work budget, is reported as replaced instead of searched further.
public enum WordDiff {
    /// Most edits Myers looks for in one stretch (its memory grows with the square of this).
    public static let maxEdits = 2000

    /// Rough upper bound on the steps one diff takes before the rest is reported as replaced.
    static let workBudget = 300_000_000

    public static func diff(_ a: [String], _ b: [String], cancel: CancelToken? = nil) throws -> [DiffOp] {
        try diff(a, b, patience: true, cancel)
    }

    /// Myers alone, without unique-word anchors: always a shortest edit script (within `maxEdits`).
    static func shortest(_ a: [String], _ b: [String]) -> [DiffOp] { (try? diff(a, b, patience: false, nil)) ?? [] }

    private static func diff(_ a: [String], _ b: [String], patience: Bool, _ cancel: CancelToken?) throws -> [DiffOp] {
        try cancel?.check()
        // Words become ints, so comparisons are cheap.
        var ids: [String: Int] = [:]
        func id(_ s: String) -> Int {
            if let v = ids[s] { return v }
            let v = ids.count
            ids[s] = v
            return v
        }
        let x = a.map(id)
        let y = b.map(id)
        var differ = Differ(a: x, b: y, patience: patience, cancel: cancel)
        return try differ.run()
    }

    /// Slides each pure insert or delete run (an equal run on both sides) along runs of repeated words to the place
    /// where `cost` is lowest, e.g. so a removed passage doesn't take the first word of the next page with it. `cost`
    /// gets the run's kind and its [start, end) in a (delete) or b (insert); ties keep the position the diff found.
    public static func slide(_ ops: [DiffOp], _ a: [String], _ b: [String], _ cost: (DiffKind, Int, Int) -> Double) -> [DiffOp] {
        var list = ops
        var i = 0
        while i < list.count {
            defer { i += 1 }
            let op = list[i]
            if op.kind == .equal { continue }
            let hasBefore = i > 0 && list[i - 1].kind == .equal
            let hasAfter = i + 1 < list.count && list[i + 1].kind == .equal
            if !hasBefore && !hasAfter { continue } // next to the other kind: a replacement, not a pure run
            if (i > 0 && !hasBefore) || (i + 1 < list.count && !hasAfter) { continue }
            let before = hasBefore ? list[i - 1] : DiffOp(.equal, 0, 0, 0)
            let after = hasAfter ? list[i + 1] : DiffOp(.equal, 0, 0, 0)

            let seq = op.kind == .delete ? a : b
            let start = op.kind == .delete ? op.a : op.b
            let len = op.length
            // How far it can move: up while the word before the run equals the run's last word, down likewise.
            var up = 0
            while hasBefore && up < before.length && seq[start - up - 1] == seq[start + len - up - 1] { up += 1 }
            var down = 0
            while hasAfter && down < after.length && seq[start + down] == seq[start + len + down] { down += 1 }
            if up == 0 && down == 0 { continue }

            var best = 0
            var bestCost = cost(op.kind, start, start + len)
            for k in -up...down where k != 0 {
                let c = cost(op.kind, start + k, start + k + len)
                if c < bestCost - 1e-9 {
                    bestCost = c
                    best = k
                }
            }
            if best == 0 { continue }
            var moved = op
            moved.a += best
            moved.b += best
            list[i] = moved
            // The words the run moved past change sides; at either end of the sequences they make a new equal run.
            if hasBefore {
                list[i - 1].length = before.length + best
            } else if best > 0 {
                list.insert(DiffOp(.equal, op.a, op.b, best), at: i)
                i += 1
            }
            if hasAfter {
                list[i + 1] = DiffOp(.equal, after.a + best, after.b + best, after.length - best)
            } else if best < 0 {
                list.insert(DiffOp(.equal, moved.a + (op.kind == .delete ? len : 0), moved.b + (op.kind == .insert ? len : 0), -best), at: i + 1)
            }
        }
        return merge(list)
    }

    /// Drops empty runs and joins neighbours: equal runs merged, and between two equal runs one delete then one insert.
    static func merge(_ ops: [DiffOp]) -> [DiffOp] {
        var result: [DiffOp] = []
        result.reserveCapacity(ops.count)
        var del = 0, ins = 0, blockA = 0, blockB = 0
        func flush() {
            if del > 0 { result.append(DiffOp(.delete, blockA, blockB, del)) }
            if ins > 0 { result.append(DiffOp(.insert, blockA + del, blockB, ins)) }
            del = 0
            ins = 0
        }
        for op in ops where op.length > 0 {
            if op.kind == .equal {
                flush()
                if let last = result.last, last.kind == .equal {
                    result[result.count - 1].length = last.length + op.length
                } else {
                    result.append(op)
                }
                continue
            }
            if del == 0 && ins == 0 {
                // The block starts where its first edit sits.
                blockA = op.a
                blockB = op.b
            }
            if op.kind == .delete { del += op.length } else { ins += op.length }
        }
        flush()
        return result
    }

    private struct Differ {
        let a: [Int]
        let b: [Int]
        let patience: Bool
        let cancel: CancelToken?
        private var ops: [DiffOp] = []
        private var work = 0

        init(a: [Int], b: [Int], patience: Bool, cancel: CancelToken?) {
            self.a = a
            self.b = b
            self.patience = patience
            self.cancel = cancel
        }

        /// Work items: a stretch to diff, or an equal run to emit once everything before it is out.
        struct Item {
            var isEqual: Bool
            var aLo: Int, aHi: Int, bLo: Int, bHi: Int
        }

        mutating func run() throws -> [DiffOp] {
            // An explicit stack instead of recursion: anchors can nest as deep as the input is long.
            var stack = [Item(isEqual: false, aLo: 0, aHi: a.count, bLo: 0, bHi: b.count)]
            while let it = stack.popLast() {
                try cancel?.check()
                if it.isEqual { emit(.equal, it.aLo, it.bLo, it.aHi - it.aLo) } else { try range(it.aLo, it.aHi, it.bLo, it.bHi, &stack) }
            }
            return WordDiff.merge(ops)
        }

        private mutating func emit(_ kind: DiffKind, _ ai: Int, _ bi: Int, _ length: Int) {
            if length > 0 { ops.append(DiffOp(kind, ai, bi, length)) }
        }

        private mutating func replace(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) {
            emit(.delete, aLo, bLo, aHi - aLo)
            emit(.insert, aHi, bLo, bHi - bLo)
        }

        private mutating func range(_ aLo0: Int, _ aHi0: Int, _ bLo0: Int, _ bHi0: Int, _ stack: inout [Item]) throws {
            var aLo = aLo0, aHi = aHi0, bLo = bLo0, bHi = bHi0
            var pre = 0
            while aLo + pre < aHi && bLo + pre < bHi && a[aLo + pre] == b[bLo + pre] { pre += 1 }
            emit(.equal, aLo, bLo, pre)
            aLo += pre
            bLo += pre
            var suf = 0
            while aHi - suf > aLo && bHi - suf > bLo && a[aHi - suf - 1] == b[bHi - suf - 1] { suf += 1 }
            aHi -= suf
            bHi -= suf
            // Pushed first, so it's emitted after the middle.
            if suf > 0 { stack.append(Item(isEqual: true, aLo: aHi, aHi: aHi + suf, bLo: bHi, bHi: bHi + suf)) }

            if aLo == aHi || bLo == bHi {
                replace(aLo, aHi, bLo, bHi)
                return
            }
            work += (aHi - aLo) + (bHi - bLo)
            if work > WordDiff.workBudget {
                replace(aLo, aHi, bLo, bHi)
                return
            }

            let found = patience ? anchors(aLo, aHi, bLo, bHi) : []
            guard let anchors = found else {
                replace(aLo, aHi, bLo, bHi) // nothing in common at all
                return
            }
            if !anchors.isEmpty {
                // Stretches between anchors, pushed in reverse so they come out in order.
                var items: [Item] = []
                var pa = aLo, pb = bLo
                for (i, j) in anchors {
                    items.append(Item(isEqual: false, aLo: pa, aHi: i, bLo: pb, bHi: j))
                    items.append(Item(isEqual: true, aLo: i, aHi: i + 1, bLo: j, bHi: j + 1))
                    pa = i + 1
                    pb = j + 1
                }
                items.append(Item(isEqual: false, aLo: pa, aHi: aHi, bLo: pb, bHi: bHi))
                for item in items.reversed() where item.isEqual || item.aHi > item.aLo || item.bHi > item.bLo { stack.append(item) }
                return
            }
            if try !myers(aLo, aHi, bLo, bHi) { replace(aLo, aHi, bLo, bHi) }
        }

        /// The longest increasing chain of words found exactly once in each side of the stretch (patience sorting).
        /// Empty when there are none; nil when the two sides share no word at all.
        private func anchors(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) -> [(Int, Int)]? {
            var countA: [Int: (count: Int, index: Int)] = [:]
            for i in aLo..<aHi {
                if let c = countA[a[i]] { countA[a[i]] = (c.count + 1, c.index) } else { countA[a[i]] = (1, i) }
            }
            var countB: [Int: (count: Int, index: Int)] = [:]
            var shared = false
            for j in bLo..<bHi where countA[b[j]] != nil {
                shared = true
                if let c = countB[b[j]] { countB[b[j]] = (c.count + 1, c.index) } else { countB[b[j]] = (1, j) }
            }
            if !shared { return nil }

            var pairs: [(i: Int, j: Int)] = []
            for i in aLo..<aHi {
                if countA[a[i]]?.count == 1, let cb = countB[a[i]], cb.count == 1 { pairs.append((i, cb.index)) }
            }
            if pairs.isEmpty { return [] }

            // Longest increasing subsequence by j (pairs are already ordered by i).
            var tails: [Int] = [] // index into pairs of the smallest tail of each length
            var prev = [Int](repeating: -1, count: pairs.count)
            for k in pairs.indices {
                var lo = 0, hi = tails.count
                while lo < hi {
                    let mid = (lo + hi) / 2
                    if pairs[tails[mid]].j < pairs[k].j { lo = mid + 1 } else { hi = mid }
                }
                prev[k] = lo > 0 ? tails[lo - 1] : -1
                if lo == tails.count { tails.append(k) } else { tails[lo] = k }
            }
            var chain: [(Int, Int)] = []
            chain.reserveCapacity(tails.count)
            var k = tails[tails.count - 1]
            while k >= 0 {
                chain.append(pairs[k])
                k = prev[k]
            }
            return chain.reversed()
        }

        /// Myers' O((N+M)D) shortest edit script; false when it needs more than `maxEdits` edits.
        private mutating func myers(_ aLo: Int, _ aHi: Int, _ bLo: Int, _ bHi: Int) throws -> Bool {
            let n = aHi - aLo, m = bHi - bLo, maxD = min(n + m, WordDiff.maxEdits)
            let offset = maxD + 1
            var v = [Int](repeating: 0, count: 2 * maxD + 3)
            var trace: [[Int]] = []
            var found = -1
            var d = 0
            while d <= maxD && found < 0 {
                if d & 63 == 0 { try cancel?.check() }
                var k = -d
                while k <= d {
                    var xx = k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) ? v[offset + k + 1] : v[offset + k - 1] + 1
                    var yy = xx - k
                    while xx < n && yy < m && a[aLo + xx] == b[bLo + yy] {
                        xx += 1
                        yy += 1
                    }
                    v[offset + k] = xx
                    if xx >= n && yy >= m { found = d }
                    k += 2
                }
                // Keep only the diagonals reachable in d steps.
                trace.append(Array(v[(offset - d)...(offset + d)]))
                work += 2 * d + 1
                d += 1
            }
            if found < 0 { return false }

            // Walk back from (n, m), collecting single steps, then emit them in order.
            var steps: [(kind: DiffKind, x: Int, y: Int)] = []
            var px = n, py = m
            var step = found
            while step > 0 {
                let prevV = trace[step - 1]
                func prior(_ k: Int) -> Int { prevV[k + step - 1] }
                let k = px - py
                let down = k == -step || (k != step && prior(k - 1) < prior(k + 1))
                let pk = down ? k + 1 : k - 1
                let sx = prior(pk)
                let sy = sx - pk
                let ex = down ? sx : sx + 1
                let ey = ex - k
                while px > ex && py > ey {
                    px -= 1
                    py -= 1
                    steps.append((.equal, px, py))
                }
                steps.append(down ? (.insert, sx, sy) : (.delete, sx, sy))
                px = sx
                py = sy
                step -= 1
            }
            while px > 0 && py > 0 {
                px -= 1
                py -= 1
                steps.append((.equal, px, py))
            }
            for s in steps.reversed() { emit(s.kind, aLo + s.x, bLo + s.y, 1) }
            return true
        }
    }
}
