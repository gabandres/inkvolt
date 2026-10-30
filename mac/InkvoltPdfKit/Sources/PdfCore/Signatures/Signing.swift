import Foundation
import Security

/// The CMS flavour written into /SubFilter.
public enum SignatureFormat: Sendable {
    /// ETSI.CAdES.detached (PAdES baseline): signing-certificate-v2 signed attribute, signing time in /M only.
    case cades
    /// adbe.pkcs7.detached: the classic Acrobat format, with a signing-time signed attribute.
    case pkcs7
}

/// Certification (DocMDP): which later changes keep a certified document's certification valid.
public enum CertificationLevel: Int, Sendable {
    case none = 0, noChanges = 1, formFilling = 2, formFillingAndComments = 3
}

/// What a visible signature shows: text on the left, an optional image (e.g. a handwritten signature) on the right.
public struct SignatureLook: Sendable, Equatable {
    public var showName = true
    public var showDate = true
    public var showReason = true
    public var showLocation = false
    public var showDistinguishedName = false
    public var showLabels = true
    /// Name shown instead of the certificate's common name.
    public var name: String?
    public var image: StampImage?

    public init() {}
}

/// One digital signature to apply (the Windows app's `SignRequest`).
public struct SignRequest: Sendable {
    /// The digital ID: a Keychain identity (software, smart card: macOS asks for the PIN or the keychain password).
    public var id: DigitalId
    /// An existing empty signature field to sign; nil → a new field.
    public var fieldName: String?
    /// Page of a new visible signature.
    public var pageIndex = 0
    /// Rect (page space) of a new visible signature; nil → invisible.
    public var rect: RectD?
    public var reason: String?
    public var location: String?
    public var contactInfo: String?
    public var look = SignatureLook()
    public var format = SignatureFormat.cades
    /// Sends a DER RFC 3161 TimeStampReq to a timestamp server and returns its DER TimeStampResp (the request holds only
    /// a hash of the signature). Nil → no timestamp.
    public var timestamp: (@Sendable ([UInt8]) async throws -> [UInt8])?
    public var certify = CertificationLevel.none
    /// The time written to /M and shown in the appearance (default: now).
    public var time: Date?

    public init(id: DigitalId) { self.id = id }
}

/// A signing refusal the UI shows as is (.NET's `SigningException`).
public struct SigningError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// Applies digital signatures (PAdES / PKCS#7 detached CMS) to PDFs (the Windows app's `Signing`). The signature is
/// always appended as an incremental update (MuPDF's), so the original bytes, and any earlier signature, stay intact;
/// /Contents is reserved as a zero-filled hex string, the /ByteRange around it is patched in and hashed, and the CMS
/// (written by PdfCore, signed by the ID's key through Security.framework) goes into the gap. A signature field's /Lock is
/// honored (FieldMDP reference, locked fields made read-only). Not supported: encrypted documents, LTV.
public enum Signing {
    /// The placeholder MuPDF writes for the byte range (ten digits each, so the real offsets fit in its place).
    private static let rangePlaceholder = "[0 1000000000 1000000000 1000000000]"

    public static func sign(_ data: [UInt8], _ password: String?, _ req: SignRequest) async throws -> [UInt8] {
        if data.firstRange(of: Array("/Encrypt".utf8)) != nil {
            throw SigningError("Encrypted (password-protected) PDFs can't be signed here. Remove the protection first (Save As without a password), then sign.")
        }
        let existing = Signatures.verify(data, password)
        let signedBefore = existing.contains { $0.status != .unsigned }
        if req.certify != .none && signedBefore {
            throw SigningError("A certifying signature must be the document's first signature: this document is already signed.")
        }
        let certification = certification(data, password)
        if certification == .noChanges {
            throw SigningError("This document is certified with no changes allowed: another signature would invalidate the certification.")
        }
        // Form filling and signing (P=2) covers signing the signature fields the certifier put there, not adding new ones.
        if certification == .formFilling && req.fieldName == nil {
            throw SigningError("This document is certified to allow only filling in forms and signing its existing signature fields: sign one of its empty signature fields instead.")
        }
        if let broken = existing.first(where: { $0.status == .disallowedChanges && $0.certificationLevel != nil }) {
            throw SigningError("The changes made to this document since it was certified aren't allowed by the certification (\(broken.detail ?? "")). Undo them, then sign.")
        }

        var reserve = req.timestamp == nil ? 16384 : 32768
        for _ in 0..<3 {
            try Task.checkCancellation()
            var (pdf, gapStart, gapEnd) = try prepare(data, password, req, reserve, signedBefore)
            let signed = Array(pdf[..<gapStart]) + Array(pdf[gapEnd...])
            let der = try await buildCms(signed, req)
            let hex = Array(der.map { String(format: "%02X", $0) }.joined().utf8)
            if hex.count <= gapEnd - gapStart - 2 {
                pdf.replaceSubrange((gapStart + 1)..<(gapStart + 1 + hex.count), with: hex)
                return pdf
            }
            reserve = der.count + 8192
        }
        throw SigningError("The signature doesn't fit the space reserved for it.")
    }

