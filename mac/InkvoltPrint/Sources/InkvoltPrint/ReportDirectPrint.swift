import CoreGraphics
import Foundation
import PDFKit
import PrintCore
import PrintMac

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
        guard let document = samplePdf(pages: 3) else { return lines + ["  sample PDF: not made"] }
        let clock = ContinuousClock()
        let started = clock.now
        let raster: [UInt8]
        do {
            let data = document.dataRepresentation()
            raster = try await Task.detached { () throws -> [UInt8] in
                guard let data, let copy = PDFDocument(data: data) else { throw DirectPrintPages.NotDrawn() }
                return try DirectPrintPages.document(copy, plan: plan)
            }.value
        } catch {
            return lines + ["  drawn: failed (\(error))"]
        }
        lines.append("  drawn: 3 pages, \(raster.count) bytes in \(clock.now - started)")
        do {
            let (id, state) = try await DirectJob.send(ipp, user: DirectPrinting.user, jobName: "Inkvolt direct print check", plan, document: raster)
            lines.append("  Print-Job: job \(id), \(state.map { DirectJob.describe($0, pages: 3) } ?? "no state")")
            let last = await DirectJob.watch(ipp, user: DirectPrinting.user, jobId: id, every: .milliseconds(200), quiet: .seconds(10))
            lines.append("  followed: \(last.map { DirectJob.describe($0, pages: 3) } ?? "no answer")")
        } catch let e as DirectPrintError {
            lines.append("  Print-Job: \(e.message) (may have printed: \(e.mayHavePrinted))")
        } catch {
            lines.append("  Print-Job: \(error)")
        }
        return lines
    }

    /// A made-up Letter PDF: each page a heading bar and a box, so its raster has runs and edges.
    private static func samplePdf(pages: Int) -> PDFDocument? {
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
        return PDFDocument(data: data as Data)
    }
}
