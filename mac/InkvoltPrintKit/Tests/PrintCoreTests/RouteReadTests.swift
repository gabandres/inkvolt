import Foundation
import Testing
@testable import PrintCore

/// Ported from RouteReadTests.cs: what a tab reads of its printer's route (`RouteRead`): two-sided on Print and Copy, Print
/// photos' options, a batch's queue. Read once asked, again after a change of route only if it was asked, and again when the
/// route changed during a read. Mac difference: a read starts once the caller yields, so the tests wait for it (`until`) where
/// Windows' starts at once.
@MainActor
struct RouteReadTests {
    /// A read the test ends (`finish`), counting reads and the route each was started on.
    @MainActor
    final class Reads {
        private var pending: CheckedContinuation<Bool, Never>?
        var started: [String] = []
        var route = "queue"
        var waits = false
        var answers = true

        func reader() -> RouteRead { RouteRead { await self.read() } }

        private func read() async -> Bool {
            started.append(route)
            if !waits { return answers }
            return await withCheckedContinuation { pending = $0 }
        }

        var isWaiting: Bool { pending != nil }

        func finish() {
            let p = pending
            pending = nil
            p?.resume(returning: answers)
        }
    }

    @Test func nothingIsReadUntilAskedAndThenOnce() async {
        let reads = Reads()
        let read = reads.reader()
        read.routeChanged() // a tab never shown reads nothing
        await Task.yield()
        #expect(reads.started.isEmpty)
        await read.ask().value
        await read.ask().value
        #expect(reads.started.count == 1)
        #expect(read.isRead)
    }

    @Test func onceAskedAChangeOfRouteReadsAgainAtOnce() async {
        let reads = Reads()
        let read = reads.reader()
        await read.ask().value
        reads.route = "direct"
        await read.routeChanged()?.value
        #expect(reads.started == ["queue", "direct"])
        #expect(read.isRead)
        await read.ask().value
        #expect(reads.started.count == 2)
    }

    @Test func aChangeDuringAReadReadsAgainWhenItEnds() async {
        let reads = Reads()
        reads.waits = true
        let read = reads.reader()
        let asked = read.ask()
        #expect(read.isReading)
        await until { reads.isWaiting }
        reads.route = "direct"
        #expect(read.routeChanged() == nil) // the read under way is the old route's
        #expect(reads.started.count == 1) // one read at a time
        #expect(read.ask() == asked) // asking meanwhile waits for the same reads

        reads.finish() // the old route's answer: not kept as read, read again
        await until { reads.isWaiting }
        #expect(reads.started == ["queue", "direct"])
        #expect(!read.isRead)
        reads.finish()
        await asked.value
        #expect(read.isRead)
        #expect(!read.isReading)
    }

    @Test func aReadWithoutAnAnswerIsAskedAgain() async {
        let reads = Reads()
        reads.answers = false // no queue yet, say
        let read = reads.reader()
        await read.ask().value
        #expect(!read.isRead)
        reads.answers = true
        await read.ask().value
        #expect(reads.started.count == 2)
        #expect(read.isRead)
    }
}
