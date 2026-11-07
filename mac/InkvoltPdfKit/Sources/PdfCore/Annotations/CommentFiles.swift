import CryptoKit
import Foundation
import PrintCore

public enum CommentFileFormat: Sendable, CaseIterable { case xfdf, fdf, csv }

/// A document's comments as a file.
public struct CommentExport: Sendable {
    /// The file's bytes.
    public var data: [UInt8]
    /// Comments written (replies included).
    public var count: Int
    /// Annotations not written and why, one line per kind.
    public var left: [String]
}

/// What an import did.
public struct CommentImport: Sendable {
    /// The document with the comments added (the original bytes when none was).
    public var data: [UInt8]
    /// Comments added (replies included).
    public var added: Int
    /// One line per comment not imported: where it is and why (already in the document, no such page, a kind that isn't
    /// imported).
    public var skipped: [String]
    /// Anything else worth knowing (a reply kept on its own because its comment isn't there).
    public var notes: [String]
}

/// Comments in and out (roadmap 1.4; the Windows app's `CommentFiles`): a document's comments exported as XFDF
/// (Acrobat's XML, ISO 19444-1), FDF (PDF syntax: each annotation as it is, appearance streams included) or CSV (a row
/// per comment, for spreadsheets), and imported from any of them into a document.
///
/// What travels: type, text (plain and rich), author, subject, dates, color and fill, opacity, flags, border, line
/// endings, geometry (rectangle, quads, ink strokes, vertices, line points, callouts), the reply tree (/IRT by id, reply or
/// group), review states, and appearances: every one in FDF, a stamp's in XFDF (its `appearance` element); imported
/// comments without one get Inkvolt's own (drawings from their geometry, highlights from their quads, notes their icon,
/// stamps their design).
///
/// Import merges, never overwrites: a comment whose id (/NM, XFDF `name`) is already in the document, or one equal to a
/// comment there (type, page, place, text and author) when it has no id, is skipped and reported, so importing the same
/// file twice adds nothing. Only an allow-list of annotation entries comes in, and every value is cleaned on the way: no
/// actions, JavaScript, file attachments, embedded files or external streams can enter the document; XML is read without
/// DTDs; files over `maxFileBytes` or with more than `maxComments` comments are refused. Refusals are `PdfEditError`s.
public enum CommentFiles {
    public static let maxFileBytes = 64 * 1024 * 1024
    public static let maxComments = 100_000
    static let maxNodes = 4_000_000

    public static func fileExtension(_ format: CommentFileFormat) -> String {
        switch format {
        case .xfdf: "xfdf"
        case .fdf: "fdf"
        case .csv: "csv"
        }
    }

    /// The format of a file by its extension (.xfdf, .xml, .fdf, .csv, .txt), or nil.
    public static func format(ofPath path: String) -> CommentFileFormat? {
        switch (path as NSString).pathExtension.lowercased() {
        case "xfdf", "xml": .xfdf
        case "fdf": .fdf
        case "csv", "txt": .csv
        default: nil
        }
    }

    /// One comment on its way in or out: the annotation's entries (keys without the slash), its page, its id and the id of
    /// the comment it replies to.
    struct Record {
        var key: String
        var page: Int
        var dict: [String: FdfValue]
        var replyTo: String?

        var subtype: String { dict["Subtype"]?.nameValue ?? "" }
    }

    /// Annotations that are not comments: never exported or imported.
    static let notComments: Set<String> = ["Widget", "Link", "Popup", ""]

    /// Annotations that carry files or media: not exported, never imported.
    static let notCarried: Set<String> = [
        "FileAttachment", "Sound", "Movie", "Screen", "RichMedia", "3D", "PrinterMark", "TrapNet", "Watermark", "Projection",
    ]

    static func tooMany() -> PdfEditError {
        PdfEditError(loc("The file has more than {0} comments, the most Inkvolt PDF imports.", CoreLanguage.number(maxComments)))
    }

