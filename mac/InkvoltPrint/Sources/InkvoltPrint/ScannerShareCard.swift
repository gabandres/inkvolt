import Foundation
import PrintCore
import PrintMac
import SwiftUI

/// The Scan tab's "Share on the network" section for an entry's USB scanner (roadmap 3.1; Windows' `ScannerShareViewModel`
/// and its card): what it shows and when are PrintCore's `ScannerShare.card`, switching is `AppModel.setSharing`; this only
/// shows them. Shown for a scanner macOS drives through a driver (never one macOS reaches over eSCL: it's on the network
/// already), and for the shared one while it's unplugged, so sharing can still be turned off.
struct ScannerShareCard: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var app

    var body: some View {
        let card = app.shareCard(printer)
        if card.isShown, let scanner = printer.systemScanner ?? printer.knownScanner {
            Section("Share on the network") {
                Toggle("Share this scanner on the network", isOn: Binding(get: { card.isOn }, set: { app.setSharing($0, scanner) }))
                    .help(card.text)
                Text(card.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if card.canShareHere {
                    // Paused on a network it wasn't turned on in: shared here only when the person says so.
                    Button("Share on This Network") { app.setSharing(true, scanner) }
                }
                if let fingerprint = card.fingerprint {
                    Text("Certificate fingerprint (SHA-256), to compare where a device shows it:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(fingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// What the share did, in plain words (never a device's address), from any thread: the last 200 lines, for the report.
final class ShareLog: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [String] = []

    func add(_ line: String) {
        lock.withLock {
            kept.append(line)
            if kept.count > 200 { kept.removeFirst(kept.count - 200) }
        }
    }

    var lines: [String] { lock.withLock { kept } }
}

extension AppModel {
    /// The sharing card for an entry: its scanner while macOS lists it, or the one it's known by.
    func shareCard(_ p: PrinterModel) -> ShareCard {
        _ = shareRevision // read again when the share changes
        let connected = p.systemScanner.flatMap { isListed($0) ? $0 : nil }
        return scannerShare.card(connected: connected, known: p.knownScanner)
    }
}
