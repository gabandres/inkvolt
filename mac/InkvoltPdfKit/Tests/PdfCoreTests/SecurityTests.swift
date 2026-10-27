import Foundation
import Testing
@testable import PdfCore

/// Encrypted test PDFs, written by MuPDF (the Windows tests have PDFsharp write them).
enum Encrypt {
    /// `data` encrypted with MuPDF's `method` ("rc4-40", "rc4-128", "aes-128", "aes-256").
    static func with(_ data: [UInt8], _ method: String, user: String, owner: String, permissions: PdfPermissions = .all) -> [UInt8] {
        let engine = try! PdfEngine.open(data)
        defer { engine.close() }
        return try! engine.write(options: "encrypt=\(method),user-password=\(user),owner-password=\(owner),permissions=\(PdfSecurity.pValue(permissions))")
    }
}

/// Ported from SecurityTests.cs. Adapted: ReadsOlderMethods reads the methods MuPDF can write (RC4 40 and 128 bits,
/// AES-128, AES-256; `TestPdf.encrypted` is AES-256 here, AES-128 from PDFsharp on Windows), and not V4 with RC4, which
/// MuPDF doesn't write; PermissionsAreWrittenAndReadBack reads /P through MuPDF; SignedFilesNeedConsentToEncrypt uses a
/// signed-looking file (`SignedEditTests.signed()`: a signature field with a placeholder signature).
struct SecurityTests {
    @Test func protectWithAes256OpensWithThePasswordOnly() throws {
        let pdf = try PdfSecurity.protect(TestPdf.make(2), nil, userPassword: "open", ownerPassword: "owner")
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(pdf).close() }
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(pdf, password: "wrong").close() }
        let engine = try PdfEngine.open(pdf, password: "open")
        #expect(engine.pageCount == 2)
        #expect(try engine.text(0).text.contains("Page 1 alpha"))
        engine.close()
        let owner = try PdfEngine.open(pdf, password: "owner")
        #expect(owner.pageCount == 2)
        owner.close()

        let info = try PdfSecurity.readSecurity(pdf, "open")
        #expect(info.method == .aes256)
        #expect(info.requiresOpenPassword)
        #expect(info.permissions.isUnrestricted)
        #expect(throws: PasswordRequired(wrongPassword: false)) { try PdfSecurity.readSecurity(pdf, nil) }
        #expect(throws: PasswordRequired(wrongPassword: true)) { try PdfSecurity.readSecurity(pdf, "wrong") }
    }

    @Test func permissionsAreWrittenAndReadBack() throws {
        let wanted = PdfPermissions(print: .lowResolution, copy: false, modify: false, annotate: true, fillForms: true, assemble: false)
        let pdf = try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: nil, ownerPassword: "owner", permissions: wanted)
        let info = try PdfSecurity.readSecurity(pdf, nil)
        #expect(info.method == .aes256)
        #expect(!info.requiresOpenPassword)
        #expect(info.permissions == wanted)
        #expect(info.revision >= 5)

        // /P as stored: print (bit 3) on, high-quality print (bit 12) off, copy (bit 5) off.
        let p = try #require(try MuDoc.open(pdf).encryptInfo()).p
        #expect(p & 4 != 0)
        #expect(p & 2048 == 0)
        #expect(p & 16 == 0)
        #expect(p & 32 != 0)

        let none = try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: "u", ownerPassword: nil,
                                           permissions: PdfPermissions(print: .none, copy: false, modify: false, annotate: false, fillForms: false, assemble: false))
        #expect(try PdfSecurity.readSecurity(none, "u").permissions.print == PrintPermission.none)
        // A random owner password was made: the user password can't lift the restrictions.
        #expect(throws: OwnerPasswordRequired.self) { try PdfSecurity.unprotect(none, "u") }
    }

    @Test func unprotectNeedsTheOwnerPassword() throws {
        let pdf = try PdfSecurity.protect(TestPdf.make(1), nil, userPassword: "open", ownerPassword: "owner")
        #expect(throws: OwnerPasswordRequired.self) { try PdfSecurity.unprotect(pdf, "open") }
        #expect(throws: OwnerPasswordRequired.self) { try PdfSecurity.unprotect(pdf, "nope") }

        // The owner can change the protection.
        let changed = try PdfSecurity.protect(pdf, "owner", userPassword: "new-open", ownerPassword: "new-owner")
        #expect(throws: PasswordRequired.self) { try PdfSecurity.readSecurity(changed, "open") }
        #expect(try PdfSecurity.readSecurity(changed, "new-open").method == .aes256)

        let plain = try PdfSecurity.unprotect(pdf, "owner")
        #expect(try PdfSecurity.readSecurity(plain, nil).method == EncryptionMethod.none)
        let engine = try PdfEngine.open(plain)
        defer { engine.close() }
        #expect(!engine.isEncrypted)
        #expect(try engine.text(0).text.contains("Page 1 alpha"))
    }

    @Test func readsOlderMethods() throws {
        let unencrypted = try PdfSecurity.readSecurity(TestPdf.make(1), nil)
        #expect(unencrypted.method == EncryptionMethod.none)
        #expect(!unencrypted.requiresOpenPassword)

        let aes = try PdfSecurity.readSecurity(TestPdf.encrypted(1, "pw"), "pw")
        #expect(aes.method == .aes256)
        #expect(aes.requiresOpenPassword)

        func with(_ method: String) -> [UInt8] { Encrypt.with(TestPdf.make(1), method, user: "pw", owner: "owner") }
        #expect(try PdfSecurity.readSecurity(with("rc4-40"), "pw").method == .rc4With40Bits)
        #expect(try PdfSecurity.readSecurity(with("rc4-128"), "pw").method == .rc4With128Bits)
        #expect(try PdfSecurity.readSecurity(with("aes-128"), "pw").method == .aes128)
    }

    @Test func signedFilesNeedConsentToEncrypt() throws {
        let signed = SignedEditTests.signed()
        #expect(throws: SignaturesWouldBreak.self) { try PdfSecurity.protect(signed, nil, userPassword: "x", ownerPassword: "y") }
        let (pdf, report) = try SignedEdits.run({ try PdfSecurity.protect(signed, nil, userPassword: "x", ownerPassword: "y") }, allowRewrite: true)
        #expect(!report.appended)
        #expect(try PdfSecurity.readSecurity(pdf, "x").method == .aes256)
    }
}

