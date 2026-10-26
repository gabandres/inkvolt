import CCups
import Foundation
import PrintCore

/// Whether "Set up in macOS" works on this Mac: the `--report … --setup-probe` step runs `LibCups.addQueue` for a test
/// queue on the printer an existing network queue prints to, says what cupsd made of it (permanent or temporary, its
/// driver), and deletes it again. Lines for the report; nothing is printed.
public enum CupsSetupProbe {
    static let testQueue = "Inkvolt_Setup_Test"

    public static func run() async -> [String] {
        var lines = ["setup probe: user \(LibCups().user)"]
        let destinations = await LibCups().destinations() ?? []
        guard let source = destinations.first(where: { d in
            CupsQueues.isRealQueue(d) && ["ipp", "ipps"].contains(d.deviceUri?.split(separator: ":").first.map { $0.lowercased() } ?? "")
        }), let uri = source.deviceUri else {
            lines.append("  no ipp queue to copy a device URI from")
            return lines
        }
        let plan = QueueSetupPlan(queueName: testQueue, deviceUri: uri, info: "Inkvolt setup test")
        let started = Date()
        do {
            try await LibCups().addQueue(plan)
            lines.append("  addQueue: ok in \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        } catch {
            lines.append("  addQueue: \(error)")
        }
        let after = await LibCups().destinations() ?? []
        if let d = after.first(where: { $0.name == testQueue }) {
            lines.append("  listed: temporary \(d.isTemporary), real queue \(CupsQueues.isRealQueue(d)), state \(d.options["printer-state"] ?? "-"), "
                + "model \(d.options["printer-make-and-model"] ?? "-"), info \(d.displayName)")
        } else {
            lines.append("  listed: not in cupsGetDests2")
        }
        lines.append("  delete: \(await delete(testQueue))")
        return lines
    }

    private static func delete(_ name: String) async -> String {
        await LibCups.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            guard let r = ippNewRequest(IPP_OP_CUPS_DELETE_PRINTER) else { return "no request" }
            ippAddString(r, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + name)
            ippAddString(r, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
            guard let response = cupsDoRequest(nil, r, "/admin/") else { return "0x\(String(cupsLastError().rawValue, radix: 16))" }
            defer { ippDelete(response) }
            let status = ippGetStatusCode(response)
            return status.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue ? "ok" : "0x\(String(status.rawValue, radix: 16))"
        }
    }
}