    // ---------------- Export ----------------

    /// `pdfFileName`: the PDF's file name, written as the file the comments belong to (XFDF and FDF `f`).
    public static func export(_ data: [UInt8], _ password: String?, _ format: CommentFileFormat, pdfFileName: String? = nil) throws -> CommentExport {
        let doc: MuDoc
        do {
            doc = try PdfEdit.openToRead(data, password)
        } catch let e as PdfEditError {
            throw PdfEditError(e.message.replacingOccurrences(of: loc("This PDF can't be read"), with: loc("This PDF's comments can't be read")))
        }
        var (records, left) = try collect(doc)
        let bytes: [UInt8]
        switch format {
        case .xfdf: bytes = writeXfdf(records, pdfFileName, &left)
        case .fdf: bytes = writeFdf(records, pdfFileName)
        case .csv: bytes = writeCsv(records)
        }
        let count = format == .xfdf ? records.filter { xfdfElements[$0.subtype] != nil }.count : records.count
        return CommentExport(data: bytes, count: count, left: left)
    }

    /// The comments of the document, in page order, each with its id (its /NM, else one made from where and what it is).
    static func collect(_ doc: MuDoc) throws -> (records: [Record], left: [String]) {
        var found: [(page: Int, annot: PObj)] = []
        var keys: [UInt: String] = [:]
        var left: [String: Int] = [:]
        for p in 0..<(try doc.pageCount()) {
            guard let annots = doc.page(p).array("Annots") else { continue }
            for (i, a) in annots.elements.enumerated() where a.isDict && keys[a.identity] == nil {
                let subtype = a.name("Subtype") ?? ""
                if notComments.contains(subtype) { continue }
                if notCarried.contains(subtype) {
                    left[subtype, default: 0] += 1
                    continue
                }
                found.append((p, a))
                if let nm = a.text("NM"), !nm.isEmpty { keys[a.identity] = nm } else { keys[a.identity] = madeKey(p, i, subtype, a) }
            }
        }
        let portable = ToPortable()
        let records = found.map { f in
            Record(key: keys[f.annot.identity] ?? "", page: f.page, dict: portable.annotation(f.annot),
                   replyTo: f.annot.dict("IRT").flatMap { keys[$0.identity] })
        }
        let lines = left.keys.sorted().map { loc("{0}: not exported (they hold files or media)", countOf(left[$0] ?? 0, $0)) }
        return (records, lines)
    }

    /// An id for a comment without /NM: the same for the same comment of the same file, every time.
    private static func madeKey(_ page: Int, _ index: Int, _ subtype: String, _ a: PObj) -> String {
        let rect = a.array("Rect").map { r in (0..<r.count).map { Fdf.number(r.num($0)) }.joined(separator: " ") } ?? ""
        let parts = [String(page), String(index), subtype, rect, a.text("Contents") ?? "", a.text("T") ?? "", a.text("M") ?? ""]
        return hashed(parts.joined(separator: "\u{1F}"))
    }

    static func hashed(_ text: String) -> String {
        let hex = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        return "inkvoltpdf-x-" + hex.prefix(24)
    }

    /// PDF objects to plain values: shared objects once, cycles cut, references to pages and the document's structure left
    /// out (they mean nothing in another file).
    private final class ToPortable {
        private var done: [Int: FdfValue?] = [:]
        private var path: Set<Int> = []
        private var nodes = 0

        /// Entries of an annotation that point into its document (or are its actions): never exported.
        private static let skipTop: Set<String> = ["P", "Parent", "Popup", "IRT", "StructParent", "OC", "A", "AA", "PA", "PieceInfo"]

        /// Entries deeper down that lead out into the document.
        private static let skipNested: Set<String> = ["P", "Parent", "Popup", "IRT", "StructParent", "StructParents", "Annots", "Pages", "AA"]

