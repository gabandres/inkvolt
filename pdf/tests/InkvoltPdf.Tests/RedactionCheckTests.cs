using System.IO.Compression;
using System.Text;
using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class RedactionCheckTests
{
    private const string Name = "Zephyrine Okonkwo";

    private static string Deflated(string text)
    {
        using var ms = new MemoryStream();
        using (var z = new ZLibStream(ms, CompressionLevel.Optimal, leaveOpen: true)) z.Write(Encoding.Latin1.GetBytes(text));
        return Encoding.Latin1.GetString(ms.ToArray());
    }

    /// <summary>
    /// Two pages. Page 1 shows the name (to be redacted). The name is also planted on page 2 (shown, outside the page,
    /// in a hidden layer), in a note's text, a text box's appearance, a form field's value, a bookmark, the document
    /// properties, the XMP packet, an attached file (compressed), and the alternate text of a tag.
    /// </summary>
    private static byte[] Everywhere() => Core2Pdf.Build([
        "<< /Type /Catalog /Pages 2 0 R /Outlines 10 0 R /Names << /EmbeddedFiles << /Names [(notes.txt) 12 0 R] >> >> /Metadata 14 0 R " +
        "/AcroForm << /Fields [9 0 R] >> /OCProperties << /OCGs [15 0 R] /D << /OFF [15 0 R] >> >> /StructTreeRoot 16 0 R /MarkInfo << /Marked true >> >>",
        "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents [6 0 R 18 0 R] /Resources << /Font << /F1 7 0 R >> /Properties << /oc1 15 0 R >> >> /Annots [8 0 R 9 0 R 19 0 R] >>",
        Core2Pdf.Stream($"BT /F1 18 Tf 72 700 Td (Patient: {Name}) Tj ET BT /F1 18 Tf 72 650 Td (Visit notes follow) Tj ET"),
        Core2Pdf.Stream($"BT /F1 12 Tf 72 700 Td (Also seen: {Name} here) Tj ET BT /F1 12 Tf 700 900 Td ({Name}) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        $"<< /Type /Annot /Subtype /Text /Rect [500 700 520 720] /Contents (Call {Name}) >>",
        $"<< /Type /Annot /Subtype /Widget /FT /Tx /T (patient) /V ({Name}) /Rect [72 400 300 420] /P 4 0 R >>",
        "<< /Type /Outlines /First 11 0 R /Last 11 0 R /Count 1 >>",
        $"<< /Title ({Name} file) /Parent 10 0 R /Dest [4 0 R /Fit] >>",
        "<< /Type /Filespec /F (notes.txt) /UF (notes.txt) /EF << /F 13 0 R >> >>",
        Core2Pdf.Stream(Deflated($"Notes about {Name}, seen on Monday."), "/Type /EmbeddedFile /Filter /FlateDecode"),
        Core2Pdf.Stream($"<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:description>About {Name}</dc:description></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>", "/Type /Metadata /Subtype /XML"),
        "<< /Type /OCG /Name (Private) >>",
        "<< /Type /StructTreeRoot /K [17 0 R] >>",
        $"<< /Type /StructElem /S /Figure /P 16 0 R /Pg 4 0 R /Alt (Photo of {Name}) >>",
        Core2Pdf.Stream($"/OC /oc1 BDC BT /F1 12 Tf 72 500 Td (Private: {Name}) Tj ET EMC"),
        "<< /Type /Annot /Subtype /FreeText /Rect [72 300 300 320] /Contents (see the note) /DA (/F1 12 Tf 0 g) /AP << /N 20 0 R >> >>",
        Core2Pdf.Stream($"BT /F1 12 Tf 2 5 Td ({Name}) Tj ET", "/Type /XObject /Subtype /Form /BBox [0 0 228 20] /Resources << /Font << /F1 7 0 R >> >>"),
        $"<< /Title (Report on {Name}) >>",
    ], "/Info 21 0 R");

    /// <summary>The areas of every match of <paramref name="text"/> on a page, grown by a point.</summary>
    private static Dictionary<int, IReadOnlyList<RectD>> AreasOf(byte[] data, int page, string text)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var t = engine.GetText(page);
        var rects = t.Find(text, true, false).Select(m => t.GetRects(m.Start, m.End).Aggregate(default(RectD), (a, r) => a.Union(r)).Inflate(1)).ToList();
        Assert.NotEmpty(rects);
        return new() { [page] = rects };
    }

    /// <summary>Redacts <paramref name="text"/> on <paramref name="page"/> as the app does, then checks with what was redacted.</summary>
    private static (byte[] Redacted, RedactionCheckReport Report) RedactAndCheck(byte[] data, int page, string text)
    {
        var areas = AreasOf(data, page, text);
        List<string> values;
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, null)) values = RedactionCheck.ValuesUnder(engine, areas);
        var redacted = Redaction.Apply(data, null, areas, dpi: 100);
        return (redacted, RedactionCheck.Run(redacted, null, new RedactionCheckOptions { Values = values, Areas = areas, Original = data }));
    }

    [Fact]
    public void TheValuesUnderTheAreasAreWhatIsLookedFor()
    {
        var data = Everywhere();
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        Assert.Equal([Name], RedactionCheck.ValuesUnder(engine, AreasOf(data, 0, Name)));
    }

    /// <summary>With INKVOLTPDF_SAMPLES set, <see cref="Everywhere"/> is written there (redaction-check-sample.pdf) for the app,
    /// and a box drawn over text (redaction-check-box.pdf).</summary>
    [Fact]
    public void EveryLeftoverOfARedactedValueIsFound()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "redaction-check-sample.pdf"), Everywhere());
            File.WriteAllBytes(Path.Combine(dir, "redaction-check-box.pdf"), Bad("box").Bad);
        }
        var (_, report) = RedactAndCheck(Everywhere(), 0, Name);

        Assert.DoesNotContain(report.Findings, f => f.Page == 0); // the redacted page itself is clean
        var kinds = report.Findings.Select(f => f.Kind).ToHashSet();
        foreach (var kind in new[]
                 {
                     RedactionLeak.PageText, RedactionLeak.HiddenText, RedactionLeak.HiddenContent, RedactionLeak.Annotation, RedactionLeak.FormField,
                     RedactionLeak.Bookmark, RedactionLeak.Metadata, RedactionLeak.Attachment, RedactionLeak.StructureTree,
                 })
            Assert.Contains(kind, kinds);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.PageText && f.Page == 1 && f.Text == Name && !f.Box.IsEmpty && f.Fix == RedactionFix.Redact);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.HiddenText && f.Page == 1 && f.Sanitize == SanitizeItem.HiddenLayers);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.HiddenText && f.Where.Contains("outside the visible page"));
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.Annotation && f.Text.Contains($"Call {Name}") && f.Sanitize == SanitizeItem.Comments);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.Annotation && f.Where == "Text box on page 2"); // in its appearance only
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.FormField && f.Where.Contains("patient") && f.Sanitize == SanitizeItem.FormValues);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.Metadata && f.Where == "Document properties");
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.Metadata && f.Where == "XMP metadata");
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.Attachment && f.Where == "Attached file 'notes.txt'" && f.Text.Contains(Name));
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.StructureTree && f.Fix == RedactionFix.None);
        Assert.DoesNotContain(report.Findings, f => f.Kind == RedactionLeak.AreaNotRemoved);
        Assert.Contains(Name, report.Values);
    }

    [Fact]
    public void FixingRemovesEverythingThatCanBeFixed()
    {
        var (redacted, report) = RedactAndCheck(Everywhere(), 0, Name);
        Assert.True(report.CanFix);
        var fixedData = RedactionCheck.Fix(redacted, null, report.Findings);
        var again = RedactionCheck.Run(fixedData, null, new RedactionCheckOptions { Values = report.Values });
        Assert.All(again.Findings, f => Assert.Equal(RedactionFix.None, f.Fix));
        Assert.DoesNotContain(again.Findings, f => f.Kind is RedactionLeak.PageText or RedactionLeak.Metadata or RedactionLeak.Attachment or RedactionLeak.Bookmark);
    }

    [Fact]
    public void ACleanRedactionReportsNothing()
    {
        var data = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            Core2Pdf.Stream($"BT /F1 18 Tf 72 700 Td (Patient: {Name}) Tj ET BT /F1 18 Tf 72 650 Td (Visit notes follow) Tj ET"),
            Core2Pdf.Stream("BT /F1 12 Tf 72 700 Td (Second page, nothing private) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]);
        var (redacted, report) = RedactAndCheck(data, 0, Name);
        Assert.True(report.IsClean, string.Join("; ", report.Findings.Select(f => $"{f.Kind} {f.Where}: {f.Text}")));
        // Checked as a file received from someone else (nothing known about it): clean too.
        Assert.True(RedactionCheck.Run(redacted, null).IsClean);
    }

    [Fact]
    public void OrdinaryFilesHaveNothingToReport()
    {
        foreach (var data in new[] { TestPdf.Make(3), Table() })
        {
            var report = RedactionCheck.Run(data, null);
            Assert.True(report.IsClean, string.Join("; ", report.Findings.Select(f => $"{f.Kind} {f.Where}: {f.Text}")));
        }
    }

    /// <summary>A dark table header with white text on it, square bullets drawn beside list items, a black rule.</summary>
    private static byte[] Table() => OnePage(
        "0.1 0.1 0.3 rg 72 680 468 24 re f 1 g BT /F1 14 Tf 80 687 Td (Name    Amount    Date) Tj ET " +
        "0 g 72 640 5 5 re f BT /F1 12 Tf 84 638 Td (First item) Tj ET 72 620 5 5 re f BT /F1 12 Tf 84 618 Td (Second item) Tj ET " +
        "72 600 468 2 re f");

    private static byte[] OnePage(string content, string annots = "", IReadOnlyList<string>? more = null, string xobjects = "") => Core2Pdf.Build([
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << {xobjects} >> >> {(annots.Length > 0 ? $"/Annots [{annots}]" : "")} >>",
        Core2Pdf.Stream(content),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        .. more ?? [],
    ]);

    private const string Line = $"BT /F1 18 Tf 72 700 Td (Name: {Name} lives here) Tj ET";

    /// <summary>Where the name is drawn by <see cref="Line"/>, in PDF space: x1 y1 x2 y2.</summary>
    private static (double X1, double Y1, double X2, double Y2) NameBox()
    {
        var area = AreasOf(OnePage(Line), 0, Name)[0][0];
        return (area.X, 792 - area.Bottom, area.Right, 792 - area.Y);
    }

    private static string Re((double X1, double Y1, double X2, double Y2) b) =>
        string.Create(System.Globalization.CultureInfo.InvariantCulture, $"{b.X1:0.##} {b.Y1:0.##} {b.X2 - b.X1:0.##} {b.Y2 - b.Y1:0.##} re");

    private static string Rect((double X1, double Y1, double X2, double Y2) b) =>
        string.Create(System.Globalization.CultureInfo.InvariantCulture, $"[{b.X1:0.##} {b.Y1:0.##} {b.X2:0.##} {b.Y2:0.##}]");

    /// <summary>A small picture with four colors (no byte of it spells "endstream").</summary>
    private static string Picture() => Core2Pdf.Stream(
        Encoding.Latin1.GetString([.. Enumerable.Range(0, 16).SelectMany(i => (i % 4) switch { 0 => new byte[] { 200, 30, 30 }, 1 => new byte[] { 30, 200, 30 }, 2 => new byte[] { 30, 30, 200 }, _ => new byte[] { 220, 220, 40 } })]),
        "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8");

    public static TheoryData<string> BadKinds => ["box", "highlight", "black-on-black", "white", "mark", "picture", "picture-comment", "spacing"];

    /// <summary>The roadmap's corpus: bad redactions of each kind. <paramref name="kind"/> picks one.</summary>
    private static (byte[] Bad, RedactionLeak Expected, RectD Area) Bad(string kind)
    {
        var b = NameBox();
        var re = Re(b);
        var rect = Rect(b);
        var area = RectD.FromEdges(b.X1, 792 - b.Y2, b.X2, 792 - b.Y1);
        const string pictureAt = "q 200 0 0 100 72 400 cm /Im1 Do Q";
        var picArea = new RectD(100, 792 - 480, 100, 60);
        return kind switch
        {
            "box" => (OnePage($"{Line} 0 g {re} f"), RedactionLeak.CoveredText, area),
            "highlight" => (OnePage(Line, "6 0 R", [
                $"<< /Type /Annot /Subtype /Highlight /Rect {rect} /C [0 0 0] /QuadPoints [{b.X1} {b.Y2} {b.X2} {b.Y2} {b.X1} {b.Y1} {b.X2} {b.Y1}] /AP << /N 7 0 R >> >>",
                Core2Pdf.Stream($"0 g 0 0 {b.X2 - b.X1:0.##} {b.Y2 - b.Y1:0.##} re f", $"/Type /XObject /Subtype /Form /BBox [0 0 {b.X2 - b.X1:0.##} {b.Y2 - b.Y1:0.##}]"),
            ]), RedactionLeak.CoveredText, area),
            "black-on-black" => (OnePage($"0 g {re} f {Line}"), RedactionLeak.CoveredText, area),
            "white" => (OnePage($"BT /F1 18 Tf 72 700 Td (Name: ) Tj 1 g ({Name}) Tj 0 g ( lives here) Tj ET"), RedactionLeak.CoveredText, area),
            "mark" => (OnePage(Line, "6 0 R", [
                $"<< /Type /Annot /Subtype /Redact /Rect {rect} /QuadPoints [{b.X1} {b.Y2} {b.X2} {b.Y2} {b.X1} {b.Y1} {b.X2} {b.Y1}] /IC [0 0 0] >>",
            ]), RedactionLeak.UnappliedMark, area),
            "picture" => (OnePage($"{pictureAt} 0 g 100 420 100 60 re f", more: [Picture()], xobjects: "/Im1 6 0 R"), RedactionLeak.CoveredContent, picArea),
            "picture-comment" => (OnePage(pictureAt, "7 0 R", [
                Picture(),
                "<< /Type /Annot /Subtype /Square /Rect [100 420 200 480] /C [0 0 0] /IC [0 0 0] /AP << /N 8 0 R >> >>",
                Core2Pdf.Stream("0 g 0 0 100 60 re f", "/Type /XObject /Subtype /Form /BBox [0 0 100 60]"),
            ], "/Im1 6 0 R"), RedactionLeak.CoveredContent, picArea),
            // The name was taken out and a box drawn where it was; "lives here" kept its place.
            "spacing" => (OnePage($"BT /F1 18 Tf 72 700 Td (Name: ) Tj ET 0 g {re} f BT /F1 18 Tf {b.X2 + 5:0.##} 700 Td (lives here) Tj ET"), RedactionLeak.GlyphSpacing, area),
            _ => throw new ArgumentException(kind),
        };
    }

    [Theory]
    [MemberData(nameof(BadKinds))]
    public void BadRedactionsAreFlaggedAndProperOnesAreNot(string kind)
    {
        var (bad, expected, area) = Bad(kind);
        var report = RedactionCheck.Run(bad, null);
        var hit = Assert.Single(report.Findings, f => f.Kind == expected);
        Assert.Equal(0, hit.Page);
        Assert.False(hit.Box.IsEmpty);
        Assert.True(hit.Box.Inflate(2).Contains(area.CenterX, area.CenterY), $"{hit.Box} should hold {area}");
        if (expected is RedactionLeak.CoveredText or RedactionLeak.UnappliedMark) Assert.Equal(Name, hit.Text);
        Assert.Equal(RedactionFix.Redact, hit.Fix);

        // Redacted properly (the area applied), nothing is left: the fix does the same.
        var proper = Redaction.Apply(bad, null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [area.Inflate(1)] }, dpi: 100);
        var after = RedactionCheck.Run(proper, null);
        Assert.True(after.IsClean, string.Join("; ", after.Findings.Select(f => $"{f.Kind} {f.Where}: {f.Text}")));
        Assert.True(RedactionCheck.Run(RedactionCheck.Fix(bad, null, report.Findings), null).IsClean);
    }

    [Fact]
    public void ARedactedAreaThatStillShowsSomethingIsFound()
    {
        // Checked as if the name had been redacted, but it wasn't.
        var data = OnePage(Line);
        var areas = AreasOf(data, 0, Name);
        var report = RedactionCheck.Run(data, null, new RedactionCheckOptions { Areas = areas, Values = [Name] });
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.AreaNotRemoved && f.Page == 0);

        // A box drawn over a picture that was never changed: the area looks black, but the picture is the original.
        var (bad, _, area) = Bad("picture");
        var boxed = RedactionCheck.Run(bad, null, new RedactionCheckOptions { Areas = new Dictionary<int, IReadOnlyList<RectD>> { [0] = [area] }, Original = bad });
        Assert.Contains(boxed.Findings, f => f.Kind == RedactionLeak.AreaNotRemoved && f.Text.Contains("original"));
    }

    /// <summary>Appends an incremental update replacing object <paramref name="number"/>.</summary>
    internal static byte[] Append(byte[] pdf, int number, string body, string trailerExtra = "")
    {
        var text = Encoding.Latin1.GetString(pdf);
        var at = text.LastIndexOf("startxref", StringComparison.Ordinal);
        var prevXref = int.Parse(text[(at + 10)..].Split('\n')[0]);
        var size = int.Parse(System.Text.RegularExpressions.Regex.Match(text, @"/Size (\d+)").Groups[1].Value);
        var update = $"{number} 0 obj\n{body}\nendobj\n";
        var xref = pdf.Length + 1 + Encoding.Latin1.GetByteCount(update);
        var tail = $"\n{update}xref\n{number} 1\n{pdf.Length + 1:D10} 00000 n \ntrailer\n<< /Size {size} /Root 1 0 R /Prev {prevXref} {trailerExtra}>>\nstartxref\n{xref}\n%%EOF\n";
        return [.. pdf, .. Encoding.Latin1.GetBytes(tail)];
    }

    [Fact]
    public void AValueInAnEarlierRevisionIsCaught()
    {
        // Version 1 shows the number; version 2 (appended) draws the line without it and a box where it was.
        var first = OnePage("BT /F1 18 Tf 72 700 Td (Account 219-09-9999) Tj ET");
        var second = Append(first, 4, Core2Pdf.Stream("BT /F1 18 Tf 72 700 Td (Account) Tj ET 0 g 150 695 110 22 re f"));
        using (var engine = PdfEngine.Open(second, InputFileTypes.PDF, null)) Assert.DoesNotContain("219", engine.GetText(0).Text);

        // Nothing known: the earlier version's page showed text the current one doesn't.
        var report = RedactionCheck.Run(second, null);
        Assert.Contains(report.Findings, f => f.Kind == RedactionLeak.EarlierRevision && f.Text.Contains("219-09-9999") && f.Fix == RedactionFix.Rewrite);
        // The value known (written differently): found in the earlier version's objects too.
        var known = RedactionCheck.Run(second, null, new RedactionCheckOptions { Values = ["219 09 9999"] });
        Assert.Contains(known.Findings, f => f.Kind == RedactionLeak.EarlierRevision && f.Where == "Earlier version 1 of the file" && f.Text.Contains("219-09-9999"));

        // Rewritten as one version (and the box beside "Account" redacted), nothing is left.
        var fixedData = RedactionCheck.Fix(second, null, report.Findings);
        Assert.Empty(RedactionCheck.Revisions(fixedData));
        Assert.True(RedactionCheck.Run(fixedData, null, new RedactionCheckOptions { Values = ["219-09-9999"] }).IsClean);
    }

    [Fact]
    public void AnObjectNothingUsesIsFound()
    {
        var data = OnePage("BT /F1 18 Tf 72 700 Td (Nothing private here) Tj ET", more: [$"<< /Note (Draft for {Name}) >>"]);
        var report = RedactionCheck.Run(data, null, new RedactionCheckOptions { Values = [Name] });
        var hit = Assert.Single(report.Findings);
        Assert.Equal(RedactionLeak.FileData, hit.Kind);
        Assert.Equal(RedactionFix.Rewrite, hit.Fix);
        Assert.True(RedactionCheck.Run(RedactionCheck.Fix(data, null, report.Findings), null, new RedactionCheckOptions { Values = [Name] }).IsClean);
    }

    [Theory]
    [InlineData("219-09-9999", "SSN 219 09 9999.", true)]
    [InlineData("219-09-9999", "ref 219099999", true)]
    [InlineData("219-09-9999", "1219-09-9999", false)]
    [InlineData(Name, "ZEPHYRINE\nOKONKWO", true)]
    [InlineData(Name, "Zephy­rine Okonkwo", true)]
    [InlineData(Name, "Zephyrine Okonkwos", false)]
    public void ValuesMatchWrittenOtherwise(string value, string text, bool found)
    {
        var matcher = new RedactionCheck.ValueMatcher([value]);
        Assert.Equal(found, matcher.Matches(text).Any());
    }

    [Fact]
    public async Task BatchFailsAFileWithLeftovers()
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-check").FullName;
        try
        {
            var bad = Path.Combine(dir, "bad.pdf");
            var good = Path.Combine(dir, "good.pdf");
            File.WriteAllBytes(bad, Bad("box").Bad);
            File.WriteAllBytes(good, TestPdf.Make(2));
            var plan = new BatchPlan { Steps = [new CheckRedactionStep()], OutputFolder = Path.Combine(dir, "out") };
            var summary = await BatchRunner.RunAsync([new BatchFile(bad), new BatchFile(good)], plan, new BatchHost(), null, CancellationToken.None);
            var failed = summary.Items.Single(i => i.File.Path == bad);
            Assert.Equal(BatchItemState.Failed, failed.State);
            Assert.Contains("Redaction check", failed.Message);
            Assert.Equal(BatchItemState.Done, summary.Items.Single(i => i.File.Path == good).State);

            // After Redact Patterns, the check looks for what was redacted: here a phrase also in the properties.
            var titled = Path.Combine(dir, "titled.pdf");
            File.WriteAllBytes(titled, Core2Pdf.Build([
                "<< /Type /Catalog /Pages 2 0 R >>",
                "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
                Core2Pdf.Stream(Line),
                "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
                $"<< /Title (About {Name}) >>",
            ], "/Info 6 0 R"));
            var redact = new BatchPlan
            {
                Steps = [new RedactPatternsStep(new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Phrases = [Name] }), new CheckRedactionStep()],
                OutputFolder = Path.Combine(dir, "out2"),
            };
            var second = await BatchRunner.RunAsync([new BatchFile(titled)], redact, new BatchHost(), null, CancellationToken.None);
            var item = Assert.Single(second.Items);
            Assert.Equal(BatchItemState.Failed, item.State);
            Assert.Contains("metadata", item.Message, StringComparison.OrdinalIgnoreCase);
            Assert.Empty(item.Outputs); // a file that fails the check isn't saved
        }
        finally
        {
            Directory.Delete(dir, true);
        }
    }
}
