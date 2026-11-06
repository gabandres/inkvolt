import Foundation

/// A network (eSCL) scanner in Inkvolt PDF's Scan dialog: one Inkvolt Print remembers, or one Bonjour found.
public struct EsclScanner: Equatable, Sendable {
    /// What the dialog remembers as the last scanner: "escl:" and the printer's UUID in lower case.
    public var key: String
    public var name: String
    public var host: String
    public var esclRoot: URL
    /// Inkvolt Print remembers it (its hand-off, `SuitePrinters`); else only found on the network now.
    public var remembered: Bool

    public init(key: String, name: String, host: String, esclRoot: URL, remembered: Bool) {
        self.key = key
        self.name = name
        self.host = host
        self.esclRoot = esclRoot
        self.remembered = remembered
    }
}

/// The Scan dialog's list of scanners (the Windows suite's `ScannerList`, its network part; the Mac's USB scanners come
/// through ImageCaptureCore): the scanners Inkvolt Print remembers first, so they're there at once, then the ones Bonjour
/// finds; their keys and labels.
public enum ScannerList {
    private static let prefix = "escl:"

    /// "escl:" and the UUID, braces gone and in lower case, so a UUID written either way is the same scanner.
    public static func key(_ uuid: String) -> String {
        prefix + uuid.trimmingCharacters(in: CharacterSet(charactersIn: "{} ")).lowercased()
    }

    /// "Name  (host)", with " · found on the network" for one Inkvolt Print doesn't remember; "Name  (USB)".
    public static func label(_ scanner: EsclScanner) -> String {
        "\(scanner.name)  (\(scanner.host))\(scanner.remembered ? "" : " · found on the network")"
    }

    public static func usbLabel(_ name: String) -> String { "\(name)  (USB)" }

    /// The network scanners: Inkvolt Print's remembered printers that scan over eSCL (hand-off order), then those Bonjour
    /// found that aren't among them. A remembered one Bonjour finds gets its address and eSCL root from discovery (DHCP may
    /// have moved it), keeping the name Inkvolt Print knows it by.
    public static func network(remembered: SuitePrinters, found: [DiscoveredPrinter]) -> [EsclScanner] {
        var list: [EsclScanner] = []
        for p in remembered.printers {
            guard let root = p.esclRoot.flatMap(URL.init(string:)) else { continue }
            let id = key(p.id)
            if !list.contains(where: { $0.key == id }) {
                list.append(EsclScanner(key: id, name: p.name, host: p.host, esclRoot: root, remembered: true))
            }
        }
        for d in found where d.hasScanner {
            guard let host = d.host, let root = d.esclRoot else { continue }
            let id = key(d.uuid)
            if let i = list.firstIndex(where: { $0.key == id }) {
                list[i].host = host
                list[i].esclRoot = root
            } else {
                list.append(EsclScanner(key: id, name: d.name, host: host, esclRoot: root, remembered: false))
            }
        }
        return list
    }
}
