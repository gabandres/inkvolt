import Foundation
import Testing
@testable import PdfCore

/// Ported from ReflowTests.cs: the Reflow view (roadmap 4.16): one readable column, its look, links, the page kept, and
/// what runs while it shows.
struct ReflowTests {
    private static let plain = ReflowLook(textScale: 1, zoom: 1, darkPages: false)

    @Test func TheDocumentBecomesOneColumnWithEachPageMarked() throws {
        let doc = try Reflow.make(ExportTestPdf.make(), password: nil, title: "Sample")
        #expect(doc.hasContent)
        #expect(doc.pages == 2)
        #expect(doc.html.contains("<div id=\"page-1\">"))
        #expect(doc.html.contains("<div id=\"page-2\">"))
        #expect(doc.html.contains("Inkvolt keeps every page on this computer."))
        #expect(doc.html.contains("default-src 'none'")) // the writer's policy: no script, no request
        #expect(!doc.html.contains("<script"))
    }

    @Test func APageWithNothingOnItHasNothingToReflow() throws {
        let doc = try Reflow.make(ExportTestPdf.blank(1), password: nil, title: nil)
        #expect(!doc.hasContent)
        #expect(doc.pages == 1)
    }

    @Test func TheLookGoesAfterTheWritersOwnStyle() throws {
        let html = Reflow.style("<html><head><style>body{}</style></head><body></body></html>", Self.plain)
        let mine = try #require(html.range(of: "<style id=\"\(Reflow.styleId)\">"))
        #expect(mine.lowerBound > html.range(of: "<style>body{}")!.lowerBound)
        #expect(mine.lowerBound < html.range(of: "</head>")!.lowerBound)
    }

    @Test func TextSizeFollowsWindowsTextSizeAndTheZoom() {
        #expect(Reflow.css(Self.plain).contains("font-size:112.5%"))
        #expect(Reflow.css(ReflowLook(textScale: 1.5, zoom: 1, darkPages: false)).contains("font-size:168.8%"))
        #expect(Reflow.css(ReflowLook(textScale: 1.5, zoom: 2, darkPages: false)).contains("font-size:337.5%"))
        // Out of range: clamped to what Windows offers and the zoom steps.
        #expect(Reflow.css(ReflowLook(textScale: 0.2, zoom: 0.1, darkPages: false)).contains("font-size:56.3%"))
    }

    @Test func DarkPagesMakeLightTextOnDark() {
        let dark = Reflow.css(ReflowLook(textScale: 1, zoom: 1, darkPages: true))
        #expect(dark.contains("background:#1e1e1e"))
        #expect(dark.contains("color-scheme:dark"))
        #expect(dark.contains("img{filter:brightness(.88)}"))
        let light = Reflow.css(Self.plain)
        #expect(light.contains("background:#ffffff"))
        #expect(!light.contains("filter"))
    }

    @Test func TheRestyleScriptCarriesTheStyleSheetSafely() {
        let script = Reflow.restyleScript(ReflowLook(textScale: 1, zoom: 1, darkPages: true))
        #expect(script.contains("getElementById('\(Reflow.styleId)')"))
        #expect(script.contains("background:#1e1e1e"))
        #expect(!script.contains("</"))
    }

    @Test func ZoomMovesOneStepAndStopsAtTheEnds() {
        #expect(Reflow.zoomStep(1, 1) == 1.1)
        #expect(Reflow.zoomStep(1, -1) == 0.9)
        #expect(Reflow.zoomStep(3, 1) == 3)
        #expect(Reflow.zoomStep(0.5, -1) == 0.5)
        // Between two steps: the next step that way.
        #expect(Reflow.zoomStep(1.2, 1) == 1.25)
        #expect(Reflow.zoomStep(1.2, -1) == 1.1)
        #expect(Reflow.zoomStep(1.2, 2) == 1.5)
    }

    @Test func PagesAreNamedFromOne() {
        #expect(Reflow.anchor(0) == "page-1")
        #expect(Reflow.pageOf("page-3", 5) == 2)
        #expect(Reflow.pageOf("page-6", 5) == nil)
        #expect(Reflow.pageOf("page-0", 5) == nil)
        #expect(Reflow.pageOf("page-+1", 5) == nil)
        #expect(Reflow.pageOf("header", 5) == nil)
        #expect(Reflow.pageOf(nil, 5) == nil)
        #expect(Reflow.scrollScript(3).contains("getElementById('page-4')"))
    }

