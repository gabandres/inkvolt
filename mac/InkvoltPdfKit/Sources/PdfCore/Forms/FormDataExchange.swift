import Foundation

/// The form data formats the app's Export and Import Form Data commands read and write.
public enum FormDataFormat: Sendable, CaseIterable { case fdf, xfdf }

extension FormEditor {
    /// Reset Form: the fields (all, or those named and the ones under them) back to their default values (/DV, else
    /// empty or off), as the ResetForm action does; then the calculations run and the changed fields are drawn again.
    /// The data comes back unchanged when nothing was reset.
    public static func resetForm(_ data: [UInt8], _ password: String?, fields names: [String]? = nil) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password, failure: "This PDF's form can't be read")
        let acro = doc.catalog.dict("AcroForm")
        let fields = try collect(doc, acro)
        if fields.isEmpty { throw PdfEditError("This PDF has no fillable form.") }
        let runner = FormActionRunner(doc, acro, fields, nil, data, password: password, xmp: Xmp.read(doc))
        runner.reset(names, exclude: false)
        return try runner.finish().data ?? data
    }

    /// Export Form Data: the exportable fields' values (no push buttons, signatures or NoExport fields; empty ones left
    /// out) as FDF or XFDF, the formats a submit sends. `file` names the PDF they belong to (/F, href).
    public static func exportData(_ data: [UInt8], _ password: String?, _ format: FormDataFormat, file: String? = nil) throws -> [UInt8] {
        let doc = try PdfEdit.openToRead(data, password)
        let acro = doc.catalog.dict("AcroForm")
        let fields = try collect(doc, acro)
        if fields.isEmpty { throw PdfEditError("This PDF has no fillable form.") }
        let runner = FormActionRunner(doc, acro, fields, nil, data, password: password, xmp: nil, readOnly: true)
        let entries = runner.entries(nil, exclude: false, includeEmpty: false)
        return format == .xfdf ? FormData.xfdf(entries, file) : FormData.fdf(entries, file)
    }

    /// Import Form Data: the values of an FDF or XFDF file filled in as typed ones are (`fill`: keystroke and validate
    /// scripts, calculations, formats); fields the file names that this form lacks are ignored. Several values (a
    /// multi-select list) are joined by "\n".
    public static func importData(_ data: [UInt8], _ password: String?, _ file: [UInt8], host: FormActionHost? = nil) throws -> FormFillResult {
        guard let parsed = FormData.parse(file) else { throw PdfEditError("That file isn't FDF or XFDF form data.") }
        var values: [String: String] = [:]
        for (name, list) in parsed where !list.isEmpty { values[name] = list.count == 1 ? list[0] : list.joined(separator: "\n") }
        if values.isEmpty { throw PdfEditError("That file has no field values.") }
        return try fill(data, password, values, host: host)
    }
}
