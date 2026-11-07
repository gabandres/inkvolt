namespace InkvoltPdf.Core;

/// <summary>
/// A file an editor saved over a longer copy of itself without cutting it to its new length keeps the old file's last bytes
/// after its own %%EOF: rows of the old xref table, the old trailer, and a startxref that now points into the middle of the
/// new file. MuPDF repairs such a file as it opens it (its pages show); PDFsharp refuses it, which left its form without
/// fields and every edit failing. <see cref="Cut"/> gives the file without that tail; the document load
/// tries it when a document opens.
/// </summary>
internal static class StaleTail
{
    /// <summary>The most startxref keywords looked at, from the end: a real file's good one is the second to last.</summary>
    private const int MaxCandidates = 64;

    /// <summary>The most bytes read past all the offsets checked, so a file full of startxrefs is cheap to refuse.</summary>
    private const int MaxScanBytes = 4 << 20;

    /// <summary>
    /// The file up to the end of the last %%EOF whose startxref points at a cross-reference section, or null when the last
    /// startxref already does, none does, or the bytes after that %%EOF may be a real (if broken) update: an object (whole
    /// or a header alone) or another cross-reference table. Dropping those could lose edits; the repair keeps them. A
    /// trailer alone is no update (one needs a table or an object before it): it is what a cut-off table leaves.
    /// </summary>
    public static byte[]? Cut(byte[] data)
    {
        var end = data.Length;
        var last = true;
        var budget = MaxScanBytes;
        for (var candidates = 0; candidates < MaxCandidates && budget > 0 && end > 0; candidates++)
        {
            if (data.AsSpan(0, end).LastIndexOf("startxref"u8) is not (var k and >= 0)) return null;
            end = k;
            if (Incremental.ParseStartXrefAt(data, k) is not ({ } at, var after))
            {
                last = false;
                continue;
            }
            var window = Math.Min(budget, Incremental.MaxXrefDictBytes);
            budget -= window;
            if (Incremental.XrefAt(data, at, window) == Incremental.XrefKind.None)
            {
                last = false;
                continue;
            }
            if (last) return null;
            var eof = data.AsSpan(after).IndexOf("%%EOF"u8);
            if (eof < 0) return null;
            var cut = after + eof + 5;
            if (cut < data.Length && data[cut] == '\r') cut++;
            if (cut < data.Length && data[cut] == '\n') cut++;
            if (cut >= data.Length || MayHoldUpdate(data.AsSpan(cut))) return null;
            return data[..cut];
        }
        return null;
    }

    private static bool MayHoldUpdate(ReadOnlySpan<byte> tail)
    {
        if (tail.IndexOf("endobj"u8) >= 0 || Incremental.HasObjectHeader(tail)) return true;
        for (var from = 0; tail[from..].IndexOf("xref"u8) is var i and >= 0; from += i + 4)
            if (!tail[..(from + i)].EndsWith("start"u8)) return true;
        return false;
    }
}
