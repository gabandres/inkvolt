using System.Runtime.CompilerServices;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Wordprocessing;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 3.3's test: a contract and its edited .docx with 30 planted changes (wording, moves, formatting). Word made the two
/// PDFs in Data/, so the test runs anywhere; set INKVOLTPDF_WORD on a PC with Word to make them again from the documents
/// built here (INKVOLTPDF_SAMPLES also keeps the .docx files, for comparing them in the app).
/// </summary>
public class CompareContractTests
{
    private sealed record Plant(ChangeKind Kind, int Clause, string Old, string New, LookParts Look = LookParts.None);

    private const int Clauses = 48;
    private const string Insertion = " promptly and in writing";
    private const string Removal = " unless waived by the board";
    private static readonly int[] Replaced = [2, 7, 11, 16, 21, 27, 33, 40];
    private static readonly int[] Inserted = [4, 13, 24, 30, 44];
    private static readonly int[] Removed = [6, 18, 26, 36, 46];
    private static readonly (int Clause, int After)[] Moved = [(9, 14), (20, 38), (31, 3), (42, 47)];

    private sealed record Run(string Text, string? Font = null, int? HalfPoints = null, bool Bold = false, bool Italic = false, string? Color = null);

    private static string Amount(int clause) => (1000 + clause * 37).ToString(System.Globalization.CultureInfo.InvariantCulture);

    private static string Title(int i) =>
        $"Article {i} {new[] { "Term", "Payment", "Warranty", "Indemnity", "Notices", "Assignment", "Audit", "Insurance", "Confidentiality", "Termination", "Liability" }[i % 11]}";

    private static string Sentence(int n)
    {
        string[] who = ["The supplier", "The customer", "Each party", "The contractor", "The landlord", "The tenant", "The licensor"];
        string[] does = ["shall keep", "may review", "must return", "will deliver", "agrees to maintain", "shall inspect", "may withhold", "will publish", "must record", "shall renew", "agrees to replace", "will settle", "may extend"];
        string[] what = ["the quarterly records", "every signed invoice", "all equipment on site", "the annual statement", "any shipping manifest", "the safety certificates", "each purchase order", "the maintenance log", "all access credentials", "the delivery schedule", "any disputed balance"];
        string[] when = ["before the next renewal date", "within ninety days of request", "at its own expense", "during normal business hours", "after the closing of each month"];
        return $"{who[n % 7]} {does[n % 13]} {what[n % 11]} {when[n % 5]}.";
    }

    /// <summary>A clause: its title, a sentence, the amount with what the version says about it, and another sentence.</summary>
    private static List<Run> Clause(int i, bool edited, List<Plant> plants)
    {
        var title = new Run(Title(i) + ". ", "Arial", 22);
        var first = new Run(Sentence(i) + " The fee for this article is ", "Arial", 22);
        var amount = new Run(Amount(i), "Arial", 22);
        var rest = " dollars";
        var last = new Run(" " + Sentence(i + 17) + " " + Sentence(i * 3 + 5), "Arial", 22);

        if (Replaced.Contains(i))
        {
            var changed = (1000 + i * 37 + 5000).ToString(System.Globalization.CultureInfo.InvariantCulture);
            plants.Add(new Plant(ChangeKind.Changed, i, Amount(i), changed));
            if (edited) amount = amount with { Text = changed };
        }
        if (Inserted.Contains(i))
        {
            plants.Add(new Plant(ChangeKind.Inserted, i, "", Insertion.Trim()));
            if (edited) rest += Insertion;
        }
        if (Removed.Contains(i))
        {
            plants.Add(new Plant(ChangeKind.Deleted, i, Removal.Trim(), ""));
            if (!edited) rest += Removal;
        }

        // Formatting: the words stay, how they are set changes.
        void Looks(string text, LookParts parts) => plants.Add(new Plant(ChangeKind.Formatted, i, text, text, parts));
        var bare = Title(i) + ".";
        switch (i)
        {
            case 1:
                Looks(bare, LookParts.Bold);
                if (edited) title = title with { Bold = true };
                break;
            case 8:
                Looks(Amount(i), LookParts.Bold);
                if (edited) amount = amount with { Bold = true };
                break;
            case 15:
                Looks(bare, LookParts.Size);
                if (edited) title = title with { HalfPoints = 28 };
                break;
            case 23:
                Looks(Amount(i), LookParts.Size);
                if (edited) amount = amount with { HalfPoints = 26 };
                break;
            case 28:
                Looks(bare, LookParts.Italic);
                if (edited) title = title with { Italic = true };
                break;
            case 34:
                Looks(Amount(i), LookParts.Color);
                if (edited) amount = amount with { Color = "C00000" };
                break;
            case 38:
                Looks(bare, LookParts.Font);
                if (edited) title = title with { Font = "Times New Roman" };
                break;
            case 45:
                Looks(bare, LookParts.Bold);
                if (!edited) title = title with { Bold = true };
                break;
        }
        return [title, first, amount, new Run(rest + ".", "Arial", 22), last];
    }

