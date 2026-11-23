import Foundation

/// How a logged job left the queue.
public enum PrintLogOutcome: Int, Equatable, Sendable, CaseIterable {
    /// CUPS said it printed (completed), or it was stopped after pages had printed.
    case printed
    /// Cancelled before a page printed (by someone, or the app that printed it).
    case cancelled
    /// It ended with neither: CUPS gave up on it (aborted) before a page printed.
    case left

    /// The name the log's file writes (Windows' enum names).
    var fileName: String {
        switch self {
        case .printed: "Printed"
        case .cancelled: "Cancelled"
        case .left: "Left"
        }
    }
}

/// One job this Mac printed (roadmap 4.9; the Windows Core's `PrintLogEntry`): when it was submitted, the printer, the
/// document's name, who printed it and from where (`machine`: nil for this Mac), its pages and copies as CUPS counted them,
/// and color and two-sided when the job's options said (nil: not known). Kept on this Mac only (`PrintLogFile`); nothing is
/// sent. `job` (Mac only) is CUPS's job id with its creation time, so a job of CUPS's history is logged once.
public struct PrintLogEntry: Equatable, Sendable {
    public var at: Date
    public var printer: String
    public var document: String
    public var user: String
    /// The document's pages.
    public var pages: Int
    public var copies: Int
    public var color: Bool?
    public var twoSided: Bool?
    public var outcome: PrintLogOutcome
    public var machine: String?
    /// The pages CUPS counted as printed, copies included; 0 when it counted none.
    public var printed: Int
    public var job: String?

    public init(at: Date, printer: String, document: String, user: String, pages: Int, copies: Int = 1, color: Bool? = nil,
                twoSided: Bool? = nil, outcome: PrintLogOutcome = .printed, machine: String? = nil, printed: Int = 0, job: String? = nil) {
        self.at = at
        self.printer = printer
        self.document = document
        self.user = user
        self.pages = pages
        self.copies = copies
        self.color = color
        self.twoSided = twoSided
        self.outcome = outcome
        self.machine = machine
        self.printed = printed
        self.job = job
    }

    /// What the month's totals count: the pages CUPS counted as printed, copies included, or (a driver that counts none)
    /// pages times copies; a cancelled job counts none.
    public var totalPages: Int64 {
        outcome == .cancelled ? 0 : printed > 0 ? Int64(printed) : Int64(pages) * Int64(max(1, copies))
    }

    /// The month it belongs to, in `calendar`'s time zone (this Mac's).
    public func month(_ calendar: Calendar = .current) -> PrintLogMonth { PrintLogMonth(at, calendar) }
}

/// A month of the log (Windows' `DateOnly` of its first day).
public struct PrintLogMonth: Hashable, Comparable, Sendable {
    public var year: Int
    public var month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    public init(_ date: Date, _ calendar: Calendar = .current) {
        let c = calendar.dateComponents([.year, .month], from: date)
        self.init(year: c.year ?? 1, month: c.month ?? 1)
    }

    /// `months` later (earlier when negative).
    public func adding(months: Int) -> PrintLogMonth {
        let index = year * 12 + (month - 1) + months
        return PrintLogMonth(year: index / 12, month: index % 12 + 1)
    }

    public static func < (a: PrintLogMonth, b: PrintLogMonth) -> Bool { (a.year, a.month) < (b.year, b.month) }
}

/// One line of a month's totals: a printer or a person, its jobs, pages (pages × copies) and of those the pages known to
/// be in color.
public struct PrintLogTotal: Equatable, Sendable {
    public var name: String
    public var jobs: Int
    public var pages: Int64
    public var colorPages: Int64

    public init(_ name: String, _ jobs: Int, _ pages: Int64, _ colorPages: Int64) {
        self.name = name
        self.jobs = jobs
        self.pages = pages
        self.colorPages = colorPages
    }
}

