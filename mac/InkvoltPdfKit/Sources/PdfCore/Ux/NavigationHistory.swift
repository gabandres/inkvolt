import Foundation

/// A place in the page view: a page and how far down it the view's top is (points, upright).
public struct ViewPlace: Sendable, Equatable {
    public var page: Int
    public var y: Double

    public init(page: Int, y: Double) {
        self.page = page
        self.y = y
    }
}

/// Go › Previous View and Next View (Windows' `PageViewer` Back and Forward): each jump (a link, a bookmark, Go to Page,
/// First and Last Page, a citation…) records where the view was; Previous View returns there and Next View comes back.
/// Turning a page or scrolling records nothing, and a new jump forgets what Next View had. Each pane keeps its own,
/// cleared when another document's pages are shown.
public struct NavigationHistory: Sendable {
    /// The places kept each way (Windows' stacks are unbounded; a long reading session stays small here).
    public static let limit = 200

    private var backward: [ViewPlace] = []
    private var ahead: [ViewPlace] = []

    public init() {}

    public var canGoBack: Bool { !backward.isEmpty }
    public var canGoForward: Bool { !ahead.isEmpty }

    /// Before a jump: where the view is now.
    public mutating func record(_ here: ViewPlace) {
        backward.append(here)
        if backward.count > Self.limit { backward.removeFirst(backward.count - Self.limit) }
        ahead.removeAll()
    }

    /// The place to go back to, `here` kept for Next View; nil when there's none, or its page is gone (taken off).
    public mutating func back(from here: ViewPlace, pageCount: Int) -> ViewPlace? {
        Self.travel(&backward, &ahead, here, pageCount)
    }

    /// The place to go forward to, `here` kept for Previous View; nil as `back`.
    public mutating func forward(from here: ViewPlace, pageCount: Int) -> ViewPlace? {
        Self.travel(&ahead, &backward, here, pageCount)
    }

    public mutating func clear() {
        backward.removeAll()
        ahead.removeAll()
    }

    private static func travel(_ from: inout [ViewPlace], _ to: inout [ViewPlace], _ here: ViewPlace, _ pageCount: Int) -> ViewPlace? {
        guard let place = from.popLast() else { return nil }
        to.append(here)
        if to.count > limit { to.removeFirst(to.count - limit) }
        return place.page < pageCount ? place : nil
    }
}
