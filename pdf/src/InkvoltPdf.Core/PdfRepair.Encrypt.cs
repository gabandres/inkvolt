namespace InkvoltPdf.Core;

public static partial class PdfRepair
{
    /// <summary>The most cross-reference sections <see cref="NewestEncryptOnly"/> follows through /Prev: more than any real file.</summary>
    private const int MaxSections = 1024;

    /// <summary>
    /// PDFsharp can't read an encrypted file whose /Encrypt is named by three or more trailers (an encrypted form saved
    /// incrementally twice, by Acrobat or by <see cref="UserPasswordEdits"/>): it fails with "Indirect reference without
    /// value". The newest section is the one that counts, so the copy PDFsharp reads (<see cref="PdfObj.Read"/>) has the
    /// /Encrypt of every older section's trailer, cross-reference stream dictionary and /XRefStm dictionary blanked out
    /// (same length: every offset stays). Only the dictionaries the cross-reference chain leads to (startxref, then each
    /// /Prev) are touched, never an object's content or a stream's data; the file itself, which signatures cover and
    /// edits are appended to, never changes. Null, and nothing copied, when fewer than two sections name /Encrypt by
    /// reference. At most <see cref="MaxSections"/> sections, each dictionary read token by token within
    /// <see cref="MaxDictChars"/>, a trailer looked for after its table within the work's budget.
    /// </summary>
    internal static byte[]? NewestEncryptOnly(byte[] data)
    {
        if (data.AsSpan().IndexOf("/Encrypt"u8) < 0 || Incremental.StartXref(data) is not { } at) return null;
        var work = new Work(2L * data.Length + 2L * MaxSections * MaxDictChars);
        var seen = new HashSet<long>();
        var blanks = new List<(int Start, int Length)>();
        var sections = 0;
        while (sections < MaxSections && seen.Add(at))
        {
            if (SectionDict(data, at, work) is not { } dict || work.Spent) break;
            var named = false;
            foreach (var d in (RawDict?[])[dict, dict.Int("/XRefStm") is { } stm && stm > 0 && stm < data.Length ? SectionDict(data, stm, work) : null])
                if (d?.Ref("/Encrypt") is not null && d.Entry("/Encrypt") is { } entry)
                {
                    if (sections > 0) blanks.Add(entry);
                    named = true;
                }
            if (named) sections++;
            else if (sections == 0) return null; // the newest section doesn't name it: this isn't the failure handled here
            if (dict.Int("/Prev") is not { } prev || prev <= 0 || prev >= data.Length) break;
            at = prev;
        }
        if (blanks.Count == 0 || work.Spent) return null;
        var copy = (byte[])data.Clone();
        foreach (var (start, length) in blanks) copy.AsSpan(start, length).Fill((byte)' ');
        return copy;
    }

    /// <summary>
    /// The dictionary of the cross-reference section at <paramref name="at"/>: a table's trailer (the first "trailer" after
    /// it), or a cross-reference stream's dictionary; null when neither is there.
    /// </summary>
    private static RawDict? SectionDict(byte[] data, long at, Work work)
    {
        switch (Incremental.XrefAt(data, at))
        {
            case Incremental.XrefKind.Table:
                var t = data.AsSpan((int)at).IndexOf("trailer"u8);
                work.Spend(t < 0 ? data.Length - at : t);
                return t < 0 || work.Spent ? null : ReadDict(data, SkipWhite(data, (int)at + t + 7, data.Length), work);
            case Incremental.XrefKind.Stream:
                var o = data.AsSpan((int)at, (int)Math.Min(data.Length - at, 64)).IndexOf("obj"u8);
                return o < 0 ? null : ReadDict(data, SkipWhite(data, (int)at + o + 3, data.Length), work);
            default:
                return null;
        }
    }
}
