import Foundation
import Testing

/// Keeps a suite's tests off Swift's cooperative thread pool: `@Suite(.offThePool)` on a suite whose tests keep a core busy
/// for seconds without suspending (whole pages of image work, two halves cross-correlated, scans of the sources).
/// swift-testing runs every test on that pool, one thread a core, and a synchronous test holds its thread to the end: on
/// GitHub's 3-core runner three such tests at once left no thread for anything else, so every test waiting on a time limit
/// (a printer that never answers, a check its caller cancels) stood still for a minute and a half and failed. Here each
/// test case runs on a thread of an operation queue instead (its task's executor preference; `#expect` still reports to
/// its test), and the pool's threads stay free to wake the rest.
public struct OffThePool: SuiteTrait, TestTrait, TestScoping {
    fileprivate let executor: QueueExecutor

    public var isRecursive: Bool { true }

    /// Each test case's own run, not the suite's.
    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? { testCase == nil ? nil : self }

    public func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        try await withTaskExecutorPreference(executor) { try await function() }
    }
}

extension Trait where Self == OffThePool {
    /// Work with no clock of its own (`OffThePool`), at utility: below the tests' own tasks, so a test waiting on a time
    /// limit gets a core first when its timer fires (at user-initiated, as `offPool`, the build Mac's full run failed seven
    /// to nine timing tests).
    public static var offThePool: Self { OffThePool(executor: .utility) }

    /// Work that keeps time itself (SNMPv3's requests, 1 s each, around seconds of key work): off the pool too, but at the
    /// tests' own priority, above the image work. At utility CI's runner let those requests run out.
    public static var offThePoolOnTime: Self { OffThePool(executor: .onTime) }
}

/// A task executor over an operation queue's own threads, not the cooperative pool's: at most one job fewer than the cores
/// at once, as PrintCore's `offPool` runs the app's page work, so a core stays free for the rest.
final class QueueExecutor: TaskExecutor {
    static let utility = QueueExecutor("TestTiming.OffThePool", .utility)
    static let onTime = QueueExecutor("TestTiming.OffThePoolOnTime", .default)

    private let queue: OperationQueue

    private init(_ name: String, _ quality: QualityOfService) {
        let q = OperationQueue()
        q.name = name
        q.qualityOfService = quality
        q.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        queue = q
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        queue.addOperation { job.runSynchronously(on: executor) }
    }
}
