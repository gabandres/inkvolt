import Foundation
import PDFKit
import PrintCore

/// Driverless printing (roadmap 2.1, Windows' `DirectPrinter.PrintAsync`): the same pages Print a PDF, Copy, Print photos, a
/// scan preset, a batch file or a layout make for a macOS queue, as a PDF file, drawn at the plan's resolution on the printer's
/// own paper (`DirectPrintPages`) into a job file, sent with Print-Job, then followed with Get-Job-Attributes until the
/// printer says it's done. What to send and how is decided in PrintCore (`DirectPrintPlan`, `DirectJob`); this draws and
/// hands over. Every print kind goes through `print`, so they stop, fail and say so alike.
public enum DirectPrinter {
    public static let watchEvery: Duration = .seconds(1), watchQuiet: Duration = .seconds(120)

    /// How a job ended once the printer had it: its id (0: none given), its last state as followed, and its count of sides
    /// (Windows' PagesPerCopy × Repeat × Copies) for the words. `tooLong`: the watch gave up after 2 hours.
    public struct Outcome: Sendable {
        public var jobId: Int
        public var last: DirectJobState?
        public var impressions: Int
        public var tooLong: String?

        /// The printer said it printed it.
        public var printed: Bool { last?.state == DirectJobState.completed }

        /// The end in words: printed, waiting, its page count.
        public var words: String {
            tooLong ?? last.map { DirectJob.describe($0, pages: impressions) } ?? loc("Waiting its turn at the printer")
        }
    }

    /// The plan for `request` from the printer's attributes (read through `caps`, kept a while), or why not; nothing is sent.
    /// Throws `DirectPrintError`: not answering, or a setting the printer can't keep (the cache is read again next time).
    public static func plan(_ caps: IppCapsCache, _ request: DirectPrintRequest) async throws -> DirectPrintPlan {
        let printer: IppPrintCaps
        do {
            printer = try await caps.get()
        } catch let error where DirectJob.noAnswer(error) {
            throw DirectPrintError.noAnswerBeforeSending() // only the printer's silence: a disk or drawing error below is its own
        }
        switch DirectPrintPlan.choose(printer, request) {
        case .success(let plan): return plan
        case .failure(let problem):
            caps.forget() // the printer may have changed (a tray, a setting): read it again next time
            throw DirectPrintError(problem.message, mayHavePrinted: false)
        }
    }

