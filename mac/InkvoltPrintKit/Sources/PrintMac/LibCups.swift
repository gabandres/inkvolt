import CCups
import Foundation
import PrintCore

/// macOS's print queues through libcups, over cupsd's domain socket (never `localhost:631`, which the sandbox refuses).
/// Needs `com.apple.security.print`: without it libcups lists nothing. Calls block, so they run off the cooperative pool,
/// one at a time.
public struct LibCups: PrintQueues, QueueControl, QueueSetupControl {
    public init() {}

    public func destinations() async -> [CupsDestination]? {
        await Self.run {
            var list: UnsafeMutablePointer<cups_dest_t>?
            let count = cupsGetDests2(nil, &list)
            defer { cupsFreeDests(count, list) }
            // None, and an error: cupsd couldn't be asked (no print entitlement: "Bad file descriptor", 0x502). "Not found"
            // (0x406, "No destinations added") is a Mac with no queue at all.
            if count == 0 {
                let error = cupsLastError()
                return error == IPP_STATUS_ERROR_NOT_FOUND || error.rawValue < IPP_STATUS_ERROR_BAD_REQUEST.rawValue ? [] : nil
            }
            guard let list else { return [] }
            var found: [CupsDestination] = []
            for i in 0..<Int(count) {
                let dest = list[i]
                guard dest.instance == nil, let name = dest.name.map({ String(cString: $0) }) else { continue } // instances are option sets
                var options: [String: String] = [:]
                for j in 0..<Int(dest.num_options) {
                    let o = dest.options[j]
                    if let key = o.name, let value = o.value { options[String(cString: key)] = String(cString: value) }
                }
                found.append(CupsDestination(name: name, options: options, jobs: Self.activeJobs(name)))
            }
            return found
        }
    }

    public var user: String { String(cString: cupsUser()) }

    public func jobs(_ queue: String) async -> [QueueJob]? {
        await Self.run {
            var list: UnsafeMutablePointer<cups_job_t>?
            let count = cupsGetJobs2(nil, &list, queue, 0, CUPS_WHICHJOBS_ACTIVE)
            defer { cupsFreeJobs(count, list) }
            guard count >= 0 else { return nil }
            guard let list else { return [] }
            return (0..<Int(count)).map { i in
                let j = list[i]
                return QueueJob(id: Int(j.id), name: j.title.map { String(cString: $0) } ?? "Untitled",
                                state: JobState(rawValue: Int(j.state.rawValue)) ?? .pending,
                                submitted: Date(timeIntervalSince1970: TimeInterval(j.creation_time)), owner: j.user.map { String(cString: $0) } ?? "")
            }
        }
    }

    public func cancel(_ queue: String, job: Int) async throws {
        let refused: PrintJobCancelError? = await Self.run {
            // Never ask for a password: a sandboxed app has no one to ask, and others' jobs aren't the user's to cancel.
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            let status = cupsCancelJob2(nil, queue, Int32(job), 0)
            if status.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue { return nil }
            switch status {
            case IPP_STATUS_ERROR_NOT_AUTHORIZED, IPP_STATUS_ERROR_FORBIDDEN, IPP_STATUS_ERROR_CUPS_AUTHENTICATION_CANCELED:
                return PrintJobCancelError("Only an administrator can cancel someone else's job.")
            case IPP_STATUS_ERROR_NOT_FOUND, IPP_STATUS_ERROR_NOT_POSSIBLE:
                return PrintJobCancelError("It has already finished.")
            default:
                return PrintJobCancelError(cupsLastErrorString().map { String(cString: $0) } ?? "macOS's printing system refused.")
            }
        }
        if let refused { throw refused }
    }

    public func resume(_ queue: String) async throws { try await Self.protected(IPP_OP_RESUME_PRINTER, queue) }

    public func acceptJobs(_ queue: String) async throws { try await Self.protected(IPP_OP_CUPS_ACCEPT_JOBS, queue) }

