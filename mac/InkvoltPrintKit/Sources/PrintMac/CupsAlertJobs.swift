import CCups
import Foundation
import PrintCore

/// Job alerts' read of a queue (roadmap 3.4): IPP Get-Jobs over cupsd's socket, as the user, twice: `not-completed` (waiting,
/// held, printing, stopped) and `aborted` (CUPS gave up on it; the newest `QueueJobAttributes.abortedLimit`, of which
/// `JobQueueState.of` keeps only recent ones). Not
/// `cupsGetJobs2`: only Get-Jobs gives `job-originating-host-name` (`localhost` for this Mac's own jobs) and the sheets printed
/// (research file, 3.4). Every user's jobs; cupsd leaves out other users' names and documents.
extension LibCups {
    public func alertJobs(_ queue: String) async -> [QueueJob]? {
        await Self.run {
            guard let waiting = Self.getJobs(queue, which: "not-completed"),
                  let aborted = Self.getJobs(queue, which: "aborted", limit: QueueJobAttributes.abortedLimit) else { return nil }
            var seen = Set<Int>()
            return (waiting + aborted).filter { seen.insert($0.id).inserted }
        }
    }

    /// One Get-Jobs: each job-attributes group's first values as text, read by `QueueJobAttributes`. Nil when cupsd refused or
    /// couldn't be asked. `limit`: at most that many (cupsd's first, the newest for finished jobs).
    private static func getJobs(_ queue: String, which: String, limit: Int? = nil) -> [QueueJob]? {
        cupsSetPasswordCB2({ _, _, _, _, _ in nil }, nil)
        guard let request = ippNewRequest(IPP_OP_GET_JOBS) else { return nil }
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_URI, "printer-uri", nil, "ipp://localhost/printers/" + queue)
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_NAME, "requesting-user-name", nil, cupsUser())
        ippAddString(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "which-jobs", nil, which)
        if let limit { ippAddInteger(request, IPP_TAG_OPERATION, IPP_TAG_INTEGER, "limit", Int32(limit)) }
        let names = QueueJobAttributes.requested.map { strdup($0) }
        defer { names.forEach { free($0) } }
        let values = names.map { UnsafePointer($0) }
        values.withUnsafeBufferPointer { list in
            _ = ippAddStrings(request, IPP_TAG_OPERATION, IPP_TAG_KEYWORD, "requested-attributes", Int32(list.count), nil, list.baseAddress)
        }
        guard let response = cupsDoRequest(nil, request, "/") else { return nil }
        defer { ippDelete(response) }
        guard ippGetStatusCode(response).rawValue < IPP_STATUS_REDIRECTION_OTHER_SITE.rawValue else { return nil }
        var jobs: [QueueJob] = []
        var group: [String: String] = [:]
        func flush() {
            if let job = QueueJobAttributes.job(group) { jobs.append(job) }
            group = [:]
        }
        var attribute = ippFirstAttribute(response)
        while let a = attribute {
            if ippGetGroupTag(a) != IPP_TAG_JOB || ippGetName(a) == nil {
                flush() // a group ends at the next group or at a separator
            } else if let name = ippGetName(a).map({ String(cString: $0) }), group[name] == nil, let value = text(a) {
                group[name] = value
            }
            attribute = ippNextAttribute(response)
        }
        flush()
        return jobs
    }

    private static func text(_ a: OpaquePointer) -> String? {
        switch ippGetValueTag(a) {
        case IPP_TAG_INTEGER, IPP_TAG_ENUM: return String(ippGetInteger(a, 0))
        case IPP_TAG_NOVALUE, IPP_TAG_UNKNOWN: return nil
        default: return ippGetString(a, 0, nil).map { String(cString: $0) }
        }
    }
}
