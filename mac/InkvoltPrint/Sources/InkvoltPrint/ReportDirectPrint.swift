import AppKit
import CoreGraphics
import Foundation
import PDFKit
import PrintCore
import PrintMac
import Synchronization

/// `--report --demo --direct-print`: the straight route (roadmap 2.1) through the app's own code, with no dialog: the
/// demo inkjet (no macOS queue, IPP with PWG and Apple raster) is routed straight, its caps read, a plan made for two copies
/// on both sides, the printer asked whether it can print, a made-up three-page PDF drawn (`DirectPrintPages`) and sent with
/// Print-Job, then followed with Get-Job-Attributes; then each kind of print and Batch print the same way, and job alerts'
/// read (`kindsCheck`). The made-up network keeps the job and completes it at once (as Windows' FixtureHandler); nothing prints.
extension Report {
    static func directPrintCheck(_ model: AppModel) async -> [String] {
        guard let p = model.printers.first(where: { $0.id == Demo.inkjetUuid }) else { return ["direct print: no demo inkjet"] }
        var lines = ["direct print: \(p.name), macOS queue \(p.queueName == nil ? "none" : "set up")"]
        var route: IppClient?
        for _ in 0..<60 {
            route = await DirectPrinting.route(p)
            if route != nil { break }
            try? await Task.sleep(for: .milliseconds(250))
        }
        guard let ipp = route else { return lines + ["  route: not straight (not connected, a queue, or no raster format)"] }
        lines.append("  route: straight to \(ipp.printerUri)")
        guard let answer = try? await ipp.printerAttributes(IppPrintCaps.requested) else { return lines + ["  caps: no answer"] }
        let caps = IppPrintCaps.from(answer)
        lines.append("  caps: \(caps.formats.map { "\($0)" }.joined(separator: ", ")); \(caps.papers.count) papers, default \(caps.defaultPaper?.name ?? "none"); "
                     + "two-sided \(caps.twoSided), color \(caps.color), copies up to \(caps.maxCopies)")
        let plan: DirectPrintPlan
        switch DirectPrintPlan.choose(caps, DirectPrintRequest(copies: 2, twoSided: true)) {
        case .success(let chosen): plan = chosen
        case .failure(let problem): return lines + ["  plan: \(problem.message)"]
        }
        lines.append("  plan: \(plan.documentFormat) at \(plan.dpi) dpi (drawn at \(plan.renderDpi)), \(plan.color), \(plan.paper.name), "
                     + "copies \(plan.copies) sent \(plan.repeatCount) time(s), back \(plan.back)")
        lines.append("  printer now: \(await DirectPrinting.printerProblem(ipp) ?? "can print")")
        guard let pdf = samplePdf(pages: 3) else { return lines + ["  sample PDF: not made"] }
        let clock = ContinuousClock()
        let started = clock.now
        let file = DirectJobFile.temporaryUrl()
        defer { try? FileManager.default.removeItem(at: file) }
        let head = DirectJob.printJobRequest(ipp.printerUri, user: DirectPrinting.user, jobName: "Inkvolt direct print check", plan)
        let upload: DirectJobUpload
        do {
            upload = try await Task.detached { () throws -> DirectJobUpload in
                guard let copy = PDFDocument(data: pdf) else { throw DirectPrintPages.NotDrawn() }
                let job = try DirectJobFile(file, request: head)
                try DirectPrintPages.write(copy, plan: plan) { bytes in try job.append(bytes) }
                return try job.finish()
            }.value
        } catch {
            return lines + ["  drawn: failed (\(error))"]
        }
        lines.append("  drawn: 3 pages into the job file, \(upload.bytes) bytes with the request in \(clock.now - started)")
        let impressions = plan.impressions(3)
        do {
            let (id, state) = try await DirectJob.send(ipp, upload)
            lines.append("  Print-Job: job \(id), \(state.map { DirectJob.describe($0, pages: impressions) } ?? "no state")")
            let last = await DirectJob.watch(ipp, user: DirectPrinting.user, jobId: id, every: .milliseconds(200), quiet: .seconds(10))
            lines.append("  followed: \((last ?? state).map { DirectJob.describe($0, pages: impressions) } ?? "no answer")")
        } catch let e as DirectPrintError {
            lines.append("  Print-Job: \(e.message) (may have printed: \(e.mayHavePrinted))")
        } catch {
            lines.append("  Print-Job: \(error)")
        }
        return lines + (await cancelCheck(model, ipp: ipp, plan: plan, pdf: pdf)) + (await kindsCheck(model, p, ipp: ipp, pdf: pdf))
    }

