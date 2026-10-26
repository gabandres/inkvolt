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
