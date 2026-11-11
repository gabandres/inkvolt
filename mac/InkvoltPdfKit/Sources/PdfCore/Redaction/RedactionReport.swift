import Foundation
import PrintCore

/// What happened to one thing the search found.
public enum RedactionOutcome: Sendable {
    /// Taken out of the result.
    case removed
    /// The person chose to keep it.
    case kept
    /// Found again after applying: the file fails.
    case stillThere
    /// The file failed, so no result was saved.
    case notSaved
}

/// One row of the removal report. `page` from 0; `masked`: the value with too little left to tell what it was
/// (`RedactionReport.mask`).
public struct RedactionRemoval: Equatable, Sendable {
    public var page: Int
    public var pattern: RedactionPattern
    public var masked: String
    public var outcome: RedactionOutcome

    public init(_ page: Int, _ pattern: RedactionPattern, _ masked: String, _ outcome: RedactionOutcome) {
        self.page = page
        self.pattern = pattern
        self.masked = masked
        self.outcome = outcome
    }

    public var outcomeText: String { RedactionReport.outcomeText(outcome) }
    public var patternName: String { RedactionPatterns.name(pattern) }
}

/// What was done to one file. It holds no unmasked value at any point: it is built only from `RedactionReport.mask`.
/// `failure`: why the file failed (no value in it), or nil.
public struct RedactionFileReport: Equatable, Sendable {
    public var file: String
    public var removals: [RedactionRemoval]
    public var looks: [RedactionLook]
    public var failure: String?
    /// Areas the person had marked by hand before this search, redacted along with its matches (no pattern, no value to mask).
    public var markedAreas = 0

    public init(_ file: String, _ removals: [RedactionRemoval], _ looks: [RedactionLook], _ failure: String?, markedAreas: Int = 0) {
        self.file = file
        self.removals = removals
        self.looks = looks
        self.failure = failure
        self.markedAreas = markedAreas
    }

    /// "4 removed; 1 kept; look by hand at pages 3 and 5".
    public var summary: String {
        var parts: [String] = []
        func count(_ o: RedactionOutcome) -> Int { removals.filter { $0.outcome == o }.count }
        if let failure { parts.append(failure) }
        let removed = count(.removed), kept = count(.kept), unsaved = count(.notSaved)
        if removed > 0 { parts.append(removed == 1 ? loc("{0} removed", context: "one", CoreLanguage.number(1)) : loc("{0} removed", context: "many", CoreLanguage.number(removed))) }
        if kept > 0 { parts.append(kept == 1 ? loc("{0} kept", context: "one", CoreLanguage.number(1)) : loc("{0} kept", context: "many", CoreLanguage.number(kept))) }
        if unsaved > 0 { parts.append(unsaved == 1 ? loc("{0} found, not saved", context: "one", CoreLanguage.number(1)) : loc("{0} found, not saved", context: "many", CoreLanguage.number(unsaved))) }
        if markedAreas > 0 { parts.append(RedactionReport.markedText(markedAreas)) }
        if removals.isEmpty && failure == nil && markedAreas == 0 { parts.append(loc("nothing found")) }
        if !looks.isEmpty { parts.append(loc("look by hand at {0}", RedactionReport.pages(looks.map(\.page)))) }
        return parts.joined(separator: "; ")
    }

    /// The report of a file that failed: nothing it found was removed from a saved result.
    public func withoutResult(_ failure: String) -> RedactionFileReport {
        var r = self
        r.failure = failure
        r.removals = removals.map { m in
            var m = m
            if m.outcome == .removed { m.outcome = .notSaved }
            return m
        }
        return r
    }
}

/// The removal report (the Windows Core's `RedactionReport`): per file the page, pattern and a masked value of each
/// removal, and the pages to look at by hand. A masked value keeps at most the last two digits of a long number: a Social
/// Security number's last four are themselves used to prove who someone is, and anything short (a date, a ZIP code, a
/// name, an address) would be all but given away by any part of it, or by its length, so those keep nothing. A phrase and
/// a custom pattern never appear, only their kind.
public struct RedactionReport: Equatable, Sendable {
    public var files: [RedactionFileReport]

    public init(_ files: [RedactionFileReport]) { self.files = files }

    public var hasFailures: Bool { files.contains { $0.failure != nil } }
    public var hasLooks: Bool { files.contains { !$0.looks.isEmpty } }

    public func count(_ outcome: RedactionOutcome) -> Int { files.reduce(0) { $0 + $1.removals.filter { $0.outcome == outcome }.count } }

