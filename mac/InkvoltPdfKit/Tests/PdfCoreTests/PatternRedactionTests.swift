import Foundation
import Testing
@testable import PdfCore

/// Ported from PatternRedactionTests.cs (same names): one Redact Patterns run after its hits were chosen
/// (`PatternRedaction`), as the review list (reviewed) and Batch (unattended) run it: the redaction with the redacted pages'
/// text back, the read-back, the check and its verdict. Adapted: the batch's recognizer is `BatchHost.reader`.
final class PatternRedactionTests {
    private static let font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"
    private static let ssn = RedactionPatternOptions(patterns: [.socialSecurity])
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-pattern-run-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    /// A text page with two numbers on it, and a second page drawing `second`; `title` the file's.
    private static func twoNumbers(_ second: String = "BT /F1 14 Tf 72 700 Td (Nothing to find) Tj ET", title: String = "Untitled") -> [UInt8] {
        Core2Pdf.build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 7 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream("BT /F1 14 Tf 72 700 Td (First 111-22-3333 here) Tj ET\nBT /F1 14 Tf 72 640 Td (Second 444-55-6666 there) Tj ET"),
            font,
            "<< /Title (\(title)) >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 8 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.stream(second),
        ], trailerExtra: "/Info 6 0 R")
    }

    private static func find(_ data: [UInt8], _ options: RedactionPatternOptions, _ ocr: (any TextRecognizer)? = nil) throws -> RedactionSearchResult {
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        return try RedactionSearch.find(engine, options, ocr: ocr)
    }

    private static func text(_ pdf: [UInt8]) throws -> String {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.text(0).text
    }

    private static func run(_ data: [UInt8], _ mode: PatternRedactionMode, _ ocr: (any TextRecognizer)? = nil, _ options: RedactionPatternOptions = ssn,
                            accept: (RedactionMatch) -> Bool = { _ in true }) throws -> (outcome: PatternRedactionOutcome, result: [UInt8]) {
        let found = try find(data, options, ocr)
        let run = PatternRedaction(file: "file.pdf", patterns: options, found: found, accepted: found.hits.filter(accept),
                                   skipped: found.hits.filter { !accept($0) }, mode: mode, ocr: ocr)
        let result = try run.redact(data, nil).data
        return (try run.verify(result, nil, data), result)
    }

    @Test func reviewedASkippedHitIsKeptAndNeitherLookedForNorFoundAgain() throws {
        let data = Self.twoNumbers()
        let (outcome, result) = try Self.run(data, .reviewed, accept: { $0.normalized == "111-22-3333" })

        #expect(outcome.verdict == .passed, "\(outcome.verdict) \(outcome.check?.summary ?? "")")
        #expect(outcome.report.removals.map(\.outcome) == [.removed, .kept])
        #expect(outcome.report.failure == nil)
        // The check knows what was kept, the areas and the file before (the full check).
        #expect(outcome.checkOptions.kept.contains("444-55-6666"))
        #expect(!outcome.checkOptions.values.contains("444-55-6666"))
        #expect(outcome.checkOptions.values.contains("111-22-3333"))
        #expect(outcome.checkOptions.areas != nil)
        #expect(outcome.checkOptions.original == data)
        #expect(!outcome.checkOptions.valuesOnly)
        #expect(try !Self.text(result).contains("111-22-3333"))
    }

    @Test func unattendedLooksForWhatThisRunAndEarlierOnesRemovedOnly() throws {
        let data = Self.twoNumbers()
        let found = try Self.find(data, Self.ssn)
        var run = PatternRedaction(file: "file.pdf", patterns: Self.ssn, found: found, accepted: found.hits, skipped: [], mode: .unattended, ocr: nil)
        run.earlierValues = ["Earlier value"]
        let options = run.checkOptions(data)
        #expect(options.valuesOnly)
        var seen = Set<String>()
        #expect(options.values.filter { seen.insert($0).inserted } == ["Earlier value", "111-22-3333", "444-55-6666"]) // each as it reads and as written
        #expect(options.areas == nil)
    }

    @Test(.enabled(if: ScanCorpus.runs)) func theDriftCaseARedactedScanKeepsItsTextInBothModes() throws {
        for mode in [PatternRedactionMode.reviewed, .unattended] {
            let reader = PlantedReader()
            let (scan, _) = try RedactionCorpusTests.oneScan(reader)
            let (outcome, result) = try Self.run(scan, mode, reader)
            #expect(outcome.verdict == .passed, "\(mode): \(outcome.verdict) \(outcome.check?.summary ?? "") \(outcome.check?.notes ?? [])")
            let text = try Self.text(result)
            #expect(text.contains("heading"), "\(mode): \(text)") // searchable again
            #expect(!text.contains("111-22-3333"))
            #expect(outcome.report.removals.map(\.outcome) == [.removed])
            #expect(outcome.report.looks.map(\.reason) == [.scanReadByOcr])
        }
    }

    @Test(.enabled(if: ScanCorpus.runs)) func theDriftCaseBatchRedactedScansStaySearchable() async throws {
        let reader = PlantedReader()
        let path = (root as NSString).appendingPathComponent("scan.pdf")
        try Data(try RedactionCorpusTests.oneScan(reader).pdf).write(to: URL(fileURLWithPath: path))
        let plan = BatchPlan(steps: [.redactPatterns(Self.ssn)], outputFolder: (root as NSString).appendingPathComponent("out"))
        let summary = try await BatchRunner.run([BatchFile(path)], plan, BatchHost(reader: reader))
        let item = summary.items[0]
        #expect(item.state == .done, "\(item.state): \(item.message) \(item.notes)")
        let output = Array(try Data(contentsOf: URL(fileURLWithPath: try #require(item.outputs.first))))
        let text = try Self.text(output)
        #expect(text.contains("A heading that reads well"), "\(text)")
        #expect(!text.contains("111-22-3333"))
        #expect(try TextLayer.words(output, nil)[0]?.language == "en-US")
    }

    @Test(.enabled(if: ScanCorpus.runs)) func aHitStillThereFailsBothUnattendedStoppingThere() throws {
        let (scan, _) = try RedactionCorpusTests.oneScan(PlantedReader())
        let unattended = try Self.run(scan, .unattended, RedactionCorpusTests.AlwaysReads()).outcome
        #expect(unattended.verdict == .stillThere)
        #expect(!unattended.stillThere.isEmpty)
        #expect(unattended.check == nil)
        #expect(unattended.report.removals.contains { $0.outcome == .stillThere })

        let reviewed = try Self.run(scan, .reviewed, RedactionCorpusTests.AlwaysReads()).outcome
        #expect(reviewed.verdict == .stillThere)
        #expect(reviewed.check != nil) // the person sees the rest of the check too
    }

    @Test func whatWasRemovedLeftElsewhereInTheFileFailsBoth() throws {
        let data = Self.twoNumbers(title: "Case 111-22-3333")
        for mode in [PatternRedactionMode.reviewed, .unattended] {
            let outcome = try Self.run(data, mode).outcome
            #expect(outcome.verdict == .leftInFile, "\(mode): \(outcome.verdict)")
            #expect(outcome.check?.findings.contains { $0.kind == .metadata } == true)
        }
    }

    @Test func aCoverTheFileCameWithIsForThePersonNotAFailure() throws {
        // Text under a black box elsewhere on the page: the full check finds it, the person's to fix; Batch's check doesn't look.
        let data = Self.twoNumbers("BT /F1 14 Tf 72 500 Td (Covered words under a box) Tj ET 0 0 0 rg 66 490 260 26 re f")
        let reviewed = try Self.run(data, .reviewed, accept: { $0.normalized == "111-22-3333" }).outcome
        #expect(reviewed.verdict == .passed, "\(reviewed.verdict)")
        #expect(reviewed.check?.findings.contains { !RedactionCheck.isLeftover($0.kind) } == true)

        let unattended = try Self.run(data, .unattended).outcome
        #expect(unattended.verdict == .passed, "\(unattended.verdict) \(unattended.check?.summary ?? "")")
        #expect(unattended.check?.isClean == true)
    }
}
