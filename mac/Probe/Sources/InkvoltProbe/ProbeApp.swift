import AppKit
import SwiftUI

@main
struct ProbeApp: App {
    @NSApplicationDelegateAdaptor(LaunchDelegate.self) private var launch
    @StateObject private var log = ProbeLog.shared

    var body: some Scene {
        WindowGroup("Inkvolt Probe") {
            ProbeView().environmentObject(log)
        }
    }
}

/// The report: one check at a time, each under a heading. Addresses are masked to their last octet, so a report can
/// be pasted into a chat without the network's addresses.
/// Starts the automatic run at launch, whether or not a window ever shows (a locked or sleeping screen).
final class LaunchDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in await AutoRun.runIfAsked(ProbeLog.shared) }
    }
}

@MainActor
final class ProbeLog: ObservableObject {
    static let shared = ProbeLog()

    /// Where an automatic run writes each line as it goes.
    var reportFile: URL?

    @Published private(set) var lines: [String] = []
    @Published private(set) var busy = false

    var text: String { lines.joined(separator: "\n") }

    func add(_ line: String) {
        lines.append(line)
        if let reportFile { try? Data(text.utf8).write(to: reportFile) }
    }
    func clear() { lines.removeAll() }

    func run(_ title: String, _ check: @escaping @MainActor (ProbeLog) async -> Void) {
        guard !busy else { return }
        busy = true
        add("== \(title)")
        Task { @MainActor in
            await check(self)
            add("")
            busy = false
        }
    }
}

struct ProbeView: View {
    @EnvironmentObject private var log: ProbeLog
    @AppStorage("address") private var address = ""
    @AppStorage("queue") private var queue = ""

    var body: some View {
        HSplitView {
            Form {
                Section("Setup") {
                    TextField("Printer address (IPv4)", text: $address)
                    TextField("CUPS queue name", text: $queue)
                    Button("Entitlements, networks") { log.run("Environment") { await SystemChecks.environment($0) } }
                }
                Section("1-2 CUPS") {
                    Button("List queues (NSPrinter, libcups)") { log.run("CUPS queues") { await CupsChecks.listQueues($0) } }
                    Button("Queue attributes (socket, localhost:631)") {
                        let queue = queue
                        log.run("CUPS attributes") { await CupsChecks.attributes($0, queue: queue) }
                    }
                    Button("Resume and Accept-Jobs (changes the queue if allowed)") {
                        let queue = queue
                        log.run("CUPS protected operations") { await CupsChecks.protectedOperations($0, queue: queue) }
                    }
                }
                Section("3 Printers & Scanners") {
                    ForEach(SystemChecks.settingsLinks.indices, id: \.self) { index in
                        Button("Open link \(index + 1)") {
                            log.run("Settings link \(index + 1)") { await SystemChecks.openSettings($0, index: index) }
                        }
                    }
                }
                Section("4-5 Scanners, Bonjour") {
                    Button("ImageCaptureCore scanners (15 s)") { log.run("ImageCaptureCore") { await ScannerChecks.scanners($0) } }
                    Button("Bonjour, listed and unlisted types") { log.run("Bonjour") { await NetworkChecks.bonjour($0) } }
                }
                Section("6-7 Local network") {
                    Button("SNMP broadcast on each network") { log.run("SNMP broadcast") { await NetworkChecks.snmpBroadcast($0) } }
                    Button("SNMP to the address") {
                        let address = address
                        log.run("SNMP unicast") { await NetworkChecks.snmpUnicast($0, address: address) }
                    }
                    Button("TCP 631/9100/515 sweep of this /24") { log.run("TCP sweep") { await NetworkChecks.sweep($0) } }
                }
                Section("9 App Transport Security") {
                    Button("HTTP and HTTPS to the address") {
                        let address = address
                        log.run("ATS") { await SystemChecks.http($0, address: address) }
                    }
                }
                Section("10 Launch at login") {
                    Button("Status") { log.run("SMAppService") { await SystemChecks.login($0, change: nil) } }
                    Button("Register") { log.run("SMAppService register") { await SystemChecks.login($0, change: true) } }
                    Button("Unregister") { log.run("SMAppService unregister") { await SystemChecks.login($0, change: false) } }
                }
            }
            .formStyle(.grouped)
            .disabled(log.busy)
            .frame(minWidth: 360)

            VStack(alignment: .leading, spacing: 0) {
                ScrollView {
                    Text(log.text)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                HStack {
                    Button("Copy report") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(log.text, forType: .string)
                    }
                    Button("Clear") { log.clear() }
                    if log.busy { ProgressView().controlSize(.small) }
                }
                .padding(8)
            }
            .frame(minWidth: 440)
        }
        .frame(minHeight: 600)
    }
}

// MARK: - Helpers shared by the checks

let probeQueue = DispatchQueue(label: "probe")

func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await Task.detached { work() }.value
}

/// Claims a one-time result from callbacks that may fire more than once (state changes, timeouts).
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

func mask(_ ip: String) -> String {
    "*.*.*." + (ip.split(separator: ".").last.map(String.init) ?? "?")
}

func describe(_ error: Error) -> String {
    let ns = error as NSError
    return "\(ns.domain) \(ns.code)"
}

func errnoText() -> String {
    let code = errno
    return "errno \(code) \(String(cString: strerror(code)))"
}

func isIPv4(_ text: String) -> Bool {
    var address = in_addr()
    return inet_pton(AF_INET, text, &address) == 1
}
