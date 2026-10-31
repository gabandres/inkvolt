import Foundation
import Testing
@testable import PdfCore

/// The check on real files, the Mac's half of `pdf/tools/a11y-corpus`: opt-in, because those PDFs aren't in the repo.
/// `INKVOLT_A11Y_CORPUS=<folder> INKVOLT_A11Y_OUT=<file> swift test --filter AccessibilityCorpusTests` writes one line per
/// PDF in the words of the tool's `check` command (`name PASS|FAIL|ERROR conditions…`), to compare with Windows' output.
struct AccessibilityCorpusTests {
    private static let folder = ProcessInfo.processInfo.environment["INKVOLT_A11Y_CORPUS"]

    @Test(.enabled(if: folder != nil)) func TheFolderIsCheckedFileByFile() throws {
        let folder = try #require(Self.folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0.hasSuffix(".pdf") }.sorted()
        var lines: [String] = []
        for name in names {
            let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: (folder as NSString).appendingPathComponent(name))))
            let started = Date()
            do {
                let report = try AccessibilityCheck.run(data, nil)
                lines.append("\(name) \(report.passed ? "PASS" : "FAIL") \(report.failedConditions.joined(separator: " "))")
                let seconds = Date().timeIntervalSince(started)
                if seconds > 5 { print("SLOW \(name) \(seconds) s") }
                for note in report.notes { print("NOTE \(name): \(note)") }
            } catch {
                lines.append("\(name) ERROR ")
                print("ERROR \(name): \(error)")
            }
        }
        let out = ProcessInfo.processInfo.environment["INKVOLT_A11Y_OUT"] ?? (folder as NSString).appendingPathComponent("mac-results.txt")
        try (lines.joined(separator: "\n") + "\n").write(toFile: out, atomically: true, encoding: .utf8)
    }
}