    /// Points the queue at another device URI (the offline fixer's `.pointAt`): CUPS-Add-Modify-Printer, an administrator's.
    public func setDeviceUri(_ queue: String, _ uri: String) async throws {
        let failure: QueueControlError? = await Self.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            return Self.ask(IPP_OP_CUPS_ADD_MODIFY_PRINTER, "ipp://localhost/printers/" + queue, path: "/admin/") { r in
                ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", nil, uri)
            }
        }
        if let failure { throw failure }
    }

    /// An operation cupsd keeps for operators and administrators (the probe showed both work from the sandbox for an
    /// administrator), asked as the user with no password prompt: a standard user is refused.
    private static func protected(_ operation: ipp_op_t, _ queue: String) async throws {
        let failure: QueueControlError? = await run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            guard let request = ippNewRequest(operation) else { return .failed("macOS's printing system couldn't be asked.") }
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + queue)
            ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
            guard let response = cupsDoRequest(nil, request, "/admin/") else {
                let status = cupsLastError()
                return status == IPP_STATUS_ERROR_FORBIDDEN || status == IPP_STATUS_ERROR_NOT_AUTHORIZED
                    || status == IPP_STATUS_ERROR_CUPS_AUTHENTICATION_CANCELED ? .refused
                    : .failed(cupsLastErrorString().map { String(cString: $0) } ?? "macOS's printing system didn't answer.")
            }
            defer { ippDelete(response) }
            let status = ippGetStatusCode(response)
            if status.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue { return nil }
            if status == IPP_STATUS_ERROR_FORBIDDEN || status == IPP_STATUS_ERROR_NOT_AUTHORIZED { return .refused }
            return .failed(cupsLastErrorString().map { String(cString: $0) } ?? "macOS's printing system refused.")
        }
        if let failure { throw failure }
    }

    /// "Set up in macOS" (`QueueSetup`): CUPS-Create-Local-Printer, which any local user may ask for, makes a temporary
    /// queue and has cupsd read the printer into its PPD (the queue is stopped until that's done); then
    /// CUPS-Add-Modify-Printer with `printer-is-temporary` false keeps it, which needs an administrator. Refused there, the
    /// temporary queue goes away by itself.
    public func addQueue(_ plan: QueueSetupPlan) async throws {
        let created: QueueControlError? = await Self.run {
            cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
            return Self.ask(ipp_op_t(rawValue: 0x4028), "ipp://localhost/", path: "/") { r in // CUPS-Create-Local-Printer
                ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_NAME, "printer-name", nil, plan.queueName)
                ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_URI, "device-uri", nil, plan.deviceUri)
                ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-info", nil, plan.info)
            }
        }
        if let created { throw created }
        // cupsd connects to the printer and writes the PPD: up to its 30 s timeout, then the queue is idle.
        var ready = false
        for _ in 0..<70 {
            try await Task.sleep(for: .milliseconds(500))
            let state = await Self.run { Self.printerState(plan.queueName) }
            guard let state else { throw QueueControlError.failed("The printer didn't tell macOS what it can do.") }
            if state != 5 { ready = true; break } // 5: stopped, still being set up
        }
        guard ready else { throw QueueControlError.failed("The printer didn't tell macOS what it can do in time.") }
        let kept: QueueControlError? = await Self.run {
            Self.ask(IPP_OP_CUPS_ADD_MODIFY_PRINTER, "ipp://localhost/printers/" + plan.queueName, path: "/admin/") { r in
                ippAddBoolean(r, IPP_TAG_PRINTER, "printer-is-temporary", 0)
                ippAddBoolean(r, IPP_TAG_PRINTER, "printer-is-accepting-jobs", 1)
                ippAddString(r, IPP_TAG_PRINTER, IPP_TAG_TEXT, "printer-info", nil, plan.info)
            }
        }
        if let kept { throw kept }
    }

    /// One request to cupsd as the user: nil when it took it.
    private static func ask(_ op: ipp_op_t, _ printerUri: String, path: String, _ fill: (OpaquePointer?) -> Void) -> QueueControlError? {
        // libcups keeps the callback per thread, and the queue's blocks may run on any: set it for each request.
        cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
        guard let request = ippNewRequest(op) else { return .failed("macOS's printing system couldn't be asked.") }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, printerUri)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        fill(request)
        let words = { cupsLastErrorString().map { String(cString: $0) } ?? "macOS's printing system refused." }
        guard let response = cupsDoRequest(nil, request, path) else {
            let status = cupsLastError()
            return status == IPP_STATUS_ERROR_FORBIDDEN || status == IPP_STATUS_ERROR_NOT_AUTHORIZED
                || status == IPP_STATUS_ERROR_CUPS_AUTHENTICATION_CANCELED ? .refused : .failed(words())
        }
        defer { ippDelete(response) }
        let status = ippGetStatusCode(response)
        if status.rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue { return nil }
        return status == IPP_STATUS_ERROR_FORBIDDEN || status == IPP_STATUS_ERROR_NOT_AUTHORIZED ? .refused : .failed(words())
    }

    /// The queue's `printer-state` (3 idle, 4 processing, 5 stopped); nil when cupsd has no such queue.
    private static func printerState(_ queue: String) -> Int? {
        cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
        guard let request = ippNewRequest(IPP_OP_GET_PRINTER_ATTRIBUTES) else { return nil }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + queue)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", nil, "printer-state")
        guard let response = cupsDoRequest(nil, request, "/") else { return nil }
        defer { ippDelete(response) }
        guard ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue,
              let attr = ippFindAttribute(response, "printer-state", IPP_TAG_ENUM) else { return nil }
        return Int(ippGetInteger(attr, 0))
    }

    /// The paper sizes the queue offers, with the margins its printer keeps (`cupsCopyDestInfo`, its media list): what
    /// Print Photos lays out on, borderless sizes included. Empty when cupsd can't say.
    public func media(_ queue: String) async -> [QueueMedia] {
        await Self.run {
            guard let dest = cupsGetNamedDest(nil, queue, nil) else { return [] }
            defer { cupsFreeDests(1, dest) }
            guard let info = cupsCopyDestInfo(nil, dest) else { return [] }
            defer { cupsFreeDestInfo(info) }
            let flags = UInt32(CUPS_MEDIA_FLAGS_DEFAULT)
            var found: [QueueMedia] = []
            for i in 0..<cupsGetDestMediaCount(nil, dest, info, flags) {
                var size = cups_size_t()
                guard cupsGetDestMediaByIndex(nil, dest, info, i, flags, &size) != 0 else { continue }
                let name = withUnsafeBytes(of: size.media) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
                func inches(_ hundredthsOfMm: Int32) -> Double { Double(hundredthsOfMm) / 2540 }
                found.append(QueueMedia(name: name, width: inches(size.width), height: inches(size.length), left: inches(size.left),
                                        top: inches(size.top), right: inches(size.right), bottom: inches(size.bottom)))
            }
            return found
        }
    }

    /// Jobs not finished yet, every user's (the count is what the queue holds).
    private static func activeJobs(_ queue: String) -> Int? {
        var jobs: UnsafeMutablePointer<cups_job_t>?
        let count = cupsGetJobs2(nil, &jobs, queue, 0, CUPS_WHICHJOBS_ACTIVE)
        defer { cupsFreeJobs(count, jobs) }
        return count >= 0 ? Int(count) : nil
    }

    private static let queue = DispatchQueue(label: "inkvolt.cups", qos: .utility)

    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { done in queue.async { done.resume(returning: body()) } }
    }
}
