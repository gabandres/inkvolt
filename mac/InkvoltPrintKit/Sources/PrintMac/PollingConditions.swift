import Foundation
import IOKit.ps
import Network
import Synchronization

/// What the window-closed checks slow down for (`AlertPolling.interval`): running on battery, and a constrained network
/// (Low Data Mode, macOS's counterpart of Windows' metered connection). Any thread.
public final class PollingConditions: Sendable {
    private let monitor = NWPathMonitor()
    private let constrainedNow = Flag()

    public init() {
        let flag = constrainedNow
        monitor.pathUpdateHandler = { path in flag.value.store(path.isConstrained, ordering: .relaxed) }
        monitor.start(queue: DispatchQueue(label: "inkvolt.path", qos: .utility))
    }

    deinit { monitor.cancel() }

    public var constrained: Bool { constrainedNow.value.load(ordering: .relaxed) }

    private final class Flag: Sendable {
        let value = Atomic(false)
    }

    /// The Mac draws on its battery now (false on a desktop, or on power).
    public var onBattery: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
