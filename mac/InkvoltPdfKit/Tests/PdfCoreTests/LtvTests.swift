import Foundation
@preconcurrency import Security
import Testing
@testable import PdfCore

/// Ported from LtvTests.cs (roadmap 3.4): PAdES B-LT and B-LTA against a local authority (`LtvTestPki`, on this Mac's
/// loopback), and what a hostile file can't make it do. Adapted: verifying with the generated root trusted for the check
/// alone is `Signatures.verify(_:_:anchors:)`; a server that stalls waits with `LtvTestPki.pause`, which `stop` ends, so no
/// thread outlives a test; A_compressed_stream_that_explodes_isn_t_inflated packs 64 MB of zeros (400 MB on Windows) and
/// checks the time, not .NET's allocation counter, which Swift hasn't (MuPDF reads such a stream through `streamHead`,
/// bounded); The_suggested_timestamp_server_answers_and_its_timestamp_verifies is opt-in, as on Windows
/// (`INKVOLTPDF_REAL_TSA`). The tests of what only looks like validation data sign with an ID made in memory
/// (`SigningTests.rsaId`), as they did before the rest came.
struct LtvTests {
    // MARK: Helpers

    static func signBb(_ pki: LtvTestPki, _ pdf: [UInt8]? = nil, format: SignatureFormat = .cades, certify: CertificationLevel = .none) async throws -> [UInt8] {
        try await SigningTests.sign(pdf ?? TestPdf.make(2), pki.signer.id) {
            $0.reason = "Approved"
            $0.format = format
            $0.certify = certify
        }
    }

    static func signLongTerm(_ pki: LtvTestPki, _ level: LongTermLevel, _ pdf: [UInt8]? = nil) async throws -> [UInt8] {
        let client = pki.client()
        return try await SigningTests.sign(pdf ?? TestPdf.make(2), pki.signer.id) {
            $0.reason = "Approved"
            $0.timestamp = client.timestampSender(pki.timestampUrl)
            $0.longTerm = level
            $0.longTermClient = client
        }
    }

    static func first(_ pdf: [UInt8], _ pki: LtvTestPki) throws -> SignatureInfo {
        try #require(Signatures.verify(pdf, nil, anchors: pki.anchors).first { $0.subFilter != "ETSI.RFC3161" })
    }

    /// How many streams each /DSS list holds.
    static func store(_ pdf: [UInt8]) throws -> (certs: Int, ocsps: Int, crls: Int, vri: Int) {
        let doc = try MuDoc.open(pdf)
        let dss = try #require(doc.catalog.dict("DSS"))
        return (dss.array("Certs")?.count ?? 0, dss.array("OCSPs")?.count ?? 0, dss.array("CRLs")?.count ?? 0, dss.dict("VRI")?.count ?? 0)
    }

    static func starts(_ pdf: [UInt8], with prefix: [UInt8]) -> Bool { pdf.count >= prefix.count && Array(pdf[..<prefix.count]) == prefix }

    static func message(_ body: () async throws -> Void) async -> String? {
        do {
            try await body()
            return nil
        } catch let e as SigningError {
            return e.message
        } catch let e as LtvFetchError {
            return e.message
        } catch {
            return "\(error)"
        }
    }

    // MARK: Levels

