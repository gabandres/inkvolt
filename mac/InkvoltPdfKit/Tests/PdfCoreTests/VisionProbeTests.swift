import Foundation
import Testing
@testable import PdfCore

/// Whether Vision has the two faults Windows' recognizer has (roadmap 2.2): lines skipped on a page (Windows' fix is
/// `MissedLines.cs`) and a page of digits read upside down (`ScanText.ClearlyMore`, ported). Opt-in, on the Mac:
/// `INKVOLTPDF_VISION_PROBE=1 swift test --filter VisionProbeTests`. Each corpus page is read the way Recognize Text reads
/// it (cleaned, upright, Vision), the words lined up with the page's truth; a skipped line shows as a run of truth words
/// with nothing read for them. The numbers go to the output; `mac/docs/PLAN.md` keeps what they said.
struct VisionProbeTests {
    static let runs = ProcessInfo.processInfo.environment["INKVOLTPDF_VISION_PROBE"] == "1"

    /// Words as compared: lower case, letters and digits only.
    static func key(_ w: String) -> String { String(w.lowercased().filter { $0.isLetter || $0.isNumber }) }

    /// The runs of consecutive truth words left unmatched by a longest common subsequence with what was read.
    static func missedRuns(_ truth: [String], _ read: [String]) -> [Int] {
        let (t, r) = (truth.map(key), read.map(key))
        let (n, m) = (t.count, r.count)
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = t[i] == r[j] && !t[i].isEmpty ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var runs: [Int] = []
        var (i, j, run) = (0, 0, 0)
        while i < n {
            if j < m && t[i] == r[j] && !t[i].isEmpty {
                if run > 0 { runs.append(run) }
                (i, j, run) = (i + 1, j + 1, 0)
            } else if j < m && table[i][j + 1] >= table[i + 1][j] {
                j += 1
            } else {
                (i, run) = (i + 1, run + 1)
            }
        }
        if run > 0 { runs.append(run) }
        return runs
    }

    @Test func missedRunsFindsAGapOfConsecutiveWords() {
        let truth = "one two three four five six seven eight nine ten".split(separator: " ").map(String.init)
        #expect(Self.missedRuns(truth, truth).isEmpty)
        #expect(Self.missedRuns(truth, ["one", "two", "eight", "nine", "ten"]) == [5])
        #expect(Self.missedRuns(truth, ["One,", "tw0", "three", "four", "five", "six", "seven", "eight", "nine", "ten."]) == [1])
    }

    @Test(.enabled(if: runs)) func visionOnTheCorpus() throws {
        var lines: [String] = []
        for file in ScanCorpus.files {
            let (pdf, pages) = try ScanCorpus.make(file)
            let engine = try PdfEngine.open(pdf)
            defer { engine.close() }
            let vision = VisionRecognizer(languages: file.language == "es" ? ["es-ES", "en-US"] : ["en-US"])
            for (p, truth) in pages.enumerated() {
                let page = try ScanText.recognize(engine, p, vision, RecognizeOptions(checkWords: false))
                let read = page.words.map(\.text)
                let runs = Self.missedRuns(truth.words, read)
                let wer = WordErrorRate.of(truth.words, read)
                lines.append("\(file.name) p\(p + 1): \(truth.words.count) words, WER \(String(format: "%.1f", wer * 100)) %, turns \(page.quarterTurns) (scanned \(truth.turns)), missed runs >= 6: \(runs.filter { $0 >= 6 }), longest \(runs.max() ?? 0)")
            }
        }
        print("VISION PROBE\n" + lines.joined(separator: "\n"))
    }

    @Test(.enabled(if: runs)) func visionOnThePageOfDigits() throws {
        let pdf = try PdfEngine.open(Core2Pdf.build(ScanTextTests.digitsPageObjects))
        defer { pdf.close() }
        for options in [RecognizeOptions(checkWords: false), RecognizeOptions.asScanned] {
            let page = try ScanText.recognize(pdf, 0, VisionRecognizer(languages: ["en-US"]), options)
            print("VISION DIGITS clean=\(options.clean): turns \(page.quarterTurns): \(page.words.map(\.text).joined(separator: " "))")
        }
    }
}
