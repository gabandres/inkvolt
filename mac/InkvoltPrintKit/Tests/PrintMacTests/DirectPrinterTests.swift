import Foundation
import PrintCore
import Synchronization
import Testing
@testable import PrintMac

/// Roadmap 2.1's other prints end to end without a printer (Mac only; IppEvePrinterTests' pattern): CUPS's `ippeveprinter`
/// takes, through `DirectPrinter` (the job every kind of print goes through), a PDF fitted inside the margins (Print a PDF,
/// Copy, a preset's print step), one at its own size (the clipboard, a separator sheet) and a sheet laid out for the paper
/// (Print Photos, an ID card, Print a PDF's layouts), each followed to the end; Batch print's files go one job each through
/// `DirectBatchQueue` with `DirectBatchJobs`, followed before the next; and job alerts' `DirectJobWatch` reads its job lists.
@Suite(.serialized)
struct DirectPrinterTests {
    static let available = FileManager.default.isExecutableFile(atPath: IppEvePrinterTests.ippeveprinter)

    static func sample(_ pages: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-direct-\(UUID().uuidString).pdf")
        try Data(BatchPrintSamples.pdf(pages, "Sample")).write(to: url)
        return url
    }

    /// The printer's caps, PWG raster only (one format is enough here; IppEvePrinterTests sends each).
    static func plan(_ printer: IppEvePrinterTests.TestPrinter, _ request: DirectPrintRequest = DirectPrintRequest()) async throws -> DirectPrintPlan {
        var r = request
        r.format = .pwgRaster
        return try DirectPrintPlan.choose(IppPrintCaps.from(try await printer.ready()), r).get()
    }

    @Test(.enabled(if: DirectPrinterTests.available))
    func eachLayoutGoesAsOneJobAndIsFollowedToItsEnd() async throws {
        let printer = try IppEvePrinterTests.TestPrinter()
        defer { printer.stop() }
        let plan = try await Self.plan(printer)
        let pdf = try Self.sample(1)
        defer { try? FileManager.default.removeItem(at: pdf) }
        for layout: DirectPrintPages.Layout in [.fitted(.fitToPaper), .fitted(.actualSize), .sheet] {
            let sending = Flag(), sentId = Flag()
            let outcome = try await DirectPrinter.print(printer.ipp, user: "inkvolt", jobName: "layout \(layout)", plan: plan, pdf: pdf, layout: layout,
                                                        onSending: { sending.set() }, onSent: { if $0 > 0 { sentId.set() } },
                                                        every: .milliseconds(100), quiet: .seconds(30))
            #expect(sending.isSet && sentId.isSet)
            #expect(outcome.printed, "\(layout): \(outcome.words)")
            #expect(outcome.impressions == 1)
            let kept = try printer.kept(outcome.jobId)
            #expect(Array(kept.prefix(4)) == Array("RaS2".utf8), "\(layout)") // PWG raster's sync word
        }
    }

    @Test(.enabled(if: DirectPrinterTests.available))
    func aStopBeforeSendingSendsNothing() async throws {
        let printer = try IppEvePrinterTests.TestPrinter()
        defer { printer.stop() }
        let plan = try await Self.plan(printer)
        let pdf = try Self.sample(2)
        defer { try? FileManager.default.removeItem(at: pdf) }
        let stop = BatchStop()
        stop.stop()
        let sending = Flag()
        await #expect(throws: CancellationError.self) {
            try await DirectPrinter.print(printer.ipp, user: "inkvolt", jobName: "stopped", plan: plan, pdf: pdf, layout: .sheet, stop: stop,
                                          onSending: { sending.set() })
        }
        #expect(!sending.isSet)
        #expect(try FileManager.default.contentsOfDirectory(atPath: printer.folder.path).filter { !$0.hasPrefix(".") }.isEmpty)
    }

    @Test(.enabled(if: DirectPrinterTests.available))
    func aBatchGoesAJobPerFileStraightToThePrinterAndItsJobListsRead() async throws {
        let printer = try IppEvePrinterTests.TestPrinter()
        defer { printer.stop() }
        _ = try await printer.ready()
        let ipp = printer.ipp
        let caps = IppCapsCache({ IppPrintCaps.from(try await ipp.printerAttributes(IppPrintCaps.requested)) })
        let queue = DirectBatchQueue("Inkvolt Raster Check", ipp: ipp, caps: caps, send: DirectBatchJobs.send(ipp, caps: caps, user: "inkvolt"))
        let info = try #require(try await queue.read())
        #expect(!info.papers.isEmpty)
        #expect(try await queue.problem() == nil)

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-direct-batch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let documents = MacBatchDocuments()
        var lines: [BatchPrintLine] = []
        for name in ["a.pdf", "b.pdf"] {
            let path = folder.appendingPathComponent(name).path
            FileManager.default.createFile(atPath: path, contents: Data(BatchPrintSamples.pdf(1, name)))
            lines.append(BatchPrintLine(path, BatchPrintSettings(), try await BatchMeasurer.measure(path, offered: nil, documents, ask: nil), info))
        }
        let summary = await BatchPrintRunner.run(lines, queue, documents)
        #expect(summary.items.map(\.state) == [.sent, .sent], "\(summary.text)")
        let kept = try FileManager.default.contentsOfDirectory(atPath: printer.folder.path).filter { !$0.hasPrefix(".") }
        #expect(kept.count == 2, "\(kept)")

        // Job alerts' read: both lists answered; the jobs printed, so none is waiting or given up on.
        let state = try await DirectJobWatch().read(ipp, user: "inkvolt")
        #expect(state.jobs.isEmpty)
        #expect(!state.othersMayPrint)
    }

    /// Set once from any thread.
    final class Flag: Sendable {
        private let value = Mutex(false)
        func set() { value.withLock { $0 = true } }
        var isSet: Bool { value.withLock { $0 } }
    }
}
