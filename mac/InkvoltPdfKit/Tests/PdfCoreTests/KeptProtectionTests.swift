import Foundation
import Testing
@testable import PdfCore

/// Ported from KeptProtectionTests.cs: edits of encrypted PDFs keep the protection, permissions and both passwords. On the
/// Mac MuPDF writes an edit under the document's own encryption, so it keeps the method too (Windows upgrades RC4 to
/// AES-128) and never needs the open password (Windows needs it for AES-256). Adapted: the edits are a rotation and a
/// note (filling a form comes with D5); Aes256WithAnUnknownOpenPasswordAsksOrDropsIt keeps the open password
/// without asking, and drops it on request; RecoversTheUserPasswordFromTheOwnerPassword checks that an edit keeps a
/// non-ASCII open password (there is nothing to recover on the Mac). Left out: extraction (D3).
struct KeptProtectionTests {
    static let owner = "owner-pw"
    static let restricted = PdfPermissions(print: .lowResolution, copy: false, modify: true, annotate: true, fillForms: true, assemble: true)

    /// Two pages encrypted with MuPDF's `method`.
    static func encrypted(_ method: String, _ user: String, permissions: PdfPermissions = restricted) -> [UInt8] {
        Encrypt.with(TestPdf.make(2), method, user: user, owner: owner, permissions: permissions)
    }

    static let methods: [(String, EncryptionMethod)] = [
        ("rc4-40", .rc4With40Bits), ("rc4-128", .rc4With128Bits), ("aes-128", .aes128), ("aes-256", .aes256),
    ]

    /// The restrictions as the method's revision can store them (revision 2 has no low-resolution printing).
    private func expected(_ info: SecurityInfo) -> PdfPermissions {
        PdfSecurity.permissions(PdfSecurity.pValue(Self.restricted), revision: info.revision)
    }

    static let edits: [(name: String, edit: @Sendable ([UInt8]) throws -> [UInt8])] = [
        ("rotate", { try PageEditor.rotate($0, owner, [0], 90) }),
        ("note", { try Annotations.addNote($0, owner, 0, 100, 100, "Kept", author: "Tester") }),
    ]

    @Test(arguments: methods)
    func editsKeepProtectionWithoutAnOpenPassword(method: String, kind: EncryptionMethod) throws {
        let pdf = Self.encrypted(method, "")
        #expect(try PdfSecurity.readSecurity(pdf, nil).method == kind)
        for (name, edit) in Self.edits {
        let edited = try edit(pdf)
        let info = try PdfSecurity.readSecurity(edited, nil)
        #expect(info.isEncrypted)
        #expect(info.method == kind)
        #expect(!info.requiresOpenPassword)
        #expect(info.permissions == expected(info))
        let e = try PdfEngine.open(edited)
        #expect(e.pageCount == 2)
        e.close()
        // Still needs the owner password to edit, and it still works.
        #expect(throws: OwnerPasswordRequired.self) { try PageEditor.rotate(edited, nil, [1], 90) }
        #expect(throws: OwnerPasswordRequired.self) { try PageEditor.rotate(edited, "nope", [1], 90) }
        _ = try PdfSecurity.readSecurity(PageEditor.rotate(edited, Self.owner, [1], 90), nil)
        #expect(info.isEncrypted, "\(name)")
        }
    }

    @Test(arguments: methods)
    func editsKeepTheOpenPassword(method: String, kind: EncryptionMethod) throws {
        let pdf = Self.encrypted(method, "user-pw")
        #expect(try PdfSecurity.readSecurity(pdf, "user-pw").method == kind)
        for (name, edit) in Self.edits {
        let edited = try edit(pdf)
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(edited).close() }
        try PdfEngine.open(edited, password: "user-pw").close()
        try PdfEngine.open(edited, password: Self.owner).close()
        let info = try PdfSecurity.readSecurity(edited, "user-pw")
        #expect(info.method == kind)
        #expect(info.requiresOpenPassword)
        #expect(info.permissions == expected(info))
        #expect(PdfSecurity.isOpenPassword(edited, "user-pw"))
        #expect(!PdfSecurity.isOpenPassword(edited, Self.owner), "\(name)")
        }
    }

    @Test func theEditIsInTheProtectedResult() throws {
        let pdf = Self.encrypted("aes-128", "u")
        let noted = try Annotations.addNote(pdf, Self.owner, 0, 100, 100, "Kept", author: "Tester")
        #expect(try Annotations.read(noted, "u").contains { $0.contents == "Kept" })
        let rotated = try PageEditor.rotate(noted, Self.owner, [0], 90)
        let e = try PdfEngine.open(rotated, password: "u")
        defer { e.close() }
        #expect(e.page(0).width > e.page(0).height)
    }

    @Test func aes256KeepsAnUnknownOpenPasswordOrDropsIt() throws {
        let pdf = Self.encrypted("aes-256", "secret")
        let kept = try PageEditor.rotate(pdf, Self.owner, [0], 90)
        #expect(try PdfSecurity.readSecurity(kept, "secret").requiresOpenPassword)

        let dropped = try KeptProtection.run(openPassword: nil, dropOpenPassword: true) { try PageEditor.rotate(pdf, Self.owner, [0], 90) }
        let info = try PdfSecurity.readSecurity(dropped, nil)
        #expect(info.method == .aes256)
        #expect(!info.requiresOpenPassword)
        #expect(info.permissions == Self.restricted)
        #expect(throws: OwnerPasswordRequired.self) { try PageEditor.rotate(dropped, nil, [0], 90) }
    }

    @Test(arguments: ["rc4-40", "rc4-128", "aes-128"])
    func anEditKeepsANonAsciiOpenPassword(method: String) throws {
        let pdf = Self.encrypted(method, "Zürich 42", permissions: PdfPermissions(copy: false))
        let edited = try PageEditor.rotate(pdf, Self.owner, [0], 90)
        let reopened = try PdfEngine.open(edited, password: "Zürich 42")
        #expect(reopened.pageCount == 2)
        reopened.close()
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(edited, password: "Zurich 42").close() }
    }

    @Test func protectionChangesAreNotUndone() throws {
        let pdf = Self.encrypted("aes-128", "u")
        #expect(try PdfSecurity.readSecurity(PdfSecurity.unprotect(pdf, Self.owner), nil).method == EncryptionMethod.none)
        let changed = try PdfSecurity.protect(pdf, Self.owner, userPassword: "new", ownerPassword: "new-owner", permissions: .all, method: .aes128)
        let info = try PdfSecurity.readSecurity(changed, "new")
        #expect(info.method == .aes128)
        #expect(info.permissions.isUnrestricted)
    }

    @Test func sessionUndoRestoresThePasswords() throws {
        let plain = TestPdf.make(2)
        let session = try DocumentSession.fromBytes(plain, "t.pdf")
        defer { session.close() }
        try session.commit(PdfSecurity.protect(plain, nil, userPassword: "open", ownerPassword: "own"), "Protect", password: "own", openPassword: "open")
        #expect(session.password == "own")
        #expect(session.openPassword == "open")
        try session.undo()
        #expect(session.password == nil)
        #expect(!session.engine.isEncrypted)
        try session.redo()
        #expect(session.password == "own")
        #expect(session.engine.isEncrypted)

        // An edit keeps the protection and the passwords.
        try session.commit(PageEditor.rotate(session.data, session.password, [0], 90), "Rotate")
        #expect(try PdfSecurity.readSecurity(session.data, "open").requiresOpenPassword)
    }
}