/// The print log (print/GLOSSARY.md, "print log"; the Windows Core's `PrintLog`): the jobs this Mac printed, newest last, with
/// month totals per printer and per person and a CSV of it. A log on one Mac, of what passed through its queues: not the
/// quotas, release or accounting of print/ROADMAP.md "Not doing". Bounded: `maxEntries` jobs and `keepMonths` months, names
/// cut to `maxText`. What's read back from the file, and every name CUPS hands over (a document's name comes from whatever
/// printed it), is hostile input: cleaned to one line of visible characters (`AlertText.clean`).
public enum PrintLog {
    public static let maxEntries = 10_000, keepMonths = 13, maxText = 128, maxPages = 1_000_000, maxCopies = 9_999

    /// `entry` added (cleaned), with the jobs past `maxEntries` or older than `keepMonths` dropped.
    public static func add(_ log: [PrintLogEntry], _ entry: PrintLogEntry, _ now: Date) -> [PrintLogEntry] {
        var list = log
        if let clean = clean(entry) { list.append(clean) }
        return trim(list, now)
    }

    /// Oldest first, only the last `maxEntries`, none older than `keepMonths` months before `now`.
    public static func trim(_ list: [PrintLogEntry], _ now: Date) -> [PrintLogEntry] {
        let range = Self.kept(now)
        var left = list.filter { range.contains($0.at) }
        if left.count > maxEntries { left.removeFirst(left.count - maxEntries) }
        return left
    }

    /// Whether a job is kept at `now`: none older than `keepMonths` months, and none dated more than a day ahead (a clock
    /// set wrong, or an edited file): it would stay for ever.
    public static func inRange(_ e: PrintLogEntry, _ now: Date) -> Bool { kept(now).contains(e.at) }

    /// The times a job may have at `now` and be kept (`inRange`), worked out once for a list.
    public static func kept(_ now: Date) -> ClosedRange<Date> {
        let oldest = gregorian.date(byAdding: .month, value: -keepMonths, to: now) ?? now
        return oldest...max(oldest, now.addingTimeInterval(86_400))
    }

