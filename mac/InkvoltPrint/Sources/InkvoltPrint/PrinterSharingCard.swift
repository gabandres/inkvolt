import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// Share a printer with phones (roadmap 4.10) on the Mac: macOS's own Printer Sharing does it (IPP and Bonjour, AirPrint
/// included), and a sandboxed app may only point to it, so Inkvolt Print says whether macOS shares each queue printer
/// (`PrinterSharing`) and opens System Settings' Sharing pane at Printer Sharing. No server of ours (Windows' `PrinterShare`).
@MainActor
enum PhoneSharing {
    /// The card's line for a queue printer; nil for a printer with no queue, or one that can't be shared.
    static func line(_ p: PrinterModel) -> String? {
        guard let d = p.destination, let state = PrinterSharing.state(d) else { return nil }
        return switch state {
        case .shared: String(localized: "macOS shares this printer: while Printer Sharing is on in System Settings › General › Sharing, iPhones, iPads and other computers on this network can print to it.")
        case .notShared: String(localized: "macOS doesn't share this printer. To print to it from iPhones, iPads and other computers on this network, turn on Printer Sharing in System Settings › General › Sharing and tick this printer there.")
        case .notSaid: String(localized: "macOS didn't say whether it shares this printer. Printer Sharing in System Settings › General › Sharing lists the printers it shares.")
        }
    }

    /// One word for the report.
    static func word(_ p: PrinterModel) -> String? {
        guard let d = p.destination, let state = PrinterSharing.state(d) else { return nil }
        return switch state {
        case .shared: "shared"
        case .notShared: "not shared"
        case .notSaid: "not said"
        }
    }

    /// The explanation File › Share a Printer with Phones… shows: how macOS shares printers, then each queue printer's state.
    static func explanation(_ app: AppModel) -> String {
        var text = String(localized: "macOS shares printers itself: turn on Printer Sharing in System Settings › General › Sharing and tick the printers to share. iPhones, iPads and other computers on this network then print to them with AirPrint, with nothing to install. Inkvolt Print runs no server of its own.")
        let queues = app.printers.compactMap { p in p.destination.flatMap(PrinterSharing.state).map { (p.name, $0) } }
        let shared = queues.filter { $0.1 == .shared }.map(\.0)
        let notShared = queues.filter { $0.1 != .shared }.map(\.0)
        if !shared.isEmpty { text += "\n\n" + String(localized: "Shared now: \(shared.formatted(.list(type: .and)))") }
        if !notShared.isEmpty { text += "\n\n" + String(localized: "Not shared: \(notShared.formatted(.list(type: .and)))") }
        return text
    }

    /// File › Share a Printer with Phones….
    static func show(_ app: AppModel) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Share a Printer with Phones")
        alert.informativeText = explanation(app)
        alert.addButton(withTitle: String(localized: "Open Sharing Settings"))
        alert.addButton(withTitle: String(localized: "Open Printers & Scanners"))
        alert.addButton(withTitle: String(localized: "Close"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(SystemSettings.printerSharing)
        case .alertSecondButtonReturn: NSWorkspace.shared.open(SystemSettings.printers)
        default: break
        }
    }
}

/// The printer pane's card for a queue printer: whether macOS shares it, and Open Sharing Settings.
struct PrinterSharingCard: View {
    let printer: PrinterModel

    var body: some View {
        if let line = PhoneSharing.line(printer) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Share with phones").font(.headline)
                Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Open Sharing Settings") { NSWorkspace.shared.open(SystemSettings.printerSharing) }
            }
        }
    }
}
