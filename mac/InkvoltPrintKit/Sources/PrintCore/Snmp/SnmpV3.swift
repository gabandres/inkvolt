import Foundation
import Synchronization

/// An SNMPv3 user (RFC 3414's User-based Security Model) as Inkvolt Print signs in with it: authPriv only, authentication
/// HMAC-SHA-256 truncated to 192 bits (usmHMAC192SHA256AuthProtocol, RFC 7860), privacy AES-128 in CFB mode
/// (usmAesCfb128Protocol, RFC 3826). The passphrases are secrets: kept with the `SnmpLogin` in the Keychain; neither the
/// description nor the mirror shows them. The Windows Core's `SnmpV3User`.
public struct SnmpV3User: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    /// RFC 3414 §11.2: shorter passphrases make weak keys; net-snmp refuses them too.
    public static let minPassphrase = 8

    /// The longest passphrase taken (Windows': so a login always fits Credential Manager; the same limit here).
    public static let maxPassphrase = 256

    /// The longest user name in bytes of UTF-8 (RFC 3414 usmUserName: SnmpAdminString (SIZE(1..32))).
    public static let maxName = 32

    public let name: String
    public let authPassphrase: String
    public let privPassphrase: String

    init(name: String, authPassphrase: String, privPassphrase: String) {
        self.name = name
        self.authPassphrase = authPassphrase
        self.privPassphrase = privPassphrase
    }

    public var description: String { "SNMPv3 user \(name) (SHA-256, AES-128; keys kept)" }

    public var debugDescription: String { description }

    public var customMirror: Mirror { Mirror(self, children: [:]) }
}

/// The cryptography the User-based Security Model needs, from the system: PrintCore is Foundation only, so PrintMac's
/// `AppleSnmpCrypto` (CryptoKit and CommonCrypto) implements it in the app, and the PC's tests use a stand-in of their own.
/// The protocol's logic (keys from passphrases, localization, the digest's place, CFB over the block cipher, the message
/// flow) is PrintCore's, in `Usm`.
public protocol SnmpCrypto: Sendable {
    /// SHA-256 of `data` (32 bytes).
    func sha256(_ data: [UInt8]) -> [UInt8]

    /// HMAC-SHA-256 of `data` with `key` (all 32 bytes; `Usm.authenticate` keeps the first 24).
    func hmacSha256(key: [UInt8], _ data: [UInt8]) -> [UInt8]

    /// AES-128's forward cipher on one 16-byte block with a 16-byte key (FIPS 197): CFB is built on it (`Usm.aesCfb`).
    func aes128(key: [UInt8], block: [UInt8]) -> [UInt8]
}

/// The User-based Security Model (RFC 3414 §2.6 and A.2, RFC 7860, RFC 3826) over an `SnmpCrypto`. Keys are localized to
/// one agent's engine ID, so a key read off one printer is no use on another. The Windows Core's `Usm`.
public enum Usm {
    /// usmHMAC192SHA256AuthProtocol's msgAuthenticationParameters: the first 24 bytes of HMAC-SHA-256 (RFC 7860 §4.2.1).
    public static let authLength = 24

    /// usmAesCfb128Protocol's msgPrivacyParameters: the 64-bit salt (RFC 3826 §3.1.2.1).
    public static let saltLength = 8

    /// RFC 3414 §2.2.3: a message's time may differ from the engine's by this much (seconds).
    public static let timeWindow = 150

    /// RFC 3411 SnmpEngineID: 5 to 32 octets (a discovery request carries none).
    public static let maxEngineId = 32

    private static let installed = Mutex<(any SnmpCrypto)?>(nil)

    /// The system's cryptography, set once at launch (the app: PrintMac's `AppleSnmpCrypto`; the tests: their own). Clients
    /// and made-up agents made without one never speak SNMPv3. As `Pro.verifier` is set.
    public static var crypto: (any SnmpCrypto)? {
        get { installed.withLock { $0 } }
        set { installed.withLock { $0 = newValue } }
    }

    /// RFC 3414 A.2.1 (A.2.2 for SHA-1; RFC 7860 §4.2.2 the same with SHA-2): the passphrase repeated to 1 MiB, hashed.
    /// `hash` is any of them (the tests check RFC 3414 A.3's MD5 and SHA-1 vectors with it).
    public static func passwordToKey(_ passphrase: String, hash: ([UInt8]) -> [UInt8]) -> [UInt8] {
        let password = Array(passphrase.utf8)
        precondition(!password.isEmpty, "An empty passphrase makes no key.")
        let count = 1_048_576
        let expanded = [UInt8](unsafeUninitializedCapacity: count) { buffer, initialized in
            for i in 0..<count { buffer[i] = password[i % password.count] }
            initialized = count
        }
        return hash(expanded)
    }

