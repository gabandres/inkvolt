import AppKit
import CCups
import Foundation

/// Research open items 1 and 2: can a sandboxed app reach cupsd, and which operations does it refuse?
enum CupsChecks {
    static let attributeNames = [
        "printer-state", "printer-state-reasons", "printer-state-message", "printer-is-accepting-jobs",
        "queued-job-count", "marker-names", "marker-types", "marker-levels", "marker-colors",
    ]

    @MainActor static func listQueues(_ log: ProbeLog) async {
        let names = NSPrinter.printerNames
        log.add("NSPrinter.printerNames: \(names.count) [\(names.joined(separator: ", "))]")
        let lines = await offMain { () -> [String] in
            var dests: UnsafeMutablePointer<cups_dest_t>?
            let count = cupsGetDests2(nil, &dests)
            defer { cupsFreeDests(count, dests) }
            var out = ["cupsGetDests2: \(count) destination(s); last error \(lastError())"]
            guard let dests else { return out }
            for index in 0..<Int(count) {
                let dest = dests[index]
                func option(_ key: String) -> String {
                    cupsGetOption(key, dest.num_options, dest.options).map { String(cString: $0) } ?? "-"
                }
                // Only the device URI's scheme: the rest names a host.
                let scheme = option("device-uri").split(separator: ":").first.map(String.init) ?? "-"
                out.append("\(String(cString: dest.name))\(dest.is_default != 0 ? " (default)" : ""): "
                    + "state \(option("printer-state")), reasons \(option("printer-state-reasons")), "
                    + "accepting \(option("printer-is-accepting-jobs")), device \(scheme)")
            }
            return out
        }
        lines.forEach(log.add)
    }

    @MainActor static func attributes(_ log: ProbeLog, queue: String) async {
        guard !queue.isEmpty else { log.add("Enter a CUPS queue name (from List queues)."); return }
        let lines = await offMain { () -> [String] in
            let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES)
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerUri(queue))
            guard let response = cupsDoRequest(nil, request, "/") else {
                return ["libcups Get-Printer-Attributes: no response; last error \(lastError())"]
            }
            defer { ippDelete(response) }
            var out = ["libcups Get-Printer-Attributes: \(statusText(ippGetStatusCode(response)))"]
            for name in attributeNames {
                if let attribute = ippFindAttribute(response, name, IPP_TAG_ZERO) {
                    out.append("  \(name) = \(values(attribute))")
                } else {
                    out.append("  \(name): missing")
                }
            }
            return out
        }
        lines.forEach(log.add)

        // The same question over TCP to localhost:631, the route the app's own IPP code would take.
        var request = URLRequest(url: URL(string: "http://localhost:631/printers/\(queue)")!)
        request.httpMethod = "POST"
        request.setValue("application/ipp", forHTTPHeaderField: "Content-Type")
        request.httpBody = rawGetPrinterAttributes(printerUri(queue))
        request.timeoutInterval = 5
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ipp = data.count >= 4 ? String(format: "0x%04x", Int(data[2]) << 8 | Int(data[3])) : "short reply"
            let markers = data.range(of: Data("marker-levels".utf8)) != nil ? "present" : "absent"
            log.add("localhost:631: HTTP \(http), IPP status \(ipp), \(data.count) bytes, marker-levels \(markers)")
        } catch {
            log.add("localhost:631: \(describe(error))")
        }
    }

    @MainActor static func protectedOperations(_ log: ProbeLog, queue: String) async {
        guard !queue.isEmpty else { log.add("Enter a CUPS queue name (from List queues)."); return }
        let lines = await offMain { () -> [String] in
            // No password prompt: an operation that needs one should fail, which is the answer.
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            var out: [String] = []
            for (label, operation) in [("Resume-Printer", IPP_OP_RESUME_PRINTER), ("CUPS-Accept-Jobs", IPP_OP_CUPS_ACCEPT_JOBS)] {
                let request = ippNewRequest(operation)
                ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerUri(queue))
                ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
                let response = cupsDoRequest(nil, request, "/admin/")
                out.append("\(label): \(response.map { statusText(ippGetStatusCode($0)) } ?? "no response"); last error \(lastError())")
                if let response { ippDelete(response) }
            }
            for group in ["_lpadmin", "lpadmin", "_lpoperator"] {
                if let entry = getgrnam(group) {
                    out.append("group \(group): gid \(entry.pointee.gr_gid)")
                } else {
                    out.append("group \(group): not found")
                }
            }
            return out
        }
        lines.forEach(log.add)
    }

    private static func printerUri(_ queue: String) -> String { "ipp://localhost/printers/\(queue)" }

    private static func lastError() -> String {
        let text = cupsLastErrorString().map { String(cString: $0) } ?? ""
        return "0x\(String(cupsLastError().rawValue, radix: 16)) \(text)"
    }

    private static func statusText(_ status: ipp_status_t) -> String {
        let name = ippErrorString(status).map { String(cString: $0) } ?? ""
        return "status 0x\(String(status.rawValue, radix: 16)) \(name)"
    }

    private static func values(_ attribute: OpaquePointer) -> String {
        let tag = ippGetValueTag(attribute)
        var parts: [String] = []
        for index in 0..<ippGetCount(attribute) {
            switch tag {
            case IPP_TAG_INTEGER, IPP_TAG_ENUM:
                parts.append(String(ippGetInteger(attribute, index)))
            case IPP_TAG_BOOLEAN:
                parts.append(ippGetBoolean(attribute, index) != 0 ? "true" : "false")
            default:
                parts.append(ippGetString(attribute, index, nil).map { String(cString: $0) } ?? "?")
            }
        }
        return parts.joined(separator: ", ")
    }

    /// A Get-Printer-Attributes request encoded by hand (RFC 8010), so the TCP route doesn't depend on libcups.
    private static func rawGetPrinterAttributes(_ printerUri: String) -> Data {
        var data = Data([0x02, 0x00, 0x00, 0x0B, 0x00, 0x00, 0x00, 0x01, 0x01])
        func attribute(_ tag: UInt8, _ name: String, _ value: String) {
            let name = Array(name.utf8), value = Array(value.utf8)
            data.append(tag)
            data.append(contentsOf: [UInt8(name.count >> 8), UInt8(name.count & 0xFF)])
            data.append(contentsOf: name)
            data.append(contentsOf: [UInt8(value.count >> 8), UInt8(value.count & 0xFF)])
            data.append(contentsOf: value)
        }
        attribute(0x47, "attributes-charset", "utf-8")
        attribute(0x48, "attributes-natural-language", "en")
        attribute(0x45, "printer-uri", printerUri)
        data.append(0x03)
        return data
    }
}
