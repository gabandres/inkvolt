import Foundation

/// Where `print --printer` sends: a macOS queue, or straight to a printer over IPP (roadmap 2.1; Windows' `BatchPrinterChoice`).
public enum BatchPrinterChoice: Equatable, Sendable {
    case queue(String)
    /// `endpoint`: the printer's IPP endpoint (http or https, as `IppClient` takes it); `printer`: the remembered printer it
    /// is (its certificate pins), or nil for an address given on the command line.
    case direct(endpoint: URL, name: String, printer: KnownPrinter?)
}

/// What `--printer` names, decided as the window decides (`PrintRoutes`; Windows' `BatchPrinterLookup`): an `ipp://` or
/// `ipps://` address is that printer, straight; a macOS queue's name (or the name Printers & Scanners shows) is that queue; a
/// printer Inkvolt Print remembers is the queue that stands for it, or straight to it (its last IPP address) when it has none
/// or the person chose that for it (`PrintState.directPrinters`). Whether the printer takes a format sent without a driver is
/// known only once it's asked (`DirectBatchQueue.read`). Never a virtual queue. Mac differences: the queues are CUPS
/// destinations, a printer's queue is the one the printer list claims for it (`CupsQueues.claim`), and the remembered
/// printers and the choice come from the app's own state file (the command runs inside the app). The words stay English, as
/// the command line's do.
public enum BatchPrinterLookup {
    /// - Throws: `BatchCommandError`: there's no such printer, it's ambiguous, virtual, or there's nothing to print through.
    public static func find(_ name: String, destinations: [CupsDestination], known: PrintState) throws -> BatchPrinterChoice {
        let shown = BatchPrintText.clean(name)
        if name.contains("://") {
            let lower = name.lowercased()
            guard lower.hasPrefix("ipp://") || lower.hasPrefix("ipps://"), let typed = URLComponents(string: name),
                  typed.user == nil, typed.password == nil, typed.query == nil, typed.fragment == nil,
                  let host = typed.host, !host.isEmpty, case let address = PrinterAddress.parse(name), let endpoint = address.ipp, address.error == nil else {
                throw BatchCommandError("\"\(shown)\" isn't a printer's address: give one as ipp://host/ipp/print or ipps://host/ipp/print.")
            }
            return .direct(endpoint: endpoint, name: address.host ?? host, printer: known.printers.first { same($0.ippUri.flatMap(URL.init(string:)), endpoint) })
        }

        let real = destinations.filter { !$0.isTemporary }
        func named(_ wanted: String) -> CupsDestination? {
            real.first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }
                ?? real.first { $0.options["printer-info"]?.caseInsensitiveCompare(wanted) == .orderedSame }
        }
        var queue = named(name)
        if queue == nil {
            // A printer's name in Inkvolt Print: the queue that stands for it, when there is just one; or straight to it.
            let matches = known.printers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
            if matches.count > 1 { throw BatchCommandError("More than one printer is called \"\(shown)\": use its queue's name.") }
            if let printer = matches.first {
                let claims = PrinterList.claims(known.printers.map {
                    ListedPrinter(id: $0.uuid, kind: .network, name: $0.name, model: $0.model, hosts: [$0.host], acceptedUuids: known.acceptedUuids[$0.uuid] ?? [])
                })
                let candidates = real.filter { !CupsQueues.isVirtual($0) && CupsQueues.claim($0, claims)?.id == printer.uuid }
                let chose = known.directPrinters.contains { $0.caseInsensitiveCompare(printer.uuid) == .orderedSame }
                let endpoint = printer.ippUri.flatMap(URL.init(string:))
                switch PrintRoutes.choose(hasQueue: !candidates.isEmpty, printerTakesRaster: endpoint != nil, personChoseDirect: chose) {
                case .direct:
                    return .direct(endpoint: endpoint!, name: printer.name, printer: printer)
                case .queue where candidates.count > 1:
                    throw BatchCommandError("\"\(shown)\" has several macOS queues: use one's name (\(candidates.map { BatchPrintText.clean($0.name) }.joined(separator: ", "))).")
                case .queue:
                    queue = candidates[0]
                case .none:
                    throw BatchCommandError("\"\(shown)\" isn't set up in macOS and Inkvolt Print hasn't reached it over IPP: press Set Up on its page in Inkvolt Print, or use a queue's name.")
                }
            }
        }
        guard let queue else {
            let names = real.filter { !CupsQueues.isVirtual($0) }.map { BatchPrintText.clean($0.name) }
            throw BatchCommandError("There is no printer \"\(shown)\".\(names.isEmpty ? "" : " macOS has: \(names.joined(separator: ", ")).")")
        }
        if CupsQueues.isVirtual(queue) {
            throw BatchCommandError("\"\(BatchPrintText.clean(queue.name))\" isn't a printer but a virtual one: choose a real one.")
        }
        return .queue(queue.name)
    }

    private static func same(_ a: URL?, _ b: URL) -> Bool {
        guard let a else { return false }
        return a.host?.lowercased() == b.host?.lowercased() && a.port == b.port && a.path == b.path && a.scheme == b.scheme
    }
}

/// A remembered printer's certificate pins as Inkvolt Print keeps them, for the command line, which writes nothing: a pin
/// that's there must match; a printer with none is taken as it answers this once (nothing secret goes to it, only the pages).
public struct ReadOnlyPins: CertificatePin {
    private let pins: [String: String]
    private let uuid: String

    public init(_ known: PrintState, _ uuid: String) {
        pins = known.certificatePins
        self.uuid = uuid
    }

    public func get(_ port: Int) -> String? { pins[CertificatePinKey.key(uuid, port: port)] }

    public func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String { get(port) ?? sha256Hex }
}