    /// The certification level of a document's certifying signature (catalog /Perms /DocMDP), else `.none`.
    public static func certification(_ data: [UInt8], _ password: String? = nil) -> CertificationLevel {
        guard let doc = try? PdfEdit.openToRead(data, password), let sig = doc.catalog.dict("Perms")?.dict("DocMDP") else { return .none }
        for r in sig.array("Reference")?.elements ?? [] where r.isDict && r.name("TransformMethod") == "DocMDP" {
            if let p = r.dict("TransformParams")?.int("P"), let level = CertificationLevel(rawValue: p), level != .none { return level }
            return .formFilling
        }
        return .none
    }

    // ---- The PDF side: field, appearance, signature dictionary with placeholders, incremental update ----

    private static func prepare(_ data: [UInt8], _ password: String?, _ req: SignRequest, _ reserve: Int,
                                _ signedBefore: Bool) throws -> (pdf: [UInt8], gapStart: Int, gapEnd: Int) {
        var source = data
        var doc = try PdfEdit.open(source, password, failure: "This PDF can't be signed")
        if !doc.canAppend {
            // The file's structure can't be appended to (no usable last xref): normalize it first, which is only safe
            // when nothing is signed yet.
            if signedBefore { throw SigningError("This signed document's file structure can't be extended, so a new signature would break the existing ones.") }
            source = try PdfEdit.writeWhole(doc, password: password)
            doc = try PdfEdit.open(source, password, failure: "This PDF can't be signed")
            if !doc.canAppend { throw SigningError("This PDF's structure can't be signed incrementally.") }
        }
        let time = req.time ?? Date()
        let catalog = doc.catalog
        let acro: PObj
        if let a = catalog.dict("AcroForm") {
            acro = a
        } else {
            acro = doc.dict()
            catalog.set("AcroForm", acro)
        }
        let fields: PObj
        if let f = acro.array("Fields") {
            fields = f
        } else {
            fields = doc.array()
            acro.set("Fields", fields)
        }
        acro.set("SigFlags", doc.int(3))

        let widget: PObj, fieldDict: PObj, page: PObj, rect: RectD
        if let name = req.fieldName {
            guard let f = try FormEditor.collect(doc, acro).first(where: { $0.name == name }) else { throw SigningError("There is no field named \"\(name)\".") }
            if f.type != "Sig" { throw SigningError("\"\(name)\" isn't a signature field.") }
            if let v = FormEditor.inherited(f.dict, "V"), v.kind != .null { throw SigningError("\"\(name)\" is already signed.") }
            fieldDict = f.dict
            widget = f.widgets.first ?? f.dict
            let onPage = try pageOfAnnot(doc, widget)
            let pi = doc.pageIndex(of: widget["P"]) ?? onPage
            page = doc.page(max(0, pi ?? 0))
            rect = widget.array("Rect").map { PageBoxes.rectToPage(page, $0) } ?? .zero
            if pi == nil && widget.isRef { doc.annots(page).append(widget) }
        } else {
            let count = try doc.pageCount()
            guard req.pageIndex >= 0 && req.pageIndex < count else { throw SigningError("The signature's page doesn't exist.") }
            page = doc.page(req.pageIndex)
            rect = req.rect ?? .zero
            let made = doc.dict([("Type", doc.name("Annot")), ("Subtype", doc.name("Widget")), ("FT", doc.name("Sig")),
                                 ("T", doc.text(try newFieldName(doc, acro))), ("F", doc.int(132)), ("P", page)]) // print + locked
            if rect.isEmpty {
                made.set("Rect", doc.array([doc.int(0), doc.int(0), doc.int(0), doc.int(0)]))
            } else {
                let r = PageBoxes.fromPageSpace(page, rect)
                made.set("Rect", doc.realArray([r.x1, r.y1, r.x2, r.y2]))
            }
            widget = doc.add(made)
            fieldDict = widget
            doc.annots(page).append(widget)
            fields.append(widget)
        }

        // Appearance (an empty one for invisible signatures).
        widget.set("AP", doc.dict([("N", appearance(doc, page, rect, req, time))]))

        let sig = doc.dict([("Type", doc.name("Sig")), ("Filter", doc.name("Adobe.PPKLite")),
                            ("SubFilter", doc.name(req.format == .cades ? "ETSI.CAdES.detached" : "adbe.pkcs7.detached")),
                            ("ByteRange", doc.array([doc.int(0), doc.int(1_000_000_000), doc.int(1_000_000_000), doc.int(1_000_000_000)])),
                            ("Contents", doc.string([UInt8](repeating: 0, count: reserve))),
                            ("M", doc.text(PdfDates.format(time)))])
        if let signer = req.id.certificate.commonName, !signer.isEmpty { sig.set("Name", doc.text(signer)) }
        for (key, value) in [("Reason", req.reason), ("Location", req.location), ("ContactInfo", req.contactInfo)] {
            if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sig.set(key, doc.text(value)) }
        }
        sig.set("Prop_Build", doc.dict([("App", doc.dict([("Name", doc.name("InkvoltPdf"))]))]))
        var references: [PObj] = []
        if req.certify != .none {
            let tp = doc.dict([("Type", doc.name("TransformParams")), ("P", doc.int(req.certify.rawValue)), ("V", doc.name("1.2"))])
            references.append(doc.dict([("Type", doc.name("SigRef")), ("TransformMethod", doc.name("DocMDP")), ("TransformParams", tp)]))
        }
        // A signature field's /Lock names the fields signing it locks (FieldMDP): record it in the signature, and make
        // those fields read-only, as Acrobat does.
        if let name = req.fieldName, let lock = fieldDict.dict("Lock") {
            let tp = doc.dict([("Type", doc.name("TransformParams")), ("Action", lock["Action"] ?? doc.name("All"))])
            if let lockFields = lock["Fields"] { tp.set("Fields", lockFields) }
            tp.set("V", doc.name("1.2"))
            references.append(doc.dict([("Type", doc.name("SigRef")), ("TransformMethod", doc.name("FieldMDP")), ("TransformParams", tp)]))
            try lockFields(doc, acro, lock, name)
        }
        if !references.isEmpty { sig.set("Reference", doc.array(references)) }
        let sigRef = doc.add(sig)
        fieldDict.set("V", sigRef)
        if req.certify != .none { catalog.set("Perms", doc.dict([("DocMDP", sigRef)])) }