        func annotation(_ a: PObj) -> [String: FdfValue] {
            var dict: [String: FdfValue] = [:]
            for key in a.keys where !Self.skipTop.contains(key) {
                if let o = a[key], let v = value(o, 1) { dict[key] = v }
            }
            return dict
        }

        private func value(_ o: PObj, _ depth: Int) -> FdfValue? {
            nodes += 1
            if nodes > CommentFiles.maxNodes || depth > 32 { return nil }
            guard o.isRef else { return plain(o, depth) }
            let n = o.num
            if let known = done[n] { return known }
            if path.contains(n) { return nil }
            path.insert(n)
            defer { path.remove(n) }
            let result = plain(o, depth)
            done[n] = result
            return result
        }

        private func plain(_ o: PObj, _ depth: Int) -> FdfValue? {
            switch o.kind {
            case .null: return nil
            case .bool: return .bool(o.bool)
            case .int, .real: return o.number.map { .number($0) }
            case .name: return o.name.map { .name($0) }
            case .string: return .string(o.text ?? "")
            case .array: return .array(o.elements.map { value($0, depth + 1) ?? .null })
            case .dict:
                let stream = o.isStream
                var dict: [String: FdfValue] = [:]
                for key in o.keys where !Self.skipNested.contains(key) && !(key == "Length" && stream) {
                    if let v = o[key], let item = value(v, depth + 1) { dict[key] = item }
                }
                if stream { return .stream(FdfStream(dict, o.rawStreamData ?? [])) }
                return .dict(dict)
            }
        }
    }

    private static func writeFdf(_ records: [Record], _ pdfFileName: String?) -> [UInt8] {
        let w = Fdf.Writer()
        let root = w.reserve()
        let refs = records.map { _ in w.reserve() }
        var byKey: [String: Int] = [:]
        for (i, r) in records.enumerated() where byKey[r.key] == nil { byKey[r.key] = refs[i] }
        for (i, r) in records.enumerated() {
            var dict = r.dict
            dict["Page"] = .number(Double(r.page))
            dict["NM"] = .string(r.key)
            if let to = r.replyTo, let target = byKey[to] { dict["IRT"] = .ref(target) }
            w.set(refs[i], .dict(dict))
        }
        var fdf: [String: FdfValue] = ["Annots": .array(refs.map { .ref($0) })]
        if let pdfFileName { fdf["F"] = .string(pdfFileName) }
        w.set(root, .dict(["FDF": .dict(fdf), "Type": .name("Catalog")]))
        return w.finish(root)
    }

    // ---------------- Import ----------------

