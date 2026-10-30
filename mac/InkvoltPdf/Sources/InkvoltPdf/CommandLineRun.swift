import Foundation
import PdfCore

/// Standard output or error, a line at a time.
final class StandardLines: LineWriter, @unchecked Sendable {
    private let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func writeLine(_ text: String) { handle.write(Data((text + "\n").utf8)) }
}

/// What stops the command line (Ctrl+C): the files being worked on finish their current action first.
nonisolated(unsafe) let commandLineCancel = CancelToken()

/// The command line (`BatchCommandLine`) run to its end before the app would start: the recognizer is Apple's Vision,
/// nothing is asked, and the exit code is the command's.
enum CommandLineRun {
    static func run(_ args: [String]) -> Int {
        signal(SIGINT) { _ in commandLineCancel.cancel() }
        signal(SIGTERM) { _ in commandLineCancel.cancel() }
        let done = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var code = BatchCommandLine.wrong }
        let box = Box()
        Task.detached {
            box.code = await BatchCommandLine.run(args, output: StandardLines(.standardOutput), error: StandardLines(.standardError),
                                                  host: BatchHost(recognize: PageOcr.recognizer(VisionRecognizer())), cancel: commandLineCancel)
            done.signal()
        }
        done.wait()
        return box.code
    }
}
