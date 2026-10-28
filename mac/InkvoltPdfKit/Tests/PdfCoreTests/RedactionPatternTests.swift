import Foundation
import Testing
@testable import PdfCore

/// Ported from RedactionPatternTests.cs. Adapted: the user's expression is ICU's syntax (NSRegularExpression), so a
/// bad one is described from ICU's error ("near character" kept); a pattern that takes too long throws
/// `RedactionSearchTimeout` (Windows: `TimeoutException` with a `RegexMatchTimeoutException` inside). Left out:
/// BatchRedactsPatternsInEveryFile (Batch comes with E8).
struct RedactionPatternTests {
    /// A page's text layer from lines of text: each character a 6 x 12 box, lines 14 points apart.
    static func page(_ lines: String...) -> PageText { page(lines) }

    static func page(_ lines: [String]) -> PageText {
        PageText(lines.enumerated().map { l, line in
            line.utf16.indices.enumerated().map { i, idx in
                (String(utf16CodeUnits: [line.utf16[idx]], count: 1), RectD(10 + 6 * Double(i), 20 + 14 * Double(l), 6, 12))
            }
        })
    }

    /// What one kind finds in a line (or lines) of text.
    static func found(_ pattern: RedactionPattern, _ lines: String...) throws -> [String] {
        try RedactionPatterns.find(page(lines), 0, RedactionPatternOptions(patterns: [pattern])).map(\.text)
    }

    static func finds(_ pattern: RedactionPattern, _ text: String, _ expected: String) throws {
        #expect(try found(pattern, "Value: \(text) here.") == [expected], "\(text)")
    }

    static func findsNothing(_ pattern: RedactionPattern, _ text: String) throws {
        #expect(try found(pattern, "Value: \(text) here.").isEmpty, "\(text)")
    }

    // ---- built-in kinds ----

    @Test(arguments: ["123-45-6789", "123 45 6789", "123456789", "078-05-1120"])
    func socialSecurityNumbers(_ ssn: String) throws { try Self.finds(.socialSecurity, ssn, ssn) }

    @Test(arguments: ["000-12-3456", "666-12-3456", "912-34-5678", "123-00-4567", "123-45-0000", "123-45 6789", "1234-56-7890",
                      "123-45-67890", "12345678", "A123-45-6789"])
    func socialSecurityNearMisses(_ text: String) throws { try Self.findsNothing(.socialSecurity, text) }

    @Test(arguments: ["(555) 201-3434", "(555)201-3434", "555-201-3434", "555.201.3434", "555 201 3434", "+1 555 201 3434",
                      "+1 (555) 201-3434", "1-800-555-0199", "+15552013434", "+44 20 7946 0958", "+44 (0)20 7946 0958", "+49 30 1234567",
                      "+33 1 23 45 67 89"])
    func phoneNumbers(_ phone: String) throws { try Self.finds(.phone, phone, phone) }

    @Test(arguments: ["555-201-343", "155-201-3434", "555-101-3434", "5552013434", "+44 12", "+44 1234 5678 9012 3456",
                      "4111 1111 1111 1111", "2026-10-27"])
    func phoneNearMisses(_ text: String) throws { try Self.findsNothing(.phone, text) }

    @Test(arguments: ["jane.doe+tag@mail.example.co.uk", "a@b.io", "José.Núñez@correo.es"])
    func emailAddresses(_ email: String) throws { try Self.finds(.email, email, email) }

    @Test(arguments: ["jane@", "@example.com", "jane@example", "jane..doe@example.com", ".jane@example.com"])
    func emailNearMisses(_ text: String) throws { try Self.findsNothing(.email, text) }

    @Test func anEmailEndsBeforeTheSentencesFullStop() throws {
        #expect(try Self.found(.email, "Write to jane@example.com.") == ["jane@example.com"])
    }

    @Test(arguments: ["4111 1111 1111 1111", "4111-1111-1111-1111", "4111111111111111", "3782 822463 10005", "5555 5555 5555 4444",
                      "6011 0009 9013 9424", "4222222222222"])
    func paymentCards(_ card: String) throws { try Self.finds(.paymentCard, card, card) }