    /// Adds the comments in `file` (XFDF, FDF or CSV, told apart by their content) to the document. Throws when the file
    /// isn't one of them, is damaged, too big, or carries a DTD.
    public static func importComments(_ data: [UInt8], _ password: String?, _ file: [UInt8]) throws -> CommentImport {
        var (records, skipped) = try parse(file)
        var notes: [String] = []
        let doc = try PdfEdit.open(data, password, userEdit: .annotate)
        let xmp = Xmp.read(doc)
        let labels = try PdfStructure.readLabels(doc)
        let pageCount = try doc.pageCount()

        // What is already there: by id, and by what it is for comments without one.
        var byKey: [String: PObj] = [:]
        var byLook: [String: PObj] = [:]
        for p in 0..<pageCount {
            for a in doc.page(p).array("Annots")?.elements ?? [] where a.isDict {
                if let nm = a.text("NM"), !nm.isEmpty, byKey[nm] == nil { byKey[nm] = a }
                let rect = a.array("Rect").map { r in (0..<r.count).map { r.num($0) } }
                let look = Self.look(p, a.name("Subtype") ?? "", rect, a.text("Contents"), a.text("T"))
                if byLook[look] == nil { byLook[look] = a }
            }
        }

        var added: [(record: Record, annot: PObj)] = []
        let builder = FromPortable(doc)
        for r in records {
            let subtype = r.subtype
            let author = r.dict["T"]?.stringValue ?? ""
            let whereText = author.isEmpty
                ? loc("Page {0}, {1}", CoreLanguage.number(r.page + 1), kindName(subtype))
                : loc("Page {0}, {1} by {2}", CoreLanguage.number(r.page + 1), kindName(subtype), author)
            if r.page < 0 || r.page >= pageCount {
                skipped.append(loc("{0}: the document has no page {1}", whereText, CoreLanguage.number(r.page + 1)))
                continue
            }
            if notComments.contains(subtype) || notCarried.contains(subtype) {
                skipped.append(notCarried.contains(subtype)
                    ? loc("{0}: files and media aren't imported", whereText) : loc("{0}: not a comment", whereText))
                continue
            }
            if byKey[r.key] != nil {
                skipped.append(loc("{0}: already in the document", whereText))
                continue
            }
            guard let rect = r.dict["Rect"]?.numbers, rect.count == 4, rect.allSatisfy(\.isFinite) else {
                skipped.append(loc("{0}: it has no position", whereText))
                continue
            }
            if let same = byLook[look(r.page, subtype, rect, r.dict["Contents"]?.stringValue, r.dict["T"]?.stringValue)] {
                byKey[r.key] = same
                skipped.append(loc("{0}: already in the document", whereText))
                continue
            }

            let page = doc.page(r.page)
            let fresh = doc.dict()
            for key in r.dict.keys.sorted() where allowedKeys.contains(key) {
                if let v = r.dict[key], let item = builder.item(v) { fresh.set(key, item) }
            }
            fresh.set("Type", doc.name("Annot"))
            fresh.set("NM", doc.text(r.key))
            fresh.set("P", page)
            let annot = doc.add(fresh)
            doc.annots(page).append(annot)
            if !hasAppearance(annot) { Annotations.makeAppearance(doc, page, annot) }
            byKey[r.key] = annot
            added.append((r, annot))
        }

        var orphans = 0
        for (r, annot) in added {
            guard let to = r.replyTo else { continue }
            if let target = byKey[to], target.identity != annot.identity, target.isRef {
                annot.set("IRT", target)
                if r.dict["RT"]?.nameValue == "Group" { annot.set("RT", doc.name("Group")) }
            } else {
                orphans += 1
                annot.remove("RT")
            }
        }
        if orphans > 0 {
            notes.append(orphans == 1
                ? loc("{0} reply kept as comments of their own: the comment they answer is neither in the document nor in the file.", 1)
                : loc("{0} replies kept as comments of their own: the comment they answer is neither in the document nor in the file.", CoreLanguage.number(orphans)))
        }
        if added.isEmpty { return CommentImport(data: data, added: 0, skipped: skipped, notes: notes) }
        if let labels { try PdfStructure.writeLabels(doc, labels) }
        InfoDict.setDate(doc, "ModDate", Date())
        Xmp.write(doc, original: xmp)
        try doc.checkFailure()
        let saved = try PdfEdit.save(doc, original: data, password: password)
        return CommentImport(data: saved, added: added.count, skipped: skipped, notes: notes)
    }

    /// How many comments `file` holds: checks it can be imported before any edit starts.
    public static func count(_ file: [UInt8]) throws -> Int { try parse(file).records.count }

    /// The comments in an XFDF, FDF or CSV file, and lines for those that can't be read.
    static func parse(_ file: [UInt8]) throws -> (records: [Record], skipped: [String]) {
        if file.isEmpty { throw PdfEditError(loc("The file is empty.")) }
        if file.count > maxFileBytes { throw PdfEditError(loc("The file is larger than {0} MB, the most Inkvolt PDF imports.", CoreLanguage.number(maxFileBytes >> 20))) }
        var skipped: [String] = []
        var start = file.count >= 3 && file[0] == 0xEF && file[1] == 0xBB && file[2] == 0xBF ? 3 : 0
        while start < file.count && [32, 9, 13, 10].contains(file[start]) { start += 1 }
        let records: [Record]
        if start < file.count && file[start] == UInt8(ascii: "<") {
            records = try readXfdf(file, &skipped)
        } else if file[start...].starts(with: Array("%FDF".utf8)) {
            records = try readFdf(file)
        } else {
            records = try readCsv(file, &skipped)
        }
        if records.count > maxComments { throw tooMany() }
        return (records, skipped)
    }

