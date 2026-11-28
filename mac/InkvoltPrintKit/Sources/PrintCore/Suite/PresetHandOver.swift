import Foundation

/// How a second launch's `--preset` reaches the copy already running (Windows' single-instance pipe, which only this user's
/// processes may open). A distributed notification can be posted by any process, sandboxed ones too, so it carries only a
/// token: the preset itself is left in a file named by that token, in a folder of the app's own sandbox container
/// (`folder`), which no other app can write. The running copy takes a preset only from a file this launch wrote in the last
/// `freshFor` seconds; anything else (a made-up token, an old file, a path) is nothing. Each file is read once and deleted.
public struct PresetHandOver: Sendable {
    /// How long a left preset waits for the running copy.
    public static let freshFor: TimeInterval = 10
    /// A preset's id or name is cut to this many characters.
    static let longest = 200
    /// More files than this left in the folder (a launch that never got its answer, many times): the oldest go.
    static let kept = 16

    public let folder: URL

    public init(folder: URL) { self.folder = folder }

    /// The second launch: `preset` left under a new token, which goes in the notification. Nil when it can't be written.
    public func leave(_ preset: String, now: Date, token: UUID = UUID()) -> String? {
        let id = token.uuidString
        let entry = Entry(preset: String(preset.prefix(Self.longest)), written: now.timeIntervalSinceReferenceDate)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            tidy()
            try JSONEncoder().encode(entry).write(to: file(id), options: .atomic)
            return id
        } catch {
            return nil
        }
    }

    /// The running copy: the preset left under `token` (the notification's object, from anyone) when this app left it in the
    /// last `freshFor` seconds; nil for anything else. The file goes either way.
    public func take(_ token: String, now: Date) -> String? {
        guard let id = UUID(uuidString: token)?.uuidString, id == token.uppercased() else { return nil } // a token, no path
        let url = file(id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= 4096 else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.written.isFinite else { return nil }
        let age = now.timeIntervalSinceReferenceDate - entry.written
        guard age >= -1, age <= Self.freshFor else { return nil } // a second of clock slack, never an old one
        let preset = String(entry.preset.prefix(Self.longest)).trimmingCharacters(in: .whitespacesAndNewlines)
        return preset.isEmpty ? nil : preset
    }

    private struct Entry: Codable {
        var preset: String
        var written: TimeInterval
    }

    private func file(_ id: String) -> URL { folder.appendingPathComponent(id + ".json") }

    /// The oldest files beyond `kept` go (each launch adds one; the running copy deletes what it takes).
    private func tidy() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path), names.count >= Self.kept else { return }
        let dated = names.prefix(1000).map { name -> (String, Date) in
            let date = (try? fm.attributesOfItem(atPath: folder.appendingPathComponent(name).path)[.modificationDate]) as? Date
            return (name, date ?? .distantPast)
        }
        for (name, _) in dated.sorted(by: { $0.1 < $1.1 }).prefix(dated.count - Self.kept + 1) {
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
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
