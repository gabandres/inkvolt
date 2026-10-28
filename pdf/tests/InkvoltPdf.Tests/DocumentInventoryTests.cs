using System.Text.Json;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class DocumentInventoryTests
{
    private static readonly HashSet<SanitizeItem> All = [.. Enum.GetValues<SanitizeItem>()];

    /// <summary>
    /// <see cref="SanitizerTests.Dirty"/> (one of everything Sanitize removes) with a second version appended that no
    /// longer shows "Visible text".
    /// </summary>
    private static byte[] Planted()
    {
        var first = SanitizerTests.Dirty();
        var content = "BT /F1 12 Tf 72 700 Td (Shown text) Tj ET /OC /L1 BDC BT /F1 12 Tf 72 650 Td (Shown layer) Tj ET EMC " +
                      "/OC /L2 BDC 1 0 0 rg BT /F1 12 Tf 72 600 Td (Secret layer) Tj ET 0 0 100 100 re f EMC q /Sec Do Q q 10 0 0 10 300 300 cm /Im Do Q ";
        return RedactionCheckTests.Append(first, 4, Core2Pdf.Stream(content), "/Info 6 0 R ");
    }

    private static string Dump(IEnumerable<InventoryItem> items) =>
        string.Join("\n", items.Select(i => $"{i.Section} | {i.What} | {i.Where} | {i.Trigger} | {i.Detail}"));

    private static InventoryItem Has(InventoryReport r, InventorySection section, Func<InventoryItem, bool> match) =>
        r.Items.FirstOrDefault(i => i.Section == section && match(i)) ?? throw new Xunit.Sdk.XunitException($"Not in {section}:\n{Dump(r.Items)}");

    [Fact]
    public void ListsEachPlantedKind()
    {
        var r = DocumentInventory.Run(Planted(), null);

        // Scripts, where they run, and what they call.
        var open = Has(r, InventorySection.Scripts, i => i.Detail.Contains("app.alert"));
        Assert.Equal("When the document opens", open.Where);
        Assert.Equal(InventoryTrigger.Automatic, open.Trigger);
        Assert.Contains("shows a message or asks a question", open.Calls);
        Assert.Equal(SanitizeItem.ActiveContent, open.RemovedBy);
        Assert.Equal("Before the document closes", Has(r, InventorySection.Scripts, i => i.Detail.Contains("willClose")).Where);
        Assert.Contains("document script “init”", Has(r, InventorySection.Scripts, i => i.Detail.Contains("docInit")).Where);
        Assert.Equal("When page 1 opens", Has(r, InventorySection.Scripts, i => i.Detail.Contains("pageOpen")).Where);
        var keystroke = Has(r, InventorySection.Scripts, i => i.Detail.Contains("AFNumber_Keystroke"));
        Assert.Equal(InventoryTrigger.Use, keystroke.Trigger);
        Assert.Contains("“name”", keystroke.Where);
        Assert.Equal(InventoryTrigger.Use, Has(r, InventorySection.Scripts, i => i.Detail.Contains("evil")).Trigger);
        Has(r, InventorySection.Scripts, i => i.What == "XFA form");
        Has(r, InventorySection.Scripts, i => i.Detail == "RichMedia");
        Has(r, InventorySection.Scripts, i => i.Detail == "Sound");

        // The open action's next step only goes to a page: nothing to list.
        Assert.Empty(r.In(InventorySection.Actions));

        // Every address, file and program, and how it is reached.
        var link = Has(r, InventorySection.Addresses, i => i.Detail == "https://example.com/link");
        Assert.Equal(InventoryTrigger.Use, link.Trigger);
        Assert.Equal(0, link.Page);
        Assert.False(link.WithoutClick);
        Assert.Contains("bookmark “Chapter”", Has(r, InventorySection.Addresses, i => i.Detail == "https://example.com/outline").Where);
        Assert.Equal("Sends the form's data", Has(r, InventorySection.Addresses, i => i.Detail == "https://example.com/submit").What);
        Assert.Equal("Starts a program or opens a file", Has(r, InventorySection.Addresses, i => i.Detail == "calc.exe").What);

        // Attachments: the document's list, the attachment comment, the associated file.
        Assert.Equal(2, r.In(InventorySection.Attachments).Count(i => i.What == "Attached file" && i.Detail.StartsWith("a.txt")));
        Has(r, InventorySection.Attachments, i => i.What == "Associated file" && i.Detail == "a.txt");

        // Metadata: properties, XMP, other apps' data, an image's own packet.
        Assert.Equal("Secret title", Has(r, InventorySection.Metadata, i => i.What == "Title").Detail);
        Assert.Equal("Jane Doe", Has(r, InventorySection.Metadata, i => i.What == "Author").Detail);
        Assert.Equal("Word", Has(r, InventorySection.Metadata, i => i.What == "Written by").Detail);
        Assert.Equal("internal", Has(r, InventorySection.Metadata, i => i.What == "Custom").Detail);
        Assert.Equal("Jane Doe", Has(r, InventorySection.Metadata, i => i.What == "Author (XMP)").Detail);
        Has(r, InventorySection.Metadata, i => i.What == "Private data of other apps" && i.Detail == "Illustrator" && i.Where == "The document");
        Has(r, InventorySection.Metadata, i => i.What == "Private data of other apps" && i.Detail == "App" && i.Where == "Page 1");
        Has(r, InventorySection.Metadata, i => i.What == "XMP metadata" && i.Where == "Page 1, a picture");

        // Earlier versions, and the text only the earlier one shows.
        Has(r, InventorySection.EarlierVersions, i => i.What == "Earlier versions" && i.Detail.StartsWith("1 earlier version"));
        Has(r, InventorySection.EarlierVersions, i => i.What == RedactionCheck.Name(RedactionLeak.EarlierRevision) && i.Detail.Contains("visible", StringComparison.OrdinalIgnoreCase));

        // Hidden: the layer, a hidden comment, a hidden field.
        Has(r, InventorySection.Hidden, i => i.What == "Hidden layer" && i.Detail.Contains("Hidden notes"));
        Has(r, InventorySection.Hidden, i => i.What == "Hidden comment" && i.Detail == "hidden square");
        Has(r, InventorySection.Hidden, i => i.What == "Hidden form field" && i.Detail == "hidden data");

        // Form values.
        Assert.Equal("John Smith", Has(r, InventorySection.FormValues, i => i.Where.Contains("“name”")).Detail);
        Assert.Equal("on (Yes)", Has(r, InventorySection.FormValues, i => i.Where.Contains("“agree”")).Detail);
        Assert.DoesNotContain(r.In(InventorySection.FormValues), i => i.Where.Contains("send")); // a push button has no value

        Assert.False(r.IsEmpty);
        Assert.Equal(1, r.Pages);
        Assert.Equal(11, r.Counts[SanitizeItem.ActiveContent]);
    }

    [Fact]
    public void SanitizedEverythingReportsNothing()
    {
        var before = DocumentInventory.Run(Planted(), null);
        Assert.All(before.Items.Where(i => i.Section is not (InventorySection.EarlierVersions or InventorySection.Hidden)),
            i => Assert.True(i.RemovedBy is not null, $"no Sanitize kind for {i.Section} | {i.What} | {i.Detail}"));

        var sanitized = Sanitizer.Sanitize(Planted(), null, All).Data;
        var after = DocumentInventory.Run(sanitized, null);
        Assert.True(after.IsEmpty, Dump(after.Items));
        Assert.StartsWith("Nothing but its pages", after.Summary);
    }

    [Fact]
    public void TextThatDoesNotShowAndCoversAreListed()
    {
        var data = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 18 Tf 72 700 Td (Shown words) Tj ET 1 1 1 rg BT /F1 18 Tf 72 600 Td (White secret) Tj ET 0 g " +
                            "BT /F1 18 Tf 72 1200 Td (Offpage secret) Tj ET BT /F1 18 Tf 72 500 Td (Boxed secret) Tj ET 0 g 60 490 200 30 re f"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
        ]);
        var r = DocumentInventory.Run(data, null);
        Has(r, InventorySection.Redaction, i => i.Detail.Contains("White secret") && i.Page == 0 && i.Where.Contains("color behind"));
        Has(r, InventorySection.Hidden, i => i.Detail.Contains("Offpage secret") && i.Where.Contains("outside the visible page"));
        Has(r, InventorySection.Redaction, i => i.Detail.Contains("Boxed secret") && i.What == RedactionCheck.Name(RedactionLeak.CoveredText));
        Assert.DoesNotContain(r.Items, i => i.Detail.Contains("Shown words"));
    }

    [Fact]
    public void AddressesReachedWithoutAClickAreMarked()
    {
        var data = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R /OpenAction << /S /URI /URI (https://tracker.example/open) >> /AcroForm << /Fields [8 0 R] >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Annots [5 0 R 8 0 R] /AA << /C 7 0 R >> >>",
            Core2Pdf.Stream(""),
            "<< /Type /Annot /Subtype /Link /Rect [72 700 200 720] /AA << /E 6 0 R >> /A << /S /GoTo /D [3 0 R /Fit] >> >>",
            "<< /S /JavaScript /JS (app.launchURL\\(\"https://hover.example/x?id=1\"\\); this.submitForm\\(\"mailto:a@example.com\"\\)) >>",
            "<< /S /Launch /F (setup.exe) >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Signature1) /Rect [300 100 400 150] /P 3 0 R /V 9 0 R >>",
            "<< /Type /Sig /Filter /Adobe.PPKLite /Name (Jane Signer) /M (D:20260301120000Z) /Reason (Approved) /Location (San Juan) >>",
        ]);
        var r = DocumentInventory.Run(data, null);

        var open = Has(r, InventorySection.Addresses, i => i.Detail == "https://tracker.example/open");
        Assert.Equal(InventoryTrigger.Automatic, open.Trigger);
        Assert.True(open.WithoutClick);
        Has(r, InventorySection.Actions, i => i.Detail == "https://tracker.example/open" && i.What == "Opens a web address");

        var hover = Has(r, InventorySection.Addresses, i => i.Detail == "https://hover.example/x?id=1");
        Assert.Equal(InventoryTrigger.Pointer, hover.Trigger);
        Assert.Contains("pointer enters", hover.Where);
        Has(r, InventorySection.Addresses, i => i.Detail == "mailto:a@example.com" && i.Trigger == InventoryTrigger.Pointer);
        var script = Has(r, InventorySection.Scripts, i => i.Detail.Contains("launchURL"));
        Assert.Equal(["opens a web address", "sends the form's data"], script.Calls);

        var launch = Has(r, InventorySection.Addresses, i => i.Detail == "setup.exe");
        Assert.Equal("When page 1 closes", launch.Where);
        Assert.True(launch.WithoutClick);
        Has(r, InventorySection.Actions, i => i.Detail == "setup.exe");
        Assert.DoesNotContain(r.Items, i => i.Section == InventorySection.Addresses && i.What == "Goes to a page"); // a click to a page reaches nothing

        var sig = Has(r, InventorySection.Signatures, i => i.Where.Contains("Signature1"));
        Assert.Equal("Jane Signer, 1 March 2026, 12:00, reason: Approved, at San Juan", sig.Detail);
        Assert.Equal(SanitizeItem.Signatures, sig.RemovedBy);

        Assert.Contains("4 addresses are reached without a click", r.Summary);
    }

    [Theory]
    [InlineData("this.print({bUI: false})", "prints")]
    [InlineData("var x = eval(code)", "runs code it builds as it goes")]
    [InlineData("this.exportDataObject({cName: 'a'})", "writes a file")]
    [InlineData("var n = identity.name", "reads who you are or what your computer runs")]
    [InlineData("Net.HTTP.request({cURL: u})", "connects to the internet")]
    [InlineData("app.setTimeOut('f()', 100)", "runs on a timer")]
    public void ScriptCallsAreNamed(string source, string words) =>
        Assert.Contains(words, DocumentInventory.ScriptCalls(source));

    [Fact]
    public void ScriptsWithoutOutwardCallsNameNone() =>
        Assert.Empty(DocumentInventory.ScriptCalls("var total = this.getField('a').value + 1; event.value = total;"));

    [Fact]
    public void ReportsSaveAsHtmlAndJson()
    {
        var r = DocumentInventory.Run(Planted(), null);
        var at = new DateTime(2026, 10, 28, 9, 30, 0);
        var html = InventoryReportFiles.Html(r, "planted <file>.pdf", at);
        Assert.StartsWith("<!DOCTYPE html>", html);
        Assert.Contains("<title>What's in this PDF: planted &lt;file&gt;.pdf</title>", html);
        foreach (var s in r.Items.Select(i => i.Section).Distinct())
            Assert.Contains($">{System.Net.WebUtility.HtmlEncode(DocumentInventory.Title(s))} (", html);
        Assert.Contains("(no click needed)", html);
        Assert.Contains("app.alert", html);
        Assert.DoesNotContain("<script", html);
        Assert.DoesNotContain("src=", html);

        var json = InventoryReportFiles.Json(r, "planted.pdf", at);
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        Assert.Equal(InventoryReportFiles.JsonFormat, root.GetProperty("format").GetString());
        Assert.Equal(1, root.GetProperty("version").GetInt32());
        Assert.Equal(["format", "version", "file", "madeAt", "pages", "summary", "items", "sanitizeFinds", "notes"], root.EnumerateObject().Select(p => p.Name));
        Assert.Equal(r.Items.Count, root.GetProperty("items").GetArrayLength());
        var first = root.GetProperty("items")[0];
        Assert.Equal("scripts", first.GetProperty("section").GetString());
        Assert.Equal(11, root.GetProperty("sanitizeFinds").GetProperty("activeContent").GetInt32());
        // Same report, same bytes.
        Assert.Equal(json, InventoryReportFiles.Json(DocumentInventory.Run(Planted(), null), "planted.pdf", at));
    }

    [Fact]
    public void AnOrdinaryFileCarriesNothing()
    {
        var data = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> /Annots [7 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 5 0 R /Resources << /Font << /F1 6 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 18 Tf 72 700 Td (Just a page) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            "<< /Type /Annot /Subtype /Link /Rect [72 690 200 720] /A << /S /GoTo /D [4 0 R /Fit] >> >>",
        ]);
        var r = DocumentInventory.Run(data, null);
        Assert.True(r.IsEmpty, Dump(r.Items));
        Assert.Equal(2, r.Pages);
        // Metadata when there is some.
        var titled = DocumentInventory.Run(TestPdf.Make(1), null);
        Assert.Equal("Synthetic", titled.In(InventorySection.Metadata).First(i => i.What == "Title").Detail);
    }
}

