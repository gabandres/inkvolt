using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Files MuPDF repairs as it opens them (their pages show) and PDFsharp refused, leaving them with no fields, comments or
/// bookmarks and every edit failing. A document's bytes are made readable once, as it opens (<see cref="PdfRepair.Normalize"/>):
/// as they are, without a stale tail, or with a cross-reference section rebuilt from the objects in the file.
/// </summary>
public class DamagedFileTests
{
    /// <summary>
    /// One page with a text field (name = Ana), a note ("Check this") and a bookmark ("Chapter one"); its content stream
    /// shows the text "12 0 obj", which a repair must not take for an object.
    /// </summary>
    private static readonly string[] Objects =
    [
        "<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R 6 0 R] /Contents 9 0 R /Resources << /Font << /Helv 4 0 R >> >> >>",
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        "<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 0 Tf 0 g) /V (Ana) >>",
        "<< /Type /Annot /Subtype /Text /P 3 0 R /Rect [400 700 420 720] /Contents (Check this) >>",
        "<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>",
        "<< /Title (Chapter one) /Parent 7 0 R /Dest [3 0 R /Fit] >>",
        Core2Pdf.Stream("BT /Helv 12 Tf 72 650 Td (12 0 obj) Tj ET\n"),
    ];

    private static string Sound() => Encoding.Latin1.GetString(Core2Pdf.Build(Objects));

    private static byte[] Bytes(string s) => Encoding.Latin1.GetBytes(s);

    /// <summary>Every row of the xref table off by two bytes, as a tool that changed the header without moving them leaves it.</summary>
    private static byte[] BrokenOffsets() =>
        Bytes(Regex.Replace(Sound(), @"(\d{10}) 00000 n", m => $"{long.Parse(m.Groups[1].Value) + 2:D10} 00000 n"));

    /// <summary>
    /// Saved over a longer older copy of itself: after the new %%EOF, the old file's last object, the end of its xref table,
    /// its trailer and a startxref into the middle of the new file. The tail holds an object, so it isn't simply cut.
    /// </summary>
    private static byte[] StaleTailWithOldObjects()
    {
        var sound = Sound();
        return Bytes(sound + "ndobj\n4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>\nendobj\n" +
            "0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n" + (sound.Length - 30) + "\n%%EOF\n");
    }

    /// <summary>The field, note and bookmark item in an object stream, a cross-reference stream whose row for that object stream is wrong.</summary>
    private static byte[] ObjectStreamWithABadOffset() => WithObjectStream(badOffset: true, size: true);

    /// <summary>A cross-reference stream without /Size, which says how many rows it has.</summary>
    private static byte[] MissingSize() => WithObjectStream(badOffset: false, size: false);

    private static byte[] WithObjectStream(bool badOffset, bool size)
    {
        int[] compressed = [5, 6, 8];
        var n = Objects.Length;
        var (objStm, xref) = (n + 1, n + 2);
        var sb = new StringBuilder("%PDF-1.7\n");
        var offsets = new Dictionary<int, int>();
        for (var i = 1; i <= n; i++)
        {
            if (compressed.Contains(i)) continue;
            offsets[i] = sb.Length;
            sb.Append($"{i} 0 obj\n{Objects[i - 1]}\nendobj\n");
        }
        var header = new StringBuilder();
        var body = new StringBuilder();
        foreach (var c in compressed)
        {
            header.Append($"{c} {body.Length} ");
            body.Append(Objects[c - 1]).Append('\n');
        }
        var content = header.ToString() + body;
        offsets[objStm] = sb.Length;
        sb.Append($"{objStm} 0 obj\n<< /Type /ObjStm /N {compressed.Length} /First {header.Length} /Length {content.Length} >>\nstream\n{content}\nendstream\nendobj\n");
        offsets[xref] = sb.Length;
        var rows = new List<byte>();
        for (var i = 0; i <= xref; i++)
        {
            if (i == 0) rows.AddRange([0, 0, 0, 0, 0, 0xFF, 0xFF]);
            else if (compressed.Contains(i)) rows.AddRange([2, .. Be(objStm, 4), .. Be(Array.IndexOf(compressed, i), 2)]);
            else rows.AddRange([1, .. Be(offsets[i] + (badOffset && i == objStm ? 7 : 0), 4), 0, 0]);
        }
        sb.Append($"{xref} 0 obj\n<< /Type /XRef {(size ? $"/Size {xref + 1} " : "")}/W [1 4 2] /Root 1 0 R /Length {rows.Count} >>\nstream\n");
        return [.. Bytes(sb.ToString()), .. rows, .. Bytes($"\nendstream\nendobj\nstartxref\n{offsets[xref]}\n%%EOF\n")];

        static byte[] Be(int v, int width) => [.. Enumerable.Range(0, width).Select(k => (byte)(v >> (8 * (width - 1 - k))))];
    }

