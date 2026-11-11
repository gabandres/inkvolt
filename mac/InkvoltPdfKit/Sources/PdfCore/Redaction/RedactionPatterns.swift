import Darwin
import Foundation
import PrintCore

/// What redaction by pattern looks for: the built-in kinds, then the user's own phrases and expression.
public enum RedactionPattern: Int, CaseIterable, Hashable, Sendable {
    /// 123-45-6789, 123 45 6789 or 123456789; not area 000, 666 or 9xx, group 00 or serial 0000.
    case socialSecurity
    /// North American numbers ((555) 201-3434, 555.201.3434, +1 555 201 3434) and international +CC numbers.
    case phone
    case email
    /// 13 to 19 digits (in groups split by spaces or dashes) that pass the Luhn check, starting 2 to 6.
    case paymentCard
    /// 2026-10-27, 10/27/2026, 27.10.2026, October 27, 2026, 27 Oct 2026 (days checked against their month).
    case date
    /// US ZIP codes (12345, 12345-6789): five digits alone match too much, so it is off unless chosen.
    case zipCode
    /// International bank account numbers, with their check digits verified (mod 97).
    case iban
    /// IPv4 (192.168.1.10) and IPv6 (2001:db8::1) addresses.
    case ipAddress
    /// One of the user's words or phrases.
    case phrase
    /// The user's own regular expression.
    case expression
}

/// What to look for, and on which pages.
public struct RedactionPatternOptions: Equatable, Sendable {
    /// The built-in kinds to look for (`.phrase` and `.expression` come from `phrases` and `expression`).
    public var patterns: Set<RedactionPattern>
    /// Words or phrases found as they are written (whitespace in one matches any whitespace, line breaks too).
    public var phrases: [String]
    /// Phrases match whole words only.
    public var wholeWord: Bool
    /// Phrases and `expression` tell capitals from small letters.
    public var matchCase: Bool
    /// A regular expression (ICU's syntax, as NSRegularExpression reads it), run on the page text with line breaks read
    /// as spaces (nil or empty: none).
    public var expression: String?
    /// The pages to search (0-based); nil for all of them.
    public var pages: [Int]?
    /// The saved set these came from (`RedactionPatternSets`), when they came from one.
    public var setName: String?

    public init(patterns: Set<RedactionPattern> = RedactionPatterns.defaults, phrases: [String] = [], wholeWord: Bool = true,
                matchCase: Bool = false, expression: String? = nil, pages: [Int]? = nil, setName: String? = nil) {
        self.patterns = patterns
        self.phrases = phrases
        self.wholeWord = wholeWord
        self.matchCase = matchCase
        self.expression = expression
        self.pages = pages
        self.setName = setName
    }

    /// Nothing to look for.
    public var isEmpty: Bool {
        !patterns.contains(where: RedactionPatterns.builtIn.contains)
            && !phrases.contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && (expression ?? "").isEmpty
    }
}

/// A match on a page.
public struct RedactionMatch: Equatable, Sendable {
    public var page: Int
    public var pattern: RedactionPattern
    /// Where the match starts in the page's `PageText.text` (UTF-16 units), and ends (exclusive).
    public var start: Int
    public var end: Int
    public var text: String
    /// Its boxes on the page, one per line it covers (page space).
    public var rects: [RectD]
    /// The match as the patterns read it: line breaks as spaces, hyphens at line ends gone, recognizer slips put right.
    public var normalized: String
    /// The text just before and just after the match, safe to show (`RedactionPatterns.displayable`).
    public var before: String
    public var after: String
    /// Found in what text recognition read on the page, not in the page's own text.
    public var fromOcr: Bool

    public init(page: Int, pattern: RedactionPattern, start: Int, end: Int, text: String, rects: [RectD], normalized: String? = nil,
                before: String = "", after: String = "", fromOcr: Bool = false) {
        self.page = page
        self.pattern = pattern
        self.start = start
        self.end = end
        self.text = text
        self.rects = rects
        self.normalized = normalized ?? text
        self.before = before
        self.after = after
        self.fromOcr = fromOcr
    }
}

/// A document has more matches than can be reviewed. Nothing is applied: a partial list must not look complete (.NET's
/// `TooManyHitsException`).
public struct TooManyHits: Error, Equatable, Sendable, CustomStringConvertible {
    public var limit: Int
    public var message: String { loc("More than {0} matches were found, so the search stopped and nothing was changed. Choose fewer kinds or a narrower pattern.", CoreLanguage.number(limit)) }
    public var description: String { message }
}

/// A pattern took too long on a page, so the search stopped (.NET's `TimeoutException` with a
/// `RegexMatchTimeoutException` inside).
public struct RedactionSearchTimeout: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    /// The user's own expression took too long (else a built-in kind did).
    public var userExpression: Bool
    public var description: String { message }
}

