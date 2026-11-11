import Foundation
import PrintCore

/// The PAdES baseline level a signature in a file reaches (ETSI EN 319 142-1), as this app judges it.
public enum PadesLevel: Sendable, Equatable {
    /// Not a PAdES baseline signature (e.g. adbe.pkcs7.detached), or a document timestamp.
    case none
    /// The signature alone.
    case bb
    /// A timestamp proves it existed at a time.
    case bt
    /// And the file holds the validation data for its certificates and the timestamp's.
    case blt
    /// And a document timestamp covers that data, so it can be renewed before the algorithms age.
    case blta
}

/// What the data in hand says about one certificate in a chain.
public enum CertificateCheckOutcome: Sendable, Equatable {
    /// A self-signed root: nobody else can vouch for it.
    case root
    /// An OCSP responder its issuer says needn't be checked.
    case noCheckNeeded
    case good
    case revoked
    /// Revoked after the time that counts, so it doesn't touch a signature made before.
    case revokedLater
    /// The responder doesn't know this certificate.
    case unknown
    /// The data in hand is too old to speak for the signing time.
    case stale
    /// No data for it in the file, or none that verifies.
    case noData
    /// Its issuer isn't in the file or on this Mac, so nothing about it can be verified.
    case noIssuer

    var covered: Bool { self == .root || self == .noCheckNeeded || self == .good || self == .revokedLater }
}

/// One certificate of a chain and what is known about it.
public struct CertificateCheck: Sendable, Equatable {
    public let name: String
    public let outcome: CertificateCheckOutcome
    public var revokedAt: Date?

    var covered: Bool { outcome.covered }
}

/// What a file holds for checking one signature in the long term.
public struct LongTermInfo: Sendable, Equatable {
    /// The PAdES level reached.
    public let level: PadesLevel
    /// Every certificate of the signature's chain (and its timestamp's) has verified revocation data in hand.
    public let dataComplete: Bool
    /// The signer's chain, then its timestamp authority's, as far as they could be built.
    public let chain: [CertificateCheck]
    /// One or two sentences for the person.
    public let summary: String
    /// The updates after this signature hold only long-term data and document timestamps.
    public var onlyValidationDataAfter = false
}

/// Revocation data asked for online, for one check of the file. Nothing of it is written anywhere.
public final class RevocationSnapshot: @unchecked Sendable {
    let pool = RevocationPool()
    public init() {}
}

/// What checking one signature field found, beyond what the app shows.
final class SignatureFacts {
    var info: SignatureInfo
    /// Where the signed bytes end: the revision the signature belongs to.
    var end = 0
    /// The bytes whose SHA-1 is this signature's /VRI key.
    var contentsForVri: [UInt8]?
    var documentTimestamp = false
    var signer: CmsSignerInfo?
    var certs: [Certificate] = []
    var tsa: Certificate?
    var tsaCerts: [Certificate] = []
    var stamped: Date?
    var trustTime: Date?
    var isPades = false
    var onlyValidationDataAfter = false

    init(_ info: SignatureInfo) { self.info = info }

    /// The signature checked out, whatever came later.
    var intact: Bool { info.status == .valid || info.status == .modifiedAfterSigning }

    var vriKey: String { DigestAlgorithm.sha1.hash(contentsForVri ?? []).map { String(format: "%02X", $0) }.joined() }

    /// The time a trusted timestamp vouches for (a document timestamp's own, when its authority is trusted); nil when no
    /// trusted authority says when: a token anyone can put in a file proves nothing about the long term.
    var vouchedTime: Date? { documentTimestamp ? (info.certificateTrusted ? stamped : nil) : trustTime }
}

/// A date as the long-term texts show it (2026-11-11, UTC): the Signatures pane's too.
public func ltvDay(_ d: Date?) -> String {
    guard let d else { return "?" }
    return ltvDayFormat.string(from: d)
}

private let ltvDayFormat: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

/// Judges each signature from what the file holds, and from nothing else (the Windows app's `LongTermCheck`): its chain
/// against the /DSS and the signature's own archived revocation data, the level it reaches, and a revocation found there
/// takes away the trust. Goes nowhere online.
enum LongTermCheck {
    /// How many document timestamps a file is looked at under: each means reading a revision again.
    private static let maxStampsRead = 3

