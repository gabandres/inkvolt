import Darwin
import Foundation
import Testing
@testable import PdfCore

/// Ported from JsFormTests.cs, whole: AcroForm JavaScript through the sandbox (`FormEditor.fill` and `read`), on
/// JavaScriptCore where Windows runs Jint. Adapted: HugeStringsAreRefusedBeforeTheyAreAllocated measures the process's
/// memory footprint around the fill (.NET counts the thread's allocations); the hostile scripts that reach for .NET
/// (System.IO, importNamespace, the CLR through constructor.constructor) are kept: they find nothing here either.
struct JsFormTests {
    static let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"

    struct F {
        var name: String
        var rect: String
        var scripts: [(String, String)] = []
        var extra = ""
        init(_ name: String, _ rect: String, _ scripts: [(String, String)] = [], _ extra: String = "") {
            self.name = name
            self.rect = rect
            self.scripts = scripts
            self.extra = extra
        }
    }

    /// A one-page form whose scripts (/AA key → JS) live in streams; optional document-level scripts and /CO.
    static func form(_ fields: [F], docScripts: [String] = [], co: [String]? = nil) -> [UInt8] {
        var more: [String] = []
        let first = 5 + fields.count
        func add(_ body: String) -> Int {
            more.append(body)
            return first + more.count - 1
        }
        var defs: [String] = []
        for f in fields {
            var aa = ""
            for (key, js) in f.scripts { aa += "/\(key) << /S /JavaScript /JS \(add(Core2Pdf.stream(js))) 0 R >> " }
            defs.append("<< \(w) /FT /Tx /T (\(f.name)) /Rect [\(f.rect)] /DA (/Helv 10 Tf 0 g) \(f.extra) \(aa.isEmpty ? "" : "/AA << \(aa)>>") >>")
        }
        var catalog = ""
        if !docScripts.isEmpty {
            var entries: [String] = []
            for (i, js) in docScripts.enumerated() {
                let stream = add(Core2Pdf.stream(js))
                entries.append("(s\(i)) \(add("<< /S /JavaScript /JS \(stream) 0 R >>")) 0 R")
            }
            catalog = "/Names << /JavaScript << /Names [\(entries.joined(separator: " "))] >> >>"
        }
        let coRefs = co.map { names in "/CO [" + names.map { n in "\(5 + fields.firstIndex { $0.name == n }!) 0 R" }.joined(separator: " ") + "]" } ?? ""
        return Core2Pdf.form(defs, acroExtra: coRefs, catalogExtra: catalog, more: more)
    }

    static func rect(_ row: Int) -> String { "72 \(700 - row * 30) 250 \(720 - row * 30)" }

    static func valueOf(_ data: [UInt8], _ name: String) throws -> String {
        try #require(try FormEditor.read(data, nil).first { $0.fieldName == name }).value
    }

    static func fill(_ form: [UInt8], _ values: (String, String)...) throws -> FormFillResult {
        try FormEditor.fill(form, nil, Dictionary(values, uniquingKeysWith: { $1 }))
    }

    @Test func customCalculationRunsInJavaScript() throws {
        let form = Self.form([
            F("a", Self.rect(0)),
            F("b", Self.rect(1), [("C", "event.value = this.getField(\"a\").value * 2")]),
            // Beyond the parsed fast path: control flow and string methods.
            F("c", Self.rect(2), [("C", "var v = getField('a').value; if (v > 10) { event.value = 'big:' + String(v).padStart(4, '0'); } else event.value = 'small';")]),
        ], co: ["b", "c"])
        let r = try Self.fill(form, ("a", "21"))
        #expect(r.rejected.isEmpty)
        #expect(try Self.valueOf(r.data, "b") == "42")
        #expect(try Self.valueOf(r.data, "c") == "big:0021")
        #expect(try FormEditor.read(r.data, nil).first { $0.fieldName == "c" }?.calculated == true)
    }

    @Test func formatScriptsRunThroughJavaScript() throws {
        let form = Self.form([
            F("amount", Self.rect(0), [("F", "AFNumber_Format(2, 0, 0, 0, \"$\", true); event.value = event.value + ' USD';")]),
            F("plain", Self.rect(1), [("F", "AFNumber_Format(2, 0, 0, 0, \"$\", true);")]),
            F("when", Self.rect(2), [("F", "AFDate_FormatEx('dd mmm yyyy');")]),
            F("phone", Self.rect(3), [("F", "AFSpecial_Format(2);")]),
            F("time", Self.rect(4), [("F", "AFTime_Format(1);")]),
            F("pct", Self.rect(5), [("F", "AFPercent_Format(1, 0);")]),
        ])
        let r = try Self.fill(form, ("amount", "1234.5"), ("plain", "-3"), ("when", "2026-03-07"), ("phone", "7875551234"), ("time", "14:05"), ("pct", "0.256"))
        let widgets = try FormEditor.read(r.data, nil)
        func shown(_ n: String) -> String? { widgets.first { $0.fieldName == n }?.displayValue }
        #expect(shown("amount") == "$1,234.50 USD")
        #expect(shown("plain") == "-$3.00")
        #expect(shown("when") == "07 Mar 2026")
        #expect(shown("phone") == "(787) 555-1234")
        #expect(shown("time") == "2:05 pm")
        #expect(shown("pct") == "25.6%")
        #expect(try Core2Pdf.allText(Core2Pdf.withoutNeedAppearances(r.data)).contains("$1,234.50 USD"))
    }