/// Redaction by pattern (the Windows app's `RedactionPatterns`): finds Social Security numbers, phone numbers, email
/// addresses, payment card numbers, dates, ZIP codes, IBANs, IP addresses, the user's phrases and the user's regular
/// expression in a document's text, page by page, with each match's boxes ready for `Redaction.apply`. The patterns run
/// on the page text with line breaks read as spaces, words hyphenated across a line ("exam-" / "ple") joined and a
/// number split after a dash ("555-" / "1234") kept whole, so a match may run onto the next line. Numbers with a check
/// digit (cards, IBANs) count only when it is right, and where two built-in kinds claim the same text the stronger one
/// keeps it (a card number isn't also a phone number). The user's phrases and expression are kept as found.
public enum RedactionPatterns {
    /// The built-in kinds in the order they are offered.
    public static let builtIn: [RedactionPattern] = [.socialSecurity, .phone, .email, .paymentCard, .date, .iban, .ipAddress, .zipCode]

    /// Every built-in kind but ZIP codes.
    public static let defaults: Set<RedactionPattern> = Set(builtIn.filter { $0 != .zipCode })

    /// How long the user's expression may take on one page before the search stops.
    public static let expressionTimeout = 1.0

    /// How long one page may take in all (seconds): each regex call has its own time limit, and a page can make very many
    /// calls. Tests shorten it.
    @TaskLocal static var pageBudgetForTests: Double?
    static var pageBudget: Double { pageBudgetForTests ?? 10 }

    /// Most matches in a document before the search stops (`TooManyHits`).
    public static let maxHits = 100_000

    /// The longest own pattern, the most phrases and the longest phrase: what a hand or a tampered file can give.
    public static let maxExpressionLength = 2_000, maxPhrases = 2_000, maxPhraseLength = 500

    public static func name(_ pattern: RedactionPattern) -> String {
        switch pattern {
        case .socialSecurity: loc("US Social Security numbers")
        case .phone: loc("Phone numbers")
        case .email: loc("Email addresses")
        case .paymentCard: loc("Payment card numbers")
        case .date: loc("Dates")
        case .zipCode: loc("US ZIP codes")
        case .iban: loc("Bank account numbers (IBAN)")
        case .ipAddress: loc("IP addresses")
        case .phrase: loc("Your words and phrases")
        case .expression: loc("Your pattern")
        }
    }

    /// What a kind looks like, for the dialog.
    public static func example(_ pattern: RedactionPattern) -> String {
        switch pattern {
        case .socialSecurity: "123-45-6789 or 123456789"
        case .phone: "(555) 201-3434, +1 555 201 3434, +44 20 7946 0958"
        case .email: "name@example.com"
        case .paymentCard: loc("4111 1111 1111 1111; only numbers whose check digit is right")
        case .date: "2026-10-27, 10/27/2026, 27.10.2026, October 27, 2026, 27 Oct 2026"
        case .zipCode: loc("90210 or 90210-1234; any five-digit number matches, so check the marks")
        case .iban: loc("DE89 3704 0044 0532 0130 00; only numbers whose check digits are right")
        case .ipAddress: "192.168.1.10, 2001:db8::1"
        default: ""
        }
    }

    /// What is wrong with a user's expression, in plain words; nil when it is fine (or empty).
    public static func validateExpression(_ expression: String?) -> String? {
        guard let expression, !expression.isEmpty else { return nil }
        if expression.utf16.count > maxExpressionLength {
            return loc("This pattern is too long: keep it under {0} characters.", CoreLanguage.number(maxExpressionLength))
        }
        guard let regex = try? NSRegularExpression(pattern: expression) else {
            // NSRegularExpression says only that the pattern can't be read, not where: the usual mistake, a parenthesis
            // or bracket without its partner, is looked for here and pointed at.
            if let (at, why) = unpaired(expression) { return loc("The pattern has a mistake near character {0}: {1}.", CoreLanguage.number(at), why) }
            return loc("The pattern has a mistake: it can't be read as a regular expression (perhaps a repeat with nothing to repeat, a \\ before something it can't escape, or a {…} repeat written wrong).")
        }
        do {
            if try !TimedRegex.matches(regex, in: "", seconds: expressionTimeout).isEmpty {
                return loc("This pattern matches empty text, so it would mark nothing useful. Make at least one part required.")
            }
        } catch {
            return loc("This pattern takes too long even on empty text. Make it simpler.")
        }
        return nil
    }

    /// What is wrong with a whole set of choices (from the dialog, a saved set or a preset), in plain words; nil when fine.
    public static func validate(_ options: RedactionPatternOptions) -> String? {
        if options.phrases.count > maxPhrases { return loc("There are too many words and phrases: at most {0}.", CoreLanguage.number(maxPhrases)) }
        if options.phrases.contains(where: { $0.utf16.count > maxPhraseLength }) {
            return loc("A word or phrase is too long: at most {0} characters.", CoreLanguage.number(maxPhraseLength))
        }
        return validateExpression(options.expression)
    }

