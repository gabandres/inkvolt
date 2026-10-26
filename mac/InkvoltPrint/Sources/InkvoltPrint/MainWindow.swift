import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// The main window: the printer list beside the selected printer's pane.
struct MainWindow: View {
    static let id = "main", demoID = "demo"

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
                SidebarHeader()
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
        // The demo window may come back by itself (window restoration): its printers start with it. Idempotent.
        .onAppear { model.start() }
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
            VStack(spacing: 12) {
                AppIconImage(size: 64)
                ProgressView().controlSize(.small)
                Text("Looking for printers…").foregroundStyle(.secondary)
            }
        } else {
            ContentUnavailableView {
                VStack(spacing: 10) {
                    AppIconImage(size: 64)
                    Text("No printers found")
                }
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

/// The app's name and icon at the top of the sidebar, as the Windows app has them.
struct SidebarHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 8) {
            AppIconImage(size: 26)
            Text("Inkvolt Print").font(.headline)
            if model.isDemo {
                Text("Demo").font(.caption.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 1)
                    .background(.orange.opacity(0.2), in: .capsule)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}

/// The app icon (the bundle's, from the asset catalog), drawn at a size.
struct AppIconImage: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
