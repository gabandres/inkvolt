import Testing
@testable import PdfCore

/// Go › Previous View and Next View (Windows' `PageViewer` Back and Forward stacks, app code without tests there): a jump
/// is recorded, Back returns to where it was and Forward comes back again, a new jump forgets what Forward had. Mac
/// additions.
struct NavigationHistoryTests {
    private func at(_ page: Int, _ y: Double = 0) -> ViewPlace { ViewPlace(page: page, y: y) }

    @Test func aJumpIsRecordedSoBackReturnsToWhereItWas() {
        var history = NavigationHistory()
        #expect(!history.canGoBack && !history.canGoForward)
        history.record(at(0, 120))
        #expect(history.canGoBack && !history.canGoForward)
        #expect(history.back(from: at(4), pageCount: 10) == at(0, 120))
        #expect(!history.canGoBack && history.canGoForward)
        #expect(history.forward(from: at(0, 120), pageCount: 10) == at(4))
        #expect(history.canGoBack && !history.canGoForward)
    }

    @Test func backAndForwardWalkSeveralJumps() {
        var history = NavigationHistory()
        history.record(at(0))
        history.record(at(3))
        history.record(at(7))
        #expect(history.back(from: at(9), pageCount: 10) == at(7))
        #expect(history.back(from: at(7), pageCount: 10) == at(3))
        #expect(history.forward(from: at(3), pageCount: 10) == at(7))
        #expect(history.forward(from: at(7), pageCount: 10) == at(9))
        #expect(history.forward(from: at(9), pageCount: 10) == nil)
    }

    @Test func aNewJumpForgetsWhatForwardHad() {
        var history = NavigationHistory()
        history.record(at(0))
        _ = history.back(from: at(5), pageCount: 10)
        #expect(history.canGoForward)
        history.record(at(0))
        #expect(!history.canGoForward)
    }

    @Test func aPlaceOnAPageThatIsGoneIsSkipped() {
        // Windows: the place is taken off and nothing moves when its page is past the end (pages were deleted).
        var history = NavigationHistory()
        history.record(at(8))
        #expect(history.back(from: at(1), pageCount: 3) == nil)
        #expect(!history.canGoBack && history.canGoForward)
    }

    @Test func clearingForgetsBothWays() {
        var history = NavigationHistory()
        history.record(at(1))
        _ = history.back(from: at(2), pageCount: 5)
        history.record(at(3))
        history.clear()
        #expect(!history.canGoBack && !history.canGoForward)
    }

    @Test func theHistoryKeepsAtMostItsLimit() {
        var history = NavigationHistory()
        for p in 0..<(NavigationHistory.limit + 20) { history.record(at(p)) }
        var steps = 0
        var here = at(-1)
        while let place = history.back(from: here, pageCount: 10_000) {
            here = place
            steps += 1
        }
        #expect(steps == NavigationHistory.limit)
        #expect(here == at(20)) // the oldest places went first
    }
}