    /// <summary>A download cut off before the cross-reference table: every object is there, nothing says where.</summary>
    private static byte[] Truncated()
    {
        var sound = Sound();
        return Bytes(sound[..sound.IndexOf("xref\n", StringComparison.Ordinal)]);
    }

    public static TheoryData<string> Damages() => ["BrokenOffsets", "StaleTailWithOldObjects", "ObjectStreamWithABadOffset", "MissingSize", "Truncated"];

    private static byte[] Damaged(string name) => name switch
    {
        "BrokenOffsets" => BrokenOffsets(),
        "StaleTailWithOldObjects" => StaleTailWithOldObjects(),
        "ObjectStreamWithABadOffset" => ObjectStreamWithABadOffset(),
        "MissingSize" => MissingSize(),
        _ => Truncated(),
    };

    private static void Readable(byte[] data)
    {
        var field = Assert.Single(FormEditor.Read(data, null));
        Assert.Equal(("name", "Ana"), (field.FieldName, field.Value));
        Assert.Contains(Annotations.Read(data, null), a => a.Contents == "Check this");
        Assert.Equal("Chapter one", Assert.Single(Bookmarks.Read(data, null)).Title);
    }

    [Theory]
    [MemberData(nameof(Damages))]
    public void ADamagedFileOpensWithItsFieldsCommentsAndBookmarks(string damage)
    {
        var data = Damaged(damage);
        Assert.ThrowsAny<Exception>(() => Readable(data)); // what the readers found in the file as it is: nothing, or an error

        var normal = PdfRepair.Normalize(data, null);
        Assert.True(normal.Repaired);
        Assert.True(normal.Data.AsSpan(0, data.Length).SequenceEqual(data)); // the repair only adds a cross-reference section
        Readable(normal.Data);

        // The session normalizes once: the view, the readers and Save all have the repaired bytes.
        using var session = DocumentSession.FromBytes(data, "damaged.pdf");
        Assert.True(session.Repaired);
        Assert.Equal(normal.Data, session.Data);
        Assert.Equal(1, session.Engine.PageCount);
        Readable(session.Data);
        var filled = FormEditor.SetValues(session.Data, null, new Dictionary<string, string> { ["name"] = "Bea" });
        Assert.Equal("Bea", Assert.Single(FormEditor.Read(filled, null)).Value);
    }

    [Fact]
    public void AClassicTrailerWithoutSizeReadsAsItIs()
    {
        // PDFsharp counts a table's rows itself: nothing to repair. (A cross-reference stream's rows it reads as none.)
        var data = Bytes(Sound().Replace("/Size 10 ", ""));
        Assert.Equal(PdfRepair.Outcome.AsIs, PdfRepair.Normalize(data, null).Outcome);
        Readable(data);
    }

    [Fact]
    public void AStaleTailWithNothingButTableRowsIsCutNotRepaired()
    {
        var sound = Sound();
        var data = Bytes(sound + "0000000099 00000 n \ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n" + (sound.Length - 30) + "\n%%EOF\n");
        var normal = PdfRepair.Normalize(data, null);
        Assert.Equal(PdfRepair.Outcome.StaleTailCut, normal.Outcome);
        Assert.Equal(sound, Encoding.Latin1.GetString(normal.Data));
    }

    [Fact]
    public void ASoundFileIsLeftAsItIs()
    {
        var data = Core2Pdf.Build(Objects);
        var normal = PdfRepair.Normalize(data, null);
        Assert.Equal(PdfRepair.Outcome.AsIs, normal.Outcome);
        Assert.Same(data, normal.Data);
        using var session = DocumentSession.FromBytes(data, "sound.pdf");
        Assert.False(session.Repaired);
        Assert.Same(data, session.Data);
    }

