import Foundation

/// Inline (direct) dictionaries and arrays with one parent each, before MuPDF compacts a file. `garbage=compact`
/// renumbers the references inside a direct container in place, once for each place it is reached from: a container two
/// parents share (a shallow copy's /Resources keeping the original's inline /Font, a link's copy keeping its inline /A)
/// is renumbered twice, and its references then point at other objects (fonts, pages, actions). Any edit that copies
/// entries shallowly is safe after this pass; the copies that can be deep are deep too (`ContentEditor.ownCopy`).
extension MuDoc {
    /// How much work the pass may do (entries looked at, entries copied, entries a replacement sorts), and how deep
    /// direct containers may nest: past either on a crafted file, the pass says so and the file is written without
    /// renumbering (`write`), correct but not compacted.
    static let defaultUnshareBudget = 4_000_000
    static let unshareDepth = 64

    /// Gives every direct dictionary or array reached from more than one place its own deep copy at each further place.
    /// Walks from the trailer through every reference once (a work list, so a chain of references doesn't nest), each
    /// container's entries by index (any key name, no lookup by name). `complete` is false when the budget or the depth
    /// ran out, or a copy couldn't be made: containers may still be shared, and the file must not be renumbered.
    @discardableResult
    func unshareDirectObjects(budget start: Int = defaultUnshareBudget) -> (copies: Int, complete: Bool) {
        var refs = Set<Int>()
        var direct = Set<UInt>()
        var pending: [PObj] = []
        var budget = start
        var copies = 0
        var complete = true
        /// One container's entries: a reference is queued once; a direct container met before is replaced by a copy.
        func walk(_ container: PObj, _ depth: Int) {
            if depth > Self.unshareDepth {
                complete = false
                return
            }
            let n = container.count
            if container.isDict {
                var replaced: [(key: PObj, value: PObj)] = []
                for i in 0..<n {
                    budget -= 1
                    if budget <= 0 {
                        complete = false
                        return
                    }
                    guard let child = container.value(at: i) else { continue }
                    if let copy = visit(child, depth), let key = container.keyObject(at: i) { replaced.append((key, copy)) }
                }
                if !replaced.isEmpty {
                    budget -= n // the sort a replacement may make, then its binary searches
                    for r in replaced { container.set(name: r.key, r.value) }
                }
            } else if container.isArray {
                for i in 0..<n {
                    budget -= 1
                    if budget <= 0 {
                        complete = false
                        return
                    }
                    guard let child = container[i] else { continue }
                    if let copy = visit(child, depth) { container.replace(at: i, with: copy) }
                }
            }
        }
        /// A copy to put in the child's place when it is a direct container already met; nil to keep it.
        func visit(_ child: PObj, _ depth: Int) -> PObj? {
            if child.isRef {
                if refs.insert(child.num).inserted { pending.append(child) }
                return nil
            }
            guard child.isDict || child.isArray else { return nil }
            if direct.insert(child.identity).inserted {
                walk(child, depth + 1)
                return nil
            }
            guard let copy = child.deepCopy(maxDepth: Self.unshareDepth - depth, budget: &budget) else {
                complete = false
                return nil
            }
            copies += 1
            direct.insert(copy.identity)
            walk(copy, depth + 1)
            return copy
        }
        let trailer = self.trailer
        direct.insert(trailer.identity)
        walk(trailer, 0)
        while complete, let next = pending.popLast() {
            if next.isDict || next.isArray { walk(next, 0) }
        }
        return (copies, complete && budget > 0)
    }
}
