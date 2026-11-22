using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>The Reflow view (roadmap 4.16): one readable column, its look, links, the page kept, and what runs while it shows.</summary>
public class ReflowTests
{
    private static readonly ReflowLook Plain = new(TextScale: 1, Zoom: 1, DarkPages: false);

    [Fact]
    public void TheDocumentBecomesOneColumnWithEachPageMarked()
    {
        var doc = Reflow.Make(ExportTestPdf.Make(), InputFileTypes.PDF, null, "Sample");
        Assert.True(doc.HasContent);
        Assert.Equal(2, doc.Pages);
        Assert.Contains("<div id=\"page-1\">", doc.Html);
        Assert.Contains("<div id=\"page-2\">", doc.Html);
        Assert.Contains("Inkvolt keeps every page on this computer.", doc.Html);
        Assert.Contains("default-src 'none'", doc.Html); // the writer's policy: no script, no request
        Assert.DoesNotContain("<script", doc.Html);
    }

    [Fact]
    public void APageWithNothingOnItHasNothingToReflow()
    {
        using var pdf = new PdfDocument();
        pdf.AddPage();
        using var ms = new MemoryStream();
        pdf.Save(ms);
        var doc = Reflow.Make(ms.ToArray(), InputFileTypes.PDF, null, null);
        Assert.False(doc.HasContent);
        Assert.Equal(1, doc.Pages);
    }

    [Fact]
    public void TheLookGoesAfterTheWritersOwnStyle()
    {
        var html = Reflow.Style("<html><head><style>body{}</style></head><body></body></html>", Plain);
        var mine = html.IndexOf($"<style id=\"{Reflow.StyleId}\">", StringComparison.Ordinal);
        Assert.True(mine > html.IndexOf("<style>body{}", StringComparison.Ordinal));
        Assert.True(mine < html.IndexOf("</head>", StringComparison.Ordinal));
    }

    [Fact]
    public void TextSizeFollowsWindowsTextSizeAndTheZoom()
    {
        Assert.Contains("font-size:112.5%", Reflow.Css(Plain));
        Assert.Contains("font-size:168.8%", Reflow.Css(Plain with { TextScale = 1.5 }));
        Assert.Contains("font-size:337.5%", Reflow.Css(Plain with { TextScale = 1.5, Zoom = 2 }));
        // Out of range: clamped to what Windows offers and the zoom steps.
        Assert.Contains("font-size:56.3%", Reflow.Css(Plain with { TextScale = 0.2, Zoom = 0.1 }));
    }

    [Fact]
    public void DarkPagesMakeLightTextOnDark()
    {
        var dark = Reflow.Css(Plain with { DarkPages = true });
        Assert.Contains("background:#1e1e1e", dark);
        Assert.Contains("color-scheme:dark", dark);
        Assert.Contains("img{filter:brightness(.88)}", dark);
        var light = Reflow.Css(Plain);
        Assert.Contains("background:#ffffff", light);
        Assert.DoesNotContain("filter", light);
    }

    [Fact]
    public void TheRestyleScriptCarriesTheStyleSheetSafely()
    {
        var script = Reflow.RestyleScript(Plain with { DarkPages = true });
        Assert.Contains($"getElementById('{Reflow.StyleId}')", script);
        Assert.Contains("background:#1e1e1e", script);
        Assert.DoesNotContain("</", script);
    }

    [Fact]
    public void ZoomMovesOneStepAndStopsAtTheEnds()
    {
        Assert.Equal(1.1, Reflow.ZoomStep(1, 1));
        Assert.Equal(0.9, Reflow.ZoomStep(1, -1));
        Assert.Equal(3, Reflow.ZoomStep(3, 1));
        Assert.Equal(0.5, Reflow.ZoomStep(0.5, -1));
        // Between two steps: the next step that way.
        Assert.Equal(1.25, Reflow.ZoomStep(1.2, 1));
        Assert.Equal(1.1, Reflow.ZoomStep(1.2, -1));
        Assert.Equal(1.5, Reflow.ZoomStep(1.2, 2));
    }

    [Fact]
    public void PagesAreNamedFromOne()
    {
        Assert.Equal("page-1", Reflow.Anchor(0));
        Assert.Equal(2, Reflow.PageOf("page-3", 5));
        Assert.Null(Reflow.PageOf("page-6", 5));
        Assert.Null(Reflow.PageOf("page-0", 5));
        Assert.Null(Reflow.PageOf("page-+1", 5));
        Assert.Null(Reflow.PageOf("header", 5));
        Assert.Null(Reflow.PageOf(null, 5));
        Assert.Contains("getElementById('page-4')", Reflow.ScrollScript(3));
    }