    @Test(arguments: ["4111 1111 1111 1112", "4111 1111-1111 1111", "1234 5678 9012 3452", "4111 1111 1111", "41111111111111111111",
                      "4 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1"])
    func paymentCardNearMisses(_ text: String) throws { try Self.findsNothing(.paymentCard, text) }

    @Test func aCardFollowedByAnotherNumberStillCounts() throws {
        #expect(try Self.found(.paymentCard, "Card 4111 1111 1111 1111 2026 expires") == ["4111 1111 1111 1111"])
    }

    @Test(arguments: ["2026-10-27", "2026/10/27", "10/27/2026", "10/27/26", "27.10.2026", "27/10/2026", "2/29/2024", "October 27, 2026",
                      "Oct 27 2026", "Sept. 3, 2026", "27 Oct 2026", "27th of October 2026", "1st January 2027"])
    func dates(_ date: String) throws { try Self.finds(.date, date, date) }

    @Test(arguments: ["2026-02-30", "2/29/2026", "13/13/2026", "31.04.2026", "27.10.26", "1.2.3", "February 30, 2026", "Octopus 27, 2026",
                      "10/27/2026/5"])
    func dateNearMisses(_ text: String) throws { try Self.findsNothing(.date, text) }

    @Test func zipCodesOnlyWhenChosen() throws {
        #expect(!RedactionPatterns.defaults.contains(.zipCode))
        #expect(try RedactionPatterns.find(Self.page("Beverly Hills, CA 90210"), 0, RedactionPatternOptions()).isEmpty)
        #expect(try Self.found(.zipCode, "CA 90210 or 90210-1234") == ["90210", "90210-1234"])
        #expect(try Self.found(.zipCode, "00000, 902101, 9021, 90210-12").isEmpty)
    }

    @Test(arguments: ["DE89 3704 0044 0532 0130 00", "DE89370400440532013000", "GB82 WEST 1234 5698 7654 32", "GB82WEST12345698765432",
                      "FR14 2004 1010 0505 0001 3M02 606"])
    func ibans(_ iban: String) throws { try Self.finds(.iban, iban, iban) }

    @Test(arguments: ["DE89 3704 0044 0532 0130 01", "DE88 3704 0044 0532 0130 00", "GB82 WEST 1234"])
    func ibanNearMisses(_ text: String) throws { try Self.findsNothing(.iban, text) }

    @Test func anIbanFollowedByACurrencyStillCounts() throws {
        #expect(try Self.found(.iban, "Pay to DE89 3704 0044 0532 0130 00 EUR") == ["DE89 3704 0044 0532 0130 00"])
    }

    @Test(arguments: ["192.168.1.10", "10.0.0.1", "255.255.255.255", "2001:db8::1", "fe80::1ff:fe23:4567:890a", "2001:0db8:85a3:0000:0000:8a2e:0370:7334"])
    func ipAddresses(_ ip: String) throws { try Self.finds(.ipAddress, ip, ip) }

    @Test(arguments: ["256.1.1.1", "1.2.3", "192.168.1.10.5", "10:30:45", "::"])
    func ipNearMisses(_ text: String) throws { try Self.findsNothing(.ipAddress, text) }

    @Test func checkedNumbersWinOverLooserKinds() throws {
        // With every kind on, a card number is only a card number (not a phone number, ZIP code or date), and an SSN only an SSN.
        let all = RedactionPatternOptions(patterns: Set(RedactionPatterns.builtIn))
        let matches = try RedactionPatterns.find(Self.page("Card 4111 1111 1111 1111, SSN 123-45-6789, call 555-201-3434 on 10/27/2026."), 0, all)
        #expect(matches.map(\.pattern) == [.paymentCard, .socialSecurity, .phone, .date])
        #expect(matches.map(\.text) == ["4111 1111 1111 1111", "123-45-6789", "555-201-3434", "10/27/2026"])
        // In the order offered.
        #expect(RedactionPatterns.summary(matches) == "US Social Security numbers: 1, Phone numbers: 1, Payment card numbers: 1, Dates: 1")
    }

    // ---- line breaks ----

