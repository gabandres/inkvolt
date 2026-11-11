import Foundation
import PrintCore

/// Who chose a Redact Patterns run's hits, which decides what verifies it and what fails it.
public enum PatternRedactionMode: Sendable {
    /// A person chose each hit (Tools › Redact by Pattern). The read-back reads again by recognition only the redacted pages
    /// left without text (the text layer just laid back holds what the recognizer reads there); the check is the full one,
    /// knowing what was kept, the areas and the document before; only leftovers of what was removed fail the run. The
    /// check's other findings (covers and hidden layers the file came with) are for the person to fix.
    case reviewed
    /// Nobody chose (Batch): every hit goes. The recognizer reads every redacted page again; a hit still there ends the run
    /// there. The check looks only for the values removed (by this run and the file's earlier ones) and for what the
    /// patterns read outside the pages, and anything it finds fails the file: nobody is there to judge a finding. The full
    /// check is the plan's own Check Redaction action.
    case unattended
}

/// Whether a run's redaction holds, the first reason it doesn't when it doesn't.
public enum PatternRedactionVerdict: Sendable {
    case passed
    /// Read back, a hit that was removed is still on its page (`PatternRedactionOutcome.stillThere`).
    case stillThere
    /// The check found what was removed elsewhere in the file (unattended: found anything).
    case leftInFile
    /// The check couldn't look for everything (its notes say why), or the read-back skipped a page: it isn't clean.
    case incomplete
}

/// `report`: the removal report: each accepted hit removed, each skipped one kept, each found again still there, with the
/// search's pages to look at by hand; no failure in it (the caller says it in its words). `check`: the redaction check, nil
/// when the run ended at the read-back (unattended). `unread`: pages the read-back couldn't read (the engine refused them).
public struct PatternRedactionOutcome: Sendable {
    public var verdict: PatternRedactionVerdict
    public var report: RedactionFileReport
    public var stillThere: [RedactionMatch]
    public var check: RedactionCheckReport?
    public var checkOptions: RedactionCheckOptions
    public var unread: [Int]
}

/// One Redact Patterns run after its hits were chosen (the Windows Core's `PatternRedaction`): the accepted hits' areas (and
/// any marked by hand) blacked out with the redacted pages' text recognized again (`redact`, run as one edit the caller's
/// way), then the result read back and searched again, the redaction check, its verdict and the removal report (`verify`).
/// The review list and Batch only choose the hits; what checks them is `PatternRedactionMode`'s.
public struct PatternRedaction: Sendable {
    /// The file's name in the report.
    public let file: String
    public let patterns: RedactionPatternOptions
    /// The search the hits come from (its pages to look at by hand go in the report).
    public let found: RedactionSearchResult
    public let accepted: [RedactionMatch]
    public let skipped: [RedactionMatch]
    public let mode: PatternRedactionMode
    /// The recognizer of the search: reads the redacted pages into text and back. Nil: no text layer, and the read-back
    /// doesn't look past the pages' text.
    public let ocr: (any TextRecognizer)?
    /// Areas redacted with the hits that no pattern found (marked by hand, a page looked at by hand), page space.
    public var marked: [(page: Int, rect: RectD)] = []
    /// Values removed from the file before this run (an earlier Redact Patterns action of a batch): looked for again.
    public var earlierValues: [String] = []

    public init(file: String, patterns: RedactionPatternOptions, found: RedactionSearchResult, accepted: [RedactionMatch],
                skipped: [RedactionMatch], mode: PatternRedactionMode, ocr: (any TextRecognizer)?) {
        self.file = file
        self.patterns = patterns
        self.found = found
        self.accepted = accepted
        self.skipped = skipped
        self.mode = mode
        self.ocr = ocr
    }

    /// What is blacked out, per page: each accepted hit's boxes (`RedactionSearch.areas`) and `marked`.
    public var areas: [Int: [RectD]] {
        var out = RedactionSearch.areas(accepted)
        for m in marked where !(out[m.page] ?? []).contains(m.rect) { out[m.page, default: []].append(m.rect) }
        return out
    }

