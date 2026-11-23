import Foundation

/// Where the print log is kept (roadmap 4.9; the Windows Core's `PrintLogFile`): one file in Application Support beside the
/// state file, a JSON line per job (Windows' fields, and the Mac's `Job`), appended as jobs are logged and written again,
/// trimmed, once it holds a fifth more than `PrintLog.maxEntries`. Read back as hostile input: a file past `maxFileBytes` is
/// started again, a line past `maxLineBytes` or that isn't an entry is skipped, every entry is cleaned (`PrintLog.clean`).
/// Never throws for a file it can't read or write: the log is a nicety. Thread-safe.
public final class PrintLogFile: @unchecked Sendable {
    public static let maxFileBytes = 16 * 1024 * 1024, maxLineBytes = 4096

    private let path: String?
    private let log: ((String) -> Void)?
    private let lock = NSRecursiveLock()
    private var entries: [PrintLogEntry]?
    private var lines = 0
    private var rewritten = Date.distantPast

    /// - Parameter path: the file; nil keeps the log in memory (demo mode).
    public init(_ path: String?, log: ((String) -> Void)? = nil) {
        self.path = path
        self.log = log
    }

    /// The log, oldest first.
    public func read(_ now: Date) -> [PrintLogEntry] { lock.withLock { load(now).list } }

    /// Adds the jobs and saves.
    public func add(_ added: [PrintLogEntry], _ now: Date) {
        guard !added.isEmpty else { return }
        lock.withLock {
            let (current, loaded) = load(now)
            let clean = added.compactMap(PrintLog.clean)
            var list = current + clean
            // Trimmed in memory; the file only gets the new lines, and is written again (trimmed) once it holds a fifth more
            // than the log keeps, or at most once a day when jobs have aged out. A file that couldn't be read is never written
            // over: only appended to.
            let before = list.count
            let range = PrintLog.kept(now)
            list = list.filter { range.contains($0.at) }
            let aged = before - list.count
            if list.count > PrintLog.maxEntries { list.removeFirst(list.count - PrintLog.maxEntries) }
            if loaded { entries = list }
            lines += clean.count
            guard path != nil else { return }
            if loaded && (lines > PrintLog.maxEntries * 6 / 5 || (aged > 0 && now.timeIntervalSince(rewritten) > 86_400)) && rewrite(list) {
                rewritten = now
            } else {
                append(clean) // also when writing it again failed: the new jobs are kept either way
            }
        }
    }

    /// Forgets every job (the file is deleted). False when the file couldn't be deleted: then nothing is forgotten.
    public func clear() -> Bool {
        lock.withLock {
            if let path, FileManager.default.fileExists(atPath: path) {
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch {
                    log?("Print log not cleared: \(error.localizedDescription)")
                    return false
                }
            }
            entries = []
            lines = 0
            return true
        }
    }

    /// The log as read from a file's lines (for tests and `load`): bounded, cleaned, oldest first.
    public static func parse(_ lines: [Substring], _ now: Date) -> [PrintLogEntry] {
        var list: [PrintLogEntry] = []
        for line in lines {
            if line.isEmpty || line.utf8.count > maxLineBytes { continue }
            if let entry = PrintLog.clean(decode(line)) { list.append(entry) }
            if list.count > PrintLog.maxEntries * 2 { list.removeFirst(PrintLog.maxEntries) }
        }
        let sorted = list.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        return PrintLog.trim(sorted, now)
    }

    public static func parse(_ lines: [String], _ now: Date) -> [PrintLogEntry] { parse(lines.map { Substring($0) }, now) }

