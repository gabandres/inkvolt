import Foundation
import Testing
@testable import PrintCore

/// Roadmap 4.18: a scan preset's PDF/A-2b and its password (AES-256, revision 6), written by `PdfWriter`. Ported from
/// ScanArchiveTests.cs with the same names; Inkvolt PDF for Mac's tests read the same files with its PDF/A check and MuPDF
/// (PrintScanArchiveTests in PdfCoreTests). The cryptography is `TestPdfCrypto`'s here (PrintCore is Foundation only); the
/// app's `ApplePdfCrypto` gives the same values (PrintMacTests). Adapted: DatesAreGregorianWhateverTheRegionalCalendar can't
/// switch the process's calendar in Swift (Foundation's `Locale.current` is fixed), so it checks that the dates written
/// don't follow it; TheTestCryptographyMatchesFips is the Mac's own (the stand-in checked against FIPS vectors).
struct ScanArchiveTests {
    private static let jpeg = TestJpeg.build(width: 850, height: 1100, dnlHeight: nil)

    init() { TestPdfCrypto.install() }

    private static func write(_ options: PdfWriteOptions?, _ title: String = "Scan", jpeg: [UInt8]? = nil) throws -> String {
        let page = PdfWriter.Page(jpeg ?? Self.jpeg, dpi: 100, words: [PdfWriter.Word("Hello", x: 10, y: 10, width: 50, height: 12)])
        let bytes = try PdfWriter.write([page], title: title, options: options)
        return String(bytes.map { Character(Unicode.Scalar($0)) })
    }

    @Test func aPlainScanIsWrittenAsBefore() throws {
        let pdf = try Self.write(nil)
        #expect(pdf.hasPrefix("%PDF-1.4\n"))
        #expect(!pdf.contains("/ID"))
        #expect(!pdf.contains("/Encrypt"))
        #expect(!pdf.contains("/Metadata"))
    }

    @Test func aPdfAScanHasItsIntentMetadataAndId() throws {
        let pdf = try Self.write(PdfWriteOptions(pdfA: true, now: Self.created), "Q3 <report> & \"notes\"")
        #expect(pdf.contains("/OutputIntents [<< /Type /OutputIntent /S /GTS_PDFA1"))
        #expect(Self.first(#"/ID \[<[0-9A-F]{32}> <[0-9A-F]{32}>\]"#, pdf) != nil)
        #expect(pdf.contains("/CreationDate (D:20261122143005Z)"))
        let xmp = Self.first(#"<\?xpacket begin.*?<\?xpacket end="w"\?>"#, pdf)?[0] ?? ""
        #expect(xmp.contains("<pdfaid:part>2</pdfaid:part>"))
        #expect(xmp.contains("<pdfaid:conformance>B</pdfaid:conformance>"))
        #expect(xmp.contains("<xmp:CreateDate>2026-11-22T14:30:05Z</xmp:CreateDate>"))
        #expect(xmp.contains("<pdf:Producer>Inkvolt Print</pdf:Producer>"))
        #expect(xmp.contains("Q3 &lt;report&gt; &amp; \"notes\"")) // escaped, the same title as the Info dictionary's
        #expect(!pdf.contains("/Encrypt"))
    }

    @Test func datesAreGregorianWhateverTheRegionalCalendar() throws {
        let pdf = try Self.write(PdfWriteOptions(pdfA: true, now: Self.created))
        #expect(pdf.contains("/CreationDate (D:20261122143005Z)"))
        #expect(pdf.contains("<xmp:CreateDate>2026-11-22T14:30:05Z</xmp:CreateDate>"))
        #expect(!pdf.contains("2569")) // the Thai Buddhist calendar's year
    }

    @Test func thePdfAProfileIsSrgbNamedForInkvoltPrint() {
        let p = IccProfiles.srgbForPrint()
        let ascii = { (bytes: [UInt8]) in String(bytes.map { Character(Unicode.Scalar($0)) }) }
        #expect(ascii(Array(p[36..<40])) == "acsp")
        #expect(ascii(Array(p[16..<20])) == "RGB ")
        #expect(ascii(p).contains("Inkvolt Print"))
        #expect(ascii(IccProfiles.srgb()).contains("Inkvolt PDF")) // Inkvolt PDF's own, unchanged
    }

    @Test func pdfAAndAPasswordNeverGoTogether() {
        #expect(throws: PdfWriter.WriteError.pdfAWithPassword) { try Self.write(PdfWriteOptions(pdfA: true, password: "x")) }
    }

    @Test func aCmykPictureIsRefusedForPdfA() {
        #expect(throws: PdfWriter.WriteError.cmykInPdfA) {
            try Self.write(PdfWriteOptions(pdfA: true), jpeg: TestJpeg.build(width: 100, height: 100, dnlHeight: nil, components: 4))
        }
    }