    /// RFC 3414 §2.6: Kul = H(Ku | engineID | Ku).
    public static func localize(_ ku: [UInt8], engineId: [UInt8], hash: ([UInt8]) -> [UInt8]) -> [UInt8] {
        hash(ku + engineId + ku)
    }

    /// usmHMAC192SHA256AuthProtocol over a whole message whose msgAuthenticationParameters are 24 zero bytes.
    public static func authenticate(key: [UInt8], _ message: [UInt8], _ crypto: any SnmpCrypto) -> [UInt8] {
        Array(crypto.hmacSha256(key: key, message).prefix(authLength))
    }

    /// RFC 3826 §3.1.2.1: the IV is engine boots (4 bytes), engine time (4 bytes) and the salt, each big-endian.
    public static func aesIv(boots: Int, time: Int, salt: [UInt8]) -> [UInt8] {
        precondition(salt.count == saltLength, "The salt is 8 bytes.")
        return bigEndian32(boots) + bigEndian32(time) + salt
    }

    private static func bigEndian32(_ value: Int) -> [UInt8] {
        let v = UInt32(truncatingIfNeeded: value)
        return [UInt8(v >> 24), UInt8(truncatingIfNeeded: v >> 16), UInt8(truncatingIfNeeded: v >> 8), UInt8(truncatingIfNeeded: v)]
    }

    /// AES-128 in CFB mode with 128-bit feedback (RFC 3826 §3.1.3, NIST SP 800-38A §6.3), any length: no padding is sent, so
    /// a short last block takes only as many bytes of its key stream as it has. The key is the privacy key's first 16 bytes.
    public static func aesCfb(key: [UInt8], iv: [UInt8], _ data: [UInt8], encrypt: Bool, _ crypto: any SnmpCrypto) -> [UInt8] {
        precondition(key.count >= 16 && iv.count == 16, "AES-128 takes a 16-byte key and IV.")
        let aesKey = Array(key.prefix(16))
        var feedback = iv
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var start = 0
        while start < data.count {
            let stream = crypto.aes128(key: aesKey, block: feedback)
            let end = min(start + 16, data.count)
            let block = data[start..<end]
            let result = zip(block, stream).map { $0 ^ $1 }
            out += result
            feedback = encrypt ? result : Array(block) // the cipher text feeds the next block either way
            start = end
        }
        return out
    }

    /// A user's two keys localized to one engine (the privacy key from the same hash, RFC 3826 §1.2), worked out once.
    public struct Keys: Sendable {
        public let auth: [UInt8]
        public let priv: [UInt8]

        public static func of(_ user: SnmpV3User, engineId: [UInt8], _ crypto: any SnmpCrypto) -> Keys {
            let hash: ([UInt8]) -> [UInt8] = { crypto.sha256($0) }
            return Keys(auth: localize(stretch(user.authPassphrase, crypto), engineId: engineId, hash: hash),
                        priv: localize(stretch(user.privPassphrase, crypto), engineId: engineId, hash: hash))
        }
    }

    /// Each passphrase's Ku (passwordToKey with SHA-256), by passphrase, not user or engine (Ku depends on the passphrase
    /// alone): stretching one hashes 1 MiB, so it's done once a run; only the localization is per engine. A few at most (the
    /// printers' logins); emptied when full. Kept in memory only, as the logins themselves are.
    private static let stretched = Mutex<[String: [UInt8]]>([:])
    private static let maxStretched = 32

    private static func stretch(_ passphrase: String, _ crypto: any SnmpCrypto) -> [UInt8] {
        if let kept = stretched.withLock({ $0[passphrase] }) { return kept }
        let ku = passwordToKey(passphrase, hash: { crypto.sha256($0) })
        stretched.withLock { kept in
            if kept.count >= maxStretched { kept.removeAll() }
            kept[passphrase] = ku
        }
        return ku
    }

