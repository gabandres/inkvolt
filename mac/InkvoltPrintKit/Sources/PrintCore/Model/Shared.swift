import Synchronization

/// A value several tasks change, behind a lock. A class, so task closures share it by reference (Xcode's Swift won't send
/// a closure that captures a local `Mutex`).
final class Shared<Value: Sendable>: Sendable {
    private let lock: Mutex<Value>

    init(_ value: Value) { lock = Mutex(value) }

    func withLock<T: Sendable>(_ body: (inout Value) -> T) -> T { lock.withLock { body(&$0) } }
}
