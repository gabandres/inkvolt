import Foundation

/// Blocking work (a socket's receive loop) on a thread of its own, never GCD's global pool: a busy machine gives the pool's
/// threads to other work, and a loop that waited for one started its clock late (CI's busy runner, 2026-11-06: SNMP's
/// 300 ms no-reply wait took 21.9 s). The thread ends with the work.
enum OwnThread {
    static func run(_ name: String, _ work: @escaping @Sendable () -> Void) {
        let thread = Thread(block: work)
        thread.name = name
        thread.qualityOfService = .userInitiated // a wait someone watches; the thread mostly sleeps in recv
        thread.start()
    }
}