    /// An entry as kept: names cleaned and cut, counts bounded; nil for one that isn't a job (no time, a date past now's
    /// year).
    public static func clean(_ e: PrintLogEntry?) -> PrintLogEntry? {
        guard let e, years.contains(e.at) else { return nil }
        var machine = text(e.machine)
        while machine.hasPrefix("\\") { machine.removeFirst() }
        let job = e.job.map { String($0.unicodeScalars.filter { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "@" || $0 == "-") }.prefix(64).map(Character.init)) }
        return PrintLogEntry(at: e.at, printer: text(e.printer), document: text(e.document), user: text(e.user),
                             pages: min(max(e.pages, 0), maxPages), copies: min(max(e.copies, 1), maxCopies), color: e.color,
                             twoSided: e.twoSided, outcome: e.outcome, machine: machine.isEmpty ? nil : machine,
                             printed: min(max(e.printed, 0), maxPages), job: job.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// One line of visible characters, at most `maxText`.
    public static func text(_ text: String?) -> String { AlertText.clean(text, maxText) }

    /// The months with jobs, newest first.
    public static func months(_ log: [PrintLogEntry], _ calendar: Calendar = .current) -> [PrintLogMonth] {
        Array(Set(log.map { $0.month(calendar) })).sorted(by: >)
    }

    /// A month's jobs, newest first.
    public static func jobs(_ log: [PrintLogEntry], in month: PrintLogMonth, _ calendar: Calendar = .current) -> [PrintLogEntry] {
        log.enumerated().filter { $0.element.month(calendar) == month }
            .sorted { ($0.element.at, $0.offset) > ($1.element.at, $1.offset) }.map(\.element)
    }

    /// A month's totals per printer, most pages first.
    public static func byPrinter(_ log: [PrintLogEntry], _ month: PrintLogMonth, _ calendar: Calendar = .current) -> [PrintLogTotal] {
        totals(log, month, calendar, \.printer)
    }

    /// A month's totals per person (the user name the job came with), most pages first.
    public static func byUser(_ log: [PrintLogEntry], _ month: PrintLogMonth, _ calendar: Calendar = .current) -> [PrintLogTotal] {
        totals(log, month, calendar, \.user)
    }

    /// "(not known)": a job CUPS named no printer or person for (cupsd leaves out other users' names).
    public static var unknown: String { loc("(not known)") }

    private static func totals(_ log: [PrintLogEntry], _ month: PrintLogMonth, _ calendar: Calendar,
                               _ key: KeyPath<PrintLogEntry, String>) -> [PrintLogTotal] {
        var order: [String] = []
        var groups: [String: [PrintLogEntry]] = [:]
        for e in log where e.month(calendar) == month && e.outcome != .cancelled {
            let name = e[keyPath: key]
            let group = name.isEmpty ? "\u{0}" : name.lowercased()
            if groups[group] == nil { order.append(group) }
            groups[group, default: []].append(e)
        }
        let rows = order.map { group -> PrintLogTotal in
            let list = groups[group] ?? []
            let first = list.first.map { $0[keyPath: key] } ?? ""
            return PrintLogTotal(first.isEmpty ? unknown : first, list.count, list.reduce(0) { $0 + $1.totalPages },
                                 list.filter { $0.color == true }.reduce(0) { $0 + $1.totalPages })
        }
        return rows.sorted {
            $0.pages != $1.pages ? $0.pages > $1.pages
                : $0.name.compare($1.name, options: [.caseInsensitive], locale: .current) == .orderedAscending
        }
    }

    /// The log as CSV (RFC 4180, a header line, oldest first): time in ISO 8601 with its offset, printer, document, user,
    /// computer, pages, copies, total pages, color and two-sided (yes, no or empty when not known), and how it ended. Every
    /// name is one cell a spreadsheet won't run (`CsvCell`).
    public static func csv(_ log: [PrintLogEntry], timeZone: TimeZone = .current) -> String {
        var csv = "time,printer,document,user,computer,pages,copies,total_pages,color,two_sided,outcome\r\n"
        let ordered = log.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element)
        for e in ordered {
            let outcome = switch e.outcome {
            case .printed: "printed"
            case .cancelled: "cancelled"
            case .left: "left"
            }
            let cells = [isoTime(e.at, timeZone), CsvCell.of(e.printer), CsvCell.of(e.document), CsvCell.of(e.user),
                         CsvCell.of(e.machine ?? ""), String(e.pages), String(e.copies), String(e.totalPages), yesNo(e.color),
                         yesNo(e.twoSided), outcome]
            csv += cells.joined(separator: ",") + "\r\n"
        }
        return csv
    }

    /// "2026-11-22T07:08:47+00:00" (Windows' `yyyy-MM-dd'T'HH:mm:sszzz`).
    static func isoTime(_ date: Date, _ timeZone: TimeZone) -> String {
        var calendar = gregorian
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let offset = timeZone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "-" : "+"
        func two(_ n: Int?) -> String { String(format: "%02d", n ?? 0) }
        return String(format: "%04d", c.year ?? 0) + "-" + two(c.month) + "-" + two(c.day) + "T" + two(c.hour) + ":" + two(c.minute)
            + ":" + two(c.second) + sign + two(abs(offset) / 3600) + ":" + two(abs(offset) % 3600 / 60)
    }

    private static func yesNo(_ value: Bool?) -> String {
        switch value {
        case true?: "yes"
        case false?: "no"
        case nil: ""
        }
    }

    /// A file name for the CSV: "Print log 2026-11-22.csv".
    public static func csvFileName(_ now: Date, timeZone: TimeZone = .current) -> String {
        loc("Print log {0}.csv", String(isoTime(now, timeZone).prefix(10)))
    }

