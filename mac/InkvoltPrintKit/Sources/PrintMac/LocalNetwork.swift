import Foundation
import Network
import Synchronization

/// Whether macOS lets the app reach this network (Local Network privacy). There is no API to ask for it or to read it, so
/// it's told from what happens: a browse or connection refused as Local Network denied, or a device that answers. While the
/// first-run alert is still open, connections fail the same way as when it was denied, so `denied` means "not allowed
/// (yet)".
public enum LocalNetworkAccess: Sendable, Equatable {
    /// Nothing has told yet.
    case unknown
    case denied
    case allowed
}

/// Collects what the transports and Bonjour see about Local Network access. Any thread.
public final class LocalNetworkSignal: Sendable {
    private let state = Mutex<(access: LocalNetworkAccess, onChange: (@Sendable (LocalNetworkAccess) -> Void)?)>((.unknown, nil))

    public init() {}

    public var access: LocalNetworkAccess { state.withLock { $0.access } }

    /// Called (on the thread that saw it) whenever the access changes.
    public func onChange(_ handler: @escaping @Sendable (LocalNetworkAccess) -> Void) { state.withLock { $0.onChange = handler } }

    public func denied() { set(.denied) }

    /// A device on this network answered (or Bonjour found one).
    public func answered() { set(.allowed) }

    private func set(_ access: LocalNetworkAccess) {
        let handler: (@Sendable (LocalNetworkAccess) -> Void)? = state.withLock { s in
            guard s.access != access else { return nil }
            s.access = access
            return s.onChange
        }
        handler?(access)
    }

    /// The error is Local Network privacy refusing the connection: URLSession's "not connected" (-1009) whose network path
    /// says `localNetworkDenied`.
    public static func isDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return false }
        if let path = ns.userInfo["_NSURLErrorNWPathKey"] as? NWPath { return path.unsatisfiedReason == .localNetworkDenied }
        return false
    }
}

/// System Settings panes the app sends the user to.
public enum SystemSettings {
    /// Privacy & Security › Local Network.
    public static let localNetwork = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
    /// Printers & Scanners (both forms open it on macOS 27; the probe checked).
    public static let printers = URL(string: "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension")!
}
