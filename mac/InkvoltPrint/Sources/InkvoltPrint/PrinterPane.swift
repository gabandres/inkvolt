import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// The selected printer: its status and alerts, its supplies, and what it is.
struct PrinterPane: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var app
    @State private var tab = Tab.status
    @State private var printingPhotos = false
    @State private var copyingCard = false

    enum Tab { case status, scan, settings }

    var body: some View {
        let leftOver = app.leftOverScans.filter { $0.scan.printerId.caseInsensitiveCompare(printer.id) == .orderedSame }
        Group {
            if tab == .scan && (printer.canScan || !leftOver.isEmpty) {
                ScanView(scan: printer.scan, leftOver: leftOver)
            } else if tab == .settings && printer.hasDeviceSettings {
                DeviceSettingsView(printer: printer).id(printer.id)
            } else {
                status
            }
        }
        .navigationTitle(printer.name)
        .sheet(isPresented: $printingPhotos) { PhotosView(printer: printer, app: app) }
        .sheet(isPresented: $copyingCard) { IdCardCopySheet(printer: printer, app: app) }
        .toolbar {
            if !printer.isScannerOnly { ToolbarItem {
                Menu {
                    Button("Print a PDF…") { Printing.printPdf(on: printer, app: app) }
                    Button("Print Photos…") { printingPhotos = true }
                    if printer.canScan {
                        Divider()
                        Button("Copy an ID Card…") { copyingCard = true }
                    }
                } label: {
                    Label("Print", systemImage: "printer")
                }
                .help(printer.queueName == nil ? "Print (choose the printer in the print panel: macOS has no printer set up for this one yet)"
                      : "Print on \(printer.name)")
            } }
            if printer.canScan || !leftOver.isEmpty || printer.hasDeviceSettings {
                ToolbarItem(placement: .principal) {
                    Picker("View", selection: $tab) {
                        Text("Status").tag(Tab.status)
                        if printer.canScan || !leftOver.isEmpty { Text("Scan").tag(Tab.scan) }
                        if printer.hasDeviceSettings { Text("Settings").tag(Tab.settings) }
                    }
                    .pickerStyle(.segmented)
                    .help("Show the printer's status, or scan")
                }
            }
        }
    }

    private var status: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                StatusCard(printer: printer)
                if printer.isNetwork { SetUpCard(printer: printer).id(printer.id) }
                if !printer.view.supplies.isEmpty { supplies }
                if let queue = printer.queueName { PrintQueueCard(queue: queue, app: app).id(queue) }
                if printer.isNetwork && printer.view.isOnline { MaintenanceCard(printer: printer).id(printer.id) }
                details
            }
            .padding(24)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "printer.fill")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(printer.name).font(.title2.bold()).textSelection(.enabled)
                if let model = printer.view.model ?? printer.model, model != printer.name {
                    Text(model).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
        }
    }

    private var supplies: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Supplies").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(Array(printer.view.supplies.enumerated()), id: \.offset) { _, supply in
                    SupplyCard(supply: SupplyText(supply))
                }
            }
        }
    }

    private var details: some View {
        let v = printer.view
        return VStack(alignment: .leading, spacing: 10) {
            Text("Details").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                if let d = printer.destination {
                    if let address = CupsQueues.address(d) { row("Address", address) }
                    row("macOS queue", d.name)
                } else {
                    row("Address", printer.host)
                }
                if !v.interfaces.isEmpty { row("Connected over", v.interfaces.joined(separator: ", ")) }
                if let firmware = v.firmware, !firmware.display.isEmpty { row("Firmware", firmware.display) }
                if let location = v.location { row("Location", location) }
                if let u = v.usage {
                    if let n = u.totalImpressions { row("Pages printed", n.formatted()) }
                    if let n = u.duplexSheets { row("Two-sided sheets", n.formatted()) }
                    if let n = u.scanImages { row("Pages scanned", n.formatted()) }
                    if let n = u.jamEvents { row("Paper jams", n.formatted()) }
                }
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).textSelection(.enabled)
        }
    }
}

