import Darwin
import Foundation

/// The kind of Office file: which of Microsoft's apps it belongs to (the Windows app's `OfficeApp`). On the Mac it picks
/// the words of a message; LibreOffice converts all three.
public enum OfficeApp: CaseIterable, Sendable { case word, excel, powerPoint }

/// Office files made into PDFs by an office app the user has installed (`OfficeConversion`): which kind a file is, the
/// extensions for the Open panel, names, the files that would stop to ask a password, and the mark macOS puts on a download.
public enum OfficeFiles {
    private static let word = [".docx", ".doc", ".docm", ".dotx", ".dot", ".rtf", ".odt"]
    private static let excel = [".xlsx", ".xls", ".xlsm", ".xlsb", ".ods"]
    private static let powerPoint = [".pptx", ".ppt", ".pptm", ".ppsx", ".pps", ".odp"]
    private static let openXml = [".docx", ".docm", ".dotx", ".xlsx", ".xlsm", ".xlsb", ".pptx", ".pptm", ".ppsx"]

    public static func extensions(_ app: OfficeApp) -> [String] {
        switch app {
        case .word: word
        case .excel: excel
        case .powerPoint: powerPoint
        }
    }

    private static func fileExtension(_ path: String) -> String {
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? "" : "." + ext.lowercased()
    }

    /// The kind of `path` (by extension), or nil when it isn't an Office file.
    public static func appFor(_ path: String) -> OfficeApp? {
        let ext = fileExtension(path)
        return OfficeApp.allCases.first { extensions($0).contains(ext) }
    }

    public static func appName(_ app: OfficeApp) -> String {
        switch app {
        case .word: "Microsoft Word"
        case .excel: "Microsoft Excel"
        case .powerPoint: "Microsoft PowerPoint"
        }
    }

    /// The extensions of `apps` without their dots, as an Open panel takes them (Windows: the filter's "*.docx;*.doc;…").
    public static func panelExtensions(_ apps: [OfficeApp]) -> [String] {
        apps.flatMap(extensions).map { String($0.dropFirst()) }
    }

    /// An Office Open XML file (normally a ZIP) stored as an OLE compound file: that is how Office saves one protected
    /// with a password (the package is encrypted inside). The converter could only fail on it.
    public static func isEncryptedOpenXml(_ head: [UInt8], _ path: String) -> Bool {
        openXml.contains(fileExtension(path)) && head.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
    }

    /// The mark macOS puts on a download (the Windows Zone.Identifier's counterpart): the flags that start the
    /// `com.apple.quarantine` attribute, in hex. Bit 0 says it was downloaded; a sandboxed app's own files carry the
    /// attribute without it. A mark that can't be read counts as a download.
    public static func quarantineMeansDownloaded(_ attribute: String) -> Bool {
        let flags = attribute.split(separator: ";", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        guard let value = UInt32(flags, radix: 16) else { return true }
        return value & 1 != 0
    }

    /// macOS marks the file as downloaded from the internet. Such a file needs the user's OK first: it could still fetch
    /// content from elsewhere, though the converter's links and macros are off.
    public static func isFromInternet(_ path: String) -> Bool {
        let name = "com.apple.quarantine"
        let size = getxattr(path, name, nil, 0, 0, 0)
        guard size > 0 else { return false } // no mark (or none readable: no attribute on this file system)
        var bytes = [UInt8](repeating: 0, count: size)
        let read = getxattr(path, name, &bytes, size, 0, 0)
        guard read > 0 else { return true }
        return quarantineMeansDownloaded(String(decoding: bytes[..<read], as: UTF8.self))
    }

    /// The PDF's name: the file's own name with .pdf.
    public static func pdfName(_ path: String) -> String {
        (((path as NSString).lastPathComponent as NSString).deletingPathExtension) + ".pdf"
    }
}

public enum WebPaper: String, CaseIterable, Sendable { case letter, a4, legal }

public enum WebMargins: String, CaseIterable, Sendable { case none, narrow, normal, wide }

/// How a web page is printed to PDF (in inches, as on Windows).
public struct WebPdfOptions: Equatable, Sendable {
    public var paper: WebPaper
    public var landscape: Bool
    public var margins: WebMargins
    /// Background colors and pictures (off: the page prints like a browser's default, on white).
    public var backgrounds: Bool
    /// A header and footer: title, address, date and page numbers.
    public var headerAndFooter: Bool

    public init(paper: WebPaper = .letter, landscape: Bool = false, margins: WebMargins = .normal, backgrounds: Bool = true, headerAndFooter: Bool = false) {
        self.paper = paper
        self.landscape = landscape
        self.margins = margins
        self.backgrounds = backgrounds
        self.headerAndFooter = headerAndFooter
    }

    public var pageInches: (width: Double, height: Double) {
        let size: (Double, Double)
        switch paper {
        case .a4: size = (8.27, 11.69)
        case .legal: size = (8.5, 14)
        case .letter: size = (8.5, 11)
        }
        return landscape ? (size.1, size.0) : size
    }

    public var marginInches: Double {
        switch margins {
        case .none: 0
        case .narrow: 0.25
        case .wide: 1
        case .normal: 0.4
        }
    }

