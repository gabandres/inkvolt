import Foundation

/// A printer that answered only SNMP when it was added (no LEDM, CDM or IPP), remembered with what it said about itself:
/// SNMP has no UUID, so its serial number (prtGeneralSerialNumber), model (hrDeviceDescr) and name (sysName) tell whether
/// the device at its address is still it. Only these printers are read over SNMP: a printer that answers HTTP and doesn't
/// for a moment (asleep, waking) is offline, never turned into an SNMP-only printer.
public struct SnmpDevice: Equatable, Sendable, Codable {
    public var serialNumber: String?
    public var model: String?
    public var systemName: String?

    public init(serialNumber: String?, model: String?, systemName: String?) {
        self.serialNumber = serialNumber
        self.model = model
        self.systemName = systemName
    }

    public static func from(_ identity: SnmpIdentity) -> SnmpDevice {
        SnmpDevice(serialNumber: clean(identity.serialNumber), model: clean(identity.model), systemName: clean(identity.systemName))
    }

    /// Where a printer's connection may go over SNMP: `transport` for a printer added as SNMP-only, else nowhere.
    public static func transport(for addedSnmpOnly: SnmpDevice?, _ transport: any SnmpTransport) -> (any SnmpTransport)? {
        addedSnmpOnly == nil ? nil : transport
    }

    /// The device answering SNMP now against this one: different when a serial number, model or name both report
    /// disagrees; same when all that both report agree; unknown when there's nothing to compare.
    public func identify(_ now: SnmpIdentity) -> DeviceIdentity {
        let compared = [(serialNumber, Self.clean(now.serialNumber)), (model, Self.clean(now.model)), (systemName, Self.clean(now.systemName))]
            .compactMap { pair -> (String, String)? in
                guard let a = pair.0, let b = pair.1 else { return nil }
                return (a, b)
            }
        if compared.isEmpty { return .unknown }
        return compared.allSatisfy { $0.0.caseInsensitiveCompare($0.1) == .orderedSame } ? .same : .different
    }

    /// A serial number from another interface (LEDM's or CDM's, when the printer starts answering them) against this one.
    public func identify(serialNumber other: String?) -> DeviceIdentity {
        guard let serialNumber, let sn = Self.clean(other) else { return .unknown }
        return serialNumber.caseInsensitiveCompare(sn) == .orderedSame ? .same : .different
    }

    private static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
