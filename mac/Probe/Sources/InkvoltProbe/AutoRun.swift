import AppKit
import Foundation

/// `open InkvoltProbe.app --args --auto --name full --address 192.0.2.10 --queue Office [--protected] [--stay]`: runs every check that
/// needs no one at the screen, in order, writes the report to the app's container
/// (`Library/Application Support/InkvoltProbe/report-<name>.txt`) and quits. Left out: the Settings links (someone has to
/// look at which pane opens) and registering for launch at login (it adds a login item).
enum AutoRun {
    @MainActor static func runIfAsked(_ log: ProbeLog) async {
        let args = CommandLine.arguments
        guard args.contains("--auto") else { return }
        func value(_ name: String) -> String {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return "" }
            return args[i + 1]
        }
        let address = value("--address"), queue = value("--queue")
        let name = value("--name").isEmpty ? "auto" : value("--name")

        var steps: [(String, @MainActor (ProbeLog) async -> Void)] = [
            ("Environment", { await SystemChecks.environment($0) }),
            // First on the network: what the checks see while the Local Network alert is still unanswered.
            ("TCP sweep", { await NetworkChecks.sweep($0) }),
            ("CUPS queues", { await CupsChecks.listQueues($0) }),
            ("CUPS attributes", { await CupsChecks.attributes($0, queue: queue) }),
        ]
        if args.contains("--protected") {
            steps.append(("CUPS protected operations", { await CupsChecks.protectedOperations($0, queue: queue) }))
        }
        steps += [
            ("Bonjour", { await NetworkChecks.bonjour($0) }),
            ("SNMP broadcast", { await NetworkChecks.snmpBroadcast($0) }),
            ("SNMP unicast", { await NetworkChecks.snmpUnicast($0, address: address) }),
            ("ATS", { await SystemChecks.http($0, address: address) }),
            ("ImageCaptureCore", { await ScannerChecks.scanners($0) }),
            ("SMAppService", { await SystemChecks.login($0, change: nil) }),
        ]
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("InkvoltProbe")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log.reportFile = folder.appendingPathComponent("report-\(name).txt")
        log.add("Inkvolt Probe automatic run \"\(name)\"")
        for (title, step) in steps {
            log.add("== \(title)  [\(ISO8601DateFormatter().string(from: Date()))]")
            await step(log)
            log.add("")
        }
        log.add("== Done")
        // --stay: the window (and the Local Network alert, if it's still unanswered) waits for someone at the Mac.
        if !args.contains("--stay") { NSApp.terminate(nil) }
    }
}
