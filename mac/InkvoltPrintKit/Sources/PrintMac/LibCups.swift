import CCups
import Foundation
import PrintCore

/// macOS's print queues through libcups, over cupsd's domain socket (never `localhost:631`, which the sandbox refuses).
/// Needs `com.apple.security.print`: without it libcups lists nothing. Calls block, so they run off the cooperative pool,
/// one at a time.
public struct LibCups: PrintQueues, QueueControl {
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
