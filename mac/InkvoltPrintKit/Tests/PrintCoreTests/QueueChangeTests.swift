import Foundation
import Synchronization
import Testing
import TestTiming
@testable import PrintCore

/// Queue change notices: a burst of them read as one. Ported from QueueChangeTests.cs; its spooler tests
/// (A_notice_means_reading_the_queues_again_only_when_the_list_may_have_changed, Notices_lost_ask_the_spooler_for_everything_again,
/// The_fields_asked_for_are_name_port_and_driver) are Windows' FindFirstPrinterChangeNotification's and have no Mac
/// counterpart (`CupsQueueNotices` polls macOS's queue list, whose cupsd takes no subscriptions).
@Suite(.serialized) // quiet periods
struct QueueChangeTests {
    private final class Count: Sendable {
        private let n = Mutex(0)
        func add() { n.withLock { $0 += 1 } }
        var value: Int { n.withLock { $0 } }
    }

    private static func settle(_ count: Count, _ expected: Int) async -> Int {
        let limit = ContinuousClock.now + Timing.limit(.seconds(5))
        while count.value < expected && ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: Timing.limit(.milliseconds(400))) // and no more after
        return count.value
    }

    @Test func aBurstOfNoticesReadsTheQueuesOnce() async {
        let calls = Count()
        let notices = QueueChangeNotices(quiet: .milliseconds(150), longest: .seconds(5)) { calls.add() }
        defer { notices.close() }
        for _ in 0..<50 { notices.notice() } // a rename: a delete, an add, field changes, a moment apart
        #expect(await Self.settle(calls, 1) == 1)

        notices.notice() // another change later: read again
        #expect(await Self.settle(calls, 2) == 2)
    }

    @Test func noticesThatNeverStopStillReadTheQueues() async {
        let calls = Count()
        let notices = QueueChangeNotices(quiet: .milliseconds(300), longest: .milliseconds(400)) { calls.add() }
        defer { notices.close() }
        let until = ContinuousClock.now + .milliseconds(1500)
        while ContinuousClock.now < until {
            notices.notice()
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(calls.value >= 1, "never read while notices kept coming")
    }

    @Test func nothingIsReadAfterTheWatchIsClosed() async {
        let calls = Count()
        let notices = QueueChangeNotices(quiet: .milliseconds(100), longest: .seconds(1)) { calls.add() }
        notices.notice()
        notices.close()
        notices.notice()
        try? await Task.sleep(for: .milliseconds(300))
        #expect(calls.value == 0)
    }
}
