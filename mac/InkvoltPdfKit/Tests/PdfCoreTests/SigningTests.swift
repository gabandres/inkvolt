import Foundation
import Security
import Testing
@testable import PdfCore

/// Ported from SigningTests.cs: digital signing (Signing, DigitalIds) and handwritten signature stamps, with in-memory
/// certificates only (keys from `SecKeyCreateRandomKey` kept out of the keychain, certificates made by PdfCore's
/// `CertificateBuilder`, as .NET's `CertificateRequest` makes them). Adapted: Signing.sign is async (the timestamp
/// request); Personal_id_is_rsa3072_document_signing_and_signs makes the ID in memory (`createPersonal(inKeychain:
/// false)`): on the Mac the ID lives in the keychain, not in a .pfx (there is no LoadPfx to try a wrong password with);
/// the CMS is read with PdfCore's `CmsSignedData`.
struct SigningTests {
    static func rsaId(_ cn: String = "Test Signer", keyUsage: UInt8? = 0xC0, ekus: [String]? = nil, from: Date = Date() - 86400,
                      to: Date = Date() + 365 * 86400) throws -> DigitalId {
        let key = try KeyEncoding.ephemeral(rsaBits: 2048)
        let cert = try CertificateBuilder(subject: [(Oids.commonName, cn)], notBefore: from, notAfter: to, keyUsage: keyUsage,
                                          extendedKeyUsages: ekus).selfSigned(key)
        return DigitalId(certificate: cert, key: key)
    }

    static func ecId(_ bits: Int, _ cn: String = "EC Signer") throws -> DigitalId {
        let key = try KeyEncoding.ephemeral(ecBits: bits)
        let cert = try CertificateBuilder(subject: [(Oids.commonName, cn)], notBefore: Date() - 86400, notAfter: Date() + 365 * 86400).selfSigned(key)
        return DigitalId(certificate: cert, key: key)
    }

    static func squiggle(_ w: Int = 120, _ h: Int = 40) -> StampImage {
        var rgb = [UInt8](repeating: 0, count: w * h * 3)
        var alpha = [UInt8](repeating: 0, count: w * h)
        for x in 0..<w {
            let y0 = Int(Double(h) / 2 + sin(Double(x) / 8) * Double(h) / 3)
            for y in max(0, y0 - 2)..<min(h, y0 + 3) {
                rgb[(y * w + x) * 3 + 2] = 120 // dark blue ink
                alpha[y * w + x] = 255
            }
        }
        return StampImage(w, h, rgb, alpha)
    }

    static func sign(_ pdf: [UInt8], _ id: DigitalId, _ change: (inout SignRequest) -> Void = { _ in }) async throws -> [UInt8] {
        var req = SignRequest(id: id)
        change(&req)
        return try await Signing.sign(pdf, nil, req)
    }

    private static func only(_ pdf: [UInt8]) throws -> SignatureInfo {
        let all = Signatures.verify(pdf)
        try #require(all.count == 1)
        return all[0]
    }

    /// The last signature's CMS in the file.
    static func cms(_ pdf: [UInt8]) throws -> CmsSignedData {
        let (_, der) = try contents(pdf)
        return try CmsSignedData(der: der)
    }

