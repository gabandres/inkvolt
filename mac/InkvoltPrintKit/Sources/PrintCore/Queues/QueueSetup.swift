import Foundation

/// The queue "Set up in macOS" asks cupsd for (the Windows app's Set up in Windows): a driverless (IPP Everywhere) queue
/// for a network printer macOS has none for, so every app can print to it.
public struct QueueSetupPlan: Equatable, Sendable {
    /// `printer-name`: letters, digits and underscores, not taken by another destination.
    public var queueName: String
    /// `device-uri`: the printer's IPP URL, on its Bonjour host name when it has one (it keeps working when DHCP gives the
    /// printer another address).
    public var deviceUri: String
    /// `printer-info`, the name macOS shows.
    public var info: String

    public init(queueName: String, deviceUri: String, info: String) {
        self.queueName = queueName
        self.deviceUri = deviceUri
        self.info = info
    }
}

/// Creates a CUPS queue from a plan. Throws `QueueControlError`: `.refused` when cupsd wants an administrator.
public protocol QueueSetupControl: Sendable {
    func addQueue(_ plan: QueueSetupPlan) async throws
}

/// The rules of "Set up in macOS". cupsd builds the queue itself: CUPS-Create-Local-Printer makes a temporary queue and
/// reads the printer's capabilities into its PPD (cupsd connects to the device URI's host, so a Bonjour service name there
/// doesn't work, only a host name or address), then CUPS-Add-Modify-Printer with `printer-is-temporary` false keeps it.
/// Both work from the sandbox; the second needs an administrator (checked on a Mac, 2026-10-26).
public enum QueueSetup {
    /// The queue for a printer with an IPP URL; nil without one (a printer that answers only LEDM or SNMP has no
    /// driverless queue to make).
    public static func plan(name: String, ippUri: URL?, hostName: String?, destinations: [CupsDestination]) -> QueueSetupPlan? {
        guard let uri = ippUri.flatMap({ deviceUri($0, hostName: hostName) }) else { return nil }
        let info = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return QueueSetupPlan(queueName: queueName(info, taken: destinations.map(\.name)), deviceUri: uri, info: info.isEmpty ? "Printer" : info)
    }

    /// The IPP URL with its host replaced by the printer's `.local` name when it has one; nil when it isn't IPP's (ipp, ipps, or
    /// IPP over http or https).
    static func deviceUri(_ ipp: URL, hostName: String?) -> String? {
        // The sessions ask IPP over HTTP (http://host:631/…), which is ipp:// to cupsd.
        let schemes = ["ipp": "ipp", "ipps": "ipps", "http": "ipp", "https": "ipps"]
        guard var parts = URLComponents(url: ipp, resolvingAgainstBaseURL: false), let scheme = parts.scheme.flatMap({ schemes[$0.lowercased()] }),
              parts.host?.isEmpty == false else { return nil }
        parts.scheme = scheme
        if var local = hostName?.lowercased() {
            while local.hasSuffix(".") { local.removeLast() }
            if local.hasSuffix(".local"), local.count > 6 { parts.host = local }
        }
        if parts.path.isEmpty { parts.path = "/ipp/print" }
        return parts.string
    }

    /// The name cupsd would give it (each run of characters other than ASCII letters and digits becomes one underscore),
    /// trimmed of underscores and kept short, then made unique among `taken` (case doesn't count).
    public static func queueName(_ name: String, taken: [String]) -> String {
        var out = ""
        for c in name.unicodeScalars {
            if c.isASCII, CharacterSet.alphanumerics.contains(c) {
                out.unicodeScalars.append(c)
            } else if !out.isEmpty, !out.hasSuffix("_") {
                out += "_"
            }
        }
        while out.hasSuffix("_") { out.removeLast() }
        if out.isEmpty { out = "Printer" }
        out = String(out.prefix(100))
        let used = Set(taken.map { $0.lowercased() })
        guard used.contains(out.lowercased()) else { return out }
        var n = 2
        while used.contains("\(out)_\(n)".lowercased()) { n += 1 }
        return "\(out)_\(n)"
    }

    /// What to tell the user after asking.
    public static func outcome(_ error: QueueControlError?, info: String) -> String {
        switch error {
        case nil: "Ready to print from any app."
        case .refused?: "Only an administrator can add printers to this Mac. In Printers & Scanners, click Add Printer, Scanner, or Fax…, then pick \u{201C}\(info)\u{201D}."
        case .failed(let why)?: "macOS couldn't set up the printer: \(why) You can add it in Printers & Scanners instead."
        }
    }
}