/// <summary>Batch's Report What's in Each File action: a web page and JSON beside each file; it never fails one.</summary>
public sealed class InventoryBatchTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-inventory-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    [Fact]
    public async Task EachFileGetsItsReport()
    {
        var dirty = Path.Combine(_root, "dirty.pdf");
        File.WriteAllBytes(dirty, SanitizerTests.Dirty());
        var outFolder = Path.Combine(_root, "out");
        var plan = new BatchPlan { Steps = [new ReportContentsStep()], OutputFolder = outFolder };

        var summary = await BatchRunner.RunAsync([new BatchFile(dirty)], plan, new BatchHost(), null, CancellationToken.None);

        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Done, item.State);
        var html = Path.Combine(outFolder, "dirty contents.html");
        var json = Path.Combine(outFolder, "dirty contents.json");
        Assert.Contains(html, item.Outputs);
        Assert.Contains(json, item.Outputs);
        Assert.Contains("app.alert", File.ReadAllText(html));
        Assert.Equal("dirty.pdf", JsonDocument.Parse(File.ReadAllText(json)).RootElement.GetProperty("file").GetString());
        Assert.Contains(item.Notes, n => n.StartsWith("Contents: Scripts (", StringComparison.Ordinal));
    }

    [Fact]
    public void ThePresetNameRoundTrips()
    {
        var text = BatchPresets.Write(new BatchPreset { Name = "Report", Steps = [new ReportContentsStep()] });
        Assert.Contains("\"reportContents\"", text);
        Assert.IsType<ReportContentsStep>(Assert.Single(BatchPresets.Read(text).Steps));
    }
}
