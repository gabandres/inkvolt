import Foundation
import Testing
@testable import PdfCore

/// The Mac app's Reset Form, Export Form Data and Import Form Data (FDF, XFDF) over the form code ported in D5; no .NET
/// counterpart file (the Windows app's FormDataActions also writes CSV and JSON, not ported yet).
struct FormDataExchangeTests {
    static let w = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R"

    /// Text "name" (default "Nobody"), check box "agree", combo "size" and a calculated "total" of "a" and "b".
    static func form() -> [UInt8] {
        Core2Pdf.form([
            "<< \(w) /FT /Tx /T (name) /V (Alice) /DV (Nobody) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) >>",
            "<< \(w) /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [72 650 90 668] /AP << /N << /Yes 10 0 R /Off 10 0 R >> >> >>",
            "<< \(w) /FT /Ch /Ff 131072 /T (size) /Opt [(S) (M) (L)] /V (L) /DV (M) /Rect [72 600 200 620] /DA (/Helv 12 Tf 0 g) >>",
            "<< \(w) /FT /Tx /T (a) /V (2) /Rect [72 560 200 580] /DA (/Helv 10 Tf 0 g) >>",
            "<< \(w) /FT /Tx /Ff 1 /T (total) /Rect [72 520 200 540] /DA (/Helv 10 Tf 0 g) /AA << /C << /S /JavaScript /JS (AFSimple_Calculate\\(\"SUM\", new Array\\(\"a\"\\)\\);) >> >> >>",
        ], acroExtra: "/CO [9 0 R]", more: [
            Core2Pdf.stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        ])
    }

    static func values(_ data: [UInt8]) throws -> [String: String] {
        var map: [String: String] = [:]
        for w in try FormEditor.read(data, nil) { map[w.fieldName] = w.value }
        return map
    }

    @Test func resetFormRestoresDefaultsAndRecalculates() throws {
        let reset = try FormEditor.resetForm(Self.form(), nil)
        let v = try Self.values(reset)
        #expect(v["name"] == "Nobody")
        #expect(v["agree"] == "Off")
        #expect(v["size"] == "M")
        #expect(v["a"] == "")
        #expect(v["total"] == "0")
        let some = try Self.values(FormEditor.resetForm(Self.form(), nil, fields: ["name"]))
        #expect(some["name"] == "Nobody" && some["size"] == "L" && some["agree"] == "Yes")
    }

    @Test func exportedDataImportsBackInEitherFormat() throws {
        let original = Self.form()
        for format in FormDataFormat.allCases {
            let exported = try FormEditor.exportData(original, nil, format, file: "form.pdf")
            let text = String(decoding: exported, as: UTF8.self)
            #expect(format == .xfdf ? text.hasPrefix("<?xml") : text.hasPrefix("%FDF"))
            let cleared = try FormEditor.resetForm(original, nil)
            let back = try FormEditor.importData(cleared, nil, exported)
            #expect(back.rejected.isEmpty)
            let v = try Self.values(back.data)
            #expect(v["name"] == "Alice" && v["agree"] == "Yes" && v["size"] == "L" && v["a"] == "2")
            #expect(v["total"] == "2") // the calculation ran on the imported value
        }
    }

    @Test func importRefusesWhatIsntFormData() throws {
        #expect(throws: PdfEditError.self) { try FormEditor.importData(Self.form(), nil, Array("not form data".utf8)) }
        #expect(throws: PdfEditError.self) { try FormEditor.exportData(TestPdf.make(1), nil, .xfdf) }
    }
}
