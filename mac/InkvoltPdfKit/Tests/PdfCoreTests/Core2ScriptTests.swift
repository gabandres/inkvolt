import Foundation
import Testing
@testable import PdfCore

/// Ported from Core2ScriptTests.cs, whole: the parsed fast paths of form scripts (calculations, formats, numbers).
struct Core2ScriptTests {
    static let values: [String: [String]] = ["a": ["10"], "b": ["2.5"], "c": [""], "row.1": ["1"], "row.2": ["4"]]

    static func lookup(_ name: String) -> [String] {
        values[name] ?? values.filter { $0.key.hasPrefix(name + ".") }.sorted { $0.key < $1.key }.flatMap(\.value)
    }

    @Test(arguments: [
        ("AFSimple_Calculate(\"SUM\", new Array(\"a\", \"b\"));", 12.5),
        ("AFSimple_Calculate('PRD', ['a', 'b'])", 25),
        ("AFSimple_Calculate(\"AVG\", new Array(\"a\", \"b\", \"c\"));", 12.5 / 3),
        ("AFSimple_Calculate(\"MIN\", \"a, b\");", 2.5),
        ("AFSimple_Calculate(\"MAX\", new Array(\"a\", \"b\"));", 10),
        ("AFSimple_Calculate(\"SUM\", new Array(\"row\"));", 5),
        ("event.value = this.getField(\"a\").value * this.getField(\"b\").value;", 25),
        ("var x = getField(\"a\").value; var y = getField(\"b\").value; event.value = (x + y) / 5 - -1;", 3.5),
        ("event.value = Math.round(AFMakeNumber(getField(\"b\").value)) % 2 // comment", 1),
        ("/* total */ event.value = Math.max(getField(\"a\").value, 99);", 99),
    ] as [(String, Double)])
    func evaluatesCommonCalculations(_ script: String, _ expected: Double) throws {
        let calc = try #require(FormScripts.parseCalculation(script))
        #expect(near(try #require(calc.evaluate(Self.lookup)), expected, 6))
    }

    @Test(arguments: ["if (x > 1) event.value = 2;", "event.value = util.printf('%d', 3);", "app.alert('hi');", "var x = 1;", ""])
    func ignoresScriptsItCannotRun(_ script: String) {
        #expect(FormScripts.parseCalculation(script) == nil)
    }

    @Test func hostileScriptsNeitherCrashNorThrow() throws {
        // Each of these would overflow the stack while parsing or evaluating if not refused.
        #expect(FormScripts.parseCalculation("event.value = " + String(repeating: "-", count: 200_000) + "1;") == nil)
        #expect(FormScripts.parseCalculation("event.value = " + String(repeating: "(", count: 200_000) + "1" + String(repeating: ")", count: 200_000) + ";") == nil)
        #expect(FormScripts.parseCalculation("event.value = 1" + String(repeating: "+1", count: 200_000) + ";") == nil)
        #expect(try #require(FormScripts.parseCalculation("event.value = ((1 + 2));")).evaluate { _ in [] } == 3)
        #expect(FormScripts.parseFormat("AFNumber_Format(1.2.3, 0, 0, 0, \"\", true);") == nil)
    }

    @Test func reportsInputs() throws {
        #expect(try #require(FormScripts.parseCalculation("AFSimple_Calculate(\"SUM\", new Array(\"a\", \"b\"));")).inputs == ["a", "b"])
    }

    @Test(arguments: [
        ("AFNumber_Format(2, 0, 0, 0, \"$\", true);", "1234.5", "$1,234.50", false),
        ("AFNumber_Format(2, 2, 0, 0, \" €\", false);", "1234.5", "1.234,50 €", false),
        ("AFNumber_Format(0, 1, 2, 0, \"\", true);", "-42.4", "(42)", false),
        ("AFNumber_Format(1, 0, 3, 0, \"\", true);", "-1000", "(1,000.0)", true),
        ("AFNumber_Format(1, 0, 1, 0, \"\", true);", "-5", "5.0", true),
        ("AFNumber_Format(2, 0, 0, 0, \"$\", true);", "-3", "-$3.00", false),
        ("AFNumber_Format(2, 0, 0, 0, \"$\", true);", "abc", "abc", false),
        ("AFPercent_Format(1, 0);", "0.256", "25.6%", false),
        ("AFDate_FormatEx(\"dd mmm yyyy\");", "2026-03-07", "07 Mar 2026", false),
        ("AFDate_FormatEx(\"mm/dd/yyyy\");", "3/7/2026", "03/07/2026", false),
        ("AFDate_Format(10);", "2026-03-07", "Mar 7, 2026", false),
        ("AFDate_FormatEx(\"yyyy-mm-dd HH:MM\");", "2026-03-07T14:05:00", "2026-03-07 14:05", false),
        ("AFSpecial_Format(2);", "7875551234", "(787) 555-1234", false),
        ("AFSpecial_Format(3);", "123456789", "123-45-6789", false),
        ("AFNumber_Format(2, 0, 0, 0, \"$\", true);", "", "", false),
    ] as [(String, String, String, Bool)])
    func formatsValues(_ script: String, _ raw: String, _ expected: String, _ red: Bool) throws {
        let fmt = try #require(FormScripts.parseFormat(script))
        let (text, isRed) = FormScripts.format(fmt, raw)
        #expect(text == expected)
        #expect(isRed == red)
    }

    @Test(arguments: [("1,234.50", 1234.5), ("1.234,50", 1234.5), ("3,5", 3.5), ("$ 12", 12), ("(7)", -7), ("-0.25", -0.25)] as [(String, Double)])
    func makesNumbers(_ text: String, _ expected: Double) {
        #expect(FormScripts.toNumber(text) == expected)
    }

    @Test func nonNumbersAreNull() {
        #expect(FormScripts.toNumber("") == nil)
        #expect(FormScripts.toNumber("n/a") == nil)
        #expect(FormScripts.numberToValue(0.1 + 0.2) == "0.3")
    }
}
