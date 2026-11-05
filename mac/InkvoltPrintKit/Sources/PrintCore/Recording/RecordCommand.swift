import Foundation

/// `record <address> <folder> [--scan] [--community name] [--escl url] [--ipp url] [--force]` (print/ROADMAP.md 1.2;
/// Windows' developer CLI `inkvoltprint record`): records a printer through `PrinterRecorder` into a folder and says what
/// it kept. Mac difference: the app is sandboxed, so the folder is a plain name inside the app's own recordings folder
/// (`base`), never a path; the Mac app runs it from `--report` (`--record <address> <folder>`). What it prints masks the
/// address and this Mac's names (`Diagnostics.scrub`), so it can be pasted; the files are scrubbed by the recorder.
public struct RecordCommand: Sendable, Equatable {
    public var host: String
    public var folder: String
    public var scan = false
    public var force = false
    public var community = SnmpClient.defaultCommunity
    public var esclHint: URL?
    public var ippHint: URL?

    public static let usage = "record <address> <folder> [--scan] [--community name] [--escl url] [--ipp url] [--force]"

    public init(host: String, folder: String) {
        self.host = host
        self.folder = folder
    }

    /// The command from the arguments: `keyword`, the address and the folder, then its options anywhere after them. Nil when
    /// `keyword` isn't there; a command with an empty address or folder when they're missing (`run` says how to use it).
    public static func parse(_ args: [String], keyword: String) -> RecordCommand? {
        guard let i = args.firstIndex(of: keyword) else { return nil }
        let rest = Array(args[(i + 1)...])
        func positional(_ n: Int) -> String { n < rest.count && !rest[n].hasPrefix("--") ? rest[n] : "" }
        var command = RecordCommand(host: positional(0), folder: positional(0).isEmpty ? "" : positional(1))
        func value(_ name: String) -> String? { rest.firstIndex(of: name).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } }
        command.scan = rest.contains("--scan")
        command.force = rest.contains("--force")
        if let c = value("--community") { command.community = c }
        command.esclHint = value("--escl").flatMap(URL.init(string:))
        command.ippHint = value("--ipp").flatMap(URL.init(string:))
        return command
    }

    /// A folder name that stays inside `base`: no separators, not "." or "..", nothing hidden.
    static func plainName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 120 && !name.hasPrefix(".") && !name.contains("/") && !name.contains("\\") && !name.contains(":")
            && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }

    /// Records the printer into `base/folder` and returns what to print. Never throws: a refusal or a failure is a line.
    public func run(in base: URL, transport: any HttpTransport, snmp: (any SnmpTransport)?, who: Diagnostics.Identity) async -> [String] {
        guard !host.isEmpty, !folder.isEmpty else { return ["Usage: \(Self.usage)"] }
        guard Self.plainName(folder) else {
            return ["record: \(folder) isn't a plain folder name; the recording goes into \(base.lastPathComponent)/<folder> in the app's own folder."]
        }
        let target = base.appendingPathComponent(folder, isDirectory: true)
        let there = (try? FileManager.default.contentsOfDirectory(atPath: target.path)) ?? []
        if !there.isEmpty && !force {
            return ["record: \(base.lastPathComponent)/\(folder) isn't empty: choose a new folder, or add --force to write into it."]
        }
        var options = RecordOptions(transport: transport, snmp: snmp)
        options.community = community
        options.esclHint = esclHint
        options.ippHint = ippHint
        options.scan = scan
        options.who = who
        func clean(_ s: String) -> String { Diagnostics.scrub(s.replacingOccurrences(of: host, with: "[host]"), who) }
        let started = ContinuousClock.now
        let result: RecordResult
        do {
            result = try await PrinterRecorder.record(host, to: target, options)
        } catch {
            return ["record: " + clean(ReportRecording.failureText(error, who))]
        }
        let ms = (ContinuousClock.now - started) / .milliseconds(1)
        var lines = ["record: recorded \(clean(result.model ?? "the printer")) (\(result.interfaces.joined(separator: ", "))) in \(Int(ms)) ms: "
            + "\(result.files.count) files in \(base.lastPathComponent)/\(folder)"]
        lines += result.files.map { "  \($0)" }
        let scrubbed = result.scrubbed.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }
        lines.append("  scrubbed: \(scrubbed.isEmpty ? "nothing found" : scrubbed.joined(separator: ", "))")
        lines += result.notKept.map { "  " + clean($0) }
        lines.append("  served as the printer at \(FixtureScrubber.defaultPlaceholderHost). Read the files before sharing them"
            + (scan ? "; the scanned pages are kept as they are." : "."))
        return lines
    }
}
