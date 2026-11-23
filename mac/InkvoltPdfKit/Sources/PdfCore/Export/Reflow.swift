import Foundation

// Ported from pdf/src/InkvoltPdf.Core/Reflow.cs (roadmap 4.16, the Reflow view).

/// How the Reflow view looks: the text size (Windows follows its Text size; the Mac has none for apps, so 1), the view's
/// own zoom, and Dark pages.
public struct ReflowLook: Equatable, Sendable {
    public var textScale: Double
    public var zoom: Double
    public var darkPages: Bool

    public init(textScale: Double, zoom: Double, darkPages: Bool) {
        self.textScale = textScale
        self.zoom = zoom
        self.darkPages = darkPages
    }
}

/// A document as one column (`Reflow.make`): the page, the pages it has, and whether it holds anything to read
/// (`hasContent` false: no page has text or pictures, a scan never recognized; there is nothing to reflow).
public struct ReflowDocument: Sendable {
    public let html: String
    public let pages: Int
    public let hasContent: Bool
}

/// Where a link clicked in the Reflow view goes (`Reflow.follow`).
public enum ReflowLinkKind: Sendable {
    /// A place in the document itself ("#page-3"): the view scrolls there.
    case inDocument
    /// A web or mail address: it opens in the user's browser or mail app, never inside the view.
    case external
    /// Anything else (a file, a script, another scheme): nothing happens.
    case blocked
}

public struct ReflowLink: Equatable, Sendable {
    public let kind: ReflowLinkKind
    public let address: String?
    public let page: Int

    public init(_ kind: ReflowLinkKind, address: String? = nil, page: Int = -1) {
        self.kind = kind
        self.address = address
        self.page = page
    }
}

/// The Reflow view (roadmap 4.16): the document's text as one readable column, for small screens and low vision. It is
/// `DocumentExport`'s HTML (`HtmlWriter`: headings, paragraphs, lists, tables and pictures in reading order, no script,
/// no request, a Content-Security-Policy), shown at `address` with a look of its own on top (`style`): the text size
/// follows the view's zoom, and Dark pages make it light on dark. It is read-only: only the commands in `runs` (on the
/// Mac, the menu actions in `runsAction`) work while it shows. Each exported page is a `div id="page-N"`, so the page in
/// view is known (`topPageScript`) and kept by `ReflowPosition` when switching between Pages and Reflow.
public enum Reflow {
    /// Where the view's page is shown (a name under .invalid never resolves: nothing can be fetched from it).
    public static let address = "https://reflow.inkvolt.invalid/document.html"

    /// The id of the style element `style` writes, which `restyleScript` replaces.
    public static let styleId = "inkvolt-look"

    /// The view's zoom steps (Zoom In and Zoom Out move one step; Actual Size is 1).
    public static let zooms: [Double] = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// `data` as one column, its pictures in it, opened with `password`. A page that can't be read is left out, as Export
    /// leaves it.
    /// - Throws: `CancellationError` when `cancel` fires; the engine's error when the document can't be opened.
    public static func make(_ data: [UInt8], password: String?, title: String?, cancel: CancelToken? = nil) throws -> ReflowDocument {
        let engine = try PdfEngine.open(data, password: password)
        defer { engine.close() }
        let output = MemorySink()
        var options = ExportOptions()
        options.title = title
        options.source = data
        options.sourcePassword = password
        let report = try DocumentExport.export(engine, .html, to: output, options: options, cancel: cancel)
        return ReflowDocument(html: String(decoding: output.bytes, as: UTF8.self), pages: engine.pageCount, hasContent: report.saved)
    }

    /// The look's style sheet: text size, colors (Dark pages: light text on dark), links, tables and pictures.
    public static func css(_ look: ReflowLook) -> String {
        let raw = 112.5 * clamp(look.textScale, 1, 2.25) * clamp(look.zoom, zooms[0], zooms[zooms.count - 1])
        let percent = (raw * 10).rounded(.toNearestOrAwayFromZero) / 10
        let size = percent == percent.rounded() ? String(Int(percent)) : String(percent)
        let colors = look.darkPages
            ? (paper: "#1e1e1e", ink: "#e6e6e6", link: "#8ab4f8", quiet: "#a8a8a8", rule: "#5c5c5c")
            : (paper: "#ffffff", ink: "#1b1b1b", link: "#0b57d0", quiet: "#5c5c5c", rule: "#8a8a8a")
        var css = "html{font-size:\(size)%;color-scheme:\(look.darkPages ? "dark" : "light")}"
        css += "body{background:\(colors.paper);color:\(colors.ink)}a{color:\(colors.link)}header,footer{color:\(colors.quiet)}"
        css += "table.ruled td,table.ruled th{border-color:\(colors.rule)}"
        if look.darkPages { css += "img{filter:brightness(.88)}" }
        return css
    }

