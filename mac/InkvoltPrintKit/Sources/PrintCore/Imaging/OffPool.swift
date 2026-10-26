import Dispatch

/// Runs CPU-heavy work (page analysis, straightening) on a Dispatch queue rather than Swift's cooperative thread pool, which
/// has one thread per core: work that never awaits would hold those threads and stall every other task (network reads,
/// timeouts) until it ends.
public func offPool<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}
