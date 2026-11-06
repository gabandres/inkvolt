import Foundation
import PrintCore

/// A page that isn't drawn or read (Windows' `PageRefusedException`): reading it took longer than its engine's
/// `pageBudget`, or a picture on it is larger than `PdfEngine.maxPictureSamples`. The rest of the document goes on.
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

/// What reading a page found (Windows' `PageVerdict`, without its check process's own outcomes).
public enum PageVerdict: Sendable, Equatable {
    /// Not read through yet.
    case unknown
    /// Read within the budget.
    case fine
    /// Its reading ran past the budget: refused from then on.
    case tooSlow
    /// A picture on it is larger than MuPDF may decode: refused from then on.
    case failed

    var refuses: Bool { self == .tooSlow || self == .failed }
}

/// An engine's verdicts on its pages and its budget, shared by its instances and Find's threads.
final class PageVerdicts: @unchecked Sendable {
    private let lock = NSLock()
    private var found: [Int: PageVerdict] = [:]
    private var seconds = PdfEngine.defaultPageBudget

    var budget: Double {
        get { lock.withLock { seconds } }
        set { lock.withLock { seconds = newValue } }
    }

    subscript(page: Int) -> PageVerdict { lock.withLock { found[page] ?? .unknown } }
}
