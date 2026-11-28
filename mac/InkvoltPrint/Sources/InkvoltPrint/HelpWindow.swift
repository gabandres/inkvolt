import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// Help › Inkvolt Print Help (⌘?; the Windows app's Help dialog, F1, and the command palette's Help and shortcuts): the
/// keyboard shortcuts, what to do when a printer isn't found, Report a Problem… and Inkvolt Pro…. Mac differences: the
/// Mac's own shortcuts; no What's New (the App Store shows it) and no Open Log Folder (the Mac app keeps no log); Open Local
/// Network Settings, as the sidebar's banner has it.
@MainActor
enum HelpWindow {
    private static var window: NSWindow?

    /// Key → what it does, as the window lists them (in the interface's language, read each time).
    static var shortcuts: [(keys: String, action: String)] {
        [
            ("⌘?", String(localized: "This help")),
            ("⌘K", String(localized: "Commands: run any command, show a printer or scan with a preset by typing its name")),
            ("⌘1 … ⌘9", String(localized: "Scan with the first nine scan presets")),
            ("⌘R", String(localized: "Scan tab: scan, or scan more pages")),
            ("⌘S", String(localized: "Scan review: save")),
            ("⌘N", String(localized: "Add a printer")),
            ("⇧⌘P", String(localized: "Batch print: many files")),
            ("⇧⌘V", String(localized: "Print what's on the clipboard")),
            ("⇧⌘F", String(localized: "Show the Fleet page (every printer)")),
            ("⌥⌘L", String(localized: "Print log")),
            (String(localized: "Tab, arrows, ⇧ or ⌥ and arrows, Delete"),
             String(localized: "Photos on the glass: pick a photo, move it, resize it, turn it, remove it")),
            ("Esc", String(localized: "Close a dialog")),
        ]
    }

    static func show(_ app: AppModel) {
        if let window { return window.makeKeyAndOrderFront(nil) }
        let hosting = NSHostingController(rootView: HelpView(app: app))
        hosting.sizingOptions = [.preferredContentSize]
        let w = NSWindow(contentViewController: hosting)
        w.title = String(localized: "Inkvolt Print Help")
        w.styleMask = [.titled, .closable]
        w.setContentSize(hosting.view.fittingSize) // its size before the first layout, so it opens centred at it
        w.isReleasedWhenClosed = false
        w.center()
        window = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            MainActor.assumeIsolated { window = nil }
        }
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    static func close() { window?.close() }
}

private struct HelpView: View {
    let app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Keyboard shortcuts").font(.headline)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                ForEach(Array(HelpWindow.shortcuts.enumerated()), id: \.offset) { _, s in
                    GridRow {
                        Text(s.keys).fontWeight(.semibold)
                        Text(s.action).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Can't find a printer?").font(.headline).padding(.top, 10)
            Text("Inkvolt Print finds printers on the same network as this Mac. A VPN, a firewall that blocks finding devices, Local Network access turned off for Inkvolt Print, or a printer on another network (a guest Wi-Fi, another subnet) can hide one. Add a Printer… (the + above the printer list) searches your network for printers that don't announce themselves, and takes a printer's IP address from its screen or network report.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Add a Printer…") {
                    HelpWindow.close()
                    MainWindow.bringForward()
                    app.isAddingPrinter = true
                }
                Button("Open Local Network Settings") { NSWorkspace.shared.open(SystemSettings.localNetwork) }
            }
            HStack {
                Button("Report a Problem…") { ReportProblemWindowController.show(app) }
                    .help("Copy the details a report needs, then open a GitHub issue to paste them in. Nothing is sent by Inkvolt Print.")
                Button("Inkvolt Pro…") {
                    HelpWindow.close()
                    ProWindow.show()
                }
                .help("Enter or remove an Inkvolt Pro licence key (one key for Inkvolt Print and Inkvolt PDF). Everything is free while the apps launch.")
                Spacer()
                Button("Close") { HelpWindow.close() }.keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(20)
        .frame(width: 560)
    }
}