    @Test func aProtectedScanHidesItsTextAndTitle() throws {
        let pdf = try Self.write(PdfWriteOptions(password: "secret"), "Payroll March")
        #expect(pdf.hasPrefix("%PDF-1.7\n"))
        #expect(pdf.contains("/Filter /Standard /V 5 /R 6 /Length 256"))
        #expect(pdf.contains("/CFM /AESV3"))
        #expect(pdf.contains("/Extensions << /ADBE << /BaseVersion /1.7 /ExtensionLevel 8 >> >>"))
        #expect(!pdf.contains("Payroll"))
        #expect(!pdf.contains("Inkvolt Print")) // the producer string is encrypted too
        #expect(!pdf.contains("/Im0 Do")) // content streams are encrypted
        #expect(!pdf.contains("(Adobe)")) // and the font's strings
        #expect(Self.first(#"/ID \[<[0-9A-F]{32}>"#, pdf) != nil)
    }

    @Test func theUserKeyChecksThePasswordAndUnwrapsTheFileKeyThatDecryptsTheTitle() throws {
        let crypto = TestPdfCrypto()
        let pdf = try Self.write(PdfWriteOptions(password: "Contraseña"), "Payroll March")
        let u = Self.hex(pdf, "U"), ue = Self.hex(pdf, "UE")
        let pw = PdfEncryption.passwordBytes("Contraseña")
        // Algorithm 2.A: the password's hash with the validation salt is the first 32 bytes of /U.
        #expect(Array(u[0..<32]) == PdfEncryption.hash(pw, Array(u[32..<40]), [], crypto))
        #expect(Array(u[0..<32]) != PdfEncryption.hash(PdfEncryption.passwordBytes("wrong"), Array(u[32..<40]), [], crypto))
        let zero = [UInt8](repeating: 0, count: 16)
        let fileKey = try #require(TestPdfCrypto.aesCbcDecrypt(key: PdfEncryption.hash(pw, Array(u[40..<48]), [], crypto), iv: zero, ue, unpad: false))
        // /Perms decrypts with the file key to the permissions and "adb".
        let perms = try #require(TestPdfCrypto.aesCbcDecrypt(key: fileKey, iv: zero, Self.hex(pdf, "Perms"), unpad: false))
        #expect(String(decoding: perms[8..<12], as: UTF8.self) == "Tadb")
        #expect(Int32(bitPattern: UInt32(perms[0]) | UInt32(perms[1]) << 8 | UInt32(perms[2]) << 16 | UInt32(perms[3]) << 24) == -4)
        // The Info dictionary's title: IV, then AES-256-CBC.
        let info = try #require(Self.first("3 0 obj\n<< /Producer <([0-9A-F]+)> /Title <([0-9A-F]+)>", pdf))
        let title = Self.bytes(info[2])
        let plain = try #require(TestPdfCrypto.aesCbcDecrypt(key: fileKey, iv: Array(title[0..<16]), Array(title[16...]), unpad: true))
        let units = stride(from: 2, to: plain.count - 1, by: 2).map { UInt16(plain[$0]) << 8 | UInt16(plain[$0 + 1]) }
        #expect(String(decoding: units, as: UTF16.self) == "Payroll March")
    }

