import CryptoKit
import Foundation

public enum AttachmentSource: Sendable, Equatable {
    case document, annotation
}

/// A file embedded in the PDF (the Windows app's `AttachmentInfo`).
public struct AttachmentInfo: Sendable, Equatable {
    /// Pass to `Attachments.extract` / `remove`: "doc:<name>" for the document's attachment list, "annot:<annotation id>"
    /// for a file-attachment annotation.
    public let key: String
    public let fileName: String
    public let description: String?
    /// Uncompressed size in bytes.
    public let size: Int
    public let created: Date?
    public let modified: Date?
    public let source: AttachmentSource
    /// Page of the file-attachment annotation, or -1 for document attachments.
    public let pageIndex: Int
    public let mimeType: String?

    public var isPdf: Bool { mimeType == "application/pdf" || fileName.lowercased().hasSuffix(".pdf") }
}

/// Embedded files: the document's /EmbeddedFiles name tree and file-attachment annotations (the Windows app's
/// `Attachments`). Attachments are never opened or run here: listed, written out, added and removed.
public enum Attachments {
    private static let docPrefix = "doc:", annotPrefix = "annot:"

    public static func list(_ data: [UInt8], _ password: String?) throws -> [AttachmentInfo] {
        let doc = try open(data, password)
        var list: [AttachmentInfo] = []
        for (key, value) in PdfStructure.nameTree(embeddedFilesRoot(doc)) {
            if let fs = value, fs.isDict { list.append(describe(docPrefix + key, key, fs, .document, -1)) }
        }
        for p in 0..<(try doc.pageCount()) {
            guard let annots = doc.page(p).array("Annots") else { continue }
            for (i, a) in annots.elements.enumerated() where a.isDict && a.name("Subtype") == "FileAttachment" {
                if let fs = a.dict("FS") {
                    list.append(describe(annotPrefix + Annotations.idOf(doc, a, p, i), "attachment", fs, .annotation, p))
                }
            }
        }
        return list
    }

    /// The attachment's file contents (decoded).
    public static func extract(_ data: [UInt8], _ password: String?, _ key: String) throws -> [UInt8] {
        let doc = try open(data, password)
        guard let fs = try findSpec(doc, key) else { throw PdfEditError("That attachment no longer exists.") }
        guard let stream = fileStream(fs), let bytes = stream.streamData else { throw PdfEditError("That attachment has no embedded data.") }
        try doc.checkFailure()
        return bytes
    }