    /// Text that came from a file, made safe to show: control and invisible format characters (bidirectional overrides that
    /// would make it read differently) gone, whitespace as single spaces, at most `max` UTF-16 units, then "…".
    public static func displayable(_ text: String, _ max: Int = 120) -> String {
        var out: [Unicode.Scalar] = []
        var units = 0
        var cut = false
        for (n, c) in text.unicodeScalars.enumerated() {
            if n >= max * 8 { break }
            if units > max {
                cut = true
                break
            }
            if c.properties.isWhitespace {
                if let last = out.last, last != " " {
                    out.append(" ")
                    units += 1
                }
                continue
            }
            switch c.properties.generalCategory {
            case .control, .format, .unassigned, .privateUse, .surrogate: continue
            default: break
            }
            out.append(c)
            units += c.utf16.count
        }
        if !cut && units <= max { return String(String.UnicodeScalarView(out)) }
        while units > max, let last = out.popLast() { units -= last.utf16.count }
        return String(String.UnicodeScalarView(out)) + "…"
    }

    /// The first parenthesis or bracket without its partner, as (its position, counted from 1; what is wrong); nil when
    /// they pair up. Escapes (\x, \Q…\E) are skipped; a [ inside a set opens a set of its own (ICU's nested sets).
    static func unpaired(_ pattern: String) -> (Int, String)? {
        let c = Array(pattern)
        var groups: [Int] = []
        var sets: [Int] = []
        var i = 0
        while i < c.count {
            if c[i] == "\\" {
                guard i + 1 < c.count else { return (i + 1, loc("a \\ at the end has nothing to escape")) }
                if c[i + 1] == "Q" {
                    var j = i + 2
                    while j + 1 < c.count && !(c[j] == "\\" && c[j + 1] == "E") { j += 1 }
                    i = j + 2
                } else {
                    i += 2
                }
                continue
            }
            if !sets.isEmpty {
                if c[i] == "[" { sets.append(i) } else if c[i] == "]" { sets.removeLast() }
            } else if c[i] == "[" {
                sets.append(i)
            } else if c[i] == "(" {
                groups.append(i)
            } else if c[i] == ")" {
                if groups.popLast() == nil { return (i + 1, loc("a ) has no ( before it")) }
            }
            i += 1
        }
        if let open = sets.first { return (open + 1, loc("a [ has no closing ]")) }
        if let open = groups.last { return (open + 1, loc("a ( has no closing )")) }
        return nil
    }

    /// The matches on one page, in reading order.
    /// - Throws: `PdfEditError` when the expression isn't valid (see `validateExpression`); `RedactionSearchTimeout` when
    ///   a pattern took too long.
    public static func find(_ text: PageText, _ page: Int, _ options: RedactionPatternOptions) throws -> [RedactionMatch] {
        try findOnPage(text, page, options, compile(options))
    }