    /// What the report's page says first when no file failed. Nothing removed: nothing was read back either.
    public var headline: String {
        let removed = count(.removed), kept = count(.kept), marked = files.reduce(0) { $0 + $1.markedAreas }
        var keptText = kept == 0 ? "" : kept == 1 ? loc(", {0} kept as you chose", context: "one", CoreLanguage.number(1))
            : loc(", {0} kept as you chose", context: "many", CoreLanguage.number(kept))
        if marked > 0 { keptText += ", " + Self.markedText(marked) }
        if removed + marked == 0 { return loc("Nothing was removed{0}.", keptText) }
        if files.count > 1 {
            return removed == 1 ? loc("Read back and searched again: none of what was removed is left in the text of the files. {0} removed{1}.", context: "one", CoreLanguage.number(1), keptText)
                : loc("Read back and searched again: none of what was removed is left in the text of the files. {0} removed{1}.", context: "many", CoreLanguage.number(removed), keptText)
        }
        return removed == 1 ? loc("Read back and searched again: none of what was removed is left in the text of the file. {0} removed{1}.", context: "one", CoreLanguage.number(1), keptText)
            : loc("Read back and searched again: none of what was removed is left in the text of the file. {0} removed{1}.", context: "many", CoreLanguage.number(removed), keptText)
    }

    static func markedText(_ areas: Int) -> String {
        areas == 1 ? loc("{0} other marked area removed", CoreLanguage.number(1)) : loc("{0} other marked areas removed", CoreLanguage.number(areas))
    }

    /// What is left of a value in a report.
    public static func mask(_ pattern: RedactionPattern, _ value: String) -> String {
        let digits = value.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }
        let tail = digits.count >= 9 ? String(String.UnicodeScalarView(digits.suffix(2))) : ""
        switch pattern {
        case .socialSecurity where !tail.isEmpty: return "***-**-**" + tail
        case .paymentCard where !tail.isEmpty: return "**** **** **** **" + tail
        case .phone where !tail.isEmpty: return "***-***-**" + tail
        case .iban where !tail.isEmpty: return "**** **** **" + tail
        case .email: return "***@***"
        case .date: return "**/**/****"
        case .ipAddress: return "***.***"
        default: return "***"
        }
    }

    /// What a match looks like in a report.
    public static func row(_ match: RedactionMatch, _ outcome: RedactionOutcome) -> RedactionRemoval {
        RedactionRemoval(match.page, match.pattern, mask(match.pattern, match.normalized), outcome)
    }

    public static func outcomeText(_ outcome: RedactionOutcome) -> String {
        switch outcome {
        case .removed: loc("Removed")
        case .kept: loc("Kept by you")
        case .stillThere: loc("Still in the file")
        case .notSaved: loc("Found, file not saved")
        }
    }

    /// "page 3", "pages 3, 5 and 8", "12 pages".
    public static func pages(_ pages: [Int]) -> String {
        let list = Array(Set(pages)).sorted().map { CoreLanguage.number($0 + 1) }
        switch list.count {
        case 0: return loc("no pages")
        case 1: return loc("page {0}", list[0])
        case 2...6: return loc("pages {0} and {1}", list.dropLast().joined(separator: ", "), list[list.count - 1])
        default: return loc("{0} pages", CoreLanguage.number(list.count))
        }
    }

    /// The report as CSV (`Csv`, UTF-8 with a byte order mark): one row per removal, per page to look at, and per file's result.
    public func csv() -> [UInt8] {
        var rows: [[String]] = [["File", "Page", "What", "Masked value", "Result"]]
        func number(_ page: Int) -> String { String(page + 1) }
        for file in files {
            let name = Self.cell(file.file)
            let result = file.failure != nil ? loc("Failed: {0}", file.summary) : !file.looks.isEmpty ? loc("Look by hand: {0}", file.summary) : loc("Finished: {0}", file.summary)
            rows.append([name, "", loc("Result for this file"), "", Self.cell(result)])
            for r in file.removals { rows.append([name, number(r.page), r.patternName, Self.cell(r.masked), r.outcomeText]) }
            for look in file.looks { rows.append([name, number(look.page), Self.cell(look.text), "", loc("Look by hand")]) }
        }
        return Csv.write(rows)
    }

    /// A cell that can't run as a spreadsheet formula, whatever a crafted file name holds: control characters go, and an
    /// apostrophe goes in front of one starting (after any spaces) with what starts a formula, wide forms included.
    static func cell(_ value: String) -> String {
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            let k = $0.properties.generalCategory
            return k != .control && k != .format
        }))
        guard let first = clean.unicodeScalars.first(where: { !$0.properties.isWhitespace }) else { return clean }
        return "=+-@|%＝＋－＠".unicodeScalars.contains(first) ? "'" + clean : clean
    }
}
