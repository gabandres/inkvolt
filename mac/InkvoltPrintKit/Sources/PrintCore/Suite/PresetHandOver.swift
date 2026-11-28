import Foundation

/// How a second launch's `--preset` reaches the copy already running (`HandOverFiles`: the notification carries only a
/// token, the preset waits in a file in the app's own sandbox container, which no other app can write, taken once within
/// `freshFor` seconds).
public struct PresetHandOver: Sendable {
    /// How long a left preset waits for the running copy.
    public static let freshFor: TimeInterval = 10
    /// A preset's id or name is cut to this many characters.
    static let longest = 200
    /// More files than this left in the folder: the oldest go.
    static let kept = HandOverFiles.kept

    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    private var files: HandOverFiles { HandOverFiles(folder: folder, freshFor: Self.freshFor, maxBytes: 4096) }

    /// The second launch: `preset` left under a new token, which goes in the notification. Nil when it can't be written.
    public func leave(_ preset: String, now: Date, token: UUID = UUID()) -> String? {
        files.leave(String(preset.prefix(Self.longest)), now: now, token: token)
    }

    /// The running copy: the preset left under `token` (the notification's object, from anyone) when this app left it in the
    /// last `freshFor` seconds; nil for anything else. The file goes either way.
    public func take(_ token: String, now: Date) -> String? {
        guard let text = files.take(token, now: now) else { return nil }
        let preset = String(text.prefix(Self.longest)).trimmingCharacters(in: .whitespacesAndNewlines)
        return preset.isEmpty ? nil : preset
    }
}

/// Where a scan preset run comes from: the app's own menus (the Dock menu, the menu bar's Scan With, the command palette),
/// which the person just clicked, or outside it (`--preset` on the command line, or handed over by a later launch), which
/// any script can start. A preset from outside asks before it scans, so the glass is never scanned without the person
/// seeing it.
public enum PresetOrigin: Sendable {
    case insideApp
    case outside

    public var asksFirst: Bool { self == .outside }
}