    /// Where the last signature's hex starts (after "/Contents <", which MuPDF writes "/Contents<"), and its CMS (the
    /// zero padding after it left out by its DER length).
    static func contents(_ pdf: [UInt8]) throws -> (Int, [UInt8]) {
        let key = try #require(pdf.lastRange(of: Array("/Contents".utf8))).upperBound
        let start = try #require(pdf[key...].firstIndex(of: 60)) + 1
        let end = try #require(pdf[start...].firstIndex(of: 62))
        return (start, try #require(Signatures.hexContents([60] + Array(pdf[start..<end]) + [62])))
    }

    @Test func invisibleRsaSignatureIsAppendedAndValid() async throws {
        let original = TestPdf.make(2)
        let signed = try await Self.sign(original, try Self.rsaId()) {
            $0.reason = "Approved"
            $0.location = "San Juan"
        }
        #expect(Array(signed[..<original.count]) == original, "signing appends an incremental update")
        let s = try Self.only(signed)
        #expect(s.status == .valid, "\(s.detail ?? "")")
        #expect(s.coversWholeDocument)
        #expect(s.signerName == "Test Signer")
        #expect(s.subFilter == "ETSI.CAdES.detached")
        #expect(s.reason == "Approved")
        #expect(s.location == "San Juan")
        #expect(!s.hasTimestamp)
        #expect(s.signingTime != nil)
        #expect(s.rect.isEmpty)

        // PAdES: signing-certificate-v2 signed, no signing-time attribute.
        let signer = try #require(try Self.cms(signed).signers.first)
        #expect(signer.signed(Oids.signingCertificateV2) != nil)
        #expect(signer.signed(Oids.signingTime) == nil)
        #expect(TestPdf.pageNumbers(original) == TestPdf.pageNumbers(signed))
    }

    @Test func visibleEcSignatureWithImageRenders() async throws {
        let original = TestPdf.make(1)
        let rect = RectD(300, 600, 240, 70)
        let signed = try await Self.sign(original, try Self.ecId(384, "Ada Lovelace")) {
            $0.pageIndex = 0
            $0.rect = rect
            $0.reason = "I agree"
            $0.look.image = Self.squiggle()
            $0.look.showDistinguishedName = true
        }
        let s = try Self.only(signed)
        #expect(s.status == .valid, "\(s.detail ?? "")")
        #expect(s.signerName == "Ada Lovelace")
        #expect(s.pageIndex == 0)
        #expect(abs(s.rect.x - rect.x) <= 0.5)
        #expect(abs(s.rect.y - rect.y) <= 0.5)
        #expect(try Self.cms(signed).signers.first?.digestOid == "2.16.840.1.101.3.4.2.2") // SHA-384 for P-384

        #expect(try Core2Pdf.allText(signed).contains("Digitally signed by Ada Lovelace"))
        #expect(try Core2Pdf.allText(signed).contains("Reason: I agree"))
        // The image half (right) has ink too.
        #expect(try Core2Pdf.ink(signed, 0, RectD(rect.x + rect.width / 2, rect.y, rect.width / 2, rect.height)) > 0.01)
    }

    @Test func existingEmptyFieldIsSigned() async throws {
        let form = Core2Pdf.form(["<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 600 272 650] /P 3 0 R /F 4 >>"])
        #expect(try Self.only(form).status == .unsigned)
        let id = try Self.rsaId()
        let signed = try await Self.sign(form, id) { $0.fieldName = "Approval" }
        let s = try Self.only(signed)
        #expect(s.fieldName == "Approval")
        #expect(s.status == .valid, "\(s.detail ?? "")")
        #expect(s.pageIndex == 0)
        #expect(try Core2Pdf.allText(signed).contains("Digitally signed by Test Signer"))

        await #expect { try await Self.sign(signed, id) { $0.fieldName = "Approval" } } throws: { ($0 as? SigningError)?.message.contains("already signed") == true }
        await #expect(throws: SigningError.self) { try await Self.sign(form, id) { $0.fieldName = "Missing" } }
    }

    @Test func secondSignatureKeepsTheFirstIntact() async throws {
        let once = try await Self.sign(TestPdf.make(1), try Self.rsaId("First Signer")) { $0.rect = RectD(72, 600, 200, 50) }
        let twice = try await Self.sign(once, try Self.ecId(256, "Second Signer")) { $0.rect = RectD(320, 600, 200, 50) }

        #expect(Array(twice[..<once.count]) == once)
        let all = Signatures.verify(twice)
        #expect(all.count == 2)
        let a = try #require(all.first { $0.signerName == "First Signer" })
        let b = try #require(all.first { $0.signerName == "Second Signer" })
        #expect(a.status == .modifiedAfterSigning, "\(a.detail ?? "")")
        #expect(b.status == .valid, "\(b.detail ?? "")")
        #expect(a.fieldName != b.fieldName)
        #expect(Signatures.brokenByEdits(Signatures.verify(once), twice).isEmpty)
    }

    @Test func certificationIsFirstOnlyAndNoChangesBlocksSigning() async throws {
        let id = try Self.rsaId()
        let certified = try await Self.sign(TestPdf.make(1), id) { $0.certify = .formFilling }
        #expect(try Self.only(certified).status == .valid)
        #expect(Signing.certification(certified) == .formFilling)
        await #expect(throws: SigningError.self) { try await Self.sign(certified, id) { $0.certify = .formFilling } }
        // Form filling and signing allowed, but only in the certifier's own signature fields: a new one is refused
        // (SignatureChangeTests covers signing an existing field).
        await #expect(throws: SigningError.self) { try await Self.sign(certified, id) }
        let commentsToo = try await Self.sign(TestPdf.make(1), id) { $0.certify = .formFillingAndComments }
        let approved = try await Self.sign(commentsToo, id)
        #expect(Signatures.verify(approved).count == 2)
        #expect(Signatures.verify(approved).first { $0.certificationLevel == 3 }?.status == .modifiedAfterSigning)

        let locked = try await Self.sign(TestPdf.make(1), id) { $0.certify = .noChanges }
        #expect(Signing.certification(locked) == .noChanges)
        await #expect(throws: SigningError.self) { try await Self.sign(locked, id) }
    }

    @Test func timestampTokenIsEmbedded() async throws {
        let id = try Self.rsaId()
        let tsa = try FakeTsa()
        let signed = try await Self.sign(TestPdf.make(1), id) { $0.timestamp = tsa.respond }
        let s = try Self.only(signed)
        #expect(s.status == .valid, "\(s.detail ?? "")")
        #expect(s.hasTimestamp)
        // The fake authority isn't trusted: its time doesn't vouch for the certificate, and the details say so.
        #expect(s.detail?.contains("timestamp authority isn't trusted") == true, "\(s.detail ?? "")")
        #expect(tsa.requests == 1)
        let time = try #require(s.signingTime)
        #expect(time > Date() - 300 && time < Date() + 60)

        // A broken server reply is a clear error.
        await #expect(throws: SigningError.self) {
            try await Self.sign(TestPdf.make(1), id) { $0.timestamp = { _ in [0x30, 0x03, 0x02, 0x01, 0x02] } }
        }
    }

