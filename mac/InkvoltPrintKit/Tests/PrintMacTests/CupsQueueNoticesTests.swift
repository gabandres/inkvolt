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

    @Test func stopStopsThem() {
        let notices = CupsQueueNotices(interval: { () -> Duration? in nil }) {}
        notices.stop()
        #expect(!notices.isRunning)
    }
}