    private static func readFdf(_ file: [UInt8]) throws -> [Record] {
        let fdf = Fdf.read(file)
        guard let root = fdf.fdfDict() else { throw PdfEditError(loc("The FDF file has no /FDF dictionary.")) }
        guard let list = fdf.resolve(root["Annots"])?.arrayValue else { return [] }
        if list.count > maxComments { throw tooMany() }

        let cleaner = Cleaner(fdf.resolve)
        var keys: [Int: String] = [:]
        var items: [(ref: Int?, dict: [String: FdfValue], key: String)] = []
        for (i, item) in list.enumerated() {
            guard let d = fdf.resolve(item)?.dictValue else { continue }
            var ref: Int?
            if case .ref(let n) = item { ref = n }
            if let existing = ref.flatMap({ keys[$0] }) {
                items.append((ref, d, existing))
                continue
            }
            let key: String
            if let nm = fdf.resolve(d["NM"])?.stringValue, !nm.isEmpty { key = nm } else { key = hashKey("fdf", i, fdf, d) }
            if let ref { keys[ref] = key }
            items.append((ref, d, key))
        }
        var records: [Record] = []
        for item in items {
            let d = item.dict
            var page = -1
            if let pg = fdf.resolve(d["Page"])?.numberValue, pg >= 0, pg < Double(Int32.max) { page = Int(pg) }
            guard let clean = try cleaner.annotation(d) else { continue }
            var replyTo: String?
            if case .ref(let n)? = d["IRT"], let k = keys[n] {
                replyTo = k
            } else if let s = fdf.resolve(d["IRT"])?.stringValue {
                replyTo = s
            }
            records.append(Record(key: item.key, page: page, dict: clean, replyTo: replyTo))
        }
        return records
    }

    /// An id for an imported comment without one, from what it is.
    static func hashKey(_ kind: String, _ index: Int, _ doc: Fdf.Document?, _ d: [String: FdfValue]) -> String {
        var text = kind + String(index)
        let w = Fdf.Writer()
        for key in ["Subtype", "Page", "Rect", "Contents", "T", "M"] {
            var v = doc.map { $0.resolve(d[key]) } ?? d[key]
            if case .stream? = v { v = nil }
            text += "\u{1F}" + w.serialize(v)
        }
        return hashed(text)
    }

    /// Comments are the same when they are of one type, on one page, in one place (to the point), with the same text and
    /// author.
    private static func look(_ page: Int, _ subtype: String, _ rect: [Double]?, _ contents: String?, _ author: String?) -> String {
        var box = ""
        if let r = rect, r.count == 4 {
            box = [min(r[0], r[2]), min(r[1], r[3]), max(r[0], r[2]), max(r[1], r[3])].map { Fdf.number($0.rounded()) }.joined(separator: " ")
        }
        let text = (contents ?? "").replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return [String(page), subtype, box, text, author ?? ""].joined(separator: "\u{1F}")
    }

    private static func hasAppearance(_ annot: PObj) -> Bool { annot.dict("AP")?.dict("N") != nil }

    // ---------------- Cleaning what comes in ----------------

