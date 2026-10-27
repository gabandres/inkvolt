import Foundation

/// What printing a protected document allows.
public enum PrintPermission: Equatable, Sendable { case none, lowResolution, highResolution }

/// How a document is encrypted (standard security handler).
public enum EncryptionMethod: Equatable, Sendable { case none, rc4With40Bits, rc4With128Bits, aes128, aes256, unknown }

/// What a reader opening the document with the user (open) password may do.
public struct PdfPermissions: Equatable, Sendable {
    public var print: PrintPermission
    /// Copy or extract text and graphics.
    public var copy: Bool
    /// Change the document's content (other than the operations below).
    public var modify: Bool
    /// Add or change comments, and fill in form fields.
    public var annotate: Bool
    /// Fill in form fields (even when `annotate` is off).
    public var fillForms: Bool
    /// Insert, rotate or delete pages and create bookmarks or thumbnails.
    public var assemble: Bool

    public init(print: PrintPermission = .highResolution, copy: Bool = true, modify: Bool = true, annotate: Bool = true,
                fillForms: Bool = true, assemble: Bool = true) {
        self.print = print
        self.copy = copy
        self.modify = modify
        self.annotate = annotate
        self.fillForms = fillForms
        self.assemble = assemble
    }

    /// Everything allowed.
    public static let all = PdfPermissions()

    /// True when nothing is restricted.
    public var isUnrestricted: Bool { self == .all }
}

/// A document's encryption: method, the security handler's revision (/R; 0 when unencrypted), whether opening needs a
/// password, and what the user password allows (everything when unencrypted).
public struct SecurityInfo: Equatable, Sendable {
    public var method: EncryptionMethod
    public var revision: Int
    public var requiresOpenPassword: Bool
    public var permissions: PdfPermissions
    public var isEncrypted: Bool { method != .none }
}

/// Password protection (the Windows app's `PdfSecurity`): encrypts with AES-256 (or AES-128), removes encryption, and
/// reports how a document is protected. Both edits rewrite the file, so a signed document needs the caller's consent
/// (`SignedEdits.run` with the rewrite allowed), else they throw `SignaturesWouldBreak`.
public enum PdfSecurity {
    // /P bits (ISO 32000-2 table 22), 1-based bit positions.
    private static let bitPrint: Int32 = 1 << 2, bitModify: Int32 = 1 << 3, bitCopy: Int32 = 1 << 4, bitAnnotate: Int32 = 1 << 5,
                       bitFillForms: Int32 = 1 << 8, bitAccessibility: Int32 = 1 << 9, bitAssemble: Int32 = 1 << 10,
                       bitHighPrint: Int32 = 1 << 11

    /// Encrypts the document with AES-256 (or AES-128). At least one password must be given. Without an `ownerPassword`,
    /// a document with restricted `permissions` gets a random one (nobody can lift the restrictions), else the user
    /// password doubles as the owner password.
    /// - Parameter password: the document's current password, if it is already encrypted (its owner password).
    /// - Throws: `PdfEditError` when neither password was given; `OwnerPasswordRequired`; `SignaturesWouldBreak`.
    public static func protect(_ data: [UInt8], _ password: String?, userPassword: String?, ownerPassword: String?,
                               permissions: PdfPermissions = .all, method: EncryptionMethod = .aes256) throws -> [UInt8] {
        if (userPassword ?? "").isEmpty && (ownerPassword ?? "").isEmpty {
            throw PdfEditError("Protecting a PDF needs an open password or a permissions password.")
        }
        guard method == .aes256 || method == .aes128 else { throw PdfEditError("Inkvolt PDF encrypts with AES-256 or AES-128.") }
        var owner = ownerPassword ?? ""
        if owner.isEmpty {
            owner = permissions.isUnrestricted ? userPassword ?? "" : randomPassword()
        }
        let doc = try PdfEdit.open(data, password)
        try SignedEdits.requireRewrite(data, reason: "encrypting rewrites the whole file")
        return try doc.write("garbage=compact," + encryptOptions(method, user: userPassword ?? "", owner: owner, p: pValue(permissions)))
    }

