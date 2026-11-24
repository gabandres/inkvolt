import Foundation
import Testing

/// Keeps a suite's tests off Swift's cooperative thread pool: `@Suite(.offThePool)` on a suite whose tests keep a core busy
/// for seconds without suspending (whole pages of image work, two halves cross-correlated, SNMPv3 keys from passphrases).
/// swift-testing runs every test on that pool, one thread a core, and a synchronous test holds its thread to the end: on
/// GitHub's 3-core runner three such tests at once left no thread for anything else, so every test waiting on a time limit
/// (a printer that never answers, a check its caller cancels) stood still for a minute and a half and failed. Here each
/// test case runs on a thread of an operation queue instead (its task's executor preference; `#expect` still reports to
/// its test), and the pool's threads stay free to wake the rest.
public struct OffThePool: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    /// Each test case's own run, not the suite's.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await withTaskExecutorPreference(QueueExecutor.shared) { try await function() }
    }
}

extension Trait where Self == OffThePool {
    /// Runs the tests off the cooperative thread pool (`OffThePool`).
    public static var offThePool: Self { OffThePool() }
}

/// A task executor over an operation queue's own threads, not the cooperative pool's: at most one job fewer than the cores
/// at once, as PrintCore's `offPool` runs the app's page work, so a core stays free for the rest. The queue's default
/// quality of service, the tests' own: above it (user-initiated, as `offPool`) the build Mac's full run failed seven to nine
/// timing tests; below it (utility) CI's runner left Vision reading no codes and SNMPv3's requests their 1 s.
final class QueueExecutor: TaskExecutor {
    static let shared = QueueExecutor()
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "TestTiming.OffThePool"
        q.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        return q
    }()

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.addOperation { job.runSynchronously(on: executor) }
    }
}