    /// The annotation entries an import keeps. Everything else (actions, /A, /AA, popups, files, structure, layers,
    /// private data of other apps) stays out.
    static let allowedKeys: Set<String> = [
        "Subtype", "Rect", "Contents", "M", "F", "C", "CA", "ca", "T", "Subj", "CreationDate", "RT", "IT", "QuadPoints", "InkList", "L",
        "LE", "Vertices", "BS", "Border", "BE", "IC", "DA", "DS", "Q", "RC", "RD", "CL", "Name", "Open", "Rotate", "State", "StateModel",
        "AP", "AS", "LL", "LLE", "LLO", "Cap", "CP", "CO", "Measure", "Sy", "OverlayText", "Repeat", "RO", "Lang", "InkvoltPdfStamp",
    ]

    /// Values made safe: references resolved (cycles cut), and anything that could act removed at every depth: action and
    /// file specification dictionaries, entries naming actions, JavaScript, files or the document's structure, and streams
    /// with external data or PostScript.
    final class Cleaner {
        private static let actionTypes: Set<String> = [
            "JavaScript", "Launch", "SubmitForm", "ResetForm", "ImportData", "URI", "GoTo", "GoToR", "GoToE", "GoToDp", "Named", "Rendition",
            "Movie", "Sound", "Hide", "SetOCGState", "Trans", "GoTo3DView", "RichMediaExecute", "Thread", "SetState", "NOP", "ECMAScript",
        ]

        private static let droppedKeys: Set<String> = [
            "AA", "JS", "JavaScript", "OpenAction", "URI", "Launch", "EF", "EmbeddedFiles", "FS", "RichMediaContent",
            "RichMediaSettings", "Sound", "Movie", "P", "Parent", "Popup", "StructParent", "StructParents", "PieceInfo", "OC", "Annots",
            "Pages", "XFA", "AcroForm",
        ]

        private let resolve: (FdfValue?) -> FdfValue?
        private var done: [Int: FdfValue?] = [:]
        private var path: Set<Int> = []
        private var nodes = 0

        init(_ resolve: @escaping (FdfValue?) -> FdfValue?) { self.resolve = resolve }

        func annotation(_ d: [String: FdfValue]) throws -> [String: FdfValue]? { try value(.dict(d), 0)?.dictValue }

        func value(_ v: FdfValue?, _ depth: Int) throws -> FdfValue? {
            nodes += 1
            if nodes > CommentFiles.maxNodes { throw PdfEditError(loc("The file holds more objects than Inkvolt PDF imports.")) }
            if depth > 32 { return nil }
            guard let v else { return nil }
            guard case .ref(let n) = v else { return try clean(v, depth) }
            if let known = done[n] { return known }
            if path.contains(n) { return nil }
            path.insert(n)
            defer { path.remove(n) }
            guard let target = resolve(v) else { return nil }
            let result = try clean(target, depth)
            done[n] = result
            return result
        }

        private func clean(_ v: FdfValue, _ depth: Int) throws -> FdfValue? {
            switch v {
            case .dict(let d):
                if isActionOrFile(d) { return nil }
                var out: [String: FdfValue] = [:]
                for (key, item) in d where !Self.droppedKeys.contains(key) && key != "IRT" {
                    if let c = try value(item, depth + 1) { out[key] = c }
                }
                return .dict(out)
            case .stream(let s):
                if isActionOrFile(s.dict) || resolve(s.dict["Subtype"])?.nameValue == "PS" { return nil }
                if s.dict["F"] != nil || s.dict["FFilter"] != nil { return nil } // data in an external file
                var out: [String: FdfValue] = [:]
                for (key, item) in s.dict where !Self.droppedKeys.contains(key) && !["Length", "DL", "FDecodeParms", "Metadata"].contains(key) {
                    if let c = try value(item, depth + 1) { out[key] = c }
                }
                return .stream(FdfStream(out, s.data))
            case .array(let list):
                if list.count > 1_000_000 { return nil }
                return .array(try list.map { try value($0, depth + 1) ?? .null })
            case .number(let d): return d.isFinite ? v : nil
            case .string, .bool, .name: return v
            case .null, .ref: return nil
            }
        }

