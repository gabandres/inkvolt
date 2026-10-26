import AppKit
import PrintCore

/// `open "Inkvolt Print.app" --args --report <name> [--wait <seconds>] [--stay] [--demo]`: after `--wait` seconds (20 by
/// default) writes what the app shows to `Application Support/InkvoltPrint/report-<name>.txt` in its container, then quits
/// (unless `--stay`). For checking a build over SSH, where no one may be at the screen. Addresses are masked to their last
/// part, so a report can be pasted into a chat.
@MainActor
enum Report {
    static func runIfAsked(_ model: AppModel) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--report") else { return }
        let name = i + 1 < args.count && !args[i + 1].hasPrefix("--") ? args[i + 1] : "app"
        let wait = args.firstIndex(of: "--wait").flatMap { $0 + 1 < args.count ? Double(args[$0 + 1]) : nil } ?? 20
        Task {
            try? await Task.sleep(for: .seconds(wait))
            let folder = AppModel.dataFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data(text(model, after: wait).utf8).write(to: folder.appendingPathComponent("report-\(name).txt"), options: .atomic)
            if !args.contains("--stay") { NSApp.terminate(nil) }
        }
    }

    static func text(_ model: AppModel, after wait: Double) -> String {
        var lines = [
            "Inkvolt Print report, \(Int(wait)) s after launch\(model.isDemo ? " (demo)" : "")",
            "Local Network: \(model.localNetwork)",
            "Searching: \(model.isSearching)",
            "Menu bar: \(model.overall)",
            "Printers: \(model.printers.count)",
        ]
        for p in model.printers {
            let v = p.view
            lines.append("")
            lines.append("\(p.name) [\(mask(p.host))]\(p.id == model.selectedID ? " (selected)" : "")")
            lines.append("  \(v.phase): \(v.listLine)")
            if let detail = v.statusDetail { lines.append("  " + mask(detail, host: p.host)) }
            if let m = v.model ?? p.model { lines.append("  model: \(m)") }
            if !v.interfaces.isEmpty { lines.append("  over: \(v.interfaces.joined(separator: ", "))") }
            if let f = v.firmware { lines.append("  firmware: \(f.display)") }
            for s in v.supplies.map({ SupplyText($0) }) {
                lines.append("  supply: \(s.name): \(s.percentText)\(s.headline.map { ", \($0)" } ?? "")")
            }
            for a in v.alerts { lines.append("  alert (\(a.severity)): \(a.message)") }
            if let u = v.usage, let pages = u.totalImpressions { lines.append("  pages printed: \(pages)") }
        }
        for (_, line) in model.menuLines { lines.append("menu: \(line.level) \(line.name): \(line.text)") }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func mask(_ host: String) -> String {
        let parts = host.split(separator: ".")
        return parts.count == 4 && parts.allSatisfy({ Int($0) != nil }) ? "*.*.*.\(parts[3])" : "host"
    }

    private static func mask(_ text: String, host: String) -> String { text.replacingOccurrences(of: host, with: mask(host)) }
}

#if DEBUG
import ScreenCaptureKit

/// Debug builds only (`build.sh debug`): `open "Inkvolt Print.app" --args --demo --snapshot laser:0,inkjet:1
/// [--size 1180x720] [--dark] [--wait <seconds>]`. After `--wait` seconds (8 by default) shows the main window at
/// `--size` points and, for each `name:index`, selects the index-th printer and captures the window with ScreenCaptureKit
/// (as the screen shows it, at its scale, without the shadow) to `Application Support/InkvoltPrint/snapshot-<name>.png` in
/// the container, then quits. For the App Store screenshots. Needs Screen Recording permission for this build (macOS asks
/// the first time) and the Mac's screen unlocked. Release builds have none of this.
@MainActor
enum Snapshot {
    static func runIfAsked(_ model: AppModel) {
        let args = CommandLine.arguments
        func value(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        if args.contains("--open-demo") { // what "Try the Demo" does, from the sandbox
            Task {
                try? await Task.sleep(for: .seconds(3))
                model.openDemo()
            }
        }
        guard let list = value("--snapshot") else { return }
        let shots = list.split(separator: ",").map { item -> (String, Int) in
            let parts = item.split(separator: ":")
            return (String(parts[0]), parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        }
        let size = value("--size").map { $0.split(separator: "x").compactMap { Double($0) } } ?? [1180, 720]
        let wait = value("--wait").flatMap(Double.init) ?? 8
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task {
            try? await Task.sleep(for: .seconds(wait))
            MainWindow.bringForward()
            try? await Task.sleep(for: .seconds(1))
            let folder = AppModel.dataFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var log: [String] = []
            for (name, index) in shots {
                if index < model.printers.count { model.selectedID = model.printers[index].id }
                guard let window = mainWindow() else {
                    log.append("\(name): no window")
                    break
                }
                if size.count == 2 { window.setContentSize(NSSize(width: size[0], height: size[1])) }
                window.center()
                window.makeKeyAndOrderFront(nil)
                try? await Task.sleep(for: .seconds(1.5))
                do {
                    let png = try await capture(window)
                    try png.write(to: folder.appendingPathComponent("snapshot-\(name).png"))
                    log.append("\(name): ok")
                } catch {
                    log.append("\(name): \(error)")
                }
            }
            try? Data(log.joined(separator: "\n").utf8).write(to: folder.appendingPathComponent("snapshot-log.txt"))
            NSApp.terminate(nil)
        }
    }

    private static func capture(_ window: NSWindow) async throws -> Data {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let config = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        config.width = Int(target.frame.width * scale)
        config.height = Int(target.frame.height * scale)
        config.ignoreShadowsSingleWindow = true
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: target),
                                                               configuration: config)
        guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.contains(MainWindow.id) == true && $0.isVisible }
            ?? NSApp.windows.first { $0.isVisible && $0.frame.width > 400 && !($0 is NSPanel) }
    }
}
#endif
