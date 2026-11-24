import Foundation
import PrintCore
import Testing
@testable import PrintMac

/// Roadmap 2.1 end to end without a printer: `/usr/bin/ippeveprinter` (CUPS's IPP Everywhere test printer, which macOS ships)
/// on a loopback port answers Get-Printer-Attributes, PrintCore reads its caps and plans a job of each raster format, PrintCore's
/// IPP client sends it with Print-Job through PrintMac's URLSession transport, the job is followed to its end with
/// Get-Job-Attributes, and the document ippeveprinter kept (`-k`) is byte for byte what was sent (as Windows' WSL check found).
/// PCLm at an assumed 600 dpi: ippeveprinter announces no `pclm-*` attributes.
/// ippeveprinter stores a document without reading it: RasterCupsTests reads the formats with libcups and Core Graphics.
@Suite(.serialized)
struct IppEvePrinterTests {
    static let ippeveprinter = "/usr/bin/ippeveprinter"

    /// CUPS's test printer on a loopback port, keeping each job's document (`-k`) in a folder of its own, announced nowhere
    /// (`-r off`). Its host name is `localhost`: given `127.0.0.1` it fails to listen on IPv6 and doesn't answer at all.
    final class TestPrinter {
        let process: Process
        let folder: URL
        let port: Int

        init() throws {
            port = Int.random(in: 30_000..<60_000)
            folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-ippeve-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            process = Process()
            process.executableURL = URL(fileURLWithPath: IppEvePrinterTests.ippeveprinter)
            process.arguments = ["-p", String(port), "-k", "-d", folder.path, "-n", "localhost", "-r", "off", "-2", "-s", "600,600",
                                 "-f", "image/pwg-raster,image/urf,application/PCLm", "Inkvolt Raster Check"]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func stop() {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: folder)
        }

        var ipp: IppClient {
            let http = DeviceHttp(host: "127.0.0.1", transport: URLSessionTransport.factory(localNetwork: nil))
            return IppClient(http, endpoint: URL(string: "http://127.0.0.1:\(port)/ipp/print")!)
        }

        /// Its attributes once it answers (it takes a moment to start).
        func ready() async throws -> IppResponse {
            for _ in 0..<50 {
                if let r = try? await ipp.printerAttributes(IppPrintCaps.requested), r.ok { return r }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw CocoaError(.featureUnsupported)
        }

        /// The kept document of job `id`.
        func kept(_ id: Int) throws -> [UInt8] {
            let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix("\(id)-") }
            let name = try #require(names.first, "no file for job \(id) in \(names)")
            return Array(try Data(contentsOf: folder.appendingPathComponent(name)))
        }
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: IppEvePrinterTests.ippeveprinter)))
    func ippeveprinterTakesEachFormatAndKeepsWhatWasSent() async throws {
        let printer = try TestPrinter()
        defer { printer.stop() }
        var caps = IppPrintCaps.from(try await printer.ready())
        // ippeveprinter lists application/PCLm but none of Mopria's pclm-* attributes, so PCLm doesn't count by itself: 600 dpi
        // assumed, as Windows' run against it does.
        if caps.pclmDpis.isEmpty && !caps.formats.contains(.pclm) {
            caps.pclmDpis = [600]
            caps.formats.append(.pclm)
        }
        #expect(caps.canPrint)
        for format in RasterFormat.allCases {
            var request = DirectPrintRequest(copies: 1, twoSided: false)
            request.format = format
            guard caps.formats.contains(format) else {
                Issue.record("ippeveprinter doesn't list \(format) with what it needs: \(caps.formats)")
                continue
            }
            let plan = try DirectPrintPlan.choose(caps, request).get()
            // One blank page of the printer's paper: ippeveprinter simulates printing each page for seconds.
            let job = plan.job(1)
            let page = try RasterPage.blank(width: job.widthPixels, height: job.heightPixels, color: job.color)
            let writer = try RasterWriter.forJob(job)
            try writer.write(page)
            try writer.finish()
            let document = writer.drain()
            let (id, _) = try await DirectJob.send(printer.ipp, user: "inkvolt", jobName: "raster-\(format)", plan, document: document)
            #expect(id > 0)
            #expect(try printer.kept(id) == document, "\(format)")
            let last = await DirectJob.watch(printer.ipp, user: "inkvolt", jobId: id, every: .milliseconds(100), quiet: .seconds(20))
            #expect(last?.state == DirectJobState.completed, "\(format): \(String(describing: last))")
        }
    }
}