    /// <summary>The version's clauses in their order, and everything planted.</summary>
    private static (List<List<Run>> Clauses, List<Plant> Plants) Version(bool edited)
    {
        var plants = new List<Plant>();
        var all = Enumerable.Range(1, Clauses).ToDictionary(i => i, i => Clause(i, edited, plants));
        var order = Enumerable.Range(1, Clauses).ToList();
        foreach (var (clause, after) in Moved)
        {
            plants.Add(new Plant(ChangeKind.Moved, clause, Title(clause), Title(clause)));
            if (!edited) continue;
            order.Remove(clause);
            order.Insert(order.IndexOf(after) + 1, clause);
        }
        return ([.. order.Select(i => all[i])], plants);
    }

    private static void WriteDocx(string path, bool edited)
    {
        using var doc = WordprocessingDocument.Create(path, WordprocessingDocumentType.Document);
        var main = doc.AddMainDocumentPart();
        var body = new Body();
        foreach (var clause in Version(edited).Clauses)
        {
            var p = new Paragraph(new ParagraphProperties(new SpacingBetweenLines { After = "160" }));
            foreach (var r in clause) p.Append(RunOf(r));
            body.Append(p);
        }
        var header = main.AddNewPart<HeaderPart>();
        header.Header = new Header(new Paragraph(RunOf(new Run("Master Services Agreement", "Arial", 18))));
        var footer = main.AddNewPart<FooterPart>();
        footer.Footer = new Footer(new Paragraph(RunOf(new Run("Contract 4471, page ", "Arial", 18)),
            new SimpleField(RunOf(new Run("1", "Arial", 18))) { Instruction = "PAGE" }));
        body.Append(new SectionProperties(
            new HeaderReference { Type = HeaderFooterValues.Default, Id = main.GetIdOfPart(header) },
            new FooterReference { Type = HeaderFooterValues.Default, Id = main.GetIdOfPart(footer) }));
        main.Document = new Document(body);
        main.Document.Save();

        static DocumentFormat.OpenXml.Wordprocessing.Run RunOf(Run r)
        {
            var props = new RunProperties();
            if (r.Font is { } f) props.Append(new RunFonts { Ascii = f, HighAnsi = f, ComplexScript = f });
            if (r.Bold) props.Append(new Bold());
            if (r.Italic) props.Append(new Italic());
            if (r.Color is { } c) props.Append(new Color { Val = c });
            if (r.HalfPoints is { } s) props.Append(new FontSize { Val = s.ToString(System.Globalization.CultureInfo.InvariantCulture) });
            return new DocumentFormat.OpenXml.Wordprocessing.Run(props, new Text(r.Text) { Space = SpaceProcessingModeValues.Preserve });
        }
    }

    private static string Data(string name) => Path.Combine(AppContext.BaseDirectory, "Data", name);

    private static CompareSource Read(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
        return CompareSource.Of([.. Enumerable.Range(0, engine.PageCount).Select(p => engine.GetComparePage(p))]);
    }

    private static string Show(CompareChange c) => $"{c.Kind} p{(c.New.Count > 0 ? c.New[0].Page : c.Old.Count > 0 ? c.Old[0].Page : -1)}: “{c.OldText}” → “{c.NewText}” {c.Look?.Describe()}";

    private static bool Matches(CompareChange c, Plant p) => p.Kind switch
    {
        ChangeKind.Moved => c.Kind == ChangeKind.Moved && c.NewText.StartsWith(p.New, StringComparison.Ordinal),
        ChangeKind.Formatted => c.Kind == ChangeKind.Formatted && c.NewText == p.New && c.Look!.Parts == p.Look,
        _ => c.Kind == p.Kind && c.OldText == p.Old && c.NewText == p.New,
    };