    [Fact]
    public void LinksStayInTheDocumentOrLeaveForTheBrowser()
    {
        Assert.Equal(new ReflowLink(ReflowLinkKind.InDocument, null, 2), Reflow.Follow(Reflow.Address + "#page-3", 4));
        Assert.Equal(ReflowLinkKind.InDocument, Reflow.Follow(Reflow.Address, 4).Kind);
        var web = Reflow.Follow("https://example.com/a?b=1", 4);
        Assert.Equal(ReflowLinkKind.External, web.Kind);
        Assert.Equal("https://example.com/a?b=1", web.Address);
        Assert.Equal(ReflowLinkKind.External, Reflow.Follow("mailto:someone@example.com", 4).Kind);
        foreach (var refused in new[] { "javascript:alert(1)", "file:///C:/Windows/win.ini", "https://reflow.inkvolt.invalid/other.html", "not a uri", "ms-settings:" })
            Assert.Equal(ReflowLinkKind.Blocked, Reflow.Follow(refused, 4).Kind);
    }

    [Fact]
    public void OnlyCommandsThatDontChangeTheDocumentRun()
    {
        foreach (var runs in new[] { "Reflow", "Save", "Print", "ExportWord", "ZoomIn", "NextPage", "GoToPage", "CloseDoc" })
            Assert.True(Reflow.Runs(runs), runs);
        foreach (var refused in new[] { "Highlight", "AddNote", "DeletePages", "EditContent", "PrepareForm", "Undo", "Redo", "Find", "Copy", "SelectAll", "ToolSelect", "SplitVertical" })
            Assert.False(Reflow.Runs(refused), refused);
    }

    // ── The page kept ──

    [Fact]
    public void ReflowOpensAtThePageTheReaderWasOn()
    {
        var position = new ReflowPosition(10);
        Assert.Equal(4, position.Enter(4));
        Assert.Equal(9, position.Enter(40)); // clamped
        Assert.Equal(9, position.Leave());
    }

    [Fact]
    public void ScrollingMovesThePageBoxOnlyWhenThePageChanges()
    {
        var position = new ReflowPosition(10);
        position.Enter(2);
        Assert.Null(position.Scrolled(2, 0));
        Assert.Null(position.Scrolled(null, 0));
        Assert.Null(position.Scrolled(12, 0)); // not a page
        Assert.Equal(5, position.Scrolled(5, 0));
        // The page view, moved there, reports page 5: no move back.
        Assert.Null(position.ViewerMoved(5, 10));
        Assert.Equal(5, position.Leave());
    }

    [Fact]
    public void ThePageViewSettlingAfterAMoveDoesntJumpTheReader()
    {
        var position = new ReflowPosition(10);
        position.Enter(0);
        Assert.Equal(8, position.Scrolled(8, 1000)); // the reader scrolls near the end
        // The page view, sent to page 9, passes through pages 7 and 8 and lands on 7 (the last pages fit on screen).
        Assert.Null(position.ViewerMoved(7, 1100));
        Assert.Null(position.ViewerMoved(6, 1000 + ReflowPosition.SettleMs - 1));
        Assert.Equal(8, position.Page);
        // Later, the page box: followed.
        Assert.Equal(3, position.ViewerMoved(3, 1000 + ReflowPosition.SettleMs));
    }

    [Fact]
    public void ThePageViewLaidOutAgainDoesntJumpTheReader()
    {
        var position = new ReflowPosition(10);
        position.Enter(4);
        position.ViewerRelaid(5000); // the window was resized under the view
        Assert.Null(position.ViewerMoved(2, 5200));
        Assert.Equal(4, position.Page);
        Assert.Equal(2, position.ViewerMoved(2, 5000 + ReflowPosition.SettleMs));
    }

    [Fact]
    public void ThePageBoxScrollsTheView()
    {
        var position = new ReflowPosition(10);
        position.Enter(0);
        Assert.Equal(7, position.ViewerMoved(7, 0));
        Assert.Null(position.Scrolled(7, 10)); // the view, scrolled there, reports page 7: no move back
        Assert.Equal(7, position.Leave());
    }
}
