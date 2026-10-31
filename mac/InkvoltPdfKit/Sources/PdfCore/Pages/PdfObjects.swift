import Foundation
import MuPDFShim

/// One PDF object of a document opened for editing (the role PDFsharp's `PdfItem`s have on Windows), over MuPDF's
/// pdf_obj. A reference stays a reference (`isRef`, `num`); reading through it reads the object it leads to. Reading
/// never throws (what can't be read reads as nothing, as PDFsharp's lenient reads do); a change that fails is recorded
/// on the document (`MuDoc.failure`) and thrown when it is saved.
final class PObj {
    let doc: MuDoc
    /// MuPDF's object; nil is PDF's null (MuPDF's PDF_NULL is a null pointer).
    let ptr: OpaquePointer?

    init(_ doc: MuDoc, _ ptr: OpaquePointer?) {
        self.doc = doc
        self.ptr = ptr
    }

    deinit { inkv_obj_drop(doc.ctx, ptr) }

    enum Kind: Int32 { case null = 0, bool, int, real, name, string, array, dict }

    /// What the object is (resolved; a stream is a dict).
    var kind: Kind { Kind(rawValue: inkv_obj_kind(doc.ctx, ptr)) ?? .null }
    var isRef: Bool { inkv_obj_is_ref(doc.ctx, ptr) != 0 }
    /// The object number of a reference (0 otherwise).
    var num: Int { Int(inkv_obj_num(doc.ctx, ptr)) }
    var isDict: Bool { kind == .dict }
    var isArray: Bool { kind == .array }
    var isStream: Bool { inkv_obj_is_stream(doc.ctx, ptr) != 0 }

    /// The resolved object's address (the same object read twice is the same address while the document is open).
    var identity: UInt { UInt(inkv_obj_identity(doc.ctx, ptr)) }

    /// What identifies the object (.NET's `Id`): its number when it is a reference, else the object itself.
    var id: ObjId { isRef ? .ref(num) : .direct(identity) }