    /// The edit: `areas` blacked out, the redacted pages' text recognized again (`Redaction.applyWithText`). `skipText`
    /// fired: the pages stay without text.
    public func redact(_ data: [UInt8], _ password: String?, progress: ((Int, Int) -> Void)? = nil, cancel: CancelToken? = nil,
                       skipText: CancelToken? = nil) throws -> Redaction.RedactedData {
        let recognize = ocr.map { PageOcr.recognizer($0, options: Redaction.textBackOptions) }
        return try Redaction.applyWithText(data, password, areas, recognize: recognize, language: ocr?.language, progress: progress,
                                           cancel: cancel, skipText: skipText)
    }

    /// What the check is told (see `PatternRedactionMode`). `before`: the document before the redaction.
    public func checkOptions(_ before: [UInt8]?) -> RedactionCheckOptions {
        let kept = RedactionSearch.values(skipped)
        let keptKeys = Set(kept.map { $0.lowercased() })
        let removed = RedactionSearch.soughtValues(accepted).filter { !keptKeys.contains($0.lowercased()) }
        switch mode {
        case .reviewed:
            return RedactionCheckOptions(values: removed, areas: areas, original: before, patterns: patterns, kept: kept)
        case .unattended:
            return RedactionCheckOptions(values: earlierValues + removed, patterns: patterns, kept: kept, valuesOnly: true)
        }
    }

    /// The removal report (`stillThere` added as still there).
    public func report(_ stillThere: [RedactionMatch] = []) -> RedactionFileReport {
        RedactionFileReport(file, accepted.map { RedactionReport.row($0, .removed) } + skipped.map { RedactionReport.row($0, .kept) }
                                + stillThere.map { RedactionReport.row($0, .stillThere) }, found.looks, nil)
    }

    /// Reads `redacted` (`redact`'s result) back and searches it again, then runs the redaction check, on the calling thread.
    /// Nothing redacted (no areas): only the check. Skipped hits found again don't count: they were kept. `before`: the
    /// document before the redaction (the check's `original`); `readBack`: (pages searched, pages) of the read-back;
    /// `checking`: called as the check starts.
    /// - Throws: `RedactionSearchTimeout` when a pattern took too long; `TooManyHits` when the read-back found more than can
    ///   be listed; `CancellationError`.
    public func verify(_ redacted: [UInt8], _ password: String?, _ before: [UInt8]?, readBack: ((Int, Int) -> Void)? = nil,
                       checking: (() -> Void)? = nil, cancel: CancelToken? = nil) throws -> PatternRedactionOutcome {
        var still: [RedactionMatch] = []
        var unread: [Int] = []
        let areas = self.areas
        if !areas.isEmpty {
            let reread = mode == .reviewed ? try Self.withoutText(redacted, password, Array(areas.keys)) : Set(areas.keys)
            (still, unread) = try RedactionSearch.readBack(redacted, password, patterns, ocr: ocr, redactedPages: reread, kept: skipped,
                                                           progress: readBack, cancel: cancel)
        }
        var options = checkOptions(before)
        // Pages the search or the read-back couldn't read weren't looked at: the check says it is incomplete.
        options.skipped = Array(Set(unread + found.skipped)).sorted()
        if !still.isEmpty && mode == .unattended {
            return PatternRedactionOutcome(verdict: .stillThere, report: report(still), stillThere: still, check: nil, checkOptions: options, unread: unread)
        }
        checking?()
        let check = try RedactionCheck.run(redacted, password, options, cancel: cancel)
        let left = mode == .reviewed ? check.findings.contains { RedactionCheck.isLeftover($0.kind) } : !check.isClean
        let verdict: PatternRedactionVerdict = !still.isEmpty ? .stillThere : left ? .leftInFile : check.incomplete ? .incomplete : .passed
        return PatternRedactionOutcome(verdict: verdict, report: report(still), stillThere: still, check: check, checkOptions: options, unread: unread)
    }

    /// The pages of `pages` without any text (none recognized, or reading it was skipped).
    private static func withoutText(_ data: [UInt8], _ password: String?, _ pages: [Int]) throws -> Set<Int> {
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        var out = Set<Int>()
        for p in pages where p >= 0 && p < engine.pageCount {
            // A page the engine refuses is read again by recognition, as one without text.
            if (try? TextLayer.hasText(engine, p)) != true { out.insert(p) }
        }
        return out
    }
}
