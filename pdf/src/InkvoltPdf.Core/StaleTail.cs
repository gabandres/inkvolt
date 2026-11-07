namespace InkvoltPdf.Core;

/// <summary>
/// A file an editor saved over a longer copy of itself without cutting it to its new length keeps the old file's last bytes
/// after its own %%EOF: rows of the old xref table, the old trailer, and a startxref that now points into the middle of the
/// new file. MuPDF repairs such a file as it opens it (its pages show); PDFsharp refuses it, which left its form without
/// fields and every edit failing. <see cref="Cut"/> gives the file without that tail.
/// </summary>
internal static class StaleTail
{
    /// <summary>How far after a startxref offset an xref stream's dictionary may run before "stream".</summary>
    private const int MaxDictBytes = 64 * 1024;

    /// <summary>
    /// The file up to the end of the last %%EOF whose startxref points at a cross-reference section, or null when the last
    /// startxref already does, none does, or the bytes after that %%EOF hold an object: those may be a real (if broken)
    /// update, and dropping it would lose edits.
    /// </summary>
    public static byte[]? Cut(byte[] data)
    {
        var end = data.Length;
        var last = true;
        while (end > 0 && data.AsSpan(0, end).LastIndexOf("startxref"u8) is var k and >= 0)
        {
            end = k;
            if (Offset(data, k + "startxref".Length) is not ({ } at, var after) || !IsXref(data, at)) { last = false; continue; }
            if (last) return null;
            var eof = data.AsSpan(after).IndexOf("%%EOF"u8);
            if (eof < 0) return null;
            var cut = after + eof + 5;
            if (cut < data.Length && data[cut] == '\r') cut++;
            if (cut < data.Length && data[cut] == '\n') cut++;
            if (cut >= data.Length || data.AsSpan(cut).IndexOf("endobj"u8) >= 0) return null;
            return data[..cut];
        }
        return null;
    }

    /// <summary>The number after "startxref" at <paramref name="p"/> and where it ends, or null.</summary>
    private static (long At, int After)? Offset(byte[] data, int p)
    {
        while (p < data.Length && data[p] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n' or (byte)'\f' or 0) p++;
        long at = 0;
        var digits = 0;
        for (; p < data.Length && data[p] is >= (byte)'0' and <= (byte)'9' && digits < 18; p++, digits++) at = at * 10 + (data[p] - '0');
        return digits > 0 && at > 0 && at < data.Length ? (at, p) : null;
    }

    /// <summary>Whether a classic xref table ("xref") or an xref stream ("n g obj" with /Type /XRef) starts at <paramref name="at"/>.</summary>
    private static bool IsXref(byte[] data, long at)
    {
        var p = (int)at;
        while (p < data.Length && data[p] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n' or (byte)'\f' or 0) p++;
        var rest = data.AsSpan(p);
        if (rest.StartsWith("xref"u8)) return true;
        var i = 0;
        for (var number = 0; number < 2; number++)
        {
            var start = i;
            while (i < rest.Length && i - start < 10 && rest[i] is >= (byte)'0' and <= (byte)'9') i++;
            if (i == start) return false;
            var spaces = i;
            while (i < rest.Length && rest[i] is (byte)' ' or (byte)'\r' or (byte)'\n') i++;
            if (i == spaces) return false;
        }
        if (!rest[i..].StartsWith("obj"u8)) return false;
        var window = rest[i..Math.Min(rest.Length, i + MaxDictBytes)];
        var stream = window.IndexOf("stream"u8);
        return stream > 0 && window[..stream].IndexOf("/XRef"u8) >= 0;
    }
}