    /// A month as the list names it: "November 2026", in `locale`'s words.
    public static func monthName(_ month: PrintLogMonth, _ locale: Locale = CoreLanguage.locale) -> String {
        var calendar = gregorian
        calendar.locale = locale
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("LLLLyyyy")
        guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 15)) else { return "" }
        let text = formatter.string(from: date)
        guard let first = text.first else { return text }
        return String(first).uppercased(with: locale) + text.dropFirst()
    }

    /// Demo mode's log: about three months of made-up jobs on the demo's printers by three made-up people, the same every run
    /// for a given day (no real name, document or computer). The numbers aren't Windows' (its `System.Random` can't be
    /// reproduced); the shape is.
    public static func demo(_ now: Date, _ calendar: Calendar = .current) -> [PrintLogEntry] {
        let printers = ["Demo office laser", "Demo inkjet", "Demo USB laser"]
        let users = ["demo", "alex", "sam"]
        let documents = ["Quarterly report.pdf", "Invoice 1042.pdf", "Boarding pass", "Lesson plan.docx", "Photo.jpg", "Budget.xlsx",
                         "Recipe", "Letter.docx"]
        var random = SplitMix(UInt64(calendar.ordinality(of: .day, in: .year, for: now) ?? 1))
        var list: [PrintLogEntry] = []
        var at = now.addingTimeInterval(-80 * 86_400)
        while at < now.addingTimeInterval(-3600) {
            let printer = switch random.next(10) {
            case ..<6: 0
            case ..<9: 1
            default: 2
            }
            let pages = 1 + random.next(printer == 1 ? 3 : 12)
            let copies = random.next(8) == 0 ? 2 : 1
            let outcome: PrintLogOutcome = random.next(20) == 0 ? .cancelled : .printed
            let color: Bool? = printer == 1 ? true : printer == 0 ? false : nil
            let twoSided: Bool? = printer == 0 ? random.next(2) == 0 : printer == 1 ? false : nil
            list.append(PrintLogEntry(at: at, printer: printers[printer], document: documents[random.next(documents.count)],
                                      user: users[random.next(users.count)], pages: pages, copies: copies, color: color,
                                      twoSided: twoSided, outcome: outcome, printed: outcome == .printed ? pages * copies : 0))
            at = at.addingTimeInterval(TimeInterval(6 + random.next(30)) * 3600)
        }
        return list
    }

    /// What a job's line says after its name: "3 pages × 2 · color · two-sided · cancelled" (only what's known).
    public static func detail(_ e: PrintLogEntry) -> String {
        var parts: [String] = []
        if e.pages > 0 {
            let pages = e.pages == 1 ? loc("{0} page", CoreLanguage.number(e.pages)) : loc("{0} pages", CoreLanguage.number(e.pages))
            parts.append(pages + (e.copies > 1 ? " × \(e.copies)" : ""))
        }
        if let color = e.color { parts.append(color ? loc("color") : loc("black and white")) }
        if let twoSided = e.twoSided { parts.append(twoSided ? loc("two-sided") : loc("one-sided")) }
        if e.outcome == .cancelled { parts.append(loc("cancelled")) }
        return parts.joined(separator: " · ")
    }

    /// The years a job's time may fall in (2000 to 9000).
    private static let years: Range<Date> = {
        let start = gregorian.date(from: DateComponents(year: 2000, month: 1, day: 1)) ?? .distantPast
        let end = gregorian.date(from: DateComponents(year: 9001, month: 1, day: 1)) ?? .distantFuture
        return start..<end
    }()

    static let gregorian: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? .current
        return c
    }()

    /// SplitMix64: small, seeded, the same everywhere.
    private struct SplitMix {
        private var state: UInt64
        init(_ seed: UInt64) { state = seed }
        mutating func next(_ n: Int) -> Int {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return Int((z ^ (z >> 31)) % UInt64(n))
        }
    }
}
