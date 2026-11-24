import CoreGraphics
import Foundation
import PDFKit
import PrintCore
import PrintMac
import Synchronization

/// `--report --demo --direct-print`: Print a PDF's straight route (roadmap 2.1) through the app's own code, with no dialog: the
/// demo inkjet (no macOS queue, IPP with PWG and Apple raster) is routed straight, its caps read, a plan made for two copies
/// on both sides, the printer asked whether it can print, a made-up three-page PDF drawn (`DirectPrintPages`) and sent with
/// Print-Job, then followed with Get-Job-Attributes. The made-up network keeps the job and completes it at once (as Windows'
/// FixtureHandler); nothing prints.
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
        return lines + (await cancelCheck(model, ipp: ipp, plan: plan, pdf: pdf))
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

    /// A made-up Letter PDF: each page a heading bar and a box, so its raster has runs and edges.
    private static func samplePdf(pages: Int) -> Data? {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return nil }
        for i in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.1, green: 0.3, blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 72, y: 700, width: 468, height: 36))
            context.setStrokeColor(CGColor(gray: 0, alpha: 1))
            context.setLineWidth(2)
            context.stroke(CGRect(x: 72 + CGFloat(i) * 40, y: 300, width: 200, height: 200))
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