/// Ported from PasswordStrengthTests.cs.
struct PasswordStrengthTests {
    @Test(arguments: [
        ("", 0), ("abc", 1), ("password", 1), ("aaaaaaaaaaaa", 1), ("abcdefgh", 1), ("sunflower", 1), ("Sunflower7", 3),
        ("Sunflower7!x", 4), ("correct horse battery staple", 4),
    ])
    func ratesPasswords(password: String, score: Int) {
        #expect(PasswordStrength.rate(password).score == score)
    }

    @Test func labelsMatchScores() {
        #expect(PasswordStrength.rate("").label == "")
        #expect(PasswordStrength.rate("123456").label == "Weak")
        #expect(PasswordStrength.rate("correct horse battery staple").label == "Strong")
    }
}

/// Ported from OwnerPasswordTests.cs (but its TextStamps line, which comes with D4).
struct OwnerPasswordTests {
    /// Opens without a password, but changes are restricted by an owner password.
    static func ownerOnly(_ owner: String) -> [UInt8] {
        Encrypt.with(TestPdf.make(2), "aes-128", user: "", owner: owner, permissions: PdfPermissions(modify: false))
    }

    @Test func editsAskForTheOwnerPasswordAndWorkWithIt() throws {
        let data = Self.ownerOnly("own")
        let viewing = try PdfEngine.open(data)
        #expect(viewing.pageCount == 2) // viewing needs no password
        viewing.close()

        #expect(throws: OwnerPasswordRequired(wrongPassword: false)) { try PageEditor.rotate(data, nil, [0], 90) }
        #expect(throws: OwnerPasswordRequired(wrongPassword: true)) { try PageEditor.rotate(data, "nope", [0], 90) }

        let rotated = try PageEditor.rotate(data, "own", [0], 90)
        let after = try PdfEngine.open(rotated, password: "own")
        defer { after.close() }
        #expect(after.pageCount == 2)
        #expect(after.page(0).width > after.page(0).height)
    }
}
