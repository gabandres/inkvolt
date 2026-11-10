import Foundation

/// Inline (direct) dictionaries and arrays with one parent each, before MuPDF compacts a file. `garbage=compact`
/// renumbers the references inside a direct container in place, once for each place it is reached from: a container two
/// parents share (a shallow copy's /Resources keeping the original's inline /Font, a link's copy keeping its inline /A)
/// is renumbered twice, and its references then point at other objects (fonts, pages, actions). Any edit that copies
/// entries shallowly is safe after this pass; the copies that can be deep are deep too (`ContentEditor.ownCopy`).
extension MuDoc {
    /// The most entries looked at, and how deep direct containers nest: a hostile file's millions of objects or nesting
    /// without end stop the pass where it is (what was unshared so far stays so; the rest is written as it is).
    static let unshareBudget = 4_000_000
    static let unshareDepth = 64

    /// Gives every direct dictionary or array reached from more than one place its own deep copy at each further place.
    /// Walks from the trailer through every reference once (a work list, so a chain of references doesn't nest).
    /// Returns how many copies were made.
    @discardableResult
    func unshareDirectObjects() -> Int {
        var refs = Set<Int>()
        var direct = Set<UInt>()
        var pending: [PObj] = []
        var budget = Self.unshareBudget
        var copies = 0
        /// One container's entries: a reference is queued once; a direct container met before is replaced by a copy.
        func walk(_ container: PObj, _ depth: Int) {
            if depth > Self.unshareDepth || budget <= 0 { return }
            if container.isDict {
                for key in container.keys {
                    budget -= 1
                    if budget <= 0 { return }
                    guard let child = container[key] else { continue }
                    if let replaced = visit(child, depth) { container.set(key, replaced) }
                }
            } else if container.isArray {
                for i in 0..<container.count {
                    budget -= 1
                    if budget <= 0 { return }
                    guard let child = container[i] else { continue }
                    if let replaced = visit(child, depth) { container.replace(at: i, with: replaced) }
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
            let copy = ContentEditor.ownCopy(self, child)
            copies += 1
            direct.insert(copy.identity)
            walk(copy, depth + 1)
            return copy
        }
        let trailer = self.trailer
        direct.insert(trailer.identity)
        walk(trailer, 0)
        while let next = pending.popLast(), budget > 0 {
            if next.isDict || next.isArray { walk(next, 0) }
        }
        return copies
    }
}
