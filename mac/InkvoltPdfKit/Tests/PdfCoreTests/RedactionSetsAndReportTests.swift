import Foundation
import Testing
@testable import PdfCore
import PrintCore

/// Ported from RedactionSetsAndReportTests.cs (same names): saved pattern sets (a tampered file is refused, never half
/// used), masked values, the CSV report, the Pro split. Adapted: in `ProGated` (Windows' "Pro" collection); a set's file
/// name is checked against `ReservedFileNames` (Windows' `DeviceNames`); the set's error is `RedactionPatternSetError`; the
/// catastrophic pattern ends in `RedactionSearchTimeout`; the CSV reads through the Mac's `Csv`.
extension ProGated {
@Suite final class RedactionSetsAndReportTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-redact-sets-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        Pro.enforced = false
        try? FileManager.default.removeItem(atPath: root)
    }

    private static let sample = RedactionPatternOptions(patterns: [.email, .zipCode], phrases: ["Acme Corp", "Zoë Núñez"], wholeWord: false,
                                                        matchCase: true, expression: #"CASE-\d{4}"#)

    private func files() -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? [] }

    // ---- saved sets ----

    @Test func aSetRoundTripsOnThePc() throws {
        let path = try RedactionPatternSets.save(RedactionPatternSet("Legal team", Self.sample), root)
        #expect((path as NSString).lastPathComponent == "Legal team.json")
        let back = try RedactionPatternSets.load(path)
        #expect(back.name == "Legal team")
        #expect(back.options.setName == "Legal team")
        #expect(back.options.patterns == Self.sample.patterns)
        #expect(back.options.phrases == Self.sample.phrases)
        #expect(!back.options.wholeWord)
        #expect(back.options.matchCase)
        #expect(back.options.expression == Self.sample.expression)

        let (sets, problems) = RedactionPatternSets.list(root)
        #expect(sets.map(\.name) == ["Legal team"])
        #expect(problems.isEmpty)
        #expect(!files().contains { $0.hasSuffix(".tmp") })

        RedactionPatternSets.delete("Legal team", root)
        #expect(RedactionPatternSets.list(root).sets.isEmpty)
    }

    @Test(arguments: [#"..\..\evil"#, "a/b:c*d?", "CON", "nul", "LPT1", "COM¹", "lpt³", "CONIN$", "com0", "..."])
    func aSetsNameNeverEscapesItsFolderOrNamesADevice(_ name: String) throws {
        let file = RedactionPatternSets.fileName(name)
        #expect(file == (file as NSString).lastPathComponent)
        #expect(!String(file.dropLast(5)).contains(".."))
        #expect(!file.contains("/"))
        #expect(!ReservedFileNames.isDevice(file))
        let stem = (file as NSString).deletingPathExtension.uppercased()
        #expect(!["CON", "NUL", "LPT1", "..."].contains(stem))
        let path = try RedactionPatternSets.save(RedactionPatternSet(name, Self.sample), root)
        #expect(URL(fileURLWithPath: path).deletingLastPathComponent().standardizedFileURL.path == URL(fileURLWithPath: root).standardizedFileURL.path)
    }

    @Test func twoNamesDontLandOnOneFile() {
        #expect(RedactionPatternSets.fileName("a/b") != RedactionPatternSets.fileName("a:b"))
    }

    static let tampered: [(String, String)] = [
        ("not json at all {", "isn't valid JSON"),
        ("[1, 2, 3]", "isn't a set"),
        ("{}", "\"format\" is missing"),
        (#"{"format":"something else","version":1,"name":"x"}"#, "isn't a set of redaction patterns"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":99,"name":"x"}"#, "newer version"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email","launchMissiles"]}"#, "doesn't know"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":"email"}"#, "should be a list"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","phrases":[1]}"#, "should list text"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email"],"wholeWord":"yes"}"#, "true or false"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email"],"expression":"("}"#, "mistake"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email"],"expression":"x*"}"#, "empty text"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x"}"#, "nothing to look for"),
        (#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"  ","kinds":["email"]}"#, "no name"),
    ]

    @Test(arguments: tampered)
    func aTamperedSetIsRefusedWhole(_ json: String, _ why: String) throws {
        let path = (root as NSString).appendingPathComponent("tampered.json")
        try json.write(toFile: path, atomically: true, encoding: .utf8)
        do {
            _ = try RedactionPatternSets.load(path)
            Issue.record("loaded")
        } catch let e as RedactionPatternSetError {
            #expect(e.message.contains(why), "\(e.message)")
        }
        let (sets, problems) = RedactionPatternSets.list(root)
        #expect(sets.isEmpty)
        #expect(problems.count == 1 && problems[0].contains(why), "\(problems)")
    }

    private static func refusal(_ read: () throws -> RedactionPatternSet) -> String {
        do {
            _ = try read()
            return "(read)"
        } catch let e as RedactionPatternSetError {
            return e.message
        } catch {
            return "\(error)"
        }
    }

    @Test func anOversizedOrOverDeepOrOverLongSetIsRefused() throws {
        let big = (root as NSString).appendingPathComponent("big.json")
        try Data(count: RedactionPatternSets.maxBytes + 1).write(to: URL(fileURLWithPath: big))
        #expect(Self.refusal { try RedactionPatternSets.load(big) }.contains("too large"))
        try FileManager.default.removeItem(atPath: big)

        let deep = String(repeating: "[", count: 5000) + String(repeating: "]", count: 5000)
        #expect(throws: RedactionPatternSetError.self) { try RedactionPatternSets.read(deep, "deep.json") }

        func set(_ extra: String) -> String { #"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","# + extra + "}" }
        let longExpression = set("\"expression\":\"\(String(repeating: "a", count: RedactionPatterns.maxExpressionLength + 1))\"")
        #expect(Self.refusal { try RedactionPatternSets.read(longExpression, "x.json") }.contains("too long"))
        let longPhrase = set("\"phrases\":[\"\(String(repeating: "a", count: RedactionPatterns.maxPhraseLength + 1))\"]")
        #expect(Self.refusal { try RedactionPatternSets.read(longPhrase, "x.json") }.contains("too long"))
        let many = Array(repeating: "\"a\"", count: RedactionPatterns.maxPhrases + 1).joined(separator: ",")
        #expect(Self.refusal { try RedactionPatternSets.read(set("\"phrases\":[\(many)]"), "x.json") }.contains("too many"))
    }

    @Test func aCatastrophicPatternInASavedSetCanLoadButEndsInAnErrorWhenRun() throws {
        let set = try RedactionPatternSets.read(#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","expression":"(x+x+)+y"}"#, "x.json")
        let text = PageText([Array(repeating: ("x", RectD(0, 0, 1, 1)), count: 40)])
        var options = set.options
        options.patterns = []
        #expect(throws: RedactionSearchTimeout.self) { try RedactionPatterns.find(text, 0, options) }
    }

    @Test func aControlCharacterInASetsNameIsntShown() throws {
        let set = try RedactionPatternSets.read(#"{"format":"Inkvolt PDF redaction patterns","version":1,"name":"Le‮gal\u0007","kinds":["email"]}"#, "x.json")
        #expect(set.name == "Legal")
    }

    @Test func anUnsavedSetWithAProblemIsntWritten() {
        #expect(throws: RedactionPatternSetError.self) { try RedactionPatternSets.save(RedactionPatternSet("x", RedactionPatternOptions(expression: "(")), self.root) }
        #expect(throws: RedactionPatternSetError.self) { try RedactionPatternSets.save(RedactionPatternSet("  ", Self.sample), self.root) }
        #expect(throws: RedactionPatternSetError.self) { try RedactionPatternSets.save(RedactionPatternSet("x", RedactionPatternOptions(patterns: [])), self.root) }
        #expect(files().isEmpty)
    }

    // ---- masks ----

    @Test(arguments: [
        (RedactionPattern.socialSecurity, "123-45-6789", "***-**-**89"),
        (.socialSecurity, "123456789", "***-**-**89"),
        (.paymentCard, "4111 1111 1111 1111", "**** **** **** **11"),
        (.paymentCard, "3782 822463 10005", "**** **** **** **05"),
        (.phone, "(555) 201-3434", "***-***-**34"),
        (.phone, "+49 30 1234", "***"), // too short to keep anything
        (.iban, "DE89 3704 0044 0532 0130 00", "**** **** **00"),
        (.email, "jane.doe@example.com", "***@***"),
        (.date, "October 27, 2026", "**/**/****"),
        (.zipCode, "90210", "***"),
        (.ipAddress, "192.168.1.10", "***.***"),
        (.phrase, "Bob", "***"),
        (.phrase, "Quillfeather Holdings 123456789", "***"),
        (.expression, "CASE-0412", "***"),
    ])
    func aMaskGivesLittleAway(_ kind: RedactionPattern, _ value: String, _ mask: String) {
        #expect(RedactionReport.mask(kind, value) == mask)
    }

    @Test func aMaskDoesntKeepTheLengthOfAFreeFormValue() {
        #expect(RedactionReport.mask(.phrase, "Al") == RedactionReport.mask(.phrase, "Maximiliano Fernandez de la Cruz"))
    }

    // ---- the CSV ----

    private static func file1(_ name: String, _ kind: RedactionPattern = .socialSecurity, _ value: String = "123-45-6789") -> RedactionFileReport {
        RedactionFileReport(name, [RedactionRemoval(2, kind, RedactionReport.mask(kind, value), .removed)], [RedactionLook(4, .scanReadByOcr, [])], nil)
    }

    @Test(arguments: ["=cmd|' /C calc'!A0.pdf", "+1+1.pdf", "-2+3.pdf", "@SUM(A1).pdf", " =spaced.pdf", "\t=tabbed.pdf", "\r\n=newline.pdf", "＝wide.pdf", "|pipe.pdf"])
    func aCellCantRunAsAFormula(_ fileName: String) throws {
        let csv = Csv.decode(RedactionReport([Self.file1(fileName)]).csv())
        for row in try Csv.read(csv).dropFirst() {
            for cell in row {
                let t = cell.drop { $0.isWhitespace && $0 != "\t" }
                let starts = t.first.map { "=+-@|＝\t".contains($0) } ?? false
                #expect(!starts, "Cell starts a formula: \(cell)")
                #expect(!cell.contains("\n"))
            }
        }
    }

    @Test func theSharedCsvGuardsADashToo() throws {
        #expect(Csv.quote("-2+3") == "\"\t-2+3\"")
        #expect(Csv.quote("-2.5") == "-2.5") // a plain number stays one
        #expect(try Csv.read(Csv.quote("-2+3") + ",x")[0][0] == "-2+3")
    }

    @Test func theReportHasEveryPartAndNoValueOrPhraseOrPattern() throws {
        let run = RedactionMatch(page: 0, pattern: .phrase, start: 0, end: 9, text: "Secret Co", rects: [RectD(0, 0, 1, 1)])
        let regex = RedactionMatch(page: 0, pattern: .expression, start: 0, end: 9, text: "CASE-0412", rects: [RectD(0, 0, 1, 1)])
        let report = RedactionReport([
            RedactionFileReport("a.pdf", [RedactionReport.row(run, .removed), RedactionReport.row(regex, .kept)], [RedactionLook(4, .scanReadByOcr, [RectD(1, 1, 2, 2)])], nil),
            RedactionFileReport("b.pdf", [], [], "Read back after redacting: 1 match is still there"),
        ])
        let csv = Csv.decode(report.csv())
        #expect(!csv.contains("Secret"))
        #expect(!csv.contains("CASE-"))
        #expect(!csv.contains(#"\d"#))
        let rows = try Csv.read(csv)
        #expect(rows.contains { $0 == ["a.pdf", "1", "Your words and phrases", "***", "Removed"] })
        #expect(rows.contains { $0 == ["a.pdf", "1", "Your pattern", "***", "Kept by you"] })
        #expect(rows.contains { $0[0] == "a.pdf" && $0[1] == "5" && $0[4] == "Look by hand" && $0[2].contains("1 place has ink") })
        #expect(rows.contains { $0[0] == "b.pdf" && $0[4].hasPrefix("Failed: Read back") })
        #expect(report.hasFailures)
        #expect(report.hasLooks)
    }

    @Test func aLookNeverCallsAPageClean() {
        for reason in RedactionLookReason.allCases {
            let text = RedactionLook(0, reason, []).text.lowercased()
            #expect(!text.contains("clean"))
            #expect(!text.contains("nothing found"))
        }
    }

    // ---- Free and Pro ----

    @Test func batchRedactionIsProAndPlainPatternSearchIsnt() throws {
        let plan = BatchPlan(steps: [.redactPatterns(RedactionPatternOptions())], outputFolder: root)
        Pro.store = MemoryProStore()
        Pro.enforced = false
        #expect(plan.validate(ocrAvailable: false) == nil) // the gate is off

        Pro.enforced = true
        defer { Pro.enforced = false }
        #expect(!Pro.allows(.patternRedaction))
        #expect(plan.validate(ocrAvailable: false) == Pro.locked(.patternRedaction))
        // The built-in kinds on one document stay free: nothing in Core locks them.
        #expect(try RedactionPatterns.find(RedactionPatternTests.page("123-45-6789"), 0, RedactionPatternOptions()).count == 1)
    }
}
}
