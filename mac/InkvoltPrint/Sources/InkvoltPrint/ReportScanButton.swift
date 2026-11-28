import Foundation
import PrintCore

/// `--report … --demo --scan-button [press]` (roadmap 2.2, the Windows app's `--scan-button [press]`): the demo HP laser's
/// scan button turned on (this made-up Mac goes on its made-up panel, `Demo.panel`) and the USB laser's scanner's (its
/// made-up Scan button, `Demo.scannerButtons`); with `press`, each is pressed and the preset's scan waited for; then both are
/// turned off again and the panel's list read back.
extension Report {
    static func scanButtonCheck(_ model: AppModel, press: Bool) async -> [String] {
        var lines: [String] = []
        if let laser = model.printers.first(where: { $0.id == Demo.uuid }) {
            lines += await check("scan-button (HP laser)", laser, press: press) { Demo.panel?.press() == true }
            lines.append("  the panel's list after: \(Demo.panel?.names ?? [])")
        } else {
            lines.append("scan-button: no demo HP laser")
        }
        for _ in 0..<50 where !model.printers.contains(where: { $0.systemScanner?.id == Demo.laserScanner.id }) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        if let usb = model.printers.first(where: { $0.systemScanner?.id == Demo.laserScanner.id }) {
            lines += await check("scan-button (USB laser)", usb, press: press) {
                guard let scanner = Demo.scannerButtons.scanners.first(where: { $0.id == Demo.laserScanner.id }) else { return false }
                scanner.press()
                return true
            }
        } else {
            lines.append("scan-button: no demo USB laser")
        }
        return lines
    }

    private static func check(_ name: String, _ printer: PrinterModel, press: Bool, _ pressIt: () -> Bool) async -> [String] {
        let button = printer.scanButton
        for _ in 0..<100 where button.way == .unknown { try? await Task.sleep(for: .milliseconds(100)) }
        var lines = ["\(name): \(button.way), \(button.text(printer.buttonPreset?.name))", "  switch: \(button.switchText)"]
        await button.setOn(true)
        for _ in 0..<100 where button.way == .panel && button.panelState != .listed { try? await Task.sleep(for: .milliseconds(100)) }
        lines.append("  on: \(button.text(printer.buttonPreset?.name))")
        if button.way == .panel { lines.append("  the panel's list: \(Demo.panel?.names ?? []) as \(Demo.panel?.hosts ?? [])") }
        if press, let preset = printer.buttonPreset {
            // The preset's folder chosen first, as a person does once (else its first save asks with a panel no one answers).
            let folder = AppModel.dataFolder.appendingPathComponent("scan-button-check", isDirectory: true)
            try? FileManager.default.removeItem(at: folder)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            AppModel.shared.setPresetFolder(preset.id, folder)
            let scan = printer.scan
            let pressed = pressIt()
            let before = scan.pages.toSave.count
            try? await Task.sleep(for: .seconds(1))
            // Done when the scan ran and its pages are saved (recognising text takes a while): none left to save.
            for _ in 0..<300 where scan.isScanning || scan.isSaving || scan.pages.toSave.count > before { try? await Task.sleep(for: .milliseconds(200)) }
            lines.append("  pressed (\(pressed ? "yes" : "nothing to press")): the preset \(preset.name) ran, \(scan.status); saved: "
                + "\(files(in: folder.appendingPathComponent("Scans"))); the pane shows \(model(printer))")
        }
        await button.setOn(false)
        lines.append("  off: \(button.text(printer.buttonPreset?.name))")
        return lines
    }

    @MainActor private static func model(_ printer: PrinterModel) -> String {
        AppModel.shared.selectedID == printer.id ? "this printer's Scan tab" : "another printer"
    }
}