        private func isActionOrFile(_ d: [String: FdfValue]) -> Bool {
            if let type = resolve(d["Type"])?.nameValue, ["Action", "Filespec", "EmbeddedFile"].contains(type) { return true }
            if let s = resolve(d["S"])?.nameValue, Self.actionTypes.contains(s) { return true }
            return d["JS"] != nil
        }
    }

    /// Plain values to objects of `doc`; streams become indirect objects, each once.
    private final class FromPortable {
        private let doc: MuDoc
        private var streams: [ObjectIdentifier: PObj] = [:]

        init(_ doc: MuDoc) { self.doc = doc }

        func item(_ v: FdfValue, _ depth: Int = 0) -> PObj? {
            if depth > 40 { return nil }
            switch v {
            case .stream(let s):
                if let known = streams[ObjectIdentifier(s)] { return known }
                let d = doc.dict()
                for key in s.dict.keys.sorted() {
                    if let x = s.dict[key], let item = item(x, depth + 1) { d.set(key, item) }
                }
                let ref = doc.addStream(s.data, dict: d, deflate: false)
                streams[ObjectIdentifier(s)] = ref
                return ref
            case .dict(let dict):
                let d = doc.dict()
                for key in dict.keys.sorted() {
                    if let x = dict[key], let item = item(x, depth + 1) { d.set(key, item) }
                }
                return d
            case .array(let list):
                return doc.array(list.map { item($0, depth + 1) ?? doc.null })
            case .name(let n): return doc.name(n)
            case .string(let s): return doc.text(s)
            case .bool(let b): return doc.bool(b)
            case .number(let d):
                if abs(d - d.rounded()) < 1e-9, abs(d) < Double(Int32.max), let i = Int(exactly: d.rounded()) { return doc.int(i) }
                return doc.real(d)
            case .null, .ref: return nil
            }
        }
    }

    // ---------------- Words ----------------

    /// What a comment of `subtype` is called ("highlight", "note", "drawing"), in the interface's language.
    public static func kindName(_ subtype: String) -> String { kindNames(subtype).one }

    /// A kind's name for one comment and for several (Windows' `KindNames`).
    private static func kindNames(_ subtype: String) -> (one: String, many: String) {
        switch subtype {
        case "Text": (loc("note"), loc("notes"))
        case "FreeText": (loc("text box"), loc("text boxes"))
        case "Highlight": (loc("highlight"), loc("highlights"))
        case "Underline": (loc("underline"), loc("underlines"))
        case "StrikeOut": (loc("strike-through"), loc("strike-throughs"))
        case "Squiggly": (loc("squiggly underline"), loc("squiggly underlines"))
        case "Ink": (loc("drawing"), loc("drawings"))
        case "Square": (loc("rectangle"), loc("rectangles"))
        case "Circle": (loc("ellipse"), loc("ellipses"))
        case "Line": (loc("line"), loc("lines"))
        case "Polygon": (loc("polygon"), loc("polygons"))
        case "PolyLine": (loc("connected lines"), loc("connected lines"))
        case "Stamp": (loc("stamp"), loc("stamps"))
        case "Caret": (loc("insert mark"), loc("insert marks"))
        case "Redact": (loc("redaction mark"), loc("redaction marks"))
        case "FileAttachment": (loc("file attachment"), loc("file attachments"))
        case "Sound": (loc("sound"), loc("sounds"))
        case "": (loc("comment"), loc("comments"))
        default: (subtype, subtype.hasSuffix("s") ? subtype : subtype + "s")
        }
    }

    /// "1 highlight", "12 highlights": a count of comments of one kind.
    static func countOf(_ n: Int, _ subtype: String) -> String {
        let names = kindNames(subtype)
        return n == 1 ? "1 \(names.one)" : "\(CoreLanguage.number(n)) \(names.many)"
    }
}
