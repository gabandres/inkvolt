import Darwin
import Foundation
import Testing
@testable import PdfCore

/// Ported from ConversionTests.cs (same names). The Mac's paths are its own, and the mark of the web is its quarantine
/// attribute, read from a real file; the rest is the Mac's own: WebCaptureRules, the header and footer.
@Suite struct ConversionTests {
    @Test(arguments: [("/a/letter.docx", OfficeApp.word), ("/a/OLD.DOC", .word), ("/a/notes.rtf", .word), ("/a/notes.odt", .word),
                      ("/a/budget.xlsx", .excel), ("/a/budget.xlsm", .excel), ("/a/deck.pptx", .powerPoint), ("/a/show.ppsx", .powerPoint)])
    func officeFilesGoToTheirApp(path: String, app: OfficeApp) {
        #expect(OfficeFiles.appFor(path) == app)
    }

    @Test(arguments: ["/a/file.pdf", "/a/page.html", "/a/data.csv", "/a/docx"])
    func otherFilesHaveNoOfficeApp(path: String) {
        #expect(OfficeFiles.appFor(path) == nil)
    }

    @Test func encryptedOfficeFilesAreToldApart() {
        // An Office Open XML file is a ZIP; protected with a password it becomes an OLE compound file.
        let cfb: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0]
        let zip: [UInt8] = [UInt8(ascii: "P"), UInt8(ascii: "K"), 3, 4, 0, 0]
        #expect(OfficeFiles.isEncryptedOpenXml(cfb, "a.docx"))
        #expect(OfficeFiles.isEncryptedOpenXml(cfb, "a.XLSX"))
        #expect(!OfficeFiles.isEncryptedOpenXml(zip, "a.docx"))
        #expect(!OfficeFiles.isEncryptedOpenXml(cfb, "a.doc")) // the old binary formats are always compound files
        #expect(!OfficeFiles.isEncryptedOpenXml([1, 2], "a.pptx"))
    }

    @Test func openFilterListsEveryExtension() {
        let all = OfficeFiles.panelExtensions(OfficeApp.allCases)
        for app in OfficeApp.allCases {
            for ext in OfficeFiles.extensions(app) { #expect(all.contains(String(ext.dropFirst()))) }
        }
        #expect(!OfficeFiles.panelExtensions([.word]).contains("pptx"))
        #expect(OfficeFiles.panelExtensions([]).isEmpty)
    }

    @Test(arguments: [("example.com", "https://example.com/"),
                      ("  https://example.com/a?b=1#c ", "https://example.com/a?b=1#c"),
                      ("http://192.0.2.10:8080/status", "http://192.0.2.10:8080/status"),
                      ("www.example.org/path page", "https://www.example.org/path%20page"),
                      // The Mac's own: what .NET's Uri does by itself.
                      ("EXAMPLE.com/Path", "https://example.com/Path"),
                      ("https://example.com?q=a b", "https://example.com/?q=a%20b"),
                      ("https://example.com/100%25/50%", "https://example.com/100%25/50%25"),
                      ("http://[2001:db8::1]:8080/x", "http://[2001:db8::1]:8080/x"),
                      ("münchen.example/ä", "https://xn--mnchen-3ya.example/%C3%A4")])
    func webAddressesAreNormalized(typed: String, expected: String) {
        let (url, error) = WebFiles.parseAddress(typed)
        #expect(error == nil)
        #expect(url?.absoluteString == expected)
    }

    @Test(arguments: ["", "javascript:alert(1)", "file:///C:/Windows/win.ini", "ftp://example.com/x", "data:text/html,hi", "not a host", "https://",
                      // The Mac's own.
                      "https://user:secret@example.com/", "https://example.com\\@evil.example/", "http://example.com:99999/", "http://example.com:x/",
                      "https://exa mple.com/", "https://example.com/a\nb", "JAVASCRIPT:alert(1)", "http://[not-v6]/", "http://../x", "file:/etc/passwd"])
    func onlyWebAddressesAreTaken(typed: String) {
        let (url, error) = WebFiles.parseAddress(typed)
        #expect(url == nil)
        #expect(error?.isEmpty == false)
    }

    @Test func webFilesAreHtmlAndMht() {
        #expect(WebFiles.isWebFile("/a/page.html"))
        #expect(WebFiles.isWebFile("/a/page.HTM"))
        #expect(WebFiles.isWebFile("/a/saved.mht"))
        #expect(WebFiles.isWebFile("/a/saved.mhtml"))
        #expect(!WebFiles.isWebFile("/a/page.pdf"))
    }

    @Test func printOptionsBecomeInches() {
        let letter = WebPdfOptions()
        #expect(letter.pageInches == (8.5, 11))
        #expect(letter.marginInches == 0.4)
        let a4 = WebPdfOptions(paper: .a4, landscape: true, margins: WebMargins.none)
        #expect(a4.pageInches == (11.69, 8.27))
        #expect(a4.marginInches == 0)
        #expect(WebPdfOptions(margins: .wide).marginInches == 1)
        #expect(WebPdfOptions(paper: .legal).pageInches == (8.5, 14))
    }

    @Test(arguments: [("https://example.com/", "example.com.pdf"),
                      ("https://www.example.com/news/2026/story.html?id=3", "www.example.com - story.pdf"),
                      ("https://example.com/docs/", "example.com - docs.pdf"),
                      ("http://192.0.2.10:8080/a:b", "192.0.2.10 - a_b.pdf"),
                      // The Mac's own: a name from a page can't reach another folder.
                      ("https://example.com/..%2F..%2Fetc%2Fpasswd", "example.com - .._.._etc_passwd.pdf")])
    func webPagesGetAFileName(address: String, name: String) throws {
        #expect(WebFiles.pdfName(try #require(URL(string: address))) == name)
    }

    @Test func theMarkOfTheWebIsRead() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-mark-\(UUID().uuidString).docx")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(!OfficeFiles.isFromInternet(file.path))
        func mark(_ text: String) {
            #expect(setxattr(file.path, "com.apple.quarantine", text, text.utf8.count, 0, 0) == 0)
        }
        mark("0083;65a1b2c3;Safari;12345678-ABCD")
        #expect(OfficeFiles.isFromInternet(file.path))
        mark("0086;65a1b2c3;TextEdit;") // a sandboxed app's own file
        #expect(!OfficeFiles.isFromInternet(file.path))
        mark("not hex")
        #expect(OfficeFiles.isFromInternet(file.path))
        #expect(!OfficeFiles.isFromInternet(file.path + ".missing"))
    }

    @Test func convertedFilesKeepTheirName() {
        #expect(OfficeFiles.pdfName("/a/Quarterly report.docx") == "Quarterly report.pdf")
    }

    // MARK: The Mac's own

    @Test func theWebPageBoxTakesASavedPageOrAnAddress() {
        let exists: (String) -> Bool = { $0 == "/a/page.html" || $0 == "/a/notes.txt" }
        #expect(WebFiles.parseSource(" \"/a/page.html\" ", fileExists: exists).url?.path == "/a/page.html")
        #expect(WebFiles.parseSource("/a/gone.html", fileExists: exists).error == "That file wasn't found.")
        #expect(WebFiles.parseSource("/a/notes.txt", fileExists: exists).url == nil)
        #expect(WebFiles.parseSource("example.com", fileExists: exists).url?.absoluteString == "https://example.com/")
        #expect(WebFiles.parseSource("", fileExists: exists).url == nil)
    }

    @Test func aSavedPageRunsNoScriptsAndAWebPageDoes() throws {
        #expect(!WebCaptureRules(source: URL(fileURLWithPath: "/a/page.html")).runsPageScripts)
        #expect(WebCaptureRules(source: try #require(URL(string: "https://example.com/"))).runsPageScripts)
    }

    @Test func aWebPageStaysOnTheWeb() throws {
        let rules = WebCaptureRules(source: try #require(URL(string: "https://example.com/")))
        func allowed(_ text: String, main: Bool) -> Bool { rules.allowsNavigation(to: URL(string: text), mainFrame: main) }
        #expect(allowed("https://example.com/next", main: true))
        #expect(allowed("http://other.example/", main: true))
        #expect(allowed("https://ads.example/frame", main: false))
        #expect(allowed("about:blank", main: false))
        #expect(!allowed("file:///etc/passwd", main: true))
        #expect(!allowed("file:///etc/passwd", main: false))
        #expect(!allowed("about:blank", main: true))
        #expect(!allowed("zoommtg://join", main: true))
        #expect(!allowed("tel:123", main: false))
        #expect(!rules.allowsNavigation(to: nil, mainFrame: true))
    }

    @Test func aSavedPageStaysItself() {
        let rules = WebCaptureRules(source: URL(fileURLWithPath: "/a/page.html"))
        func allowed(_ text: String, main: Bool) -> Bool { rules.allowsNavigation(to: URL(string: text), mainFrame: main) }
        #expect(allowed("file:///a/page.html", main: true))
        #expect(allowed("file:///a/page.html#part", main: true))
        #expect(allowed("file:///a/page_files/frame.html", main: false))
        #expect(!allowed("file:///a/other.html", main: true))
        #expect(!allowed("https://example.com/", main: true)) // a redirect in a saved page
        #expect(!allowed("https://ads.example/frame", main: false))
        #expect(!allowed("zoommtg://join", main: false))
    }

    @Test func loadFailuresAreSaidInWords() {
        let d = NSURLErrorDomain
        #expect(WebCaptureRules.describe(domain: d, code: NSURLErrorCannotFindHost).hasPrefix("The site wasn't found."))
        #expect(WebCaptureRules.describe(domain: d, code: NSURLErrorNotConnectedToInternet).hasPrefix("The site couldn't be reached."))
        #expect(WebCaptureRules.describe(domain: d, code: NSURLErrorTimedOut) == "The site took too long to answer.")
        #expect(WebCaptureRules.describe(domain: d, code: NSURLErrorServerCertificateUntrusted).contains("certificate"))
        #expect(WebCaptureRules.describe(domain: d, code: NSURLErrorNetworkConnectionLost) == "The connection was interrupted.")
        #expect(WebCaptureRules.describe(domain: d, code: 12345).contains("12345"))
        #expect(WebCaptureRules.describe(domain: "Other", code: 7).contains("Other"))
        #expect(WebCaptureRules.describe(httpStatus: 404).contains("404"))
        #expect(WebCaptureRules.isInterruption(domain: d, code: NSURLErrorCancelled))
        #expect(WebCaptureRules.isInterruption(domain: "WebKitErrorDomain", code: 102))
        #expect(!WebCaptureRules.isInterruption(domain: d, code: NSURLErrorTimedOut))
    }

    @Test func theHeaderAndFooterSayWhatEdgePrints() throws {
        let long = String(repeating: "t", count: 200)
        let options = WebPdfOptions(headerAndFooter: true)
        let o = try #require(options.headerFooter(title: "A\ntitle " + long, address: "https://example.com/"))
        #expect(o.headerLeft == "<<date>>")
        #expect(o.headerCenter.hasPrefix("A title "))
        #expect(!o.headerCenter.contains("\n"))
        #expect(o.headerCenter.count == 61)
        #expect(o.footerLeft == "https://example.com/")
        #expect(o.footerRight == "<<page>>/<<pages>>")
        #expect(WebPdfOptions().headerFooter(title: "t", address: "a") == nil) // not asked for
        #expect(WebPdfOptions(margins: WebMargins.none, headerAndFooter: true).headerFooter(title: "t", address: "a") == nil) // nowhere to put it
    }
}