    /// Draws `pdf` (`pages`: indices, nil every one) as `layout` says, sends it as `jobName` and follows it. `onSending` marks the
    /// point of no return (the document starts going out); `onSent` the printer has it (its id). Before the point of no return
    /// `stop` (or the task's cancellation) stops it with nothing sent (`CancellationError`); after it, `stop` cancels the job at
    /// the printer (Cancel-Job: `CancellationError` when it took it, else a `DirectPrintError` saying it may still print), unless
    /// `finishOnceSent` (a batch): then the job is followed to its end whatever `stop` says. Throws `DirectPrintError` when the
    /// printer refused or stopped the job (`mayHavePrinted` says whether it may have it), `DirectPrintPages.NotDrawn` or a file
    /// error when this Mac couldn't make the pages ready (nothing sent).
    public static func print(_ ipp: IppClient, user: String, jobName: String, plan: DirectPrintPlan, pdf: URL, password: String? = nil, pages: [Int]? = nil,
                             layout: DirectPrintPages.Layout, stop: BatchStop = BatchStop(), finishOnceSent: Bool = false,
                             progress: (@Sendable (String) -> Void)? = nil, onSending: (@Sendable () -> Void)? = nil,
                             onSent: (@Sendable (Int) -> Void)? = nil, every: Duration = watchEvery, quiet: Duration = watchQuiet) async throws -> Outcome {
        let file = DirectJobFile.temporaryUrl()
        defer { try? FileManager.default.removeItem(at: file) }
        let head = DirectJob.printJobRequest(ipp.printerUri, user: user, jobName: jobName, plan)
        progress?(loc("Making the pages ready…"))
        let drawing = Task.detached(priority: .userInitiated) { () throws -> (upload: DirectJobUpload, pages: Int) in
            try draw(pdf, password: password, pages: pages, plan: plan, layout: layout, into: file, head: head, stop: stop)
        }
        let made = try await withTaskCancellationHandler { try await drawing.value } onCancel: {
            drawing.cancel()
            stop.stop()
        }
        if Task.isCancelled || stop.isStopped { throw CancellationError() }

        onSending?()
        progress?(loc("Sending the pages to the printer…"))
        let (jobId, answered) = try await DirectJob.send(ipp, made.upload)
        onSent?(jobId)
        let impressions = plan.impressions(made.pages)
        guard jobId > 0 else { return Outcome(jobId: 0, last: answered, impressions: impressions) }

        if let answered { progress?(DirectJob.describe(answered, pages: impressions)) }
        let follow = !finishOnceSent
        let clock = ContinuousClock()
        let started = clock.now
        let watched = await DirectJob.watch(ipp, user: user, jobId: jobId, every: every, quiet: quiet,
                                            stopped: { follow && (stop.isStopped || Task.isCancelled) },
                                            progress: { progress?(DirectJob.describe($0, pages: impressions)) })
        let last = watched ?? answered
        if follow && (stop.isStopped || Task.isCancelled) { try await DirectJob.stop(ipp, user: user, jobId: jobId) } // says whether the printer took it
        var outcome = Outcome(jobId: jobId, last: last, impressions: impressions)
        outcome.tooLong = DirectJob.followedTooLong(last, after: clock.now - started)
        if let tooLong = outcome.tooLong { progress?(tooLong) }
        if let last, last.state == DirectJobState.aborted || last.state == DirectJobState.canceled {
            throw DirectPrintError(DirectJob.describe(last, pages: impressions), mayHavePrinted: true)
        }
        return outcome
    }

    /// Off the main thread: the PDF opened from its file, its pages drawn into the job file after `head` (Print-Job's
    /// attributes). Returns the file to upload and the pages drawn of one copy.
    static func draw(_ url: URL, password: String?, pages: [Int]?, plan: DirectPrintPlan, layout: DirectPrintPages.Layout, into file: URL, head: [UInt8],
                     stop: BatchStop) throws -> (upload: DirectJobUpload, pages: Int) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: url) else { throw DirectPrintPages.NotDrawn() }
        if document.isLocked, !(password.map { document.unlock(withPassword: $0) } ?? false) { throw DirectPrintPages.NotDrawn() }
        let job = try DirectJobFile(file, request: head)
        try DirectPrintPages.write(document, pages: pages, plan: plan, layout: layout, stop: stop) { bytes in try job.append(bytes) }
        return (try job.finish(), pages?.count ?? document.pageCount)
    }
}

/// Batch print's files straight to the printer (Windows' `DirectBatchJobs` in BatchPrinting.cs): each file's pages drawn into
/// a PDF as a macOS queue's would be (`CupsBatchQueue.drawPages`), then printed through `DirectPrinter`, followed to the end
/// (`DirectBatchQueue` waits for it).
public enum DirectBatchJobs {
    public static func send(_ ipp: IppClient, caps: IppCapsCache, user: String) -> DirectBatchSend {
        { document, job, request, progress, onSending, stop in
            let plan = try await DirectPrinter.plan(caps, request)
            let pdf = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-direct-\(UUID().uuidString).pdf")
            defer { try? FileManager.default.removeItem(at: pdf) }
            _ = try await CupsBatchQueue.drawPages(document, job, into: pdf, progress: progress, stop)
            try stop.check()
            do {
                _ = try await DirectPrinter.print(ipp, user: user, jobName: job.name, plan: plan, pdf: pdf, layout: .fitted(document.sizing), stop: stop,
                                                  finishOnceSent: true, progress: progress, onSending: onSending)
            } catch let e as DirectPrintError where !e.mayHavePrinted && e.ippStatus != nil {
                caps.forget() // refused for a setting or its format: read the printer again for the next file
                throw e
            }
        }
    }
}
