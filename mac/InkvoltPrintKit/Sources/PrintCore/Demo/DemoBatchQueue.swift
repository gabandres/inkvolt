import Foundation
import Synchronization

/// Demo mode's batch print queue (Windows' demo PC queue): one of the made-up Mac's queues (`Demo.destinations`), its problem
/// read from its made-up state as a real queue's is (the shared front-desk printer is off, so a batch to it stops), Letter,
/// Legal and A4, two-sided except on the USB laser. Every page is drawn by the real engines, then counted; nothing is sent
/// anywhere and nothing prints.
public final class DemoBatchQueue: BatchQueue {
    public let destination: CupsDestination
    private let sentJobs = Mutex<[BatchPrintJob]>([])

    public init(_ destination: CupsDestination) { self.destination = destination }

    /// The made-up queue called `name` (its CUPS name or its shown name), or nil.
    public static func named(_ name: String) -> DemoBatchQueue? {
        Demo.destinations.first { $0.name == name || $0.options["printer-info"] == name }.map(DemoBatchQueue.init)
    }

    /// The made-up queues a batch can print to (not the PDF writer).
    public static var all: [DemoBatchQueue] { Demo.destinations.filter { $0.name != "PDFwriter" }.map(DemoBatchQueue.init) }

    public static let papers = [BatchPaper("na_letter_8.5x11in", "US Letter"), BatchPaper("na_legal_8.5x14in", "US Legal"),
                                BatchPaper("iso_a4_210x297mm", "A4")]

    public var name: String { destination.options["printer-info"] ?? destination.name }

    /// What it was "sent": the jobs, in order.
    public var sent: [BatchPrintJob] { sentJobs.withLock { $0 } }

    /// Answered after a moment, as cupsd answers: the window waits on it as on a real queue (a second click on Print lands
    /// meanwhile).
    public func read() async throws -> BatchQueueInfo? {
        try await Task.sleep(for: .milliseconds(20))
        return BatchQueueInfo(name, Self.papers, "na_letter_8.5x11in", canTwoSided: destination.name != "Demo_USB_laser")
    }

    public func problem() async throws -> String? {
        let o = destination.options
        return BatchQueueReading.problem(state: Int(o["printer-state"] ?? "3"), accepting: o["printer-is-accepting-jobs"].map { $0 == "true" },
                                         reasons: (o["printer-state-reasons"] ?? "none").split(separator: ",").map(String.init))
    }

    public func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?, onSpooling: @escaping @Sendable () -> Void,
                     _ stop: BatchStop) async throws -> BatchReceipt {
        if let paper = job.paper, !Self.papers.contains(where: { $0.key == paper }) {
            throw BatchSettingRefused("\(name) doesn't offer that paper.")
        }
        var drawn = 0
        for (i, page) in job.pages.enumerated() {
            try stop.check()
            progress?("Getting page \(i + 1) of \(job.pages.count) ready…")
            _ = try await document.render(page, stop)
            drawn += 1
        }
        try stop.check()
        onSpooling()
        sentJobs.withLock { $0.append(job) }
        return BatchReceipt(pages: drawn, sheets: BatchPrintSettings.sheets(drawn, job.copies, job.twoSided))
    }
}
