import AppKit
import PrintCore
import PrintMac
import SwiftUI

/// `--report <name> --demo --ax-audit [--lang es]`: the accessibility audit (PrintMac's `AxWalk`, shared with Inkvolt PDF)
/// of the main window and Wave 4's windows, sheets and alerts: the print log (and Clear the Log's question), Use Your
/// Camera, Use Your Phone, Set Up a Printer's Wi-Fi, Recent Scans, Join Two Halves, Print Photos, Share a Printer with
/// Phones, a turned stack's question, two-sided printing by hand's copies and its prompt between the sides, a preset's PDF
/// password. Each is opened through the call its menu or button makes, audited, then closed or cancelled (a modal alert
/// ends as cancelled, so nothing is printed, saved or opened). SwiftUI sheets are shown in a window of their own (their
/// state is the view's), which has their content and controls. Demo mode only: the made-up printers and scanners.
extension Report {
    static func axAuditCheck(_ model: AppModel) async -> [String] {
        guard model.isDemo else { return ["ax audit: demo mode only (--demo)"] }
        let spanish: [String: String] = AppLanguage.current == "es"
            ? AxWalk.table("Localizable").merging(AxWalk.table("CoreStrings")) { (first: String, _: String) -> String in first } : [:]
        var walk = AxWalk(spanish: spanish)
        try? await Task.sleep(for: .seconds(2))
        let main = NSApp.windows.first { (w: NSWindow) -> Bool in w.isVisible && w.styleMask.contains(.titled) }
        walk.audit(main, "main window")

        // Windows of their own.
        await window(&walk, "print log") { _ = PrintLogWindow.show(model) } close: { PrintLogWindow.close() }
        _ = PrintLogWindow.show(model)
        try? await Task.sleep(for: .milliseconds(600))
        await modal(&walk, "print log: Clear the Log?") { PrintLogWindow.model?.clear() }
        PrintLogWindow.close()
        await window(&walk, "Set Up a Printer's Wi-Fi") { _ = PrinterSetupWindow.show(model) } close: { PrinterSetupWindow.closeForReport() }

        if let scan = await demoScanner(model) {
            await window(&walk, "Use Your Camera", wait: 2000) { scan.scanWithCamera() } close: { CameraWindow.close() }
            for _ in 0..<50 where scan.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            scan.clear()
            await window(&walk, "Use Your Phone", wait: 2000) { scan.scanWithPhone() } close: { PhoneWindow.close() }
            for _ in 0..<50 where scan.isScanning { try? await Task.sleep(for: .milliseconds(100)) }
            scan.clear()
            await hosted(&walk, "Recent Scans", RecentScansSheet(app: model, printer: scan.owner))
            await scanAndWait(scan)
            if let page = scan.pages.pages.first {
                await hosted(&walk, "Join Two Halves", JoinSheet(scan: scan, id: page.id), wait: 2500)
            } else {
                walk.note("Join Two Halves: no page scanned to join", finding: true)
            }
            scan.clear()
            await modal(&walk, "a turned stack's question") { _ = scan.turnStackQuestion(3) }
            await hosted(&walk, "Print Photos", PhotosView(printer: scan.owner, app: model), wait: 1500)
        } else {
            walk.note("scanner windows: no demo inkjet", finding: true)
        }

        // Modal alerts.
        await modal(&walk, "Share a Printer with Phones") { PhoneSharing.show(model) }
        await modal(&walk, "Print on Both Sides by Hand: copies") { _ = HandDuplexPrinting.askCopies("Synthetic.pdf") }
        let plan = HandDuplexPlan.plan(Array(0..<5))
        await modal(&walk, "Print on Both Sides by Hand: between the sides") {
            _ = HandDuplexPrinting.prompt("Synthetic.pdf", plan, queue: "ax-audit", printer: .down)
        }
        let preset = ScanPresets.builtIns()[0].name
        await modal(&walk, "a preset's PDF password") { _ = PresetPasswordPrompt.ask(presetName: preset) }
        return ["ax audit (\(AppLanguage.current)):"] + walk.lines + [walk.summary]
    }

    private static func visible() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map { (w: NSWindow) -> ObjectIdentifier in ObjectIdentifier(w) })
    }

    /// The titled window that wasn't showing before.
    private static func fresh(_ before: Set<ObjectIdentifier>) -> NSWindow? {
        NSApp.windows.first { (w: NSWindow) -> Bool in w.isVisible && !before.contains(ObjectIdentifier(w)) && w.styleMask.contains(.titled) }
    }

    /// Opens a window with `open`, audits it once it shows, and closes it with `close`.
    private static func window(_ walk: inout AxWalk, _ name: String, wait: Int = 900, _ open: @MainActor () -> Void,
                               close: @MainActor () -> Void) async {
        let before = visible()
        open()
        var found: NSWindow?
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(100))
            if let w = fresh(before) { found = w; break }
        }
        guard let window = found else {
            walk.note("\(name): no window showed", finding: true)
            return
        }
        try? await Task.sleep(for: .milliseconds(wait))
        walk.audit(window.attachedSheet ?? window, name)
        close()
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// A SwiftUI sheet's view in a window of its own, audited, then closed.
    private static func hosted<V: View>(_ walk: inout AxWalk, _ name: String, _ view: V, wait: Int = 1000) async {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: view)
        w.center()
        w.makeKeyAndOrderFront(nil)
        try? await Task.sleep(for: .milliseconds(wait))
        walk.audit(w, name + " (its sheet's content)")
        w.close()
        try? await Task.sleep(for: .milliseconds(300))
    }

    /// Puts up a modal alert with `trigger` (from the run loop, so its modal loop doesn't block this check), audits it,
    /// then ends it as cancelled.
    private static func modal(_ walk: inout AxWalk, _ name: String, _ trigger: @escaping @MainActor () -> Void) async {
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { trigger() } }
        var found: NSWindow?
        for _ in 0..<60 {
            try? await Task.sleep(for: .milliseconds(100))
            if let w = NSApp.modalWindow { found = w; break }
        }
        guard let window = found else {
            walk.note("\(name): no alert showed", finding: true)
            return
        }
        try? await Task.sleep(for: .milliseconds(500))
        walk.audit(window, name)
        NSApp.stopModal(withCode: .cancel)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                         context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
        for _ in 0..<30 where NSApp.modalWindow != nil { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(300))
    }
}
