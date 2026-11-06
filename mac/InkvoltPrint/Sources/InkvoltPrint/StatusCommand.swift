import AppKit
import PrintCore
import PrintMac

/// The app's entry: `Inkvolt Print status --all [--json] [--out file]` (Inkvolt Pro, roadmap 2.6) reads every printer once and
/// writes the list, with no window and nothing kept; `Inkvolt Print print …` (roadmap 2.4, `PrintCommand`) prints a batch
/// without a window; anything else starts the app.
@main
enum Launch {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if FleetCommand.isFor(args) { exit(MainActor.assumeIsolated { StatusCommand.run(args) }) }
        if BatchPrintCommandLine.isCommand(args) { exit(MainActor.assumeIsolated { PrintCommand.run(args) }) }
        AppLanguage.apply(args) // the commands above stay English
        InkvoltPrintApp.main()
    }
}

/// `status --all` from Terminal (the Windows app's `inkvoltprint status --all` in the app itself): run as
/// `"/Applications/Inkvolt Print.app/Contents/MacOS/Inkvolt Print" status --all --json`. Read only (`FleetReader`): no state,
/// history or certificate pin is written, so it runs beside the app. With `--demo`, the made-up printers (and `--pro-enforce`
/// switches the Pro check on without a key, to see the refusal). Mac difference: the sandbox lets `--out` write only inside
/// the app's container, so a file elsewhere comes from the shell (`> printers.json`).
@MainActor
enum StatusCommand {
    static func run(_ args: [String]) -> Int32 {
        let model = AppModel.shared
        ProSetup.configure(model)
        if model.isDemo && args.contains("--pro-enforce") { Pro.enforced = true }
        let fleet = model.fleetMac
        let given = args.filter { $0 != "--pro-enforce" && $0 != "--no-printers" }
        let done = Done()
        Task.detached {
            let result = await FleetCommand.run(given, read: { try await FleetReader.readAll(fleet, now: Date()) }, now: { Date() }, .current)
            done.set(result)
        }
        // The main run loop keeps going meanwhile: ImageCaptureCore and the network report to it.
        while done.result == nil { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
        let result = done.result!
        FileHandle.standardOutput.write(Data(result.output.utf8))
        FileHandle.standardError.write(Data(result.error.utf8))
        return result.code
    }

    /// The command's result, handed from its task to the main thread.
    private final class Done: @unchecked Sendable {
        private let lock = NSLock()
        private var value: FleetCommand.Result?

        var result: FleetCommand.Result? { lock.withLock { value } }
        func set(_ r: FleetCommand.Result) { lock.withLock { value = r } }
    }
}