    /// Removes the document's encryption (and so its passwords and permission restrictions).
    /// - Parameter password: the owner (permissions) password; the user password suffices only when both are the same.
    public static func unprotect(_ data: [UInt8], _ password: String?) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        if !doc.hasEncrypt { return data }
        try SignedEdits.requireRewrite(data, reason: "removing the encryption rewrites the whole file")
        return try doc.write("garbage=compact,encrypt=none")
    }

    /// How the document is protected: method, revision, whether opening needs a password, and permissions.
    /// - Parameter password: needed only when the document has a user (open) password.
    /// - Throws: `PasswordRequired` when the document needs an open password and it is missing or wrong.
    public static func readSecurity(_ data: [UInt8], _ password: String?) throws -> SecurityInfo {
        let doc: MuDoc
        do {
            doc = try MuDoc.open(data)
        } catch let e as PdfEngineError {
            throw PdfEditError("This PDF can't be read: \(e.message)")
        }
        let needsPassword = doc.needsPassword
        if needsPassword {
            if (password ?? "").isEmpty { throw PasswordRequired(wrongPassword: false) }
            if doc.authBits(password) == 0 { throw PasswordRequired(wrongPassword: true) }
        }
        guard let info = try doc.encryptInfo() else {
            return SecurityInfo(method: .none, revision: 0, requiresOpenPassword: false, permissions: .all)
        }
        return SecurityInfo(method: method(info), revision: info.r, requiresOpenPassword: needsPassword,
                            permissions: permissions(info.p, revision: info.r))
    }

    /// True when `password` is the encrypted document's open (user) password, not just its owner password.
    public static func isOpenPassword(_ data: [UInt8], _ password: String?) -> Bool {
        guard let password, !password.isEmpty, let doc = try? MuDoc.open(data), doc.needsPassword else { return false }
        return doc.authBits(password) & 2 != 0
    }

    /// True when the document needs a password to open (the empty user password doesn't open it).
    public static func needsOpenPassword(_ data: [UInt8]) -> Bool { (try? MuDoc.open(data))?.needsPassword ?? false }

    /// The permissions a /P value grants under security handler revision `revision`.
    static func permissions(_ p: Int32, revision: Int) -> PdfPermissions {
        func has(_ bit: Int32) -> Bool { p & bit != 0 }
        let print: PrintPermission = !has(bitPrint) ? .none
            : revision >= 3 && !has(bitHighPrint) ? .lowResolution : .highResolution
        // Revision 2 has no separate form-fill and assembly bits: annotate and modify cover them.
        return revision >= 3
            ? PdfPermissions(print: print, copy: has(bitCopy), modify: has(bitModify), annotate: has(bitAnnotate),
                             fillForms: has(bitFillForms), assemble: has(bitAssemble))
            : PdfPermissions(print: print, copy: has(bitCopy), modify: has(bitModify), annotate: has(bitAnnotate),
                             fillForms: has(bitAnnotate), assemble: has(bitModify))
    }

    /// The /P value for `permissions`: the reserved bits set as the standard asks, accessibility extraction always allowed.
    static func pValue(_ permissions: PdfPermissions) -> Int32 {
        var p = Int32(bitPattern: 0xFFFF_F0C0) | bitAccessibility
        if permissions.print != .none { p |= bitPrint }
        if permissions.print == .highResolution { p |= bitHighPrint }
        if permissions.copy { p |= bitCopy }
        if permissions.modify { p |= bitModify }
        if permissions.annotate { p |= bitAnnotate }
        if permissions.fillForms { p |= bitFillForms }
        if permissions.assemble { p |= bitAssemble }
        return p
    }

    /// MuPDF's write options for new encryption. Its options are comma-separated, so a password can't hold a comma.
    static func encryptOptions(_ method: EncryptionMethod, user: String, owner: String, p: Int32) -> String {
        let name: String
        switch method {
        case .aes128: name = "aes-128"
        case .rc4With40Bits: name = "rc4-40"
        case .rc4With128Bits: name = "rc4-128"
        default: name = "aes-256"
        }
        return "encrypt=\(name),user-password=\(user),owner-password=\(owner),permissions=\(p)"
    }

    /// The method an encryption dictionary names.
    static func method(_ info: (v: Int, r: Int, length: Int, p: Int32, filter: String, cfm: String)) -> EncryptionMethod {
        if info.filter != "Standard" { return .unknown }
        switch info.v {
        case 1: return .rc4With40Bits
        case 2, 3: return info.length <= 40 ? .rc4With40Bits : .rc4With128Bits
        case 4:
            switch info.cfm {
            case "", "Identity": return .none
            case "AESV2": return .aes128
            case "AESV3": return .aes256
            case "V2": return .rc4With128Bits
            default: return .unknown
            }
        case 5: return .aes256
        default: return .unknown
        }
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 18)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString()
    }
}

/// A rough strength hint for a new document password (length and variety, with common patterns marked down).
public enum PasswordStrength {
    private static let common = [
        "password", "passw0rd", "123456", "12345678", "123456789", "qwerty", "abc123", "letmein", "welcome", "admin",
        "iloveyou", "monkey", "dragon", "111111", "000000", "secret", "pdf",
    ]

    /// 0 (empty) to 4 (strong), with a word for it.
    public static func rate(_ password: String) -> (score: Int, label: String) {
        if password.isEmpty { return (0, "") }
        let lower = password.lowercased()
        let units = Array(password.utf16)
        if units.count < 6 || common.contains(lower) || Set(units).count <= 2 { return (1, "Weak") }

        var classes = 0
        let scalars = password.unicodeScalars
        if scalars.contains(where: { $0.properties.isLowercase }) { classes += 1 }
        if scalars.contains(where: { $0.properties.isUppercase }) { classes += 1 }
        if scalars.contains(where: { $0.properties.generalCategory == .decimalNumber }) { classes += 1 }
        if scalars.contains(where: { !($0.properties.isAlphabetic || $0.properties.generalCategory == .decimalNumber) }) { classes += 1 }

        // Long passphrases are strong even in one case; runs like "abcdef" or "123456" don't count for much.
        let n = units.count
        var score = n >= 16 ? 4 : n >= 12 ? 3 : n >= 8 ? 2 : 1
        if classes >= 3 && n >= 10 { score += 1 }
        if classes == 1 && n < 16 { score -= 1 }
        if common.contains(where: { $0.count >= 5 && lower.contains($0) }) || isRun(Array(lower.utf16)) { score -= 1 }
        score = min(max(score, 1), 4)
        return (score, ["Weak", "Fair", "Good", "Strong"][score - 1])
    }

    /// The whole password is one ascending or descending run ("abcdefgh", "98765432").
    private static func isRun(_ s: [UInt16]) -> Bool {
        if s.count < 4 { return false }
        let step = Int(s[1]) - Int(s[0])
        if abs(step) != 1 { return false }
        for i in 2..<s.count where Int(s[i]) - Int(s[i - 1]) != step { return false }
        return true
    }
}