    static func apply(_ data: [UInt8], _ password: String?, _ all: [SignatureFacts], _ pool: RevocationPool, _ anchors: [Certificate]?) {
        pool.restartBudget()
        for f in all where f.intact {
            for c in f.certs { pool.addCert(c) }
            for c in f.tsaCerts { pool.addCert(c) }
            if let archived = f.signer?.signed(Oids.revocationArchival)?.first { pool.addArchival(archived) }
        }
        // Only document timestamps a trusted authority made speak for a time.
        let stamps = all.filter { $0.intact && $0.documentTimestamp && $0.vouchedTime != nil }.sorted { $0.end < $1.end }
        var revisions: [Int: RevocationPool] = [:]

        for f in all where f.intact {
            guard let cert = f.info.certificate else { continue }
            if pool.outOfBudget {
                outOfBudget(f, pool)
                continue
            }
            let firstStamp = stamps.first { $0.end > f.end }
            let when = f.vouchedTime ?? firstStamp?.vouchedTime ?? Date()
            let tsa = f.documentTimestamp ? nil : f.vouchedTime != nil ? f.tsa : firstStamp?.tsa
            let chain = walk(cert, pool, when, anchors)
            let tsaChain = tsa.map { walk($0, pool, when, anchors) } ?? []
            let complete = chain.allSatisfy(\.covered) && tsaChain.allSatisfy(\.covered)

            // Revocation takes away the trust at the time that counts for trust: a trusted timestamp's, else now.
            let trustAt = f.trustTime ?? Date()
            let atTrust = f.trustTime != nil && f.trustTime == when ? chain : walk(cert, pool, trustAt, anchors)
            if let revoked = atTrust.first(where: { $0.outcome == .revoked }) {
                f.info.certificateTrusted = false
                f.info.certificateStatus = revoked.revokedAt.map { loc("Revoked on {0}: {1}", ltvDay($0), revoked.name) } ?? loc("Revoked: {0}", revoked.name)
            }

            let level = self.level(data, password, f, stamps, pool, &revisions, complete, anchors)
            f.info.longTerm = LongTermInfo(level: level, dataComplete: complete, chain: chain + tsaChain, summary: summary(f, level, complete, chain + tsaChain, pool),
                                           onlyValidationDataAfter: f.onlyValidationDataAfter)
            if pool.outOfBudget { outOfBudget(f, pool) }
        }
    }

    /// A file that makes the check run out of time never leaves a certificate trusted: what it held wasn't all judged, and a
    /// revocation among it could have been missed.
    private static func outOfBudget(_ f: SignatureFacts, _ pool: RevocationPool) {
        f.info.longTerm = LongTermInfo(level: .none, dataComplete: false, chain: [], summary: summary(f, .none, false, [], pool),
                                       onlyValidationDataAfter: f.onlyValidationDataAfter)
        f.info.certificateTrusted = false
        f.info.certificateStatus = loc("The file's validation data is more than a check reads, so it wasn't fully checked.")
    }

    private static func level(_ data: [UInt8], _ password: String?, _ f: SignatureFacts, _ stamps: [SignatureFacts], _ pool: RevocationPool,
                              _ revisions: inout [Int: RevocationPool], _ complete: Bool, _ anchors: [Certificate]?) -> PadesLevel {
        if f.documentTimestamp || !f.isPades { return .none }
        let later = stamps.filter { $0.end > f.end }
        if f.vouchedTime == nil && later.isEmpty { return .bb }
        if !complete { return .bt }
        // B-LTA: a document timestamp over this signature's data. A signature without a timestamp of its own has its time
        // from the first document timestamp, which is then its B-T: it takes one more.
        let over = f.vouchedTime == nil ? Array(later.dropFirst()) : later
        let tsa = f.vouchedTime != nil ? f.tsa : later.first?.tsa
        for stamp in over.reversed().prefix(maxStampsRead) {
            let revision: RevocationPool
            if let known = revisions[stamp.end] {
                revision = known
            } else {
                revision = revisionPool(data, stamp.end, password, pool)
                revisions[stamp.end] = revision
            }
            let when = f.vouchedTime ?? later[0].vouchedTime ?? Date()
            guard let cert = f.info.certificate else { break }
            let covered = walk(cert, revision, when, anchors).allSatisfy(\.covered) && (tsa.map { walk($0, revision, when, anchors).allSatisfy(\.covered) } ?? true)
            if covered { return .blta }
        }
        return .blt
    }