    var bool: Bool { inkv_obj_bool(doc.ctx, ptr) != 0 }
    /// A number (int or real), else nil.
    var number: Double? { kind == .int || kind == .real ? inkv_obj_number(doc.ctx, ptr) : nil }
    var int: Int? { number.map { Int(exactly: $0.rounded(.towardZero)) ?? 0 } }
    /// A name, without its slash.
    var name: String? {
        var buf = [CChar](repeating: 0, count: 256)
        guard inkv_obj_name(doc.ctx, ptr, &buf, 256) != 0 else { return nil }
        return String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// A string's text (PDFDocEncoding or UTF-16 decoded).
    var text: String? {
        guard let c = inkv_obj_text(doc.ctx, ptr) else { return nil }
        defer { inkv_free(c) }
        return String(cString: c)
    }

    /// A string's bytes.
    var bytes: [UInt8]? {
        var n = 0
        guard let b = inkv_obj_string(doc.ctx, ptr, &n) else { return nil }
        defer { inkv_free(b) }
        return Array(UnsafeBufferPointer(start: b, count: n))
    }

    /// An array's length, or a dictionary's number of entries.
    var count: Int { Int(inkv_obj_count(doc.ctx, ptr)) }

    subscript(index: Int) -> PObj? {
        guard index >= 0, let p = inkv_obj_at(doc.ctx, ptr, Int32(index)) else { return nil }
        return PObj(doc, p)
    }

    /// An array's elements.
    var elements: [PObj] { isArray ? (0..<count).compactMap { self[$0] } : [] }

    /// A dictionary's keys (without slashes).
    var keys: [String] {
        guard isDict else { return [] }
        return (0..<count).compactMap { i in
            guard let c = inkv_obj_key_at(doc.ctx, ptr, Int32(i)) else { return nil }
            defer { inkv_free(c) }
            return String(cString: c)
        }
    }

    subscript(key: String) -> PObj? {
        guard let p = inkv_obj_get(doc.ctx, ptr, key) else { return nil }
        let o = PObj(doc, p)
        return o.kind == .null && !o.isRef ? nil : o
    }

    /// The entry under a name given as its bytes (a name that isn't UTF-8, read from a content stream).
    subscript(raw key: [UInt8]) -> PObj? {
        guard let p = inkv_obj_get(doc.ctx, ptr, (key + [0]).map { CChar(bitPattern: $0) }) else { return nil }
        let o = PObj(doc, p)
        return o.kind == .null && !o.isRef ? nil : o
    }

    func has(_ key: String) -> Bool { self[key] != nil }

    /// Sets a dictionary entry; nil removes it.
    func set(_ key: String, _ value: PObj?) {
        doc.note { inkv_obj_put(doc.ctx, ptr, key, value?.ptr, $0) }
    }

    func remove(_ key: String) { set(key, nil) }

    func append(_ value: PObj) { insert(value, at: count) }

    func insert(_ value: PObj, at index: Int) {
        doc.note { inkv_obj_array_insert(doc.ctx, ptr, Int32(index), value.ptr, $0) }
    }

    func replace(at index: Int, with value: PObj) {
        doc.note { inkv_obj_array_put(doc.ctx, ptr, Int32(index), value.ptr, $0) }
    }

    func remove(at index: Int) {
        doc.note { inkv_obj_array_delete(doc.ctx, ptr, Int32(index), $0) }
    }

    /// A stream's data, decoded; nil when it can't be read.
    var streamData: [UInt8]? { stream(raw: false) }

    /// A stream's data as the file stores it (still encoded: a JPEG's own bytes); nil when it can't be read.
    var rawStreamData: [UInt8]? { stream(raw: true) }

    private func stream(raw: Bool) -> [UInt8]? {
        var n = 0
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard let b = inkv_obj_stream(doc.ctx, doc.doc, ptr, raw ? 1 : 0, &n, &err) else { return nil }
        defer { inkv_free(b) }
        return Array(UnsafeBufferPointer(start: b, count: n))
    }

    /// Replaces a stream's data (deflated when asked).
    func setStream(_ data: [UInt8], deflate: Bool) {
        doc.note { err in data.withUnsafeBufferPointer { inkv_obj_set_stream(doc.ctx, doc.doc, ptr, $0.baseAddress, $0.count, deflate ? 1 : 0, err) } }
    }

    // ---- Reading shortcuts (PdfObj's on Windows) ----

    /// A dictionary value, when it is a dictionary.
    func dict(_ key: String) -> PObj? { self[key].flatMap { $0.isDict ? $0 : nil } }
    func array(_ key: String) -> PObj? { self[key].flatMap { $0.isArray ? $0 : nil } }
    func name(_ key: String) -> String? { self[key]?.name }
    func text(_ key: String) -> String? { self[key]?.text }
    func int(_ key: String) -> Int? { self[key]?.int }
    func number(_ key: String) -> Double? { self[key]?.number }
    /// The number at an array index (0 when it isn't one).
    func num(_ index: Int) -> Double { self[index]?.number ?? 0 }
}

/// An object's identity: its number for an indirect object, else the direct object itself.
enum ObjId: Hashable {
    case ref(Int)
    case direct(UInt)
}

extension MuDoc {
    /// Runs a shim change; the first failure is kept for `save` to throw.
    func note(_ body: (UnsafeMutablePointer<CChar>) -> Int32) {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let ok = err.withUnsafeMutableBufferPointer { body($0.baseAddress!) } != 0
        if !ok && failure == nil { failure = PdfEngine.message(err) }
    }

    private func made(_ body: (UnsafeMutablePointer<CChar>) -> OpaquePointer?) -> PObj {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        if let p = err.withUnsafeMutableBufferPointer({ body($0.baseAddress!) }) { return PObj(self, p) }
        if failure == nil { failure = PdfEngine.message(err) }
        return PObj(self, nil)
    }

    private func new(_ kind: Int32, _ number: Double = 0, text: String? = nil, bytes: [UInt8] = []) -> PObj {
        made { err in bytes.withUnsafeBufferPointer { inkv_obj_new(ctx, doc, kind, number, text, $0.baseAddress, $0.count, err) } }
    }

