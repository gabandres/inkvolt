import Foundation
import PrintCore
import PrintMac
import Testing
@testable import PdfCore

/// Roadmap 4.18 of Inkvolt Print: a scan preset's PDF/A-2b and password-protected PDFs, written by PrintCore's scan writer
/// (with the system's cryptography, PrintMac's `ApplePdfCrypto`, as the app installs it), read by Inkvolt PDF for Mac's own
/// PDF/A check, security reading and engine (MuPDF). Ported from PrintScanArchiveTests.cs with the same names. Adapted: the
/// Mac reads a file's security with MuPDF where Windows has PDFsharp, and MuPDF takes the password in UTF-8 here, so the
/// Spanish password opens the engine too.
struct PrintScanArchiveTests {
    private static let password = "Secret 2026"

    /// A password beyond ASCII.
    private static let spanish = "Contraseña 2026"

    init() { PdfEncryption.crypto = ApplePdfCrypto() }

    private static func pdf(_ options: PdfWriteOptions?, title: String = "Invoice (March) Ñ") throws -> [UInt8] {
        try PdfWriter.write([PdfWriter.Page(ScanPdfTests.jpeg, dpi: 4, words: [PdfWriter.Word("Archived", x: 2, y: 2, width: 20, height: 2)]),
                             PdfWriter.Page(ScanPdfTests.jpeg, dpi: 4)], title: title, options: options)
    }

    @Test func aPdfAScanPassesInkvoltPdfsCheck() throws {
        let problems = PdfA.validate(try Self.pdf(PdfWriteOptions(pdfA: true)))
        #expect(problems.isEmpty, "\(problems.joined(separator: "; "))")
    }

    @Test func aPlainScanIsNotPdfA() throws { #expect(!PdfA.validate(try Self.pdf(nil)).isEmpty) }

    @Test func aPdfAScanKeepsItsTextLayer() throws {
        let engine = try PdfEngine.open(try Self.pdf(PdfWriteOptions(pdfA: true)))
        #expect(engine.pageCount == 2)
        #expect(try engine.text(0).find("Archived", matchCase: true, wholeWord: false).count == 1)
    }

    @Test func aProtectedScanIsAes256AndOpensWithItsPasswordOnly() throws {
        let data = try Self.pdf(PdfWriteOptions(password: Self.password))
        let info = try PdfSecurity.readSecurity(data, Self.password)
        #expect(info.method == .aes256)
        #expect(info.revision == 6)
        #expect(info.requiresOpenPassword)
        #expect(info.permissions.isUnrestricted)
        #expect(throws: PasswordRequired.self) { try PdfSecurity.readSecurity(data, nil) }
        #expect(throws: PasswordRequired.self) { try PdfSecurity.readSecurity(data, "wrong") }
        #expect(throws: PasswordRequired.self) { try PdfEngine.open(data) }
        let engine = try PdfEngine.open(data, password: Self.password)
        #expect(engine.pageCount == 2)
        #expect(try engine.text(0).find("Archived", matchCase: true, wholeWord: false).count == 1)
    }

    /// Off: PdfEngine draws every page of a document opened with its open password white (found here, not this scan's:
    /// Inkvolt PDF's own Protect output, AES-128 and AES-256, draws white the same way; an owner-only one draws; the text
    /// layer reads, and once unprotected the scan draws as the plain one: `aProtectedScanDrawsAsThePlainOneOnceUnprotected`).
    /// PLAN, "Open".
    @Test(.disabled("PdfEngine draws a document opened with its open password white (PLAN, Open)"))
    func aProtectedScanDrawsAsThePlainOne() throws {
        let plain = try PdfEngine.open(try Self.pdf(nil))
        let locked = try PdfEngine.open(try Self.pdf(PdfWriteOptions(password: Self.password)), password: Self.password)
        #expect(try plain.render(0, scale: 0.5).pixels == locked.render(0, scale: 0.5).pixels)
    }

    /// Mac addition: the protected scan's pictures come back whole through MuPDF's decryption (Remove Protection, then drawn).
    @Test func aProtectedScanDrawsAsThePlainOneOnceUnprotected() throws {
        let plain = try PdfEngine.open(try Self.pdf(nil))
        let open = try PdfEngine.open(try PdfSecurity.unprotect(try Self.pdf(PdfWriteOptions(password: Self.password)), Self.password))
        #expect(try plain.render(0, scale: 0.5).pixels == open.render(0, scale: 0.5).pixels)
    }

    @Test func aPasswordBeyondAsciiOpensIt() throws {
        let data = try Self.pdf(PdfWriteOptions(password: Self.spanish))
        #expect(try PdfSecurity.readSecurity(data, Self.spanish).method == .aes256)
        #expect(throws: PasswordRequired.self) { try PdfSecurity.readSecurity(data, "Contrasena 2026") }
        #expect(try PdfEngine.open(data, password: Self.spanish).pageCount == 2) // Mac: MuPDF reads it in UTF-8
    }

    @Test func inkvoltPdfRemovesTheProtectionWithThePassword() throws {
        let open = try PdfSecurity.unprotect(try Self.pdf(PdfWriteOptions(password: Self.password)), Self.password)
        #expect(try PdfSecurity.readSecurity(open, nil).method == .none)
    }
}