    @Test func keystrokeScriptsCanRejectOrAdjustACommittedValue() throws {
        let form = Self.form([
            F("n", Self.rect(0), [("K", "AFNumber_Keystroke(2, 0, 0, 0, '', true);")], "/V (5)"),
            F("code", Self.rect(1), [("K", "if (event.willCommit) { if (event.value.length > 3) { app.alert('Three letters at most.'); event.rc = false; } else event.value = event.value.toUpperCase(); }")]),
            F("zip", Self.rect(2), [("K", "AFSpecial_Keystroke(0);")]),
            F("date", Self.rect(3), [("K", "AFDate_KeystrokeEx('mm/dd/yyyy');")]),
        ])
        var r = try Self.fill(form, ("n", "abc"))
        #expect(r.data == form) // nothing else changed: no new document
        try #require(r.rejected.count == 1)
        #expect(r.rejected[0].fieldName == "n")
        #expect(r.rejected[0].message.contains("does not match the format of the field [ n ]"))

        r = try Self.fill(form, ("n", "1,234.5"), ("code", "abcd"), ("zip", "123"), ("date", "02/30/2026"))
        #expect(r.rejected.map(\.fieldName).sorted() == ["code", "date", "zip"])
        #expect(r.rejected.first { $0.fieldName == "code" }?.message == "Three letters at most.")
        #expect(try Self.valueOf(r.data, "n") == "1,234.5")
        #expect(try Self.valueOf(r.data, "code") == "")

        r = try Self.fill(form, ("code", "abc"), ("zip", "00901"), ("date", "03/07/2026"))
        #expect(r.rejected.isEmpty)
        #expect(try Self.valueOf(r.data, "code") == "ABC")
        #expect(try Self.valueOf(r.data, "zip") == "00901")
    }

    @Test func validateScriptsCanRejectAValue() throws {
        let form = Self.form([
            F("pct", Self.rect(0), [("V", "AFRange_Validate(true, 0, true, 100);")]),
            F("even", Self.rect(1), [("V", "if (event.value % 2) { app.alert({ cMsg: 'Even numbers only', nIcon: 0 }); event.rc = false; }")]),
            F("total", Self.rect(2), [("C", "AFSimple_Calculate('SUM', ['pct', 'even']);")]),
        ])
        var r = try Self.fill(form, ("pct", "150"), ("even", "3"))
        #expect(r.rejected.count == 2)
        #expect(r.rejected.first { $0.fieldName == "pct" }?.message
            == "The value entered must be greater than or equal to 0 and less than or equal to 100.")
        #expect(r.rejected.first { $0.fieldName == "even" }?.message == "Even numbers only")

