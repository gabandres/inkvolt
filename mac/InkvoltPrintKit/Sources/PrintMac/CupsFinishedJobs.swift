import CCups
import Foundation
import PrintCore

/// The print log's read of CUPS's own history (roadmap 4.9): IPP Get-Jobs over cupsd's socket, as the user, for every queue
/// (`printer-uri` `ipp://localhost/`) with `which-jobs=completed` (cancelled, aborted and completed jobs), the newest first,
/// at most `limit`. Every user's jobs; cupsd leaves out other users' names and documents (research file, 4.9).
extension LibCups: FinishedJobHistory {
    public func finishedJobs(limit: Int) async -> [FinishedJob]? {
        let limit = min(max(limit, 1), PrintLogRecorder.maxOpen)
        return await Self.run {
            Self.jobGroups("ipp://localhost/", which: "completed", limit: limit, requested: FinishedJobAttributes.requested)?
                .compactMap(FinishedJobAttributes.job)
        }
    }
}
