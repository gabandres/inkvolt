import AppKit
import PrintCore
import PrintMac

/// `print` from Terminal (Windows' `inkvoltprint print`, roadmap 2.4, Pro): run as
/// `"/Applications/Inkvolt Print.app/Contents/MacOS/Inkvolt Print" print --list <file> --printer <name>`, with no window
/// (`BatchPrintCommandLine`). Control-C stops between files and pages. With `--demo`, the made-up Mac's queues (nothing
/// prints) and `--pro-enforce` switches the Pro check on without a key, to see the refusal.
///
/// Mac difference: the App Store's sandbox lets this process read only what the user gave the app, so the files and folders
/// the Batch Print window was given (`BatchPlaces`: added, saved a list to, watched) are opened to it first; anything else
/// reads as "macOS doesn't let Inkvolt Print read this file". A report goes where the sandbox lets it write: one of those
/// places, or the app's container.
@MainActor
enum PrintCommand {
    static func run(_ args: [String]) -> Int32 {
        let model = AppModel.shared
        ProSetup.configure(model)
        if model.isDemo && args.contains("--pro-enforce") { Pro.enforced = true }
        let given = args.filter { $0 != "--pro-enforce" && $0 != "--demo" }
        let places = model.isDemo ? nil : BatchPlaces.open(model.store) // every remembered place, for this run
        defer { places?.close() }

        let stop = BatchStop()
        signal(SIGINT, SIG_IGN)
        let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        interrupt.setEventHandler { stop.stop() }
        interrupt.resume()
        defer { interrupt.cancel() }

        let host = MacPrintHost(demo: model.isDemo, known: model.store.current)
        let done = Done()
        Task.detached {
            let code = await BatchPrintCommandLine.run(given, host, stop, output: { Self.write(FileHandle.standardOutput, $0) },
                                                       error: { Self.write(FileHandle.standardError, $0) })
            done.set(code)
        }
        // The main run loop keeps going meanwhile: Control-C and PDFKit report to it.
        while done.code == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        return done.code ?? BatchPrintSummary.wrong
    }

    nonisolated static func write(_ handle: FileHandle, _ line: String) {
        handle.write(Data((line + "\n").utf8))
    }

    /// The command's exit code, handed from its task to the main thread.
    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Int32?

        var code: Int32? { lock.withLock { value } }
        func set(_ c: Int32) { lock.withLock { value = c } }
    }
}

/// This Mac's side of `print`: PDFKit and Image I/O, and the printer a name stands for (`BatchPrinterLookup` decides, roadmap
/// 2.1): its macOS queue (by its name or the name System Settings shows), or straight to it over IPP with the certificate pins
/// Inkvolt Print keeps for it, read only (an `ipp://` or `ipps://` address, a remembered printer with no queue or set to print
/// straight); demo mode's made-up queues.
struct MacPrintHost: BatchPrintHost {
    let demo: Bool
    /// The app's state when the command started: the printers it remembers, their pins, the print straight choices.
    var known = PrintState()
    var documents: any BatchDocuments { MacBatchDocuments() }

    func findPrinter(_ name: String) async throws -> any BatchQueue {
        if demo {
            if let queue = DemoBatchQueue.named(name) { return queue }
            let names = DemoBatchQueue.all.map(\.name).joined(separator: ", ")
            throw BatchCommandError("There is no printer \"\(BatchPrintText.clean(name))\" in the demo (its queues: \(names)).")
        }
        // An address given needs no queue list.
        let destinations = name.contains("://") ? [] : await LibCups().destinations() ?? []
        switch try BatchPrinterLookup.find(name, destinations: destinations, known: known) {
        case .queue(let queue):
            return CupsBatchQueue(queue: queue)
        case .direct(let endpoint, let shown, let printer):
            // Lives as long as the command: the process ends with the batch.
            let http = DeviceHttp(host: endpoint.host ?? "", transport: URLSessionTransport.factory(localNetwork: nil),
                                  pin: printer.map { ReadOnlyPins(known, $0.uuid) })
            let ipp = IppClient(http, endpoint: endpoint)
            let caps = IppCapsCache({ IppPrintCaps.from(try await ipp.printerAttributes(IppPrintCaps.requested)) })
            return DirectBatchQueue(shown, ipp: ipp, caps: caps, send: DirectBatchJobs.send(ipp, caps: caps, user: DirectPrinting.user))
        }
    }
}
