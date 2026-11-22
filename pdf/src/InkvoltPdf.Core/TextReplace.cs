using System.Globalization;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What Find &amp; Replace looks for: the text, and whether case and whole words count.</summary>
public sealed record ReplaceQuery(string Find, bool MatchCase = false, bool WholeWord = false);

/// <summary>
/// One place Find &amp; Replace found the text: its page, its paragraph (by its place in the page's paragraphs as Edit Text
/// &amp; Images groups them, and its text and box then), where in that text, and the words around it for the preview.
/// </summary>
public sealed record ReplaceMatch(int PageIndex, int Paragraph, int Start, int Length, string Found, string Before, string After)
{
    /// <summary>The paragraph's text when it was found: a replacement is made only where the paragraph still reads so.</summary>
    public string ParagraphText { get; init; } = "";

    /// <summary>The paragraph's box (page space, top-left origin), to show where the match is.</summary>
    public RectD Box { get; init; }

    /// <summary>Why the paragraph can't be changed ("it is …", as Edit Text &amp; Images says it); null when it can.</summary>
    public string? Blocked { get; init; }
}

/// <summary>What Find &amp; Replace found: the matches in page order, and whether there were more than it lists.</summary>
public sealed record ReplaceFound(IReadOnlyList<ReplaceMatch> Matches, bool CutShort)
{
    /// <summary>The pages with a match.</summary>
    public int Pages => Matches.Select(m => m.PageIndex).Distinct().Count();
}

/// <summary>How a replacement went other than as asked.</summary>
public enum ReplaceNoteKind
{
    /// <summary>Made, but characters the paragraph's font lacks are drawn in an installed font (<see cref="ReplaceNote.Fonts"/>).</summary>
    StandIn,
    /// <summary>
    /// Made in text on one line, which doesn't wrap: it is <see cref="ReplaceNote.Wider"/> points wider and may run into what
    /// is beside it (as Edit Text &amp; Images says of one line).
    /// </summary>
    Wider,
    /// <summary>Not made: no font on this PC has these characters (<see cref="ReplaceNote.Chars"/>); the text stays as it was.</summary>
    Missing,
    /// <summary>Not made: the longer paragraph would run into the text or picture below it.</summary>
    WouldOverlap,
    /// <summary>Not made: the paragraph can't be edited (<see cref="ReplaceNote.Why"/>).</summary>
    CantEdit,
    /// <summary>Not made: the paragraph no longer reads as it did when it was found.</summary>
    Changed,
}

/// <summary>
/// A replacement that wasn't made as asked, and what was done instead: for the first of <see cref="Count"/> matches in one
/// paragraph (they share it).
/// </summary>
public sealed record ReplaceNote(ReplaceMatch Match, ReplaceNoteKind Kind, int Count)
{
    /// <summary><see cref="ReplaceNoteKind.StandIn"/>: the characters borrowed; <see cref="ReplaceNoteKind.Missing"/>: those no font has.</summary>
    public IReadOnlyList<string> Chars { get; init; } = [];

    /// <summary><see cref="ReplaceNoteKind.StandIn"/>: the installed fonts they are drawn in ("Arial").</summary>
    public IReadOnlyList<string> Fonts { get; init; } = [];

    /// <summary><see cref="ReplaceNoteKind.CantEdit"/>: why, as a sentence for the user.</summary>
    public string? Why { get; init; }

    /// <summary><see cref="ReplaceNoteKind.Wider"/>: how much wider the line is (points).</summary>
    public double Wider { get; init; }

    /// <summary>The replacement was made (<see cref="ReplaceNoteKind.StandIn"/>, <see cref="ReplaceNoteKind.Wider"/>).</summary>
    public bool Made => Kind is ReplaceNoteKind.StandIn or ReplaceNoteKind.Wider;
}

/// <summary>What Replace or Replace All did: the document (the same array when nothing was replaced), how many, and the notes.</summary>
public sealed record ReplaceResult(byte[] Data, int Replaced, IReadOnlyList<ReplaceNote> Notes)
{
    /// <summary>Matches not replaced.</summary>
    public int Left => Notes.Where(n => !n.Made).Sum(n => n.Count);
}