    [Fact]
    public void WordMadeContractListsItsThirtyPlantedChangesAndNoOthers()
    {
        var (_, plants) = Version(edited: true);
        Assert.Equal(30, plants.Count);
        var r = DocumentCompare.Run(Read(File.ReadAllBytes(Data("compare-contract-old.pdf"))), Read(File.ReadAllBytes(Data("compare-contract-new.pdf"))));

        var unmatched = r.Changes.ToList();
        var missing = new List<Plant>();
        foreach (var plant in plants)
        {
            var found = unmatched.FindIndex(c => Matches(c, plant));
            if (found < 0) missing.Add(plant);
            else unmatched.RemoveAt(found);
        }
        Assert.True(missing.Count == 0 && unmatched.Count == 0,
            $"Not found: {string.Join("; ", missing)}\nNot planted:\n{string.Join("\n", unmatched.Select(Show))}");
        Assert.Equal((8, 5, 5, 4, 8), (r.Changed, r.Inserted, r.Deleted, r.Moved, r.Formatted));
    }

    [Fact]
    public void AWordMadePageIsNoScanAndAPictureOfOneIs()
    {
        using var made = PdfEngine.Open(File.ReadAllBytes(Data("compare-contract-old.pdf")), MuPDFCore.InputFileTypes.PDF, null);
        var page = made.GetComparePage(0);
        Assert.False(page.IsPicture);
        Assert.False(page.Text.IsEmpty);
        Assert.Equal(11, page.Looks.At(page.Text.Text.IndexOf("Article", StringComparison.Ordinal))!.Size, 0);

        var picture = ImageImport.ImagesToPdf([(TestImages.Png(400, 500, (_, _) => (250, 250, 250, 255)), "scan.png")]);
        using var scan = PdfEngine.Open(picture, MuPDFCore.InputFileTypes.PDF, null);
        var read = scan.GetComparePage(0);
        Assert.True(read.IsPicture);
        Assert.True(read.Text.IsEmpty);
        Assert.Null(CompareSource.Of([read]).LooksOf(0));
        Assert.True(CompareSource.Of([read]).IsScanned(0));
    }

    [Fact]
    public void WithoutFormattingOnlyTheWordingAndMovesAreListed()
    {
        static CompareSource Plain(byte[] pdf)
        {
            using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
            return CompareSource.Of([.. Enumerable.Range(0, engine.PageCount).Select(p => engine.GetComparePage(p))], formatting: false);
        }
        var r = DocumentCompare.Run(Plain(File.ReadAllBytes(Data("compare-contract-old.pdf"))), Plain(File.ReadAllBytes(Data("compare-contract-new.pdf"))));
        Assert.Equal((8, 5, 5, 4, 0), (r.Changed, r.Inserted, r.Deleted, r.Moved, r.Formatted));
    }

    [Fact]
    public void TheLooksLineUpWithThePageTextOnEveryPage()
    {
        using var engine = PdfEngine.Open(File.ReadAllBytes(Data("compare-contract-new.pdf")), MuPDFCore.InputFileTypes.PDF, null);
        for (var p = 0; p < engine.PageCount; p++)
        {
            var read = engine.GetComparePage(p);
            Assert.Equal(engine.GetText(p).Text, read.Text.Text);
            // A word planted in another look has it exactly there, and the word beside it doesn't.
            var at = read.Text.Text.IndexOf("Article 8 ", StringComparison.Ordinal);
            if (at < 0) continue;
            var amount = read.Text.Text.IndexOf(Amount(8), at, StringComparison.Ordinal);
            Assert.True(read.Looks.At(amount)!.Bold);
            Assert.False(read.Looks.At(amount - 2)!.Bold);
        }
    }

    /// <summary>Makes the two PDFs again with the installed Word (INKVOLTPDF_WORD set).</summary>
    [Fact]
    public void MakeThePdfsWithWord()
    {
        if (!OperatingSystem.IsWindows() || Environment.GetEnvironmentVariable("INKVOLTPDF_WORD") is not { Length: > 0 }) return;
        var folder = Path.Combine(Path.GetDirectoryName(Source())!, "Data");
        var keep = Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } s ? s : Path.GetTempPath();
        var type = Type.GetTypeFromProgID("Word.Application") ?? throw new InvalidOperationException("Word isn't installed.");
        dynamic word = Activator.CreateInstance(type)!;
        try
        {
            foreach (var (edited, name) in new[] { (false, "compare-contract-old"), (true, "compare-contract-new") })
            {
                var docx = Path.Combine(keep, name + ".docx");
                WriteDocx(docx, edited);
                dynamic d = word.Documents.Open(docx, false, true);
                d.ExportAsFixedFormat(Path.Combine(folder, name + ".pdf"), 17);
                d.Close(0);
            }
        }
        finally
        {
            word.Quit(0);
        }

        static string Source([CallerFilePath] string path = "") => path;
    }
}