    @Test func matchesRunOntoTheNextLine() throws {
        let text = Self.page("SSN 123-45-", "6789 and phone (555) 201", "3434, born October", "27, 2026; card 4111 1111", "1111 1111 ok")
        let matches = try RedactionPatterns.find(text, 0, RedactionPatternOptions())
        #expect(matches.map(\.pattern) == [.socialSecurity, .phone, .date, .paymentCard])
        #expect(matches.map(\.text) == ["123-45-\n6789", "(555) 201\n3434", "October\n27, 2026", "4111 1111\n1111 1111"])
        #expect(matches.allSatisfy { $0.rects.count == 2 }) // one box per line
        let ssn = matches[0].rects
        #expect(abs(ssn[0].y - 20) < 0.001)
        #expect(abs(ssn[1].y - 34) < 0.001)
        #expect(abs(ssn[0].x - (10 + 6 * 4)) < 0.001) // starts at "123"
        #expect(abs(ssn[1].right - (10 + 6 * 4)) < 0.001) // ends after "6789"
    }

    // ---- the user's phrases and pattern ----

    @Test func phrasesMatchWholeWordsAndCaseAsAsked() throws {
        let text = Self.page("Acme Corp and ACME", "corporation; acmeville; Confi-", "dential")
        func phrases(_ wholeWord: Bool, _ matchCase: Bool, _ list: String...) throws -> [String] {
            try RedactionPatterns.find(text, 0, RedactionPatternOptions(patterns: [], phrases: list, wholeWord: wholeWord, matchCase: matchCase)).map(\.text)
        }
        #expect(try phrases(true, false, "acme") == ["Acme", "ACME"])
        #expect(try phrases(false, false, "acme") == ["Acme", "ACME", "acme"])
        #expect(try phrases(true, true, "Acme") == ["Acme"])
        #expect(try phrases(true, false, "acme corporation") == ["ACME\ncorporation"]) // across a line break
        #expect(try phrases(true, false, "Confidential") == ["Confi-\ndential"]) // hyphenated across a line
        #expect(try phrases(true, true, "Acme", "  ", "Acme") == ["Acme"]) // blanks and repeats ignored
        #expect(RedactionPatternOptions(patterns: [], phrases: [" "]).isEmpty)
    }