    /// One entry as its line (Windows' member names; a null for what isn't known).
    public static func line(_ e: PrintLogEntry) -> String {
        func quoted(_ s: String) -> String {
            var out = "\""
            for u in s.unicodeScalars {
                switch u {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                default:
                    if u.value < 0x20 || u.value == 0x2028 || u.value == 0x2029 { out += String(format: "\\u%04X", u.value) } else { out.unicodeScalars.append(u) }
                }
            }
            return out + "\""
        }
        func bool(_ b: Bool?) -> String { b.map { $0 ? "true" : "false" } ?? "null" }
        var parts = [
            "\"At\":" + quoted(PrintLog.isoTime(e.at, .current)),
            "\"Printer\":" + quoted(e.printer),
            "\"Document\":" + quoted(e.document),
            "\"User\":" + quoted(e.user),
            "\"Pages\":\(e.pages)",
            "\"Copies\":\(e.copies)",
            "\"Color\":" + bool(e.color),
            "\"TwoSided\":" + bool(e.twoSided),
            "\"Outcome\":" + quoted(e.outcome.fileName),
            "\"Machine\":" + (e.machine.map(quoted) ?? "null"),
            "\"Printed\":\(e.printed)",
        ]
        if let job = e.job { parts.append("\"Job\":" + quoted(job)) }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// A line as an entry, or nil for one that isn't (not a JSON object, a field of the wrong kind, an outcome by a name
    /// it doesn't know). A number it doesn't know as an outcome is Left, as Windows' enum reads it.
    static func decode(_ line: Substring) -> PrintLogEntry? {
        guard let o = Json.parse(Array(line.utf8), handWritten: false, maxDepth: 2)?.objectValue else { return nil }
        func string(_ key: String) -> String?? {
            switch o[key] {
            case nil, .null?: return .some(nil)
            case .string(let s)?: return .some(s)
            default: return nil
            }
        }
        func whole(_ text: String) -> Int? {
            guard let d = Double(text), d.rounded() == d, abs(d) <= Double(Int32.max) else { return nil }
            return Int(d)
        }
        func int(_ key: String, _ fallback: Int) -> Int? {
            switch o[key] {
            case nil, .null?: return fallback
            case .number(let n)?: return whole(n)
            default: return nil
            }
        }
        func bool(_ key: String) -> Bool?? {
            switch o[key] {
            case nil, .null?: return .some(nil)
            case .bool(let b)?: return .some(b)
            default: return nil
            }
        }
        guard let atText = string("At"), let at = atText.flatMap(parseTime), let printer = string("Printer"), let document = string("Document"),
              let user = string("User"), let machine = string("Machine"), let job = string("Job"), let pages = int("Pages", 0),
              let copies = int("Copies", 1), let printed = int("Printed", 0), let color = bool("Color"), let twoSided = bool("TwoSided")
        else { return nil }
        let outcome: PrintLogOutcome
        switch o["Outcome"] {
        case nil, .null?: outcome = .printed
        case .string(let s)?:
            guard let known = PrintLogOutcome.allCases.first(where: { $0.fileName.caseInsensitiveCompare(s) == .orderedSame }) else { return nil }
            outcome = known
        case .number(let n)?:
            guard let value = whole(n) else { return nil }
            outcome = PrintLogOutcome(rawValue: value) ?? .left
        default: return nil
        }
        return PrintLogEntry(at: at, printer: printer ?? "", document: document ?? "", user: user ?? "", pages: pages, copies: copies,
                             color: color, twoSided: twoSided, outcome: outcome, machine: machine, printed: printed, job: job)
    }

    /// ISO 8601 with an offset or Z, seconds' fractions allowed (what Windows' DateTimeOffset writes, and the Mac's line).
    static func parseTime(_ text: String) -> Date? {
        guard text.count <= 40 else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text)
    }

    /// The log as kept, read from the file the first time. A read that fails (the file unreadable, a disk away) isn't kept:
    /// an empty list for now (`loaded` false, so nothing writes over the file), and the next call reads again.
    private func load(_ now: Date) -> (list: [PrintLogEntry], loaded: Bool) {
        if let entries { return (entries, true) }
        guard let path else {
            entries = []
            return ([], true)
        }
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else {
            entries = []
            return ([], true)
        }
        if let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber, size.intValue > Self.maxFileBytes {
            log?("Print log file too large, starting it again")
            try? fm.removeItem(atPath: path)
            lines = 0
            entries = []
            return ([], true)
        }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            log?("Print log not read")
            return ([], false)
        }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: Self.maxFileBytes + 1) ?? Data() else {
            log?("Print log not read")
            return ([], false)
        }
        let text = String(decoding: data, as: UTF8.self)
        let all = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.hasSuffix("\r") ? $0.dropLast() : $0 }
        lines = all.filter { !$0.isEmpty }.count
        let list = Self.parse(all, now)
        entries = list
        return (list, true)
    }

    private func append(_ added: [PrintLogEntry]) {
        guard let path else { return }
        let text = added.map { Self.line($0) + "\n" }.joined()
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: path) {
                try Data(text.utf8).write(to: URL(fileURLWithPath: path))
                return
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { throw CocoaError(.fileWriteNoPermission) }
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        } catch {
            log?("Print log not saved: \(error.localizedDescription)")
        }
    }

    /// The whole log written again, trimmed; false when it couldn't be (the old file stays as it was).
    private func rewrite(_ list: [PrintLogEntry]) -> Bool {
        guard let path else { return false }
        do {
            try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try Data(list.map { Self.line($0) + "\n" }.joined().utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            lines = list.count
            return true
        } catch {
            log?("Print log not written again: \(error.localizedDescription)")
            return false
        }
    }
}
