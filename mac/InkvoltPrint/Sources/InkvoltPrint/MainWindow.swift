import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// The main window: the printer list beside the selected printer's pane.
struct MainWindow: View {
    static let id = "main"

    @Environment(AppModel.self) private var model

    /// Opens the window, or brings it forward (from the menu bar, or a notification).
    @MainActor static func bringForward() {
        NSApp.activate()
        AppModel.shared.openMainWindow?()
    }

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            VStack(spacing: 0) {
                if model.localNetwork == .denied { LocalNetworkBanner() }
                List(selection: $model.selectedID) {
                    ForEach(model.printers) { p in
                        PrinterRow(printer: p).tag(p.id)
                    }
                }
                .overlay { if model.isEmpty { EmptyList() } }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            if let p = model.selected {
                PrinterPane(printer: p).id(p.id)
            } else {
                ContentUnavailableView("No printer selected", systemImage: "printer")
            }
        }
    }
}

/// A printer in the list: a dot for its state, its name, and its state in a few words.
struct PrinterRow: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var model
    @State private var confirmRemove = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            StatusDot(tone: printer.tone)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name).lineLimit(1)
                Text(printer.view.listLine).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button("Remove from Inkvolt Print…") { confirmRemove = true }
        }
        .confirmationDialog("Remove \(printer.name) from Inkvolt Print?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { model.remove(printer) }
        } message: {
            Text("This doesn't remove it from macOS. It won't be listed again when it's found on the network.")
        }
    }
}

struct StatusDot: View {
    let tone: PrinterModel.Tone

    var body: some View {
        Circle()
            .fill(tone.color)
            .overlay { if tone == .unknown { Circle().strokeBorder(.secondary, lineWidth: 1) } }
            .frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
}

extension PrinterModel.Tone {
    var color: Color {
        switch self {
        case .unknown: .clear
        case .ok: .green
        case .warning: .orange
        case .error: .red
        case .off: .gray
        }
    }
}

/// Local Network access is off (or the first-run question isn't answered yet): said plainly, never a silent empty list.
struct LocalNetworkBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Inkvolt Print can't reach your network", systemImage: "network.slash").font(.headline)
            Text("It needs Local Network access to find printers and read their status. Allow it when macOS asks, or turn it on in System Settings.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Button("Open Local Network Settings") { NSWorkspace.shared.open(SystemSettings.localNetwork) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12))
    }
}

/// No printers: still looking, or none found (with what to do).
struct EmptyList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.isSearching {
            VStack(spacing: 10) {
                ProgressView()
                Text("Looking for printers…").foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView {
                Label("No printers found", systemImage: "printer")
            } description: {
                Text("Make sure your printer is on and connected to the same network as this Mac.")
            } actions: {
                if !model.isDemo {
                    Button("Search Again") { model.searchAgain() }
                    Button("Try the Demo") { model.openDemo() }
                }
            }
        }
    }
}
