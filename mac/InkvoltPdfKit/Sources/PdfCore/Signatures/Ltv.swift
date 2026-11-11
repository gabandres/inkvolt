import Foundation
import PrintCore

/// How far signing goes beyond the signature itself.
public enum LongTermLevel: Sendable, Equatable {
    /// Just the signature (and its timestamp, when asked).
    case none
    /// PAdES B-LT: with the revocation data for the whole chain in the file. Takes a signature timestamp.
    case lt
    /// PAdES B-LTA: and a document timestamp over it all.
    case lta
}

/// One address a certificate names, or the timestamp server, and what asking it involves.
public struct LtvAddress: Sendable, Equatable {
    public let kind: LtvAddressKind
    public let url: String
    /// The certificate it would be asked about.
    public let forWhom: String
    /// Why it won't be contacted, whatever is decided; nil when it may be.
    public let refusedBecause: String?
}

/// What would go online, worked out without going online.
public struct LtvPlan: Sendable {
    /// Each once.
    public let addresses: [LtvAddress]
    /// What else to know (signatures left out, certificates that name no address).
    public let notes: [String]
    /// The file already holds everything: nothing needs asking.
    public let complete: Bool

    /// The server the timestamp field starts with, until the person enters another: free, answers over https. Nothing is
    /// sent unless they ask for a timestamp.
    public static let suggestedTimestampServer = "https://timestamp.sectigo.com"

    /// A plain line for each kind of address: what the far end gets.
    public static func whatIsSent(_ kind: LtvAddressKind) -> String {
        switch kind {
        case .ocsp: loc("is told which certificate is being asked about (its serial number and a hash of its issuer)")
        case .crl: loc("sends its list of revoked certificates; nothing but the request is sent")
        case .issuer: loc("sends a public certificate; nothing but the request is sent")
        case .timestamp: loc("receives a hash of the document or signature, never the document")
        }
    }
}

/// What became of one certificate.
public struct LtvCertificateResult: Sendable, Equatable {
    public let name: String
    public let outcome: String
    public let covered: Bool
}

/// The outcome of adding long-term data.
public struct LtvResult: Sendable {
    /// The file with the update appended (the same bytes when there was nothing to add).
    public let pdf: [UInt8]
    /// Whether anything was appended.
    public let changed: Bool
    /// Each certificate looked at, and what became of it.
    public let certificates: [LtvCertificateResult]
    /// What was actually asked.
    public let contacts: [LtvContact]
}

/// The outcome of asking online about a file's certificates, which leaves the file alone.
public struct LtvOnlineResult: Sendable {
    public let snapshot: RevocationSnapshot
    public let certificates: [LtvCertificateResult]
    public let contacts: [LtvContact]
    public let problem: String?
}

/// Long-term validation (the Windows app's `Ltv`): gets the revocation data for a signature's whole chain from the
/// addresses its certificates name, stores it in the file (`Dss`) as an incremental update, and can add a document
/// timestamp over it. All of it happens in memory: whatever fails, the caller has the bytes it started with. Going online
/// happens only here and only through `LtvClient`; `plan` says beforehand where it would go.
public enum Ltv {
    /// What adding long-term data to `data` would contact. Stays offline.
    /// - Parameters:
    ///   - client: the client that would go; addresses are judged as it would judge them.
    ///   - onlyMissing: leave out what the file already holds the answer to (false: what a check online would ask).
    ///   - repairedLength: the document's `DocumentSession.repairedLength`: signatures made before the repair aren't extended.
    public static func plan(_ data: [UInt8], _ password: String? = nil, client: LtvClient? = nil, onlyMissing: Bool = true, repairedLength: Int = 0) -> LtvPlan {
        let facts = Signatures.inspect(data, password, repairedLength: repairedLength)
        let builder = PlanBuilder(onlyMissing ? storedPool(data, password) : RevocationPool(), client)
        for f in facts where f.intact {
            guard let cert = f.info.certificate else { continue }
            builder.addChain(cert, f.certs, f.stamped ?? Date())
            if let tsa = f.tsa { builder.addChain(tsa, f.tsaCerts, f.stamped ?? Date()) }
        }
        var notes: [String] = []
        let broken = facts.filter { $0.info.status == .invalid || $0.info.status == .disallowedChanges || $0.info.status == .unsupported }.count
        if broken > 0 {
            notes.append(broken == 1 ? loc("{0} signature that didn't check out is left out.", CoreLanguage.number(broken))
                : loc("{0} signatures that didn't check out are left out.", CoreLanguage.number(broken)))
        }
        return LtvPlan(addresses: builder.addresses, notes: notes + builder.notes, complete: builder.addresses.isEmpty && builder.notes.isEmpty)
    }

