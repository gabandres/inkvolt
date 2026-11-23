import CoreLocation
import CoreWLAN
import Foundation
import PrintCore
import SystemConfiguration

/// This Mac's Wi-Fi for the new-printer setup guide (roadmap 4.17), read through CoreWLAN: where it is, the networks nearby
/// and the gateway it was given. Read only: the app never joins or leaves a network (PLAN, "Mac differences"). macOS 14 and
/// later give Wi-Fi names only to an app with location access (`WifiLocation`); without it the scan throws
/// `WifiLocationError`, so the guide says how to turn it on. The scan takes a few seconds and runs off the caller's thread.
public struct CoreWifi: WifiReading {
    public init() {}

    private static var interface: CWInterface? { CWWiFiClient.shared().interface() }

    public func now() async throws -> WifiNow {
        guard let wifi = Self.interface else { return .noAdapter }
        return WifiNow(hasAdapter: true, ssid: wifi.ssidData().map { [UInt8]($0) })
    }

    public func nearby() async throws -> [WifiNetwork] {
        guard WifiLocation.allowed else { throw WifiLocationError() }
        return try await Task.detached(priority: .userInitiated) { () throws -> [WifiNetwork] in
            guard let wifi = Self.interface else { return [] }
            let found = try wifi.scanForNetworks(withSSID: nil)
            let networks = found.compactMap { n -> WifiNetwork? in
                guard let ssid = n.ssidData, !ssid.isEmpty else { return nil } // hidden, or no location access after all
                return WifiNetwork(ssid: [UInt8](ssid), signal: WifiNetwork.quality(rssi: n.rssiValue), secured: !n.supportsSecurity(.none))
            }
            if networks.isEmpty && !found.isEmpty { throw WifiLocationError() } // names withheld: location access is off
            return networks
        }.value
    }

    /// The router of the network service on the Wi-Fi interface (SystemConfiguration's dynamic store), IPv4 only.
    public func gateway() async -> String? {
        guard let name = Self.interface?.interfaceName,
              let store = SCDynamicStoreCreate(nil, "InkvoltPrint" as CFString, nil, nil),
              let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/[^/]+/IPv4" as CFString) as? [String] else { return nil }
        for key in keys.prefix(64) {
            guard let value = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  value["InterfaceName"] as? String == name, let router = value["Router"] as? String else { continue }
            return router
        }
        return nil
    }

    /// What the report says of this Mac's Wi-Fi, with no network's name and no address (`--report … --wifi`).
    public static func reportLines() async -> [String] {
        guard let wifi = interface else { return ["wifi: no interface"] }
        var lines = ["wifi: interface found, power \(wifi.powerOn() ? "on" : "off"), location \(WifiLocation.statusWord)",
                     "wifi: current network's name \(wifi.ssidData() == nil ? "withheld or none" : "given")"]
        do {
            let (count, named) = try await Task.detached { () throws -> (Int, Int) in
                guard let found = try Self.interface?.scanForNetworks(withSSID: nil) else { return (0, 0) }
                return (found.count, found.filter { $0.ssidData?.isEmpty == false }.count)
            }.value
            lines.append("wifi: scan returned \(count) networks, \(named) with their names")
        } catch {
            lines.append("wifi: scan refused: \((error as NSError).domain) \((error as NSError).code)")
        }
        let gateway = await CoreWifi().gateway()
        lines.append("wifi: gateway \(gateway == nil ? "none" : SetupNetworks.setupPage(gateway) == nil ? "found, not private" : "found, private")")
        return lines
    }
}

/// Location access for Wi-Fi names (the setup guide's one use of it; the owner approved the entitlement): asked only from
/// the person's click in the guide, with the usage text in Info.plist. Main thread, as CLLocationManager's delegate.
@MainActor
public final class WifiLocation: NSObject, CLLocationManagerDelegate {
    public static let shared = WifiLocation()
    private let manager = CLLocationManager()
    private var waiting: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private var timers: [UUID: Task<Void, Never>] = [:]

    override private init() {
        super.init()
        manager.delegate = self
    }

    /// Location access was given (the guide may list networks).
    public nonisolated static var allowed: Bool { isAllowed(CLLocationManager().authorizationStatus) }

    /// Always, or when in use (raw 4: macOS answers a when-in-use request with always, but either counts).
    nonisolated static func isAllowed(_ status: CLAuthorizationStatus) -> Bool { status == .authorizedAlways || status.rawValue == 4 }

    /// Never asked yet: the guide's Look asks first.
    public nonisolated static var undetermined: Bool { CLLocationManager().authorizationStatus == .notDetermined }

    nonisolated static var statusWord: String {
        let status = CLLocationManager().authorizationStatus
        if isAllowed(status) { return "allowed" }
        return switch status {
        case .notDetermined: "not asked"
        case .restricted: "restricted"
        case .denied: "denied"
        default: "unknown"
        }
    }

    /// Asks macOS once (its alert shows the usage text) and answers when the person has chosen; at once when already decided.
    /// No choice within `requestLimit`, or the asking task cancelled (Cancel, the window closing): not allowed, so the guide
    /// says how to turn it on (`.locationOff`); a choice made later still counts at the next Look.
    public func request() async -> Bool {
        guard Self.undetermined else { return Self.allowed }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                guard !Task.isCancelled else { return c.resume(returning: false) }
                waiting[id] = c
                timers[id] = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: Self.requestLimit)
                    self?.finish(id, false)
                }
                manager.requestWhenInUseAuthorization()
            }
        } onCancel: {
            Task { @MainActor in WifiLocation.shared.finish(id, false) }
        }
    }

    /// How long `request` waits for the person to answer macOS's alert.
    public static let requestLimit: Duration = .seconds(60)

    /// Answers one waiting request (once: a second answer finds none) and stops its timer.
    private func finish(_ id: UUID, _ allowed: Bool) {
        timers.removeValue(forKey: id)?.cancel()
        waiting.removeValue(forKey: id)?.resume(returning: allowed)
    }

    public nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        Task { @MainActor in
            let allowed = Self.allowed
            for id in Array(self.waiting.keys) { self.finish(id, allowed) }
        }
    }
}
