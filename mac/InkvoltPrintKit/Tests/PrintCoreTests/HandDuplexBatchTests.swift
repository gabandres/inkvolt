import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Ported from HandDuplexBatchTests.cs: batch print on both sides by hand (roadmap 4.2): on a printer that can't print both
/// sides, each two-sided file goes as its fronts, the reload prompt (`BatchPrintOptions.turnStack`), then its backs (page 0: a
/// blank side), and stopping at the prompt stops the batch there. Adapted: a stop is a `BatchStop`, .NET's
/// OperationCanceledException a `CancellationError`.
struct HandDuplexBatchTests {
    private static let oneSided = BatchQueueInfo("Test queue", FakeQueue.papers, "na_letter_8.5x11in", canTwoSided: false)

    /// Records each job's pages; a page 0 is drawn as nothing (a blank side), as the app's queues draw it.
    private final class Queue: BatchQueue, @unchecked Sendable {
        let sentJobs = Mutex<[BatchPrintJob]>([])
        /// Thrown when the n-th job (0: the fronts, 1: the backs) is sent, after it's handed over.
        var failOn: (@Sendable (Int) -> (any Error)?)?
        /// The sheets the queue says a job took, in place of its pages.
        var sheetsTaken: (@Sendable (BatchPrintJob) -> Int)?

        var sent: [BatchPrintJob] { sentJobs.withLock { $0 } }

        func read() async throws -> BatchQueueInfo? { HandDuplexBatchTests.oneSided }
        func problem() async throws -> String? { nil }

        func send(_ document: any BatchDocument, _ job: BatchPrintJob, progress: (@Sendable (String) -> Void)?, onSpooling: @escaping @Sendable () -> Void,
                  _ stop: BatchStop) async throws -> BatchReceipt {
            for page in job.pages where page > 0 { _ = try await document.render(page, stop) }
            onSpooling()
            if let failure = failOn?(sent.count) { throw failure }
            sentJobs.withLock { $0.append(job) }
            return BatchReceipt(pages: job.pages.count, sheets: sheetsTaken?(job) ?? BatchPrintSettings.sheets(job.pages.count, job.copies, job.twoSided))
        }
    }

    private static func line(_ folder: BatchFolder, _ name: String, _ pages: Int, copies: Int = 1, byHand: Bool = true) async throws -> BatchPrintLine {
        let path = folder.file(name, "pages=\(pages)")
        let measure = try await BatchMeasurer.measure(path, offered: nil, FakeDocuments(), ask: nil)
        return BatchPrintLine(path, BatchPrintSettings(copies: copies, twoSided: true), measure, oneSided, byHand: byHand)
    }

    private static func options(_ turnStack: @escaping @Sendable (String, HandDuplexPlan, BatchStop) async -> OutputFace?) -> BatchPrintOptions {
        var options = BatchPrintOptions()
        options.turnStack = turnStack
        return options
    }

    @Test func frontsThenThePromptThenTheBacksLastSheetFirst() async throws {
        let folder = BatchFolder()
        let queue = Queue()
        let asked = Mutex<[(String, Int)]>([])
        let options = Self.options { name, plan, _ in
            asked.withLock { $0.append((name, plan.sheets)) }
            #expect(queue.sent.count == 1) // the fronts went first
            return .down
        }
        let line = try await Self.line(folder, "report.pdf", 5)
        #expect(line.problem == nil)
        #expect(line.byHand)
        #expect(line.sheets == 3)
        let summary = await BatchPrintRunner.run([line], queue, FakeDocuments(), options: options)
        #expect(asked.withLock { $0.map(\.0) } == ["report.pdf"] && asked.withLock { $0.map(\.1) } == [3])
        #expect(queue.sent[0].pages == [1, 3, 5])
        #expect(queue.sent[1].pages == [4, 2]) // page 5's sheet set aside
        #expect(queue.sent.allSatisfy { !$0.twoSided })
        #expect(queue.sent.allSatisfy { $0.copies == 1 })
        #expect(summary.items.count == 1)
        #expect(summary.items[0].state == .sent)
        #expect(summary.items[0].sheetsSent == 3)
    }

