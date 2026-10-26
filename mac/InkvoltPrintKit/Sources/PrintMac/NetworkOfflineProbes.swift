import Foundation
import PrintCore
import Synchronization

/// The offline fixer's network checks on this Mac: a fresh Bonjour browse for the printer's UUID (up to `lookup`), and
/// which printer ports answer TCP at an address.
public struct NetworkOfflineProbes: OfflineProbes {
    public static let lookup: Duration = .seconds(8)

    private let localNetwork: LocalNetworkSignal?

    public init(localNetwork: LocalNetworkSignal? = nil) { self.localNetwork = localNetwork }

    public func rediscover(_ uuid: String) async throws -> Rediscovery? {
        let seen = Seen()
        let (changes, changed) = AsyncStream.makeStream(of: Void.self)
        let discovery = BonjourDiscovery(localNetwork: localNetwork) { services in
            seen.list.withLock { $0 = services }
            changed.yield()
        }
        discovery.start()
        defer {
            discovery.stop()
            changed.finish()
        }
        let deadline = ContinuousClock.now + Self.lookup
        let timer = Task {
            try? await Task.sleep(until: deadline)
            changed.finish()
        }
        defer { timer.cancel() }
        for await _ in changes {
            try Task.checkCancellation()
            // Found with an address: done (more services may follow, but one address is what's asked).
            if let found = Rediscovery.from(DiscoveredPrinters.join(seen.list.withLock { $0 }), uuid: uuid) { return found }
        }
        try Task.checkCancellation()
        return Rediscovery.from(DiscoveredPrinters.join(seen.list.withLock { $0 }), uuid: uuid)
    }

    /// What the browse has seen (a class: Xcode's Swift won't send a closure that captures a local `Mutex`).
    private final class Seen: Sendable {
        let list = Mutex<[AnnouncedService]>([])
    }

    public func reach(_ host: String) async throws -> Reachability {
        try await Reachability.check(host, with: SocketNetworkScanner(localNetwork: localNetwork))
    }
}
