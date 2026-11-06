import Foundation
import MuPDFShim
import PrintCore

/// A page that isn't drawn or read (Windows' `PageRefusedException`): reading it took longer than its engine's
/// `pageBudget`, a picture on it is larger than `PdfEngine.maxPicturePixels`, or a stream on it is decompressed more
/// than twice in a row. The rest of the document goes on.
public struct PageRefused: Error, Equatable, Sendable, CustomStringConvertible {
    public let page: Int
    /// True: it took too long; false: a picture on it is too large to decode.
    public let tooSlow: Bool

    init(page: Int, tooSlow: Bool) {
        self.page = page
        self.tooSlow = tooSlow
    }

    /// What the user reads, with the page as they count it.
    public var message: String {
        tooSlow
            ? loc("Page {0} took too long to read, so it isn't shown. The rest of the document can still be used.", CoreLanguage.number(page + 1))
            : loc("Page {0} couldn't be read, so it isn't shown. The rest of the document can still be used.", CoreLanguage.number(page + 1))
    }

    public var description: String { message }
}

/// The pages a job over many pages (redaction's search and check, Prepare Form, Recognize Text, the AI assistant's
/// reading) skipped because the engine refused them, to say which, as Find does: one refused page doesn't stop the job.
public final class SkippedPages: @unchecked Sendable {
    private let lock = NSLock()
    private var pages = Set<Int>()

    public init() {}

    /// What `read` gives for a page, or nil when the engine refuses the page (kept, to be said).
    /// - Throws: whatever else `read` throws.
    public func unlessRefused<T>(_ read: () throws -> T) throws -> T? {
        do {
            return try read()
        } catch let refused as PageRefused {
            insert(refused.page)
            return nil
        }
    }

    func insert(_ page: Int) { lock.withLock { _ = pages.insert(page) } }

    public func contains(_ page: Int) -> Bool { lock.withLock { pages.contains(page) } }

    /// The skipped pages (from 0), in order.
    public var list: [Int] { lock.withLock { pages.sorted() } }

    /// "Pages that couldn't be read were skipped: 2, 5." (as the user counts them); nil when none were.
    public var note: String? { Self.note(list) }

    /// The same for `pages` (from 0).
    public static func note(_ pages: [Int]) -> String? {
        if pages.isEmpty { return nil }
        return loc("Pages that couldn't be read were skipped: {0}.", pages.sorted().map { CoreLanguage.number($0 + 1) }.joined(separator: ", "))
    }
}

/// What reading a page found (Windows' `PageVerdict`, without its check process's own outcomes).
public enum PageVerdict: Sendable, Equatable {
    /// Not read through yet.
    case unknown
    /// Read within the budget.
    case fine
    /// Its reading ran past the budget (the reading thread's own time), or a pattern's tiles would: refused from then on.
    case tooSlow
    /// A picture on it is larger than MuPDF may decode, or a stream on it is decompressed more than twice in a row:
    /// refused from then on.
    case failed

    public var refuses: Bool { self == .tooSlow || self == .failed }
}

/// An engine's verdicts on its pages, its budget, and the cookies of the calls reading its pages now (all its
/// instances and Find's threads), so closing the engine stops them at once.
final class PageVerdicts: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [Int: PageVerdict] = [:]
    private var seconds = PdfEngine.defaultPageBudget
    private var live: [Int: OpaquePointer] = [:]
    private var nextId = 0
    private var closedNow = false

    var budget: Double {
        get { lock.withLock { seconds } }
        set { lock.withLock { seconds = newValue } }
    }

    subscript(page: Int) -> PageVerdict { lock.withLock { found[page] ?? .unknown } }

    /// Keeps what a reading found: a refusal for good, `fine` only over `unknown`.
    func set(_ page: Int, _ verdict: PageVerdict) {
        lock.withLock {
            if verdict.refuses || found[page] == nil { found[page] = verdict }
        }
    }

    var closed: Bool { lock.withLock { closedNow } }

    /// Watches a call's cookie until `unwatch`: aborted now if the engine is closed, else when it closes.
    func watch(_ cookie: OpaquePointer) -> Int {
        lock.withLock {
            if closedNow { inkv_cookie_abort(cookie) }
            nextId += 1
            live[nextId] = cookie
            return nextId
        }
    }

    func unwatch(_ id: Int) { lock.withLock { live[id] = nil } }

    /// The engine is closing: every reading stops (their calls return at once and let go of the engine's locks).
    func close() {
        lock.withLock {
            closedNow = true
            for cookie in live.values { inkv_cookie_abort(cookie) }
        }
    }
}