    // Mac only: a laid-out job's file (a booklet's or pages per sheet's sides) names its set-aside sheet by the document's page.
    @Test func aLaidOutFileNamesTheSetAsideSheetByTheDocumentsPage() async throws {
        let folder = BatchFolder()
        let lastPages = Mutex<[Int?]>([])
        let options = Self.options { _, plan, _ in
            lastPages.withLock { $0.append(plan.reload(.down).lastPage) }
            return .down
        }
        let plain = try await Self.line(folder, "sides.pdf", 3)
        let named = BatchPrintLine(plain.path, plain.settings, plain.measure, Self.oneSided, byHand: true, pageNumbers: [1, 5, 9])
        let queue = Queue()
        _ = await BatchPrintRunner.run([plain, named], queue, FakeDocuments(), options: options)
        #expect(lastPages.withLock { $0 } == [3, 9])
        #expect(queue.sent.map(\.pages) == [[1, 3], [2], [1, 3], [2]]) // the same sides either way
    }

    // Mac only: Copy by hand (Windows' PrintCopyByHandAsync) sends its sides file once with the order CopyLayout.order gives:
    // uncollated copies repeat each sheet, an odd last side's back is blank and its sheet set aside, as Windows' plan says.
    @Test func aCopyLaidOutByTheAppGoesByHandInItsOwnOrder() async throws {
        let folder = BatchFolder()
        let queue = Queue()
        let plain = try await Self.line(folder, "Copy.pdf", 3)
        let (order, times) = CopyLayout.order(3, 2, collate: false, twoSided: true) // 0 1 0 1 2 -1 2 -1
        // 2 pages per sheet: the sides show pages 1, 3 and 5.
        let line = BatchPrintLine(plain.path, BatchPrintSettings(copies: times, twoSided: true), plain.measure, Self.oneSided, byHand: true,
                                  pageNumbers: [1, 3, 5], order: order)
        #expect(line.sheets == 4)
        let setAside = Mutex<Int?>(nil)
        let summary = await BatchPrintRunner.run([line], queue, FakeDocuments(), options: Self.options { _, plan, _ in
            setAside.withLock { $0 = plan.reload(.down).lastPage }
            return .down
        })
        #expect(queue.sent[0].pages == [1, 1, 3, 3]) // fronts: sheet by sheet, each twice
        #expect(queue.sent[1].pages == [0, 2, 2]) // backs last sheet first; the set-aside sheet's back isn't sent
        #expect(setAside.withLock { $0 } == 5) // named by the page on its side
        #expect(summary.items[0].state == .sent)
        let outside = BatchPrintLine(plain.path, BatchPrintSettings(copies: 1, twoSided: true), plain.measure, Self.oneSided, byHand: true, order: [0, 7, -3])
        #expect(outside.order == [0, -1, -1]) // an index outside the pages is a blank side

        let collated = CopyLayout.order(3, 2, collate: true, twoSided: true) // made here: 0 1 2 -1 0 1 2 -1
        let together = BatchPrintLine(plain.path, BatchPrintSettings(copies: collated.ticketCopies, twoSided: true), plain.measure, Self.oneSided,
                                      byHand: true, order: collated.sides)
        #expect(together.sheets == (try CopyLayout.sheets(3, 1, 2, twoSided: true)))
        let noOrder = BatchPrintLine(plain.path, BatchPrintSettings(copies: 2, twoSided: true), plain.measure, Self.oneSided, byHand: false, order: [0, 0])
        #expect(noOrder.order == nil) // not by hand: the queue prints both sides, the file as it is
    }

    @Test func copiesOfAnOddFileSendABlankSideBetweenThemFaceUpInOrder() async throws {
        let folder = BatchFolder()
        let queue = Queue()
        _ = await BatchPrintRunner.run([try await Self.line(folder, "a.pdf", 3, copies: 2)], queue, FakeDocuments(), options: Self.options { _, _, _ in .up })
        #expect(queue.sent[0].pages == [1, 3, 1, 3])
        #expect(queue.sent[1].pages == [2, 0, 2])
    }

    @Test func stoppingAtThePromptStopsTheBatchAfterTheFronts() async throws {
        let folder = BatchFolder()
        let queue = Queue()
        let summary = await BatchPrintRunner.run([try await Self.line(folder, "a.pdf", 4), try await Self.line(folder, "b.pdf", 2)], queue, FakeDocuments(),
                                                 options: Self.options { _, _, _ in nil })
        #expect(queue.sent.count == 1) // a.pdf's fronts only
        #expect(summary.items[0].state == .stopped)
        #expect(summary.items[0].message == loc("Fronts printed; the backs weren't, as you stopped."))
        #expect(summary.items[1].state == .stopped)
        #expect(summary.stoppedAt != nil)
    }

