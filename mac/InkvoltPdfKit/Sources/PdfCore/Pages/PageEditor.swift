import Foundation

/// Page edits (the Windows app's `PageEditor`): each takes the document's bytes and password and returns the edited
/// bytes, opened and saved through `PdfEdit` (an encrypted document needs its permissions password and stays encrypted;
/// a signed one gets the edit appended). D2 has rotating and deleting; D3 brings the rest (reorder, insert, extract,
/// merge, duplicate) and keeps bookmarks, links and form fields in step with the pages.
public enum PageEditor {
    /// Deletes pages; a document must keep at least one.
    public static func delete(_ data: [UInt8], _ password: String?, _ pages: [Int]) throws -> [UInt8] {
        try edit(data, password) { doc in
            let distinct = Array(Set(pages))
            if distinct.count >= (try doc.pageCount()) { throw PdfEditError("A document must keep at least one page.") }
            try doc.deletePages(distinct)
            SignedEdits.noteRemoval()
        }
    }

    /// Turns pages by `degrees` (a multiple of 90) clockwise, on top of how they are turned already.
    public static func rotate(_ data: [UInt8], _ password: String?, _ pages: [Int], _ degrees: Int) throws -> [UInt8] {
        if degrees % 90 != 0 { throw PdfEditError("Rotation must be a multiple of 90°.") }
        return try edit(data, password) { doc in try doc.rotate(Array(Set(pages)).sorted(), degrees) }
    }

    /// Opens the document for an edit, runs `body`, and saves it (`rewrite`: always written whole).
    static func edit(_ data: [UInt8], _ password: String?, rewrite: Bool = false, _ body: (MuDoc) throws -> Void) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        try body(doc)
        return try PdfEdit.save(doc, original: data, password: password, rewrite: rewrite)
    }
}