    var null: PObj { PObj(self, nil) }
    func bool(_ v: Bool) -> PObj { new(1, v ? 1 : 0) }
    func int(_ v: Int) -> PObj { new(2, Double(v)) }
    func real(_ v: Double) -> PObj { new(3, v) }
    func name(_ v: String) -> PObj { new(4, text: v) }
    /// A string of raw bytes.
    func string(_ bytes: [UInt8]) -> PObj { new(5, bytes: bytes) }
    /// A text string: PDFDocEncoding when it fits, else UTF-16 (PDFsharp's `PdfString` with the encoding Windows picks).
    func text(_ v: String) -> PObj { new(8, text: v) }
    func array(_ items: [PObj] = []) -> PObj {
        let a = new(6)
        for item in items { a.append(item) }
        return a
    }
    func dict(_ entries: [(String, PObj)] = []) -> PObj {
        let d = new(7)
        for (k, v) in entries { d.set(k, v) }
        return d
    }
    /// Numbers as an array of reals (.NET's `PdfObj.Reals`).
    func reals(_ values: Double...) -> PObj { array(values.map { real($0) }) }

    /// A new indirect object holding `obj`; the reference.
    func add(_ obj: PObj) -> PObj { made { inkv_obj_add(ctx, doc, obj.ptr, $0) } }

    /// A new stream object (its reference) with `dict`'s entries; the data deflated when asked, else stored as given.
    func addStream(_ data: [UInt8], dict: PObj? = nil, deflate: Bool) -> PObj {
        made { err in data.withUnsafeBufferPointer { inkv_obj_add_stream(ctx, doc, dict?.ptr, $0.baseAddress, $0.count, deflate ? 1 : 0, err) } }
    }

    var trailer: PObj { made { inkv_obj_trailer(ctx, doc, $0) } }
    var catalog: PObj { trailer.dict("Root") ?? dict() }

    /// The page's object (a reference).
    func page(_ index: Int) -> PObj { made { inkv_obj_page(ctx, doc, Int32(index), $0) } }

    /// The index of the page `obj` refers to, or nil.
    func pageIndex(of obj: PObj?) -> Int? {
        guard let obj, obj.isRef else { return nil }
        let n = Int(inkv_obj_page_number(ctx, doc, obj.ptr))
        return n >= 0 ? n : nil
    }

    func pages() throws -> [PObj] { try (0..<pageCount()).map { page($0) } }

    /// Every indirect object number in use (for walking all objects).
    var objectCount: Int { Int(inkv_obj_xref_len(ctx, doc)) }

    func object(_ num: Int) -> PObj { made { inkv_obj_ref(ctx, doc, Int32(num), $0) } }

    /// Inserts a page object (a reference) before page `at` (the count appends).
    func insertPage(_ page: PObj, at index: Int) {
        note { inkv_page_insert(ctx, doc, Int32(index), page.ptr, $0) }
    }

    /// Throws the first change that failed.
    func checkFailure() throws {
        if let failure { throw PdfEditError("This PDF can't be edited: \(failure)") }
    }
}

/// Copies pages and objects from documents opened in the same context into `dst` (MuPDF's graft map: each source object
/// once).
final class Graft {
    let dst: MuDoc
    private let map: OpaquePointer

    init(into dst: MuDoc) throws {
        self.dst = dst
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard let m = inkv_graft_new(dst.ctx, dst.doc, &err) else { throw PdfEngineError(message: PdfEngine.message(err)) }
        map = m
    }

    deinit { inkv_graft_drop(dst.ctx, map) }

    /// Source page `from` (contents, resources and boxes, not its annotations) as page `to`.
    func page(_ src: MuDoc, _ from: Int, to: Int) throws {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard inkv_graft_page(dst.ctx, map, Int32(to), src.doc, Int32(from), &err) != 0 else {
            throw PdfEngineError(message: PdfEngine.message(err))
        }
    }

    /// A source object copied with everything it refers to.
    func object(_ obj: PObj) -> PObj {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        if let p = inkv_graft_obj(dst.ctx, map, obj.ptr, &err) { return PObj(dst, p) }
        if dst.failure == nil { dst.failure = PdfEngine.message(err) }
        return dst.null
    }
}