    /// What the file up to a timestamp held, plus the signatures' own certificates.
    private static func revisionPool(_ data: [UInt8], _ end: Int, _ password: String?, _ whole: RevocationPool) -> RevocationPool {
        let revision = RevocationPool()
        for c in whole.certs { revision.addCert(c) }
        // A revision that can't be read holds nothing.
        if end > 0, end <= data.count, let doc = try? PdfEdit.openToRead(Array(data[..<end]), password) { Dss.readInto(doc, revision) }
        return revision
    }

    /// What the pool says about each certificate of `cert`'s chain at `when`, responders included.
    private static func walk(_ cert: Certificate, _ pool: RevocationPool, _ when: Date, _ anchors: [Certificate]?) -> [CertificateCheck] {
        var result: [CertificateCheck] = []
        var seen = Set<String>()
        let chain = RevocationPool.buildChain(cert, pool.certs, at: when, anchors: anchors)
        for (i, c) in chain.enumerated() {
            judge(c, i + 1 < chain.count ? chain[i + 1] : nil, pool, when, &result, &seen, 0)
        }
        return result
    }

    private static func judge(_ c: Certificate, _ issuer: Certificate?, _ pool: RevocationPool, _ when: Date, _ result: inout [CertificateCheck],
                              _ seen: inout Set<String>, _ depth: Int) {
        guard seen.insert(c.thumbprint).inserted else { return }
        let name = CertFacts.name(c)
        if CertFacts.isSelfSigned(c) {
            result.append(CertificateCheck(name: name, outcome: .root))
            return
        }
        guard let issuer else {
            result.append(CertificateCheck(name: name, outcome: .noIssuer))
            return
        }
        if c.isNoCheckResponder {
            result.append(CertificateCheck(name: name, outcome: .noCheckNeeded))
            return
        }
        let v = pool.check(c, issuer, when)
        let outcome: CertificateCheckOutcome = switch v.answer {
        case .good: .good
        case .revoked: .revoked
        case .revokedLater: .revokedLater
        case .unknown: .unknown
        case .stale: .stale
        case .none: .noData
        }
        result.append(CertificateCheck(name: name, outcome: outcome, revokedAt: v.revokedAt))
        // A delegated responder is a certificate the answer leans on: it needs its own data, unless it says it doesn't.
        if let responder = v.responder, depth < 3 { judge(responder, issuer, pool, when, &result, &seen, depth + 1) }
    }

    private static func summary(_ f: SignatureFacts, _ level: PadesLevel, _ complete: Bool, _ chain: [CertificateCheck], _ pool: RevocationPool) -> String {
        if pool.outOfBudget { return loc("The file's validation data is more than a check reads, so it wasn't fully checked.") }
        var missing: [String] = []
        for c in chain where !c.covered && !missing.contains(c.name) { missing.append(c.name) }
        let names = missing.prefix(3).joined(separator: ", ")
        let which = missing.isEmpty ? "" : missing.count > 3 ? loc(" Missing for: {0}, and more.", names) : loc(" Missing for: {0}.", names)
        let note = chain.first { $0.outcome == .revokedLater }.map { loc(" {0} was revoked later, on {1}, after this signature's time.", $0.name, ltvDay($0.revokedAt)) } ?? ""
        if f.documentTimestamp {
            return (complete ? loc("Document timestamp: its authority's validation data is in the file.") : loc("Document timestamp: its authority's validation data isn't all in the file.{0}", which)) + note
        }
        let text: String
        switch level {
        case .blta: text = loc("PAdES B-LTA: LTV enabled. The file holds the validation data for every certificate, and a document timestamp covers it.")
        case .blt: text = loc("PAdES B-LT: LTV enabled. The file holds the validation data for every certificate.")
        case .bt: text = loc("PAdES B-T: timestamped, but the file doesn't hold the validation data, so checking it later depends on the certificate authorities still answering.{0}", which)
        case .bb: text = complete
            ? loc("PAdES B-B: the file holds the validation data, but no timestamp proves when it was signed, so it can't be checked once the certificate expires.")
            : loc("PAdES B-B: no timestamp and no validation data in the file, so it can't be checked once the certificate expires.")
        case .none: text = complete && f.stamped != nil
            ? loc("LTV enabled, though not in the PAdES format: the file holds the validation data for every certificate.")
            : loc("Not in the PAdES format. The file doesn't hold what it takes to check it in the long term.{0}", which)
        }
        return text + note
    }
}
