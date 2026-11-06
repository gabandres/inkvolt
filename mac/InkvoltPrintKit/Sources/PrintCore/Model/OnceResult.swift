import Synchronization

/// A continuation resumed once: by the work's end, a timeout or a cancel, whichever comes first. Finished before the
/// continuation is there, it resumes as soon as it is. Lets a wait end on the cancel or timeout itself, not when the thread
/// doing the work (a GCD thread a busy machine may not give for seconds, a blank-page check) gets to look: SNMP's exchange,
/// Search my network's port check, Scan's blank check.
public final class OnceResult<Value: Sendable>: Sendable {
    private let state = Mutex<(continuation: CheckedContinuation<Value, Never>?, ended: Value?)>((nil, nil))

    public init() {}

    public func start(_ continuation: CheckedContinuation<Value, Never>) {
        let ended: Value? = state.withLock { s in
            if let ended = s.ended { return ended }
            s.continuation = continuation
            return nil
        }
        if let ended { continuation.resume(returning: ended) }
    }

    public func finish(_ result: Value) {
        let waiting: CheckedContinuation<Value, Never>? = state.withLock { s in
            if s.ended != nil { return nil }
            s.ended = result
            let c = s.continuation
            s.continuation = nil
            return c
        }
        waiting?.resume(returning: result)
    }
}
