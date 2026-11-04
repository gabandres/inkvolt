import Foundation
import Testing
@testable import PdfCore

/// FormDataTests.cs: form data in and out (roadmap 1.4): XFDF, FDF, CSV and JSON round trips, CSV merges, validation.
struct FormDataTests {
    static let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"

    /// A form with every field type: text (max 30), several lines, a check box, a radio group, a combo box, a
    /// multi-select list, a required text, a number whose validate script refuses more than 120, and address.city under
    /// a parent.
    static func form() -> [UInt8] {
        Core2Pdf.form([
            "<< \(w) /FT /Tx /T (name) /MaxLen 30 /Rect [72 740 300 760] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(w) /FT /Tx /Ff 4096 /T (notes) /Rect [72 660 300 730] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(w) /FT /Btn /T (agree) /V /Off /AS /Off /Rect [72 630 90 648] /AP << /N << /Yes 16 0 R /Off 17 0 R >> >> >>",
            "<< /FT /Btn /Ff 49152 /T (color) /Kids [14 0 R 15 0 R] /V /Off >>",
            "<< \(w) /FT /Ch /Ff 131072 /T (size) /Opt [(S) (M) (L)] /V (M) /Rect [72 560 200 580] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(w) /FT /Ch /Ff 2097152 /T (toppings) /Opt [[(ham) (Ham)] [(egg) (Egg)] [(kale) (Kale)]] /Rect [72 480 200 540] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(w) /FT /Tx /Ff 2 /T (email) /Rect [72 450 300 470] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(w) /FT /Tx /T (age) /Rect [72 420 140 440] /DA (/Helv 10 Tf 0 g) /AA << /V << /S /JavaScript /JS (if \\(Number\\(event.value\\) > 120\\) event.rc = false;) >> >> >>",
            "<< /T (address) /Kids [18 0 R] >>",
        ], more: [
            "<< \(w) /Parent 8 0 R /Rect [72 600 90 618] /AS /Off /AP << /N << /Red 16 0 R /Off 17 0 R >> >> >>",
            "<< \(w) /Parent 8 0 R /Rect [120 600 138 618] /AS /Off /AP << /N << /Blue 16 0 R /Off 17 0 R >> >> >>",
            Core2Pdf.stream("q 0 g 2 2 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            "<< \(w) /FT /Tx /Parent 13 0 R /T (city) /Rect [72 390 300 410] /DA (/Helv 10 Tf 0 g) >>",
        ], extraAnnots: "14 0 R 15 0 R 18 0 R")
    }

    static let values: [String: String] = [
        "name": "José, \"Pepe\" Núñez",
        "notes": "Line one\nLine two, with a comma\n= not a formula",
        "agree": "Yes",
        "color": "Blue",
        "size": "L",
        "toppings": "ham\nkale",
        "email": "pepe@example.com",
        "age": "42",
        "address.city": "San Juan 🌴",
    ]

    static func read(_ pdf: [UInt8]) throws -> [String: String] {
        Dictionary(try FormEditor.dataFields(pdf, nil).map { ($0.name, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    @Test func formHasEveryFieldType() throws {
        let fields = try FormEditor.dataFields(Self.form(), nil)
        #expect(fields.map(\.name).sorted() == Self.values.keys.sorted())
        #expect(fields.contains { $0.kind == .checkBox })
        #expect(fields.contains { $0.kind == .radio })
        #expect(fields.contains { $0.multiSelect })
        #expect(fields.first { $0.name == "email" }?.required == true)
    }

    @Test(arguments: [FormDataFormat.xfdf, .fdf, .csv, .json])
    func roundTripsEveryFieldType(_ format: FormDataFormat) throws {
        let filled = try FormEditor.fill(Self.form(), nil, Self.values)
        #expect(filled.rejected.isEmpty)
        let expected = try Self.read(filled.data)
        #expect(expected["agree"] == "Yes")
        #expect(expected["toppings"] == "ham\nkale")

        let file = try FormDataFiles.export(filled.data, nil, format, pdfFileName: "form.pdf")
        #expect(FormDataFiles.sniff(file) == format)
        let back = try FormDataFiles.importData(Self.form(), nil, file)
        #expect(back.rejected.isEmpty, "\(back.rejected)")
        #expect(back.unknown.isEmpty)
        #expect(try Self.read(back.data) == expected)
    }

    @Test func csvQuotesCommasQuotesLineBreaksAndUnicode() throws {
        let rows = [
            ["plain", "comma", "quote", "lines", "unicode", "formula", "spaces", ""],
            ["a", "1,5", "say \"hi\"", "x\r\ny\nz", "日本語 — ñ 🌴", "=SUM(A1)", " padded ", ""],
        ]
        let bytes = Csv.write(rows)
        #expect(bytes.starts(with: [0xEF, 0xBB, 0xBF]))
        let text = String(decoding: bytes[3...], as: UTF8.self)
        #expect(text.contains("\"1,5\""))
        #expect(text.contains("\"say \"\"hi\"\"\""))
        #expect(text.contains("\t=SUM(A1)")) // a spreadsheet won't run it
        let read = try Csv.read(Csv.decode(bytes))
        #expect(read.count == 2)
        #expect(read[0] == rows[0])
        #expect(read[1] == ["a", "1,5", "say \"hi\"", "x\r\ny\nz", "日本語 — ñ 🌴", "=SUM(A1)", " padded ", ""])

        // Excel's semicolon CSV, Windows-1252 without a byte order mark, a missing last cell.
        let semi = Array("name;notes;size\r\nJos".utf8) + [0xE9] + Array(";\"a;b\";S\r\nAna;x\r\n".utf8)
        let t = try Csv.read(Csv.decode(semi))
        #expect(t[1] == ["José", "a;b", "S"])
        #expect(t[2] == ["Ana", "x"])
    }

    @Test func jsonTakesNestedObjectsNumbersAndBooleans() throws {
        let json = #"{ "fields": { "name": "Ana", "age": 37, "agree": true, "toppings": ["egg"], "address": { "city": "Ponce" } } }"#
        let r = try FormDataFiles.importData(Self.form(), nil, Array(json.utf8))
        #expect(r.rejected.isEmpty)
        let v = try Self.read(r.data)
        #expect(v["name"] == "Ana")
        #expect(v["age"] == "37")
        #expect(v["agree"] == "Yes")
        #expect(v["toppings"] == "egg")
        #expect(v["address.city"] == "Ponce")
    }

    @Test func importReportsUnknownNamesAndRefusedValues() throws {
        let csv = Array("name,size,ghost,age\r\nAna,XL,boo,200\r\nBo,S,,1\r\n".utf8)
        let r = try FormDataFiles.importData(Self.form(), nil, csv)
        #expect(r.unknown == ["ghost"])
        #expect(r.rejected.contains { $0.fieldName == "size" && $0.message.contains("isn't one of its choices") })
        #expect(r.rejected.contains { $0.fieldName == "age" }) // the form's validate script
        #expect(r.notes.count == 1) // only the first row was used
        #expect(try Self.read(r.data)["name"] == "Ana")
    }

    static func tempFolder(_ prefix: String) -> String {
        (NSTemporaryDirectory() as NSString).appendingPathComponent(prefix + UUID().uuidString.replacingOccurrences(of: "-", with: ""))
    }

    static func pdfs(_ folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.hasSuffix(".pdf") }
    }

    @Test func mergeMakesOneFilledFormPerRow() throws {
        let folder = Self.tempFolder("inkvolt-merge-")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        var csv = "name,notes,agree,color,size,toppings,email,age,address.city,last\r\n"
        let sml = Array("SML")
        for i in 1...200 {
            csv += "\"Person \(i), Jr.\",\"note \(i)\nsecond line\",\(i % 2 == 0 ? "TRUE" : "no"),\(i % 3 == 0 ? "Red" : "Blue"),\(sml[i % 3]),"
                + "\"ham\negg\",p\(i)@example.com,\(i % 100),Città \(i),Núñez\(i)\r\n"
        }
        let formPath = (folder as NSString).appendingPathComponent("intake.pdf")
        let report = try FormMerge.run(Self.form(), nil, Array(csv.utf8), formPath: formPath,
                                       FormMergeOptions(outputFolder: folder, nameTemplate: "<<last>> <<n:3>>"))

        #expect(report.made.count == 200)
        #expect(report.failed.isEmpty)
        #expect(report.unknownColumns == ["last"])
        #expect(Self.pdfs(folder).count == 200)
        for row in report.made {
            let i = row.row
            #expect(row.file == (folder as NSString).appendingPathComponent(String(format: "Núñez%d %03d.pdf", i, i)))
            let v = try Self.read([UInt8](try Data(contentsOf: URL(fileURLWithPath: try #require(row.file)))))
            #expect(v["name"] == "Person \(i), Jr.")
            #expect(v["notes"]?.replacingOccurrences(of: "\r", with: "") == "note \(i)\nsecond line")
            #expect(v["agree"] == (i % 2 == 0 ? "Yes" : "Off"))
            #expect(v["color"] == (i % 3 == 0 ? "Red" : "Blue"))
            #expect(v["size"] == String(sml[i % 3]))
            #expect(v["toppings"] == "ham\negg")
            #expect(v["email"] == "p\(i)@example.com")
            #expect(v["age"] == String(i % 100))
            #expect(v["address.city"] == "Città \(i)")
        }
    }

    @Test func mergeReportsEachRowThatFailsValidation() throws {
        let folder = Self.tempFolder("inkvolt-merge-")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let csv = "name,size,email,age,agree\r\n"
            + "Good,S,a@x.com,30,yes\r\n"
            + "Bad size,XL,b@x.com,30,yes\r\n"
            + "This name is far longer than thirty characters,M,c@x.com,30,no\r\n"
            + "No email,M,,30,no\r\n"
            + "Too old,M,d@x.com,130,no\r\n"
            + "Odd box,M,e@x.com,30,maybe\r\n"
            + "Two problems,XXL,,30,no\r\n"
            + "Also good,L,f@x.com,99,TRUE\r\n"
        let report = try FormMerge.run(Self.form(), nil, Array(csv.utf8), formPath: (folder as NSString).appendingPathComponent("f.pdf"),
                                       FormMergeOptions(outputFolder: folder))
        #expect(report.made.map(\.row) == [1, 8])
        #expect(report.failed.map(\.row) == [2, 3, 4, 5, 6, 7])
        try #require(report.failed.count == 6)
        #expect(report.failed[0].problems.count == 1 && report.failed[0].problems[0].contains("isn't one of its choices"))
        #expect(report.failed[1].problems.count == 1 && report.failed[1].problems[0].contains("at most 30 characters"))
        #expect(report.failed[2].problems.count == 1 && report.failed[2].problems[0].contains("required"))
        #expect(report.failed[3].problems.count == 1 && report.failed[3].problems[0].hasPrefix("age"))
        #expect(report.failed[4].problems.count == 1 && report.failed[4].problems[0].contains("isn't one of its states"))
        #expect(report.failed[5].problems.count == 2)
        #expect(Self.pdfs(folder).count == 2)
        #expect(report.text == "2 forms made, 6 rows failed.")

        let lines = try Csv.read(Csv.decode(report.csv()))
        #expect(lines.count == 9)
        #expect(Array(lines[2].prefix(3)) == ["2", "Failed", ""])
    }

    @Test func mergeNamePatternMustNameRealColumns() {
        #expect(FormMerge.validateTemplate("<<name>> <<Last name>> <<n:3>>", ["Last name"]) == nil)
        #expect(FormMerge.validateTemplate("<<surname>>", ["Last name"])?.contains("<<surname>>") == true)
        #expect(FormMerge.fileName("<<x>> <<n>>", ["x"], ["a/b"], "/tmp/f.pdf", 7, Date()) == "a_b 7")
    }

    @Test func commandLineFillsFormsFromACsv() async throws {
        let folder = Self.tempFolder("inkvolt-fill-")
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let form = (folder as NSString).appendingPathComponent("form.pdf")
        let csv = (folder as NSString).appendingPathComponent("rows.csv")
        try Data(Self.form()).write(to: URL(fileURLWithPath: form))
        try Data("name,email,size\r\nAna,a@x.com,S\r\nBo,b@x.com,Q\r\n".utf8).write(to: URL(fileURLWithPath: csv))
        let output = MemoryLines(), error = MemoryLines()
        let code = await BatchCommandLine.run(["--fill", form, csv, "--name", "<<email>> filled"], output: output, error: error, host: BatchHost())
        #expect(code == BatchCommandLine.someFailed)
        let forms = (folder as NSString).appendingPathComponent("form forms")
        #expect(FileManager.default.fileExists(atPath: (forms as NSString).appendingPathComponent("a@x.com filled.pdf")))
        #expect(FileManager.default.fileExists(atPath: (forms as NSString).appendingPathComponent("form merge report.csv")))
        #expect(error.text.contains("failed   row 2"))
        #expect(output.text.contains("1 form made, 1 row failed."))
    }
}
