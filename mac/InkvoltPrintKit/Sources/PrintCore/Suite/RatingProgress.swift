import Foundation

/// When Inkvolt Print asks for an App Store rating (the Windows app's `RatingProgress`, there for the Microsoft Store): once
/// ever, after the app has done its job for the person `successesNeeded` times (saved a scan or sent a print), the first of
/// them at least `wait` ago, so never during the first session. macOS's own rating prompt does the asking (and may show
/// nothing: it decides); asking counts as asked. Kept in the state file; nothing leaves the Mac.
public struct RatingProgress: Equatable, Sendable, Codable {
    public static let successesNeeded = 5
    public static let wait: TimeInterval = 2 * 24 * 3600

    /// How many times the app has done its job.
    public var successes: Int
    /// When it first did.
    public var firstSuccess: Date?
    /// When the rating prompt was asked for, if it was.
    public var asked: Date?

    public init(successes: Int = 0, firstSuccess: Date? = nil, asked: Date? = nil) {
        self.successes = successes
        self.firstSuccess = firstSuccess
        self.asked = asked
    }

    public init(from decoder: any Decoder) throws {
        // Every field optional, and a hand edit's nonsense is nothing, so the state file always loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        successes = max(0, (try? c.decodeIfPresent(Int.self, forKey: .successes)) ?? 0)
        firstSuccess = try? c.decodeIfPresent(Date.self, forKey: .firstSuccess)
        asked = try? c.decodeIfPresent(Date.self, forKey: .asked)
    }

    public func record(_ now: Date) -> RatingProgress {
        RatingProgress(successes: successes == Int.max ? successes : successes + 1, firstSuccess: firstSuccess ?? now, asked: asked)
    }

    public func shouldAsk(_ now: Date) -> Bool {
        guard asked == nil, successes >= Self.successesNeeded, let first = firstSuccess else { return false }
        return now.timeIntervalSince(first) >= Self.wait
    }

    public func markAsked(_ now: Date) -> RatingProgress {
        RatingProgress(successes: successes, firstSuccess: firstSuccess, asked: asked ?? now)
    }

    /// Two copies of the progress (the state file and another process's): the higher count, the earliest first success,
    /// and asked if either asked, so the prompt never comes twice.
    public static func merge(_ a: RatingProgress?, _ b: RatingProgress?) -> RatingProgress? {
        guard let a else { return b }
        guard let b else { return a }
        return RatingProgress(successes: max(a.successes, b.successes), firstSuccess: earliest(a.firstSuccess, b.firstSuccess),
                              asked: earliest(a.asked, b.asked))
    }

    private static func earliest(_ a: Date?, _ b: Date?) -> Date? {
        guard let a else { return b }
        guard let b else { return a }
        return min(a, b)
    }
}
