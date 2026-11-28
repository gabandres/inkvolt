import Foundation
import PrintCore
import PrintMac

/// `--ica-scan [name] [--times n]`: scans the glass once (or `n` times in a row) through ImageCaptureCore on the first
/// scanner it lists whose name holds `name` (USB, or a network one), as the Scan tab does (`ConnectedScanner` over
/// `SystemScanDevice`), and lists every word ImageCaptureCore sent (the session, the unit, each page, the end) and each
/// page's size. Nothing is saved; no device's address in the report.
extension Report {
    static func icaScanCheck(name: String?, times: Int) async -> [String] {
        let browse = SystemScanners(network: true) { _ in }
        browse.start()
        defer {
            browse.closeSessions()
            browse.stop()
        }
        try? await Task.sleep(for: .seconds(6))
        guard let (s, device) = browse.allDevices.first(where: { name == nil || $0.scanner.name.localizedCaseInsensitiveContains(name ?? "") }) else {
            return ["ica scan: no scanner named \(name ?? "")"]
        }
        let started = ContinuousClock.now
        let trace = ShareLog()
        device.trace = { line in trace.add("+\((ContinuousClock.now - started).components.seconds)s \(line)") }
        let scanner = ConnectedScanner(s, device: device)
        var lines = ["ica scan: \(s.name) (\(s.usb ? "USB" : s.makerDriver ? "network, maker's driver" : "network, AirScan"))"]
        for n in 1...max(times, 1) {
            // At most 3 minutes a scan: one that hangs is cut off and said so, with what ImageCaptureCore sent until then.
            let scan = Task { () -> String in
                do {
                    var pages: [[UInt8]] = []
                    for try await page in scanner.scan(ScanRequest(source: .platen, color: .color, resolution: 200)) { pages.append(page) }
                    let sizes = pages.compactMap(ScanImaging.size).map { "\($0.width) × \($0.height)" }
                    return "\(pages.count) page(s) \(sizes), \(pages.map(\.count)) bytes"
                } catch {
                    return "failed: \(error)"
                }
            }
            let limit = Task {
                try? await Task.sleep(for: .seconds(180))
                scan.cancel()
            }
            let outcome = await scan.value
            limit.cancel()
            lines.append("  scan \(n): \(outcome)")
        }
        device.trace = nil
        return lines + trace.lines.map { "  ica: " + $0 }
    }
}