    /// The header and footer a browser prints (Windows: Edge's own; WebKit has none, so they are written on afterwards):
    /// the date and title at the top, the address and page numbers at the bottom, in the margins. Nil when not asked
    /// for, or with no margins to put them in (Edge shows none there either).
    public func headerFooter(title: String, address: String, date: Date = Date()) -> HeaderFooterOptions? {
        guard headerAndFooter, marginInches > 0 else { return nil }
        func short(_ text: String, _ limit: Int) -> String {
            let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            return line.count > limit ? String(line.prefix(limit)) + "…" : line
        }
        var o = HeaderFooterOptions()
        o.headerLeft = "<<date>>"
        o.headerCenter = short(title, 60)
        o.footerLeft = short(address, 80)
        o.footerRight = "<<page>>/<<pages>>"
        o.fontSize = 8
        o.marginTop = 6
        o.marginBottom = 6
        o.marginLeft = 18
        o.marginRight = 18
        o.date = date
        return o
    }
}

/// Web pages and saved web files (HTML, MHT) made into PDFs with WebKit.
public enum WebFiles {
    public static let extensions = [".html", ".htm", ".mht", ".mhtml"]

    public static func isWebFile(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        return !ext.isEmpty && extensions.contains("." + ext.lowercased())
    }

    /// What the web page dialog's box holds: a saved page on this Mac (a full path, or `~/`), or a typed web address.
    public static func parseSource(_ text: String, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> (url: URL?, error: String?) {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard typed.hasPrefix("/") || typed.hasPrefix("~/") else { return parseAddress(typed) }
        let path = (typed as NSString).expandingTildeInPath
        guard fileExists(path) else { return (nil, "That file wasn't found.") }
        guard isWebFile(path) else { return (nil, "Choose a saved web page (.html or .mht).") }
        return (URL(fileURLWithPath: path), nil)
    }

    /// A typed web address: http or https (https is added when no scheme is typed), with a host. Anything else (file,
    /// javascript, data, ftp addresses) is refused: local files are chosen with Browse. Read by hand, not through
    /// Foundation's URL, which would percent-encode "not a host" into a host. An address with a name or password in it
    /// is refused too (.NET takes it): it can make one site look like another.
    public static func parseAddress(_ text: String) -> (url: URL?, error: String?) {
        let notAddress = "That isn't a web address."
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return (nil, "Type a web address, such as example.com.") }
        guard !typed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return (nil, notAddress) }
        let onlyWeb = "Only web addresses (http or https) can be opened here. For a file on this Mac, use Browse."
        let lower = typed.lowercased()
        if !typed.contains("://"), lower.hasPrefix("javascript:") || lower.hasPrefix("data:") || lower.hasPrefix("file:") { return (nil, onlyWeb) }
        let full = typed.contains("://") ? typed : "https://" + typed
        guard let mark = full.range(of: "://") else { return (nil, notAddress) }
        let scheme = full[..<mark.lowerBound].lowercased()
        guard let first = scheme.first, first.isASCII, first.isLetter,
              scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) else { return (nil, notAddress) }
        guard scheme == "http" || scheme == "https" else { return (nil, onlyWeb) }
        let rest = full[mark.upperBound...]
        let end = rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex
        let authority = String(rest[..<end])
        guard !authority.isEmpty else { return (nil, "That web address has no site name.") }
        guard !authority.contains("@") else { return (nil, "That web address has a name or password in it, which can't be used here.") }
        guard let site = site(authority) else { return (nil, notAddress) }
        var tail = encoded(String(rest[end...]))
        if !tail.hasPrefix("/") { tail = "/" + tail }
        guard let url = URL(string: "\(scheme)://\(site)\(tail)"), url.host != nil else { return (nil, notAddress) }
        return (url, nil)
    }

    /// "host[:port]" checked, with the host in lower case (and in its ASCII form when it is an international name).
    private static func site(_ authority: String) -> String? {
        var host = authority, port = ""
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]"), AiAddress(String(authority[...close]))?.isIPv4 == false else { return nil }
            host = String(authority[...close])
            port = String(authority[authority.index(after: close)...])
        } else {
            if let colon = authority.lastIndex(of: ":") {
                host = String(authority[..<colon])
                port = String(authority[colon...])
            }
            var labels = host.lowercased().split(separator: ".", omittingEmptySubsequences: false)
            if labels.last?.isEmpty == true, labels.count > 1 { labels.removeLast() } // the root's dot
            guard labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }) else { return nil }
            host = labels.joined(separator: ".")
            if !host.allSatisfy(\.isASCII) {
                var parts = URLComponents()
                parts.host = host
                guard let ascii = parts.encodedHost, !ascii.contains("%") else { return nil }
                host = ascii
            }
        }
        if port.isEmpty { return host }
        guard port.hasPrefix(":"), let number = Int(port.dropFirst()), (1...65535).contains(number), port.dropFirst().allSatisfy(\.isASCII) else { return nil }
        return host + port
    }

    /// The path, query and fragment with what a URL can't hold percent-encoded; what is encoded already stays as it is.
    private static func encoded(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var out = ""
        for (i, b) in bytes.enumerated() {
            let hex = { (c: UInt8) in (c >= 48 && c <= 57) || (c >= 65 && c <= 70) || (c >= 97 && c <= 102) }
            let isEscape = b == 37 && i + 2 < bytes.count && hex(bytes[i + 1]) && hex(bytes[i + 2])
            let plain = b > 32 && b < 127 && !"\"<>\\^`{|}%".utf8.contains(b)
            if plain || isEscape { out.unicodeScalars.append(UnicodeScalar(b)) } else { out += String(format: "%%%02X", b) }
        }
        return out
    }

    /// "example.com - story.pdf": the site, and the last part of the path when there is one.
    public static func pdfName(_ url: URL) -> String {
        let invalid = "<>:\"/\\|?*"
        func clean(_ text: String) -> String {
            String(text.map { $0.unicodeScalars.allSatisfy { $0.value >= 32 } && !invalid.contains($0) ? $0 : "_" })
        }
        let piece = url.path(percentEncoded: true).split(separator: "/").last.map(String.init) ?? ""
        var last = clean(piece.removingPercentEncoding ?? piece)
        if let dot = last.lastIndex(of: "."), dot != last.startIndex, last.distance(from: dot, to: last.endIndex) <= 6 { last = String(last[..<dot]) } // story.html: story
        let host = clean(url.host ?? "")
        var name = (last.isEmpty ? host : "\(host) - \(last)").trimmingCharacters(in: .whitespaces)
        if name.count > 100 { name = String(name.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return name + ".pdf"
    }
}

/// What a web page conversion lets the page do, and what its errors mean: the choices WebCapture in the app makes, here
/// so they are tested. A page from the web runs its scripts (most need them to show anything; so on Windows); a saved page
/// on this Mac doesn't (Windows runs them): it is whole already, and a file someone sent is untrusted. Either way the app's
/// own short scripts, which see only the document's state, run apart from the page's.
public struct WebCaptureRules: Sendable {
    public let source: URL

    /// How long a page may take to load, a script call into it may take, and printing it may take.
    public static let loadTimeout: TimeInterval = 60, scriptTimeout: TimeInterval = 10, printTimeout: TimeInterval = 120

    public init(source: URL) { self.source = source }

    public var isLocal: Bool { source.isFileURL }
    public var runsPageScripts: Bool { !isLocal }

    public var loadingText: String { isLocal ? "Opening the file…" : "Loading \(source.host ?? "the page")…" }

    /// Where the page may go. The main frame: a web page stays on the web, a saved page stays itself (its anchors). A
    /// frame inside it: the web and what a page makes itself, and for a web page nothing from this Mac; a saved page's
    /// frames stay local (what they would fetch from the web is mostly advertising). Other schemes never (they would
    /// ask another app to open).
    public func allowsNavigation(to url: URL?, mainFrame: Bool) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return false }
        let web = scheme == "http" || scheme == "https"
        if mainFrame {
            if !isLocal { return web }
            return scheme == "file" && url.standardizedFileURL.path == source.standardizedFileURL.path
        }
        if scheme == "about" || scheme == "blob" || scheme == "data" { return true }
        return isLocal ? scheme == "file" : web
    }

    /// A load cut short by another navigation of the page's own (a script or a redirect moving on), which isn't a failure.
    public static func isInterruption(domain: String, code: Int) -> Bool {
        (domain == NSURLErrorDomain && code == NSURLErrorCancelled) || (domain == "WebKitErrorDomain" && code == 102)
    }

    /// What to tell the user about a load that failed.
    public static func describe(domain: String, code: Int) -> String {
        guard domain == NSURLErrorDomain else { return "The page couldn't be loaded (\(domain) \(code))." }
        switch code {
        case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed: return "The site wasn't found. Check the address and the internet connection."
        case NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet, NSURLErrorInternationalRoamingOff, NSURLErrorDataNotAllowed:
            return "The site couldn't be reached. Check the internet connection."
        case NSURLErrorTimedOut: return "The site took too long to answer."
        case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasUnknownRoot,
             NSURLErrorServerCertificateNotYetValid, NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired:
            return "The site's security certificate isn't valid, so the page wasn't loaded."
        case NSURLErrorNetworkConnectionLost: return "The connection was interrupted."
        case NSURLErrorFileDoesNotExist: return "That file wasn't found."
        default: return "The page couldn't be loaded (\(code))."
        }
    }

    public static func describe(httpStatus: Int) -> String { "The site answered with an error (\(httpStatus))." }

    public static let notAPage = "The page didn't load (it was stopped or left for a download)."
    public static let busy = "The page stopped answering (its own scripts keep it busy), so it can't be printed."
    public static func lateLoad(_ seconds: TimeInterval) -> String { "The page didn't finish loading within \(Int(seconds)) seconds." }
    public static func latePrint(_ seconds: TimeInterval) -> String { "Printing the page didn't finish within \(Int(seconds)) seconds." }
    public static let notPrinted = "The page couldn't be printed to PDF."
}
