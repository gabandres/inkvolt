using System.Globalization;
using System.Text;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>How the Reflow view looks: Windows' Text size (as the app follows it), the view's own zoom, and Dark pages.</summary>
public readonly record struct ReflowLook(double TextScale, double Zoom, bool DarkPages);

/// <summary>A document as one column (<see cref="Reflow.Make"/>): the page, the pages it has, and whether it holds anything to read.</summary>
/// <param name="HasContent">False when no page has text or pictures (a scan never recognized): there is nothing to reflow.</param>
public sealed record ReflowDocument(string Html, int Pages, bool HasContent);

/// <summary>Where a link clicked in the Reflow view goes (<see cref="Reflow.Follow"/>).</summary>
public enum ReflowLinkKind
{
    /// <summary>A place in the document itself ("#page-3"): the view scrolls there.</summary>
    InDocument,
    /// <summary>A web or mail address: it opens in the user's browser or mail app, never inside the view.</summary>
    External,
    /// <summary>Anything else (a file, a script, another scheme): nothing happens.</summary>
    Blocked,
}

public readonly record struct ReflowLink(ReflowLinkKind Kind, string? Address = null, int Page = -1);

/// <summary>
/// The Reflow view (roadmap 4.16): the document's text as one readable column, for small screens and low vision. It is
/// <see cref="DocumentExport"/>'s HTML (<see cref="HtmlWriter"/>: headings, paragraphs, lists, tables and pictures in
/// reading order, no script, no request, a Content-Security-Policy), served at <see cref="Address"/> with a look of its
/// own on top (<see cref="Style"/>): the text size follows Windows' Text size and the view's zoom, and Dark pages make it
/// light on dark. It is read-only: only the commands in <see cref="Runs"/> work while it shows. Each exported page is a
/// <c>div id="page-N"</c>, so the page in view is known (<see cref="TopPageScript"/>) and kept by <see cref="ReflowPosition"/>
/// when switching between Pages and Reflow.
/// </summary>
public static class Reflow
{
    /// <summary>Where the view's page is served (a name under .invalid never resolves: nothing can be fetched from it).</summary>
    public const string Address = "https://reflow.inkvolt.invalid/document.html";

    /// <summary>The id of the style element <see cref="Style"/> writes, which <see cref="RestyleScript"/> replaces.</summary>
    public const string StyleId = "inkvolt-look";

    /// <summary>The view's zoom steps (Zoom In and Zoom Out move one step; Actual Size is 1).</summary>
    public static readonly IReadOnlyList<double> Zooms = [0.5, 0.67, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3];

    /// <summary>
    /// <paramref name="data"/> as one column, its pictures in it; <paramref name="type"/> and <paramref name="password"/>
    /// as the document was opened. A page that can't be read is left out, as Export leaves it.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    public static ReflowDocument Make(byte[] data, InputFileTypes type, string? password, string? title, CancellationToken cancel = default)
    {
        using var engine = PdfEngine.Open(data, type, password);
        using var output = new MemoryStream();
        var report = DocumentExport.Export(engine, ExportFormat.Html, output, new ExportOptions
        {
            Title = title,
            Source = type == InputFileTypes.PDF ? data : null,
            SourcePassword = password,
        }, cancel);
        return new ReflowDocument(Encoding.UTF8.GetString(output.ToArray()), engine.PageCount, report.Saved);
    }

    /// <summary>The look's style sheet: text size, colors (Dark pages: light text on dark), links, tables and pictures.</summary>
    public static string Css(ReflowLook look)
    {
        var percent = Math.Round(112.5 * Math.Clamp(look.TextScale, 1, 2.25) * Math.Clamp(look.Zoom, Zooms[0], Zooms[^1]), 1, MidpointRounding.AwayFromZero);
        var size = percent.ToString(CultureInfo.InvariantCulture);
        var (paper, ink, link, quiet, rule) = look.DarkPages
            ? ("#1e1e1e", "#e6e6e6", "#8ab4f8", "#a8a8a8", "#5c5c5c")
            : ("#ffffff", "#1b1b1b", "#0b57d0", "#5c5c5c", "#8a8a8a");
        return $"html{{font-size:{size}%;color-scheme:{(look.DarkPages ? "dark" : "light")}}}" +
               $"body{{background:{paper};color:{ink}}}a{{color:{link}}}header,footer{{color:{quiet}}}" +
               $"table.ruled td,table.ruled th{{border-color:{rule}}}" +
               (look.DarkPages ? "img{filter:brightness(.88)}" : "");
    }

    /// <summary><paramref name="html"/> (<see cref="ReflowDocument.Html"/>) with <paramref name="look"/>'s style sheet, after the writer's own.</summary>
    public static string Style(string html, ReflowLook look)
    {
        var tag = $"<style id=\"{StyleId}\">{Css(look)}</style>";
        var head = html.IndexOf("</head>", StringComparison.Ordinal);
        return head < 0 ? tag + html : html.Insert(head, tag + "\n");
    }

    /// <summary>A script that puts <paramref name="look"/> in place in the page as shown, keeping where the reader is.</summary>
    public static string RestyleScript(ReflowLook look) =>
        $"(function(){{var s=document.getElementById('{StyleId}');if(s)s.textContent={Js(Css(look))};}})()";

