import Foundation
import Testing
@testable import PdfCore

/// Mac only: a document opened with its open (user) password draws as the plain one, in every method MuPDF writes and
/// in Inkvolt PDF's own Protect output.
struct EncryptedRenderTests {
    static let user = "open-pw"
    static let methods = ["rc4-40", "rc4-128", "aes-128", "aes-256"]
    static let textBand = RectD(60, 70, 400, 120)

    /// The fraction of dark pixels in `region` of the first page, rendered at 2x.
    static func ink(_ engine: PdfEngine, _ region: RectD = textBand) throws -> Double {
        let img = try engine.render(0, scale: 2, region: region)
        var dark = 0
        var i = 0
        while i + 2 < img.pixels.count {
            if Int(img.pixels[i]) + Int(img.pixels[i + 1]) + Int(img.pixels[i + 2]) < 384 { dark += 1 }
            i += 3
        }
        return Double(dark) / Double(img.width * img.height)
    }

    @Test(arguments: methods)
    func aPageOpenedWithItsPasswordDrawsItsInk(method: String) throws {
        let plain = TestPdf.make(1)
        let plainEngine = try PdfEngine.open(plain)
        let expected = try Self.ink(plainEngine)
        plainEngine.close()
        #expect(expected > 0.01)
        let pdf = Encrypt.with(plain, method, user: Self.user, owner: Self.user + "-owner")
        let engine = try PdfEngine.open(pdf, password: Self.user)
        defer { engine.close() }
        #expect(engine.isEncrypted)
        let ink = try Self.ink(engine)
        #expect(abs(ink - expected) < 0.002, "\(method): \(ink) against \(expected)")
    }

    /// A wrong password tried after the right one (MuPDF overwrites the document's key on every failed try) leaves the
    /// document readable: its streams come out as the plain file's.
    @Test(arguments: methods)
    func aWrongPasswordAfterTheRightOneKeepsTheDocumentReadable(method: String) throws {
        let pdf = Encrypt.with(TestPdf.make(1), method, user: Self.user, owner: Self.user + "-owner")
        let doc = try MuDoc.open(pdf)
        #expect(doc.needsPassword)
        #expect(doc.authBits(Self.user) & 2 != 0)
        #expect(doc.authBits("wrong") == 0)
        #expect(doc.needsPassword)
        let plain = try doc.write("encrypt=none")
        let engine = try PdfEngine.open(plain)
        defer { engine.close() }
        #expect(try Self.ink(engine) > 0.01, "\(method)")
    }

    /// A file with only an owner password opens with none; a wrong owner password tried later (Remove Protection's prompt)
    /// keeps it readable too (the empty password authenticated again; the orchestrator's review).
    @Test(arguments: methods)
    func aWrongOwnerPasswordOnAFileThatOpensWithNoneKeepsItReadable(method: String) throws {
        let pdf = Encrypt.with(TestPdf.make(1), method, user: "", owner: Self.user + "-owner")
        let doc = try MuDoc.open(pdf)
        #expect(!doc.needsPassword)
        #expect(doc.authBits("wrong") == 0)
        let plain = try doc.write("encrypt=none")
        let engine = try PdfEngine.open(plain)
        defer { engine.close() }
        #expect(try Self.ink(engine) > 0.01, "\(method)")
    }

    /// The engine's other instances (a sibling, as print and search threads use; the text one; a saved picture) and the
    /// print copy read a protected document as the plain one.
    @Test func theEnginesOtherReadersAndThePrintCopyDrawAProtectedDocument() throws {
        let pdf = try PdfSecurity.protect(TestPdf.make(2), nil, userPassword: Self.user, ownerPassword: "owner")
        let engine = try PdfEngine.open(pdf, password: Self.user)
        defer { engine.close() }
        let sibling = try engine.sibling()
        defer { sibling.close() }
        #expect(try Self.ink(sibling) > 0.01)
        #expect(try engine.findAll("alpha", matchCase: false, wholeWord: false).reduce(0) { $0 + $1.hits.count } == 2)
        #expect(try engine.textLines(0, annotations: true).contains { $0.text.contains("quick brown fox") })
        // The saved picture is the plain file's, byte for byte.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("encrypted-render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plain = try PdfEngine.open(TestPdf.make(2))
        defer { plain.close() }
        try plain.saveImage(0, dpi: 36, path: dir.appendingPathComponent("plain.png").path, jpeg: false)
        try engine.saveImage(0, dpi: 36, path: dir.appendingPathComponent("protected.png").path, jpeg: false)
        #expect(try Data(contentsOf: dir.appendingPathComponent("plain.png")) == Data(contentsOf: dir.appendingPathComponent("protected.png")))
        let shown = (0..<engine.pageCount).map { (engine.page($0).width, engine.page($0).height) }
        let copy = try PrintCopy.make(pdf, Self.user, shown: shown)
        let printed = try PdfEngine.open(copy.data)
        defer { printed.close() }
        #expect(try Self.ink(printed) > 0.01)
    }

    @Test(arguments: [EncryptionMethod.aes256, .aes128])
    func protectOutputDrawsItsInk(method: EncryptionMethod) throws {
        let plain = TestPdf.make(2)
        let pdf = try PdfSecurity.protect(plain, nil, userPassword: Self.user, ownerPassword: "owner", method: method)
        let engine = try PdfEngine.open(pdf, password: Self.user)
        defer { engine.close() }
        #expect(try Self.ink(engine) > 0.01)
        // The owner password opens it too, and draws.
        let byOwner = try PdfEngine.open(pdf, password: "owner")
        defer { byOwner.close() }
        #expect(try Self.ink(byOwner) > 0.01)
    }
}
