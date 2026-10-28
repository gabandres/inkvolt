import Foundation

/// A version as What's New compares them: major, minor and patch ("1.0.3"; a fourth number, as package versions have, is
/// dropped).
public struct NoteVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (a: NoteVersion, b: NoteVersion) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}

/// One version's entry in an app's WHATS-NEW.md.
public struct ReleaseNote: Equatable, Sendable {
    public var version: NoteVersion
    public var items: [String]

    public init(version: NoteVersion, items: [String]) {
        self.version = version
        self.items = items
    }
}

/// What's New in both apps: each app bundles a WHATS-NEW.md ("## 1.1.0" headings, "- " items; a heading that isn't a
/// version, such as "## Next", is notes for a release still to come and never shown). After an update the app shows, once,
/// the entries newer than the version it last ran as; a new install shows nothing. Ported from the Windows Core's
/// `ReleaseNotes` (shared/InkvoltPrint.Core/Suite).
public enum ReleaseNotes {
    /// The versioned entries, newest first.
    public static func parse(_ markdown: String) -> [ReleaseNote] {
        var notes: [ReleaseNote] = []
        var current: Int? // the index in `notes` items go to
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                current = nil
                if let version = normalize(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)) {
                    notes.append(ReleaseNote(version: version, items: []))
                    current = notes.count - 1
                }
            } else if line.hasPrefix("#") {
                current = nil
            } else if let c = current, !line.isEmpty {
                if line.hasPrefix("- ") {
                    notes[c].items.append(String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                } else if !notes[c].items.isEmpty {
                    notes[c].items[notes[c].items.count - 1] += " " + line // a wrapped item
                }
            }
        }
        return notes.filter { !$0.items.isEmpty }.sorted { $0.version > $1.version }
    }

    /// The entries to show on this start: those after `lastSeen` up to `current`. Without a readable `lastSeen` (updated
    /// from a version that didn't keep it) just the current version's.
    public static func since(_ notes: [ReleaseNote], lastSeen: String?, current: NoteVersion, newInstall: Bool) -> [ReleaseNote] {
        if newInstall { return [] }
        if let seen = normalize(lastSeen) {
            return notes.filter { $0.version > seen && $0.version <= current }
        }
        return notes.filter { $0.version == current }
    }

    public static func format(_ notes: [ReleaseNote]) -> String {
        notes.map { note in (["Version \(note.version)"] + note.items.map { "• " + $0 }).joined(separator: "\n") }.joined(separator: "\n\n")
    }

    /// "1.0.3", "1.0.3.0", "1.0" → 1.0.3, 1.0.3, 1.0.0 (as .NET's `Version.TryParse`: two to four numbers); else nil.
    public static func normalize(_ text: String?) -> NoteVersion? {
        guard let text else { return nil }
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ".", omittingEmptySubsequences: false)
        guard (2...4).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for p in parts {
            guard !p.isEmpty, p.allSatisfy(\.isASCII), let n = Int(p), n >= 0 else { return nil }
            numbers.append(n)
        }
        return NoteVersion(numbers[0], numbers[1], numbers.count > 2 ? numbers[2] : 0)
    }
}