    // RFC 3414 §5 usmStats counters an agent reports instead of answering: which tells the manager what went wrong.
    public static let unsupportedSecLevels: Oid = "1.3.6.1.6.3.15.1.1.1.0"
    public static let notInTimeWindows: Oid = "1.3.6.1.6.3.15.1.1.2.0"
    public static let unknownUserNames: Oid = "1.3.6.1.6.3.15.1.1.3.0"
    public static let unknownEngineIds: Oid = "1.3.6.1.6.3.15.1.1.4.0"
    public static let wrongDigests: Oid = "1.3.6.1.6.3.15.1.1.5.0"
    public static let decryptionErrors: Oid = "1.3.6.1.6.3.15.1.1.6.0"

    /// Equal in time independent of where they differ (a digest compared).
    static func constantTimeEqual(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for i in a.indices { difference |= a[i] ^ b[i] }
        return difference == 0
    }
}

/// Why an SNMPv3 agent refused a request (an RFC 3414 report): told apart, so the user hears which part is wrong.
public enum SnmpRefusal: Sendable, Equatable {
    case unknownUser, wrongAuthKey, wrongPrivKey, securityLevel
}

/// An SNMPv3 agent refused the user or its keys (`reason`). The description names neither.
public struct SnmpAccessError: Error, Equatable, CustomStringConvertible {
    public let reason: SnmpRefusal

    public init(_ reason: SnmpRefusal) { self.reason = reason }

    public var description: String {
        switch reason {
        case .unknownUser: loc("The printer doesn't know this SNMPv3 user name.")
        case .wrongAuthKey: loc("The printer refused the SNMPv3 authentication passphrase.")
        case .wrongPrivKey: loc("The printer couldn't read the request: check the SNMPv3 privacy passphrase.")
        case .securityLevel: loc("The printer doesn't take SNMPv3 with authentication and privacy (SHA-256, AES-128) for this user.")
        }
    }
}

/// An SNMPv3 message (RFC 3412 §6, RFC 3414 §2.4): header, USM security parameters, and the scoped PDU, in clear or
/// encrypted. `encode` writes it; `sign` puts the digest in; `decode` reads one and says where its digest is, so it can be
/// checked over the very bytes that came. Every length from the network is bounded (`decode`). The Windows Core's
/// `SnmpV3Message`.
public struct SnmpV3Message: Sendable, CustomStringConvertible {
    public static let flagAuth: UInt8 = 0x01, flagPriv: UInt8 = 0x02, flagReportable: UInt8 = 0x04

    /// The largest message this manager takes (RFC 3412 msgMaxSize; also what UDP gives a printer's reply).
    public static let maxSize = 65507

    /// The longest user name, context name and parameter fields read (RFC 3414's SnmpAdminString is 32 octets; a digest
    /// or salt of another protocol may be longer, but not this long).
    static let maxField = 64

    public var messageId: Int
    public var maxMessageSize: Int
    public var flags: UInt8
    public var engineId: [UInt8]
    public var engineBoots: Int
    public var engineTime: Int
    public var userName: String
    /// The digest; `Usm.authLength` zero bytes before `sign`, empty without authentication.
    public var authParameters: [UInt8]
    /// The AES salt; empty without privacy.
    public var privParameters: [UInt8]
    /// The scoped PDU in clear: contextEngineID, contextName, PDU (nil when `encrypted`).
    public var contextEngineId: [UInt8]?
    public var contextName: String
    public var pdu: SnmpMessage?
    /// The scoped PDU encrypted (privacy): its BER, AES-CFB encrypted.
    public var encrypted: [UInt8]?
    /// Where the digest's 24 bytes are in the bytes `decode` read (-1: no digest).
    public private(set) var authOffset = -1

    public init(messageId: Int, maxMessageSize: Int = SnmpV3Message.maxSize, flags: UInt8, engineId: [UInt8] = [], engineBoots: Int = 0,
                engineTime: Int = 0, userName: String = "", authParameters: [UInt8] = [], privParameters: [UInt8] = [],
                contextEngineId: [UInt8]? = nil, contextName: String = "", pdu: SnmpMessage? = nil, encrypted: [UInt8]? = nil) {
        self.messageId = messageId
        self.maxMessageSize = maxMessageSize
        self.flags = flags
        self.engineId = engineId
        self.engineBoots = engineBoots
        self.engineTime = engineTime
        self.userName = userName
        self.authParameters = authParameters
        self.privParameters = privParameters
        self.contextEngineId = contextEngineId
        self.contextName = contextName
        self.pdu = pdu
        self.encrypted = encrypted
    }

