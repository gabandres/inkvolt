import Foundation
import PdfCore

/// Standard output or error, a line at a time.
final class StandardLines: LineWriter, @unchecked Sendable {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func writeLine(_ text: String) { handle.write(Data((text + "\n").utf8)) }
}

/// What stops the command line (Ctrl+C): the files being worked on finish their current action first.
let commandLineCancel = CancelToken()

/// The command line (`BatchCommandLine`) run to its end before the app would start: the recognizer is Apple's Vision
/// with Recognize Text's choices (`SavedOcr`), nothing is asked, and the exit code is the command's. The main thread runs
/// its run loop meanwhile: the dictionary for suspect words (`MacSpelling`) answers on it.
@MainActor
enum CommandLineRun {
    static func run(_ args: [String]) -> Int {
        signal(SIGINT) { _ in commandLineCancel.cancel() }
        signal(SIGTERM) { _ in commandLineCancel.cancel() }
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var result: Int?
            var code: Int? {
                get { lock.withLock { result } }
                set { lock.withLock { result = newValue } }
            }
        }
        let box = Box()
        let host = SavedOcr.batchHost()
        Task.detached {
            box.code = await BatchCommandLine.run(args, output: StandardLines(.standardOutput), error: StandardLines(.standardError),
                                                  host: host, cancel: commandLineCancel)
            CFRunLoopStop(CFRunLoopGetMain())
        }
        while box.code == nil { _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.25)) }
        return box.code ?? BatchCommandLine.wrong
    }
}