    /// `html` (`ReflowDocument.html`) with `look`'s style sheet, after the writer's own.
    public static func style(_ html: String, _ look: ReflowLook) -> String {
        let tag = "<style id=\"\(styleId)\">\(css(look))</style>"
        guard let head = html.range(of: "</head>") else { return tag + html }
        return html.replacingCharacters(in: head.lowerBound..<head.lowerBound, with: tag + "\n")
    }

    /// A script that puts `look` in place in the page as shown, keeping where the reader is.
    public static func restyleScript(_ look: ReflowLook) -> String {
        "(function(){var s=document.getElementById('\(styleId)');if(s)s.textContent=\(js(css(look)));})()"
    }

    /// The zoom `steps` steps from `zoom` (Zoom In: +1, Zoom Out: -1), within `zooms`; from between two steps, the first
    /// step is the next one that way.
    public static func zoomStep(_ zoom: Double, _ steps: Int) -> Double {
        let same = 0.001
        let last = zooms.count - 1
        if steps == 0 { return clamp(zoom, zooms[0], zooms[last]) }
        if steps > 0 {
            let at = zooms.firstIndex { $0 > zoom + same } ?? last
            return zooms[min(max(at + steps - 1, 0), last)]
        }
        let at = zooms.lastIndex { $0 < zoom - same } ?? 0
        return zooms[min(max(at + steps + 1, 0), last)]
    }

    /// The element id of page `page` (0-based) in the view.
    public static func anchor(_ page: Int) -> String { "page-\(page + 1)" }

    /// The page (0-based) an element id names, or nil when it names none of `pages`.
    public static func pageOf(_ anchor: String?, _ pages: Int) -> Int? {
        guard let anchor, anchor.hasPrefix("page-") else { return nil }
        let digits = anchor.dropFirst(5)
        // Digits only, as .NET's NumberStyles.None: no sign, no space.
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(digits), n >= 1, n <= pages
        else { return nil }
        return n - 1
    }

    /// A script that scrolls the view to page `page`'s start.
    public static func scrollScript(_ page: Int) -> String {
        "(function(){var e=document.getElementById('\(anchor(page))');if(e)e.scrollIntoView();})()"
    }

    /// A script that answers the id of the page at the top of the view: the first page whose end is below the top edge (a
    /// page with nothing on it has no height, so the page after it answers).
    public static let topPageScript =
        "(function(){var d=document.querySelectorAll('main > div[id^=\"page-\"]');for(var i=0;i<d.length;i++){if(d[i].getBoundingClientRect().bottom>4)return d[i].id;}return d.length?d[d.length-1].id:'';})()"

    /// Where a navigation to `uri` goes: a place in the document stays in the view, a web or mail address leaves it for the
    /// browser, everything else is refused.
    public static func follow(_ uri: String, _ pages: Int) -> ReflowLink {
        guard let u = URLComponents(string: uri), let scheme = u.scheme, !scheme.isEmpty else { return ReflowLink(.blocked) }
        let own = URLComponents(string: address)!
        let host = u.host?.lowercased()
        if scheme.lowercased() == own.scheme, host == own.host, u.port == nil, u.percentEncodedPath == own.percentEncodedPath, u.query == nil {
            let fragment = u.fragment.flatMap { $0.isEmpty ? nil : $0 }
            return ReflowLink(.inDocument, page: pageOf(fragment, pages) ?? -1)
        }
        if host == own.host { return ReflowLink(.blocked) } // the view shows one page
        return ExportLink.web(uri)?.uri.map { ReflowLink(.external, address: $0) } ?? ReflowLink(.blocked)
    }

