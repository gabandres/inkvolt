import AppKit
import Foundation
import ImageCaptureCore
import Security
import ServiceManagement

/// The environment report, and research open items 3, 9 and 10.
enum SystemChecks {
    static let entitlements = [
        "com.apple.security.app-sandbox", "com.apple.security.network.client", "com.apple.security.network.server",
        "com.apple.security.print", "com.apple.security.device.usb", "com.apple.security.files.user-selected.read-write",
    ]

    static let settingsLinks = [
        "x-apple.systempreferences:com.apple.Print-Scan-Settings.extension",
        "x-apple.systempreferences:com.apple.preference.printfax",
    ]

    @MainActor static func environment(_ log: ProbeLog) async {
        let info = ProcessInfo.processInfo
        log.add("macOS \(info.operatingSystemVersionString)")
        log.add("sandbox container: \(info.environment["APP_SANDBOX_CONTAINER_ID"] != nil ? "yes" : "no")")
        if let task = SecTaskCreateFromSelf(nil) {
            for key in entitlements {
                let value = SecTaskCopyValueForEntitlement(task, key as CFString, nil)
                log.add("\(key): \(value.map { "\($0)" } ?? "absent")")
            }
        }
        for network in ipv4Interfaces() {
            log.add("\(network.name): \(mask(network.address)) mask \(network.netmask ?? "-") "
                + "broadcast \(network.broadcast.map(mask) ?? "-")\(network.isPrivate ? " private" : "")")
        }
    }

    @MainActor static func openSettings(_ log: ProbeLog, index: Int) async {
        let link = settingsLinks[index]
        let opened = NSWorkspace.shared.open(URL(string: link)!)
        log.add("\(link): open returned \(opened); note which pane appeared")
    }

    @MainActor static func http(_ log: ProbeLog, address: String) async {
        guard isIPv4(address) else { log.add("Enter an IPv4 address."); return }
        let session = URLSession(configuration: .ephemeral, delegate: AcceptAnyCertificate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        for path in ["http://\(address)/", "http://\(address)/eSCL/ScannerCapabilities", "https://\(address)/"] {
            let shown = path.replacingOccurrences(of: address, with: mask(address))
            var request = URLRequest(url: URL(string: path)!)
            request.timeoutInterval = 5
            do {
                let (data, response) = try await session.data(for: request)
                log.add("\(shown): HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0), \(data.count) bytes")
            } catch {
                log.add("\(shown): \(describe(error))")
            }
        }
    }

    @MainActor static func login(_ log: ProbeLog, change register: Bool?) async {
        let service = SMAppService.mainApp
        do {
            switch register {
            case true?: try service.register()
            case false?: try await service.unregister()
            case nil: break
            }
            log.add("status: \(statusName(service.status))")
        } catch {
            log.add("failed: \(describe(error)); status \(statusName(service.status))")
        }
    }

    private static func statusName(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: "notRegistered"
        case .enabled: "enabled"
        case .requiresApproval: "requiresApproval"
        case .notFound: "notFound"
        @unknown default: "unknown \(status.rawValue)"
        }
    }
}

/// Test only: printers serve self-signed certificates. The app will pin them instead.
final class AcceptAnyCertificate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge)
        async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            return (.useCredential, URLCredential(trust: trust))
        }
        return (.performDefaultHandling, nil)
    }
}

/// Research open item 4: does ImageCaptureCore see USB and network scanners from the sandbox?
enum ScannerChecks {
    @MainActor static func scanners(_ log: ProbeLog) async {
        let watch = ScannerWatch()
        watch.start()
        try? await Task.sleep(for: .seconds(15))
        watch.stop()
        if watch.events.isEmpty { log.add("No scanners, no events in 15 s") }
        watch.events.forEach(log.add)
    }
}

final class ScannerWatch: NSObject, ICDeviceBrowserDelegate {
    private let browser = ICDeviceBrowser()
    private(set) var events: [String] = []

    func start() {
        let raw = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
            | ICDeviceLocationTypeMask.bonjour.rawValue | ICDeviceLocationTypeMask.shared.rawValue
        browser.delegate = self
        browser.browsedDeviceTypeMask = typeMask(raw) ?? .scanner
        browser.start()
    }

    func stop() { browser.stop() }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        events.append("added: \(device.name ?? "?") via \(device.transportType ?? "?")")
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        events.append("removed: \(device.name ?? "?")")
    }

    func deviceBrowserDidEnumerateLocalDevices(_ browser: ICDeviceBrowser) {
        events.append("local devices enumerated")
    }

    /// Builds the mask whether the SDK imports it as an option set or as a failable raw-value type.
    private func typeMask<T: RawRepresentable>(_ raw: T.RawValue) -> T? { T(rawValue: raw) }
}
