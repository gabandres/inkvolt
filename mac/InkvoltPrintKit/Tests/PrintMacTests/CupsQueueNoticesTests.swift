import Foundation
import PrintCore
import Testing
@testable import PrintMac

/// The queue notices' thread holds only its pace and state, never the notices themselves: stopping them, or letting them
/// go, ends it (the loop itself is PrintCore's `PollingLoop`, tested in QueueChangeTests). Each asks this Mac's cupsd once
/// (the subscription, then the list), then waits: the pace given is nil, a closed window's.
@Suite(.serialized)
struct CupsQueueNoticesTests {
    @Test func noticesLetGoAreStopped() {
        weak var gone: CupsQueueNotices?
        var pace: PollingLoop?
        do {
            let notices = CupsQueueNotices(interval: { () -> Duration? in nil }) {}
            gone = notices
            pace = notices.pace
            #expect(notices.isRunning)
        }
        #expect(gone == nil) // the thread didn't keep them
        #expect(pace?.isRunning == false)
    }

    /// The next event asked for: past the last one seen, never back; at Int32.max there's none (the hostile-input review:
    /// `+ 1` overflowed), so the loop subscribes again.
    @Test func theNextSequenceNeverOverflows() {
        #expect(CupsQueueNotices.nextSequence(after: 5, atLeast: 1) == 6)
        #expect(CupsQueueNotices.nextSequence(after: 2, atLeast: 9) == 9)
        #expect(CupsQueueNotices.nextSequence(after: Int32.max - 1, atLeast: 1) == Int32.max)
        #expect(CupsQueueNotices.nextSequence(after: Int32.max, atLeast: 1) == nil)
        #expect(CupsQueueNotices.nextSequence(after: Int32.min, atLeast: 1) == 1)
    }

    @Test func stopStopsThem() {
        let notices = CupsQueueNotices(interval: { () -> Duration? in nil }) {}
        notices.stop()
        #expect(!notices.isRunning)
    }
}
