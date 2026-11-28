import Foundation
import Testing
@testable import PrintCore

/// When Inkvolt Print asks for a rating: once, after the app has done its job a few times on different days. Ported from
/// RatingPromptTests.cs. Adapted: `Merge`'s "the same object" is equality (a value type), and the JSON round trip is the
/// state file's (`PrintState.rating`).
struct RatingPromptTests {
    private static let day0 = ISO8601DateFormatter().date(from: "2026-11-02T09:00:00-04:00")!

    private static func done(_ times: Int, _ first: Date) -> RatingProgress {
        var progress = RatingProgress()
        for i in 0..<times { progress = progress.record(first.addingTimeInterval(Double(i) * 60)) }
        return progress
    }

    private static func days(_ n: Double) -> TimeInterval { n * 24 * 3600 }

    @Test func NewInstallNeverAsks() {
        #expect(!RatingProgress().shouldAsk(Self.day0))
        #expect(!RatingProgress().shouldAsk(Self.day0.addingTimeInterval(Self.days(365))))
    }

    @Test func AsksAfterEnoughSuccessesOnceTheFirstIsOldEnough() {
        let progress = Self.done(RatingProgress.successesNeeded, Self.day0)
        #expect(!progress.shouldAsk(Self.day0.addingTimeInterval(3 * 3600))) // same session: too soon
        #expect(!progress.shouldAsk(Self.day0.addingTimeInterval(RatingProgress.wait - 60)))
        #expect(progress.shouldAsk(Self.day0.addingTimeInterval(RatingProgress.wait)))
    }

    @Test func FewerSuccessesNeverAsk() {
        let progress = Self.done(RatingProgress.successesNeeded - 1, Self.day0)
        #expect(!progress.shouldAsk(Self.day0.addingTimeInterval(Self.days(30))))
    }

    @Test func AsksOnlyOnceEvenIfDismissed() {
        let progress = Self.done(RatingProgress.successesNeeded, Self.day0)
        let later = Self.day0.addingTimeInterval(Self.days(5))
        #expect(progress.shouldAsk(later))
        let asked = progress.markAsked(later)
        #expect(!asked.shouldAsk(later))
        #expect(!asked.record(later.addingTimeInterval(Self.days(1))).shouldAsk(later.addingTimeInterval(Self.days(60))))
        #expect(asked.markAsked(later.addingTimeInterval(Self.days(9))).asked == later) // the first ask is kept
    }

    @Test func FirstSuccessIsKeptAndCountsGrow() {
        let progress = RatingProgress().record(Self.day0).record(Self.day0.addingTimeInterval(Self.days(3)))
        #expect(progress.successes == 2)
        #expect(progress.firstSuccess == Self.day0)
    }

    @Test func ClockSetBackDoesNotAsk() {
        let progress = Self.done(RatingProgress.successesNeeded, Self.day0)
        #expect(!progress.shouldAsk(Self.day0.addingTimeInterval(-Self.days(3))))
    }

    @Test func MergingTwoWindowsKeepsTheAskAndTheHigherCount() throws {
        let asked = Self.done(RatingProgress.successesNeeded, Self.day0).markAsked(Self.day0.addingTimeInterval(Self.days(3)))
        let other = Self.done(RatingProgress.successesNeeded + 2, Self.day0.addingTimeInterval(Self.days(1)))
        let merged = try #require(RatingProgress.merge(other, asked))
        #expect(merged.successes == RatingProgress.successesNeeded + 2)
        #expect(merged.firstSuccess == Self.day0)
        #expect(merged.asked == Self.day0.addingTimeInterval(Self.days(3)))
        #expect(!merged.shouldAsk(Self.day0.addingTimeInterval(Self.days(10))))
        #expect(RatingProgress.merge(nil, asked) == asked)
        #expect(RatingProgress.merge(asked, nil) == asked)
        #expect(RatingProgress.merge(nil, nil) == nil)
    }

    @Test func RoundTripsThroughSettingsJson() throws {
        let progress = Self.done(RatingProgress.successesNeeded, Self.day0).markAsked(Self.day0.addingTimeInterval(Self.days(4)))
        var state = PrintState()
        state.rating = progress
        let back = try JSONDecoder().decode(PrintState.self, from: JSONEncoder().encode(state))
        #expect(back.rating == progress)
        #expect(try JSONDecoder().decode(RatingProgress.self, from: Data("{}".utf8)) == RatingProgress())
        // Mac only: a hand edit's nonsense loads as nothing rather than losing the state file.
        #expect(try JSONDecoder().decode(RatingProgress.self, from: Data(#"{"successes":"x","asked":true}"#.utf8)) == RatingProgress())
        #expect(try JSONDecoder().decode(PrintState.self, from: Data(#"{"rating":7}"#.utf8)).rating == nil)
    }
}
