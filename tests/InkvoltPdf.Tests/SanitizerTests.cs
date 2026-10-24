using System.Text;
using MuPDFCore;
using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

public class SanitizerTests
{
    private static readonly HashSet<SanitizeItem> All = [.. Enum.GetValues<SanitizeItem>()];

    private const string Xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
                               "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator><rdf:Seq><rdf:li>Jane Doe</rdf:li></rdf:Seq></dc:creator></rdf:Description>" +
                               "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>";

    /// <summary>
    /// One page holding one of everything Sanitize removes (numbers in the comments are the object numbers): metadata
    /// (Info with 4 entries, 2 XMP packets, 2 PieceInfo), a hidden layer drawing text, a vector box and a form XObject, an
    /// annotation in that layer, 2 hidden annotations (one a filled field), a comment with its popup, 3 filled fields, a
    /// bookmark leading to a web page, a thumbnail, 11 pieces of active content, 2 external links and 3 embedded files.
    /// </summary>
    internal static byte[] Dirty(string pageContent = "", string extraResources = "")
    {
        var content = "BT /F1 12 Tf 72 700 Td (Visible text) Tj ET /OC /L1 BDC BT /F1 12 Tf 72 650 Td (Shown layer) Tj ET EMC " +
                      "/OC /L2 BDC 1 0 0 rg BT /F1 12 Tf 72 600 Td (Secret layer) Tj ET 0 0 100 100 re f EMC q /Sec Do Q q 10 0 0 10 300 300 cm /Im Do Q " + pageContent;
        string[] objects =
        [
            /* 1 */ "<< /Type /Catalog /Pages 2 0 R /Metadata 7 0 R /OpenAction 8 0 R /AA << /WC 10 0 R >> /Names << /JavaScript 11 0 R /EmbeddedFiles 13 0 R >> " +
                    "/Outlines 16 0 R /PageMode /UseOutlines /OCProperties << /OCGs [18 0 R 19 0 R] /D << /OFF [19 0 R] /Order [18 0 R 19 0 R] >> >> " +
                    "/AcroForm << /Fields [23 0 R 25 0 R 26 0 R 40 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 5 0 R >> >> /XFA 27 0 R >> " +
                    "/PieceInfo << /Illustrator << /Private (catalog private) >> >> /AF [14 0 R] >>",
            /* 2 */ "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            /* 3 */ "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Thumb 21 0 R /AA << /O 22 0 R >> " +
                    "/PieceInfo << /App << /Private (page private) >> >> /LastModified (D:20200101) " +
                    $"/Resources << /Font << /F1 5 0 R >> /Properties << /L1 18 0 R /L2 19 0 R >> /XObject << /Sec 20 0 R /Im 38 0 R >> {extraResources} >> " +
                    "/Annots [23 0 R 25 0 R 26 0 R 28 0 R 29 0 R 30 0 R 31 0 R 32 0 R 33 0 R 34 0 R 35 0 R 36 0 R 37 0 R 40 0 R] >>",
            /* 4 */ Core2Pdf.Stream(content),
            /* 5 */ "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            /* 6 */ "<< /Title (Secret title) /Author (Jane Doe) /Producer (Word) /Custom (internal) >>",
            /* 7 */ Core2Pdf.Stream(Xmp, "/Type /Metadata /Subtype /XML"),
            /* 8 */ "<< /S /JavaScript /JS (app.alert\\(1\\)) /Next 9 0 R >>",
            /* 9 */ "<< /S /GoTo /D [3 0 R /Fit] >>",
            /* 10 */ "<< /S /JavaScript /JS (willClose\\(\\)) >>",
            /* 11 */ "<< /Names [(init) 12 0 R] >>",
            /* 12 */ "<< /S /JavaScript /JS (docInit\\(\\)) >>",
            /* 13 */ "<< /Names [(a.txt) 14 0 R] >>",
            /* 14 */ "<< /Type /Filespec /F (a.txt) /UF (a.txt) /EF << /F 15 0 R >> >>",
            /* 15 */ Core2Pdf.Stream("attached secret", "/Type /EmbeddedFile"),
            /* 16 */ "<< /Type /Outlines /First 17 0 R /Last 17 0 R /Count 1 >>",
            /* 17 */ "<< /Title (Chapter) /Parent 16 0 R /A << /S /URI /URI (https://example.com/outline) >> >>",
            /* 18 */ "<< /Type /OCG /Name (Shown) >>",
            /* 19 */ "<< /Type /OCG /Name (Hidden notes) >>",
            /* 20 */ Core2Pdf.Stream("BT /F1 12 Tf 72 500 Td (Secret form) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /OC 19 0 R /Resources << /Font << /F1 5 0 R >> >>"),
            /* 21 */ Core2Pdf.Stream("abcdefghijkl", "/Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8"),
            /* 22 */ "<< /S /JavaScript /JS (pageOpen\\(\\)) >>",
            /* 23 */ "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /V (John Smith) /Rect [72 400 272 420] /P 3 0 R /F 4 /DA (/Helv 12 Tf 0 g) /AA << /K 24 0 R >> >>",
            /* 24 */ "<< /S /JavaScript /JS (AFNumber_Keystroke\\(2\\)) >>",
            /* 25 */ "<< /Type /Annot /Subtype /Widget /FT /Tx /T (hiddenfield) /V (hidden data) /Rect [72 300 272 320] /P 3 0 R /F 2 /DA (/Helv 12 Tf 0 g) >>",
            /* 26 */ "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (send) /Rect [300 400 400 420] /P 3 0 R /F 4 /A << /S /SubmitForm /F << /FS /URL /F (https://example.com/submit) >> >> >>",
            /* 27 */ Core2Pdf.Stream("<xdp:xdp xmlns:xdp=\"http://ns.adobe.com/xdp/\"/>"),
            /* 28 */ "<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (Private comment) /Popup 29 0 R /F 4 >>",
            /* 29 */ "<< /Type /Annot /Subtype /Popup /Rect [520 600 600 700] /Parent 28 0 R >>",
            /* 30 */ "<< /Type /Annot /Subtype /Link /Rect [72 690 200 710] /A << /S /JavaScript /JS (evil\\(\\)) >> >>",
            /* 31 */ "<< /Type /Annot /Subtype /Link /Rect [72 640 200 660] /A << /S /URI /URI (https://example.com/link) >> >>",
            /* 32 */ "<< /Type /Annot /Subtype /Link /Rect [72 590 200 610] /A << /S /Launch /F (calc.exe) >> >>",
            /* 33 */ "<< /Type /Annot /Subtype /FileAttachment /Rect [550 500 570 520] /FS 14 0 R /Contents (attachment) >>",
            /* 34 */ "<< /Type /Annot /Subtype /Square /Rect [400 100 450 150] /F 2 /Contents (hidden square) >>",
            /* 35 */ "<< /Type /Annot /Subtype /Square /Rect [400 200 450 250] /OC 19 0 R /Contents (layer square) >>",
            /* 36 */ "<< /Type /Annot /Subtype /RichMedia /Rect [100 100 200 200] >>",
            /* 37 */ "<< /Type /Annot /Subtype /Sound /Rect [220 100 240 120] >>",
            /* 38 */ Core2Pdf.Stream("abcdefghijkl", "/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Metadata 39 0 R"),
            /* 39 */ Core2Pdf.Stream("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"/>", "/Type /Metadata /Subtype /XML"),
            /* 40 */ "<< /Type /Annot /Subtype /Widget /FT /Btn /T (agree) /V /Yes /AS /Yes /Rect [72 200 82 210] /P 3 0 R /F 4 /AP << /N << /Yes 41 0 R /Off 42 0 R >> >> >>",
            /* 41 */ Core2Pdf.Stream("0 0 1 rg 0 0 10 10 re f", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
            /* 42 */ Core2Pdf.Stream("", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
            /* 43 */ "<< /Unused (orphan data) >>",
        ];
        return Core2Pdf.Build(objects, "/Info 6 0 R");
    }

    /// <summary>Everything in the file as text: its bytes plus every stream decoded, to look for what must be gone.</summary>
    private static string Everything(byte[] data, string? password = null)
    {
        var sb = new StringBuilder(Encoding.Latin1.GetString(data));
        using var doc = password is null ? PdfReader.Open(new MemoryStream(data), PdfDocumentOpenMode.Import) : PdfReader.Open(new MemoryStream(data), password, PdfDocumentOpenMode.Import);
        foreach (var o in doc.Internals.GetAllObjects())
        {
            sb.Append(o).Append('\n');
            if (o is PdfDictionary { Stream: not null } d) sb.Append(Encoding.Latin1.GetString(d.Stream.UnfilteredValue)).Append('\n');
        }
        return sb.ToString();
    }

    private static string PageText(byte[] data, string? password = null)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        return engine.GetText(0).Text;
    }

    /// <summary>With INKVOLTPDF_SAMPLES set, <see cref="Dirty"/> is written there (sanitize-sample.pdf) for the app.</summary>
    [Fact]
    public void ScanCountsEachKind()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "sanitize-sample.pdf"), Dirty());
        }
        var scan = Sanitizer.Scan(Dirty(), null);
        Assert.Equal(8, scan[SanitizeItem.Metadata]); // 4 Info entries, 2 XMP packets, 2 PieceInfo
        Assert.Equal(1, scan[SanitizeItem.HiddenLayers]);
        Assert.Equal(2, scan[SanitizeItem.HiddenAnnotations]);
        Assert.Equal(1, scan[SanitizeItem.Comments]); // the popup goes with its note
        Assert.Equal(3, scan[SanitizeItem.FormValues]); // the hidden field's value too; the push button has none
        Assert.Equal(1, scan[SanitizeItem.Bookmarks]);
        Assert.Equal(1, scan[SanitizeItem.Thumbnails]);
        // Open action, document will-close, document script, page open, keystroke, link script, Launch, SubmitForm,
        // RichMedia, Sound, XFA.
        Assert.Equal(11, scan[SanitizeItem.ActiveContent]);
        Assert.Equal(2, scan[SanitizeItem.ExternalLinks]); // a link and the bookmark's action
        Assert.Equal(3, scan[SanitizeItem.EmbeddedFiles]); // name tree, attachment annotation, /AF
        Assert.Equal(0, scan[SanitizeItem.Signatures]);
        Assert.True(scan.UnusedObjects >= 1);
        Assert.Equal(0, scan.EarlierRevisions);
        Assert.False(scan.IsClean);
    }

    [Fact]
    public void RemovesEverythingAndRescansClean()
    {
        var pdf = Dirty();
        var result = Sanitizer.Sanitize(pdf, null, All);
        var before = Sanitizer.Scan(pdf, null);
        // The hidden field went as a hidden annotation before its value was counted, the bookmark before its web address.
        foreach (var item in All)
            Assert.True(before[item] - (item is SanitizeItem.FormValues or SanitizeItem.ExternalLinks ? 1 : 0) == result.Removed[item], $"{item}: {before[item]} found, {result.Removed[item]} removed");
        Assert.NotNull(result.Remaining);
        Assert.True(result.Remaining!.IsClean, string.Join(", ", result.Remaining.Counts.Where(c => c.Value > 0)));
        Assert.Equal(0, result.Remaining.UnusedObjects);
        Assert.Empty(result.Removed.Notes);

        // The page still shows what it showed; what was hidden is gone from the file, not just from view.
        var text = PageText(result.Data);
        Assert.Contains("Visible text", text);
        Assert.Contains("Shown layer", text);
        var all = Everything(result.Data);
        foreach (var secret in new[] { "Secret layer", "Secret form", "Hidden notes", "Secret title", "Jane Doe", "Word", "internal", "attached secret", "John Smith",
                     "hidden data", "app.alert", "docInit", "pageOpen", "AFNumber", "evil", "calc.exe", "example.com", "Private comment", "private", "orphan", "xdp" })
            Assert.False(all.Contains(secret, StringComparison.Ordinal), $"still in the file: {secret}");

        using var doc = Core2Pdf.Open(result.Data);
        var catalog = doc.Internals.Catalog;
        foreach (var key in new[] { "/AA", "/Outlines", "/PieceInfo", "/AF", "/PageMode" }) Assert.False(catalog.Elements.ContainsKey(key), key);
        Assert.Single(PdfObj.Array(PdfObj.Dict(catalog.Elements["/OCProperties"])!.Elements["/OCGs"])!.Elements); // the layer that shows
        Assert.Equal("GoTo", PdfObj.Name(PdfObj.Dict(catalog.Elements["/OpenAction"])!.Elements["/S"])); // the script before it went
        var page = doc.Pages[0];
        Assert.False(page.Elements.ContainsKey("/Thumb"));
        Assert.False(page.Elements.ContainsKey("/AA"));
        // Left: the visible text field (emptied), the push button (without its action) and the check box (off).
        var annots = PdfObj.Array(page.Elements["/Annots"])!.Elements.Select(PdfObj.Dict).ToList();
        Assert.Equal(["name", "send", "agree"], annots.Select(a => PdfObj.Str(a!.Elements["/T"])));
        Assert.Equal("Off", PdfObj.Name(annots[2]!.Elements["/AS"]));
        Assert.False(annots[1]!.Elements.ContainsKey("/A"));
        var fields = PdfObj.Array(PdfObj.Dict(catalog.Elements["/AcroForm"])!.Elements["/Fields"])!;
        Assert.Equal(3, fields.Elements.Count); // the hidden field went with its widget
        Assert.False(PdfObj.Dict(catalog.Elements["/AcroForm"])!.Elements.ContainsKey("/XFA"));
        // The XMP packet left says only which program wrote the file.
        Assert.DoesNotContain("ModifyDate", all);
        Assert.DoesNotContain("DocumentID", all);
    }

    [Fact]
    public void RemovesOnlyWhatIsChosen()
    {
        var result = Sanitizer.Sanitize(Dirty(), null, new HashSet<SanitizeItem> { SanitizeItem.ActiveContent });
        Assert.Equal(11, result.Removed[SanitizeItem.ActiveContent]);
        Assert.Equal(0, result.Removed[SanitizeItem.Comments]);
        var left = result.Remaining!;
        Assert.Equal(0, left[SanitizeItem.ActiveContent]);
        Assert.Equal(1, left[SanitizeItem.Comments]);
        Assert.Equal(2, left[SanitizeItem.ExternalLinks]);
        Assert.Equal(1, left[SanitizeItem.Bookmarks]);
        Assert.Equal(1, left[SanitizeItem.HiddenLayers]);
        Assert.Equal(3, left[SanitizeItem.FormValues]);
        Assert.Contains("Secret title", Everything(result.Data));

        // The open action's script went; the page it then went to stays.
        using var doc = Core2Pdf.Open(result.Data);
        var open = PdfObj.Dict(doc.Internals.Catalog.Elements["/OpenAction"])!;
        Assert.Equal("GoTo", PdfObj.Name(open.Elements["/S"]));
        Assert.False(open.Elements.ContainsKey("/Next"));
        // The link that ran a script (and so leads nowhere now) went; the web link stays.
        var subtypes = PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements.Select(e => PdfObj.NameOf(PdfObj.Dict(e)!, "/Subtype")).ToList();
        Assert.Equal(1, subtypes.Count(s => s == "/Link"));
        Assert.DoesNotContain("/RichMedia", subtypes);
    }

    [Fact]
    public void ExternalLinksLeaveBookmarksInPlace()
    {
        var result = Sanitizer.Sanitize(Dirty(), null, new HashSet<SanitizeItem> { SanitizeItem.ExternalLinks });
        Assert.Equal(2, result.Removed[SanitizeItem.ExternalLinks]);
        using var doc = Core2Pdf.Open(result.Data);
        var outlines = PdfObj.Dict(doc.Internals.Catalog.Elements["/Outlines"])!;
        var item = PdfObj.Dict(outlines.Elements["/First"])!;
        Assert.Equal("Chapter", PdfObj.Str(item.Elements["/Title"]));
        Assert.False(item.Elements.ContainsKey("/A"));
        Assert.Equal(1, result.Remaining![SanitizeItem.Bookmarks]);
    }

    [Fact]
    public void HiddenLayerContentGoesButItsStateStays()
    {
        // Inside a text object: hidden text followed by text placed from a new position is cut, its Td kept.
        var cut = HiddenContent.Strip("BT /F1 12 Tf 72 700 Td (A) Tj /OC /H BDC 0 -20 Td (Secret) Tj EMC 0 -20 Td (B) Tj ET"u8.ToArray(), t => t == "H", _ => false, out var kept);
        Assert.Null(kept);
        var text = Encoding.Latin1.GetString(cut!);
        Assert.DoesNotContain("Secret", text);
        Assert.Contains("0 -20 Td\n", text);
        Assert.Contains("(B) Tj", text);

        // Visible text placed right after the hidden text relies on its width: that section stays.
        Assert.Null(HiddenContent.Strip("BT /F1 12 Tf 72 700 Td /OC /H BDC (Secret) Tj EMC (B) Tj ET"u8.ToArray(), t => t == "H", _ => false, out kept));
        Assert.NotNull(kept);

        // Clipping, color and q/Q survive; drawing doesn't. ' becomes a line move.
        cut = HiddenContent.Strip("/OC /H BDC q 0 0 50 50 re W n 1 0 0 rg 0 0 100 100 re f /Img Do Q EMC (after) Tj"u8.ToArray(), t => t == "H", _ => false, out kept);
        text = Encoding.Latin1.GetString(cut!);
        Assert.Null(kept);
        Assert.Contains("q\n0 0 50 50 re\nW\nn\n1 0 0 rg\nQ\n", text);
        Assert.DoesNotContain("100 100 re", text);
        Assert.DoesNotContain("Img", text);
        Assert.DoesNotContain("BDC", text);
        Assert.Contains("(after) Tj", text);
        cut = HiddenContent.Strip("BT 72 700 Td /OC /H BDC (x) ' EMC 0 -10 Td (y) Tj ET"u8.ToArray(), t => t == "H", _ => false, out _);
        Assert.Contains("T*", Encoding.Latin1.GetString(cut!));
        Assert.DoesNotContain("(x)", Encoding.Latin1.GetString(cut!));

        // A hidden XObject's Do goes; other content stays. Nothing hidden: nothing changes.
        cut = HiddenContent.Strip("q /A Do Q q /B Do Q"u8.ToArray(), _ => false, n => n == "B", out _);
        Assert.Equal("q /A Do Q q  Q", Encoding.Latin1.GetString(cut!));
        Assert.Null(HiddenContent.Strip("/OC /V BDC (x) Tj EMC"u8.ToArray(), _ => false, _ => false, out _));
    }

    [Fact]
    public void MembershipDictionariesKeepShowingWhatTheyShowed()
    {
        // /M1: shown while L2 is off (AnyOff) -> stays, and keeps showing once L2 is gone. /M2: needs L1 and L2 on -> hidden, removed.
        var pdf = Dirty("/OC /M1 BDC BT /F1 12 Tf 72 450 Td (Shown while off) Tj ET EMC /OC /M2 BDC BT /F1 12 Tf 72 420 Td (Both needed) Tj ET EMC",
            "/Properties << /L1 18 0 R /L2 19 0 R /M1 << /Type /OCMD /OCGs [19 0 R] /P /AnyOff >> /M2 << /Type /OCMD /OCGs [18 0 R 19 0 R] /P /AllOn >> >>");
        var before = PageText(pdf);
        Assert.Contains("Shown while off", before);
        Assert.DoesNotContain("Both needed", before);
        var result = Sanitizer.Sanitize(pdf, null, new HashSet<SanitizeItem> { SanitizeItem.HiddenLayers });
        var after = PageText(result.Data);
        Assert.Contains("Shown while off", after);
        Assert.Contains("Shown layer", after);
        var all = Everything(result.Data);
        Assert.DoesNotContain("Both needed", all);
        Assert.DoesNotContain("Secret layer", all);
        Assert.DoesNotContain("Secret form", all);
        Assert.DoesNotContain("Hidden notes", all);
        Assert.Equal(0, result.Remaining![SanitizeItem.HiddenLayers]);
    }

    [Fact]
    public void EarlierRevisionsAreGone()
    {
        var pdf = Dirty();
        // An incremental update that renames the document: the old title stays in the first revision.
        var prev = Encoding.Latin1.GetString(pdf).LastIndexOf("startxref", StringComparison.Ordinal);
        var prevXref = int.Parse(Encoding.Latin1.GetString(pdf)[(prev + 10)..].Split('\n')[0]);
        var update = $"6 0 obj\n<< /Title (New title) >>\nendobj\n";
        var xref = pdf.Length + 1 + update.Length;
        var tail = $"\n{update}xref\n6 1\n{pdf.Length + 1:D10} 00000 n \ntrailer\n<< /Size 44 /Root 1 0 R /Info 6 0 R /Prev {prevXref} >>\nstartxref\n{xref}\n%%EOF\n";
        pdf = [.. pdf, .. Encoding.Latin1.GetBytes(tail)];
        Assert.Equal(1, Sanitizer.Scan(pdf, null).EarlierRevisions);
        Assert.Equal(5, Sanitizer.Scan(pdf, null)[SanitizeItem.Metadata]); // the newest Info has one entry

        var result = Sanitizer.Sanitize(pdf, null, new HashSet<SanitizeItem>()); // nothing chosen: the rewrite alone
        Assert.Equal(1, result.Removed.EarlierRevisions);
        Assert.Equal(0, result.Remaining!.EarlierRevisions);
        var all = Everything(result.Data);
        Assert.DoesNotContain("Secret title", all);
        Assert.Contains("New title", all);
    }

    [Fact]
    public void SignedFilesNeedConsentAndLoseTheirSignatures()
    {
        var signed = SignedEditTests.Signed(pages: 1, megabytes: 1);
        Assert.Equal(1, Sanitizer.Scan(signed, null)[SanitizeItem.Signatures]);
        Assert.Throws<SignaturesWouldBreakException>(() => Sanitizer.Sanitize(signed, null, All));
        var (data, report) = SignedEdits.Run(() => Sanitizer.Sanitize(signed, null, All).Data, allowRewrite: true);
        Assert.False(report.Appended);
        Assert.Equal(0, Sanitizer.Scan(data, null)[SanitizeItem.Signatures]);
        Assert.DoesNotContain("/ByteRange", Everything(data));
        Assert.All(Signatures.Verify(data, null), s => Assert.Equal(SignatureStatus.Unsigned, s.Status));
        Assert.Contains("Hello contract", PageText(data));
    }

    [Fact]
    public void EncryptedFilesKeepTheirProtection()
    {
        var pdf = PdfSecurity.Protect(Dirty(), null, "open", "owner");
        Assert.Throws<OwnerPasswordRequiredException>(() => Sanitizer.Sanitize(pdf, "open", All));
        var result = KeptProtection.Run("open", false, () => Sanitizer.Sanitize(pdf, "owner", All));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(result.Data, InputFileTypes.PDF, null));
        Assert.Equal(EncryptionMethod.Aes256, PdfSecurity.ReadSecurity(result.Data, "open").Method);
        Assert.True(result.Remaining!.IsClean, string.Join(", ", result.Remaining.Counts.Where(c => c.Value > 0)));
        Assert.Contains("Visible text", PageText(result.Data, "open"));
        Assert.DoesNotContain("Secret layer", Everything(result.Data, "owner"));
    }

    [Fact]
    public void CleanFileStaysClean()
    {
        var pdf = TestPdf.Make(2);
        var scan = Sanitizer.Scan(pdf, null);
        Assert.True(scan[SanitizeItem.Metadata] > 0); // the title and dates TestPdf's save writes
        var result = Sanitizer.Sanitize(pdf, null, All);
        Assert.True(result.Remaining!.IsClean);
        Assert.Equal([1, 2], TestPdf.PageNumbers(result.Data));
    }
}