/// <summary>
/// Find &amp; Replace across the document (roadmap 4.2): the text is found in each page's paragraphs as Edit Text &amp;
/// Images groups them (so a phrase wrapped across two lines is found), and replaced through its paragraph editing: the
/// paragraph is rewritten in its box in its own font and looks, rewrapped, characters the font lacks drawn from the closest
/// installed font. Replace All is one pass over the document kept open, saved once: one undo step, one incremental update
/// for a signed file. A replacement that can't be made as asked is never skipped silently: each comes back as a
/// <see cref="ReplaceNote"/> (characters no font has, a paragraph that would run into what follows, one that can't be
/// edited), and the text there stays as it was.
/// </summary>
public static class TextReplace
{
    /// <summary>Matches listed at most: a search for "e" in a long book stops here and says so.</summary>
    public const int MaxMatches = 5_000;

    /// <summary>The longest text looked for.</summary>
    public const int MaxQuery = 1_000;

    /// <summary>Characters of context on each side of a match in the preview.</summary>
    public const int ContextChars = 40;

    /// <summary>
    /// Where <paramref name="query"/>'s text is in <paramref name="text"/>: case ignored unless asked (as Find ignores it,
    /// letters only), a whole word only when asked (not inside a longer word). Matches don't overlap.
    /// </summary>
    public static List<(int Start, int Length)> FindIn(string text, ReplaceQuery query)
    {
        var hits = new List<(int, int)>();
        var find = query.Find;
        if (find.Length == 0 || find.Length > MaxQuery || text.Length == 0) return hits;
        var ci = CultureInfo.InvariantCulture.CompareInfo;
        var options = query.MatchCase ? CompareOptions.None : CompareOptions.IgnoreCase;
        var pos = 0;
        while (pos < text.Length)
        {
            var rel = ci.IndexOf(text.AsSpan(pos), find, options, out var length);
            if (rel < 0 || length == 0) break;
            var start = pos + rel;
            var end = start + length;
            if (!query.WholeWord || (!(start > 0 && IsWordChar(text[start - 1]) && IsWordChar(text[start])) && !(end < text.Length && IsWordChar(text[end]) && IsWordChar(text[end - 1]))))
            {
                hits.Add((start, length));
                pos = end;
            }
            else pos = start + 1;
        }
        return hits;
    }

    private static bool IsWordChar(char c) => char.IsLetterOrDigit(c) || c == '_' ||
        CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark;