/// The printer's state in words, its alerts, and "This is my printer" when another device has its address.
/// "Set up in macOS" (the Windows app's Set up in Windows): offered while macOS has no queue for a network printer that's
/// connected, so other apps can print to it too.
struct SetUpCard: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var app
    @State private var working = false
    @State private var message: String?
    @State private var done = false

    var body: some View {
        if (printer.queueName == nil && app.destinations != nil && printer.view.isOnline) || message != nil {
            VStack(alignment: .leading, spacing: 8) {
                if printer.queueName == nil {
                    Text("macOS has no printer set up for this one, so other apps can't print to it.")
                        .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let message { Text(message).fixedSize(horizontal: false, vertical: true) }
                HStack {
                    if printer.queueName == nil {
                        Button("Set Up in macOS") { Task { await setUp() } }.disabled(working)
                        if message != nil && !done { Button("Open Printers & Scanners") { NSWorkspace.shared.open(SystemSettings.printers) } }
                    }
                    if working {
                        ProgressView().controlSize(.small)
                        Text("macOS is reading what the printer can do…").foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func setUp() async {
        working = true
        message = nil
        message = await app.setUpQueue(for: printer)
        done = printer.queueName != nil
        working = false
    }
}

struct StatusCard: View {
    let printer: PrinterModel
    @Environment(AppModel.self) private var app
    @State private var confirmAccept = false
    @State private var fixing = false

    var body: some View {
        let v = printer.view
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(printer.tone == .unknown ? .secondary : printer.tone.color).font(.title3)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(v.statusMessage).font(.title3.weight(.semibold))
                    if let detail = v.statusDetail { Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                }
                if v.phase == .connecting { ProgressView().controlSize(.small) }
            }
            ForEach(Array(v.alerts.enumerated()), id: \.offset) { _, alert in
                Label {
                    Text(alert.message)
                } icon: {
                    Image(systemName: alert.severity == .error ? "xmark.octagon.fill" : alert.severity == .warning ? "exclamationmark.triangle.fill" : "info.circle")
                        .foregroundStyle(alert.severity == .error ? .red : alert.severity == .warning ? .orange : .secondary)
                }
            }
            HStack {
                if printer.needsFixing { Button("Fix It…") { fixing = true } }
                if v.phase == .elsewhere { Button("This Is My Printer…") { confirmAccept = true } }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $fixing) { OfflineFixerSheet(printer: printer, app: app) }
        .confirmationDialog("Use the device that now answers at \(printer.host) as \(printer.name)?", isPresented: $confirmAccept) {
            Button("This Is My Printer") { printer.acceptDevice() }
        } message: {
            Text("Only do this if it really is this printer, for example after a repair, a reset or a new network board gave it a new ID. "
                + "Otherwise it's another device that took the printer's address.")
        }
    }

    private var symbol: String {
        switch printer.tone {
        case .unknown: "circle.dotted"
        case .ok: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        case .off: "powersleep"
        }
    }
}

/// One supply: its colour, level, how long it lasts, and what replaces it.
struct SupplyCard: View {
    let supply: SupplyText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Swatch(code: supply.colorCode)
                Text(supply.name).font(.callout.weight(.medium)).lineLimit(2)
                Spacer(minLength: 4)
                Text(supply.percentText).font(.title3.monospacedDigit().weight(.semibold))
            }
            if let fraction = supply.fraction {
                ProgressView(value: fraction).tint(tint)
            }
            if let headline = supply.headline {
                Text(headline).font(.callout).foregroundStyle(supply.level == .ok ? .secondary : tint)
            }
            if let cartridge = supply.cartridge {
                Text(cartridge).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 8))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(supply.accessibleText)
    }

    private var tint: Color {
        switch supply.level {
        case .ok: .accentColor
        case .low: .orange
        case .empty: .red
        }
    }
}

/// K, C, M, Y or #RRGGBB as a dot; none for a supply without a colour.
struct Swatch: View {
    let code: String?

    var body: some View {
        if let color = Self.color(code) {
            Circle().fill(color).overlay(Circle().strokeBorder(.primary.opacity(0.2))).frame(width: 12, height: 12).accessibilityHidden(true)
        }
    }

    static func color(_ code: String?) -> Color? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), !code.isEmpty else { return nil }
        switch code {
        case "K": return .black
        case "C": return .cyan
        case "M": return Color(red: 0.85, green: 0.1, blue: 0.55)
        case "Y": return .yellow
        default:
            guard code.hasPrefix("#"), code.count == 7, let rgb = Int(code.dropFirst(), radix: 16) else { return nil }
            return Color(red: Double(rgb >> 16 & 0xFF) / 255, green: Double(rgb >> 8 & 0xFF) / 255, blue: Double(rgb & 0xFF) / 255)
        }
    }
}