    @Test func theUsersExpression() throws {
        let text = Self.page("Files CASE-0412 and case-0001,", "not CASE-12.")
        func run(_ matchCase: Bool) throws -> [RedactionMatch] {
            try RedactionPatterns.find(text, 0, RedactionPatternOptions(patterns: [], matchCase: matchCase, expression: #"CASE-\d{4}"#))
        }
        #expect(try run(false).map(\.text) == ["CASE-0412", "case-0001"])
        #expect(try run(true).map(\.text) == ["CASE-0412"])
        #expect(try run(false).allSatisfy { $0.pattern == .expression })

        // Line breaks read as spaces.
        let broken = try RedactionPatterns.find(Self.page("Account", "No. 77"), 0, RedactionPatternOptions(patterns: [], expression: #"Account No\. \d+"#))
        #expect(broken.map(\.text) == ["Account\nNo. 77"])
    }

    @Test func aBadExpressionIsReportedInPlainWords() throws {
        #expect(RedactionPatterns.validateExpression(nil) == nil)
        #expect(RedactionPatterns.validateExpression(#"\bCASE-\d+"#) == nil)
        #expect(RedactionPatterns.validateExpression("CASE-(")?.contains("near character") == true)
        #expect(RedactionPatterns.validateExpression("[a-")?.contains("near character") == true)
        #expect(RedactionPatterns.validateExpression("x*")?.contains("empty text") == true)
        #expect(throws: PdfEditError.self) { try RedactionPatterns.find(Self.page("text"), 0, RedactionPatternOptions(expression: "(")) }
    }

    @Test func aPathologicalExpressionTimesOutCleanly() throws {
        let text = Self.page(String(repeating: "x", count: 40), "and more " + String(repeating: "x", count: 40))
        let options = RedactionPatternOptions(patterns: [], expression: "(x+x+)+y")
        let clock = ContinuousClock.now
        var error: RedactionSearchTimeout?
        do {
            _ = try RedactionPatterns.find(text, 4, options)
        } catch let e as RedactionSearchTimeout {
            error = e
        }
        #expect(ContinuousClock.now - clock < .seconds(15))
        #expect(error?.message.contains("page 5") == true)
        #expect(error?.userExpression == true)
    }

    // ---- documents ----

    /// A PDF with the given lines of Helvetica text on each page.
    static func pdf(_ pages: [[String]]) -> [UInt8] {
        let n = pages.count
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [\((0..<n).map { "\(3 + $0) 0 R" }.joined(separator: " "))] /Count \(n) >>",
        ]
        let font = 3 + 2 * n
        for p in 0..<n {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents \(3 + n + p) 0 R /Resources << /Font << /F1 \(font) 0 R >> >> >>")
        }
        for lines in pages {
            var content = ""
            for (l, line) in lines.enumerated() {
                let escaped = line.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)")
                content += "BT /F1 14 Tf 72 \(700 - 24 * l) Td (\(escaped)) Tj ET\n"
            }
            objects.append(Core2Pdf.stream(content))
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
        return Core2Pdf.build(objects)
    }

    static func text(_ pdf: [UInt8], _ page: Int) throws -> String {
        let engine = try PdfEngine.open(pdf)
        defer { engine.close() }
        return try engine.text(page).text
    }

    @Test func onlyTheChosenPagesAreSearched() throws {
        let data = Self.pdf([["Mail one@example.com"], ["Mail two@example.com"], ["Mail three@example.com"]])
        let engine = try PdfEngine.open(data)
        defer { engine.close() }
        var progress: [(Int, Int)] = []
        let all = try RedactionPatterns.find(engine, RedactionPatternOptions()) { progress.append(($0, $1)) }
        #expect(all.map(\.page) == [0, 1, 2])
        #expect(all.map(\.text) == ["one@example.com", "two@example.com", "three@example.com"])
        #expect(progress.map(\.0) == [1, 2, 3] && progress.allSatisfy { $0.1 == 3 })

        let some = try RedactionPatterns.find(engine, RedactionPatternOptions(pages: [2, 1, 2, 9]))
        #expect(some.map(\.page) == [1, 2])

        let parsed = PageRange.tryParse("2", engine.pageCount)
        #expect(parsed.ok)
        #expect(try RedactionPatterns.find(engine, RedactionPatternOptions(pages: parsed.pages)).map(\.text) == ["two@example.com"])
    }

    @Test func redactingRemovesTheMatchesForGoodAndLeavesTheRest() throws {
        let data = Self.pdf([
            ["Public heading", "Contact jane.doe@example.com today", "SSN 123-45-", "6789 on file"],
            ["Second page stays: no numbers here"],
        ])
        #expect(try Self.text(data, 0).contains("jane.doe@example.com"))
        let heading = try Core2RedactionTests.area(data, "Public heading")

        let (redacted, matches) = try RedactionPatterns.redact(data, nil, RedactionPatternOptions())
        #expect(matches.map(\.pattern) == [.email, .socialSecurity])
        #expect(matches.reduce(0) { $0 + $1.rects.count } == 3) // the SSN runs over two lines

        let after = try Self.text(redacted, 0)
        for secret in ["jane.doe", "example.com", "123-45", "6789"] { #expect(!after.contains(secret), "\(secret)") }
        #expect(try Self.text(redacted, 1) == "Second page stays: no numbers here") // a page without matches keeps its text
        for m in matches {
            for r in m.rects { #expect(try Core2Pdf.ink(redacted, 0, r.inflate(-1)) > 0.95, "\(m.pattern) blacked out") }
        }
        #expect(try Core2Pdf.ink(redacted, 0, heading) > 0.05, "the heading still shows")
        #expect(try Core2Pdf.ink(redacted, 0, heading) < 0.6, "and isn't blacked out")

        // Nothing found: the file is left as it was.
        let (same, none) = try RedactionPatterns.redact(data, nil, RedactionPatternOptions(patterns: [.iban]))
        #expect(none.isEmpty)
        #expect(same == data)
    }
}
