import Foundation
import Testing
@testable import PdfCore

/// Report a Problem's report, log tail and issue address: the report, tail and issue-URL tests of Inkvolt Print's
/// HelpTests.cs (the same names; the Windows code is shared/InkvoltPrint.Core/Suite/Diagnostics.cs, which Inkvolt PDF
/// uses too). The masking is PrintCore's `Diagnostics.scrub`, tested in PrintCoreTests' DiagnosticsTests; here a stand-in
/// masks the two values the Windows test checks, to show every setting and log line goes through it.
struct HelpTests {
    private static func scrub(_ s: String) -> String {
        s.replacingOccurrences(of: #"C:\Users\jdoe\Scans"#, with: "[path]").replacingOccurrences(of: "192.168.1.23", with: "[ip]")
    }

    @Test func Report_has_the_app_windows_settings_and_the_scrubbed_log_tail() {
        let report = ProblemReport.report(
            app: "Inkvolt Print", version: "1.0.3", system: "Version 26.1 (Build 25B78)", architecture: "arm64",
            packaged: true, settings: [("Theme", "Dark"), ("Scan folder", #"C:\Users\jdoe\Scans"#)],
            logTail: ["2026-10-25 10:00:00.000 Connected to 192.168.1.23", "2026-10-25 10:00:01.000 Ready"], scrub: Self.scrub)

        #expect(report.contains("Inkvolt Print 1.0.3 (Store package)"))
        #expect(report.contains("macOS: Version 26.1 (Build 25B78), arm64"))
        #expect(report.contains("Theme: Dark"))
        #expect(report.contains("Scan folder: [path]"))
        #expect(report.contains("Connected to [ip]"))
        #expect(report.contains("Ready"))
        #expect(!report.lowercased().contains("jdoe"))
        #expect(!report.contains("192.168"))
    }

    @Test func Report_says_when_there_is_no_log() {
        let report = ProblemReport.report(app: "Inkvolt PDF", version: "1.0.3", system: "macOS", architecture: "x86_64", packaged: false,
                                          settings: [], logTail: [], scrub: { $0 })
        #expect(report.contains("Inkvolt PDF 1.0.3"))
        #expect(!report.contains("Store package"))
        #expect(report.contains("(no log yet)"))
    }

    @Test func Tail_reads_the_last_lines_of_a_log_another_writer_holds_open() throws {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-tail-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(atPath: path) }
        try (1...500).map { "line \($0)" }.joined(separator: "\n").appending("\n").write(toFile: path, atomically: true, encoding: .utf8)
        let writer = try #require(FileHandle(forUpdatingAtPath: path))
        defer { try? writer.close() }
        #expect(ProblemReport.tail(path, count: 3) == ["line 498", "line 499", "line 500"])
    }

    @Test func Tail_of_a_missing_log_is_empty() {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("none-\(UUID().uuidString).log")
        #expect(ProblemReport.tail(path, count: 10).isEmpty)
    }

    @Test func Issue_url_prefills_a_github_issue_without_the_log() throws {
        let url = ProblemReport.issueUrl(repository: "https://github.com/gabandres/inkvolt", app: "Inkvolt Print", version: "1.0.3",
                                         system: "Version 26.1 (Build 25B78)")
        #expect(url.hasPrefix("https://github.com/gabandres/inkvolt/issues/new?title="))
        let encoded = try #require(url.range(of: "&body=")).upperBound
        let body = try #require(String(url[encoded...]).removingPercentEncoding)
        #expect(body.contains("Inkvolt Print 1.0.3"))
        #expect(body.contains("Version 26.1 (Build 25B78)"))
        #expect(body.lowercased().contains("paste"))
        #expect(url.count < 2000)
        #expect(URL(string: url) != nil)
    }
}
