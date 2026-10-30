namespace InkvoltPdf.Core;

/// <summary>The command palette's words when a search finds nothing: what to try next, in plain words.</summary>
public static class PaletteText
{
    /// <summary>
    /// With a document open, the palette lists every command, so a miss means other words (or a page number). Without
    /// one, most commands aren't offered at all, which is worth saying: "sign" finds nothing on the start page.
    /// </summary>
    public static string NoMatch(string query, bool hasDocument)
    {
        var q = query.Trim();
        var shown = q.Length > 40 ? q[..40] + "…" : q;
        return hasDocument
            ? $"Nothing matches “{shown}”. Try another word, or type a page number to go there."
            : $"Nothing matches “{shown}” with no document open. Open a file for the document commands (sign, edit text, export, redact…).";
    }
}
