import Foundation

/// A color for annotations and bookmark titles, components 0…1.
public struct AnnotColor: Equatable, Hashable, Sendable {
    public var r: Double, g: Double, b: Double

    public init(_ r: Double, _ g: Double, _ b: Double) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let yellow = AnnotColor(1, 0.85, 0.1)
    public static let red = AnnotColor(0.9, 0.1, 0.1)
}

/// A bookmark (an outline entry) as the bookmarks editor sees it.
public struct Bookmark: Equatable, Sendable {
    public var title: String
    public var pageIndex: Int
    public var top: Double?
    public var children: [Bookmark] = []
    /// Children shown expanded.
    public var open = false
    public var bold = false
    public var italic = false
    /// Title color; nil: the viewer's default (black).
    public var color: AnnotColor?
    /// Read only: the action when it isn't a jump to a page in this document ("URI", "Launch", "GoToR", "Named",
    /// "JavaScript", …); kept when `pageIndex` and `top` stay as read.
    public var actionKind: String?
    /// Read only: the web address of a URI action.
    public var uri: String?
    /// The bookmark this was read from (1-based, in reading order; 0 = new). Valid for the bytes it was read from.
    var sourceId = 0

    public init(_ title: String, _ pageIndex: Int = -1, top: Double? = nil, children: [Bookmark] = []) {
        self.title = title
        self.pageIndex = pageIndex
        self.top = top
        self.children = children
    }
}

/// No bookmark at that path (.NET's `ArgumentOutOfRangeException`).
public struct BookmarkNotFound: Error, Equatable, Sendable {
    public var message: String
}

/// A bookmark can't be moved into itself (.NET's `InvalidOperationException`).
public struct BookmarkMoveRefused: Error, Equatable, Sendable {
    public var message = "A bookmark can't be moved into itself."
}

/// Edits of a bookmark tree addressed by index paths: [2] is the third top-level bookmark, [2, 0] its first child.
/// Every edit returns a new tree; untouched bookmarks are kept as they were, so writing the tree back changes only what
/// was edited.
public enum BookmarkTree {
    public static func at(_ tree: [Bookmark], _ path: [Int]) throws -> Bookmark {
        if path.isEmpty { throw BookmarkNotFound(message: "Empty bookmark path.") }
        var list = tree
        var b: Bookmark?
        for i in path {
            guard i >= 0 && i < list.count else { throw BookmarkNotFound(message: "The bookmark isn't there any more.") }
            b = list[i]
            list = list[i].children
        }
        return b!
    }

    /// The bookmark at `path` replaced with what `change` makes of it.
    public static func replace(_ tree: [Bookmark], _ path: [Int], _ change: (Bookmark) -> Bookmark) throws -> [Bookmark] {
        _ = try at(tree, path)
        return rebuild(tree, path, 0, change)
    }

    /// The bookmark at `path` removed with its children.
    public static func remove(_ tree: [Bookmark], _ path: [Int]) throws -> [Bookmark] {
        _ = try at(tree, path)
        return splice(tree, Array(path.dropLast())) { $0.remove(at: path[path.count - 1]) }
    }

    /// `bookmark` inserted as child `index` of `parent` (empty: the top level; the index clamped).
    public static func insert(_ tree: [Bookmark], _ parent: [Int], _ index: Int, _ bookmark: Bookmark) throws -> [Bookmark] {
        if !parent.isEmpty { _ = try at(tree, parent) }
        return splice(tree, parent) { $0.insert(bookmark, at: min(max(index, 0), $0.count)) }
    }

    /// The bookmark at `from` (with its children) moved to child `index` of `parent`, where the index counts the parent's
    /// children before the move. The parent is opened so the moved bookmark shows.
    public static func move(_ tree: [Bookmark], _ from: [Int], _ parent: [Int], _ index: Int) throws -> [Bookmark] {
        let moving = try at(tree, from)
        if parent.count >= from.count && Array(parent.prefix(from.count)) == from { throw BookmarkMoveRefused() }
        if !parent.isEmpty { _ = try at(tree, parent) }

        // Removing first shifts later siblings (and the parent's path) up by one where they share the old parent.
        var target = parent
        var index = index
        let oldParent = Array(from.dropLast())
        let depth = oldParent.count
        if target.count > depth && Array(target.prefix(depth)) == oldParent && target[depth] > from[from.count - 1] { target[depth] -= 1 }
        if target == oldParent && index > from[from.count - 1] { index -= 1 }

        let without = try remove(tree, from)
        let result = try insert(without, target, index, moving)
        if target.isEmpty { return result }
        return try replace(result, target) { b in
            var b = b
            b.open = true
            return b
        }
    }

    private static func splice(_ tree: [Bookmark], _ parent: [Int], _ change: (inout [Bookmark]) -> Void) -> [Bookmark] {
        if parent.isEmpty {
            var list = tree
            change(&list)
            return list
        }
        return rebuild(tree, parent, 0) { b in
            var b = b
            change(&b.children)
            return b
        }
    }

    private static func rebuild(_ list: [Bookmark], _ path: [Int], _ depth: Int, _ change: (Bookmark) -> Bookmark) -> [Bookmark] {
        var copy = list
        let i = path[depth]
        if depth == path.count - 1 {
            copy[i] = change(copy[i])
        } else {
            copy[i].children = rebuild(copy[i].children, path, depth + 1, change)
        }
        return copy
    }
}
