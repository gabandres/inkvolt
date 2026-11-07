using System.Text;
using System.Text.RegularExpressions;
using Inkvolt.Testing;
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

    private static void Readable(byte[] data, string? password = null)
    {
        var field = Assert.Single(FormEditor.Read(data, password));
        Assert.Equal(("name", "Ana"), (field.FieldName, field.Value));
        Assert.Contains(Annotations.Read(data, password), a => a.Contents == "Check this");
        Assert.Equal("Chapter one", Assert.Single(Bookmarks.Read(data, password)).Title);
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
        using var session = DocumentSession.FromBytes(data, "damaged.pdf", repair: true);
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
        using var session = DocumentSession.FromBytes(data, "sound.pdf", repair: true);
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
        using var session = DocumentSession.FromBytes(Truncated(), "damaged.pdf", repair: true);
        Assert.True(session.Repaired);
        using var cert = SigningTests.RsaCert();
        // Signing appends to the repaired bytes (Incremental.Track is given those, never the file's).
        var signed = Signing.Sign(session.Data, null, new SignRequest { Certificate = cert, Reason = "Approved" });
        Assert.True(signed.AsSpan(0, session.Data.Length).SequenceEqual(session.Data));
        var sig = Assert.Single(Signatures.Verify(signed, null, null, session.RepairedLength));
        Assert.Equal(SignatureStatus.Valid, sig.Status); // made on the repaired copy: checked as usual
        Assert.False(sig.InRepairedFile);
        Readable(signed);
    }

    /// <summary>Signed, then saved over a longer copy of itself: its tail holds an object, so the file is repaired, not cut.</summary>
    private static (string Signed, byte[] Damaged) SignedThenDamaged()
    {
        using var cert = SigningTests.RsaCert();
        var signed = Encoding.Latin1.GetString(Signing.Sign(Core2Pdf.Build(Objects), null, new SignRequest { Certificate = cert }));
        return (signed, Bytes(signed + "ndobj\n4 0 obj\n<< /Old true >>\nendobj\ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n" + (signed.Length - 30) + "\n%%EOF\n"));
    }

    [Fact]
    public void ASignatureMadeBeforeTheRepairIsNeverShownValid()
    {
        var (signed, damaged) = SignedThenDamaged();
        using var session = DocumentSession.FromBytes(damaged, "damaged.pdf", repair: true);
        Assert.True(session.Repaired);
        var sig = Assert.Single(Signatures.Verify(session.Data, null, null, session.RepairedLength));
        Assert.Equal(SignatureStatus.Unsupported, sig.Status);
        Assert.True(sig.InRepairedFile);
        Assert.NotNull(sig.Detail);
        Assert.Null(sig.LongTerm);
        // A file that wasn't repaired is checked as usual.
        var plain = Signatures.Verify(Bytes(signed));
        Assert.Equal(SignatureStatus.Valid, Assert.Single(plain).Status);
        Assert.Equal(SignatureStatus.Valid, Assert.Single(Signatures.Verify(Bytes(signed), null, null, repairedLength: 0)).Status);
    }

    [Fact]
    public void ARecoveredRepairedDocumentStaysRepaired()
    {
        // The recovery copy is the repaired bytes with the person's edits: sound, so opening it again repairs nothing. The
        // repair is carried in the copy's description, and the signature made before it is still not checked.
        var root = Path.Combine(Path.GetTempPath(), $"inkvolt-recovery-{Guid.NewGuid():N}");
        try
        {
            using var session = DocumentSession.FromBytes(SignedThenDamaged().Damaged, "damaged.pdf", repair: true);
            Assert.True(session.Repaired);
            Assert.Equal(PdfRepair.Outcome.AsIs, PdfRepair.Normalize(session.Data, null).Outcome);
            var store = RecoveryStore.Start(root);
            store.Write("a", session.Data, new RecoveryInfo("damaged.pdf", null, null, null, DateTime.UtcNow, 1, session.RepairedLength));
            store.Abandon();
            var left = Assert.Single(RecoveryStore.FindLeftOver(root));
            Assert.Equal(session.RepairedLength, left.Info.RepairedLength);
            using var recovered = DocumentSession.Recover(File.ReadAllBytes(left.PdfPath), null, "damaged.pdf", repairedLength: left.Info.RepairedLength);
            Assert.True(recovered.Repaired);
            Assert.Equal(session.RepairedLength, recovered.RepairedLength);
            var sig = Assert.Single(Signatures.Verify(recovered.Data, null, null, recovered.RepairedLength));
            Assert.Equal(SignatureStatus.Unsupported, sig.Status);
            Assert.True(sig.InRepairedFile);
            // A description from before the field reads as not repaired; a length past the copy's end is cut to it.
            var old = System.Text.Json.JsonSerializer.Deserialize<RecoveryInfo>("""{"DisplayName":"a.pdf","SavedUtc":"2026-11-07T00:00:00Z","Page":1}""")!;
            Assert.Equal(0, old.RepairedLength);
            using var past = DocumentSession.Recover(session.Data, null, "damaged.pdf", repairedLength: long.MaxValue);
            Assert.Equal(session.Data.LongLength, past.RepairedLength);
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
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
        Assert.True(clock.ElapsedMilliseconds < 30_000, $"{clock.ElapsedMilliseconds} ms"); // quadratic, it would take hours
    }

    /// <summary>The file cut off before its cross-reference table, with <paramref name="objects"/> in place of the usual ones.</summary>
    private static byte[] TruncatedOf(IReadOnlyList<string> objects)
    {
        var sound = Encoding.Latin1.GetString(Core2Pdf.Build(objects));
        return Bytes(sound[..(sound.IndexOf("\nxref\n", StringComparison.Ordinal) + 1)]);
    }

    /// <summary>Signed, then saved over a longer copy of itself: its tail holds an object, so the file is repaired, not cut.</summary>
    private static byte[] SavedOverALongerCopy(byte[] signed)
    {
        var s = Encoding.Latin1.GetString(signed);
        return Bytes(s + "ndobj\n4 0 obj\n<< /Old true >>\nendobj\ntrailer\n<< /Size 10 /Root 1 0 R >>\nstartxref\n" + (s.Length - 30) + "\n%%EOF\n");
    }

    [Theory]
    [InlineData("/BaseFont /BitstreamVeraSans-Roman")]
    [InlineData("/Upstream true")]
    [InlineData("/NM (livestream)")]
    [InlineData("/NM (a stream\n)")]
    [InlineData("/NM <73747265616d> /Mainstream [ (x) ]")]
    public void TheWordStreamInANameOrStringStartsNoStream(string entry)
    {
        // A stream starts at the keyword after its dictionary's ">>", followed by an end of line. Taken anywhere, it skipped
        // to the content stream's endstream and lost the field, the note and the bookmark written between.
        var objects = Objects.ToArray();
        objects[3] = $"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica {entry} /Encoding /WinAnsiEncoding >>";
        var normal = PdfRepair.Normalize(TruncatedOf(objects), null);
        Assert.True(normal.Repaired);
        Readable(normal.Data);
    }

    [Fact]
    public void ManyObjectsEndingInEndstreamAreReadInLinearTime()
    {
        // Each object's "endstream" holds the letters "stream": a search for the keyword that skipped each one walked every
        // later object, for each object.
        var sb = new StringBuilder("%PDF-1.7\n");
        for (var i = 1; i <= 300_000; i++) sb.Append($"{i} 0 obj << /A 1 >> endstream\nendobj\n");
        sb.Append("300001 0 obj << /Type /Catalog /Pages 300002 0 R >> endobj\n300002 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\n");
        var data = Bytes(sb.ToString());
        var clock = System.Diagnostics.Stopwatch.StartNew();
        Assert.NotNull(PdfRepair.Rebuild(data));
        Assert.True(clock.ElapsedMilliseconds < 30_000, $"{clock.ElapsedMilliseconds} ms");
    }

    [Fact]
    public void ManyUnclosedStringsStopTheRebuildQuickly()
    {
        // Every dictionary opens a string that never closes, so each one's reading runs over all the objects after it,
        // up to its limit: the scan's total work is capped.
        var sb = new StringBuilder("%PDF-1.7\n");
        for (var i = 1; i <= 300_000; i++) sb.Append($"{i} 0 obj << /A (\n");
        var data = Bytes(sb.ToString());
        var clock = System.Diagnostics.Stopwatch.StartNew();
        PdfRepair.Rebuild(data);
        Assert.True(clock.ElapsedMilliseconds < 30_000, $"{clock.ElapsedMilliseconds} ms");
    }

    [Fact]
    public void ASoundSignedFileWithAStaleAnnotsEntryIsLeftAsItIs()
    {
        // Page 2's /Annots names a note (6) and object 10, a note left in the file's body that its cross-reference table
        // lists at offset 0 (as some editors leave a deleted object). PDFsharp reads the file; one reference to no object
        // is no damage. A rebuild would bring the note back and show the valid signature (on page 1) as not checked.
        var objects = Objects.ToArray().Concat([
            "<< /Type /Annot /Subtype /Text /P 11 0 R /Rect [0 0 20 20] /Contents (Deleted) >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R 10 0 R] >>",
        ]).ToArray();
        objects[1] = "<< /Type /Pages /Kids [3 0 R 11 0 R] /Count 2 >>";
        objects[2] = objects[2].Replace("/Annots [5 0 R 6 0 R]", "/Annots [5 0 R]");
        var listed = Encoding.Latin1.GetString(Core2Pdf.Build(objects));
        var row = $"{listed.IndexOf("\n10 0 obj", StringComparison.Ordinal) + 1:D10} 00000 n";
        Assert.Contains(row, listed);
        var stale = Bytes(listed.Replace(row, "0000000000 00000 n"));
        Assert.Equal("Ana", Assert.Single(FormEditor.Read(stale, null)).Value);
        Assert.Contains(Annotations.Read(stale, null), a => a.Contents == "Check this");
        Assert.DoesNotContain(Annotations.Read(stale, null), a => a.Contents == "Deleted");
        using var cert = SigningTests.RsaCert();
        var signed = Signing.Sign(stale, null, new SignRequest { Certificate = cert });
        Assert.Equal(SignatureStatus.Valid, Assert.Single(Signatures.Verify(signed)).Status);

        var normal = PdfRepair.Normalize(signed, null);
        Assert.Equal(PdfRepair.Outcome.AsIs, normal.Outcome);
        Assert.Same(signed, normal.Data);
        using var session = DocumentSession.FromBytes(signed, "signed.pdf", repair: true);
        Assert.False(session.Repaired);
        Assert.Equal(SignatureStatus.Valid, Assert.Single(Signatures.Verify(session.Data, null, null, session.RepairedLength)).Status);
    }

    [Fact]
    public void AnEncryptedFileWhoseTrailerIsLostIsNotRebuilt()
    {
        // Without its trailer nothing says how the file is encrypted: a rebuild without /Encrypt had PDFsharp read the
        // ciphertext as text. The file is kept as it is (MuPDF still opens it).
        var encrypted = PdfSecurity.Protect(Core2Pdf.Build(Objects), null, "open", "owner");
        var s = Encoding.Latin1.GetString(encrypted);
        var truncated = Bytes(s[..(s.IndexOf("\nxref", StringComparison.Ordinal) + 1)]);
        Assert.DoesNotContain("trailer", Encoding.Latin1.GetString(truncated));
        var normal = PdfRepair.Normalize(truncated, "open");
        Assert.Equal(PdfRepair.Outcome.AsIs, normal.Outcome);
        Assert.Same(truncated, normal.Data);
        Assert.Null(PdfRepair.Rebuild(truncated));
    }

    [Fact]
    public void AnEncryptedFileIsRebuiltWithItsEncryptAndId()
    {
        var encrypted = Encoding.Latin1.GetString(PdfSecurity.Protect(Core2Pdf.Build(Objects), null, "open", "owner"));
        var broken = Bytes(Regex.Replace(encrypted, @"(\d{10}) 00000 n", m => $"{long.Parse(m.Groups[1].Value) + 2:D10} 00000 n"));
        Assert.ThrowsAny<Exception>(() => Readable(broken, "open"));
        var normal = PdfRepair.Normalize(broken, "open");
        Assert.True(normal.Repaired);
        var tail = Encoding.Latin1.GetString(normal.Data[broken.Length..]);
        Assert.Contains("/Encrypt ", tail);
        Assert.Contains("/ID [", tail);
        Readable(normal.Data, "open");
    }

    [Fact]
    public void AnIndirectLengthIsFollowed()
    {
        // The content stream's /Length is "10 0 R" (object 10, written after it), and its text holds "endstream" and an
        // object header. Read as a length of 1, the content ended at that "endstream" and the "5 0 obj" after it replaced the field.
        var content = "BT /Helv 12 Tf 72 650 Td (endstream) Tj (5 0 obj) Tj ET\n";
        var objects = Objects.ToArray().Append(Encoding.Latin1.GetByteCount(content).ToString()).ToArray();
        objects[8] = $"<< /Length 10 0 R >>\nstream\n{content}\nendstream";
        var normal = PdfRepair.Normalize(TruncatedOf(objects), null);
        Assert.True(normal.Repaired);
        Readable(normal.Data);
    }

    [Fact]
    public void TheAppsOwnBytesAreNotChecked()
    {
        // Combine, Extract, Scan and the rest open what the app just made: as it is, with no read of the whole file first.
        var data = Truncated();
        using (var own = DocumentSession.FromBytes(data, "made.pdf"))
        {
            Assert.False(own.Repaired);
            Assert.Same(data, own.Data);
        }
        using var outside = DocumentSession.FromBytes(data, "attachment.pdf", repair: true);
        Assert.True(outside.Repaired);
    }

    [Fact]
    public void ARepairedCopyTheViewerRefusesIsNotUsed()
    {
        // MuPDF opened the file as it is but refuses the repaired copy: the file is opened as it is, not repaired.
        var data = Truncated();
        var (bytes, engine, repaired) = DocumentSession.OpenReadable(data, MuPDFCore.InputFileTypes.PDF, null,
            b => ReferenceEquals(b, data) ? PdfEngine.Open(b, MuPDFCore.InputFileTypes.PDF, null) : throw new InvalidOperationException("refused"));
        using (engine)
        {
            Assert.Same(data, bytes);
            Assert.Equal(0, repaired);
            Assert.Equal(1, engine.PageCount);
        }
    }

    [Fact]
    public void ARepairedFileIsNeverCertified()
    {
        using var session = DocumentSession.FromBytes(Truncated(), "damaged.pdf", repair: true);
        using var cert = SigningTests.RsaCert();
        var ex = Assert.Throws<SigningException>(() => Signing.Sign(session.Data, null,
            new SignRequest { Certificate = cert, Certify = CertificationLevel.FormFilling, RepairedLength = session.RepairedLength }));
        Assert.Contains("repaired", ex.Message);
    }

    [Fact]
    public async Task LongTermDataIsNeverAddedForASignatureMadeBeforeTheRepair()
    {
        using var pki = new LtvTestPki();
        var damaged = SavedOverALongerCopy(Signing.Sign(Core2Pdf.Build(Objects), null, new SignRequest { Certificate = pki.Signer }));
        using var session = DocumentSession.FromBytes(damaged, "damaged.pdf", repair: true);
        Assert.True(session.Repaired);
        using (var client = pki.Client())
        {
            var ex = await Assert.ThrowsAsync<SigningException>(() => Ltv.AddVerificationAsync(session.Data, null, client, repairedLength: session.RepairedLength));
            Assert.Contains("repaired", ex.Message);
        }

        // Batch: the file is skipped, saying why.
        var dir = Directory.CreateTempSubdirectory("inkvolt-damaged-batch-").FullName;
        try
        {
            var path = Path.Combine(dir, "damaged.pdf");
            File.WriteAllBytes(path, damaged);
            var plan = new BatchPlan { Steps = [new AddLongTermStep()], OutputFolder = Path.Combine(dir, "out") };
            var summary = await BatchRunner.RunAsync([new BatchFile(path)], plan, new BatchHost { LongTermClient = () => pki.Client() }, null, CancellationToken.None);
            var item = Assert.Single(summary.Items);
            Assert.Equal(BatchItemState.Skipped, item.State);
            Assert.Contains("repaired", item.Message);
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}

/// <summary>
/// A repair's bound on a hostile object stream (<see cref="PdfRepair.Rebuild"/>), timed, so alone: under the full suite's
/// load it took 38 s against 2 s by itself.
/// </summary>
[Collection(Timing.Alone)]
public sealed class DamagedFileTimingTests
{
    [Fact]
    public void AHostileObjectStreamIsReadQuickly()
    {
        // /N says 2 billion objects, and 5 million pairs all name object 1 (20 MB decoded, a few KB in the file).
        const int pairs = 5_000_000;
        var header = new StringBuilder(pairs * 4);
        for (var i = 0; i < pairs; i++) header.Append("1 0 ");
        var content = Encoding.Latin1.GetBytes(header + "<< /Type /Catalog /Pages 2 0 R >>");
        using var packed = new MemoryStream();
        using (var z = new System.IO.Compression.ZLibStream(packed, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true)) z.Write(content);
        var data = (byte[])[.. Encoding.Latin1.GetBytes($"%PDF-1.7\n3 0 obj\n<< /Type /ObjStm /N 2147483647 /First {pairs * 4} /Filter /FlateDecode /Length {packed.Length} >>\nstream\n"),
            .. packed.ToArray(), .. Encoding.Latin1.GetBytes("\nendstream\nendobj\n2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")];
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var allocated = GC.GetAllocatedBytesForCurrentThread();
        PdfRepair.Rebuild(data);
        allocated = GC.GetAllocatedBytesForCurrentThread() - allocated;
        // The decoded bytes, not a match per pair: matching every pair allocated GBs and took 17 to 26 s.
        Assert.True(allocated < 300 << 20, $"{allocated >> 20} MB");
        Assert.True(clock.Elapsed < Timing.Limit(TimeSpan.FromSeconds(10)), $"{clock.Elapsed}"); // 2 s here
    }
}
