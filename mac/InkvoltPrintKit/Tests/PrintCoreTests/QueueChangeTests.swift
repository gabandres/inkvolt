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

    // MARK: Polling macOS's queue list (Mac only: its cupsd takes no subscriptions)

    @Test func theQueueListIsPolledOnlyWhileTheWindowShowsAndLessOftenWhenSaving() {
        #expect(QueueNoticePolling.interval(windowOpen: true, onBattery: false, lowPower: false) == Duration.seconds(2))
        #expect(QueueNoticePolling.interval(windowOpen: true, onBattery: true, lowPower: false) == Duration.seconds(6))
        #expect(QueueNoticePolling.interval(windowOpen: true, onBattery: false, lowPower: true) == Duration.seconds(6))
        #expect(QueueNoticePolling.interval(windowOpen: false, onBattery: false, lowPower: false) == nil)
        #expect(QueueNoticePolling.interval(windowOpen: false, onBattery: true, lowPower: true) == nil)
    }

    private struct Conditions {
        var window = true
        var battery = false
        var lowPower = false
    }

    /// The conditions a loop reads, and the waits a fake clock was asked for.
    private final class Fake: Sendable {
        let conditions = Mutex(Conditions())
        let waits = Mutex<[Duration]>([])

        var interval: @Sendable () -> Duration? {
            { [self] () -> Duration? in
                let c = conditions.withLock { $0 }
                return QueueNoticePolling.interval(windowOpen: c.window, onBattery: c.battery, lowPower: c.lowPower)
            }
        }

        var sleep: @Sendable (Duration) -> Void {
            { [self] (d: Duration) -> Void in waits.withLock { $0.append(d) } }
        }
    }

    @Test func theLoopWaitsAsTheRuleSaysAsConditionsChange() {
        let fake = Fake()
        let loop = PollingLoop(interval: fake.interval, sleep: fake.sleep)
        var polls = 0
        while loop.pause() {
            polls += 1
            if polls == 2 { fake.conditions.withLock { $0.battery = true } }
            if polls == 3 { fake.conditions.withLock { $0.battery = false; $0.lowPower = true } }
            if polls == 4 { fake.conditions.withLock { $0.lowPower = false } }
            if polls == 5 { loop.stop() }
        }
        let expected: [Duration] = [.seconds(2), .seconds(2), .seconds(6), .seconds(6), .seconds(2)]
        #expect(fake.waits.withLock { $0 } == expected)
        #expect(polls == 5)
        #expect(!loop.pause()) // stopped stays stopped, without waiting
        #expect(fake.waits.withLock { $0.count } == 5)
    }

    /// A loop on a thread of its own, counting its polls.
    private final class Runner: Sendable {
        let polls = Mutex(0)
        let ended = Mutex(false)

        init(_ loop: PollingLoop) {
            let thread = Thread { [self] in
                while loop.pause() { polls.withLock { $0 += 1 } }
                ended.withLock { $0 = true }
            }
            thread.start()
        }

        var count: Int { polls.withLock { $0 } }
        var isEnded: Bool { ended.withLock { $0 } }

        func settle(_ done: @Sendable (Runner) -> Bool) async -> Bool {
            let limit = ContinuousClock.now + Timing.limit(.seconds(5))
            while !done(self) && ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(10)) }
            return done(self)
        }
    }

    @Test func aClosedWindowPollsNothingUntilItOpensAgain() async {
        let fake = Fake()
        fake.conditions.withLock { $0.window = false }
        let loop = PollingLoop(interval: fake.interval, sleep: fake.sleep)
        let runner = Runner(loop)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(runner.count == 0)

        fake.conditions.withLock { $0.window = true }
        loop.wake() // the window opened: a poll now, then the fake clock's 2 s
        #expect(await runner.settle { $0.count >= 3 })

        loop.stop()
        #expect(await runner.settle { $0.isEnded })
    }

    @Test func aWindowClosedInTheMiddleOfAWaitPollsNothingMore() async {
        let fake = Fake()
        let loop = PollingLoop(interval: fake.interval) { (d: Duration) -> Void in
            fake.waits.withLock { $0.append(d) }
            fake.conditions.withLock { $0.window = false } // closed while the 2 s go by
        }
        let runner = Runner(loop)
        try? await Task.sleep(for: .milliseconds(200))
        #expect(runner.count == 0)
        #expect(fake.waits.withLock { $0 } == [Duration.seconds(2)])

        fake.conditions.withLock { $0.window = true }
        loop.wake()
        #expect(await runner.settle { $0.count >= 1 })
        loop.stop()
        #expect(await runner.settle { $0.isEnded })
    }

    @Test func stopEndsALoopInTheMiddleOfAWait() async {
        let loop = PollingLoop(interval: { () -> Duration? in .seconds(3600) }) // the real wait, an hour
        let runner = Runner(loop)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(runner.count == 0)
        let asked = ContinuousClock.now
        loop.stop()
        #expect(await runner.settle { $0.isEnded })
        #expect(ContinuousClock.now - asked < Timing.limit(.seconds(5))) // of an hour
        #expect(runner.count == 0)
    }

    @Test func aWindowClosedWaitEndsOnStopToo() async {
        let loop = PollingLoop(interval: { () -> Duration? in nil })
        let runner = Runner(loop)
        try? await Task.sleep(for: .milliseconds(100))
        loop.stop()
        #expect(await runner.settle { $0.isEnded })
        #expect(runner.count == 0)
    }
}