    @Test func theBacksFailingSaysTheFrontsPrintedAndStopsWithoutSendingAgain() async throws {
        struct Driver: Error, CustomStringConvertible { var description: String { "driver" } }
        let folder = BatchFolder()
        let failures: [any Error] = [BatchQueueError("The printer stopped.", mayHaveSent: true), Driver(), CancellationError()]
        for failure in failures {
            let queue = Queue()
            queue.failOn = { $0 == 1 ? failure : nil }
            let summary = await BatchPrintRunner.run([try await Self.line(folder, "a.pdf", 5), try await Self.line(folder, "b.pdf", 2)], queue, FakeDocuments(),
                                                     options: Self.options { _, _, _ in .down })
            let a = summary.items[0]
            #expect(a.sheetsSent == 3) // the fronts are on paper
            #expect(a.mayHaveSent) // never sent again by itself (reprinting would print the fronts twice)
            #expect([BatchPrintState.failed, .stopped].contains(a.state))
            #expect(summary.items[1].state == .stopped)
            #expect(summary.stoppedAt != nil)
            #expect(!a.message.contains("driver")) // no error's own text
        }
    }

    @Test func stoppedBeforeThePromptItIsntShown() async throws {
        let folder = BatchFolder()
        let stop = BatchStop()
        let asked = Atomic(0)
        let queue = Queue()
        queue.sheetsTaken = { job in stop.stop(); return job.pages.count } // Stop pressed while the fronts went
        let summary = await BatchPrintRunner.run([try await Self.line(folder, "a.pdf", 4)], queue, FakeDocuments(),
                                                 options: Self.options { _, _, _ in asked.add(1, ordering: .relaxed); return .down }, stop)
        #expect(asked.load(ordering: .relaxed) == 0)
        #expect(queue.sent.count == 1)
        #expect(summary.items[0].message == loc("Fronts printed; the backs weren't, as you stopped."))
        #expect(summary.items[0].sheetsSent == 2)
    }

    @Test func aPassTakingMoreSheetsThanEstimatedStopsTheBatch() async throws {
        let folder = BatchFolder()
        let asked = Atomic(0)
        let options = Self.options { _, _, _ in asked.add(1, ordering: .relaxed); return .down }
        let queue = Queue()
        queue.sheetsTaken = { _ in 99 }
        var summary = await BatchPrintRunner.run([try await Self.line(folder, "a.pdf", 4)], queue, FakeDocuments(), options: options)
        #expect(asked.load(ordering: .relaxed) == 0) // stopped after the fronts
        #expect(summary.stopReason == loc("A job came to more sheets than its estimate, so nothing more is sent."))
        #expect(summary.items[0].sheetsSent == 99)

        let backsOver = Queue()
        backsOver.sheetsTaken = { $0.pages == [4, 2] ? 99 : $0.pages.count }
        summary = await BatchPrintRunner.run([try await Self.line(folder, "b.pdf", 4)], backsOver, FakeDocuments(), options: options)
        #expect(summary.stopReason == loc("A job came to more sheets than its estimate, so nothing more is sent."))
    }

    @Test func onePageNeedsNoPromptAndNobodyToAskRefusesAsBefore() async throws {
        let folder = BatchFolder()
        let queue = Queue()
        let asked = Atomic(0)
        _ = await BatchPrintRunner.run([try await Self.line(folder, "one.pdf", 1)], queue, FakeDocuments(),
                                       options: Self.options { _, _, _ in asked.add(1, ordering: .relaxed); return .down })
        #expect(asked.load(ordering: .relaxed) == 0)
        #expect(queue.sent.map(\.pages) == [[1]])

        // The command line and a watched folder have nobody to put the stack back: two-sided on a one-sided printer is refused.
        #expect(try await Self.line(folder, "cli.pdf", 4, byHand: false).problem == loc("This printer doesn't print two-sided."))
        let noAsk = Queue()
        let summary = await BatchPrintRunner.run([try await Self.line(folder, "x.pdf", 4)], noAsk, FakeDocuments())
        #expect(noAsk.sent.isEmpty)
        #expect(summary.items[0].state == .skipped)
    }
}
