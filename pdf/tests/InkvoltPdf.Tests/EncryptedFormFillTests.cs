using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using PdfSharp.Pdf.IO;
using PdfSharp.Pdf.Security;

namespace InkvoltPdf.Tests;

/// <summary>
/// Encrypted forms whose permissions allow filling (USCIS, OPM): filled with the user password, as Acrobat, Nitro and
/// Preview do, and saved as an incremental update that keeps the original encryption, /Encrypt and /ID. The permissions
/// (owner) password is never needed for what /P allows, and still is for the rest.
/// </summary>
public class EncryptedFormFillTests
{
    private static byte[] Plain() => Core2Pdf.Form(
    [
        "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P 3 0 R >>",
        "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /Rect [72 650 90 668] /V /Off /AS /Off /F 4 /P 3 0 R /MK << /CA (4) >> >>",
    ]);

    /// <summary>The form protected by PDFsharp: owner password "own", the given user password, only what is asked allowed.</summary>
    private static byte[] Protect(string method, bool fill, bool annotate, string user = "", byte[]? plain = null)
    {
        using var doc = PdfReader.Open(new MemoryStream(plain ?? Plain()), PdfDocumentOpenMode.Modify);
        var h = doc.SecurityHandler;
        switch (method)
        {
            case "rc4-40": h.SetEncryptionToV1(); break;
            case "rc4-128": h.SetEncryptionToV2(128); break;
            case "rc4-v4": h.SetEncryptionToV4UsingRC4(); break;
            case "aes-128": h.SetEncryptionToV4UsingAES(); break;
            case "aes-256": h.SetEncryptionToV5(); break;
            default: throw new ArgumentException(method);
        }
        var s = doc.SecuritySettings;
        s.UserPassword = user;
        s.OwnerPassword = "own";
        s.PermitModifyDocument = false;
        s.PermitAssembleDocument = false;
        s.PermitAnnotations = annotate;
        s.PermitFormsFill = fill;
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    private static string? ValueByPdfSharp(byte[] data, string password = "")
    {
        using var doc = PdfReader.Open(new MemoryStream(data), password, PdfDocumentOpenMode.Import);
        return Core2Pdf.Field(doc, "name")?.Elements.GetString("/V");
    }

    [Theory]
    [InlineData("rc4-40")]
    [InlineData("rc4-128")]
    [InlineData("rc4-v4")]
    [InlineData("aes-128")]
    [InlineData("aes-256")]
    public void AFormThatAllowsFillingIsFilledWithoutTheOwnerPasswordAndStaysEncrypted(string method)
    {
        var data = Protect(method, fill: true, annotate: false);
        var before = PdfSecurity.ReadSecurity(data, null);

        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["name"] = "Filled One", ["agree"] = "On" }).Data;

        // An incremental update: the original bytes, untouched, then the new objects, encrypted with the file key.
        Assert.True(filled.AsSpan(0, data.Length).SequenceEqual(data));
        var update = Encoding.Latin1.GetString(filled, data.Length, filled.Length - data.Length);
        Assert.DoesNotContain("Filled One", update);
        Assert.DoesNotContain(Convert.ToHexString(Encoding.Latin1.GetBytes("Filled One")), update, StringComparison.OrdinalIgnoreCase);
        Assert.Contains("/Encrypt", update);
        Assert.Equal(Incremental.Tail(data)!.Id, Incremental.Tail(filled)!.Id);

        // Same protection; MuPDF, PDFsharp and Inkvolt read the value.
        var after = PdfSecurity.ReadSecurity(filled, null);
        Assert.Equal(before, after);
        Assert.Contains("Filled One", Core2Pdf.AllText(filled));
        Assert.Equal("Filled One", ValueByPdfSharp(filled));
        var widgets = FormEditor.Read(filled, null);
        Assert.Equal("Filled One", widgets.Single(w => w.FieldName == "name").Value);
        Assert.NotEqual("Off", widgets.Single(w => w.FieldName == "agree").Value);