    /// The values the patterns find in text that isn't on a page (a comment, a property), as the patterns read them.
    static func findValues(_ text: String, _ options: RedactionPatternOptions, _ custom: NSRegularExpression?) throws -> [String] {
        let box = RectD(0, 0, 1, 1)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in line.unicodeScalars.map { (String($0), box) } }
        return try findOnPage(PageText(lines), 0, options, custom).map(\.normalized)
    }

    /// The matches on the chosen pages (all of them when none are chosen), page by page; `progress` gets (pages done,
    /// pages to search). A page the engine refuses is skipped, and `skipped` says which.
    /// - Throws: as `find(_:_:_:)`; `CancellationError` when `cancel` fires.
    public static func find(_ engine: PdfEngine, _ options: RedactionPatternOptions, progress: ((Int, Int) -> Void)? = nil,
                            cancel: CancelToken? = nil, skipped: SkippedPages? = nil) throws -> [RedactionMatch] {
        let custom = try compile(options)
        let pages = Array(Set((options.pages ?? Array(0..<engine.pageCount)).filter { $0 >= 0 && $0 < engine.pageCount })).sorted()
        let skipped = skipped ?? SkippedPages()
        var matches: [RedactionMatch] = []
        for (i, p) in pages.enumerated() {
            try cancel.check()
            // Cached only for a few pages: a long document would push the pages the viewer shows out of the engine's text cache.
            if let text = try skipped.unlessRefused({ try engine.text(p, cache: pages.count <= 8, cancel: cancel) }) {
                matches += try findOnPage(text, p, options, custom)
            }
            if matches.count > maxHits { throw TooManyHits(limit: maxHits) }
            progress?(i + 1, pages.count)
        }
        return matches
    }

    /// The areas to black out per page: each match's boxes, grown by half a point so no edge of a glyph survives.
    public static func areas(_ matches: [RedactionMatch]) -> [Int: [RectD]] {
        var out: [Int: [RectD]] = [:]
        for m in matches {
            for r in m.rects.map({ $0.inflate(0.5) }) where !(out[m.page] ?? []).contains(r) { out[m.page, default: []].append(r) }
        }
        return out
    }

    /// Finds the matches and redacts them for good (`Redaction.apply`); the data as it was when nothing matched. `skipped`:
    /// the pages the engine refused (from 0), not searched, so whatever matches on them is still there.
    public static func redact(_ data: [UInt8], _ password: String?, _ options: RedactionPatternOptions,
                              cancel: CancelToken? = nil) throws -> (data: [UInt8], matches: [RedactionMatch], skipped: [Int]) {
        let engine = try PdfEngine.open(data, password: password)
        let matches: [RedactionMatch]
        let skipped = SkippedPages()
        do {
            matches = try find(engine, options, cancel: cancel, skipped: skipped)
            engine.close()
        } catch {
            engine.close()
            throw error
        }
        try cancel.check()
        return matches.isEmpty ? (data, matches, skipped.list) : (try Redaction.apply(data, password, areas(matches)), matches, skipped.list)
    }

    /// How many matches of each kind, in the order the kinds are offered (kinds without matches left out).
    public static func counts(_ matches: [RedactionMatch]) -> [(pattern: RedactionPattern, count: Int)] {
        var counts: [RedactionPattern: Int] = [:]
        for m in matches { counts[m.pattern, default: 0] += 1 }
        return (builtIn + [.phrase, .expression]).compactMap { p in counts[p].map { (p, $0) } }
    }

    /// "Email addresses: 3, Dates: 2".
    public static func summary(_ matches: [RedactionMatch]) -> String {
        counts(matches).map { loc("{0}: {1}", name($0.pattern), CoreLanguage.number($0.count)) }.joined(separator: ", ")
    }

    // ---- Finding ----

    static func compile(_ options: RedactionPatternOptions) throws -> NSRegularExpression? {
        if let error = validate(options) { throw PdfEditError(error) }
        guard let expression = options.expression, !expression.isEmpty else { return nil }
        do {
            return try NSRegularExpression(pattern: expression, options: options.matchCase ? [] : [.caseInsensitive])
        } catch {
            throw PdfEditError(loc("The pattern isn't valid."))
        }
    }

    private static let contextChars = 48

    /// `lenient`: the text came from a recognizer: read slips kindly (`lenientView`), and a number of the right length counts
    /// even when its check digit fails, since one misread digit would otherwise hide it.
    static func findOnPage(_ text: PageText, _ page: Int, _ options: RedactionPatternOptions, _ custom: NSRegularExpression?,
                           lenient: Bool = false) throws -> [RedactionMatch] {
        var found: [RedactionMatch] = []
        if text.isEmpty { return found }
        let units = Array(text.text.utf16)
        let (plainUnits, plainMap) = view(units)
        // The kinds read a recognizer's text kindly; the person's own pattern reads what was read ("CASE-12" isn't "CA5E-12").
        let (viewUnits, map) = lenient ? lenientView(plainUnits, plainMap) : (plainUnits, plainMap)
        let view = String(decoding: viewUnits, as: UTF16.self) as NSString
        let plain = String(decoding: plainUnits, as: UTF16.self) as NSString
        let started = Date()
        let budget = pageBudget
        func spend() throws {
            if Date().timeIntervalSince(started) > budget {
                throw RedactionSearchTimeout(message: loc("Looking at page {0} took too long, so the search stopped and nothing was changed.", CoreLanguage.number(page + 1)),
                                             userExpression: false)
            }
        }

        func add(_ pattern: RedactionPattern, _ start: Int, _ end: Int, _ readIn: NSString?, _ readMap: [Int]?) throws {
            if end <= start { return }
            var (s, e) = (start, end)
            let normalized: String
            if let readIn {
                normalized = readIn.substring(with: NSRange(location: s, length: e - s))
            } else {
                let (v, _) = Self.view(Array(units[s..<e]))
                normalized = String(decoding: v, as: UTF16.self).trimmingCharacters(in: .whitespaces)
            }
            if let readMap { (s, e) = (readMap[s], readMap[e - 1] + 1) }
            var rects = text.rects(s, e).filter { !$0.isEmpty }
            // Text without a box of its own (glyphs of no size) is still text in the file: its page has to go too.
            if rects.isEmpty {
                let b = text.boxAt(s)
                rects.append(RectD(b.x, b.y, 1, 1))
            }
            let after = min(units.count, e + contextChars)
            let space = e < after && PageText.isWhiteSpace(units[e]) ? " " : ""
            found.append(RedactionMatch(page: page, pattern: pattern, start: s, end: e, text: text.string(s, e), rects: rects, normalized: normalized,
                                        before: displayable(text.string(max(0, s - contextChars), s), contextChars),
                                        after: space + displayable(text.string(e, after), contextChars)))
            if found.count > maxHits { throw TooManyHits(limit: maxHits) }
        }

        // Built-in kinds: every rule's matches, then where two kinds overlap the stronger (earlier in `strength`) keeps the text.
        var builtIn: [(pattern: RedactionPattern, start: Int, end: Int)] = []
        for rule in rules where options.patterns.contains(rule.pattern) {
            do {
                var m = try TimedRegex.first(rule.regex, in: view, from: 0, seconds: 2)
                while let match = m {
                    let at = match.range.location, length = match.range.length
                    let end = accept(rule, match, view, viewUnits, lenient)
                    if let end { builtIn.append((rule.pattern, at, end)) }
                    if builtIn.count > maxHits * 4 { throw TooManyHits(limit: maxHits) }
                    // What a check cut off or refused may hold the next number ("2026 4111 1111 1111 1111"): look again from
                    // where the number that counted ends, or after the first group of one that didn't.
                    var next = -1
                    if rule.trim && end != at + length {
                        if let end { next = end } else { next = firstSeparator(viewUnits, at, length) }
                    }
                    let from = next > at ? next : at + max(length, 1)
                    m = from <= view.length ? try TimedRegex.first(rule.regex, in: view, from: from, seconds: 2) : nil
                    try spend()
                }
            } catch is TimedRegex.Timeout {
                throw RedactionSearchTimeout(message: loc("Looking for {0} took too long on page {1}.", name(rule.pattern).lowercased(), CoreLanguage.number(page + 1)),
                                             userExpression: false)
            }
            try spend()
        }
        let ordered = builtIn.enumerated().sorted { a, b in
            let sa = strength.firstIndex(of: a.element.pattern) ?? 99, sb = strength.firstIndex(of: b.element.pattern) ?? 99
            if sa != sb { return sa < sb }
            let la = a.element.end - a.element.start, lb = b.element.end - b.element.start
            if la != lb { return la > lb }
            return a.offset < b.offset
        }.map(\.element)
        // Each unit at most once: a page of hostile text can hold hundreds of thousands of matches.
        var taken = [Bool](repeating: false, count: viewUnits.count)
        for m in ordered {
            if taken[m.start..<m.end].contains(true) { continue }
            for i in m.start..<m.end { taken[i] = true }
            try add(m.pattern, m.start, m.end, view, map)
        }

        // The user's phrases go through the page search (whole words, case, hyphenation, whitespace as it does).
        var seen = Set<String>()
        for phrase in options.phrases.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !phrase.isEmpty {
            if !seen.insert(options.matchCase ? phrase : phrase.lowercased()).inserted { continue }
            for hit in text.find(phrase, matchCase: options.matchCase, wholeWord: options.wholeWord) {
                try add(.phrase, hit.start, hit.end, nil, nil)
            }
            try spend()
        }

        if let custom {
            let all: [NSTextCheckingResult]
            do {
                all = try TimedRegex.matches(custom, in: plain, seconds: expressionTimeout)
            } catch {
                throw RedactionSearchTimeout(message: loc("Your pattern took too long on page {0}, so the search stopped. Make it simpler: a repeat inside a repeat, such as (a+)+, can take very long on some text.", CoreLanguage.number(page + 1)), userExpression: true)
            }
            for m in all where m.range.length > 0 {
                try add(.expression, m.range.location, m.range.location + m.range.length, plain, plainMap)
                try spend()
            }
        }
        return found.enumerated().sorted { a, b in
            if a.element.start != b.element.start { return a.element.start < b.element.start }
            if a.element.end != b.element.end { return a.element.end < b.element.end }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// The first space or dash in `units[at..<at+length]`, else -1.
    private static func firstSeparator(_ units: [UInt16], _ at: Int, _ length: Int) -> Int {
        for i in at..<min(units.count, at + length) where units[i] == 32 || units[i] == 45 { return i }
        return -1
    }

    /// The page text as the patterns read it, with each unit's index in the text: whitespace (line breaks too) as a space,
    /// dashes as '-', soft hyphens and other invisible characters dropped, wide forms as plain ones ("１２３" as "123"), a
    /// hyphen at a line break between letters dropped with the break (one word) and one between digits kept without the
    /// break (one number), as is one that starts the next line.
    private static func view(_ text: [UInt16]) -> (view: [UInt16], map: [Int]) {
        var out: [UInt16] = []
        var map: [Int] = []
        out.reserveCapacity(text.count)
        map.reserveCapacity(text.count)
        var i = 0
        while i < text.count {
            var c = text[i]
            if c == 0xAD {
                if i + 1 < text.count && text[i + 1] == 10 { i += 1 }
                i += 1
                continue
            }
            if isFormat(c) {
                i += 1
                continue
            }
            if c == 10 && i > 0 && i + 2 < text.count && isDigit(text[i - 1]) && isDash(text[i + 1]) && isDigit(text[i + 2]) {
                i += 1
                continue
            }
            if c >= 0xFF01 && c <= 0xFF5E && !isDash(c) { c -= 0xFEE0 }
            if isDash(c) && i > 0 && i + 2 < text.count && text[i + 1] == 10 {
                if PageText.isLetter(text[i - 1]) && PageText.isLetter(text[i + 2]) {
                    i += 2
                    continue
                }
                // Between digits (a number), or a letter and a digit (CASE-0412): the hyphen stays, the break goes.
                if isLetterOrDigit(text[i - 1]) && isLetterOrDigit(text[i + 2]) {
                    out.append(45)
                    map.append(i)
                    i += 2
                    continue
                }
            }
            out.append(PageText.isWhiteSpace(c) ? 32 : isDash(c) ? 45 : c)
            map.append(i)
            i += 1
        }
        return (out, map)
    }

    /// The letters a recognizer takes for digits, and the digit each is: O o → 0, l I | ! → 1, S s → 5, B → 8, Z z → 2.
    private static let slips: [UInt16: UInt16] = [79: 48, 111: 48, 108: 49, 73: 49, 124: 49, 33: 49, 83: 53, 115: 53, 66: 56, 90: 50, 122: 50]

    /// The view for text a recognizer read: in a word of digits and letters recognizers take for digits, those letters become
    /// the digits ("l23-45-6789", "4111 1lll 1111 1111"), and spaces it put around a dash, slash or at sign go.
    private static func lenientView(_ view: [UInt16], _ map: [Int]) -> (view: [UInt16], map: [Int]) {
        var chars = view
        let space: UInt16 = 32
        var start = 0
        while start < chars.count {
            if chars[start] == space {
                start += 1
                continue
            }
            var end = start
            while end < chars.count && chars[end] != space { end += 1 }
            var digits = 0, others = 0
            for i in start..<end {
                let c = chars[i]
                if isDigit(c) {
                    digits += 1
                } else if (PageText.isLetter(c) && slips[c] == nil) || c == 64 {
                    others += 1 // a letter no recognizer takes for a digit, or an at sign
                }
            }
            if digits >= 1 && others == 0 {
                for i in start..<end { if let d = slips[chars[i]] { chars[i] = d } }
            }
            start = end
        }
        func joins(_ before: UInt16, _ after: UInt16, _ afterThat: UInt16) -> Bool {
            if before == 64 || after == 64 { return true }
            if isDigit(before) && (after == 45 || after == 47) && (isDigit(afterThat) || afterThat == space) { return true }
            return (before == 45 || before == 47) && isDigit(after)
        }
        var out: [UInt16] = []
        var kept: [Int] = []
        out.reserveCapacity(chars.count)
        kept.reserveCapacity(chars.count)
        for i in 0..<chars.count {
            if chars[i] == space, let last = out.last {
                var next = i + 1
                while next < chars.count && chars[next] == space { next += 1 }
                if next < chars.count && joins(last, chars[next], next + 1 < chars.count ? chars[next + 1] : space) { continue }
            }
            out.append(chars[i])
            kept.append(map[i])
        }
        return (out, kept)
    }

    private static func isDash(_ c: UInt16) -> Bool { c == 45 || (0x2010...0x2015).contains(c) || c == 0x2212 || c == 0xFE63 || c == 0xFF0D }

    private static func isDigit(_ c: UInt16) -> Bool { c >= 48 && c <= 57 }

    private static func isFormat(_ c: UInt16) -> Bool { Unicode.Scalar(c)?.properties.generalCategory == .format }

    private static func isLetterOrDigit(_ c: UInt16) -> Bool {
        PageText.isLetter(c) || Unicode.Scalar(c)?.properties.numericType == .decimal
    }

    /// Where a rule's match ends once checked (a card or IBAN may lose groups that came after it), or nil.
    private static func accept(_ rule: Rule, _ m: NSTextCheckingResult, _ view: NSString, _ units: [UInt16], _ lenient: Bool) -> Int? {
        let start = m.range.location
        var end = start + m.range.length
        while true {
            let value = view.substring(with: NSRange(location: start, length: end - start))
            if rule.valid(m, view, value) || (lenient && rule.relaxed?(value) == true) { return end }
            if !rule.trim { return nil }
            // The last space or dash before the end (.NET's LastIndexOfAny over [start, end - 1]).
            var cut = end - 1
            while cut >= start && units[cut] != 32 && units[cut] != 45 { cut -= 1 }
            if cut <= start { return nil }
            end = cut
        }
    }

    // ---- The patterns ----

    /// `trim`: on a failed check, try again without the last group (a year or code printed after the number). `relaxed`:
    /// what counts on a recognized page, where one misread digit must not hide a number: no check digit.
    private struct Rule: Sendable {
        var pattern: RedactionPattern
        var regex: NSRegularExpression
        var valid: @Sendable (NSTextCheckingResult, NSString, String) -> Bool
        var trim = false
        var relaxed: (@Sendable (String) -> Bool)?
    }

    /// Which kind keeps text two kinds claim: checked numbers first, the loosest last.
    private static let strength: [RedactionPattern] = [.paymentCard, .iban, .socialSecurity, .email, .ipAddress, .phone, .date, .zipCode]

    // A number starts where no letter, digit or '@' comes before it, nor a digit and a dot or dash (it would be the tail
    // of a longer number), and ends the same way. A comma or slash between numbers is a list ("123-45-6789,987-65-4321",
    // a printed CSV), or a network's size after an address (10.0.0.1/24).
    private static let lead = #"(?<![\w@])(?<![0-9][.-])"#
    private static let trail = #"(?![\w@])(?![.-][0-9])"#
    // A date with numbers for its month ends only at a digit after its own separator: another separator between two dates
    // is a list or a range ("01/01/2025-12/31/2025").
    private static let dateLead = #"(?<![\w@])(?:(?=[0-9]{1,4}-)(?<![0-9]-)|(?=[0-9]{1,4}/)(?<![0-9]/)|(?=[0-9]{1,4}\.)(?<![0-9]\.))"#
    private static let dateTrail = #"(?![\w@])(?!\k<s>[0-9])"#
    private static let months = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?"
    private static let octet = "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])"

    private static func r(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private static func group(_ m: NSTextCheckingResult, _ view: NSString, _ name: String) -> String {
        let r = m.range(withName: name)
        return r.location == NSNotFound ? "" : view.substring(with: r)
    }

    private static func int(_ m: NSTextCheckingResult, _ view: NSString, _ name: String) -> Int { Int(group(m, view, name)) ?? 0 }

    private static let monthStarts = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    private static func month(_ m: NSTextCheckingResult, _ view: NSString) -> Int {
        let mon = group(m, view, "mon").lowercased()
        return (monthStarts.firstIndex { mon.hasPrefix($0) } ?? -1) + 1
    }

    private static func digits(_ value: String) -> String { String(value.unicodeScalars.filter { $0.value >= 48 && $0.value <= 57 }.map(Character.init)) }

    private static func isDay(_ year: Int, _ month: Int, _ day: Int) -> Bool {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1 else { return false }
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
        return day <= days
    }

    private static let rules: [Rule] = makeRules()

    private static func makeRules() -> [Rule] {
        var list: [Rule] = []
        list.append(Rule(pattern: .socialSecurity, regex: r(lead + #"(?<a>[0-9]{3})(?<s>[- ]?)(?<g>[0-9]{2})\k<s>(?<n>[0-9]{4})"# + trail)) { m, v, _ in
            let a = group(m, v, "a")
            return a != "000" && a != "666" && !a.hasPrefix("9") && group(m, v, "g") != "00" && group(m, v, "n") != "0000"
        })
        // North American: an optional +1, area code (in parentheses or not), exchange and line, or +1 and ten digits run together.
        list.append(Rule(pattern: .phone, regex: r(lead + #"(?:(?:\+?1[-. ]?)?(?:\([2-9][0-9]{2}\)[-. ]?|[2-9][0-9]{2}[-. ])[2-9][0-9]{2}[-. ][0-9]{4}|\+1[-. ]?[2-9][0-9]{2}[2-9][0-9]{6})"# + trail)) { _, _, _ in true })
        // International: + and a country code (not 1), then groups, maybe a trunk (0); 8 to 15 digits in all (E.164).
        list.append(Rule(pattern: .phone, regex: r(lead + #"\+[2-9][0-9]{0,2}(?:[-. ]?\(0\))?(?:[-. ]?\(?[0-9]{1,5}\)?){2,6}"# + trail)) { _, _, value in
            (8...15).contains(digits(value.replacingOccurrences(of: "(0)", with: "")).count)
        })
        list.append(Rule(pattern: .email, regex: r(#"(?<![\w.%+-])[\p{L}\p{N}._%+-]+@(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+\p{L}{2,24}(?![\w-])"#)) { _, _, value in
            !value.hasPrefix(".") && !value.contains("..") && !value.contains(".@")
        })
        // 13 to 19 digits run together, or in groups (4-4-4-4, 4-6-5, ...) split by spaces or dashes, all the same.
        list.append(Rule(pattern: .paymentCard, regex: r(lead + #"[2-6](?:[0-9]{12,18}|[0-9]{3}(?:[ -][0-9]{2,7}){2,4})"# + trail), valid: { _, _, value in
            let separators = Set(value.filter { $0 == " " || $0 == "-" })
            let d = digits(value)
            return separators.count <= 1 && (13...19).contains(d.count) && luhn(d)
        }, trim: true, relaxed: { value in [15, 16].contains(digits(value).count) }))
        list.append(Rule(pattern: .date, regex: r(dateLead + #"(?<y>(?:1[89]|2[0-9])[0-9]{2})(?<s>[-/.])(?<m>0?[1-9]|1[0-2])\k<s>(?<d>0?[1-9]|[12][0-9]|3[01])"# + dateTrail)) { m, v, _ in
            isDay(int(m, v, "y"), int(m, v, "m"), int(m, v, "d"))
        })
        // 10/27/2026 or 27.10.2026: month first or day first, whichever makes a date; two-digit years only with slashes.
        list.append(Rule(pattern: .date, regex: r(dateLead + #"(?<a>[0-9]{1,2})(?<s>[-/.])(?<b>[0-9]{1,2})\k<s>(?<y>[0-9]{4}|[0-9]{2})"# + dateTrail)) { m, v, _ in
            var y = int(m, v, "y")
            if group(m, v, "y").count == 2 { y = group(m, v, "s") == "/" ? 2000 + y : -1 }
            if y < 1800 || y > 2199 { return false }
            let a = int(m, v, "a"), b = int(m, v, "b")
            return isDay(y, a, b) || isDay(y, b, a)
        })
        list.append(Rule(pattern: .date, regex: r(#"(?<![\w])(?<mon>"# + months + #")\.? +(?<d>[0-9]{1,2})(?:st|nd|rd|th)?,? +(?<y>[0-9]{4})(?![\w])"#, ignoreCase: true)) { m, v, _ in
            isDay(int(m, v, "y"), month(m, v), int(m, v, "d"))
        })
        list.append(Rule(pattern: .date, regex: r(#"(?<![\w])(?<d>[0-9]{1,2})(?:st|nd|rd|th)? +(?:of +)?(?<mon>"# + months + #")\.?,? +(?<y>[0-9]{4})(?![\w])"#, ignoreCase: true)) { m, v, _ in
            isDay(int(m, v, "y"), month(m, v), int(m, v, "d"))
        })
        list.append(Rule(pattern: .zipCode, regex: r(lead + "[0-9]{5}(?:-[0-9]{4})?" + trail)) { _, _, value in !value.hasPrefix("00000") })
        // Two letters, two check digits, then up to 30 letters and digits, printed in groups of four or run together.
        list.append(Rule(pattern: .iban, regex: r(#"(?<![\w])[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![\w])"#), valid: { _, _, value in
            ibanValid(value.replacingOccurrences(of: " ", with: ""))
        }, trim: true, relaxed: { value in (15...34).contains(value.replacingOccurrences(of: " ", with: "").utf16.count) }))
        list.append(Rule(pattern: .ipAddress, regex: r(lead + "(?:\(octet)\\.){3}\(octet)" + trail)) { _, _, _ in true })
        // IPv6: hex groups and colons; written in full (eight groups) or shortened with "::".
        list.append(Rule(pattern: .ipAddress, regex: r(#"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"#)) { _, _, value in
            (value.contains("::") || value.filter { $0 == ":" }.count == 7) && value.contains(where: \.isHexDigit) && isIPv6(value)
        })
        return list
    }

    private static func isIPv6(_ value: String) -> Bool {
        var address = in6_addr()
        return value.withCString { inet_pton(AF_INET6, $0, &address) } == 1
    }

    /// The Luhn check digit of payment card numbers.
    static func luhn(_ digits: String) -> Bool {
        let d = digits.unicodeScalars.map { Int($0.value) - 48 }
        var sum = 0
        for i in 0..<d.count {
            var v = d[d.count - 1 - i]
            if i % 2 == 1 {
                v *= 2
                if v > 9 { v -= 9 }
            }
            sum += v
        }
        return sum % 10 == 0
    }

    /// ISO 13616: 15 to 34 characters, the first four moved to the end and letters as 10 to 35 leave 1 mod 97.
    static func ibanValid(_ iban: String) -> Bool {
        let u = Array(iban.utf16)
        guard (15...34).contains(u.count) else { return false }
        var rest = 0
        for c in u[4...] + u[..<4] {
            if c >= 48 && c <= 57 {
                rest = (rest * 10 + Int(c - 48)) % 97
            } else if c >= 65 && c <= 90 {
                rest = (rest * 100 + Int(c - 65 + 10)) % 97
            } else {
                return false
            }
        }
        return rest == 1
    }
}