    @Test func LinksStayInTheDocumentOrLeaveForTheBrowser() {
        #expect(Reflow.follow(Reflow.address + "#page-3", 4) == ReflowLink(.inDocument, page: 2))
        #expect(Reflow.follow(Reflow.address, 4).kind == .inDocument)
        let web = Reflow.follow("https://example.com/a?b=1", 4)
        #expect(web.kind == .external)
        #expect(web.address == "https://example.com/a?b=1")
        #expect(Reflow.follow("mailto:someone@example.com", 4).kind == .external)
        for refused in ["javascript:alert(1)", "file:///C:/Windows/win.ini", "https://reflow.inkvolt.invalid/other.html", "not a uri", "ms-settings:"] {
            #expect(Reflow.follow(refused, 4).kind == .blocked, "\(refused)")
        }
    }

    @Test func OnlyCommandsThatDontChangeTheDocumentRun() {
        for runs in ["Reflow", "Save", "Print", "ExportWord", "ZoomIn", "NextPage", "GoToPage", "CloseDoc"] {
            #expect(Reflow.runs(runs), "\(runs)")
        }
        for refused in ["Highlight", "AddNote", "DeletePages", "EditContent", "PrepareForm", "Undo", "Redo", "Find", "Copy", "SelectAll", "ToolSelect", "SplitVertical"] {
            #expect(!Reflow.runs(refused), "\(refused)")
        }
    }

    /// Mac only: the menu bar's actions that run while Reflow shows are the Windows commands' (`runs`), by selector;
    /// Copy and Select All are the web view's own, so they reach it through the responder chain.
    @Test func TheMacsMenuActionsFollowTheWindowsCommands() {
        for runs in ["toggleReflow:", "saveDocument:", "printDocument:", "exportWord:", "zoomIn:", "nextPage:", "goToPage:", "performClose:",
                     "moveTabToNewWindow:", "toggleSidebar:", "toggleOrganizer:", "toggleDarkPages:"] {
            #expect(Reflow.runsAction(runs), "\(runs)")
        }
        for refused in ["highlightText:", "deletePages:", "undo:", "redo:", "showFind:", "copy:", "selectAll:", "splitSideBySide:", "chooseTool:",
                        "fitWidth:", "singlePageMode:", "toggleReadAloud:"] {
            #expect(!Reflow.runsAction(refused), "\(refused)")
        }
        // Every Mac action listed is a command of the menu bar, or AppKit's own window item.
        let known = Set(DocumentCommands.all.map(\.command.action)).union(["moveTabToNewWindow:"])
        #expect(Reflow.macActions.subtracting(known).isEmpty, "\(Reflow.macActions.subtracting(known).sorted())")
    }

    // ── The page kept ──

    @Test func ReflowOpensAtThePageTheReaderWasOn() {
        let position = ReflowPosition(10)
        #expect(position.enter(4) == 4)
        #expect(position.enter(40) == 9) // clamped
        #expect(position.leave() == 9)
    }

    @Test func ScrollingMovesThePageBoxOnlyWhenThePageChanges() {
        let position = ReflowPosition(10)
        position.enter(2)
        #expect(position.scrolled(2, 0) == nil)
        #expect(position.scrolled(nil, 0) == nil)
        #expect(position.scrolled(12, 0) == nil) // not a page
        #expect(position.scrolled(5, 0) == 5)
        // The page view, moved there, reports page 5: no move back.
        #expect(position.viewerMoved(5, 10) == nil)
        #expect(position.leave() == 5)
    }

    @Test func ThePageViewSettlingAfterAMoveDoesntJumpTheReader() {
        let position = ReflowPosition(10)
        position.enter(0)
        #expect(position.scrolled(8, 1000) == 8) // the reader scrolls near the end
        // The page view, sent to page 9, passes through pages 7 and 8 and lands on 7 (the last pages fit on screen).
        #expect(position.viewerMoved(7, 1100) == nil)
        #expect(position.viewerMoved(6, 1000 + ReflowPosition.settleMs - 1) == nil)
        #expect(position.page == 8)
        // Later, the page box: followed.
        #expect(position.viewerMoved(3, 1000 + ReflowPosition.settleMs) == 3)
    }

    @Test func ThePageViewLaidOutAgainDoesntJumpTheReader() {
        let position = ReflowPosition(10)
        position.enter(4)
        position.viewerRelaid(5000) // the window was resized under the view
        #expect(position.viewerMoved(2, 5200) == nil)
        #expect(position.page == 4)
        #expect(position.viewerMoved(2, 5000 + ReflowPosition.settleMs) == 2)
    }

    @Test func ThePageBoxScrollsTheView() {
        let position = ReflowPosition(10)
        position.enter(0)
        #expect(position.viewerMoved(7, 0) == 7)
        #expect(position.scrolled(7, 10) == nil) // the view, scrolled there, reports page 7: no move back
        #expect(position.leave() == 7)
    }
}
