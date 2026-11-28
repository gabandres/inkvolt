import Foundation
import Testing
@testable import PdfCore

/// `CancelToken.off` (Finder's Convert to Word waits on it; a Mac addition, no Windows tests): the work waited for until
/// it ends or Cancel fires. Pre-release review: after Cancel, a DocumentSession still being opened finished and was never
/// closed (its bytes and MuPDF context kept); what work makes after Cancel won now goes to `discard`.
struct CancelTokenOffTests {
    private final class Made: @unchecked Sendable {
        private let lock = NSLock()
        private var closed = 0
        var closings: Int { lock.withLock { closed } }
        func close() { lock.withLock { closed += 1 } }
    }

    /// Up to 10 s (a semaphore can't be waited on from an async context itself).
    private static func waited(_ s: DispatchSemaphore) -> Bool { s.wait(timeout: .now() + 10) == .success }

    @Test func whatWorkMakesAfterCancelWonIsDiscarded() async throws {
        let cancel = CancelToken()
        let release = DispatchSemaphore(value: 0), discarded = DispatchSemaphore(value: 0)
        let made = Made()
        let waiting = Task {
            try await cancel.off({ release.wait(); return made }, discard: { $0.close(); discarded.signal() })
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        cancel.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(made.closings == 0) // the work hasn't ended yet: Cancel didn't wait for it
        release.signal()
        #expect(Self.waited(discarded))
        #expect(made.closings == 1)
    }

    @Test func whatWorkMakesBeforeCancelIsReturnedNotDiscarded() async throws {
        let cancel = CancelToken()
        let made = Made()
        let got = try await cancel.off({ made }, discard: { $0.close() })
        cancel.cancel()
        #expect(got === made && made.closings == 0)
        // Cancelled before it starts: CancellationError, and what the work still makes is discarded.
        let late = Made(), discarded = DispatchSemaphore(value: 0)
        await #expect(throws: CancellationError.self) {
            try await cancel.off({ late }, discard: { $0.close(); discarded.signal() })
        }
        #expect(Self.waited(discarded))
        #expect(late.closings == 1)
    }
}
