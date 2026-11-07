/// The page the page view draws ahead of those shown (roadmap 3.6, as Windows asks for the next pages): the next one the
/// way the view last moved, so a drawing set's next sheet (a few hundred milliseconds) is ready as it scrolls in.
/// The way is learned only when the first page shown changes: the view asks for its pages again with the same ones
/// shown (a tile arrived, a zoom), which says nothing of a move.
public struct ReadAhead: Sendable {
    private var first: Int?
    private var up = false

    public init() {}

    /// The page ahead of `shown` among `count` pages; nil past either end.
    public mutating func page(after shown: ClosedRange<Int>, of count: Int) -> Int? {
        if let first, shown.lowerBound != first { up = shown.lowerBound < first }
        first = shown.lowerBound
        let ahead = up ? shown.lowerBound - 1 : shown.upperBound + 1
        return ahead >= 0 && ahead < count ? ahead : nil
    }

    /// The pages were laid out again (the document reloaded, pages inserted or deleted, another reading mode or turn):
    /// the page shown next says nothing of a move, so the way is forgotten (down, as a document is read).
    public mutating func reset() {
        first = nil
        up = false
    }
}
