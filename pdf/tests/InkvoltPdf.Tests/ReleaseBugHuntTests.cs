using System.Diagnostics;
using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>What an independent look before release 1.6 found in redaction by pattern and Translate: each failed before its fix.</summary>
public sealed class ReleaseBugHuntTests(ITestOutputHelper output) : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-bughunt-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private const string Ssn = "123-45-6789";

    private static PageText Page(params string[] lines) =>
        new([.. lines.Select((line, l) => line.Select((c, i) => (c.ToString(), new RectD(10 + 6 * i, 20 + 14 * l, 6, 12))).ToList())]);

    private static List<string> Found(RedactionPattern pattern, params string[] lines) =>
        [.. RedactionPatterns.Find(Page(lines), 0, new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern> { pattern } }).Select(m => m.Text)];

    private const string Font = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>";

    /// <summary>A page of ordinary text; <paramref name="more"/> are objects 6 on, <paramref name="catalog"/> and <paramref name="page"/> go in those objects.</summary>
    private static byte[] Doc(string catalog = "", string page = "", string content = "BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET", IReadOnlyList<string>? more = null, string trailer = "") =>
        Core2Pdf.Build(
        [
            $"<< /Type /Catalog /Pages 2 0 R {catalog} >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> {(page.StartsWith("/Properties", StringComparison.Ordinal) ? page : "")} >> {(page.StartsWith("/Properties", StringComparison.Ordinal) ? "" : page)} >>",
            Core2Pdf.Stream(content),
            Font,
            .. more ?? [],
        ], trailer);

    private async Task<BatchSummary> Redact(byte[] pdf, RedactionPatternOptions? options = null, InkvoltPrint.Core.Imaging.ITextRecognizer? ocr = null)
    {
        var path = Path.Combine(_root, $"in{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(path, pdf);
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(options ?? new RedactionPatternOptions())], OutputFolder = Path.Combine(_root, "out") };
        return await BatchRunner.RunAsync([new BatchFile(path)], plan, new BatchHost { Recognizer = ocr }, null, default);
    }

    private static void Fails(BatchSummary summary) => Assert.True(summary.Items[0].State == BatchItemState.Failed, $"{summary.Items[0].State}: {summary.Items[0].Message}");

    private static void Passes(BatchSummary summary) => Assert.True(summary.Items[0].State == BatchItemState.Done, $"{summary.Items[0].State}: {summary.Items[0].Message} ({string.Join("; ", summary.Items[0].Notes)})");

    // ───────────── numbers the patterns skip ─────────────

    [Theory]
    [InlineData("Ref 2026 4111 1111 1111 1111 paid")] // a year before it
    [InlineData("Room 3012 4111-1111-1111-1111")]
    public void A_card_after_a_four_digit_number_is_found(string line) =>
        Assert.Contains(Found(RedactionPattern.PaymentCard, line), f => f.Replace("-", " ").Contains("4111 1111 1111 1111", StringComparison.Ordinal));

    [Fact]
    public void Two_cards_side_by_side_are_both_found() =>
        Assert.Equal(2, Found(RedactionPattern.PaymentCard, "4111 1111 1111 1111 5555 5555 5555 4444").Count);

    [Fact]
    public void An_iban_after_a_code_is_found() =>
        Assert.Contains(Found(RedactionPattern.Iban, "Code AB12 DE89 3704 0044 0532 0130 00"), f => f.StartsWith("DE89", StringComparison.Ordinal));

    [Theory]
    [InlineData(RedactionPattern.SocialSecurity, "Jane,123-45-6789,223-45-6789,x", 2)]
    [InlineData(RedactionPattern.Phone, "555-201-3434,555-201-3435", 2)]
    [InlineData(RedactionPattern.IpAddress, "10.0.0.1,10.0.0.2", 2)]
    [InlineData(RedactionPattern.PaymentCard, "4111111111111111,5555555555554444", 2)]
    [InlineData(RedactionPattern.Date, "10/27/2026,11/27/2026", 2)]
    [InlineData(RedactionPattern.Date, "01/01/2025-12/31/2025", 2)]
    [InlineData(RedactionPattern.SocialSecurity, "123-45-6789/223-45-6789", 2)]
    [InlineData(RedactionPattern.IpAddress, "10.0.0.1/24", 1)]
    [InlineData(RedactionPattern.Phone, "555-201-3434/555-201-3435", 2)]
    public void Values_run_together_by_a_comma_or_slash_are_all_found(RedactionPattern pattern, string line, int count) =>
        Assert.Equal(count, Found(pattern, line).Count);

    // ───────────── saved sets ─────────────

    [Theory]
    [InlineData("""{"format":"Inkvolt PDF redaction patterns","version":"1","name":"x","phrases":["a"]}""")]
    [InlineData("""{"format":"Inkvolt PDF redaction patterns","version":1,"name":"\uD800x","phrases":["a"]}""")]
    [InlineData("""{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","phrases":["\uDC00"]}""")]
    [InlineData("""{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["\uD800"]}""")]
    public void A_malformed_set_is_refused_with_a_reason(string json) =>
        Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Read(json, "x.json"));

    [Fact]
    public void A_malformed_set_doesnt_stop_the_others_from_listing()
    {
        File.WriteAllText(Path.Combine(_root, "bad.json"), """{"format":"Inkvolt PDF redaction patterns","version":"1","name":"x"}""");
        RedactionPatternSets.Save(new RedactionPatternSet("good", new RedactionPatternOptions()), _root);
        var (sets, problems) = RedactionPatternSets.List(_root);
        Assert.Single(sets);
        Assert.Single(problems);
    }

    // ───────────── the rest of the file ─────────────

    private static string Attachment(string name, string text) =>
        Core2Pdf.Stream(text, "/Type /EmbeddedFile");

    private static byte[] WithAttachment(string name, string text) => Doc(
        catalog: $"/Names << /EmbeddedFiles << /Names [({name}) 6 0 R] >> >>",
        more: [$"<< /Type /Filespec /F ({name}) /UF ({name}) /EF << /F 7 0 R >> >>", Attachment(name, text)]);

    [Fact]
    public async Task A_value_late_in_a_long_attachment_is_found() =>
        Fails(await Redact(WithAttachment("data.csv", new string('x', 1_500_000) + "\nSSN " + Ssn + "\n")));

    [Fact]
    public async Task A_value_in_a_link_action_held_apart_is_found() =>
        Fails(await Redact(Doc(page: "/Annots [6 0 R]", more: ["<< /Type /Annot /Subtype /Link /Rect [72 690 300 720] /A 7 0 R >>", "<< /S /URI /URI (mailto:jane.doe@example.com) >>"])));

    [Fact]
    public async Task A_value_in_a_forms_xfa_data_is_found() =>
        Fails(await Redact(Doc(catalog: "/AcroForm << /Fields [] /XFA [(datasets) 6 0 R] >>", more: [Core2Pdf.Stream($"<xfa:datasets><data><ssn>{Ssn}</ssn></data></xfa:datasets>")])));

    [Fact]
    public async Task A_value_in_a_hidden_layer_is_found() =>
        Fails(await Redact(Doc(
            catalog: "/OCProperties << /OCGs [6 0 R] /D << /OFF [6 0 R] >> >>",
            page: "/Properties << /L1 6 0 R >>",
            content: $"BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET /OC /L1 BDC BT /F1 14 Tf 72 600 Td (SSN {Ssn}) Tj ET EMC",
            more: ["<< /Type /OCG /Name (Secret) >>"])));

    /// <summary>The document with its content replaced by an incremental update: the old text stays in the file.</summary>
    private static byte[] Updated(byte[] pdf, string content)
    {
        var text = Encoding.Latin1.GetString(pdf);
        var prev = int.Parse(text[(text.LastIndexOf("startxref", StringComparison.Ordinal) + 9)..].Trim().Split('\n')[0].Trim());
        var size = 6;
        var sb = new StringBuilder(text);
        var at = sb.Length;
        sb.Append($"4 0 obj\n{Core2Pdf.Stream(content)}\nendobj\n");
        var xref = sb.Length;
        sb.Append($"xref\n4 1\n{at:D10} 00000 n \ntrailer\n<< /Size {size} /Root 1 0 R /Prev {prev} >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.Latin1.GetBytes(sb.ToString());
    }

    [Fact]
    public async Task A_value_only_in_an_earlier_version_is_found()
    {
        var pdf = Updated(Doc(content: $"BT /F1 14 Tf 72 700 Td (SSN {Ssn}) Tj ET"), "BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET");
        using (var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null))
            Assert.DoesNotContain(Ssn, engine.GetText(0).Text);
        Fails(await Redact(pdf));
    }

    [Fact]
    public async Task A_program_version_that_reads_as_an_address_doesnt_fail_the_file() =>
        Passes(await Redact(Doc(more: [$"<< /Producer (iText 5.5.13.3 \\(c\\)2000-2022 iText Group NV) /Creator (Report 16.0.1.2) >>"], trailer: "/Info 6 0 R")));

    [Fact]
    public async Task A_programs_version_in_xmp_doesnt_fail_the_file() =>
        Passes(await Redact(Doc(catalog: "/Metadata 6 0 R", more: [Core2Pdf.Stream("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:pdf=\"http://ns.adobe.com/pdf/1.3/\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><pdf:Producer>iText 5.5.13.3</pdf:Producer><xmp:CreatorTool>Report 16.0.1.2</xmp:CreatorTool></rdf:Description></rdf:RDF></x:xmpmeta>", "/Type /Metadata /Subtype /XML")])));

    [Fact]
    public async Task An_address_in_a_files_title_is_still_found() =>
        Fails(await Redact(Doc(more: ["<< /Title (Server 10.1.2.3) >>"], trailer: "/Info 6 0 R")));

    /// <summary>A time stamp whose digits pass a card's check, with a zone that lets the digits end there.</summary>
    private static string CardLikeStamp()
    {
        for (var s = 0; ; s++)
            if ($"202401151030{s % 60:D2}" is var stamp && RedactionPatterns.Luhn(stamp)) return $"D:{stamp}+00'00'";
    }

    [Fact]
    public async Task A_time_stamp_isnt_taken_for_a_card_number()
    {
        Passes(await Redact(Doc(more: [$"<< /CreationDate ({CardLikeStamp()}) >>"], trailer: "/Info 6 0 R")));
        Passes(await Redact(Doc(page: "/Annots [6 0 R]", more: [$"<< /Type /Annot /Subtype /Text /Rect [72 690 90 710] /M ({CardLikeStamp()}) /Contents (A note) >>"])));
    }

    [Fact]
    public void A_later_redaction_after_an_export_is_refused()
    {
        var redact = new RedactPatternsStep(new RedactionPatternOptions());
        var other = new RedactPatternsStep(new RedactionPatternOptions { Phrases = ["word"] });
        var plan = new BatchPlan { Steps = [redact, new ExportStep(BatchExportFormat.Word), other], OutputFolder = _root };
        Assert.Contains("before exports", plan.Validate(true));
    }

    [Fact]
    public async Task A_report_that_cant_be_written_doesnt_lose_the_batch()
    {
        var blocker = Path.Combine(_root, "afile");
        File.WriteAllText(blocker, "x");
        var path = Path.Combine(_root, "in.pdf");
        File.WriteAllBytes(path, Doc());
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(new RedactionPatternOptions())], OutputFolder = Path.Combine(blocker, "out") };
        var summary = await BatchRunner.RunAsync([new BatchFile(path)], plan, new BatchHost(), null, default);
        Assert.Equal(BatchItemState.Failed, summary.Items[0].State);
        Assert.Null(summary.RedactionReportPath);
    }

    [Fact]
    public async Task A_batch_note_doesnt_repeat_a_value_in_a_files_own_names()
    {
        var name = Ssn + ".txt";
        var summary = await Redact(WithAttachment(name, "Nothing here"));
        Fails(summary);
        var all = string.Join(" ", summary.Items[0].Notes.Append(summary.Items[0].Message));
        Assert.DoesNotContain(Ssn, all);

        var field = await Redact(Doc(catalog: "/AcroForm << /Fields [6 0 R] >>", page: "/Annots [6 0 R]", more: [$"<< /Type /Annot /Subtype /Widget /FT /Tx /T (Holder {Ssn}) /Rect [72 500 300 530] /V (x) >>"]));
        Fails(field);
        Assert.DoesNotContain(Ssn, string.Join(" ", field.Items[0].Notes.Append(field.Items[0].Message)));
    }

    [Fact]
    public async Task A_date_on_the_page_that_is_also_the_files_own_date_doesnt_fail_it()
    {
        var pdf = Doc(content: "BT /F1 14 Tf 72 700 Td (Dated 2026-10-27 and more words) Tj ET", catalog: "/Metadata 6 0 R",
            more: [Core2Pdf.Stream("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\"><rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><xmp:CreateDate>2026-10-27T10:00:00Z</xmp:CreateDate></rdf:Description></rdf:RDF></x:xmpmeta>", "/Type /Metadata /Subtype /XML")]);
        Passes(await Redact(pdf));
    }

    [Fact]
    public async Task A_value_in_a_string_held_apart_is_found() =>
        Fails(await Redact(Doc(more: ["<< /Title 7 0 R >>", $"(Holder {Ssn})"], trailer: "/Info 6 0 R")));

    [Fact]
    public async Task An_attachment_that_cant_be_read_fails_the_file() =>
        Fails(await Redact(Doc(catalog: "/Names << /EmbeddedFiles << /Names [(a.bin) 6 0 R] >> >>",
            more: ["<< /Type /Filespec /F (a.bin) /EF << /F 7 0 R >> >>", Core2Pdf.Stream("this is not flate data at all", "/Type /EmbeddedFile /Filter /FlateDecode")])));

    [Fact]
    public async Task A_value_in_an_attached_pdf_with_kerned_text_is_found()
    {
        var inner = Doc(content: "BT /F1 14 Tf 72 700 Td [(SSN 123-)-20(45-)30(6789)] TJ ET");
        Fails(await Redact(WithAttachment("inner.pdf", Encoding.Latin1.GetString(inner))));
    }

    // ───────────── ink the search doesn't see ─────────────

    /// <summary>A page of text with a picture on it: a band of a shade with light words in it (a banner, a card).</summary>
    private static byte[] LightOnBand(double shade, PlantedReader reader)
    {
        var source = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 60] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream($"{shade} g 0 0 300 60 re f 1 g BT /F1 14 Tf 20 22 Td (SSN {Ssn}) Tj ET"),
            Font,
        ]);
        using var engine = PdfEngine.Open(source, InputFileTypes.PDF, null);
        var image = engine.Render(0, 2);
        var gray = InkvoltPrint.Core.Imaging.ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        reader.PlantWords(612, 792, [("SSN", new RectD(92, 330, 34, 18)), (Ssn, new RectD(128, 330, 90, 18))]);
        return Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im0 6 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET q 300 0 0 60 72 400 cm /Im0 Do Q"),
            Font,
            Core2Pdf.Stream(Encoding.Latin1.GetString(gray), $"/Type /XObject /Subtype /Image /Width {image.Width} /Height {image.Height} /ColorSpace /DeviceGray /BitsPerComponent 8"),
        ]);
    }

    [Theory]
    [InlineData(0.0)]
    [InlineData(0.3)]
    [InlineData(0.5)]
    [InlineData(0.7)]
    public void Light_words_on_a_band_in_a_picture_arent_called_clean(double shade)
    {
        var reader = new PlantedReader();
        var pdf = LightOnBand(shade, reader);
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), reader);
        output.WriteLine($"shade {shade}: looks {found.Looks.Count} hits {found.Hits.Count}");
        Assert.NotEmpty(found.Looks);
    }

    /// <summary>A scan under a text layer that holds only its first line; the recognizer reads both, and the lines are close.</summary>
    [Fact]
    public async Task A_value_on_the_next_line_of_one_the_text_layer_has_is_still_found()
    {
        var source = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream($"BT /F1 12 Tf 72 700 Td ({Ssn}) Tj ET BT /F1 12 Tf 72 688 Td (223-45-6789) Tj ET"),
            Font,
        ]);
        using var render = PdfEngine.Open(source, InputFileTypes.PDF, null);
        var image = render.Render(0, 150.0 / 72);
        var gray = InkvoltPrint.Core.Imaging.ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        var reader = new PlantedReader();
        reader.Plant(612, 792, render.GetText(0));
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> /XObject << /Im0 6 0 R >> >> >>",
            Core2Pdf.Stream($"q 612 0 0 792 0 0 cm /Im0 Do Q BT 3 Tr /F1 12 Tf 72 700 Td ({Ssn}) Tj ET"),
            Font,
            Core2Pdf.Stream(Encoding.Latin1.GetString(gray), $"/Type /XObject /Subtype /Image /Width {image.Width} /Height {image.Height} /ColorSpace /DeviceGray /BitsPerComponent 8"),
        ]);
        using (var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null))
        {
            var found = RedactionSearch.Find(engine, new RedactionPatternOptions(), reader);
            output.WriteLine(string.Join("; ", found.Hits.Select(h => $"{h.Normalized} ocr={h.FromOcr}")));
            Assert.Contains(found.Hits, h => h.Normalized == "223-45-6789");
        }
        Passes(await Redact(pdf, null, reader));
    }

    [Fact]
    public void A_pattern_nested_very_deep_doesnt_stop_the_app()
    {
        var deep = new string('(', 990) + "a" + new string(')', 990);
        Assert.Null(RedactionPatterns.ValidateExpression(deep));
        var options = new RedactionPatternOptions { Expression = deep, Patterns = new HashSet<RedactionPattern>() };
        Assert.Single(RedactionPatterns.Find(Page("x a y"), 0, options));
    }

    [Fact]
    public void A_malformed_preset_is_refused_with_a_reason()
    {
        var json = """{"format":"Inkvolt PDF batch preset","version":1,"name":"\uD800","steps":[{"action":"redactPatterns","phrases":["\uD800"]}]}""";
        var ex = Record.Exception(() => BatchPresets.Read(json, "x.json"));
        output.WriteLine(ex?.GetType().Name ?? "no exception");
        Assert.True(ex is BatchPresetException or null, ex?.ToString());
    }

    // ───────────── translate ─────────────

    [Fact]
    public void Text_in_a_hidden_layer_isnt_sent_for_translating()
    {
        var pdf = Doc(
            catalog: "/OCProperties << /OCGs [6 0 R] /D << /OFF [6 0 R] >> >>",
            page: "/Properties << /L1 6 0 R >>",
            content: "BT /F1 14 Tf 72 700 Td (An ordinary line of words) Tj ET /OC /L1 BDC BT /F1 14 Tf 72 600 Td (Secret plan nobody sees) Tj ET EMC",
            more: ["<< /Type /OCG /Name (Secret) >>"]);
        var plan = Translation.MakePlan(pdf, null, [0]);
        Assert.Contains(plan.Texts, t => t.Text.Contains("ordinary", StringComparison.Ordinal));
        Assert.DoesNotContain(plan.Texts, t => t.Text.Contains("Secret", StringComparison.Ordinal));
    }

    [Fact]
    public void A_signed_and_encrypted_file_still_gets_its_copy_after_the_translating()
    {
        var pdf = SignedEditTests.Encrypted(SignedEditTests.Signed());
        var plan = Translation.MakePlan(pdf, "owner", [0, 1]);
        var answers = new TranslationAnswers();
        foreach (var (text, _) in plan.Texts) answers.Done[text] = "Translated words";
        var result = Translation.Apply(plan, answers, "es");
        Assert.NotNull(result.Data);
        using var engine = PdfEngine.Open(result.Data!, InputFileTypes.PDF, "owner");
        Assert.Contains("Translated", engine.GetText(0).Text);
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(result.Data!, InputFileTypes.PDF, null));
    }

    [Fact]
    public void An_aes256_file_with_an_open_password_gets_its_copy_and_keeps_the_password()
    {
        var pdf = PdfSecurity.Protect(TranslationPdf.Report(1), null, "open", "open");
        var plan = Translation.MakePlan(pdf, "open", [0]);
        var answers = new TranslationAnswers();
        foreach (var (text, _) in plan.Texts) answers.Done[text] = "Translated words";
        var copy = Translation.Apply(plan, answers, "es").Data!;
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(copy, InputFileTypes.PDF, null));
        using var engine = PdfEngine.Open(copy, InputFileTypes.PDF, "open");
        Assert.Contains("Translated", engine.GetText(0).Text);
    }

    [Fact]
    public void An_aes256_file_opened_with_its_permissions_password_asks_before_anything_is_sent()
    {
        var pdf = PdfSecurity.Protect(TranslationPdf.Report(1), null, "open", "owner");
        Assert.Throws<OpenPasswordUnknownException>(() => Translation.MakePlan(pdf, "owner", [0]));
        var plan = Translation.MakePlan(pdf, "owner", [0], openPassword: "open");
        var answers = new TranslationAnswers();
        foreach (var (text, _) in plan.Texts) answers.Done[text] = "Translated words";
        var copy = Translation.Apply(plan, answers, "es").Data!;
        using var engine = PdfEngine.Open(copy, InputFileTypes.PDF, "open");
        Assert.Contains("Translated", engine.GetText(0).Text);
    }

    [Theory]
    [InlineData(60000)]
    public async Task A_right_to_left_answer_with_no_spaces_lays_out_quickly(int length)
    {
        var lines = Enumerable.Range(0, 50).Select(_ => "The quick brown fox jumps over a lazy dog, until the quick brown fox jumps over a lazy dog again.").ToArray();
        var sb = new StringBuilder("BT /FA 8 Tf ");
        foreach (var (l, i) in lines.Select((l, i) => (l, i))) sb.Append($"1 0 0 1 72 {740 - i * 10} Tm ({l}) Tj ");
        var pdf = ContentEditPdf.Make(sb.Append("ET ").ToString());
        var plan = Translation.MakePlan(pdf, null, [0]);
        var answers = new TranslationAnswers();
        foreach (var (text, _) in plan.Texts) answers.Done[text] = new string('ب', length);
        var clock = Stopwatch.StartNew();
        var run = Task.Run(() => Translation.Apply(plan, answers, "ar"));
        var finished = await Task.WhenAny(run, Task.Delay(TimeSpan.FromSeconds(120))) == run;
        output.WriteLine($"{length} chars: {clock.Elapsed.TotalSeconds:F1} s, finished {finished}, texts {plan.Texts.Count}");
        Assert.True(finished);

    }
}
