import Foundation
import PrintCore

/// `--report --demo --web-port`: a printer's web server on a port of its own (Windows' PrinterWebPortTests). The demo laser
/// typed in Add a printer with a port (`http://<demo laser>:8080`) is probed there (demo mode's made-up network answers on
/// every port, so LEDM answers at 8080 and the root is kept), set on the listed laser, which connects again and remembers it
/// (the state's `webRoot`, its web page there); typed again as a plain address, the default ports come back.
extension Report {
    static func webPortCheck(_ model: AppModel) async -> [String] {
        guard let p = model.printers.first(where: { $0.id == Demo.uuid }) else { return ["web port: no demo laser"] }
        var lines = ["web port:"]
        let typed = "http://\(p.host):8080/hp/device/info"
        let a = PrinterAddress.parse(typed)
        lines.append("  typed \(typed): web \(a.web?.absoluteString ?? "none"), IPP \(a.ipp?.absoluteString ?? "none")")
        guard let host = a.host, let probe = await model.probe(host, ipp: a.ipp, snmpLogin: .public, web: a.web) else {
            return lines + ["  no answer there"]
        }
        lines.append("  probe: \(probe.interfaces.joined(separator: ", ")); kept: \(probe.webRootKept(a.web)?.absoluteString ?? "none")")
        p.setWebRoot(probe.webRootKept(a.web))
        lines.append("  connected again: \(await connectedWith(p, model) { $0 != nil })")
        lines.append("  remembered: \(model.store.read { s in s.printers.first { $0.uuid == p.id }?.webRoot } ?? "none"), web page \(p.webPage?.absoluteString ?? "none")")
        let plain = PrinterAddress.parse("http://\(p.host)/")
        let again = await model.probe(p.host, ipp: plain.ipp, snmpLogin: .public, web: plain.web)
        p.setWebRoot(again?.webRootKept(plain.web))
        lines.append("  typed as a plain address: \(await connectedWith(p, model) { $0 == nil }), web page \(p.webPage?.absoluteString ?? "none")")
        return lines
    }

    /// Waits up to 15 s for the laser's remembered web root to satisfy `done` with the laser online: "yes" or "no".
    private static func connectedWith(_ p: PrinterModel, _ model: AppModel, _ done: (String?) -> Bool) async -> String {
        for _ in 0..<60 {
            let root = model.store.read { s in s.printers.first { $0.uuid == p.id }?.webRoot }
            if p.view.isOnline && done(root) { return "yes" }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return "no"
    }
}
