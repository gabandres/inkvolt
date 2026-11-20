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
        while (seen.Count < MaxSections && seen.Add(at))
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
    /// Whether the cross-reference sections, followed through /Prev as PDFsharp follows them, come to an end. False when one
    /// leads back to a section already read (PDFsharp would read on for good), or reading them takes more than any real
    /// file's: a table's trailer comes soon after it, so that is a few times the file's size at most.
    /// </summary>
    internal static bool SectionsEnd(byte[] data)
    {
        if (Incremental.StartXref(data) is not { } at) return true;
        var work = new Work(4L * data.Length + 2L * MaxSections * MaxDictChars);
        var seen = new HashSet<long>();
        while (true)
        {
            if (!seen.Add(at)) return false;
            work.Spend(MaxDictChars); // what looking at a section may read, whatever it holds
            var dict = SectionDict(data, at, work);
            if (work.Spent) return false;
            if (dict?.Int("/Prev") is not { } prev || prev <= 0 || prev >= data.Length) return true;
            at = prev;
        }
    }

    /// <summary>The most dictionaries <see cref="EncryptionOf"/> gives for one indirect /Encrypt: one in a sound file.</summary>
    internal const int MaxEncryptCandidates = 8;

    /// <summary>
    /// How a file's objects are encrypted, as PDFsharp finds it: /Encrypt as written in the newest cross-reference section
    /// that names it (followed through /Prev), with /ID from the newest that has one. When /Encrypt is a reference, every
    /// dictionary written under that object's number and generation is a candidate (one in a sound file; which one PDFsharp
    /// takes is the cross-reference's to say, so a caller checks them all).
    /// </summary>
    internal sealed record Encryption(string Encrypt, (int Num, int Gen)? Object, IReadOnlyList<string> Dictionaries, string? Id);

    /// <summary>
    /// The encryption of <paramref name="data"/> (<see cref="Encryption"/>); null when no section names /Encrypt, the sections
    /// can't be read, or an indirect one has no dictionary or more than <see cref="MaxEncryptCandidates"/>.
    /// </summary>
    internal static Encryption? EncryptionOf(byte[] data)
    {
        if (data.AsSpan().IndexOf("/Encrypt"u8) < 0 || Incremental.StartXref(data) is not { } at) return null;
        var work = new Work(4L * data.Length + 2L * MaxSections * MaxDictChars);
        var seen = new HashSet<long>();
        string? encrypt = null, id = null;
        while (seen.Count < MaxSections && seen.Add(at))
        {
            if (SectionDict(data, at, work) is not { } dict || work.Spent) return null;
            id ??= dict.Raw("/ID");
            if ((encrypt = dict.Raw("/Encrypt")) is not null) break;
            if (dict.Int("/Prev") is not { } prev || prev <= 0 || prev >= data.Length) return null;
            at = prev;
        }
        if (encrypt is null) return null;
        if (RefOf(encrypt) is not { } r) return new Encryption(encrypt, null, [encrypt], id);

        var dicts = new List<string>();
        var objKw = new Next(data, "obj"u8.ToArray());
        for (var pos = 0; objKw.From(pos) is var i and >= 0; pos = i + 3)
        {
            if (Incremental.ObjectHeaderAt(data, i) is not { } header || header.Num != r.Num || header.Gen != r.Gen) continue;
            var start = SkipWhite(data, i + 3, data.Length);
            if (ReadDict(data, start, work) is { } d) dicts.Add(System.Text.Encoding.Latin1.GetString(data, start, d.End - start));
            if (work.Spent || dicts.Count > MaxEncryptCandidates) return null;
        }
        return dicts.Count == 0 ? null : new Encryption(encrypt, r, dicts, id);
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
