import Foundation

/// Help › Report a Problem: the details a report needs, scrubbed, shown first, then copied for the user to paste into a
/// GitHub issue (the Windows apps' `Diagnostics.Report`, `Tail` and `IssueUrl`). Nothing is sent from the app. The
/// masking itself is PrintCore's `Diagnostics.scrub` (ported with Inkvolt Print), passed in as `scrub` so PdfCore stays
/// free of PrintCore.
public enum ProblemReport {
    /// Lines of the log a report carries.
    public static let logLines = 200

    /// The report: the app and its version, the system, the settings and the log's tail, each value and line scrubbed.
    /// `system` is the Mac's (macOS's version), where Windows writes "Windows:" and .NET's version.
    public static func report(app: String, version: String, system: String, architecture: String, packaged: Bool,
                              settings: [(name: String, value: String)], logTail: [String], scrub: (String) -> String) -> String {
        var lines: [String] = []
        lines.append("\(app) \(version)\(packaged ? " (Store package)" : "")")
        lines.append("macOS: \(system), \(architecture)")
        lines.append("")
        lines.append("Settings")
        for s in settings { lines.append("\(s.name): \(scrub(s.value))") }
        lines.append("")
        lines.append("Log (last \(logLines) lines)")
        if logTail.isEmpty { lines.append("(no log yet)") }
        for line in logTail { lines.append(scrub(line)) }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The last `count` lines of a log, read while the app may be writing to it; none when it's missing.
    public static func tail(_ path: String, count: Int = logLines) -> [String] {
        guard let handle = FileHandle(forReadingAtPath: path) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            return []
        }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        if lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(count))
    }

    /// A new GitHub issue with the version and the system filled in, asking to paste the copied details (too long for a
    /// URL).
    public static func issueUrl(repository: String, app: String, version: String, system: String) -> String {
        let body = """
            **App:** \(app) \(version)
            **macOS:** \(system)

            **What happened?**


            **What did you expect to happen?**


            **Steps to get there**


            **Details**
            Paste here the details \(app) copied (Report a Problem). Read them first: delete anything you'd rather not share.

            """
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        func escape(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s }
        var repo = repository
        while repo.hasSuffix("/") { repo.removeLast() }
        return "\(repo)/issues/new?title=\(escape("[\(app)] "))&body=\(escape(body))"
    }
}