    /// Every kind of print straight to the demo inkjet through the app's own route and job flow (roadmap 2.1): the Print tab's
    /// note and choice, Print a PDF and Copy (pages fitted inside the margins), a booklet laid out on the printer's paper
    /// (`SheetPrintView`, both sides), Print Photos' 4 × 6 sheet borderless, Batch print through the printer's routed queue
    /// (`RoutedBatchQueue` to `DirectBatchQueue`), and job alerts' read of the printer's own list (`RoutedJobQueue`).
    private static func kindsCheck(_ model: AppModel, _ p: PrinterModel, ipp: IppClient, pdf: Data) async -> [String] {
        var lines = ["  print tab: note \(p.routeNote) (\(p.routeNote.text ?? "none")), choice offered \(p.canChooseDirect)"]
        guard let caps = try? await p.directCaps.cache(for: ipp).get() else { return lines + ["  kinds: the printer's attributes not read"] }
        func send(_ kind: String, _ data: Data, _ layout: DirectPrintPages.Layout, _ request: DirectPrintRequest) async -> String {
            let url = DirectJobFile.temporaryUrl().deletingPathExtension().appendingPathExtension("pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            guard (try? data.write(to: url)) != nil else { return "  \(kind): not written" }
            guard case .success(let plan) = DirectPrintPlan.choose(caps, request) else { return "  \(kind): the printer can't keep \(request)" }
            let said = await DirectPrinting.run(url, password: nil, name: "Inkvolt \(kind) check", plan: plan, ipp: ipp, layout: layout, say: { _ in })
            return "  \(kind): \(plan.paper.name)\(plan.paper.borderless ? " borderless" : ""), \(plan.twoSided ? "both sides" : "one side"), \(said)"
        }
        lines.append(await send("print a PDF", pdf, .fitted(.fitToPaper), DirectPrintRequest()))
        lines.append(await send("copy", pdf, .fitted(.fitToPaper), DirectPrintRequest(copies: 2)))
        // A booklet laid out on the plan's paper, as DirectPrinting.printSheets does.
        if case .success(let plan) = DirectPrintPlan.choose(caps, DirectPrintRequest(copies: 1, twoSided: true)),
           let document = PDFDocument(data: Data(BatchPrintSamples.pdf(8, "Sample"))) {
            let url = DirectJobFile.temporaryUrl().deletingPathExtension().appendingPathExtension("pdf")
            defer { try? FileManager.default.removeItem(at: url) }
            let paper = NSSize(width: plan.paper.widthInches * 72, height: plan.paper.heightInches * 72)
            let view = Printing.printSheets(document, choice: SheetChoice(.booklet), name: "booklet", on: nil, app: nil, save: url, paper: paper)
            if let sheets = try? Data(contentsOf: url) {
                lines.append(await send("booklet (\(view?.plan.sheetCount ?? 0) sides)", sheets, .sheet, DirectPrintRequest(copies: 1, twoSided: true)))
            } else {
                lines.append("  booklet: not laid out")
            }
        }
        var photo = DirectPrintRequest()
        (photo.paperInches, photo.borderless) = ((4, 6), true)
        if let sheet = samplePdf(pages: 1, width: 288, height: 432) { lines.append(await send("photos 4x6", sheet, .sheet, photo)) }

        // Batch print: two files through the printer's own queue, routed straight.
        if let queue = p.batchQueue() {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-direct-batch-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let documents = MacBatchDocuments()
            var batch: [BatchPrintLine] = []
            let info = try? await queue.read()
            for (name, pages) in [("a.pdf", 2), ("b.pdf", 3)] {
                let path = folder.appendingPathComponent(name).path
                FileManager.default.createFile(atPath: path, contents: Data(BatchPrintSamples.pdf(pages, name)))
                if let measure = try? await BatchMeasurer.measure(path, offered: nil, documents, ask: nil) {
                    batch.append(BatchPrintLine(path, BatchPrintSettings(), measure, info ?? nil))
                }
            }
            let summary = await Task.detached { await BatchPrintRunner.run(batch, queue, documents) }.value
            lines.append("  batch: \(info.map { _ in "papers read" } ?? "no papers"), \(summary.items.map { "\($0.name) \($0.state)" }.joined(separator: ", ")); \(summary.text)")
        } else {
            lines.append("  batch: no queue")
        }
        // Job alerts: the printer's own list while its jobs go straight.
        if let jobs = p.jobQueue({ nil }) {
            do {
                let state = try await jobs.read()
                lines.append("  job alerts read: the printer's list, \(state?.jobs.count ?? -1) job(s)")
            } catch {
                lines.append("  job alerts read: failed (\(error))")
            }
        }
        return lines
    }

    /// The app's own job flow (`DirectPrinting.run`, the window's) cancelled the moment the printer has given the job its
    /// id: the sending isn't cut, and the made-up printer must see Cancel-Job for that id.
    private static func cancelCheck(_ model: AppModel, ipp: IppClient, plan: DirectPrintPlan, pdf: Data) async -> [String] {
        let url = DirectJobFile.temporaryUrl().deletingPathExtension().appendingPathExtension("pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? pdf.write(to: url)) != nil else { return ["  cancel: sample PDF not written"] }
        let seen = SeenOperations(model.recordingTransport())
        let watched = IppClient(DeviceHttp(host: Demo.inkjetHost, transport: seen), endpoint: ipp.endpoint)
        let said = await Task { @MainActor () -> String in
            await DirectPrinting.run(url, password: nil, name: "Inkvolt direct print cancel check", plan: plan, ipp: watched, sent: { _ in
                withUnsafeCurrentTask { task in task?.cancel() } // the person's Cancel, right after the printer gave the job its id
            }, say: { _ in })
        }.value
        return ["  cancel once the job has its id: \(said)", "  the printer saw: \(seen.operations.joined(separator: ", "))"]
    }

    /// A made-up PDF (Letter unless given): each page a heading bar and a box, so its raster has runs and edges.
    private static func samplePdf(pages: Int, width: CGFloat = 612, height: CGFloat = 792) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for i in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: width * 0.12, y: height * 0.88, width: width * 0.76, height: height * 0.05))
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2)
            context.stroke(CGRect(x: width * 0.12 + CGFloat(i) * 40, y: height * 0.38, width: width / 3, height: width / 3))
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}

/// The IPP operations a made-up printer was sent, in order, a job's id with each that names one (the cancel check's).
private final class SeenOperations: HttpTransport {
    private let inner: any HttpTransport
    private let seen = Mutex<[String]>([])

    init(_ inner: any HttpTransport) { self.inner = inner }

    var operations: [String] { seen.withLock { $0 } }

    func send(_ request: HttpRequest) async throws -> HttpResponse {
        let body = request.bodyBytes()
        if let op = try? IppCodec.readRequestHeader(body).operation {
            let name: String
            switch op {
            case IppCodec.printJob: name = "Print-Job"
            case IppCodec.cancelJob: name = "Cancel-Job"
            case IppCodec.getJobAttributes: name = "Get-Job-Attributes"
            case IppCodec.getPrinterAttributes: name = "Get-Printer-Attributes"
            default: name = String(format: "0x%04X", op)
            }
            let operation = try? IppCodec.decodeGroups(body).groups.first
            let job: Int? = operation.flatMap { IppResponse(statusCode: 0, attributes: $0.attributes).int("job-id") }
            let said: String = job.map { "\(name) \($0)" } ?? name
            seen.withLock { $0.append(said) }
        }
        return try await inner.send(request)
    }
}
