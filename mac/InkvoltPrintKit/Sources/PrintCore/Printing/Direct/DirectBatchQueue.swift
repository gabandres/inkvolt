import Foundation
import Synchronization

/// Draws one batch file's pages and sends them as one job straight to the printer, then follows the job until the printer says
/// it ended (or goes quiet). `onSending` is called at the point of no return, before the document goes out; from there `stop`
/// no longer stops the job: a batch never cancels a job the printer has. Throws `DirectPrintError` when the printer couldn't take
/// the request, refused the job or stopped it, or, before anything went, didn't answer (`DirectPrintError.notAnswering`).
public typealias DirectBatchSend = @Sendable (_ document: any BatchDocument, _ job: BatchPrintJob, _ request: DirectPrintRequest,
                                              _ progress: (@Sendable (String) -> Void)?, _ onSending: @escaping @Sendable () -> Void,
                                              _ stop: BatchStop) async throws -> Void

/// Batch print (roadmap 2.4) straight to a printer with no macOS queue, one set to print straight, or one whose queue macOS
/// can't use (2.1; Windows' `DirectBatchQueue`): a Print-Job per file through `DirectBatchSend` (the app draws the pages as
/// Print a PDF does). The papers and two-sided come from the printer's attributes; a printer that is stopped, reports an error
/// or isn't taking jobs stops the batch before the next file; a setting it can't keep, or pages this Mac couldn't draw, fail
/// that file with nothing sent. Each job is followed to its end before the next goes (a printer without a driver often takes
/// one job at a time), so once it's sent the batch waits for it however long it prints (`endsOnItsOwnOnceSpooling`): one the
/// printer stopped or that may have printed stops the batch, and the batch never sends it again by itself
/// (`BatchQueueError.mayHaveSent`). Stop takes effect up to the point of no return; past it the job finishes, as on a queue.
public final class DirectBatchQueue: BatchQueue {
    private let name: String
    private let ipp: IppClient
    private let caps: IppCapsCache
    private let sendJob: DirectBatchSend

    public init(_ name: String, ipp: IppClient, caps: IppCapsCache, send: @escaping DirectBatchSend) {
        (self.name, self.ipp, self.caps, self.sendJob) = (name, ipp, caps, send)
    }

    /// Throws `DirectPrintError` (not answering) when the printer didn't answer.
    public func read() async throws -> BatchQueueInfo? {
        let c: IppPrintCaps
        do {
            c = try await caps.get()
        } catch let error where DirectJob.noAnswer(error) {
            throw DirectPrintError.noAnswerBeforeSending()
        }
        guard c.canPrint else { return nil }
        return BatchQueueInfo(name, c.paperChoices().map { BatchPaper($0.paper.name, $0.label) }, c.defaultPaper?.name, canTwoSided: c.twoSided)
    }

    public func problem() async throws -> String? {
        do {
            return DirectJob.printerProblem(try await ipp.printerAttributes(DirectJob.stateAttributes))
        } catch let error where DirectJob.noAnswer(error) {
            return DirectPrintError.noAnswerBeforeSending().message
        }
    }

    public var noAnswer: String { DirectPrintError.noAnswerBeforeSending().message }

    /// Drawing takes each copy the printer doesn't make itself again: the time to the point of no return counts them.
    public func sendLimit(_ job: BatchPrintJob, _ options: BatchPrintOptions) -> Duration {
        options.sendTimeout + options.sendTimePerPage * (job.pages.count * max(1, job.copies))
    }

    /// Sent, the job is followed until the printer says it ended or has said nothing new for a while.
    public var endsOnItsOwnOnceSpooling: Bool { true }

    /// What a batch file asks of the printer: copies, two-sided and the paper by its PWG name (nil: the printer's default).
    public static func request(_ job: BatchPrintJob) -> DirectPrintRequest {
        var r = DirectPrintRequest(copies: job.copies, twoSided: job.twoSided)
        r.paperName = job.paper
        return r
    }

    public func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?,
                     onSpooling: @escaping @Sendable () -> Void, _ stop: BatchStop) async throws -> BatchReceipt {
        let request = Self.request(job)
        let printer: IppPrintCaps
        do {
            printer = try await caps.get()
        } catch let error where DirectJob.noAnswer(error) {
            throw BatchQueueError(DirectPrintError.noAnswerBeforeSending().message, mayHaveSent: false)
        }
        // Checked before anything's drawn: a setting the printer can't keep fails this file, and the next may be fine.
        if case .failure(let problem) = DirectPrintPlan.choose(printer, request) {
            caps.forget()
            throw BatchSettingRefused(problem.message)
        }

        let sending = Atomic(false)
        do {
            try await sendJob(document, job, request, progress, {
                sending.store(true, ordering: .releasing)
                onSpooling()
            }, stop)
        } catch let e as DirectPrintError {
            if sending.load(ordering: .acquiring) {
                // The batch's summary reads it as a sentence ("Stopped at file 2 of 3 (b.pdf): The printer stopped the job. 1 sent…").
                throw BatchQueueError(Self.sentence(e.message), mayHaveSent: e.mayHavePrinted)
            }
            if e.notAnswering { throw BatchQueueError(e.message, mayHaveSent: false) } // the printer went quiet: the rest wouldn't go either
            throw BatchFileError(e.message) // drawn wrong, or the printer changed since the check: nothing went
        } catch is CancellationError {
            // Past the point of no return a stop must not read as "not sent": the printer may have the job.
            if sending.load(ordering: .acquiring) { throw BatchQueueError(loc("You stopped the batch."), mayHaveSent: true) }
            throw CancellationError()
        } catch {
            if sending.load(ordering: .acquiring) { throw error }
            // This Mac's side (its disk, a page's drawing, the raster file): this file fails, the printer is fine.
            throw BatchFileError(Self.notDrawn)
        }
        return BatchReceipt(pages: job.pages.count, sheets: BatchPrintSettings.sheets(job.pages.count, job.copies, job.twoSided))
    }

    /// Pages this Mac couldn't draw (Windows' `Direct_NotDrawn`).
    public static var notDrawn: String { loc("Its pages couldn't be made ready on this Mac. Nothing was sent.") }

    private static func sentence(_ text: String) -> String {
        var why = text
        while why.last?.isWhitespace == true { why.removeLast() }
        return why.hasSuffix(".") ? why : why + "."
    }
}