    /// Embeds a file in the document's attachment list (renamed "name (2).ext" if the name is taken).
    public static func add(_ data: [UInt8], _ password: String?, _ fileName: String, _ bytes: [UInt8], description: String? = nil,
                           modified: Date? = nil) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            var entries = PdfStructure.nameTree(embeddedFilesRoot(doc))
            var name = (fileName.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            if name.isEmpty { name = "attachment" }
            var unique = name
            var n = 2
            while entries.contains(where: { $0.key == unique }) {
                let ext = (name as NSString).pathExtension
                let base = (name as NSString).deletingPathExtension
                unique = "\(base) (\(n))" + (ext.isEmpty ? "" : ".\(ext)")
                n += 1
            }

            let now = Date()
            var streamDict: [(String, PObj)] = [("Type", doc.name("EmbeddedFile"))]
            if let mime = mimeOf(name) { streamDict.append(("Subtype", doc.name(mime))) }
            streamDict.append(("Params", doc.dict([
                ("Size", doc.int(bytes.count)),
                ("CreationDate", doc.text(PdfDates.format(now))),
                ("ModDate", doc.text(PdfDates.format(modified ?? now))),
                ("CheckSum", doc.string(Array(Insecure.MD5.hash(data: bytes)))),
            ])))
            let stream = doc.addStream(bytes, dict: doc.dict(streamDict), deflate: true)

            var spec: [(String, PObj)] = [
                ("Type", doc.name("Filespec")),
                ("F", doc.string(Array(String(unique.unicodeScalars.map { $0.value < 128 ? Character($0) : "_" }).utf8))),
                ("UF", doc.text(unique)),
            ]
            if let description, !description.isEmpty { spec.append(("Desc", doc.text(description))) }
            spec.append(("EF", doc.dict([("F", stream), ("UF", stream)])))
            spec.append(("AFRelationship", doc.name("Unspecified")))
            entries.append((unique, doc.add(doc.dict(spec))))
            writeTree(doc, entries)
        }
    }

    /// Removes a document attachment, or a file-attachment annotation.
    public static func remove(_ data: [UInt8], _ password: String?, _ key: String) throws -> [UInt8] {
        try PageEditor.edit(data, password) { doc in
            if key.hasPrefix(annotPrefix) {
                if !(try Annotations.deleteIn(doc, String(key.dropFirst(annotPrefix.count)))) {
                    throw PdfEditError("That attachment no longer exists.")
                }
            } else {
                let name = key.hasPrefix(docPrefix) ? String(key.dropFirst(docPrefix.count)) : key
                var entries = PdfStructure.nameTree(embeddedFilesRoot(doc))
                let before = entries.count
                entries.removeAll { $0.key == name }
                if entries.count == before { throw PdfEditError("That attachment no longer exists.") }
                writeTree(doc, entries)
                SignedEdits.noteRemoval()
            }
        }
    }

    private static func open(_ data: [UInt8], _ password: String?) throws -> MuDoc {
        do {
            return try PdfEdit.openToRead(data, password)
        } catch let e as PdfEditError {
            throw PdfEditError(e.message.replacingOccurrences(of: "This PDF can't be read", with: "This PDF's attachments can't be read"))
        }
    }

    private static func embeddedFilesRoot(_ doc: MuDoc) -> PObj? { doc.catalog.dict("Names")?.dict("EmbeddedFiles") }

    /// Rewrites the /EmbeddedFiles name tree as one sorted leaf (or drops it when empty).
    private static func writeTree(_ doc: MuDoc, _ entries: [(key: String, value: PObj?)]) {
        let catalog = doc.catalog
        var names = catalog.dict("Names")
        if names == nil {
            if entries.isEmpty { return }
            let made = doc.dict()
            catalog.set("Names", made)
            names = catalog.dict("Names")
        }
        guard let names else { return }
        if entries.isEmpty {
            names.remove("EmbeddedFiles")
            return
        }
        let arr = doc.array()
        // Ordinal order, as .NET's StringComparer.Ordinal (UTF-16 code units).
        for (k, v) in entries.sorted(by: { Array($0.key.utf16).lexicographicallyPrecedes(Array($1.key.utf16)) }) {
            guard let v else { continue } // a key with no value names nothing
            arr.append(doc.text(k))
            arr.append(v)
        }
        names.set("EmbeddedFiles", doc.dict([("Names", arr)]))
    }

    private static func findSpec(_ doc: MuDoc, _ key: String) throws -> PObj? {
        if key.hasPrefix(annotPrefix) {
            return try Annotations.find(doc, String(key.dropFirst(annotPrefix.count)))?.annot.dict("FS")
        }
        let name = key.hasPrefix(docPrefix) ? String(key.dropFirst(docPrefix.count)) : key
        return PdfStructure.nameTree(embeddedFilesRoot(doc)).first { $0.key == name }?.value.flatMap { $0.isDict ? $0 : nil }
    }

    private static func fileStream(_ fs: PObj) -> PObj? {
        let ef = fs.dict("EF")
        return ef?.dict("UF") ?? ef?.dict("F")
    }

    private static func describe(_ key: String, _ fallbackName: String, _ fs: PObj, _ source: AttachmentSource, _ page: Int) -> AttachmentInfo {
        var name = fs.text("UF") ?? fs.text("F") ?? fallbackName
        name = name.replacingOccurrences(of: "\\", with: "/")
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.isEmpty { name = fallbackName }
        let stream = fileStream(fs)
        let params = stream?.dict("Params")
        var size = params?.int("Size") ?? -1
        if size < 0 { size = stream.map { $0.streamData?.count ?? 0 } ?? 0 }
        let mime = stream?.name("Subtype")?.replacingOccurrences(of: "#2F", with: "/").replacingOccurrences(of: "#2f", with: "/")
        return AttachmentInfo(key: key, fileName: name, description: fs.text("Desc"), size: size,
                              created: PdfDates.parse(params?.text("CreationDate")), modified: PdfDates.parse(params?.text("ModDate")),
                              source: source, pageIndex: page, mimeType: mime)
    }

    private static func mimeOf(_ name: String) -> String? {
        switch (name as NSString).pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "txt": "text/plain"
        case "csv": "text/csv"
        case "xml": "text/xml"
        case "json": "application/json"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "zip": "application/zip"
        default: nil
        }
    }
}