    /// <summary>
    /// Every match in the document, page by page, in the order of the page's paragraphs (at most <see cref="MaxMatches"/>).
    /// A page that can't be read has none. <paramref name="progress"/> hears each page read (its number, from 1).
    /// </summary>
    public static ReplaceFound Find(byte[] data, string? password, ReplaceQuery query, IProgress<int>? progress = null, CancellationToken cancel = default)
    {
        var matches = new List<ReplaceMatch>();
        if (query.Find.Length == 0 || query.Find.Length > MaxQuery) return new ReplaceFound(matches, false);
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, PdfStrings.Doc_PagesCantBeRead);
        for (var page = 0; page < doc.PageCount; page++)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report(page + 1);
            foreach (var (i, p) in ContentEditor.ParagraphsOf(doc, page, cancel).Index())
                foreach (var (start, length) in FindIn(p.Text, query))
                {
                    if (matches.Count == MaxMatches) return new ReplaceFound(matches, true);
                    matches.Add(new ReplaceMatch(page, i, start, length, p.Text.Substring(start, length), Around(p.Text, start, -1), Around(p.Text, start + length, 1))
                    {
                        ParagraphText = p.Text,
                        Box = p.Box,
                        Blocked = p.Blocked,
                    });
                }
        }
        return new ReplaceFound(matches, false);
    }

    /// <summary>The words before (<paramref name="direction"/> -1) or after (1) a place, about <see cref="ContextChars"/> of them, on one line.</summary>
    private static string Around(string text, int at, int direction)
    {
        string s;
        if (direction < 0)
        {
            var from = Math.Max(0, at - ContextChars);
            while (from > 0 && from < at && !char.IsWhiteSpace(text[from - 1])) from++; // start at a word
            s = (from > 0 ? "…" : "") + text[from..at];
        }
        else
        {
            var to = Math.Min(text.Length, at + ContextChars);
            while (to < text.Length && to > at && !char.IsWhiteSpace(text[to])) to--; // end at a word
            s = text[at..to] + (to < text.Length ? "…" : "");
        }
        return s.Replace('\n', ' ');
    }

    /// <summary>
    /// Replaces <paramref name="matches"/> (from <see cref="Find"/> on these bytes) with <paramref name="with"/>, paragraph by
    /// paragraph, in one pass over the document; see the class summary. Nothing replaced: the same bytes back.
    /// </summary>
    public static ReplaceResult Replace(byte[] data, string? password, IReadOnlyList<ReplaceMatch> matches, string with, CancellationToken cancel = default)
    {
        var notes = new List<ReplaceNote>();
        if (matches.Count == 0) return new ReplaceResult(data, 0, notes);
        with = with.Replace("\r\n", "\n").Replace('\r', '\n').Replace('\t', ' ');
        var replaced = 0;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, PdfStrings.Doc_CantEdit);
        foreach (var group in matches.GroupBy(m => (m.PageIndex, m.Paragraph)).OrderBy(g => g.Key.PageIndex).ThenBy(g => g.Key.Paragraph))
        {
            cancel.ThrowIfCancellationRequested();
            var first = group.First();
            var count = group.Count();
            ReplaceNote NoteOf(ReplaceNoteKind kind, int n, string? why = null) => new(first, kind, n) { Why = why };
            if (first.Blocked is { } blocked)
            {
                notes.Add(NoteOf(ReplaceNoteKind.CantEdit, count, Loc.Format(PdfStrings.Edit_ParagraphCantBeEdited, blocked)));
                continue;
            }
            // The page as it is now (an earlier paragraph on it may have been rewritten), and the paragraph on it that still
            // reads as it did, where it was.
            IReadOnlyList<TextParagraph> now;
            try
            {
                now = ContentEditor.ParagraphsOf(doc, first.PageIndex, cancel);
            }
            catch (ContentEditException ex)
            {
                notes.Add(NoteOf(ReplaceNoteKind.CantEdit, count, ex.Message));
                continue;
            }
            var p = now.Where(q => q.Text == first.ParagraphText).MinBy(q => Math.Abs(q.Box.X - first.Box.X) + Math.Abs(q.Box.Y - first.Box.Y));
            if (p is null || Math.Abs(p.Box.X - first.Box.X) + Math.Abs(p.Box.Y - first.Box.Y) > 2 * Math.Max(1, p.FontSize))
            {
                notes.Add(NoteOf(ReplaceNoteKind.Changed, count));
                continue;
            }
            if (p.Blocked is { } why)
            {
                notes.Add(NoteOf(ReplaceNoteKind.CantEdit, count, Loc.Format(PdfStrings.Edit_ParagraphCantBeEdited, why)));
                continue;
            }

            // The paragraph's new text: each match, from the last, where it still reads as found.
            var text = p.Text;
            var made = 0;
            var end = int.MaxValue;
            foreach (var m in group.OrderByDescending(m => m.Start))
            {
                if (m.Start < 0 || m.Start + m.Length > end || m.Start + m.Length > text.Length || string.CompareOrdinal(text, m.Start, m.Found, 0, m.Length) != 0)
                {
                    notes.Add(new ReplaceNote(m, ReplaceNoteKind.Changed, 1));
                    continue;
                }
                text = string.Concat(text.AsSpan(0, m.Start), with, text.AsSpan(m.Start + m.Length));
                end = m.Start;
                made++;
            }
            if (made == 0) continue;
            text = ContentEditor.ParagraphText(text);
            var spans = ContentEditor.Carry(p.Text, text, p.Spans);
            var check = p.Check(text, spans);
            if (check.Missing.Count > 0)
            {
                notes.Add(NoteOf(ReplaceNoteKind.Missing, made) with { Chars = check.Missing });
                continue;
            }
            if (check.LookProblem is { } lp)
            {
                notes.Add(NoteOf(ReplaceNoteKind.CantEdit, made, Loc.Format(PdfStrings.Edit_CantBeWritten, lp)));
                continue;
            }
            if (check.Overlaps is not null)
            {
                notes.Add(NoteOf(ReplaceNoteKind.WouldOverlap, made));
                continue;
            }
            try
            {
                ContentEditor.ReplaceParagraphIn(doc, p, text, allowOverlap: false, spans, []);
            }
            catch (ContentEditException ex)
            {
                notes.Add(NoteOf(ReplaceNoteKind.CantEdit, made, ex.Message));
                continue;
            }
            replaced += made;
            if (check.Borrowed.Count > 0)
                notes.Add(NoteOf(ReplaceNoteKind.StandIn, made) with { Chars = check.Borrowed, Fonts = check.StandIns });
            if (p.Lines.Count == 1 && check.LineCount == 1 && check.Box.Width - p.Box.Width > 0.5)
                notes.Add(NoteOf(ReplaceNoteKind.Wider, made) with { Wider = check.Box.Width - p.Box.Width });
        }
        if (replaced == 0) return new ReplaceResult(data, 0, notes);
        SignedEdits.NoteRemoval(); // the old text stays in a signed file's earlier revision
        return new ReplaceResult(PdfObj.Save(doc), replaced, notes);
    }
}