    public var authenticated: Bool { flags & Self.flagAuth != 0 }
    public var isPrivate: Bool { flags & Self.flagPriv != 0 }
    public var reportable: Bool { flags & Self.flagReportable != 0 }

    /// The scoped PDU's BER (what privacy encrypts).
    public static func encodeScoped(_ contextEngineId: [UInt8], _ contextName: String, _ pdu: SnmpMessage) -> [UInt8] {
        Ber.constructed(Ber.sequence, Ber.octets(contextEngineId), Ber.octets(Array(contextName.utf8)), pdu.encodePdu())
    }

    /// A scoped PDU as `encodeScoped` writes it. `SnmpFormatError` for anything else (a wrong privacy key's output).
    public static func decodeScoped(_ data: [UInt8]) throws -> (contextEngineId: [UInt8], contextName: String, pdu: SnmpMessage) {
        var reader = Ber.Reader(data)
        var scoped = try reader.enter(Ber.sequence)
        if reader.hasMore { throw SnmpFormatError("SNMPv3: data after the scoped PDU.") }
        return try readScoped(data, &scoped)
    }

    private static func readScoped(_ data: [UInt8], _ scoped: inout Ber.Reader) throws
        -> (contextEngineId: [UInt8], contextName: String, pdu: SnmpMessage) {
        let engine = try bounded(scoped.readOctets(), Usm.maxEngineId, "contextEngineID")
        let name = String(decoding: try bounded(scoped.readOctets(), maxField, "contextName"), as: UTF8.self)
        let pdu = try SnmpMessage.decodePdu(data, &scoped, version: .v3, community: "")
        if scoped.hasMore { throw SnmpFormatError("SNMPv3: data after the PDU.") }
        return (engine, name, pdu)
    }

    /// The message's bytes, the digest as it is in `authParameters`; and where that digest is in them (-1: none).
    public func encodeWithOffset() -> (bytes: [UInt8], authOffset: Int) {
        let header = Ber.constructed(Ber.sequence, Ber.integer32(Int64(messageId)), Ber.integer32(Int64(maxMessageSize)), Ber.octets([flags]),
                                     Ber.integer32(3))
        var beforeAuth = Ber.octets(engineId)
        beforeAuth += Ber.integer32(Int64(engineBoots))
        beforeAuth += Ber.integer32(Int64(engineTime))
        beforeAuth += Ber.octets(Array(userName.utf8))
        let auth = Ber.octets(authParameters)
        let usmContent = beforeAuth + auth + Ber.octets(privParameters)
        let usm = Ber.tlv(Ber.sequence, usmContent)
        let security = Ber.octets(usm)
        let data: [UInt8]
        if let encrypted {
            data = Ber.octets(encrypted)
        } else {
            guard let contextEngineId, let pdu else { preconditionFailure("No scoped PDU.") }
            data = Self.encodeScoped(contextEngineId, contextName, pdu)
        }
        let version = Ber.integer32(3)
        let body = version + header + security + data
        let message = Ber.tlv(Ber.sequence, body)
        // The digest's place: the outer header, version, header, the security OCTET STRING's and USM SEQUENCE's headers,
        // then the USM fields before it, then its own header.
        var offset = message.count - body.count + version.count + header.count
        offset += security.count - usm.count
        offset += usm.count - usmContent.count
        offset += beforeAuth.count + auth.count - authParameters.count
        return (message, authParameters.isEmpty ? -1 : offset)
    }

    public func encode() -> [UInt8] { encodeWithOffset().bytes }

    /// The message signed with `authKey`: its digest over the bytes with 24 zero bytes in its place.
    public func sign(_ authKey: [UInt8], _ crypto: any SnmpCrypto) -> [UInt8] {
        var zeroed = self
        zeroed.authParameters = [UInt8](repeating: 0, count: Usm.authLength)
        var (bytes, offset) = zeroed.encodeWithOffset()
        let digest = Usm.authenticate(key: authKey, bytes, crypto)
        bytes.replaceSubrange(offset..<offset + Usm.authLength, with: digest)
        return bytes
    }

    /// True when `bytes` (as `decode` read them) carry the right digest for `authKey`.
    public func verify(_ bytes: [UInt8], _ authKey: [UInt8], _ crypto: any SnmpCrypto) -> Bool {
        guard authenticated, authOffset >= 0, authParameters.count == Usm.authLength, authOffset + Usm.authLength <= bytes.count else { return false }
        var zeroed = bytes
        zeroed.replaceSubrange(authOffset..<authOffset + Usm.authLength, with: [UInt8](repeating: 0, count: Usm.authLength))
        return Usm.constantTimeEqual(Usm.authenticate(key: authKey, zeroed, crypto), authParameters)
    }