        r = try Self.fill(form, ("pct", "50"), ("even", "4"))
        #expect(r.rejected.isEmpty)
        #expect(try Self.valueOf(r.data, "total") == "54")
    }

    @Test func documentScriptsDefineHelpersAndAlertsAreCollected() throws {
        let form = Self.form([
            F("a", Self.rect(0)),
            F("b", Self.rect(1), [("C", "event.value = twice(getField('a').value); if (event.value > 100) app.alert('Over ' + LIMIT);")]),
            F("c", Self.rect(2)),
            F("d", Self.rect(3), [("C", "getField('c').display = getField('b').value > 100 ? display.hidden : display.visible; console.println('a=' + getField('a').value);")]),
        ], docScripts: ["function twice(x) { return x * 2; }", "var LIMIT = 100; app.alert('opening');"])
        var r = try Self.fill(form, ("a", "60"))
        #expect(try Self.valueOf(r.data, "b") == "120")
        #expect(r.alerts == ["Over 100"]) // the document script's own alert isn't the user's doing
        #expect(r.log.contains("console: a=60"))
        #expect(!(try FormEditor.read(r.data, nil)).contains { $0.fieldName == "c" })

        r = try Self.fill(r.data, ("a", "7"))
        #expect(try FormEditor.read(r.data, nil).contains { $0.fieldName == "c" })
        #expect(r.alerts.isEmpty)
    }

    @Test func utilFunctions() throws {
        let form = Self.form([
            F("a", Self.rect(0)),
            F("p", Self.rect(1), [("C", "event.value = util.printf('%,0.2f|%d|%s|%05.1f|%x|%+d', 1234.567, 3.9, 'x', 2.25, 255, 4);")]),
            F("d", Self.rect(2), [("C", "event.value = util.printd('yyyy-mm-dd', new Date(2026, 2, 7)) + ' ' + util.printd('dd/mm/yyyy', util.scand('yyyy-mm-dd', '2026-03-07'));")]),
            F("g", Self.rect(3), [("C", "var f = getField('row'); event.value = f.getArray().length + ':' + f.getArray().map(function (k) { return k.name; }).join(',') + ':' + getField('a').type;")]),
            F("row.1", Self.rect(4)),
            F("row.2", Self.rect(5)),
        ])
        let r = try Self.fill(form, ("a", "1"))
        #expect(try Self.valueOf(r.data, "p") == "1,234.57|3|x|002.3|FF|+4")
        #expect(try Self.valueOf(r.data, "d") == "2026-03-07 07/03/2026")
        #expect(try Self.valueOf(r.data, "g") == "2:row.1,row.2:text")
    }

    @Test(arguments: [
        "app.openDoc('C:/x.pdf'); event.value = 'ran';",
        "SOAP.request({ cURL: 'http://x' }); event.value = 'ran';",
        "app.execMenuItem('Quit'); event.value = 'ran';",
        "this.exportDataObject({ cName: 'a' }); event.value = 'ran';",
        "while (true) {}",
        "for (;;) { event.value = 'ran'; }",
        "function f(n) { return f(n + 1) + 1; } event.value = f(0);",
        "var a = []; while (true) { a.push(1); }",
        "var s = 'x'; while (true) { s = s + s; }",
        "event.value = { toString: function () { while (true) {} } };",
        "event.value = System.IO.File.ReadAllText('C:/Windows/win.ini');",
        "var File = importNamespace('System.IO').File; event.value = 'ran';",
        "event.value = getField('a').constructor.constructor('return System')().Environment.MachineName;",
        "event.value = require('fs');",
    ])
    func hostileScriptsTerminateQuicklyWithoutSideEffects(_ script: String) throws {
        let form = Self.form([F("a", Self.rect(0)), F("b", Self.rect(1), [("C", script)], "/V (old)")])
        let start = Date()
        let r = try Self.fill(form, ("a", "1"))
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(ms < 3000, "took \(ms) ms")
        #expect(try Self.valueOf(r.data, "b") == "old")
        #expect(try Self.valueOf(r.data, "a") == "1")
        #expect(r.log.contains { $0.contains("failed") }, "\(r.log)")
    }

    @Test func onlyTheAcrobatModelIsReachable() throws {
        let probe = "event.value = [typeof System, typeof importNamespace, typeof require, typeof clr, typeof host, typeof h, typeof fetch, typeof XMLHttpRequest, typeof Net, typeof SOAP, "
            + "typeof this.importDataObject, typeof this.exportDataObject, typeof app.openDoc, typeof util.readFileIntoStream, typeof this.saveAs, typeof app.execMenuItem, "
            + "typeof getField, typeof app.alert, typeof AFNumber_Format, typeof app.launchURL, typeof this.submitForm, typeof this.mailDoc, typeof this.print].join(',');"
        let form = Self.form([F("a", Self.rect(0)), F("b", Self.rect(1), [("C", probe)])])
        let r = try Self.fill(form, ("a", "1"))
        // Outward calls exist, but only reach the app's host (which asks the user); without one they do nothing.
        #expect(try Self.valueOf(r.data, "b") == Array(repeating: "undefined", count: 16).joined(separator: ",") + ",function,function,function,function,function,function,function")
    }

    @Test func brokenScriptsFallBackToTheParsedFastPaths() throws {
        // A document script that breaks the built-ins makes the scripts throw: the parsed fast paths still compute and format.
        let form = Self.form([
            F("a", Self.rect(0)),
            F("b", Self.rect(1)),
            F("t", Self.rect(2), [("C", "AFSimple_Calculate(\"SUM\", new Array(\"a\", \"b\"));"), ("F", "AFNumber_Format(2, 0, 0, 0, \"$\", true);")]),
        ], docScripts: ["AFSimple_Calculate = null; AFNumber_Format = null;"])
        let r = try Self.fill(form, ("a", "2"), ("b", "3"))
        let t = try #require(try FormEditor.read(r.data, nil).first { $0.fieldName == "t" })
        #expect(t.value == "5")
        #expect(t.displayValue == "$5.00")
    }

    /// The process's physical memory footprint (what Activity Monitor shows).
    static func footprint() -> Int64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Int64(info.phys_footprint) : 0
    }

    @Test(arguments: [
        "'a'.repeat(Math.pow(2, 26)).length",
        "'a'.padStart(Math.pow(2, 26), 'b').length",
        "'a'.padEnd(Math.pow(2, 26)).length",
        "var s = 'x'.repeat(1000000); [s, s, s].join('').length",
        "var s = 'x'.repeat(1000000); String([s, s]).length",
        "var s = 'x'.repeat(600000); s.concat(s).length",
        "var s = 'x'.repeat(100000); s.replace(/x/g, 'yyyyyyyyyyyy').length",
        "var s = 'x'.repeat(1000); s.replaceAll('x', '$&'.repeat(2000)).length",
        "var s = 'x'.repeat(1000); s.replace(/x/g, function () { return 'y'.repeat(5000); }).length",
        "new Array(Math.pow(2, 26)).fill(1).length",
        "Array(Math.pow(2, 26)).join('a').length",
    ])
    func hugeStringsAreRefusedBeforeTheyAreAllocated(_ expression: String) throws {
        let form = Self.form([F("a", Self.rect(0)), F("b", Self.rect(1), [("C", "event.value = \(expression);")])], co: ["b"])
        let before = Self.footprint()
        let start = Date()
        let r = try Self.fill(form, ("a", "1"))
        let ms = Date().timeIntervalSince(start) * 1000
        #expect(ms < 3000, "took \(ms) ms")
        // The whole process (tests run in parallel): a refused build stays far below the gigabytes it asked for.
        #expect(Self.footprint() - before < 256 * 1024 * 1024, "allocated too much")
        #expect(try Self.valueOf(r.data, "b") == "")
        #expect(r.log.contains { $0.contains("failed") })
    }

    @Test func ordinaryStringBuildingStillWorks() throws {
        let form = Self.form([
            F("a", Self.rect(0)),
            F("b", Self.rect(1), [("C", "var p = [1, [2, 3]]; p.push(p); event.value = ['x'.repeat(3), '7'.padStart(3, '0'), [1, 2].join('-'), String(p), "
                + "'a-b'.replace('-', '$&$&'), 'aXbX'.replace(/X/g, function (m) { return m.toLowerCase(); }), 'q'.concat(1, 2), 'ab'.replaceAll('b', 'c')].join('|');")]),
        ], co: ["b"])
        #expect(try Self.valueOf(Self.fill(form, ("a", "1")).data, "b") == "xxx|007|1-2|1,2,3,|a--b|axbx|q12|ac")
    }

    @Test(arguments: [
        ("3/04/2025", "dd/mm/yyyy", 2025, 4, 3), ("03/4/2025", "dd/mm/yyyy", 2025, 4, 3), ("3.4.25", "dd.mm.yyyy", 2025, 4, 3),
        ("3.04.2025", "dd.mm.yyyy", 2025, 4, 3), ("3-4-2025", "dd/mm/yyyy", 2025, 4, 3), ("4/3/2025", "mm/dd/yyyy", 2025, 4, 3),
        ("2025-04-03", "dd/mm/yyyy", 2025, 4, 3), ("3 April 2025", "dd/mm/yyyy", 2025, 4, 3), ("April 3, 2025", "mm/dd/yyyy", 2025, 4, 3),
        ("3 apr 25", "d-mmm-yy", 2025, 4, 3), ("2025/4/3", "yyyy/mm/dd", 2025, 4, 3), ("12/1999", "mm/yyyy", 1999, 12, 1),
        ("3/4/99", "dd/mm/yy", 1999, 4, 3),
    ] as [(String, String, Int, Int, Int)])
    func datesFollowTheFieldsDayAndMonthOrder(_ typed: String, _ pattern: String, _ year: Int, _ month: Int, _ day: Int) {
        #expect(FormScripts.parseDate(typed, pattern) == FormDate(year, month, day))
    }

    @Test(arguments: [("13/13/2025", "dd/mm/yyyy"), ("31/02/2025", "dd/mm/yyyy"), ("3", "dd/mm/yyyy"), ("1/2/3/4", "dd/mm/yyyy")])
    func impossibleDatesAreRefused(_ typed: String, _ pattern: String) {
        #expect(FormScripts.parseDate(typed, pattern) == nil)
    }

    @Test func dateKeystrokeAcceptsShortFormsInTheFieldsOrder() throws {
        let form = Self.form([F("d", Self.rect(0), [("K", "AFDate_KeystrokeEx(\"dd/mm/yyyy\");"), ("F", "AFDate_FormatEx(\"dd/mm/yyyy\");")])])
        let r = try Self.fill(form, ("d", "3/4/2025"))
        #expect(r.rejected.isEmpty)
        #expect(try FormEditor.read(r.data, nil).first { $0.fieldName == "d" }?.displayValue == "03/04/2025")
    }
}
