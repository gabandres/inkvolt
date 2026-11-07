import Foundation

/// A damaged file's bytes made sound once, as it opens (the Windows app's `PdfRepair.Normalize`): `DocumentSession`'s open,
/// reload, `fromBytes(repair:)` and `recover(repair:)`, Batch and the form merge. MuPDF repairs a damaged file as it opens it;
/// here the repaired document is written out as a copy (every object, the encryption kept), so the view, the readers and the
/// edits share sound bytes, an update can be appended to them, and the repair is known: the person is told once, and a
/// signature made before it is never shown valid (`Signatures.verify`'s `repairedLength`). A stale tail holding objects is a
/// repair too (`StaleTail`). Never throws: a file nothing helps is kept as it is, and its readers say what is wrong.
enum PdfRepair {
    struct Result {
        /// The bytes to work on.
        var data: [UInt8]
        /// The file was damaged and these are its repaired bytes.
        var repaired: Bool
    }

    static func normalize(_ data: [UInt8], _ password: String?) -> Result {
        guard PdfBytes.first(Array("%PDF".utf8), in: data, to: 1024) != nil else { return Result(data: data, repaired: false) }
        let tail = StaleTail.find(data)
        let bytes = tail.map { Array(data[..<$0.keep]) } ?? data
        let hidden = tail?.hidesObjects == true
        guard let doc = try? MuDoc.open(bytes) else { return Result(data: data, repaired: hidden) }
        // A password the document needs and wasn't given: read as it is until it is (the session asks for it).
        if doc.needsPassword && doc.authBits(password) == 0 { return Result(data: bytes, repaired: hidden) }
        if !damaged(doc) { return Result(data: bytes, repaired: hidden) }
        // MuPDF's repaired cross-reference runs to the largest object number it found: a few objects numbered in the millions
        // (300 bytes) were written as 8 million rows, 168 MB. Such a copy is renumbered; a fuller one keeps its numbers.
        let sparse = doc.objectCount > 2 * doc.loadAllObjects() + 1024
        guard let copy = try? doc.write(sparse ? "garbage=compact,encrypt=keep" : "encrypt=keep"), let check = try? MuDoc.open(copy),
              !damaged(check) else {
            return Result(data: bytes, repaired: true)
        }
        return Result(data: copy, repaired: true)
    }

    /// Whether the file is damaged as MuPDF reads it, or hides objects in a stale tail (what `Signatures.verify` checks on
    /// bytes no session normalized).
    static func isDamaged(_ data: [UInt8], _ password: String?) -> Bool {
        if StaleTail.find(data)?.hidesObjects == true { return true }
        guard let doc = try? MuDoc.open(data) else { return true }
        if doc.needsPassword { _ = doc.authBits(password) }
        return damaged(doc)
    }

    /// MuPDF repaired it, now or as the parts every reader walks (the catalog, page tree, form, bookmarks) were read.
    private static func damaged(_ doc: MuDoc) -> Bool {
        if !doc.canAppend { return true }
        let catalog = doc.catalog
        _ = catalog.dict("Pages")?.array("Kids")?.count
        _ = catalog.dict("AcroForm")?.array("Fields")?.count
        _ = catalog.dict("Outlines")?.dict("First")?.keys
        if let first = try? doc.pageCount(), first > 0 { _ = doc.page(0).array("Annots")?.count }
        return !doc.canAppend
    }
}
