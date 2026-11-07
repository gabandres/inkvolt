import Foundation
import MuPDFShim
import PrintCore

/// An edit needs the document's permissions (owner) password: it was opened without it, or the one given is wrong (the
/// Windows app's `OwnerPasswordRequiredException`).
public struct OwnerPasswordRequired: Error, Equatable, Sendable, CustomStringConvertible {
    public var wrongPassword: Bool
    public var description: String {
        wrongPassword ? loc("Incorrect permissions password.") : loc("Editing this PDF needs its permissions (owner) password.")
    }
}

/// An edit or a file operation that can't be done, in words for the user (.NET's `InvalidOperationException`,
/// `ArgumentException`).
public struct PdfEditError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// One PDF opened for editing through MuPDF (the role PDFsharp's `PdfDocument` has on Windows). Used by one thread.
final class MuDoc {
    let ctx: UnsafeMutableRawPointer
    let doc: OpaquePointer
    /// Opened for an edit its permissions (/P) allow with just the user password.
    var editedWithUserPassword = false
    /// Read without the file's tail (`StaleTail`): an update goes right after the bytes read.
    var appendsAfter: Int?
    /// A document opened in another's context (so pages and objects can be grafted between them) keeps that document,
    /// and so the context, alive.
    private let owner: MuDoc?
    /// The first change that failed (objects are changed without throwing, as PDFsharp's are); saving throws it.
    var failure: String?
    /// Standard-14 font objects the edit's appearances share, by /BaseFont (`FontResources.standard`).
    var standardFonts: [String: PObj] = [:]

    private init(ctx: UnsafeMutableRawPointer, doc: OpaquePointer, owner: MuDoc? = nil) {
        self.ctx = ctx
        self.doc = doc
        self.owner = owner
    }

    deinit {
        inkv_drop_doc(ctx, doc)
        if owner == nil { inkv_drop_context(ctx) }
    }

    static func open(_ data: [UInt8]) throws -> MuDoc {
        guard let ctx = inkv_new_context(64 << 20) else { throw PdfEngineError(message: "MuPDF couldn't start.") } // English: the engine's own failure, for a developer
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        // Up to the end of the file's last good revision (`StaleTail`): a stale tail or junk after it reaches no reader, and
        // an update goes right after it (`appendsAfter`).
        let keep = StaleTail.keepLength(data)
        guard let doc = data.withUnsafeBufferPointer({ inkv_open_pdf(ctx, $0.baseAddress, keep, 8, &err) }) else {
            inkv_drop_context(ctx)
            throw PdfEngineError(message: PdfEngine.message(err))
        }
        let opened = MuDoc(ctx: ctx, doc: doc)
        if keep < data.count { opened.appendsAfter = keep }
        return opened
    }

    /// A PDF opened in `other`'s context, to graft pages and objects between them.
    static func open(_ data: [UInt8], in other: MuDoc) throws -> MuDoc {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let keep = StaleTail.keepLength(data)
        guard let doc = data.withUnsafeBufferPointer({ inkv_open_pdf(other.ctx, $0.baseAddress, keep, 8, &err) }) else {
            throw PdfEngineError(message: PdfEngine.message(err))
        }
        let opened = MuDoc(ctx: other.ctx, doc: doc, owner: other)
        if keep < data.count { opened.appendsAfter = keep }
        return opened
    }

    /// A new, empty PDF (no pages), in a context of its own.
    static func create() throws -> MuDoc {
        guard let ctx = inkv_new_context(64 << 20) else { throw PdfEngineError(message: "MuPDF couldn't start.") } // English: the engine's own failure, for a developer
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard let doc = inkv_new_pdf(ctx, &err) else {
            inkv_drop_context(ctx)
            throw PdfEngineError(message: PdfEngine.message(err))
        }
        return MuDoc(ctx: ctx, doc: doc)
    }

    /// An image file as a document in `other`'s context (one page per frame), to draw its frames.
    static func openImage(_ data: [UInt8], magic: String, in other: MuDoc) throws -> MuDoc {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard let doc = data.withUnsafeBufferPointer({ inkv_open_image(other.ctx, $0.baseAddress, $0.count, magic, &err) }) else {
            throw PdfEngineError(message: PdfEngine.message(err))
        }
        return MuDoc(ctx: other.ctx, doc: doc, owner: other)
    }

    private func check(_ ok: (UnsafeMutablePointer<CChar>) -> Bool) throws {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let done = err.withUnsafeMutableBufferPointer { ok($0.baseAddress!) }
        if !done { throw PdfEngineError(message: PdfEngine.message(err)) }
    }