    @Test func signingForTheLongTermStoresTheWholeChainAndReachesBLt() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let pdf = try await Self.signLongTerm(pki, .lt)
        let s = try Self.first(pdf, pki)
        #expect(s.status == .valid)
        #expect(s.certificateTrusted, "\(s.certificateStatus)")
        let lt = try #require(s.longTerm)
        #expect(lt.level == .blt)
        #expect(lt.dataComplete)
        #expect(lt.onlyValidationDataAfter)
        #expect(lt.summary.contains("LTV enabled"))
        let stored = try Self.store(pdf)
        #expect(stored.certs >= 4, "signer, intermediate, root, timestamp authority: \(stored.certs)")
        #expect(stored.ocsps >= 3, "signer, intermediate, timestamp authority: \(stored.ocsps)")
        #expect(stored.vri == 1)
        // The signer's intermediate wasn't on this Mac or in the signature: it came from the address the certificate names.
        #expect(pki.hits.contains { $0.hasPrefix("/cert/") })
    }

    @Test func signingForBLtaAddsADocumentTimestampAndItsAuthoritysData() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let pdf = try await Self.signLongTerm(pki, .lta)
        let all = Signatures.verify(pdf, nil, anchors: pki.anchors)
        #expect(all.count == 2)
        let s = try #require(all.first { $0.subFilter != "ETSI.RFC3161" })
        let stamp = try #require(all.first { $0.subFilter == "ETSI.RFC3161" })
        #expect(s.status == .valid)
        #expect(s.longTerm?.level == .blta)
        #expect(stamp.status == .valid)
        #expect(stamp.hasTimestamp)
        #expect(stamp.certificateTrusted, "\(stamp.certificateStatus)")
        #expect(stamp.longTerm?.dataComplete == true, "\(stamp.longTerm?.summary ?? "")")
        #expect(try Self.store(pdf).vri == 2)
    }

    @Test func aPlainSignatureIsBBAndGoesNowhere() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let s = try Self.first(try await Self.signBb(pki), pki)
        #expect(s.longTerm?.level == .bb)
        #expect(s.longTerm?.dataComplete == false)
        #expect(pki.hits.isEmpty)
    }

    @Test func anAdbePkcs7SignatureIsNoPadesLevel() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        #expect(try Self.first(try await Self.signBb(pki, format: .pkcs7), pki).longTerm?.level == PadesLevel.none)
    }

    // MARK: Add Verification Information

    @Test func addingVerificationInformationIsAnUpdateThatLeavesTheSignatureValid() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        let result = try await Ltv.addVerification(signed, nil, pki.client())
        #expect(result.changed)
        #expect(Self.starts(result.pdf, with: signed), "the signed bytes stay as they were")
        let s = try Self.first(result.pdf, pki)
        #expect(s.status == .valid)
        #expect(s.longTerm?.dataComplete == true)
        // No timestamp asked for: the data is in the file but nothing proves when it was signed.
        #expect(s.longTerm?.level == .bb)
        #expect(result.contacts.contains { $0.kind == .ocsp })
        for c in result.certificates { #expect(c.covered, "\(c.outcome)") }
    }

    @Test func addingVerificationInformationWithATimestampReachesBLta() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        let client = pki.client()
        let result = try await Ltv.addVerification(signed, nil, client, documentTimestamp: client.timestampSender(pki.timestampUrl))
        #expect(Self.starts(result.pdf, with: signed))
        #expect(try Self.first(result.pdf, pki).longTerm?.level == .blta)
        #expect(try Self.first(result.pdf, pki).status == .valid)
        // One document timestamp gives a signature without one its time, the other goes over the data.
        #expect(Signatures.verify(result.pdf).filter { $0.subFilter == "ETSI.RFC3161" }.count == 2)
    }

    @Test func aBTSignatureWithVerificationInformationReachesBLt() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let client = pki.client()
        let stamped = try await SigningTests.sign(TestPdf.make(1), pki.signer.id) { $0.timestamp = client.timestampSender(pki.timestampUrl) }
        #expect(try Self.first(stamped, pki).longTerm?.level == .bt)
        let result = try await Ltv.addVerification(stamped, nil, client)
        #expect(try Self.first(result.pdf, pki).longTerm?.level == .blt)
    }

    @Test func theSuggestedTimestampServerIsOneTheRulesAccept() {
        #expect(LtvClient.whyRefused(LtvPlan.suggestedTimestampServer, .timestamp) == nil)
    }

    /// The real suggested server, opt-in (INKVOLTPDF_REAL_TSA set): it gets a hash of a test signature.
    @Test func theSuggestedTimestampServerAnswersAndItsTimestampVerifies() async throws {
        guard let v = ProcessInfo.processInfo.environment["INKVOLTPDF_REAL_TSA"], !v.isEmpty else { return }
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let real = LtvClient()
        let stamped = try await SigningTests.sign(TestPdf.make(1), pki.signer.id) { $0.timestamp = real.timestampSender(LtvPlan.suggestedTimestampServer) }
        #expect(try Self.first(stamped, pki).longTerm?.level == .bt)
    }

    @Test func verificationInformationWorksOnEverySignatureInAFile() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let other = try pki.issue("Second Signer", pki.intermediate, ku: 0x40)
        let once = try await Self.signBb(pki)
        let twice = try await SigningTests.sign(once, other.id)
        let result = try await Ltv.addVerification(twice, nil, pki.client())
        let all = Signatures.verify(result.pdf, nil, anchors: pki.anchors)
        #expect(all.count == 2)
        for s in all { #expect(s.longTerm?.dataComplete == true, "\(s.longTerm?.summary ?? "")") }
        #expect(all.first { $0.signerName?.contains("Long-Term") == true }?.status == .modifiedAfterSigning) // another signature followed it
        #expect(all.first { $0.signerName == "Second Signer" }?.status == .valid)
        #expect(try Self.store(result.pdf).vri == 2)
    }

    @Test func verificationInformationWorksOnAFileWithAnXrefStream() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await SigningTests.sign(try IncrSignatureTests.signedForm(xrefStream: true), pki.signer.id)
        let result = try await Ltv.addVerification(signed, nil, pki.client())
        #expect(Self.starts(result.pdf, with: signed))
        #expect(Signatures.verify(result.pdf, nil, anchors: pki.anchors).first { $0.signerName?.contains("Long-Term") == true }?.status == .valid)
    }

    @Test func aNoChangesCertificationTakesVerificationInformationAndATimestamp() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let certified = try await Self.signBb(pki, certify: .noChanges)
        let client = pki.client()
        let result = try await Ltv.addVerification(certified, nil, client, documentTimestamp: client.timestampSender(pki.timestampUrl))
        let s = try Self.first(result.pdf, pki)
        #expect(s.certificationLevel == 1)
        #expect(s.status == .valid)
        #expect(s.longTerm?.level == .blta)
        // And the certification still bites after them.
        let noted = try Annotations.addNote(result.pdf, nil, 0, 100, 100, "Hello", author: "Eve")
        #expect(try Self.first(noted, pki).status == .disallowedChanges)
    }

    @Test func aSecondRunWithNothingNewChangesNothingAndAsksNobody() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let done = try await Ltv.addVerification(try await Self.signBb(pki), nil, pki.client()).pdf
        let before = pki.hits.count
        let second = try await Ltv.addVerification(done, nil, pki.client())
        #expect(!second.changed)
        #expect(second.pdf == done)
        #expect(pki.hits.count == before)
        #expect(second.contacts.isEmpty)
        #expect(Ltv.plan(done).complete)
    }

    @Test func aTimestampCanBeRenewedOverEarlierOnes() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let lta = try await Self.signLongTerm(pki, .lta)
        let client = pki.client()
        let renewed = try await Ltv.addVerification(lta, nil, client, documentTimestamp: client.timestampSender(pki.timestampUrl))
        let all = Signatures.verify(renewed.pdf, nil, anchors: pki.anchors)
        #expect(all.filter { $0.subFilter == "ETSI.RFC3161" }.count == 2)
        #expect(all.first { $0.subFilter != "ETSI.RFC3161" }?.longTerm?.level == .blta)
        for s in all { #expect(s.status == .valid, "\(s.fieldName): \(s.detail ?? "")") }
    }

    @Test func aDelegatedResponderCountsWhenItsIssuerDelegatedIt() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.delegateOcsp = true
        let s = try Self.first(try await Self.signLongTerm(pki, .lt), pki)
        #expect(s.longTerm?.level == .blt)
        #expect(s.longTerm?.chain.contains { $0.name == "Test OCSP Responder" && $0.outcome == .noCheckNeeded } == true)
    }

    @Test func aSelfSignedIdStoresItselfAndAsksNobody() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let id = try DigitalIds.createPersonal(name: "Grace Hopper", email: nil, organization: nil, inKeychain: false)
        let signed = try await SigningTests.sign(TestPdf.make(1), id)
        let result = try await Ltv.addVerification(signed, nil, pki.client())
        #expect(result.contacts.isEmpty)
        #expect(pki.hits.isEmpty)
        let all = Signatures.verify(result.pdf)
        #expect(all.count == 1 && all[0].status == .valid)
        #expect(try Self.store(result.pdf).certs >= 1)
    }

    // MARK: Revocation

    @Test func aCertificateRevokedBeforeSigningLosesItsTrustFromTheFileAlone() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.revoke(pki.signer, at: Date() - 86400)
        let signed = try await Self.signBb(pki)
        #expect(!(try Self.first(signed, pki).certificateStatus.contains("Revoked"))) // nothing in the file says so yet
        let result = try await Ltv.addVerification(signed, nil, pki.client())
        let s = try Self.first(result.pdf, pki)
        #expect(!s.certificateTrusted)
        #expect(s.certificateStatus.contains("Revoked"))
        #expect(result.certificates.contains { $0.outcome.contains("REVOKED") })
        #expect(s.longTerm?.chain.contains { $0.outcome == .revoked } == true)
    }

    @Test func aRevokedIdCantSignForTheLongTerm() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.revoke(pki.signer, at: Date() - 86400)
        let message = await Self.message { _ = try await Self.signLongTerm(pki, .lt) }
        #expect(message?.contains("revoked") == true, "\(message ?? "")")
    }

    @Test func aRevocationAfterATrustedTimestampDoesntTouchTheSignature() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let client = pki.client()
        let stamped = try await SigningTests.sign(TestPdf.make(1), pki.signer.id) { $0.timestamp = client.timestampSender(pki.timestampUrl) }
        pki.revoke(pki.signer, at: Date() + 3600)
        let result = try await Ltv.addVerification(stamped, nil, client)
        let s = try Self.first(result.pdf, pki)
        #expect(s.certificateTrusted, "\(s.certificateStatus)")
        #expect(s.longTerm?.chain.contains { $0.outcome == .revokedLater } == true)
        #expect(s.longTerm?.summary.contains("revoked later") == true)
    }

    @Test func crlAnswersWhenTheResponderDoesnt() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/ocsp") { _ in LtvTestPki.http(500, []) }
        let pdf = try await Self.signLongTerm(pki, .lt)
        #expect(try Self.first(pdf, pki).longTerm?.level == .blt)
        #expect(try Self.store(pdf).crls >= 2)
        #expect(try Self.store(pdf).ocsps == 0)
    }

    @Test func aListedCertificateOnACrlCountsAsRevoked() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/ocsp") { _ in LtvTestPki.http(503, []) }
        pki.revoke(pki.signer, at: Date() - 2 * 86400)
        let signed = try await Self.signBb(pki)
        let s = try Self.first(try await Ltv.addVerification(signed, nil, pki.client()).pdf, pki)
        #expect(!s.certificateTrusted)
        #expect(s.certificateStatus.contains("Revoked"))
    }

    @Test func checkingOnlineChangesNothingAndFindsARevocation() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        pki.revoke(pki.signer, at: Date() - 86400)
        let online = try await Ltv.checkOnline(signed, nil, pki.client())
        #expect(online.problem == nil)
        #expect(online.certificates.contains { $0.outcome.contains("REVOKED") })
        let checkedNow = try #require(Signatures.verify(signed, nil, online: online.snapshot).first)
        #expect(!checkedNow.certificateTrusted)
        #expect(checkedNow.certificateStatus.contains("Revoked"))
        // Once more without it: the check was for that moment only, and the file holds nothing.
        #expect(Signatures.verify(signed).first?.certificateStatus.contains("Revoked") == false)
    }

    // MARK: Offline, and servers that misbehave

    @Test func offlineAddingFailsClearlyAndLeavesTheInputAlone() async throws {
        let pki = try LtvTestPki()
        let signed = try await Self.signBb(pki)
        let copy = signed
        pki.stop() // the "internet" is gone
        let message = await Self.message { _ = try await Ltv.addVerification(signed, nil, pki.client(10)) }
        #expect(message?.contains("Nothing was changed") == true, "\(message ?? "")")
        #expect(message?.contains("can't be reached") == true, "\(message ?? "")")
        #expect(copy == signed)
    }

    @Test func offlineSigningForTheLongTermGivesNoFile() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/ocsp") { _ in LtvTestPki.http(503, []) }
        for issuer in [pki.intermediate!, pki.root!] { pki.override("/crl/\(issuer.thumbprint).crl") { _ in LtvTestPki.http(503, []) } }
        let message = await Self.message { _ = try await Self.signLongTerm(pki, .lta) }
        #expect(message?.contains("answered with an error") == true, "\(message ?? "")")
        #expect(message?.contains("Nothing was changed") == true)
    }

    @Test func aTimestampServerThatFailsLeavesNoHalfWrittenFile() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        let message = await Self.message {
            _ = try await Ltv.addVerification(signed, nil, pki.client(), documentTimestamp: { _ in throw LtvFetchError("no.example.com can't be reached.") })
        }
        #expect(message?.contains("Nothing was changed") == true, "\(message ?? "")")
    }

    @Test(arguments: ["garbage", "forged", "other"])
    func aRespondersBadAnswerIsNotStored(_ kind: String) async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let forger = try KeyEncoding.ephemeral(rsaBits: 2048)
        let other = LtvTestPki.ocspRequest(pki.intermediate, pki.root)
        pki.override("/ocsp") { body in
            let reply: [UInt8] = switch kind {
            case "garbage": Array("<html>Sign in to the hotel Wi-Fi</html>".utf8)
            case "forged": (try? pki.ocspReply(body, forgedKey: forger)) ?? []
            default: (try? pki.ocspReply(other)) ?? []
            }
            return LtvTestPki.http(200, reply)
        }
        // Nothing else answers either, so the run ends with the responder's problem.
        for issuer in [pki.intermediate!, pki.root!] { pki.override("/crl/\(issuer.thumbprint).crl") { _ in LtvTestPki.http(404, []) } }
        let signed = try await Self.signBb(pki)
        let message = await Self.message { _ = try await Ltv.addVerification(signed, nil, pki.client()) }
        #expect(message?.contains("Nothing was changed") == true, "\(message ?? "")")
    }

    @Test func anAnswerTooOldForTheSigningTimeIsntStored() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/ocsp") { body in LtvTestPki.http(200, (try? pki.ocspReply(body, thisUpdate: Date() - 30 * 86400)) ?? []) }
        for issuer in [pki.intermediate!, pki.root!] { pki.override("/crl/\(issuer.thumbprint).crl") { _ in LtvTestPki.http(404, []) } }
        let client = pki.client()
        let stamped = try await SigningTests.sign(TestPdf.make(1), pki.signer.id) { $0.timestamp = client.timestampSender(pki.timestampUrl) }
        let message = await Self.message { _ = try await Ltv.addVerification(stamped, nil, client) }
        #expect(message?.contains("too old") == true, "\(message ?? "")")
        #expect(message?.contains("Nothing was changed") == true)
    }

    @Test func anOversizedReplyIsCutOff() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/big") { _ in LtvTestPki.http(200, [UInt8](repeating: 0, count: LtvClient.maxOcspReply + 1)) }
        pki.override("/chunked") { _ in
            let chunk = [UInt8](repeating: 0, count: 200_000)
            let one = Array("\(String(chunk.count, radix: 16, uppercase: true))\r\n".utf8) + chunk + Array("\r\n".utf8)
            return Array("HTTP/1.1 200 X\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n".utf8) + one + one + Array("0\r\n\r\n".utf8)
        }
        let client = pki.client()
        let a = await Self.message { _ = try await client.get("\(pki.baseUrl)/big", .ocsp, maxBytes: LtvClient.maxOcspReply) }
        #expect(a?.contains("more than") == true, "\(a ?? "")")
        let b = await Self.message { _ = try await client.get("\(pki.baseUrl)/chunked", .ocsp, maxBytes: LtvClient.maxOcspReply) }
        #expect(b?.contains("more than") == true, "\(b ?? "")")
    }

    @Test func aServerThatStallsRunsOutOfTime() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        // The server waits ten minutes (`stop` ends it): the client giving up first is what counts. Adapted: no bound on the
        // test's own time, which a loaded run's busy threads stretched to minutes on ignia-mac while the client still gave up.
        pki.override("/slow") { _ in
            pki.pause(600)
            return LtvTestPki.http(200, [])
        }
        let client = pki.client(0.4)
        let message = await Self.message { _ = try await client.get("\(pki.baseUrl)/slow", .crl, maxBytes: 1000) }
        #expect(message?.contains("didn't answer in time") == true, "\(message ?? "")")
    }

    @Test func aTimestampServerMustBeHttps() async throws {
        #expect(LtvClient.whyRefused("http://timestamp.example.com/", .timestamp)?.contains("https") == true)
        #expect(LtvClient.whyRefused("https://timestamp.example.com/", .timestamp) == nil)
        #expect(LtvClient.whyRefused("http://ocsp.example.com/", .ocsp) == nil) // as the certificate names it
        let message = await Self.message { _ = try await LtvClient().timestampSender("http://timestamp.example.com/")([1]) }
        #expect(message?.contains("https") == true, "\(message ?? "")")
    }

    // MARK: A file must not be able to make the app probe the local network

    @Test(arguments: [
        "http://127.0.0.1/", "http://127.1/", "http://2130706433/", "http://0x7f.0.0.1/", "http://localhost/", "http://x.localhost/",
        "http://localhost./", "http://127\u{3002}0\u{3002}0\u{3002}1/", "http://\u{FF4C}\u{FF4F}\u{FF43}\u{FF41}\u{FF4C}\u{FF48}\u{FF4F}\u{FF53}\u{FF54}/",
        "HTTP://LOCALHOST/", "http://[::1]/", "http://[::ffff:127.0.0.1]/", "http://0.0.0.0/", "http://10.0.0.1/", "http://172.16.0.1/",
        "http://192.168.1.1/admin", "http://169.254.169.254/latest/meta-data/", "http://100.64.0.1/", "http://[fe80::1]/", "http://[fc00::1]/",
        "http://[fd12:3456::1]/", "http://printer/", "http://nas.local/", "http://router.lan/", "http://service.internal/", "http://224.0.0.1/",
        "file:///C:/Windows/win.ini", "ldap://directory.example.com/", "ftp://example.com/x.crl", "https://user:pw@example.com/",
    ])
    func addressesOnThisPcOrALocalNetworkAreRefused(_ url: String) {
        #expect(LtvClient.whyRefused(url, .ocsp) != nil)
    }

    @Test(arguments: ["http://ocsp.example.com/", "https://crl.example.com/ca.crl", "http://93.184.216.34/"])
    func publicAddressesACertificateNamesAreFine(_ url: String) {
        #expect(LtvClient.whyRefused(url, .crl) == nil)
    }

    @Test(arguments: [
        ("127.0.0.1", false), ("10.1.2.3", false), ("192.168.0.10", false), ("169.254.169.254", false), ("::1", false), ("fe80::1", false),
        ("fc00::1", false), ("::ffff:192.168.0.1", false), ("64:ff9b::a00:1", false), ("2002:a00:1::", false), ("2001::1", false),
        ("ff02::1", false), ("93.184.216.34", true), ("2606:2800:220:1::1", true),
    ])
    func whichAddressesCountAsPublic(_ address: String, _ expected: Bool) throws {
        #expect(LtvClient.isPublic(try #require(AiAddress(address))) == expected)
    }

    /// A Mac addition (the Mac writes the request line itself): a line break in an address a certificate names can't start
    /// a header of its own.
    @Test func anAddressCantAddLinesToTheRequest() throws {
        #expect(LtvClient.parse("http://ocsp.example.com/a\r\nX-Evil: 1 é")?.path == "/a%0D%0AX-Evil:%201%20%C3%A9")
        #expect(LtvClient.parse("http://ocsp.example.com")?.path == "/")
        #expect(LtvClient.parse("http://ocsp.example.com?x=1#y")?.path == "/?x=1")
    }

    @Test func anOrdinaryClientWontReachAListenerOnThisPc() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let message = await Self.message { _ = try await LtvClient().get("\(pki.baseUrl)/crl/x.crl", .crl, maxBytes: 1000) }
        #expect(message?.contains("wasn't contacted") == true, "\(message ?? "")")
        #expect(pki.hits.isEmpty)
    }

    @Test func aPublicLookingNameThatResolvesToThisPcIsntContacted() async throws {
        // DNS rebinding: the name looks public and resolves to loopback or the router when asked.
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let port = try #require(LtvClient.parse(pki.baseUrl)?.port)
        for answer in ["127.0.0.1", "192.168.1.1", "169.254.169.254"] {
            let found = [try #require(AiAddress("93.184.216.34")), try #require(AiAddress(answer))]
            let client = LtvClient(allowLoopback: false, timeout: 3, resolve: { _ in found })
            let message = await Self.message { _ = try await client.get("http://ocsp.example.com:\(port)/ocsp", .ocsp, maxBytes: 1000) }
            #expect(message?.contains("wasn't contacted") == true, "\(message ?? "")")
        }
        #expect(pki.hits.isEmpty)
    }

    @Test(arguments: ["http://192.168.1.1/admin", "http://169.254.169.254/latest/meta-data/", "http://10.0.0.1/", "http://[fe80::1]/", "file:///C:/Windows/win.ini"])
    func aRedirectToALocalAddressIsntFollowed(_ target: String) async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/go") { _ in LtvTestPki.http(302, [], "Location: \(target)") }
        // Loopback is let through here only so the first hop gets anywhere in a test; everything else stays refused.
        let message = await Self.message { _ = try await pki.client().get("\(pki.baseUrl)/go", .crl, maxBytes: 1000) }
        #expect(message?.contains("wasn't contacted") == true, "\(message ?? "")")
    }

    @Test func redirectsEndSomewhere() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let loop = "\(pki.baseUrl)/loop"
        pki.override("/loop") { _ in LtvTestPki.http(302, [], "Location: \(loop)") }
        let message = await Self.message { _ = try await pki.client().get(loop, .crl, maxBytes: 1000) }
        #expect(message?.contains("too many") == true, "\(message ?? "")")
        #expect((1...5).contains(pki.hits.count))
    }

    @Test func openingAndVerifyingAFileContactsNothingItsCertificatesName() async throws {
        // The signer's issuer isn't in the file or on this Mac, and its certificate names this listener for everything: a
        // chain build left alone would fetch the issuer from it, and a revocation check would ask it too.
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        let viaDss = try await Ltv.addVerification(try await Self.signBb(pki), nil, pki.client()).pdf
        let hitsBefore = pki.hits.count
        let all = Signatures.verify(signed)
        #expect(all.count == 1 && !all[0].certificateTrusted)
        _ = Signatures.brokenByEdits(all, signed)
        _ = Signatures.verify(viaDss)
        _ = Ltv.plan(signed)
        #expect(pki.hits.count == hitsBefore)
    }

    @Test func signingGoesNowhereEither() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        #expect(pki.hits.isEmpty)
        let all = Signatures.verify(signed)
        #expect(all.count == 1 && all[0].status == .valid)
    }

    @Test func certificatesThatNameLocalAddressesAreListedAsRefusedAndReported() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let hostile = try pki.issue("Hostile", pki.intermediate, ku: 0x40, ocsp: ["http://192.168.1.1/probe"],
                                    crl: ["http://169.254.169.254/latest/meta-data/"], issuers: ["\(pki.baseUrl)/cert/\(pki.intermediate.thumbprint).cer"])
        let signed = try await SigningTests.sign(TestPdf.make(1), hostile.id)

        let plan = Ltv.plan(signed)
        #expect(plan.addresses.contains { $0.url.contains("192.168.1.1") && $0.refusedBecause != nil })
        #expect(plan.addresses.contains { $0.url.contains("169.254") && $0.refusedBecause != nil })

        let client = pki.client(10) // the test server's answers must come within it
        let result = try await Ltv.addVerification(signed, nil, client)
        #expect(!result.contacts.contains { $0.url.contains("192.168") || $0.url.contains("169.254") })
        #expect(result.certificates.contains { !$0.covered && $0.name == "Hostile" && $0.outcome.contains("local network") })
        #expect(try Self.first(result.pdf, pki).status == .valid)
        #expect(try Self.first(result.pdf, pki).longTerm?.dataComplete == false)

        // Signing for the long term with such an ID promises something it can't keep.
        let message = await Self.message {
            _ = try await SigningTests.sign(TestPdf.make(1), hostile.id) {
                $0.timestamp = client.timestampSender(pki.timestampUrl)
                $0.longTerm = .lt
                $0.longTermClient = client
            }
        }
        #expect(message?.contains("can't be complete") == true, "\(message ?? "")")
    }

    @Test func thePlanSaysWhereItWouldGoWithoutGoing() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let plan = Ltv.plan(try await Self.signBb(pki))
        #expect(pki.hits.isEmpty)
        #expect(!plan.complete)
        #expect(plan.addresses.contains { $0.kind == .ocsp && $0.forWhom == "Test Long-Term Signer" })
        #expect(plan.addresses.contains { $0.kind == .issuer })
        for a in plan.addresses { #expect(a.refusedBecause != nil) } // the listener's on loopback, which no real client reaches
        for kind in LtvAddressKind.allCases { #expect(!LtvPlan.whatIsSent(kind).isEmpty) }
    }

    // MARK: Hostile stores

    /// Appends an update that points the catalog's /DSS at `dss`, with any extra objects.
    static func withDss(_ pdf: [UInt8], _ dss: String, _ objects: [Int: [UInt8]] = [:]) throws -> [UInt8] {
        let text = String(decoding: pdf.map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        func last(_ pattern: String) -> String? {
            let re = try? NSRegularExpression(pattern: pattern)
            let ns = text as NSString
            guard let m = re?.matches(in: text, range: NSRange(location: 0, length: ns.length)).last else { return nil }
            return ns.substring(with: m.range(at: 1))
        }
        let rootText = try #require(last(#"/Root\s*(\d+) \d+ R"#))
        let root = try #require(Int(rootText))
        let start = try #require(text.range(of: "\n\(root) 0 obj", options: .backwards)).upperBound
        let end = try #require(text[start...].range(of: "endobj")).lowerBound
        var body = text[start..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        let close = try #require(body.range(of: ">>", options: .backwards))
        body = String(body[..<close.lowerBound]) + " /DSS \(dss) >>"
        let ns = text as NSString
        let sizes = (try? NSRegularExpression(pattern: #"/Size (\d+)"#))?.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .compactMap { Int(ns.substring(with: $0.range(at: 1))) } ?? []
        let prev = try #require(last(#"startxref\s+(\d+)"#))
        var all = objects
        all[root] = Array(body.utf8)
        var out = pdf + [10]
        var offsets: [(Int, Int)] = []
        for (n, value) in all.sorted(by: { $0.key < $1.key }) {
            offsets.append((n, out.count))
            out += Array("\(n) 0 obj\n".utf8) + value + Array("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n"
        for (n, at) in offsets { table += "\(n) 1\n\(String(format: "%010d", at)) 00000 n \n" }
        table += "trailer\n<< /Size \(max(sizes.max() ?? 0, (all.keys.max() ?? 0) + 1)) /Root \(root) 0 R /Prev \(prev) >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    static func streamObject(_ data: [UInt8], _ extra: String = "") -> [UInt8] {
        Array("<< /Length \(data.count)\(extra) >>\nstream\n".utf8) + data + Array("\nendstream".utf8)
    }

    @Test(arguments: [
        "/Name", "42", "null", "(a string)", "[1 2 3]",
        "<< /Certs /Nope /OCSPs 7 /CRLs (x) /VRI [1] >>",
        "<< /Certs [999 0 R] /OCSPs [null 1 (x) [] <<>>] /CRLs [<< /Length 5 >>] >>",
        "<< /VRI << /ABC /Nope /DEF << /Cert 5 /OCSP (x) /CRL [999 0 R] >> >> >>",
    ])
    func aStoreOfTheWrongShapeIsNoStore(_ dss: String) async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let s = try Self.first(try Self.withDss(try await Self.signBb(pki), dss), pki)
        #expect(s.status == .valid)
        #expect(s.longTerm?.dataComplete == false)
    }

    @Test func aStoreThatRefersToItselfIsNoStore() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let n = 900
        let pdf = try Self.withDss(try await Self.signBb(pki), "\(n) 0 R", [
            n: Array("<< /Certs \(n + 1) 0 R /OCSPs [\(n) 0 R] /CRLs [\(n + 1) 0 R] /VRI \(n) 0 R >>".utf8),
            n + 1: Array("[\(n + 1) 0 R \(n) 0 R]".utf8),
        ])
        #expect(try Self.first(pdf, pki).status == .valid)
    }

    @Test func garbageAndOversizedDataInAStoreAreSkippedQuickly() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        var objects: [Int: [UInt8]] = [:]
        var lists = ""
        var n = 1000
        // Far more streams than a store is read for, and streams too large to read.
        for _ in 0..<1500 {
            objects[n] = Self.streamObject((0..<32).map { _ in UInt8.random(in: 0...255) })
            lists += "\(n) 0 R "
            n += 1
        }
        objects[n] = Self.streamObject([UInt8](repeating: 0, count: RevocationPool.maxCertBytes + 1))
        lists += "\(n) 0 R "
        let pdf = try Self.withDss(try await Self.signBb(pki), "<< /Certs [\(lists)] /OCSPs [\(lists)] /CRLs [\(lists)] >>", objects)
        let started = Date()
        #expect(try Self.first(pdf, pki).status == .valid)
        #expect(Date().timeIntervalSince(started) < 30)
    }

    @Test func aCompressedStreamThatExplodesIsntInflated() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let maker = try MuDoc.create()
        let packed = try #require(maker.addStream([UInt8](repeating: 0, count: 64 << 20), deflate: true).rawStreamData) // 64 MB of zeros, packed small
        let pdf = try Self.withDss(try await Self.signBb(pki), "<< /CRLs [950 0 R] /OCSPs [950 0 R] /Certs [950 0 R] >>",
                                   [950: Self.streamObject(packed, " /Filter /FlateDecode")])
        let started = Date()
        #expect(try Self.first(pdf, pki).status == .valid)
        #expect(Date().timeIntervalSince(started) < 30, "stopped long before the end of it")
    }

    @Test func aForgedAnswerInAStoreCountsForNothing() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let forger = try KeyEncoding.ephemeral(rsaBits: 2048)
        let signed = try await Self.signBb(pki)
        let real = try await Ltv.addVerification(signed, nil, pki.client()).pdf
        #expect(try Self.first(real, pki).longTerm?.dataComplete == true)

        // "Good", in the responder's format, signed by nobody it should be. And a forged "revoked" doesn't take trust away.
        let request = LtvTestPki.ocspRequest(pki.signer, pki.intermediate)
        let forgedGood = try pki.ocspReply(request, forgedKey: forger)
        pki.revoke(pki.signer, at: Date() - 86400)
        let forgedRevoked = try pki.ocspReply(request, forgedKey: forger)
        let pdf = try Self.withDss(signed, "<< /OCSPs [950 0 R 951 0 R] >>", [950: Self.streamObject(forgedGood), 951: Self.streamObject(forgedRevoked)])
        let s = try Self.first(pdf, pki)
        #expect(!s.certificateStatus.contains("Revoked"))
        #expect(s.longTerm?.dataComplete == false)
        #expect(s.longTerm?.chain.contains { $0.name == "Test Long-Term Signer" && ($0.outcome == .noData || $0.outcome == .noIssuer) } == true)
    }

    @Test func aStoreCantHideAChangeToTheDocument() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let pdf = try await Ltv.addVerification(try await Self.signBb(pki), nil, pki.client()).pdf
        #expect(try Self.first(pdf, pki).status == .valid)
        // A comment added on top of the data: no longer only validation data.
        let noted = try Annotations.addNote(pdf, nil, 0, 100, 100, "Later", author: "Eve")
        let s = try Self.first(noted, pki)
        #expect(s.status == .modifiedAfterSigning)
        #expect(s.longTerm?.onlyValidationDataAfter == false)
    }

    @Test func encryptedFilesAreRefusedWithAReason() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let message = await Self.message { _ = try await Ltv.addVerification(TestPdf.encrypted(1, "pw"), "pw", pki.client()) }
        #expect(message?.contains("Encrypted") == true, "\(message ?? "")")
    }

    @Test func aFileWithoutSignaturesHasNothingToAdd() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let message = await Self.message { _ = try await Ltv.addVerification(TestPdf.make(1), nil, pki.client()) }
        #expect(message?.contains("isn't signed") == true, "\(message ?? "")")
        #expect(pki.hits.isEmpty)
    }

    // MARK: What only looks like validation data

    private static func signed(_ level: CertificationLevel = .none, _ pdf: [UInt8] = TestPdf.make(2)) async throws -> [UInt8] {
        try await SigningTests.sign(pdf, try SigningTests.rsaId()) { $0.certify = level }
    }

    private static func onlyFirst(_ pdf: [UInt8]) throws -> SignatureInfo {
        try #require(Signatures.verify(pdf).first)
    }

    private static func pixelsChanged(_ a: [UInt8], _ b: [UInt8]) throws -> Double {
        let ea = try PdfEngine.open(a), eb = try PdfEngine.open(b)
        defer {
            ea.close()
            eb.close()
        }
        let pa = try ea.render(0, scale: 1).pixels, pb = try eb.render(0, scale: 1).pixels
        try #require(pa.count == pb.count)
        return Double(zip(pa, pb).count { $0 != $1 }) / Double(pa.count)
    }

    private static func overlay(_ doc: MuDoc, _ subtype: String, _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ flags: Int) -> PObj {
        let look = doc.addStream(Array("0 0 0 rg 0 0 300 300 re f".utf8), dict: doc.dict([
            ("Type", doc.name("XObject")), ("Subtype", doc.name("Form")), ("BBox", doc.array([0, 0, 300, 300].map { doc.int($0) })),
        ]), deflate: false)
        return doc.dict([
            ("Type", doc.name("Annot")), ("Subtype", doc.name(subtype)), ("F", doc.int(flags)),
            ("Rect", doc.array([x1, y1, x2, y2].map { doc.int($0) })), ("AP", doc.dict([("N", look)])),
        ])
    }

    /// An update adding a signature field that says it is a document timestamp and has nothing behind that but the name.
    private static func withFakeTimestamp(_ signed: [UInt8], _ x1: Int, _ y1: Int, _ x2: Int, _ y2: Int, _ flags: Int) throws -> [UInt8] {
        let doc = try PdfEdit.open(signed, nil)
        let page = doc.page(0)
        let widget = overlay(doc, "Widget", x1, y1, x2, y2, flags)
        widget.set("FT", doc.name("Sig"))
        widget.set("T", doc.text("Timestamp9"))
        widget.set("P", page)
        widget.set("V", doc.add(doc.dict([("SubFilter", doc.name("ETSI.RFC3161"))])))
        let ref = doc.add(widget)
        doc.annots(page).append(ref)
        try #require(doc.catalog.dict("AcroForm")?.array("Fields")).append(ref)
        return try doc.append(original: signed)
    }

    @Test(arguments: [(CertificationLevel.none, SignatureStatus.modifiedAfterSigning), (.noChanges, .disallowedChanges)])
    func aFieldDrawnOverThePageThatCallsItselfATimestampIsAChange(_ level: CertificationLevel, _ expected: SignatureStatus) async throws {
        let signed = try await Self.signed(level)
        let forged = try Self.withFakeTimestamp(signed, 50, 50, 350, 350, 4)
        #expect(try Self.pixelsChanged(signed, forged) > 0.05)
        #expect(try Self.onlyFirst(forged).status == expected)
    }

    @Test(arguments: [(CertificationLevel.none, SignatureStatus.modifiedAfterSigning), (.noChanges, .disallowedChanges)])
    func anInvisibleFieldWithNoRealTimestampInItIsAChange(_ level: CertificationLevel, _ expected: SignatureStatus) async throws {
        let forged = try Self.withFakeTimestamp(try await Self.signed(level), 0, 0, 0, 0, 132)
        #expect(try Self.onlyFirst(forged).status == expected)
    }

    @Test(arguments: [
        (0, 0, 0, 0, 132), // what we write
        (100, 100, 100, 400, 4), // no width
        (50, 50, 350, 350, 2), // hidden
    ])
    func whatCountsAsAnInvisibleFieldReallyDrawsNothing(_ box: (Int, Int, Int, Int, Int)) async throws {
        let signed = try await Self.signed()
        #expect(try Self.pixelsChanged(signed, Self.withFakeTimestamp(signed, box.0, box.1, box.2, box.3, box.4)) == 0)
    }

    private static func withDirectAnnotation(_ signed: [UInt8], _ subtype: String) throws -> [UInt8] {
        let doc = try PdfEdit.open(signed, nil)
        doc.annots(doc.page(0)).append(overlay(doc, subtype, 50, 50, 350, 350, 4))
        doc.catalog.set("DSS", doc.dict())
        return try doc.append(original: signed)
    }

    @Test(arguments: [
        (CertificationLevel.none, "Stamp", SignatureStatus.modifiedAfterSigning),
        (.noChanges, "Stamp", .disallowedChanges),
        (.none, "Widget", .modifiedAfterSigning),
        (.noChanges, "Widget", .disallowedChanges),
    ])
    func anAnnotationWrittenInsideThePagesListIsAChange(_ level: CertificationLevel, _ subtype: String, _ expected: SignatureStatus) async throws {
        let signed = try await Self.signed(level)
        let forged = try Self.withDirectAnnotation(signed, subtype)
        if subtype == "Stamp" { #expect(try Self.pixelsChanged(signed, forged) > 0.05) }
        #expect(try Self.onlyFirst(forged).status == expected)
    }

    @Test func anAnnotationInsideThePagesListWhenSignedDoesntGetInTheWayOfValidationData() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let doc = try MuDoc.open(TestPdf.make(2))
        doc.annots(doc.page(0)).append(Self.overlay(doc, "Stamp", 50, 50, 100, 100, 4))
        let client = pki.client()
        let extended = try await Ltv.addVerification(try await Self.signBb(pki, try doc.write("")), nil, client,
                                                     documentTimestamp: client.timestampSender(pki.timestampUrl)).pdf
        let s = try Self.first(extended, pki)
        #expect(s.status == .valid, "\(s.detail ?? "")")
        #expect(s.longTerm?.onlyValidationDataAfter == true)
    }

    @Test(arguments: [8, 256]) // as many as a certificate's answers were looked at; as many as the store holds
    func forgedAnswersInAFileCantHideWhatTheServerSaid(_ count: Int) async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let forger = try KeyEncoding.ephemeral(rsaBits: 2048)
        let signed = try await Self.signBb(pki)
        pki.revoke(pki.signer, at: Date() - 86400)
        let request = LtvTestPki.ocspRequest(pki.signer, pki.intermediate)
        let forged = try (0..<count).map { i in try pki.ocspReply(request, forgedKey: forger, thisUpdate: Date() - Double(i + 1) * 60) }
        let pdf = try Dss.append(signed, nil, [VriEntry(key: "AA", certs: [], ocsps: forged, crls: [])])
        let online = try await Ltv.checkOnline(pdf, nil, pki.client())
        #expect(online.certificates.contains { $0.outcome.contains("REVOKED") })
        #expect(Signatures.verify(pdf, nil, online: online.snapshot).first?.certificateStatus.contains("Revoked") == true)
    }

    @Test func forgedAnswersCantPushARealOneOutOfAStore() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let forger = try KeyEncoding.ephemeral(rsaBits: 2048)
        let signed = try await Self.signBb(pki)
        pki.revoke(pki.signer, at: Date() - 86400)
        let request = LtvTestPki.ocspRequest(pki.signer, pki.intermediate)
        let answers = try (0..<8).map { i in try pki.ocspReply(request, forgedKey: forger, thisUpdate: Date() - Double(i + 1) * 60) } + [try pki.ocspReply(request)]
        let pdf = try Dss.append(signed, nil, [VriEntry(key: "AA", certs: [pki.intermediate.cert.der], ocsps: answers, crls: [])])
        #expect(try Self.first(pdf, pki).certificateStatus.contains("Revoked"))
    }

    @Test func slowServersDontUseUpTheTimeAFileIsGiven() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/ocsp") { body in
            pki.pause(11)
            return LtvTestPki.http(200, (try? pki.ocspReply(body)) ?? [])
        }
        let result = try await Ltv.addVerification(try await Self.signBb(pki), nil, pki.client(15)) // two answers, 22 s in all
        for c in result.certificates { #expect(c.covered, "\(c.name): \(c.outcome)") }
    }

    @Test func checkingOnlineAsksOnlyWhatTheWindowListed() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        let signed = try await Self.signBb(pki)
        let doc = try PdfEdit.open(signed, nil)
        doc.page(0).set("Rotate", doc.int(90))
        let changed = try doc.append(original: signed)
        #expect(try Self.first(changed, pki).status == .disallowedChanges)
        let client = pki.client()
        #expect(Ltv.plan(changed, nil, client: client, onlyMissing: false).addresses.isEmpty)
        _ = try await Ltv.checkOnline(changed, nil, client)
        #expect(pki.hits.isEmpty)
    }

    private static func cutOff() -> [UInt8] { Array("HTTP/1.1 200 X\r\nContent-Length: 1000\r\nConnection: close\r\n\r\nabc".utf8) }

    @Test func aReplyCutOffIsAServerThatCantBeUsed() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/short") { _ in Self.cutOff() }
        let message = await Self.message { _ = try await pki.client().get("\(pki.baseUrl)/short", .ocsp, maxBytes: LtvClient.maxOcspReply) }
        #expect(message?.contains("127.0.0.1") == true, "\(message ?? "")")
    }

    @Test func aRespondersReplyCutOffLeavesTheCrlToAnswer() async throws {
        let pki = try LtvTestPki()
        defer { pki.stop() }
        pki.override("/ocsp") { _ in Self.cutOff() }
        let result = try await Ltv.addVerification(try await Self.signBb(pki), nil, pki.client())
        for c in result.certificates { #expect(c.covered, "\(c.name): \(c.outcome)") }
        #expect(result.certificates.contains { $0.outcome.contains("CRL") })
    }
}

extension ProGated {
    /// Long-term validation's Pro gate (LtvProTests in LtvTests.cs): in the Pro suites, since ProTests turns
    /// `Pro.enforced` on meanwhile.
    @Suite struct LtvProTests {
        @Test func addingIsProAndVerifyingStaysFree() {
            #expect(!Pro.title(.longTermValidation).isEmpty)
            #expect(Pro.locked(.longTermValidation).lowercased().contains("long-term"))
            #expect(!Pro.describe(.longTermValidation).isEmpty)
            // The check itself is the one every Pro feature asks: off while Pro isn't enforced.
            #expect(Pro.allows(.longTermValidation))
        }
    }
}
