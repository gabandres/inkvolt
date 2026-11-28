import Foundation
import PrintCore

/// A later launch's `--convert-to` handed to the copy already running (Windows' single-instance pipe; Inkvolt Print's
/// `--preset` goes the same way, both through `HandOverFiles`). The distributed notification carries only a token; the
/// command line waits in a file of the user's temporary folder (0700, beside the launches' `FileSlot` locks), which a
/// sandboxed app can't write, taken once within `freshFor` seconds. Before, the running copy converted whatever command
/// line any process of the user posted, making Word files beside any PDF it named.
public struct ConvertHandOver: Sendable {
    /// How long a left command line waits for the running copy (a launch waits 3 seconds for its answer).
    public static let freshFor: TimeInterval = 10
    /// A left command line larger than this is not read: `ConvertCommand.maxFiles` paths of up to 16 KB each, as JSON.
    static let maxBytes = 16 << 20

    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    /// The folder the app's launches use: `inkvolt-pdf-convert/hand-over` in the user's temporary folder.
    public static var standard: ConvertHandOver {
        ConvertHandOver(folder: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkvolt-pdf-convert/hand-over", isDirectory: true))
    }

    private var files: HandOverFiles { HandOverFiles(folder: folder, freshFor: Self.freshFor, maxBytes: Self.maxBytes) }

    /// The later launch: its command line (`ConvertCommand.toArguments`) left under a new token, which goes in the
    /// notification. Nil when it can't be written.
    public func leave(_ arguments: [String], now: Date, token: UUID = UUID()) -> String? {
        guard arguments.count <= ConvertCommand.maxFiles + 1, let data = try? JSONEncoder().encode(arguments) else { return nil }
        return files.leave(String(decoding: data, as: UTF8.self), now: now, token: token)
    }

    /// The running copy: the command line left under `token` (the notification's, from anyone) when a launch left it in the
    /// last `freshFor` seconds; nil for anything else (a command line in the notification itself is never read).
    public func take(_ token: String, now: Date) -> [String]? {
        guard let text = files.take(token, now: now), let arguments = try? JSONDecoder().decode([String].self, from: Data(text.utf8)),
              arguments.count <= ConvertCommand.maxFiles + 1 else { return nil }
        return arguments
    }
}
