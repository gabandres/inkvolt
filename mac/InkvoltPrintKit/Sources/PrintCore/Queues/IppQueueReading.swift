import Foundation

/// Route 1 on the Mac (roadmap 3.6, the Windows app's `IppQueueReading`): a queue whose printer speaks IPP (a driverless USB
/// printer's IPP-over-USB relay, or a network IPP queue nobody added as a network printer) is asked for its printer
/// attributes, and the reply is read with the same IPP mapping as a network printer's. The asking is PrintMac's
/// (`QueueDeviceReader`); this decides which queues are asked, what is asked, and what the bytes say.
public enum IppQueueReading {
    /// The attributes asked for: the status and supplies a network printer is read for, without identifiers.
    public static let attributes = [
        "printer-state", "printer-state-reasons", "printer-state-message", "marker-names", "marker-levels", "marker-low-levels",
        "marker-high-levels", "marker-types", "marker-colors", "printer-alert", "printer-alert-description",
    ]

    /// Largest reply read (a real one is a few kilobytes).
    public static let maxBytes = 256 * 1024

    /// The reading from the printer's bytes: a whole Get-Printer-Attributes reply (what the Mac's transport gets), or the
    /// printer-attributes group alone, with or without its group tag (what Windows hands over). Nil when there are none,
    /// too many, the printer refused, or they can't be read.
    public static func from(_ bytes: [UInt8], usb: Bool) -> QueueDeviceReading? {
        guard let first = bytes.first, bytes.count <= maxBytes else { return nil }
        var framed: [UInt8]
        if first == 1 || first == 2 { // IPP version 1.x or 2.x: a whole reply
            framed = bytes
        } else {
            framed = [1, 1, 0, 0, 0, 0, 0, 1] // version 1.1, successful-ok, request id 1
            if first >= 0x10 { framed.append(0x04) } // attributes without their group tag: printer-attributes
            framed += bytes
            framed.append(0x03)
        }
        guard let response = try? IppCodec.decode(framed), response.ok else { return nil }
        return from(response, usb: usb)
    }

    /// The reading from a decoded reply: nil when it has neither a state nor supplies.
    public static func from(_ response: IppResponse, usb: Bool) -> QueueDeviceReading? {
        guard response.attributes["printer-state"] != nil || response.attributes["marker-names"] != nil else { return nil }
        let status = IppClient.toStatus(response)
        let from: QueueReadingFrom = usb ? .printerOverUsb : .printerOverNetwork
        let supplies = IppClient.toConsumables(response)
        // No state it can read says nothing about the printer: macOS's status stands (a jam it knows of doesn't become
        // "Unknown"), with the problems it did give.
        return status.code == "unknown"
            ? QueueDeviceReading(from: from, status: nil, alerts: status.alerts, supplies: supplies)
            : QueueDeviceReading(from: from, status: status, alerts: [], supplies: supplies)
    }

    /// Which way a queue's printer can be asked over IPP, from its `device-uri`: over USB for CUPS's own IPP-over-USB
    /// (`ippusb://`) or a local relay to a USB printer (`ipp://localhost:60000/…`, as `ippusbxd` serves one); over the
    /// network for an IPP or Bonjour queue. Nil: nothing to ask (macOS's `usb://` backend speaks the printer's own language,
    /// not IPP, so only cupsd's copy of the levels is there; a raw socket or LPD queue has SNMP; a shared queue is another
    /// computer's printer).
    public static func route(_ d: CupsDestination) -> QueueReadingFrom? {
        guard let uri = d.deviceUri, let scheme = CupsQueues.scheme(uri) else { return nil }
        if scheme == "ippusb" { return .printerOverUsb }
        guard CupsQueues.connection(d) == .network, ["ipp", "ipps", "http", "https", "dnssd", "mdns"].contains(scheme) else { return nil }
        let host = CupsQueues.host(uri)?.lowercased()
        return ["localhost", "127.0.0.1", "::1"].contains(host) ? .printerOverUsb : .printerOverNetwork
    }
}