    /// <summary>
    /// The zoom <paramref name="steps"/> steps from <paramref name="zoom"/> (Zoom In: +1, Zoom Out: -1), within
    /// <see cref="Zooms"/>; from between two steps, the first step is the next one that way.
    /// </summary>
    public static double ZoomStep(double zoom, int steps)
    {
        const double Same = 0.001;
        if (steps == 0) return Math.Clamp(zoom, Zooms[0], Zooms[^1]);
        int at;
        if (steps > 0)
        {
            at = Zooms.Count - 1;
            for (var i = 0; i < Zooms.Count; i++)
                if (Zooms[i] > zoom + Same) { at = i; break; }
            return Zooms[Math.Clamp(at + steps - 1, 0, Zooms.Count - 1)];
        }
        at = 0;
        for (var i = Zooms.Count - 1; i >= 0; i--)
            if (Zooms[i] < zoom - Same) { at = i; break; }
        return Zooms[Math.Clamp(at + steps + 1, 0, Zooms.Count - 1)];
    }

    /// <summary>The element id of page <paramref name="page"/> (0-based) in the view.</summary>
    public static string Anchor(int page) => "page-" + (page + 1).ToString(CultureInfo.InvariantCulture);

    /// <summary>The page (0-based) an element id names, or null when it names none of <paramref name="pages"/>.</summary>
    public static int? PageOf(string? anchor, int pages)
    {
        if (anchor is null || !anchor.StartsWith("page-", StringComparison.Ordinal)) return null;
        return int.TryParse(anchor.AsSpan(5), NumberStyles.None, CultureInfo.InvariantCulture, out var n) && n >= 1 && n <= pages ? n - 1 : null;
    }

    /// <summary>A script that scrolls the view to page <paramref name="page"/>'s start.</summary>
    public static string ScrollScript(int page) =>
        $"(function(){{var e=document.getElementById('{Anchor(page)}');if(e)e.scrollIntoView();}})()";

    /// <summary>
    /// A script that answers the id of the page at the top of the view: the first page whose end is below the top edge
    /// (a page with nothing on it has no height, so the page after it answers).
    /// </summary>
    public const string TopPageScript =
        "(function(){var d=document.querySelectorAll('main > div[id^=\"page-\"]');for(var i=0;i<d.length;i++){if(d[i].getBoundingClientRect().bottom>4)return d[i].id;}return d.length?d[d.length-1].id:'';})()";

    /// <summary>
    /// Where a navigation to <paramref name="uri"/> goes: a place in the document stays in the view, a web or mail address
    /// leaves it for the browser, everything else is refused.
    /// </summary>
    public static ReflowLink Follow(string uri, int pages)
    {
        if (!Uri.TryCreate(uri, UriKind.Absolute, out var u)) return new ReflowLink(ReflowLinkKind.Blocked);
        if (u.GetLeftPart(UriPartial.Path) == Address)
        {
            var page = u.Fragment.Length > 1 ? PageOf(Uri.UnescapeDataString(u.Fragment[1..]), pages) : null;
            return new ReflowLink(ReflowLinkKind.InDocument, null, page ?? -1);
        }
        if (u.Host == new Uri(Address).Host) return new ReflowLink(ReflowLinkKind.Blocked); // the view serves one page
        return ExportLink.Web(uri)?.Uri is { } safe ? new ReflowLink(ReflowLinkKind.External, safe) : new ReflowLink(ReflowLinkKind.Blocked);
    }

    /// <summary>
    /// The commands that work while the Reflow view shows: it is read-only, so the ones that change the document, select
    /// on the page or need the page view don't (leave Reflow for them). Copy and Select All are the view's own.
    /// </summary>
    public static bool Runs(string command) => Commands.Contains(command);

    private static readonly HashSet<string> Commands = new(StringComparer.Ordinal)
    {
        "Reflow", "Save", "SaveAs", "ShowInFolder", "CloseDoc", "CloseAll", "ReloadFromDisk", "Print", "PrintWithOptions",
        "ExportWord", "ExportExcel", "ExportText", "ExportPowerPoint", "ExportHtml", "ExportImages", "Properties",
        "ZoomIn", "ZoomOut", "ActualSize", "FirstPage", "PrevPage", "NextPage", "LastPage", "GoToPage", "Back", "Forward",
        "NavPane", "MoveToNewWindow", "Organize",
    };

    private static string Js(string s)
    {
        var sb = new StringBuilder("'");
        foreach (var c in s)
            sb.Append(c switch
            {
                '\\' => "\\\\",
                '\'' => "\\'",
                '<' => "\\x3c",
                '\n' => "\\n",
                '\r' => "\\r",
                _ => c.ToString(),
            });
        return sb.Append('\'').ToString();
    }
}

/// <summary>
/// The page the Reflow view is at, kept in step with the page view's (roadmap 4.16): Reflow opens at the page the reader
/// was on, scrolling it moves the page box, the page box and the page commands scroll it, and leaving opens Pages at the
/// page it was at. Each side's report of a move the other caused comes back as no move, so they never chase each other.
/// </summary>
public sealed class ReflowPosition(int pages)
{
    public int Pages { get; } = Math.Max(1, pages);

    /// <summary>The page in view (0-based).</summary>
    public int Page { get; private set; }

    /// <summary>Reflow opens with the page view at <paramref name="viewerPage"/>: the page to scroll to.</summary>
    public int Enter(int viewerPage) => Page = Math.Clamp(viewerPage, 0, Pages - 1);

    /// <summary>The view reports the page at its top (null: it couldn't tell): the page for the page view, or null when it hasn't moved.</summary>
    public int? Scrolled(int? reflowPage)
    {
        if (reflowPage is not { } p || p < 0 || p >= Pages || p == Page) return null;
        return Page = p;
    }

    /// <summary>The page view moved to <paramref name="viewerPage"/> (the page box, Next Page): the page to scroll the view to, or null when it is there.</summary>
    public int? ViewerMoved(int viewerPage)
    {
        var p = Math.Clamp(viewerPage, 0, Pages - 1);
        if (p == Page) return null;
        return Page = p;
    }

    /// <summary>Leaving Reflow: the page Pages opens at.</summary>
    public int Leave() => Page;
}
