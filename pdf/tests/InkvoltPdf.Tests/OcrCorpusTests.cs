using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>The OCR corpus's generator and its measure (pdf/tools/ocr-corpus): the numbers in its RESULTS.md rest on them.</summary>
public class OcrCorpusTests
{
    [Fact]
    public void WordErrorRateCountsSubstitutionsDeletionsAndInsertions()
    {
        string[] truth = ["the", "river", "año", "1234.50"];
        Assert.Equal(0, WordErrorRate.Of(truth, truth));
        Assert.Equal(0.25, WordErrorRate.Of(truth, ["the", "rlver", "año", "1234.50"])); // one substituted
        Assert.Equal(0.25, WordErrorRate.Of(truth, ["the", "año", "1234.50"])); // one missed
        Assert.Equal(0.25, WordErrorRate.Of(truth, ["the", "river", "a", "año", "1234.50"])); // one extra
        Assert.Equal(0.25, WordErrorRate.Of(truth, ["the", "river", "ano", "1234.50"])); // accents count
        Assert.Equal(1, WordErrorRate.Of(truth, []));
        Assert.Equal(1.5, WordErrorRate.Of(["a", "b"], ["x", "y", "z"]));
        Assert.Equal(["Total:", "€1,234", "río"], WordErrorRate.Words(" Total:  €1,234\nrío "));
    }

    [Fact]
    public void TheCorpusIsTheSameEveryTime()
    {
        var file = ScanCorpus.Files[0] with { Pages = 1 };
        var (first, truth) = ScanCorpus.Make(file);
        var (second, _) = ScanCorpus.Make(file);
        Assert.Equal(ScanCorpus.Sha256(first), ScanCorpus.Sha256(second));

        var page = Assert.Single(truth);
        Assert.True(page.Words.Count > 250, $"{page.Words.Count} words");
        using var engine = PdfEngine.Open(first, InputFileTypes.PDF, null);
        Assert.Equal(1, engine.PageCount);
        Assert.DoesNotContain(engine.GetText(0).Text, char.IsLetter); // a scan: no text to find until it's recognized
    }

    [Fact]
    public void TheCorpusHasTwoLanguagesAndTheRoadmapsSkews()
    {
        Assert.Equal(["en", "es"], ScanCorpus.Files.Select(f => f.Language).Distinct().Order());
        Assert.All(ScanCorpus.Files, f => Assert.InRange(f.MinSkew, 3, 10));
        Assert.All(ScanCorpus.Files, f => Assert.InRange(f.MaxSkew, 3, 10));
        var (_, _, _, spanish) = ScanCorpus.MakePage(ScanCorpus.Files.First(f => f.Language == "es"), 0);
        Assert.Contains(spanish.Words, w => w.Any(c => "áéíóúñü".Contains(c)));
    }
}
