import Foundation
import Testing
@testable import PdfCore

/// Ported from BookmarkTreeTests.cs: all 3 tests. Adapted: "untouched branches stay the same records" is equality here
/// (bookmarks are values).
struct BookmarkTreeTests {
    private func tree() -> [Bookmark] {
        [
            Bookmark("A", 0, children: [Bookmark("A1", 0), Bookmark("A2", 1)]),
            Bookmark("B", 1),
            Bookmark("C", 2, children: [Bookmark("C1", 2)]),
        ]
    }

    private func show(_ tree: [Bookmark]) -> String {
        tree.map { $0.children.isEmpty ? $0.title : "\($0.title)(\(show($0.children)))" }.joined(separator: " ")
    }

    private func titled(_ title: String) -> (Bookmark) -> Bookmark {
        { b in
            var b = b
            b.title = title
            return b
        }
    }

    @Test func renamesRemovesAndInserts() throws {
        let t = tree()
        #expect(show(t) == "A(A1 A2) B C(C1)")
        #expect(show(try BookmarkTree.replace(t, [0, 1], titled("X"))) == "A(A1 X) B C(C1)")
        #expect(show(try BookmarkTree.remove(t, [1])) == "A(A1 A2) C(C1)")
        #expect(show(try BookmarkTree.remove(t, [0, 0])) == "A(A2) B C(C1)")
        #expect(show(try BookmarkTree.insert(t, [1], 0, Bookmark("N"))) == "A(A1 A2) B(N) C(C1)")
        #expect(show(try BookmarkTree.insert(t, [], 99, Bookmark("N"))) == "A(A1 A2) B C(C1) N")
        // Untouched branches stay as they were.
        #expect(try BookmarkTree.replace(t, [0, 1], titled("X"))[2] == t[2])
    }

    @Test func movesAndNests() throws {
        let t = tree()
        #expect(show(try BookmarkTree.move(t, [1], [], 0)) == "B A(A1 A2) C(C1)")
        #expect(show(try BookmarkTree.move(t, [0], [], 3)) == "B C(C1) A(A1 A2)")
        #expect(show(try BookmarkTree.move(t, [1], [2], 1)) == "A(A1 A2) C(C1 B)")
        #expect(show(try BookmarkTree.move(t, [0, 1], [2], 0)) == "A(A1) B C(A2 C1)")
        // Into a later sibling: the target's path shifts when the moved one leaves.
        #expect(show(try BookmarkTree.move(t, [0], [1], 0)) == "B(A(A1 A2)) C(C1)")
        #expect(try BookmarkTree.move(t, [0], [1], 0)[0].open)
        // Out to the top level.
        #expect(show(try BookmarkTree.move(t, [0, 1], [], 1)) == "A(A1) A2 B C(C1)")
        #expect(throws: BookmarkMoveRefused.self) { try BookmarkTree.move(t, [0], [0, 1], 0) }
        #expect(throws: BookmarkNotFound.self) { try BookmarkTree.remove(t, [5]) }
    }

    @Test func editsRoundTripThroughTheFile() throws {
        let pdf = try Bookmarks.setOutline(TestPdf.make(3), nil, tree())
        let read = try Bookmarks.read(pdf, nil)
        let edited = try Bookmarks.setOutline(pdf, nil, try BookmarkTree.move(try BookmarkTree.replace(read, [1], titled("Bee")), [2, 0], [], 0))
        #expect(show(try Bookmarks.read(edited, nil)) == "C1 A(A1 A2) Bee C")
        #expect(try Bookmarks.read(edited, nil)[0].pageIndex == 2)
    }
}
