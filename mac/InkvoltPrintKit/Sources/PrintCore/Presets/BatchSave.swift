import Foundation

/// The files of a batch a preset save already wrote before it failed part-way (file 2 of 3, say), so pressing Save again
/// writes only the rest: a file counts as saved while it is made of the very same pages, in the same order. Forgotten when
/// the pages change and once a save completes (saving again on purpose then writes everything again). Pages are known by
/// their identity (the review's page ids; the Windows app compares page objects by reference).
public struct SavedParts<Page: Equatable & Sendable>: Sendable {
    private struct Saved: Sendable {
        let pages: [Page]
        let paths: [String]
    }

    private var saved: [Saved] = []

    public init() {}

    public var count: Int { saved.count }

    /// Where this file's pages were saved, or nil when they weren't.
    public func find(_ pages: [Page]) -> [String]? { saved.first { $0.pages == pages }?.paths }

    public mutating func add(_ pages: [Page], paths: [String]) { saved.append(Saved(pages: pages, paths: paths)) }

    public mutating func clear() { saved.removeAll() }
}

/// `{n}` for each file of a batch: the preset's counter when it could be reserved, else counting on from the last number
/// given (the preset was deleted while its pages were on screen), so no two files of one save share a number.
public struct PartNumbers: Sendable {
    private var next: Int

    public init(_ next: Int) { self.next = next }

    /// - Parameter reserved: What `ScanPresets.reserve` gave for this file; nil when the preset is gone.
    public mutating func take(_ reserved: Int?) -> Int {
        let n = reserved ?? next
        next = n + 1
        return n
    }
}
