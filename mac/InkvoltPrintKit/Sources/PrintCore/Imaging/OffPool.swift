import Foundation

/// Runs CPU-heavy work (page analysis, straightening) off Swift's cooperative thread pool, which has one thread per core:
/// work that never awaits would hold those threads and stall every other task (network reads, timeouts) until it ends.
/// At most one task fewer than the cores run at once, so a core stays free for them even while pages are analysed in
/// parallel (the IPP timing tests stalled behind a full set of straightening checks).
public func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        OffPool.queue.addOperation { continuation.resume(returning: work()) }
    }
}

enum OffPool {
    static let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "inkvolt.page-work"
        q.qualityOfService = .userInitiated
        q.maxConcurrentOperationCount = max(1, ProcessInfo.processInfo.activeProcessorCount - 1)
        return q
    }()
}