    var needsPassword: Bool { inkv_needs_password(ctx, doc) != 0 }
    var hasEncrypt: Bool { inkv_is_encrypted(ctx, doc) != 0 }

    /// fz_authenticate_password's bits: 1 none needed, 2 user, 4 owner; 0 wrong.
    func authBits(_ password: String?) -> Int32 { inkv_auth_bits(ctx, doc, password ?? "") }

    /// The encryption dictionary's V, R, Length, P, /Filter and the stream crypt method; nil when not encrypted.
    func encryptInfo() throws -> (v: Int, r: Int, length: Int, p: Int32, filter: String, cfm: String)? {
        var info = [Int32](repeating: 0, count: 4)
        var filter = [CChar](repeating: 0, count: 32), cfm = [CChar](repeating: 0, count: 32)
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let found = inkv_encrypt_info(ctx, doc, &info, &filter, &cfm, &err)
        if found < 0 { throw PdfEngineError(message: PdfEngine.message(err)) }
        if found == 0 { return nil }
        func text(_ c: [CChar]) -> String { String(decoding: c.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        return (Int(info[0]), Int(info[1]), Int(info[2]), info[3], text(filter), text(cfm))
    }

    func pageCount() throws -> Int {
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let n = inkv_pdf_count(ctx, doc, &err)
        if n < 0 { throw PdfEngineError(message: PdfEngine.message(err)) }
        return Int(n)
    }

    func rotate(_ pages: [Int], _ degrees: Int) throws {
        let list = pages.map { Int32($0) }
        try check { err in list.withUnsafeBufferPointer { inkv_pdf_rotate(ctx, doc, $0.baseAddress, Int32(list.count), Int32(degrees), err) } != 0 }
    }

    func deletePages(_ pages: [Int]) throws {
        let list = pages.map { Int32($0) }
        try check { err in list.withUnsafeBufferPointer { inkv_pdf_delete_pages(ctx, doc, $0.baseAddress, Int32(list.count), err) } != 0 }
    }

    var canAppend: Bool { inkv_can_append(ctx, doc) != 0 }

    /// The original bytes and an incremental update with the edits (the encryption kept). A document read without the
    /// file's tail (`appendsAfter`) gets the update right after the bytes it read: MuPDF's offsets count from there. Every
    /// caller goes through here (edits, signing).
    func append(original: [UInt8]) throws -> [UInt8] {
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        let base = min(appendsAfter ?? original.count, original.count)
        try check { err in original.withUnsafeBufferPointer { inkv_append_pdf(ctx, doc, $0.baseAddress, base, &out, &length, err) } != 0 }
        defer { inkv_free(out) }
        return Array(UnsafeBufferPointer(start: out, count: length))
    }

    /// Every object in use was loaded (`loadAllObjects`): a write needn't walk them again.
    private var objectsLoaded = false

    /// Loads every object in use (in C: free numbers are skipped without a look, so a repaired cross-reference that runs to
    /// the largest number found costs nothing for the numbers between); how many are in use. `keepingThemIn`: each also
    /// listed under that trailer key, so a garbage-collecting write keeps them all. Throws when the walk failed partway.
    @discardableResult
    func loadAllObjects(keepingThemIn key: String? = nil) throws -> Int {
        var used: Int32 = 0
        try check { err in inkv_obj_load_all(ctx, doc, key, &used, err) != 0 }
        objectsLoaded = true
        return Int(used)
    }

    /// A whole new file, written with MuPDF's write options. A repaired document's objects are loaded first: MuPDF's writer
    /// takes the repaired cross-reference for one without object streams, can't read what is compressed in them, and with
    /// garbage collection on silently drops it (a form's bookmarks and structure tree were lost).
    func write(_ options: String) throws -> [UInt8] {
        if !canAppend && !objectsLoaded { try loadAllObjects() }
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        try check { err in inkv_write_pdf(ctx, doc, options, &out, &length, err) != 0 }
        defer { inkv_free(out) }
        return Array(UnsafeBufferPointer(start: out, count: length))
    }
}

/// What an edit may do to an encrypted document with only its user password (empty, or the open password), when its /P
/// allows it: the Windows app's `UserEdit`. Anything else needs the permissions (owner) password.
enum UserEdit {
    case none
    /// /P bit 9 (fill in forms) or bit 6 (comments, and with them filling).
    case fillForms
    /// /P bit 6.
    case annotate
}

/// Opening a PDF for an edit and saving the edited result, as the Windows app's `PdfObj.Open` and `PdfObj.Save` do with
/// PDFsharp. An encrypted document is edited with its permissions (owner) password, or for what its /P allows (`userEdit`)
/// with the user password: MuPDF holds the file key either way. Saving: a signed document, or one edited with the user
/// password, gets the edit appended as an incremental update (the bytes as they were, the update under the same key);
/// anything else (also such a document when it can't be appended to) is written whole (MuPDF's garbage collection, so what
/// an edit removed is gone), keeping its encryption as it was: the same method, permissions and both passwords
/// (`encrypt=keep`).
enum PdfEdit {
    static func open(_ data: [UInt8], _ password: String?, failure: String? = nil, userEdit: UserEdit = .none) throws -> MuDoc {
        let doc: MuDoc
        do {
            doc = try MuDoc.open(data)
        } catch let e as PdfEngineError {
            throw PdfEditError("\(failure ?? loc("This PDF can't be edited")): \(e.message)")
        }
        if doc.hasEncrypt {
            let bits = doc.authBits(password)
            if bits & 4 == 0 {
                if bits & 2 != 0 && allowsWithUserPassword(doc, userEdit) {
                    doc.editedWithUserPassword = true
                    return doc
                }
                // A password that opens nothing at all is wrong; none, or only the open password, isn't.
                throw OwnerPasswordRequired(wrongPassword: !(password ?? "").isEmpty && bits & 6 == 0)
            }
        }
        return doc
    }

    /// Whether the standard handler's /P allows this edit with just the user password (revision 2 has no separate fill
    /// bit: `PdfSecurity.permissions` reads annotate for it).
    private static func allowsWithUserPassword(_ doc: MuDoc, _ edit: UserEdit) -> Bool {
        guard edit != .none, let found = try? doc.encryptInfo(), PdfSecurity.method(found) != .unknown else { return false }
        let allowed = PdfSecurity.permissions(found.p, revision: found.r)
        switch edit {
        case .none: return false
        case .fillForms: return allowed.fillForms || allowed.annotate
        case .annotate: return allowed.annotate
        }
    }

    /// The edited document's bytes. `rewrite`: always written whole (redaction, extraction), never appended.
    static func save(_ doc: MuDoc, original data: [UInt8], password: String?, rewrite: Bool = false) throws -> [UInt8] {
        if !rewrite && SignedEdits.looksSigned(data) {
            if doc.canAppend {
                let appended = try doc.append(original: data)
                SignedEdits.noteAppended()
                return appended
            }
            if !SignedEdits.rewriteAllowed {
                throw SignaturesWouldBreak(signatureCount: SignedEdits.countSignatures(data), reason: "MuPDF can't append to this file")
            }
        }
        // The bytes as the publisher protected them, and the update under the same key, as Acrobat saves such a form.
        if !rewrite && doc.editedWithUserPassword && doc.canAppend { return try doc.append(original: data) }
        return try writeWhole(doc, password: password)
    }

    /// The whole document, its protection kept (or its open password dropped, inside `KeptProtection.run`, which only the
    /// owner password may do).
    static func writeWhole(_ doc: MuDoc, password: String?) throws -> [UInt8] {
        if KeptProtection.dropOpenPassword, !doc.editedWithUserPassword, let info = try doc.encryptInfo() {
            let method = PdfSecurity.method(info)
            return try doc.write("garbage=compact," + PdfSecurity.encryptOptions(method == .aes256 ? .aes256 : .aes128,
                                                                             user: "", owner: password ?? "", p: info.p))
        }
        return try doc.write("garbage=compact,encrypt=keep")
    }
}

/// An edit of a signed PDF can't be appended as an incremental update, so saving it would rewrite the file and
/// invalidate its signatures (the Windows app's `SignaturesWouldBreakException`). Nothing was changed; run the edit again
/// through `SignedEdits.run` with the rewrite allowed once the user agrees.
public struct SignaturesWouldBreak: Error, Equatable, Sendable, CustomStringConvertible {
    /// Signatures in the file (at least 1).
    public var signatureCount: Int
    /// Why the edit can't be appended, for the log.
    public var reason: String

    public var description: String {
        if signatureCount == 1 {
            return loc("This edit can't be added to the signed file as an update ({1}), so saving it would invalidate its signature.", CoreLanguage.number(signatureCount), reason)
        }
        return loc("This edit can't be added to the signed file as an update ({1}), so saving it would invalidate its {0} signatures.", CoreLanguage.number(signatureCount), reason)
    }
}

/// What an edit run through `SignedEdits.run` did to a signed document.
public struct SignedEditReport: Equatable, Sendable {
    /// Saved as an incremental update: the signed bytes are kept as they were.
    public var appended: Bool
    /// The edit removed something but was appended, so the removed item is still in the file's earlier (signed)
    /// revision; `SignedEdits.flatten` removes it for good.
    public var removedItemKept: Bool

    public init(appended: Bool, removedItemKept: Bool) {
        self.appended = appended
        self.removedItemKept = removedItemKept
    }
}

/// Edits of signed documents are appended after the signed bytes, which keeps the signatures valid. When that isn't
/// possible, every edit throws `SignaturesWouldBreak` rather than silently rewriting the file; `run` lets the caller allow
/// the rewrite (after warning the user) and reports what the edit did.
public enum SignedEdits {
    final class Scope: @unchecked Sendable {
        let allowRewrite: Bool
        var appended = false
        var removed = false
        init(allowRewrite: Bool) { self.allowRewrite = allowRewrite }
    }

    @TaskLocal static var current: Scope?

    /// Runs `edit` (on this thread). With `allowRewrite`, a signed document that can't be appended to is rewritten
    /// instead of throwing `SignaturesWouldBreak`.
    public static func run(_ edit: () throws -> [UInt8], allowRewrite: Bool = false) throws -> ([UInt8], SignedEditReport) {
        let scope = Scope(allowRewrite: allowRewrite)
        let data = try $current.withValue(scope) { try edit() }
        return (data, SignedEditReport(appended: scope.appended, removedItemKept: scope.appended && scope.removed))
    }

    /// Rewrites the document as a single revision (a "flattened copy"): earlier revisions, and whatever edits removed from
    /// them, are gone for good. Its signatures no longer verify.
    public static func flatten(_ data: [UInt8], _ password: String?) throws -> [UInt8] {
        try PdfEdit.writeWhole(PdfEdit.open(data, password), password: password)
    }

    static var rewriteAllowed: Bool { current?.allowRewrite == true }

    /// For edits that always rewrite the file (encryption, optimizing, flattening): a signed document needs the caller's
    /// consent (`run` with the rewrite allowed), else this throws.
    static func requireRewrite(_ data: [UInt8], reason: String) throws {
        if looksSigned(data) && !rewriteAllowed { throw SignaturesWouldBreak(signatureCount: countSignatures(data), reason: reason) }
    }

    static func noteAppended() { current?.appended = true }

    /// Called by edits that remove content (pages, comments, attachments).
    static func noteRemoval() { current?.removed = true }

    private static let byteRange = Array("/ByteRange".utf8)

    /// Signed-looking files carry a /ByteRange; signature dictionaries are never compressed into object streams.
    static func looksSigned(_ data: [UInt8]) -> Bool { PdfBytes.first(byteRange, in: data) != nil }

    /// The signature dictionaries in the file, by their /ByteRange (at least 1 for a signed-looking file).
    static func countSignatures(_ data: [UInt8]) -> Int {
        var count = 0
        var from = 0
        while let at = PdfBytes.first(byteRange, in: data, from: from) {
            count += 1
            from = at + byteRange.count
        }
        return max(count, 1)
    }
}

/// Keeps an encrypted document encrypted through edits (the Windows app's `KeptProtection`). On the Mac MuPDF keeps the
/// encryption as it was when it writes an edit (an update appended under the same key, or the whole file with
/// `encrypt=keep`), so both passwords and the permissions stay without the open password being known; `run` is only
/// needed to save a document without its open password (`dropOpenPassword`), which rewrites it with the same method,
/// permissions and permissions password.
public enum KeptProtection {
    final class Scope: Sendable {
        let openPassword: String?
        let dropOpenPassword: Bool
        init(openPassword: String?, dropOpenPassword: Bool) {
            self.openPassword = openPassword
            self.dropOpenPassword = dropOpenPassword
        }
    }

    @TaskLocal static var current: Scope?

    /// Runs `edit` (on this thread); with `dropOpenPassword`, an encrypted document is saved without an open password.
    public static func run<T>(openPassword: String?, dropOpenPassword: Bool, _ edit: () throws -> T) rethrows -> T {
        try $current.withValue(Scope(openPassword: openPassword, dropOpenPassword: dropOpenPassword)) { try edit() }
    }

    static var dropOpenPassword: Bool { current?.dropOpenPassword == true }
}