    /// True when `data` is an SNMPv3 message (its version says 3), without reading the rest.
    public static func isV3(_ data: [UInt8]) -> Bool {
        var outer = Ber.Reader(data)
        guard var message = try? outer.enter(Ber.sequence) else { return false }
        return (try? message.readInteger()) == 3
    }

    /// A v3 message from the network; `SnmpFormatError` for anything else (only the USM, security model 3, is spoken).
    /// Every length is bounded: the engine ID to 32 bytes (RFC 3411), the user name and parameters to `maxField`, the
    /// numbers to 0…2³¹−1, a value to its container (`Ber.Reader`).
    public static func decode(_ data: [UInt8]) throws -> SnmpV3Message {
        guard data.count <= maxSize else { throw SnmpFormatError("SNMPv3: longer than a message can be.") }
        var outer = Ber.Reader(data)
        var message = try outer.enter(Ber.sequence)
        if try message.readInteger() != 3 { throw SnmpFormatError("SNMP: not a v3 message.") }
        var header = try message.enter(Ber.sequence)
        let id = try int31(header.readInteger())
        let max = try int31(header.readInteger())
        let flags = try header.readOctets()
        guard flags.count == 1 else { throw SnmpFormatError("SNMPv3: msgFlags is one byte.") }
        if try header.readInteger() != 3 { throw SnmpFormatError("SNMPv3: only the User-based Security Model is spoken.") }
        if header.hasMore { throw SnmpFormatError("SNMPv3: data after the header.") }
        let (st, ss, sl) = try message.next()
        guard st == Ber.octetString else { throw SnmpFormatError("SNMPv3: security parameters expected.") }
        var security = Ber.Reader(data, start: ss, end: ss + sl)
        var usm = try security.enter(Ber.sequence)
        if security.hasMore { throw SnmpFormatError("SNMPv3: data after the security parameters.") }
        let engine = try bounded(usm.readOctets(), Usm.maxEngineId, "msgAuthoritativeEngineID")
        let boots = try int31(usm.readInteger())
        let time = try int31(usm.readInteger())
        let user = String(decoding: try bounded(usm.readOctets(), maxField, "msgUserName"), as: UTF8.self)
        let (at, aStart, aLength) = try usm.next()
        guard at == Ber.octetString, aLength <= maxField else { throw SnmpFormatError("SNMPv3: authentication parameters expected.") }
        let priv = try bounded(usm.readOctets(), maxField, "msgPrivacyParameters")
        if usm.hasMore { throw SnmpFormatError("SNMPv3: data after the USM parameters.") }
        var result = SnmpV3Message(messageId: id, maxMessageSize: max, flags: flags[0], engineId: engine, engineBoots: boots, engineTime: time,
                                   userName: user, authParameters: Array(data[aStart..<aStart + aLength]), privParameters: priv)
        result.authOffset = aLength == 0 ? -1 : aStart
        let (dt, ds, dl) = try message.next()
        if message.hasMore || outer.hasMore { throw SnmpFormatError("SNMPv3: extra data after the message.") }
        if dt == Ber.octetString {
            result.encrypted = Array(data[ds..<ds + dl])
            return result
        }
        guard dt == Ber.sequence else { throw SnmpFormatError("SNMPv3: scoped PDU expected.") }
        var scoped = Ber.Reader(data, start: ds, end: ds + dl)
        let (cid, cname, pdu) = try readScoped(data, &scoped)
        result.contextEngineId = cid
        result.contextName = cname
        result.pdu = pdu
        return result
    }

    private static func int31(_ value: Int64) throws -> Int {
        guard value >= 0 && value <= Int64(Int32.max) else { throw SnmpFormatError("SNMPv3: value out of range.") }
        return Int(value)
    }

    private static func bounded(_ bytes: [UInt8], _ limit: Int, _ what: String) throws -> [UInt8] {
        guard bytes.count <= limit else { throw SnmpFormatError("SNMPv3: \(what) longer than \(limit) bytes.") }
        return bytes
    }

    /// For logs: the message's shape, never its keys or digest.
    public var description: String { "SNMPv3 message \(messageId) flags \(SnmpValue.hexString([flags])) user \(userName)" }
}
