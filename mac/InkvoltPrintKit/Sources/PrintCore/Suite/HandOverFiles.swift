import Foundation

/// How a later launch hands something to the copy already running (Windows' single-instance pipe, which only this user's
/// processes may open), for Inkvolt Print's `--preset` (`PresetHandOver`) and Inkvolt PDF's `--convert-to`
/// (`ConvertHandOver`). A distributed notification can be posted by any process, sandboxed ones too, so it carries only a
/// token: what is handed over is left in a file named by that token, in a folder only the app writes (Inkvolt Print's
/// sandbox container; Inkvolt PDF's folder of the user's temporary directory, 0700, which a sandboxed app can't reach).
/// The running copy takes only a file left in the last `freshFor` seconds; anything else (a made-up token, an old file, a
/// path) is nothing. Each file is read once and deleted.
public struct HandOverFiles: Sendable {
    /// More files than this left in the folder (a launch that never got its answer, many times): the oldest go.
    public static let kept = 16

    public let folder: URL
    /// How long a left file waits for the running copy.
    public let freshFor: TimeInterval
    /// A file larger than this is not read.
    public let maxBytes: Int

    public init(folder: URL, freshFor: TimeInterval, maxBytes: Int) {
        self.folder = folder
        self.freshFor = freshFor
        self.maxBytes = maxBytes
    }

    /// The later launch: `text` left under a new token (0600), which goes in the notification. Nil when it can't be written.
    public func leave(_ text: String, now: Date, token: UUID = UUID()) -> String? {
        let id = token.uuidString
        let entry = Entry(text: text, written: now.timeIntervalSinceReferenceDate)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            tidy()
            let data = try JSONEncoder().encode(entry)
            if data.count > maxBytes { return nil }
            try data.write(to: file(id), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(id).path)
            return id
        } catch {
            return nil
        }
    }

    /// The running copy: the text left under `token` (the notification's object, from anyone) when this app left it in the
    /// last `freshFor` seconds; nil for anything else. The file goes either way.
    public func take(_ token: String, now: Date) -> String? {
        guard let id = UUID(uuidString: token)?.uuidString, id == token.uppercased() else { return nil } // a token, no path
        let url = file(id)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.size] as? NSNumber)?.intValue ?? .max <= maxBytes else { return nil }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let data = try? Data(contentsOf: url), let entry = try? JSONDecoder().decode(Entry.self, from: data),
              entry.written.isFinite else { return nil }
        let age = now.timeIntervalSinceReferenceDate - entry.written
        guard age >= -1, age <= freshFor else { return nil } // a second of clock slack, never an old one
        return entry.text
    }

    private struct Entry: Codable {
        var text: String
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
