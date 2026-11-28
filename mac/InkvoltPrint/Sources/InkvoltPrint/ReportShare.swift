import AppKit
import Foundation
import PrintCore
import PrintMac

/// `--share-scanner [name] [--hold s]` (roadmap 3.1): a scanner shared on the network, checked without anyone at the screen.
/// With `--demo`: the demo laser's scanner card switched on (this Mac only, on 127.0.0.1), our eSCL client scanning its
/// glass through the share over HTTPS, then switched off and the port checked closed. Without: the first scanner
/// ImageCaptureCore lists whose name holds `name` (USB, or a network one: a check, as Windows' `ShareAsync` takes one the
/// card wouldn't offer) shared on this Mac's private networks and announced, on a keychain and a choice of the run's own
/// (nothing kept, the app's own sharing untouched), held `--hold` seconds for a device on the network to scan through it,
/// then stopped; with `--self-scan`, our client on this Mac scans a page from its glass through the share. No device's address in the report.
extension Report {
    static func shareScannerCheck(_ model: AppModel, name: String?, hold: Int, selfScan: Bool) async -> [String] {
        model.isDemo ? await demoShareCheck(model, hold: hold) : await systemShareCheck(name: name, hold: hold, selfScan: selfScan)
    }

    private static func demoShareCheck(_ model: AppModel, hold: Int) async -> [String] {
        let entry = { model.printers.first { $0.systemScanner?.id == Demo.laserScanner.id } }
        for _ in 0..<100 where entry() == nil { try? await Task.sleep(for: .milliseconds(100)) } // the list is made a moment after launch
        guard let p = entry(), let s = p.systemScanner else {
            return ["share scanner: no demo laser scanner among \(model.printers.map { "\($0.name) (\($0.systemScanner?.name ?? "-"))" })"]
        }
        var lines = ["share scanner (demo, \(p.name)):"]
        let before = model.shareCard(p)
        lines.append("  card before: shown \(before.isShown), on \(before.isOn): \(before.text)")
        model.setSharing(true, s)
        for _ in 0..<100 where model.scannerShare.state != .on { try? await Task.sleep(for: .milliseconds(100)) }
        let card = model.shareCard(p)
        lines.append("  card: on \(card.isOn), fingerprint shown \(card.fingerprint != nil): \(card.text)")
        guard let port = model.scannerShare.port else { return lines + ["  not listening: \(model.scannerShare.problem ?? "")"] }
        lines += await clientLines(port: port, scan: true)
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        model.setSharing(false, s)
        for _ in 0..<100 where model.scannerShare.state != .off { try? await Task.sleep(for: .milliseconds(100)) }
        lines.append("  off: \(model.shareCard(p).text) | port still answers: \((try? await client(port).status()) != nil)")
        return lines + model.shareLog.lines.map { "  log: " + $0 }
    }

    private static func systemShareCheck(name: String?, hold: Int, selfScan: Bool) async -> [String] {
        let browse = SystemScanners(network: true) { _ in }
        browse.start()
        defer { browse.stop() }
        try? await Task.sleep(for: .seconds(6))
        let all = browse.allDevices
        var lines = ["share scanner: ICC lists \(all.count) scanner(s)"]
        guard let (s, device) = all.first(where: { name == nil || $0.scanner.name.localizedCaseInsensitiveContains(name ?? "") }) else {
            return lines + ["  none named \(name ?? "")"]
        }
        let kind = s.usb ? "USB" : s.makerDriver ? "network, maker's driver" : "network, AirScan (eSCL: the card wouldn't offer it)"
        lines.append("  \(s.name) (\(kind))")
        guard let keychain = try? KeychainFile() else { return lines + ["  no keychain file for the run"] }
        defer { keychain.delete() }
        let log = ShareLog()
        let env = ShareEnvironment(host: NetworkShareHost(), networks: SystemShareNetworks(), advertiser: BonjourShareAdvertiser(),
                                   certificates: PhoneCertificateKeychain(keychain: keychain.keychain))
        let share = ScannerShare(env, computerName: Host.current().localizedName ?? "Mac", choice: nil, save: { _ in }, log: { log.add($0) })
        let connected = ConnectedScanner(s, device: device)
        await share.share(connected)
        let caps = try? await connected.capabilities()
        let describe: (InputCaps?) -> String = { c in c.map { "\($0.maxWidth)x\($0.maxHeight)/300 in, \($0.resolutions) dpi, \($0.colorModes)" } ?? "-" }
        lines.append("  glass \(describe(caps?.platen)); feeder \(describe(caps?.adf))")
        lines.append("  state \(share.state), served networks \(SharePeers.served(SystemShareNetworks().read()).count): \(share.text(s.id))")
        if let port = share.port { lines += await clientLines(port: port, scan: selfScan) }
        if hold > 0 { try? await Task.sleep(for: .seconds(hold)) }
        await share.stop()
        await share.close()
        lines.append("  stopped: \(share.state)")
        return lines + log.lines.map { "  log: " + $0 }
    }

    private static func client(_ port: Int) -> EsclClient {
        EsclClient(DeviceHttp(host: "127.0.0.1", transport: URLSessionTransport.factory(localNetwork: nil)), root: URL(string: "https://127.0.0.1:\(port)/eSCL/")!)
    }

    /// Our eSCL client on this Mac, over HTTPS: the capabilities, and with `scan`, one page from the glass.
    private static func clientLines(port: Int, scan: Bool) async -> [String] {
        let client = client(port)
        var lines: [String] = []
        do {
            let caps = try await client.capabilities()
            lines.append("  client: \(caps?.makeAndModel ?? "?"), sources \(caps?.sources.map { "\($0)" } ?? []), formats \(caps?.platen?.documentFormats ?? [])")
            guard scan else { return lines }
            var pages: [[UInt8]] = []
            for try await page in client.scan(ScanRequest(source: .platen, color: .color, resolution: 150)) { pages.append(page) }
            let sizes = pages.compactMap(ScanImaging.size).map { "\($0.width) × \($0.height)" }
            lines.append("  client scanned \(pages.count) page(s) \(sizes)")
        } catch {
            lines.append("  client failed: \(error)")
        }
        return lines
    }
}
