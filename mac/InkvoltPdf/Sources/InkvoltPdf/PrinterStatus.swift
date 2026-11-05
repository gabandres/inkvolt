import AppKit
import PdfCore
import PrintCore
import PrintMac

/// Printer status when printing (the Windows app's `PrinterCheck` and `ConfirmPrinterReady`): for the print panel's
/// printer, when it is one Inkvolt Print remembers (its hand-off, `SuitePrinters`, in the app group both apps claim:
/// matched by the queue Inkvolt Print found for it, else by the queue's device URI and name), the printer's state and
/// toner, read from the printer itself (status and supplies only, `PrinterCheck`, at most 2 seconds) and kept 15 seconds.
/// Without Inkvolt Print, its hand-off or an answer, nothing is shown and printing is as before.
@MainActor
final class PrinterStatusLookup {
    static let shared = PrinterStatusLookup()
    private static let fresh: TimeInterval = 15

    struct Found {
        let printer: SuitePrinter
        /// Nil: it answered with something unreadable (no status, as on Windows).
        let health: PrinterHealth?
    }

    /// The shared folder (the self-test points it at its own).
    var root: () -> String? = { ProKeyRoot.url?.path }
    var transport: HttpTransportFactory = URLSessionTransport.factory(localNetwork: nil)
    var snmp: any SnmpTransport = UdpSnmpTransport()
    var queues: any PrintQueues = LibCups()
    private var cache: [String: (at: Date, health: Task<PrinterHealth?, Never>)] = [:]

    /// The Inkvolt Print printer behind the print panel's printer (`NSPrinter.name`: the CUPS queue's name, or the name
    /// macOS shows for it) and its health, or nil.
    func check(printerName: String) async -> Found? {
        guard let root = root() else { return nil }
        let handed = await Task.detached { SuitePrinters.load(root: root) }.value
        guard !handed.printers.isEmpty else { return nil }
        let all = await queues.destinations() ?? []
        let destination = all.first { $0.name == printerName } ?? all.first { $0.displayName == printerName }
        let queue = destination?.name ?? printerName
        guard let printer = handed.printer(forQueue: queue, destination) else { return nil }
        return Found(printer: printer, health: await health(printer))
    }

    private func health(_ p: SuitePrinter) async -> PrinterHealth? {
        if let c = cache[p.id], Date().timeIntervalSince(c.at) < Self.fresh { return await c.health.value }
        let transport = transport, snmp = snmp
        let task = Task.detached { await PrinterCheck.health(p, transport: transport, snmp: snmp) }
        cache[p.id] = (Date(), task)
        return await task.value
    }

    func forget() { cache = [:] }
}

/// Inkvolt Print, the suite's other app: File › Printer Settings (Inkvolt Print) and the print panel's button open it
/// (Windows: shown only when installed; here the item stays and, without the app, offers it in the App Store).
@MainActor
enum InkvoltPrintApp {
    static let bundleId = "com.bermudezsystems.InkvoltPrint"
    static let storePage = URL(string: "macappstore://apps.apple.com/app/id6827219248")!

    static var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) != nil }

    /// Opens it (or brings it forward); without it, says so and offers its App Store page.
    static func open(from window: NSWindow?) {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard error != nil else { return }
                Task { @MainActor in say("Inkvolt Print couldn't be started. Is it still installed?", store: false, NSApp.keyWindow) }
            }
            return
        }
        say("Inkvolt Print isn't on this Mac.", store: true, window)
    }

    private static func say(_ text: String, store: Bool, _ window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = text
        if store {
            alert.informativeText = "Inkvolt Print shows your printers' status, ink and toner, and keeps their settings. It's in the Mac App Store."
            alert.addButton(withTitle: "Open App Store")
            alert.addButton(withTitle: "Cancel")
        }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            if store && response == .alertFirstButtonReturn { NSWorkspace.shared.open(storePage) }
        }
        if let window { alert.beginSheetModal(for: window, completionHandler: done) } else { done(alert.runModal()) }
    }
}

extension AppDelegate {
    /// File › Printer Settings (Inkvolt Print).
    @objc func openInkvoltPrint(_ sender: Any?) { InkvoltPrintApp.open(from: NSApp.keyWindow) }
}