    @Test func theOwnerKeyIsBuiltOnTheUserKey() throws {
        let pdf = try Self.write(PdfWriteOptions(password: "pw"))
        let (u, o) = (Self.hex(pdf, "U"), Self.hex(pdf, "O"))
        #expect(o.count == 48)
        #expect(Array(o[0..<32]) == PdfEncryption.hash(PdfEncryption.passwordBytes("pw"), Array(o[32..<40]), u, TestPdfCrypto()))
    }

    @Test func eachFileGetsItsOwnKey() throws {
        #expect(Self.hex(try Self.write(PdfWriteOptions(password: "pw")), "UE") != Self.hex(try Self.write(PdfWriteOptions(password: "pw")), "UE"))
    }

    @Test func stringsInsideABodyAreEncryptedWhereverTheyAre() throws {
        let crypt = try PdfEncryption.create("pw")
        let body = try crypt.encryptStrings(#"<< /A (a \(nested (b)\) c\051) /B <48 49> /C [(x) /N 3] >>"#)
        #expect(Self.first(#"^<< /A <[0-9A-F]{96}> /B <[0-9A-F]{64}> /C \[<[0-9A-F]{64}> /N 3\] >>$"#, body) != nil)
    }

    @Test func aPasswordIsNormalizedAndCutAtACharacter() {
        #expect(PdfEncryption.passwordBytes("\u{FB01}le") == PdfEncryption.passwordBytes("file")) // NFKC: the ligature is two letters
        let cut = PdfEncryption.passwordBytes(String(repeating: "é", count: 100)) // 200 bytes of UTF-8
        #expect(cut.count == 126)
        #expect(String(decoding: cut, as: UTF8.self) == String(repeating: "é", count: 63))
        #expect(!PdfEncryption.usable(""))
        #expect(!PdfEncryption.usable(nil))
    }

    @Test func aNewPasswordIsTypedTwice() {
        #expect(PdfEncryption.checkNew("", "") == .empty)
        #expect(PdfEncryption.checkNew("abc", "abd") == .mismatch)
        #expect(PdfEncryption.checkNew("abc", "abc") == nil)
    }

    // MARK: The preset's options

    @Test func pdfAAndAPasswordExcludeEachOtherInTheEditor() {
        var p = ScanPreset()
        p.fileType = .searchablePdf
        let archived = ScanPresets.withPdfA(p, true)
        #expect(ScanPresets.savesPdfA(archived))
        let locked = ScanPresets.withPassword(archived, true)
        #expect(!locked.pdfA)
        #expect(ScanPresets.savesWithPassword(locked))
        #expect(!ScanPresets.withPdfA(locked, true).password)
        // Both on (a hand-edited file): the password wins, and PDF/A isn't claimed.
        var both = p
        (both.pdfA, both.password) = (true, true)
        #expect(!ScanPresets.savesPdfA(both))
    }

    @Test func onlyAPdfGetsPdfAOrAPassword() {
        for type in [PresetFileType.jpeg, .word, .text] {
            var p = ScanPreset()
            (p.fileType, p.pdfA) = (type, true)
            #expect(!ScanPresets.savesPdfA(p))
            (p.pdfA, p.password) = (false, true)
            #expect(!ScanPresets.savesWithPassword(p))
        }
        var pdf = ScanPreset()
        (pdf.fileType, pdf.pdfA) = (.pdf, true)
        #expect(ScanPresets.savesPdfA(pdf))
    }

    @Test func writeOptionsFollowThePreset() throws {
        func preset(pdfA: Bool = false, password: Bool = false, type: PresetFileType = .searchablePdf) -> ScanPreset {
            var p = ScanPreset()
            (p.pdfA, p.password, p.fileType) = (pdfA, password, type)
            return p
        }
        #expect(try ScanPresets.writeOptions(ScanPreset(), nil) == nil)
        #expect(try ScanPresets.writeOptions(preset(pdfA: true), nil)?.pdfA == true)
        #expect(try ScanPresets.writeOptions(preset(password: true), "pw")?.password == "pw")
        #expect(throws: PdfEncryption.Problem.noPassword) { try ScanPresets.writeOptions(preset(password: true), "") } // never saved open
        #expect(throws: PdfEncryption.Problem.noPassword) { try ScanPresets.writeOptions(preset(pdfA: true, password: true), nil) }
        #expect(try ScanPresets.writeOptions(preset(password: true, type: .jpeg), nil) == nil) // not a PDF: nothing to protect
    }

    @Test func aSavedPasswordGoesWithItsPresetOrItsOption() {
        func p(_ id: String, _ pw: Bool) -> ScanPreset {
            var p = ScanPreset()
            (p.id, p.name, p.password) = (id, id, pw)
            return p
        }
        let before = [p("a", true), p("b", true), p("c", true), p("d", false)]
        let after = [p("a", true), p("b", false), p("d", true)] // c deleted, b turned off
        #expect(ScanPresets.passwordsToForget(before, after) == ["b", "c"])
    }

    @Test func theSummarySaysPdfAOrPassword() {
        var p = ScanPreset()
        p.name = "x"
        #expect(!ScanPresetText.summary(p).contains("PDF/A"))
        p.pdfA = true
        #expect(ScanPresetText.summary(p).contains("PDF/A"))
        (p.pdfA, p.password) = (false, true)
        #expect(ScanPresetText.summary(p).contains(loc("a password to open")))
    }

    @Test func theNewOptionsSurviveAStoreAndRead() throws {
        var p = ScanPreset()
        (p.id, p.name, p.pdfA) = ("a", "A", true)
        let json = try JSONEncoder().encode(p)
        #expect(try JSONDecoder().decode(ScanPreset.self, from: json).pdfA)
        #expect(try !JSONDecoder().decode(ScanPreset.self, from: Data(#"{"Id":"a","Name":"A"}"#.utf8)).password)
        #expect(String(decoding: json, as: UTF8.self).contains(#""PdfA":true"#)) // the Windows app's field name
    }

    @Test func theTestCryptographyMatchesFips() {
        let c = TestPdfCrypto()
        let abc = Array("abc".utf8)
        #expect(PdfEncryption.hex(c.sha256(abc)) == "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")
        #expect(PdfEncryption.hex(c.sha384(abc)).lowercased()
            == "cb00753f45a35e8bb5a03d699ac65007272c32ab0eded1631a8b605a43ff5bed8086072ba1e7cc2358baeca134c825a7")
        #expect(PdfEncryption.hex(c.sha512(abc)).lowercased()
            == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f")
        let plain = Self.bytes("00112233445566778899AABBCCDDEEFF"), zero = [UInt8](repeating: 0, count: 16)
        let key16 = Array(0..<16).map(UInt8.init), key32 = Array(0..<32).map(UInt8.init)
        #expect(PdfEncryption.hex(c.aesCbcEncrypt(key: key16, iv: zero, plain, pad: false)) == "69C4E0D86A7B0430D8CDB78070B4C55A") // FIPS 197 C.1
        #expect(PdfEncryption.hex(c.aesCbcEncrypt(key: key32, iv: zero, plain, pad: false)) == "8EA2B7CA516745BFEAFC49904B496089") // C.3
        let padded = c.aesCbcEncrypt(key: key32, iv: plain, Array("Payroll".utf8), pad: true)
        #expect(padded.count == 16)
        #expect(TestPdfCrypto.aesCbcDecrypt(key: key32, iv: plain, padded, unpad: true) == Array("Payroll".utf8))
    }

    // MARK: Reading the file

    private static let created = Date(timeIntervalSince1970: 1_795_357_805) // 2026-11-22 14:30:05 UTC

    /// The first match's groups (0 the whole match), or nil.
    private static func first(_ pattern: String, _ text: String) -> [String]? {
        let regex = try! NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        let ns = text as NSString
        guard let m = regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }

    private static func hex(_ pdf: String, _ key: String) -> [UInt8] { bytes(first("/\(key) <([0-9A-F]+)>", pdf)?[1] ?? "") }

    private static func bytes(_ hex: String) -> [UInt8] {
        let digits = Array(hex.utf8)
        return stride(from: 0, to: digits.count - 1, by: 2).map { UInt8(String(decoding: digits[$0...$0 + 1], as: UTF8.self), radix: 16)! }
    }
}