        try doc.checkFailure()
        var pdf: [UInt8]
        do {
            pdf = try doc.append(original: source)
        } catch {
            throw SigningError("The signature can't be appended to this PDF: \(error)")
        }
        let from = source.count
        let zeros = [60] + [UInt8](repeating: 48, count: reserve * 2) + [62]
        guard let gap = pdf[from...].lastRange(of: zeros),
              let rangeAt = pdf[from...].lastRange(of: Array(rangePlaceholder.utf8)) else {
            throw SigningError("The signature placeholder wasn't written.")
        }
        let gapStart = gap.lowerBound, gapEnd = gap.upperBound
        var range = "[0 \(gapStart) \(gapEnd) \(pdf.count - gapEnd)"
        range = range.padding(toLength: rangePlaceholder.count - 1, withPad: " ", startingAt: 0) + "]"
        pdf.replaceSubrange(rangeAt, with: Array(range.utf8))
        return (pdf, gapStart, gapEnd)
    }

    private static func pageOfAnnot(_ doc: MuDoc, _ widget: PObj) throws -> Int? {
        for p in 0..<(try doc.pageCount()) where doc.page(p).array("Annots")?.elements.contains(where: { $0.identity == widget.identity }) == true {
            return p
        }
        return nil
    }

    /// Sets the read-only flag on the fields a signature field's /Lock names (/All, /Include or /Exclude).
    private static func lockFields(_ doc: MuDoc, _ acro: PObj, _ lock: PObj, _ signatureField: String) throws {
        let names = Set(lock.array("Fields")?.elements.compactMap(\.text) ?? [])
        func listed(_ name: String) -> Bool { names.contains { name == $0 || name.hasPrefix($0 + ".") } }
        let action = lock.name("Action")
        for f in try FormEditor.collect(doc, acro) where f.name != signatureField {
            let locked = action == "Include" ? listed(f.name) : action == "Exclude" ? !listed(f.name) : true
            if locked { f.dict.set("Ff", doc.int((f.dict.int("Ff") ?? 0) | 1)) }
        }
    }

    private static func newFieldName(_ doc: MuDoc, _ acro: PObj) throws -> String {
        let names = Set(try FormEditor.collect(doc, acro).map(\.name))
        var n = 1
        while names.contains("Signature\(n)") { n += 1 }
        return "Signature\(n)"
    }

    /// The visible signature's look: details on the left, the image on the right; upright on rotated pages.
    private static func appearance(_ doc: MuDoc, _ page: PObj, _ rect: RectD, _ req: SignRequest, _ time: Date) -> PObj {
        if rect.isEmpty { return doc.formXObject([], 0, 0, 0, 0, nil) }
        let look = req.look
        let w = rect.width, h = rect.height
        let cert = req.id.certificate
        let name = look.name ?? cert.commonName ?? ""
        var lines: [String] = []
        func labeled(_ label: String, _ value: String) -> String { look.showLabels ? "\(label): \(value)" : value }
        if look.showName { lines.append(look.showLabels ? "Digitally signed by \(name)" : name) }
        if look.showDistinguishedName { lines.append(labeled("DN", cert.subject)) }
        if look.showReason, let r = req.reason, !r.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(labeled("Reason", r)) }
        if look.showLocation, let l = req.location, !l.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(labeled("Location", l)) }
        if look.showDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy.MM.dd HH:mm:ss xxx"
            lines.append(labeled("Date", f.string(from: time)))
        }

        var content = ""
        let pad = min(4, min(w, h) * 0.05)
        var textW = w - 2 * pad
        var image: PObj?
        if let img = look.image, img.width > 0, img.height > 0 {
            image = SignatureStamps.imageXObject(doc, img)
            let aspect = Double(img.width) / Double(img.height)
            let boxW = lines.isEmpty ? w - 2 * pad : min((w - 2 * pad) * 0.5, (h - 2 * pad) * aspect)
            let iw = min(boxW, (h - 2 * pad) * aspect)
            let ih = iw / aspect
            let ix = w - pad - boxW + (boxW - iw) / 2
            let iy = (h - ih) / 2
            content += "q \(PdfNum.f(iw)) 0 0 \(PdfNum.f(ih)) \(PdfNum.f(ix)) \(PdfNum.f(iy)) cm /Im1 Do Q\n"
            textW = w - 3 * pad - boxW
        }

        var ops: [UInt8] = Array(content.utf8)
        let resources: PObj
        if !lines.isEmpty && textW > 2 {
            let painter = TextPainter(.helvetica, lines)
            let widest = lines.map(painter.measure).max() ?? 0
            var size = min((h - 2 * pad) / (Double(lines.count) * 1.2), widest > 0 ? textW / widest : 12)
            size = min(max(size, 1), 14)
            var y = h - pad - size
            let block = Double(lines.count) * size * 1.2
            y -= max(0, (h - 2 * pad - block) / 2)
            for line in lines {
                painter.draw(line, pad, y, size)
                y -= size * 1.2
            }
            let built = painter.build(doc, w, h, "/Helv", .black)
            ops += built.ops
            resources = built.resources
        } else {
            resources = doc.dict()
        }
        if let image { resources.set("XObject", doc.dict([("Im1", image)])) }
        return doc.formXObject(ops, 0, 0, w, h, resources, matrix: doc.counterRotation(page))
    }

    // ---- The CMS side ----

    private static func buildCms(_ signed: [UInt8], _ req: SignRequest) async throws -> [UInt8] {
        let id = req.id
        let cert = id.certificate
        let digest = cert.digest
        let cms: CmsBuilder
        do {
            cms = try CmsBuilder(signed, signer: cert, chain: id.chain, digest: digest, signingTime: req.format == .pkcs7 ? req.time ?? Date() : nil) {
                try id.sign($0, digest)
            }
        } catch let e as KeyEncoding.Failure {
            if e.cancelled { throw CancellationError() }
            throw SigningError(e.description)
        }
        guard let tsa = req.timestamp else { return cms.encode() }
        var nonce = [UInt8](repeating: 0, count: 8)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonce.count, &nonce)
        nonce[0] = (nonce[0] & 0x7F) | 0x01
        let reply: [UInt8]
        do {
            reply = try await tsa(Rfc3161.request(cms.signature, nonce: nonce))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SigningError("The timestamp server couldn't be reached: \(error)")
        }
        let token: [UInt8]
        do {
            token = try Rfc3161.token(fromReply: reply, stamping: cms.signature, nonce: nonce).der
        } catch let e as SigningError {
            throw SigningError("The timestamp server's reply isn't usable: \(e.message)")
        } catch {
            throw SigningError("The timestamp server's reply isn't usable: it isn't a timestamp response.")
        }
        return cms.encode(unsigned: [CmsBuilder.attribute(Oids.timestampToken, token)])
    }

    /// The ESS signing-certificate-v2 attribute value (RFC 5035): the signer certificate's hash and issuer/serial.
    static func signingCertificateV2(_ cert: Certificate, _ digest: DigestAlgorithm) -> [UInt8] {
        var id: [[UInt8]] = []
        if digest != .sha256 { id.append(DerWriter.seq([DerWriter.oid(digest.oid)])) }
        id.append(DerWriter.octets(digest.hash(cert.der)))
        id.append(DerWriter.seq([DerWriter.seq([DerWriter.context(4, cert.issuerRaw)]), DerWriter.tlv(0x02, cert.serial)]))
        return DerWriter.seq([DerWriter.seq([DerWriter.seq(id)])])
    }
}