    [Fact]
    public void AFileBeyondRepairKeepsItsBytesAndItsFirstError()
    {
        // No objects at all: nothing to rebuild from. Readers then fail with what PDFsharp said of the file as it is.
        var data = Bytes("%PDF-1.7\nthis is not a document\nstartxref\n9\n%%EOF\n");
        var normal = PdfRepair.Normalize(data, null);
        Assert.Equal(PdfRepair.Outcome.AsIs, normal.Outcome);
        Assert.Same(data, normal.Data);
        var first = Assert.ThrowsAny<Exception>(() => PdfReader.Open(new MemoryStream(data), PdfDocumentOpenMode.Import));
        var ex = Assert.Throws<InvalidOperationException>(() => FormEditor.Read(normal.Data, null));
        Assert.Contains(first.Message, ex.Message);
    }

    [Fact]
    public void ADamagedFileOnDiskOpensRepaired()
    {
        var path = Path.Combine(Path.GetTempPath(), $"inkvolt-damaged-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, Truncated());
        try
        {
            using var session = DocumentSession.Open(path);
            Assert.True(session.Repaired);
            Readable(session.Data);
            Assert.False(session.IsDirty); // nothing is written until the person saves
            session.SaveAs(path);
            using var doc = PdfReader.Open(path, PdfDocumentOpenMode.Import); // saving wrote the repaired copy
            Assert.Equal(1, doc.PageCount);
        }
        finally
        {
            File.Delete(path);
        }
    }

    [Fact]
    public void ARepairedFileCanBeSignedAndItsSignatureChecks()
    {
        using var session = DocumentSession.FromBytes(Truncated(), "damaged.pdf");
        Assert.True(session.Repaired);
        using var cert = SigningTests.RsaCert();
        // Signing appends to the repaired bytes (Incremental.Track is given those, never the file's).
        var signed = Signing.Sign(session.Data, null, new SignRequest { Certificate = cert, Reason = "Approved" });
        Assert.True(signed.AsSpan(0, session.Data.Length).SequenceEqual(session.Data));
        var sig = Assert.Single(Signatures.InRepairedFile(Signatures.Verify(signed), session.RepairedLength));
        Assert.Equal(SignatureStatus.Valid, sig.Status); // made on the repaired copy: checked as usual
        Assert.False(sig.InRepairedFile);
        Readable(signed);
    }

    [Fact]
    public void ASignatureMadeBeforeTheRepairIsNeverShownValid()
    {
        // Signed, then saved over a longer copy of itself: its tail holds an object, so the file is repaired, not cut.
        using var cert = SigningTests.RsaCert();
        var signed = Encoding.Latin1.GetString(Signing.Sign(Core2Pdf.Build(Objects), null, new SignRequest { Certificate = cert }));
        var damaged = Bytes(signed + "ndobj\n4 0 obj\n<< /Old true >>\nendobj\ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n" + (signed.Length - 30) + "\n%%EOF\n");
        using var session = DocumentSession.FromBytes(damaged, "damaged.pdf");
        Assert.True(session.Repaired);
        var sig = Assert.Single(Signatures.InRepairedFile(Signatures.Verify(session.Data), session.RepairedLength));
        Assert.Equal(SignatureStatus.Unsupported, sig.Status);
        Assert.True(sig.InRepairedFile);
        Assert.NotNull(sig.Detail);
        Assert.Null(sig.LongTerm);
        // A file that wasn't repaired is checked as usual.
        var plain = Signatures.Verify(Bytes(signed));
        Assert.Equal(SignatureStatus.Valid, Assert.Single(plain).Status);
        Assert.Same(plain, Signatures.InRepairedFile(plain, 0));
    }

    [Fact]
    public void ARepairOfAHostileFileFinishesQuickly()
    {
        // 300,000 object headers with no endobj, each followed by "stream" that never ends, and a dictionary of near misses.
        var sb = new StringBuilder("%PDF-1.7\n");
        for (var i = 1; i <= 300_000; i++) sb.Append($"{i} 0 obj << /Length 999999 /Type /strea >> stream\n");
        var data = Bytes(sb.ToString());
        var clock = System.Diagnostics.Stopwatch.StartNew();
        PdfRepair.Rebuild(data);
        Assert.True(clock.ElapsedMilliseconds < 3000, $"{clock.ElapsedMilliseconds} ms");
    }
}