        // A later fill appends again.
        var again = FormEditor.Fill(filled, null, new Dictionary<string, string> { ["name"] = "Filled Two" }).Data;
        Assert.True(again.AsSpan(0, filled.Length).SequenceEqual(filled));
        Assert.Equal("Filled Two", ValueByPdfSharp(again));
        Assert.Contains("Filled Two", Core2Pdf.AllText(again));
        Assert.Equal(before, PdfSecurity.ReadSecurity(again, null));
    }

    [Fact]
    public void TheAnnotateBitAloneAllowsFilling()
    {
        var data = Protect("aes-128", fill: false, annotate: true);
        var filled = FormEditor.Fill(data, null, new Dictionary<string, string> { ["name"] = "By annotate" }).Data;
        Assert.Equal("By annotate", ValueByPdfSharp(filled));

        // ...and comments, which filling alone doesn't.
        var noted = Annotations.AddNote(filled, null, 0, 300, 80, "A note", "Ana", AnnotColor.Yellow, "n1");
        Assert.True(noted.AsSpan(0, filled.Length).SequenceEqual(filled));
        Assert.Contains(Annotations.Read(noted, null), a => a.Contents == "A note");
        Assert.Throws<OwnerPasswordRequiredException>(() =>
            Annotations.AddNote(Protect("aes-128", fill: true, annotate: false), null, 0, 300, 80, "A note", "Ana", AnnotColor.Yellow, "n1"));
    }

    [Fact]
    public void AFormWithAnOpenPasswordIsFilledWithIt()
    {
        var data = Protect("aes-256", fill: true, annotate: false, user: "open");
        var filled = FormEditor.Fill(data, "open", new Dictionary<string, string> { ["name"] = "With open" }).Data;
        Assert.True(filled.AsSpan(0, data.Length).SequenceEqual(data));
        Assert.Equal("With open", ValueByPdfSharp(filled, "open"));
        Assert.True(PdfSecurity.ReadSecurity(filled, "open").RequiresOpenPassword);
    }

    [Fact]
    public void AFileWhoseUpdatesDontRepeatTheEncryptionDictionaryOpens()
    {
        // Acrobat's updates name the original /Encrypt object without writing it again; PDFsharp alone can't read the
        // third such trailer. Two such updates, each writing the page tree root again.
        var data = Protect("aes-128", fill: true, annotate: false);
        var acrobat = AppendPagesAgain(AppendPagesAgain(data));
        Assert.ThrowsAny<InvalidOperationException>(() => ValueByPdfSharp(acrobat));
        Assert.Equal("Alice", FormEditor.Read(acrobat, null).Single(w => w.FieldName == "name").Value);
        var filled = FormEditor.Fill(acrobat, null, new Dictionary<string, string> { ["name"] = "Three" }).Data;
        Assert.Equal("Three", ValueByPdfSharp(filled)); // our update writes the encryption dictionary again
        Assert.Contains("Three", Core2Pdf.AllText(filled));
    }

    [Fact]
    public void AFormTheUserPasswordPathCantCopyAsksForTheOwnerPassword()
    {
        // An object nested deeper than a copy is written (PDFsharp reads it): the copy fails, and the person is asked for
        // the owner password as for anything else the user password can't do, never shown the raw failure.
        var deep = new string('[', 300) + new string(']', 300);
        var plain = Core2Pdf.Form(
            ["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P 3 0 R >>"],
            catalogExtra: "/Deep 6 0 R", more: [deep]);
        var data = Protect("aes-128", fill: true, annotate: false, plain: plain);
        Assert.Equal("Alice", FormEditor.Read(data, null).Single().Value);
        Assert.Throws<OwnerPasswordRequiredException>(() => FormEditor.Fill(data, null, new Dictionary<string, string> { ["name"] = "x" }));
    }

    [Fact]
    public void AnEncryptedFormIsNotTakenForDamagedAsItOpens()
    {
        // The document's bytes are normalized once as it opens: a sound encrypted form, also one whose updates don't
        // repeat the encryption dictionary, is read as it is (a repair would say so, and stop its signatures checking).
        var data = Protect("aes-128", fill: true, annotate: false);
        Assert.Equal(PdfRepair.Outcome.AsIs, PdfRepair.Normalize(data, null).Outcome);
        Assert.Equal(PdfRepair.Outcome.AsIs, PdfRepair.Normalize(AppendPagesAgain(AppendPagesAgain(data)), null).Outcome);
        Assert.Equal(PdfRepair.Outcome.AsIs, PdfRepair.Normalize(Protect("aes-256", fill: true, annotate: false, user: "open"), "open").Outcome);
    }

    [Theory]
    [InlineData("rc4-128")]
    [InlineData("aes-256")]
    public void ADamagedEncryptedFormIsRepairedThenFilledWithTheUserPassword(string method)
    {
        // Every xref row off by two bytes: the repair rebuilds the cross-reference, carrying /Encrypt and /ID, and the
        // repaired bytes are filled through the user password as a sound file is.
        var data = Protect(method, fill: true, annotate: false);
        var broken = Encoding.Latin1.GetBytes(System.Text.RegularExpressions.Regex.Replace(Encoding.Latin1.GetString(data),
            @"(\d{10}) 00000 n", m => $"{long.Parse(m.Groups[1].Value) + 2:D10} 00000 n"));
        var normal = PdfRepair.Normalize(broken, null);
        Assert.True(normal.Repaired);
        Assert.Equal("Alice", FormEditor.Read(normal.Data, null).Single(w => w.FieldName == "name").Value);

        var filled = FormEditor.Fill(normal.Data, null, new Dictionary<string, string> { ["name"] = "Repaired" }).Data;
        Assert.True(filled.AsSpan(0, normal.Data.Length).SequenceEqual(normal.Data));
        Assert.DoesNotContain("Repaired", Encoding.Latin1.GetString(filled, normal.Data.Length, filled.Length - normal.Data.Length));
        Assert.Equal("Repaired", ValueByPdfSharp(filled));
        Assert.Equal(PdfSecurity.ReadSecurity(data, null), PdfSecurity.ReadSecurity(filled, null));
    }

    [Fact]
    public void AnEncryptionDictionaryIsWrittenAgainWithItsIndirectValues()
    {
        // An encryption dictionary whose /Length and /CF are indirect objects (legal; PDFsharp's reader refuses them, but
        // a dictionary written again must never lose them): they keep their original objects, which stay in the file.
        using var doc = new PdfSharp.Pdf.PdfDocument();
        var length = new PdfSharp.Pdf.PdfIntegerObject(doc, 128);
        doc.Internals.AddObject(length);
        var cf = new PdfSharp.Pdf.PdfDictionary(doc);
        cf.Elements["/StdCF"] = new PdfSharp.Pdf.PdfDictionary();
        doc.Internals.AddObject(cf);
        var h = new PdfSharp.Pdf.PdfDictionary(doc);
        h.Elements["/Filter"] = new PdfSharp.Pdf.PdfName("/Standard");
        h.Elements["/Length"] = length.Reference;
        h.Elements["/CF"] = cf.Reference;
        h.Elements["/O"] = new PdfSharp.Pdf.PdfString(new string([(char)0xE9, (char)1]), PdfSharp.Pdf.PdfStringEncoding.RawEncoding);
        var body = Encoding.Latin1.GetString(UserPasswordEdits.EncryptBody(h)!);
        Assert.Contains($"/Length {length.Reference!.ObjectNumber} 0 R", body);
        Assert.Contains($"/CF {cf.Reference!.ObjectNumber} 0 R", body);
        Assert.Contains("/O <E901>", body);
        Assert.DoesNotContain("null", body);

        // A string that wouldn't read back byte for byte (text beyond Latin-1, even inside /CF): not written again.
        var std = new PdfSharp.Pdf.PdfDictionary();
        std.Elements["/X"] = new PdfSharp.Pdf.PdfString(new string((char)0x4E2D, 1), PdfSharp.Pdf.PdfStringEncoding.Unicode);
        var direct = new PdfSharp.Pdf.PdfDictionary();
        direct.Elements["/StdCF"] = std;
        h.Elements["/CF"] = direct;
        Assert.Null(UserPasswordEdits.EncryptBody(h));
    }

    /// <summary>An update holding the page tree root unchanged (it has no strings to encrypt), as Acrobat writes one.</summary>
    private static byte[] AppendPagesAgain(byte[] file)
    {
        var text = Encoding.Latin1.GetString(file);
        string Ref(string key) => System.Text.RegularExpressions.Regex.Match(text, key + @"\s*(\d+) 0 R").Groups[1].Value;
        var pages = Ref("/Pages");
        var body = System.Text.RegularExpressions.Regex.Match(text, $@"\n{pages} 0 obj\s*(<<.*?>>)\s*endobj", System.Text.RegularExpressions.RegexOptions.Singleline).Groups[1].Value;
        var tail = Incremental.Tail(file)!;
        var at = file.Length;
        var obj = $"{pages} 0 obj\n{body}\nendobj\n";
        var update = obj + $"xref\n{pages} 1\n{at:D10} 00000 n \ntrailer\n<< /Size {tail.Size} /Root {Ref("/Root")} 0 R /Encrypt {Ref("/Encrypt")} 0 R " +
                     $"/ID {tail.Id} /Prev {tail.StartXref} >>\nstartxref\n{at + obj.Length}\n%%EOF\n";
        return [.. file, .. Encoding.Latin1.GetBytes(update)];
    }

    [Theory]
    [InlineData("rc4-128")]
    [InlineData("aes-128")]
    [InlineData("aes-256")]
    public void ATrailerWhoseSizeIsTooSmallLosesNothing(string method)
    {
        // The newest section names an encryption dictionary with the file's highest number, and a /Size that doesn't count
        // it: the decrypted copy leaves it out, so a new object mustn't take its number: /Encrypt would lead to that object.
        var data = Protect(method, fill: true, annotate: false);
        var text = Encoding.Latin1.GetString(data);
        var encrypt = Regex.Match(text, @"/Encrypt (\d+) 0 R").Groups[1].Value;
        var body = Regex.Match(text, $@"\n{encrypt} 0 obj\s*(<<.*?>>)\s*endobj", RegexOptions.Singleline).Groups[1].Value;
        var root = Regex.Match(text, @"/Root (\d+) 0 R").Groups[1].Value;
        var highest = Regex.Matches(text, @"(\d+) 0 obj").Max(m => int.Parse(m.Groups[1].Value)) + 1;
        var tail = Incremental.Tail(data)!;
        var obj = $"{highest} 0 obj\n{body}\nendobj\n";
        var low = Encoding.Latin1.GetBytes(text + obj + $"xref\n{highest} 1\n{data.Length:D10} 00000 n \ntrailer\n<< /Size 2 /Root {root} 0 R /Encrypt {highest} 0 R " +
                                           $"/ID {tail.Id} /Prev {tail.StartXref} >>\nstartxref\n{data.Length + obj.Length}\n%%EOF\n");
        Assert.Equal("Alice", FormEditor.Read(low, null).Single(w => w.FieldName == "name").Value);

        var filled = FormEditor.Fill(low, null, new Dictionary<string, string> { ["name"] = "Low size" }).Data;

        Assert.True(filled.AsSpan(0, low.Length).SequenceEqual(low));
        Assert.Equal("Low size", FormEditor.Read(filled, null).Single(w => w.FieldName == "name").Value);
        Assert.Contains("Low size", Core2Pdf.AllText(filled));
        Assert.Equal(PdfSecurity.ReadSecurity(data, null), PdfSecurity.ReadSecurity(filled, null));
    }

    [Fact]
    public void APermissionsValueChangedInAnAes256FileIsNotBelieved()
    {
        // At AES-256 /P isn't in the key: /Perms holds the real value, encrypted (algorithm 13). PDFsharp checks it as it
        // opens the file: one edited to allow filling isn't filled.
        var data = Protect("aes-256", fill: false, annotate: false);
        var text = Encoding.Latin1.GetString(data);
        var p = Regex.Match(text, @"/P (-\d+)");
        var allowed = (int.Parse(p.Groups[1].Value) | (1 << 8)).ToString(System.Globalization.CultureInfo.InvariantCulture).PadRight(p.Groups[1].Length);
        var edited = Encoding.Latin1.GetBytes(text.Remove(p.Groups[1].Index, allowed.Length).Insert(p.Groups[1].Index, allowed));
        Assert.ThrowsAny<InvalidOperationException>(() => FormEditor.Fill(edited, null, new Dictionary<string, string> { ["name"] = "x" }));
    }

    [Fact]
    public void WhatThePermissionsDontAllowStillNeedsTheOwnerPassword()
    {
        var noFill = Protect("rc4-128", fill: false, annotate: false);
        Assert.Throws<OwnerPasswordRequiredException>(() => FormEditor.Fill(noFill, null, new Dictionary<string, string> { ["name"] = "x" }));

        var fillOnly = Protect("aes-128", fill: true, annotate: false);
        Assert.Throws<OwnerPasswordRequiredException>(() => PageEditor.Rotate(fillOnly, null, [0], 90));
        Assert.Throws<OwnerPasswordRequiredException>(() => TextStamps.Put(fillOnly, null, 0, new RectD(10, 10, 50, 20), StampKind.Text, "x", 11));

        // Opened for filling, the document is never written whole (that would drop the encryption).
        using (var doc = PdfObj.Open(fillOnly, null, PdfDocumentOpenMode.Modify, null, UserEdit.FillForms))
            Assert.Throws<OwnerPasswordRequiredException>(() => PdfObj.Save(doc, rewrite: true));

        // With it, the edit works as before.
        var filled = FormEditor.Fill(noFill, "own", new Dictionary<string, string> { ["name"] = "Owner" }).Data;
        Assert.Equal("Owner", ValueByPdfSharp(filled));
    }
}