    /// The commands that work while the Reflow view shows (Windows' names): it is read-only, so the ones that change the
    /// document, select on the page or need the page view don't (leave Reflow for them). Copy and Select All are the
    /// view's own.
    public static func runs(_ command: String) -> Bool { commands.contains(command) }

    private static let commands: Set<String> = [
        "Reflow", "Save", "SaveAs", "ShowInFolder", "CloseDoc", "CloseAll", "ReloadFromDisk", "Print", "PrintWithOptions",
        "ExportWord", "ExportExcel", "ExportText", "ExportPowerPoint", "ExportHtml", "ExportImages", "Properties",
        "ZoomIn", "ZoomOut", "ActualSize", "FirstPage", "PrevPage", "NextPage", "LastPage", "GoToPage", "Back", "Forward",
        "NavPane", "MoveToNewWindow", "Organize",
    ]

    /// The Mac's menu actions for `commands` (those it has: no Show in Folder, Close All, Export Images, Back or Forward
    /// there), with Page Setup (Windows' Print with options), Share and Dark Pages, which the Mac has as commands. Copy and
    /// Select All are the web view's own.
    public static let macActions: Set<String> = [
        "toggleReflow:", "saveDocument:", "saveDocumentAs:", "performClose:", "reloadFromDisk:", "printDocument:", "runPageLayout:",
        "exportWord:", "exportExcel:", "exportText:", "exportPowerPoint:", "exportHtml:", "showDocumentProperties:",
        "zoomIn:", "zoomOut:", "actualSize:", "firstPage:", "previousPage:", "nextPage:", "lastPage:", "goToPage:",
        "toggleSidebar:", "moveTabToNewWindow:", "toggleOrganizer:", "shareDocument:", "toggleDarkPages:",
    ]

    /// Whether the menu action `selector` ("zoomIn:") runs while the Reflow view shows.
    public static func runsAction(_ selector: String) -> Bool { macActions.contains(selector) }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

    private static func js(_ s: String) -> String {
        var out = "'"
        for c in s {
            switch c {
            case "\\": out += "\\\\"
            case "'": out += "\\'"
            case "<": out += "\\x3c"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(c)
            }
        }
        return out + "'"
    }
}

/// The page the Reflow view is at, kept in step with the page view's (roadmap 4.16): Reflow opens at the page the reader
/// was on, scrolling it moves the page box, the page box and the page commands scroll it, and leaving opens Pages at the
/// page it was at. Each side's report of a move the other caused comes back as no move, so they never chase each other:
/// the page view, sent to a page or laid out again (resized under the view), passes through other pages as it settles,
/// and what it reports for `settleMs` after is its settling, not the reader's.
public final class ReflowPosition {
    /// How long after the page view was sent somewhere, or laid out again, its page reports are ignored (ms).
    public static let settleMs: Int64 = 800

    private var quietUntil = Int64.min

    public let pages: Int

    /// The page in view (0-based).
    public private(set) var page = 0

    public init(_ pages: Int) { self.pages = max(1, pages) }

    /// Reflow opens with the page view at `viewerPage`: the page to scroll to.
    @discardableResult
    public func enter(_ viewerPage: Int) -> Int {
        page = min(max(viewerPage, 0), pages - 1)
        return page
    }

    /// The view reports the page at its top (nil: it couldn't tell) at `now` (ms): the page to send the page view to, or
    /// nil when it hasn't moved.
    public func scrolled(_ reflowPage: Int?, _ now: Int64) -> Int? {
        guard let p = reflowPage, p >= 0, p < pages, p != page else { return nil }
        quietUntil = now + Self.settleMs
        page = p
        return p
    }

    /// The page view was laid out again (resized, zoomed) at `now`: its page may change on its own.
    public func viewerRelaid(_ now: Int64) { quietUntil = max(quietUntil, now + Self.settleMs) }

    /// The page view moved to `viewerPage` at `now` (the page box, Next Page): the page to scroll the view to, or nil when
    /// it is there or the page view is still settling.
    public func viewerMoved(_ viewerPage: Int, _ now: Int64) -> Int? {
        if now < quietUntil { return nil }
        let p = min(max(viewerPage, 0), pages - 1)
        if p == page { return nil }
        page = p
        return p
    }

    /// Leaving Reflow: the page Pages opens at.
    public func leave() -> Int { page }
}