    /// What signing with `signer` for the long term would contact, the timestamp server included. Stays offline.
    public static func plan(signer: Certificate, chain: [Certificate] = [], timestampUrl: String, client: LtvClient? = nil) -> LtvPlan {
        let builder = PlanBuilder(RevocationPool(), client)
        builder.addChain(signer, chain, Date())
        let refused = client?.why(timestampUrl, .timestamp) ?? (client == nil ? LtvClient.whyRefused(timestampUrl, .timestamp) : nil)
        let list = [LtvAddress(kind: .timestamp, url: timestampUrl, forWhom: loc("the signature"), refusedBecause: refused)] + builder.addresses
        return LtvPlan(addresses: list,
                       notes: builder.notes + [loc("The timestamp's certificate names addresses of its own, of the same kinds; they are asked too, once the timestamp arrives.")],
                       complete: false)
    }

    /// What adding long-term data to these files would contact, all together (Batch's window before it runs), and how many
    /// have a signature to add it for: encrypted files, damaged ones and those with no signature that checks out are
    /// skipped in the run, so they are left out here too. Stays offline.
    /// - Parameter timestampUrl: the document timestamp's server, asked once per file (`forEachFile` names that).
    public static func plan(files paths: [String], client: LtvClient, timestampUrl: String?, forEachFile: String) -> (plan: LtvPlan, signed: Int) {
        var addresses: [LtvAddress] = []
        var notes: [String] = []
        var complete = true
        var signed = 0
        if let timestampUrl {
            addresses.append(LtvAddress(kind: .timestamp, url: timestampUrl, forWhom: forEachFile, refusedBecause: client.why(timestampUrl, .timestamp)))
        }
        for path in paths {
            // Unreadable here, it fails as the batch runs, before anything is asked.
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)).map({ $0 }) else { continue }
            if isEncrypted(data) { continue }
            if !Signatures.inspect(data, nil).contains(where: { $0.intact && $0.info.certificate != nil }) { continue }
            if PdfRepair.normalize(data, nil).repaired { continue } // skipped in the run: a damaged file's signatures are never extended
            signed += 1
            let p = plan(data, nil, client: client)
            complete = complete && p.complete
            for a in p.addresses where !addresses.contains(where: { $0.url == a.url }) { addresses.append(a) }
            for n in p.notes where !notes.contains(n) { notes.append(n) }
        }
        return (LtvPlan(addresses: addresses, notes: notes, complete: complete && timestampUrl == nil), signed)
    }

    private final class PlanBuilder {
        private let pool: RevocationPool
        private let client: LtvClient?
        private var urls = Set<String>()
        private var seen = Set<String>()
        private(set) var addresses: [LtvAddress] = []
        private(set) var notes: [String] = []

        init(_ pool: RevocationPool, _ client: LtvClient?) {
            self.pool = pool
            self.client = client
        }

        func addChain(_ cert: Certificate, _ extra: [Certificate], _ when: Date) {
            let chain = RevocationPool.buildChain(cert, extra + pool.certs, at: when)
            for (i, c) in chain.enumerated() {
                guard seen.insert(c.thumbprint).inserted, !CertFacts.isSelfSigned(c), !c.ocspNoCheck else { continue }
                let issuer = i + 1 < chain.count ? chain[i + 1] : nil
                let name = CertFacts.name(c)
                if let issuer {
                    if pool.check(c, issuer, when).answer.settles { continue }
                } else {
                    for url in c.issuerUrls { add(.issuer, url, name) }
                    notes.append(loc("{0}'s issuer isn't in the file or on this Mac. If it can be fetched, the addresses it names are asked too.", name))
                }
                for url in c.ocspUrls { add(.ocsp, url, name) }
                for url in c.crlUrls { add(.crl, url, name) }
                if c.ocspUrls.isEmpty && c.crlUrls.isEmpty { notes.append(loc("{0} names no address to ask about it, so it can't be covered.", name)) }
            }
        }

        private func add(_ kind: LtvAddressKind, _ url: String, _ name: String) {
            guard urls.insert(url).inserted else { return }
            addresses.append(LtvAddress(kind: kind, url: url, forWhom: name, refusedBecause: client?.why(url, kind) ?? (client == nil ? LtvClient.whyRefused(url, kind) : nil)))
        }
    }

    /// Add Verification Information: asks for what the file lacks and stores it as an incremental update, leaving every
    /// signature as it was. A certificate that names no address, or only ones that are refused, is reported and left
    /// uncovered; a server that can't be reached ends it all with an error, and nothing is changed.
    /// - Parameters:
    ///   - documentTimestamp: adds a document timestamp over it all, with this exchange (`LtvClient.timestampSender`).
    ///   - repairedLength: the document's `DocumentSession.repairedLength`: a signature made before the repair is never
    ///     extended, and nothing is added to a file holding one.
    public static func addVerification(_ data: [UInt8], _ password: String?, _ client: LtvClient,
                                       documentTimestamp: (@Sendable ([UInt8]) async throws -> [UInt8])? = nil, repairedLength: Int = 0) async throws -> LtvResult {
        try await extend(data, password, client, documentTimestamp, strict: false, repairedLength: repairedLength)
    }

    /// Asks online about the certificates of a file's signatures, without changing the file: for `Signatures.verify(online:)`.
    public static func checkOnline(_ data: [UInt8], _ password: String?, _ client: LtvClient, repairedLength: Int = 0) async throws -> LtvOnlineResult {
        let facts = Signatures.inspect(data, password, repairedLength: repairedLength)
        let gather = Gatherer(client, RevocationPool(), useStored: false)
        for f in facts where f.intact { // as the plan: what the person was shown is all that is asked
            guard let cert = f.info.certificate else { continue }
            _ = try await gather.coverChain(cert, f.certs, f.stamped ?? Date()) // at the time the plan built the chain at
            if let tsa = f.tsa { _ = try await gather.coverChain(tsa, f.tsaCerts, f.stamped ?? Date()) }
        }
        let snapshot = RevocationSnapshot()
        snapshot.pool.addFrom(gather.pool)
        return LtvOnlineResult(snapshot: snapshot, certificates: gather.results(), contacts: client.contacts, problem: gather.firstFailure)
    }

    /// The whole job. `strict`: for signing, where a promise of B-LT can't be kept with a gap in it; there only the new
    /// signature is extended in a repaired file (`repairedLength`), else such a file is refused.
    static func extend(_ data: [UInt8], _ password: String?, _ client: LtvClient, _ documentTimestamp: (@Sendable ([UInt8]) async throws -> [UInt8])?,
                       strict: Bool, repairedLength: Int = 0) async throws -> LtvResult {
        if isEncrypted(data) {
            throw SigningError(loc("Encrypted (password-protected) PDFs can't take long-term data, since an update can't be appended to them without breaking their signatures. Nothing was changed."))
        }
        let before = Signatures.inspect(data, password, repairedLength: repairedLength)
        if !strict && before.contains(where: { $0.info.inRepairedFile }) {
            throw SigningError(loc("The file was damaged and Inkvolt PDF repaired it to open it, so its signatures can't be checked and long-term data can't be added to them. Add it to the original file. Nothing was changed."))
        }
        var intact = before.filter { $0.intact && $0.info.certificate != nil }
        if intact.isEmpty {
            throw SigningError(before.contains { $0.info.status != .unsigned }
                ? loc("None of this document's signatures checks out, so there is nothing to add long-term data for. Nothing was changed.")
                : loc("This document isn't signed, so there is nothing to add long-term data for."))
        }

        // A signature with no timestamp yet gets its time from a first document timestamp (its B-T); the data then comes
        // after that time, so it can speak for it, and the timestamp below goes over the data (B-LTA).
        var output = data
        var changed = false
        if let documentTimestamp, intact.contains(where: { f in
            !f.documentTimestamp && f.stamped == nil && !before.contains { $0.documentTimestamp && $0.intact && $0.end > f.end }
        }) {
            output = try await Signing.addDocumentTimestamp(output, password, documentTimestamp)
            changed = true
            intact = Signatures.inspect(output, password, repairedLength: repairedLength).filter { $0.intact && $0.info.certificate != nil }
        }

        let gather = Gatherer(client, storedPool(output, password), useStored: true)
        var entries: [VriEntry] = []
        if strict, let newest = intact.filter({ !$0.documentTimestamp }).max(by: { $0.end < $1.end }) { // not a timestamp added above
            // Signing promises B-LT for the new signature only: its chain must be complete. Earlier signers' get what can
            // be had, and a gap or a server failing for them doesn't stop the signing.
            let (entry, used) = try await gather.entry(for: newest)
            try stop(gather, used)
            entries.append(entry)
            for f in intact where f !== newest { entries.append(try await gather.entry(for: f).vri) }
            gather.forgetFailures()
        } else {
            for f in intact { entries.append(try await gather.entry(for: f).vri) }
            try stop(gather, nil)
        }

        if !Dss.holds(output, password, entries) {
            output = try Dss.append(output, password, entries)
            changed = true
        }
        if let documentTimestamp {
            output = try await Signing.addDocumentTimestamp(output, password, documentTimestamp)
            changed = true
            // The stamp's own authority, so the timestamp can be checked later too.
            guard let stamp = Signatures.inspect(output, password).filter({ $0.documentTimestamp && $0.intact }).max(by: { $0.end < $1.end }) else {
                throw SigningError(loc("The document timestamp doesn't check out. Nothing was changed."))
            }
            let (entry, used) = try await gather.entry(for: stamp)
            try stop(gather, strict ? used : nil)
            output = try Dss.append(output, password, [entry])
        }

        // Whatever happened above, no signature may have suffered for it.
        if changed {
            let after = Signatures.inspect(output, password)
            for f in before where f.intact {
                if after.first(where: { $0.info.fieldName == f.info.fieldName })?.intact != true {
                    throw SigningError(loc("Adding long-term data would have broken the signature \"{0}\". Nothing was changed.", f.info.fieldName))
                }
            }
        }
        return LtvResult(pdf: output, changed: changed, certificates: gather.results(), contacts: client.contacts)
    }

    /// A server's failure ends it all; with `strict` (signing), so does a revoked certificate or a gap among those.
    private static func stop(_ gather: Gatherer, _ strict: [Gatherer.Entry]?) throws {
        if let failure = gather.firstFailure { throw SigningError(loc("{0} Nothing was changed.", failure), serverFailure: true) }
        guard let strict else { return }
        if let revoked = strict.first(where: { $0.outcome == .revoked }) {
            throw SigningError(loc("{0} has been revoked, so it can't sign for the long term. Nothing was changed.", CertFacts.name(revoked.cert)))
        }
        if let gap = strict.first(where: { !$0.outcome.covered }) {
            throw SigningError(loc("Long-term data can't be complete: {0}. Sign without long-term validation, or use a digital ID whose authority can be asked. Nothing was changed.", gap.detail))
        }
    }

    /// The file is encrypted, by its trailer (the bytes "/Encrypt" in a page's text don't make it so); one MuPDF can't
    /// open is taken as it reads.
    static func isEncrypted(_ data: [UInt8]) -> Bool {
        if let doc = try? MuDoc.open(data) { return doc.hasEncrypt }
        return data.firstRange(of: Array("/Encrypt".utf8)) != nil
    }

    private static func storedPool(_ data: [UInt8], _ password: String?) -> RevocationPool {
        let pool = RevocationPool()
        // Nothing to build on: everything is asked for.
        if let doc = try? PdfEdit.openToRead(data, password) { Dss.readInto(doc, pool) }
        return pool
    }

    /// Walks chains and asks for what is missing, one certificate at a time, each at most once.
    private final class Gatherer {
        final class Entry {
            let cert: Certificate
            var responder: Certificate?
            var ocsp: [UInt8]?
            var crl: [UInt8]?
            var outcome = CertificateCheckOutcome.noData
            var detail = ""
            init(_ cert: Certificate) { self.cert = cert }
        }

        private let client: LtvClient
        private let useStored: Bool
        let pool: RevocationPool
        private var byThumbprint: [String: Entry] = [:]
        private var order: [Entry] = []
        private(set) var firstFailure: String?

        /// What failed so far no longer stops the run (earlier signers' chains, when signing).
        func forgetFailures() { firstFailure = nil }

        init(_ client: LtvClient, _ pool: RevocationPool, useStored: Bool) {
            self.client = client
            self.pool = pool
            self.useStored = useStored
        }

        var entries: [Entry] { order }

        func results() -> [LtvCertificateResult] {
            order.map { LtvCertificateResult(name: CertFacts.name($0.cert), outcome: $0.detail, covered: $0.outcome.covered) }
        }

        /// Covers a signature's chain and its timestamp's, and says what of it is this signature's (and which certificates).
        func entry(for f: SignatureFacts) async throws -> (vri: VriEntry, used: [Entry]) {
            let when = f.stamped ?? Date()
            var used = try await coverChain(f.info.certificate!, f.certs, when)
            if let tsa = f.tsa, tsa != f.info.certificate { used += try await coverChain(tsa, f.tsaCerts, when) }
            let certs = used.map(\.cert.der) + used.compactMap { $0.responder?.der }
            return (VriEntry(key: f.vriKey, certs: Self.distinct(certs), ocsps: Self.distinct(used.compactMap(\.ocsp)), crls: Self.distinct(used.compactMap(\.crl))), used)
        }

        private static func distinct(_ items: [[UInt8]]) -> [[UInt8]] {
            var seen = Set<[UInt8]>()
            return items.filter { seen.insert(DigestAlgorithm.sha256.hash($0)).inserted }
        }

        func coverChain(_ cert: Certificate, _ extra: [Certificate], _ when: Date) async throws -> [Entry] {
            for c in extra { pool.addCert(c) }
            let chain = try await chainWithIssuers(cert, when)
            var used: [Entry] = []
            for (i, c) in chain.enumerated() { try await cover(c, i + 1 < chain.count ? chain[i + 1] : nil, when, &used) }
            return used
        }

        /// The chain, fetching a missing issuer from the address its certificate names: only when the certificate before
        /// it checks out against it.
        private func chainWithIssuers(_ cert: Certificate, _ when: Date) async throws -> [Certificate] {
            var chain = RevocationPool.buildChain(cert, pool.certs, at: when)
            var fetch = 0
            while fetch < 4, let last = chain.last, !CertFacts.isSelfSigned(last) {
                fetch += 1
                var issuer: Certificate?
                var failure: String?
                for url in last.issuerUrls where !client.refuses(url, .issuer) {
                    do {
                        let bytes = try await client.get(url, .issuer, maxBytes: LtvClient.maxCertificateReply)
                        issuer = Self.readCertificates(bytes).first { CertFacts.signedBy(last, $0) }
                        if issuer != nil { break }
                    } catch let e as LtvFetchError {
                        failure = failure ?? e.message
                    }
                }
                guard let issuer else {
                    firstFailure = firstFailure ?? failure
                    break
                }
                pool.addCert(issuer)
                chain = RevocationPool.buildChain(cert, pool.certs, at: when)
                if !chain.contains(issuer) { break }
            }
            return chain
        }

        /// A certificate reply is one DER certificate, or a .p7c bundle of them.
        private static func readCertificates(_ bytes: [UInt8]) -> [Certificate] {
            if let c = try? Certificate(der: bytes) { return [c] }
            return Array(((try? CmsSignedData(der: bytes))?.certificates ?? []).prefix(8))
        }

        private func cover(_ c: Certificate, _ issuer: Certificate?, _ when: Date, _ used: inout [Entry]) async throws {
            if let known = byThumbprint[c.thumbprint] {
                used.append(known)
                if let r = known.responder, let re = byThumbprint[r.thumbprint] { used.append(re) }
                return
            }
            let e = Entry(c)
            byThumbprint[c.thumbprint] = e
            order.append(e)
            used.append(e)
            let name = CertFacts.name(c)
            if CertFacts.isSelfSigned(c) {
                e.outcome = .root
                e.detail = loc("a root: needs no revocation data")
                return
            }
            if c.ocspNoCheck {
                e.outcome = .noCheckNeeded
                e.detail = loc("an OCSP responder that needs no check of its own")
                return
            }
            guard let issuer else {
                e.outcome = .noIssuer
                e.detail = loc("{0}'s issuer isn't in the file or on this Mac, and couldn't be fetched", name)
                return
            }
            if useStored {
                let stored = judge(c, issuer, when)
                if stored.answer.settles, let evidence = stored.evidence {
                    record(e, stored, evidence, loc("already in the file"))
                    try await coverResponder(e, issuer, when, &used)
                    return
                }
            }

            var refused = 0, tried = 0
            var failure: String?
            for url in c.ocspUrls {
                if client.refuses(url, .ocsp) {
                    refused += 1
                    continue
                }
                tried += 1
                do {
                    let der = try await client.post(url, .ocsp, contentType: "application/ocsp-request", body: OcspResponse.request(c, issuer), maxBytes: LtvClient.maxOcspReply)
                    let parsed = OcspResponse.parse(der)
                    guard let reply = parsed.response else {
                        failure = failure ?? loc("The answer from {0} can't be used: {1}.", LtvClient.host(url), parsed.problem ?? "")
                        continue
                    }
                    if reply.answer(for: c, issuer) == nil || !reply.signed(for: issuer, known: pool.certs).signed {
                        failure = failure ?? loc("The answer from {0} isn't signed by the certificate's issuer, or is about another certificate.", LtvClient.host(url))
                        continue
                    }
                    pool.addOcsp(der)
                    let v = judge(c, issuer, when)
                    if v.answer == .stale {
                        failure = failure ?? loc("The answer from {0} is too old to speak for the signing time.", LtvClient.host(url))
                        continue
                    }
                    record(e, v, v.evidence ?? der, "OCSP, \(LtvClient.host(url))")
                    try await coverResponder(e, issuer, when, &used)
                    return
                } catch let x as LtvFetchError {
                    failure = failure ?? x.message
                }
            }
            for url in c.crlUrls {
                if client.refuses(url, .crl) {
                    refused += 1
                    continue
                }
                tried += 1
                do {
                    let der = try await client.get(url, .crl, maxBytes: LtvClient.maxCrlReply)
                    guard let list = CrlDocument.parse(der), list.speaks(for: c, issuer) else {
                        failure = failure ?? loc("The list from {0} can't be read, or isn't signed by the certificate's issuer.", LtvClient.host(url))
                        continue
                    }
                    pool.addCrl(der)
                    let v = judge(c, issuer, when)
                    if v.answer == .stale {
                        failure = failure ?? loc("The list from {0} is too old to speak for the signing time.", LtvClient.host(url))
                        continue
                    }
                    record(e, v, v.evidence ?? der, "CRL, \(LtvClient.host(url))")
                    return
                } catch let x as LtvFetchError {
                    failure = failure ?? x.message
                }
            }

            if tried == 0 {
                e.detail = refused > 0
                    ? loc("{0} names only addresses on a local network or that can't be used, so none was contacted", name)
                    : loc("{0} names no address to ask about it", name)
                return
            }
            e.detail = failure ?? loc("{0} couldn't be asked about", name)
            firstFailure = firstFailure ?? failure ?? e.detail
        }

        /// The pool's time budget is for the file's data: however long the servers took to answer, this question gets all of it.
        private func judge(_ c: Certificate, _ issuer: Certificate, _ when: Date) -> RevocationVerdict {
            pool.restartBudget()
            return pool.check(c, issuer, when)
        }

        private func coverResponder(_ e: Entry, _ issuer: Certificate, _ when: Date, _ used: inout [Entry]) async throws {
            if let r = e.responder, byThumbprint[r.thumbprint] == nil {
                pool.addCert(r)
                try await cover(r, issuer, when, &used)
            }
        }

        private func record(_ e: Entry, _ v: RevocationVerdict, _ evidence: [UInt8], _ source: String) {
            e.responder = v.responder
            if OcspResponse.parse(evidence).response != nil { e.ocsp = evidence } else { e.crl = evidence }
            switch v.answer {
            case .good:
                e.outcome = .good
                e.detail = loc("not revoked ({0})", source)
            case .revoked:
                e.outcome = .revoked
                e.detail = v.revokedAt.map { loc("REVOKED on {0} ({1})", ltvDay($0), source) } ?? loc("REVOKED ({0})", source)
            case .revokedLater:
                e.outcome = .revokedLater
                e.detail = loc("revoked later, on {0}, after the signing time ({1})", ltvDay(v.revokedAt), source)
            case .unknown:
                e.outcome = .unknown
                e.detail = loc("the authority doesn't know this certificate ({0})", source)
            default:
                e.outcome = .noData
                e.detail = loc("no usable answer ({0})", source)
            }
        }
    }
}