    @Test func pkcs7FormatAndExistingXrefStreamSignedFile() async throws {
        let signed = try await Self.sign(try IncrSignatureTests.signedForm(xrefStream: true), try Self.rsaId()) { $0.format = .pkcs7 }
        let all = Signatures.verify(signed)
        #expect(all.first { $0.fieldName == "Approval" }?.status == .modifiedAfterSigning)
        let mine = try #require(all.first { $0.fieldName != "Approval" })
        #expect(mine.status == .valid, "\(mine.detail ?? "")")
        #expect(mine.subFilter == "adbe.pkcs7.detached")
    }

    @Test func encryptedDocumentsAreRefused() async throws {
        let id = try Self.rsaId()
        await #expect { try await Signing.sign(TestPdf.encrypted(1, "pw"), "pw", SignRequest(id: id)) } throws: {
            ($0 as? SigningError)?.message.contains("Encrypted") == true
        }
    }

    @Test func personalIdIsRsa3072DocumentSigningAndSigns() async throws {
        let id = try DigitalIds.createPersonal(name: "Grace Hopper", email: "grace@example.com", organization: "Navy", inKeychain: false)
        #expect(DigitalIds.isUsable(id.certificate))
        #expect(id.certificate.keyBits == 3072)
        #expect(id.certificate.extendedKeyUsages?.contains(DigitalIds.documentSigningEku) == true)
        let fiveYears = Calendar(identifier: .gregorian).date(byAdding: .year, value: 5, to: Date())!
        #expect(id.certificate.notAfter > fiveYears - 2 * 86400 && id.certificate.notAfter < fiveYears + 86400)
        #expect(DigitalIds.describe(id.certificate).contains("self-signed"))
        #expect(id.certificate.subject == "CN=Grace Hopper, O=Navy, E=grace@example.com")
        let signed = try await Self.sign(TestPdf.make(1), id)
        #expect(try Self.only(signed).signerName == "Grace Hopper")
    }

    @Test func handwrittenSignatureStampPutMoveRemove() throws {
        let pdf = TestPdf.make(1)
        let rect = RectD(100, 400, 150, 50)
        let withSig = try SignatureStamps.put(pdf, nil, 0, rect, Self.squiggle())
        let stamps = try SignatureStamps.read(withSig, nil)
        try #require(stamps.count == 1)
        let stamp = stamps[0]
        #expect(stamp.kind == .signature)
        #expect(try TextStamps.read(withSig, nil).isEmpty)
        #expect(try Core2Pdf.ink(withSig, 0, rect) > 0.01)

        let moved = try SignatureStamps.put(withSig, nil, 0, RectD(300, 600, 75, 25), nil, replaceId: stamp.id)
        let after = try SignatureStamps.read(moved, nil)
        try #require(after.count == 1)
        #expect(after[0].id == stamp.id)
        #expect(abs(after[0].rect.x - 300) <= 0.5)
        #expect(try Core2Pdf.ink(moved, 0, RectD(300, 600, 75, 25)) > 0.01)
        #expect(try Core2Pdf.ink(moved, 0, rect) < 0.001)

        let removed = try TextStamps.remove(moved, nil, stamp.id)
        #expect(try SignatureStamps.read(removed, nil).isEmpty)
    }
}

/// An in-process RFC 3161 timestamp authority for tests.
final class FakeTsa: @unchecked Sendable {
    private let id: DigitalId
    private let lock = NSLock()
    private var serial = 1
    private var count = 0

    var requests: Int { lock.withLock { count } }

    init() throws {
        let key = try KeyEncoding.ephemeral(rsaBits: 2048)
        let cert = try CertificateBuilder(subject: [(Oids.commonName, "Fake TSA")], notBefore: Date() - 86400, notAfter: Date() + 365 * 86400,
                                          extendedKeyUsages: [Signatures.timestampingEku], ekuCritical: true).selfSigned(key)
        id = DigitalId(certificate: cert, key: key)
    }

    @Sendable func respond(_ request: [UInt8]) throws -> [UInt8] {
        let n: Int = lock.withLock {
            count += 1
            serial += 1
            return serial - 1
        }
        let req = try Der.parse(request).children()
        let imprint = req[1].raw
        let nonce = req.dropFirst(2).first { $0.tag == 0x02 }
        var tst: [[UInt8]] = [DerWriter.int(1), DerWriter.oid("1.2.3.4.5"), imprint, DerWriter.int(n), DerWriter.generalized(Date())]
        if let nonce { tst.append(nonce.raw) }
        let cms = try CmsBuilder(DerWriter.seq(tst), encapsulate: true, contentType: Oids.tstInfo, signer: id.certificate, chain: [],
                                 digest: .sha256, signingTime: nil) { try self.id.sign($0, .sha256) }
        return DerWriter.seq([DerWriter.seq([DerWriter.int(0)]), cms.encode()])
    }
}
