import Foundation

/// A scanner the Scan tab can drive: a printer's eSCL scanner, or one macOS has a driver for (ImageCaptureCore, in PrintMac).
/// What it offers is described as eSCL does (`ScannerCapabilities`), so the tab's choices are the same for both.
public protocol ScanDevice: Sendable {
    func capabilities() async throws -> ScannerCapabilities?

    /// One scan job: each page as JPEG bytes. Stopping early (cancelling the iteration) stops the job.
    func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error>
}

extension EsclClient: ScanDevice {}

/// A scanner macOS lists through ImageCaptureCore, as the printer list sees it.
public struct SystemScanner: Equatable, Sendable {
    /// ICC's persistent id for the device.
    public var id: String
    public var name: String
    /// Connected over USB (else on the network: those are eSCL scanners Inkvolt Print reaches itself).
    public var usb: Bool

    public init(id: String, name: String, usb: Bool) {
        self.id = id
        self.name = name
        self.usb = usb
    }
}

/// Which printer on the list a USB scanner belongs to (the Windows app's `WiaMatch`, by name): the queue printer whose name
/// or model is the scanner's, once makers' words, "series" and a "(1A2B3C)" suffix are set aside, when exactly one is.
/// A scanner no printer claims is listed as a scanner of its own. Network scanners aren't matched: a network printer scans
/// over eSCL.
public enum ScannerMatch {
    private static let idPrefix = "mac-scanner:"

    /// The id a scanner listed on its own goes by: never a UUID or a queue's id.
    public static func id(for scanner: SystemScanner) -> String { idPrefix + scanner.id.lowercased() }

    public static func isScannerId(_ id: String?) -> Bool { id?.hasPrefix(idPrefix) == true }

    /// The printer (id) among `printers` (id, names: its name and model) the scanner belongs to, or nil.
    public static func owner(_ scanner: SystemScanner, _ printers: [(id: String, names: [String])]) -> String? {
        guard scanner.usb else { return nil }
        let key = normalized(scanner.name)
        guard !key.isEmpty else { return nil }
        let owners = printers.filter { p in p.names.contains { normalized($0) == key } }
        return owners.count == 1 ? owners[0].id : nil
    }

    private static let noise: Set<String> = ["series", "printer", "scanner", "mfp", "usb", "network", "ipp", "everywhere", "airprint"]
    private static let makers = ["hewlett-packard": "hp", "hewlett packard": "hp", "epson": "epson", "canon": "canon", "brother": "brother"]

    /// "HP LaserJet MFP M234dw (1A2B3C) - IPP Everywhere" and "HP LaserJet M234dw series" → "hp laserjet m234dw".
    static func normalized(_ name: String) -> String {
        var s = name.lowercased()
        for (long, short) in makers { s = s.replacingOccurrences(of: long, with: short) }
        if let dash = s.range(of: " - ") { s = String(s[..<dash.lowerBound]) }
        s = s.replacingOccurrences(of: #"\([^)]*\)"#, with: " ", options: .regularExpression)
        let words = s.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init).filter { !noise.contains($0) }
        return words.joined(separator: " ")
    }
}
