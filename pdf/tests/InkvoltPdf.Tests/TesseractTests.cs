using System.Diagnostics;
using System.Net;
using System.Security.Cryptography;
using System.Text;
using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 2.2, the second engine: Tesseract's TSV read as hostile, its download kept only as pinned (a fake server, no
/// network), the engine taken out of the installer's LZMA stream (a small stream of the same kind), the languages offered
/// and which engine reads a choice, two languages on a page line by line, and the program run with limits. The real
/// engine is opt-in: INKVOLTPDF_TESSERACT names a folder holding tesseract.exe and tessdata\eng.traineddata, or
/// "download" to download and install it (about 27 MB) into a temporary folder through <see cref="TesseractStore"/>.
/// </summary>
public class TesseractTests
{
    private const string Header = "level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext";

    // ---- TSV ----

    [Fact]
    public void TsvGivesTheWordsWithTheirLinesAndConfidence()
    {
        var tsv = Header + "\n" +
                  "1\t1\t0\t0\t0\t0\t0\t0\t1600\t400\t-1\t\n" +
                  "4\t1\t1\t1\t1\t0\t48\t67\t707\t34\t-1\t\n" +
                  "5\t1\t1\t1\t1\t1\t48\t67\t56\t26\t96.842865\tThe\n" +
                  "5\t1\t1\t1\t1\t2\t117\t67\t83\t34\t41.5\tquick\n" +
                  "5\t1\t1\t1\t2\t1\t47\t110\t32\t26\t96.57\tEl\r\n" +
                  "5\t1\t2\t1\t1\t1\t90\t200\t96\t34\t97\trápido\n";
        var words = TesseractTsv.Parse(tsv, 1600, 400);
        Assert.Equal(["The", "quick", "El", "rápido"], words.Select(w => w.Text));
        Assert.Equal([0, 0, 1, 2], words.Select(w => w.Line));
        Assert.Equal(41.5, words[1].Confidence);
        Assert.Equal((117d, 67d, 83d, 34d), (words[1].X, words[1].Y, words[1].Width, words[1].Height));
    }

    [Fact]
    public void TsvFromAnythingElseIsRefused()
    {
        Assert.Throws<InvalidDataException>(() => TesseractTsv.Parse("", 100, 100));
        Assert.Throws<InvalidDataException>(() => TesseractTsv.Parse("The quick brown fox\n", 100, 100));
        Assert.Throws<InvalidDataException>(() => TesseractTsv.Parse("<html>5\t1\t1\t1\t1\t1\t0\t0\t5\t5\t90\tword</html>", 100, 100));
    }

    [Fact]
    public void HostileRowsAreLeftOutAndBoxesKeptInsideTheImage()
    {
        var rows = new[]
        {
            "5\t1\t1\t1\t1\t1\t10\t10\t20\t20\t90\tkept",
            "5\t1\t1\t1\t1\t2\t10\t10\t20\t20\t90\ttoo\tmany", // 13 fields
            "5\t1\t1\t1\t1\t3\t10\t10\t20\t20\t90", // 11 fields
            "5\t1\t1\t1\t1\t4\tx\t10\t20\t20\t90\tnotanumber",
            "5\t1\t1\t1\t1\t5\t10\t10\t20\t20\tNaN\tnan",
            "5\t1\t1\t1\t1\t6\t10\t10\t20\t20\tInfinity\tinf",
            "5\t1\t1\t1\t1\t7\t10\t10\t99999999999\t20\t90\toverflow",
            "5\t1\t1\t1\t1\t8\t500\t500\t20\t20\t90\toutside",
            "5\t1\t1\t1\t1\t9\t-50\t-50\t20\t20\t90\tbefore",
            "5\t1\t1\t1\t1\t10\t10\t10\t0\t20\t90\tflat",
            "5\t1\t1\t1\t1\t11\t10\t10\t20\t20\t90\t   ",
            "5\t1\t1\t1\t1\t12\t10\t10\t20\t20\t90\t" + new string('w', 500),
            "5\t1\t1\t1\t1\t13\t90\t90\t50\t50\t250\tclipped",
            "5\t1\t1\t1\t1\t14\t10\t10\t20\t20\t90\tcon\u0000trol\u001b",
            "3\t1\t1\t1\t0\t0\t10\t10\t20\t20\t-1\tparagraph",
        };
        var words = TesseractTsv.Parse(Header + "\n" + string.Join("\n", rows), 100, 100);
        Assert.Equal(["kept", "clipped", "control"], words.Select(w => w.Text));
        var clipped = words[1];
        Assert.Equal((90d, 90d, 10d, 10d, 100d), (clipped.X, clipped.Y, clipped.Width, clipped.Height, clipped.Confidence!.Value));
    }

    [Fact]
    public void TsvWordsAreCountedBeforeTheyAreKept()
    {
        var sb = new StringBuilder(Header).Append('\n');
        for (var i = 0; i < TesseractTsv.MaxWords + 50; i++) sb.Append($"5\t1\t1\t1\t1\t{i}\t1\t1\t2\t2\t90\tw\n");
        Assert.Equal(TesseractTsv.MaxWords, TesseractTsv.Parse(sb.ToString(), 10, 10).Count);
    }

    // ---- LZMA and the engine's files ----

    private static byte[] Solid() =>
        Encoding.ASCII.GetBytes(string.Concat(Enumerable.Range(0, 3000).Select(i => $"line {i} of the solid stream, {i * 7 % 13} \n")));

    private static byte[] Stream() => File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Data", "solid-stream.lzma"));

    [Fact]
    public void LzmaDecodesTheStreamToItsEndMarker()
    {
        var output = new MemoryStream();
        var n = Lzma.Decode(new MemoryStream(Stream()), output, maxOutput: 1 << 20);
        Assert.Equal(Solid().Length, n);
        Assert.Equal(Solid(), output.ToArray());
    }

    [Fact]
    public void LzmaStopsWhereAskedAndRefusesMoreThanItMay()
    {
        var output = new MemoryStream();
        Lzma.Decode(new MemoryStream(Stream()), output, maxOutput: 1 << 20, stopAfter: 5000);
        Assert.InRange(output.Length, 5000, 5000 + 273);
        Assert.Equal(Solid().AsSpan(0, 5000).ToArray(), output.ToArray()[..5000]);
        Assert.Throws<InvalidDataException>(() => Lzma.Decode(new MemoryStream(Stream()), System.IO.Stream.Null, maxOutput: 10_000));
    }

    [Fact]
    public void ABrokenLzmaStreamThrowsAndNeverRunsOn()
    {
        var stream = Stream();
        Assert.Throws<InvalidDataException>(() => Lzma.Decode(new MemoryStream(stream[..(stream.Length / 2)]), System.IO.Stream.Null, 1 << 20));
        var badProps = (byte[])stream.Clone();
        badProps[0] = 250;
        Assert.Throws<InvalidDataException>(() => Lzma.Decode(new MemoryStream(badProps), System.IO.Stream.Null, 1 << 20));
        var hugeDictionary = (byte[])stream.Clone();
        BitConverter.GetBytes(uint.MaxValue).CopyTo(hugeDictionary, 1);
        Assert.Throws<InvalidDataException>(() => Lzma.Decode(new MemoryStream(hugeDictionary), System.IO.Stream.Null, 1 << 20));
        // Bytes changed in the middle: an error, or other bytes, never more than allowed and never stuck.
        var random = new Random(7);
        for (var trial = 0; trial < 40; trial++)
        {
            var bad = (byte[])stream.Clone();
            for (var k = 0; k < 3; k++) bad[random.Next(10, bad.Length)] ^= (byte)random.Next(1, 256);
            var output = new MemoryStream();
            try
            {
                Lzma.Decode(new MemoryStream(bad), output, maxOutput: 200_000);
            }
            catch (InvalidDataException)
            {
                // refused: fine
            }
            Assert.True(output.Length <= 200_000);
        }
    }

    /// <summary>An "installer": a stub, then the stream; two files pinned at their places in what it decodes to.</summary>
    private static (string Archive, EngineFile[] Files) FakeInstaller(string folder, bool wrongHash = false)
    {
        var solid = Solid();
        var archive = Path.Combine(folder, "setup.download");
        File.WriteAllBytes(archive, [.. new byte[1000], .. Stream()]);
        EngineFile Pin(string name, int offset, int size) =>
            new(name, offset, size, Convert.ToHexStringLower(SHA256.HashData(solid.AsSpan(offset, size))));
        var files = new[] { Pin("tesseract.exe", 120, 4000), Pin("libtesseract-5.dll", 50_000, 20_000), Pin("LICENSE", 101_000, 582) };
        if (wrongHash) files[1] = files[1] with { Sha256 = new string('0', 64) };
        return (archive, files);
    }

    [Fact]
    public void TheEngineIsTakenOutOfTheInstallerFileByFileAndChecked()
    {
        using var temp = new TempFolder();
        var (archive, files) = FakeInstaller(temp.Path);
        var destination = Path.Combine(temp.Path, "engine", "1.0");
        TesseractStore.Extract(archive, 1000, Stream()[0], BitConverter.ToUInt32(Stream(), 1), files, destination);
        foreach (var f in files)
            Assert.Equal(Solid().AsSpan((int)f.Offset, (int)f.Size).ToArray(), File.ReadAllBytes(Path.Combine(destination, f.Name)));
        Assert.Equal(3, Directory.GetFiles(destination).Length);
        Assert.False(Directory.Exists(destination + ".partial"));
    }

    [Fact]
    public void AFileThatIsntThePinnedOneLeavesNoEngine()
    {
        using var temp = new TempFolder();
        var (archive, files) = FakeInstaller(temp.Path, wrongHash: true);
        var destination = Path.Combine(temp.Path, "engine", "1.0");
        Assert.Throws<InvalidDataException>(() => TesseractStore.Extract(archive, 1000, Stream()[0], BitConverter.ToUInt32(Stream(), 1), files, destination));
        Assert.False(Directory.Exists(destination));
        Assert.False(Directory.Exists(destination + ".partial"));
        // Another stream than the pinned one (its properties differ) isn't decoded at all.
        (archive, files) = FakeInstaller(temp.Path);
        Assert.Throws<InvalidDataException>(() => TesseractStore.Extract(archive, 1000, (byte)(Stream()[0] + 1), BitConverter.ToUInt32(Stream(), 1), files, destination));
        Assert.Throws<ArgumentException>(() => TesseractStore.Extract(archive, 1000, Stream()[0], BitConverter.ToUInt32(Stream(), 1),
            [new EngineFile("..\\evil.dll", 0, 10, new string('0', 64))], destination));
    }

    [Fact]
    public void ThePinsAreWellFormed()
    {
        Assert.Equal("https", TesseractCatalog.InstallerUrl.Scheme);
        Assert.Equal("github.com", TesseractCatalog.InstallerUrl.Host);
        Assert.StartsWith("/tesseract-ocr/tesseract/releases/download/", TesseractCatalog.InstallerUrl.AbsolutePath);
        Assert.Contains(TesseractCatalog.EngineFiles, f => f.Name == "tesseract.exe");
        Assert.All(TesseractCatalog.EngineFiles, f => Assert.Matches("^[0-9a-f]{64}$", f.Sha256));
        Assert.Equal(TesseractCatalog.EngineFiles.Length, TesseractCatalog.EngineFiles.Select(f => f.Name.ToLowerInvariant()).Distinct().Count());
        Assert.True(TesseractCatalog.Languages.Length > 100);
        Assert.Equal(TesseractCatalog.Languages.Length, TesseractCatalog.Languages.Select(l => l.Code).Distinct().Count());
        Assert.Equal(TesseractCatalog.Languages.Length, TesseractCatalog.Languages.Select(l => l.Tag).Distinct().Count());
        Assert.All(TesseractCatalog.Languages, l =>
        {
            Assert.Matches("^[0-9a-f]{64}$", l.Sha256);
            Assert.InRange(l.Size, 100_000, 50_000_000);
            Assert.Equal("raw.githubusercontent.com", l.Url.Host);
            Assert.Contains(TesseractCatalog.LanguageCommit, l.Url.AbsolutePath);
        });
    }

    [Theory]
    [InlineData("en-US", "eng")]
    [InlineData("es-MX", "spa")]
    [InlineData("zh-Hans-CN", "chi_sim")]
    [InlineData("zh-Hant-TW", "chi_tra")]
    [InlineData("zh-CN", "chi_sim")]
    [InlineData("zh-HK", "chi_tra")]
    [InlineData("sr-Latn-RS", "srp_latn")]
    [InlineData("sr-Cyrl-RS", "srp")]
    [InlineData("nb-NO", "nor")]
    [InlineData("hi", "hin")]
    [InlineData("uz-Cyrl", "uzb_cyrl")]
    [InlineData("xx-YY", null)]
    [InlineData("", null)]
    public void ATagFindsTesseractsLanguage(string tag, string? code) => Assert.Equal(code, TesseractCatalog.ForTag(tag)?.Code);

    // ---- The download ----

    private sealed class FakeServer(Func<HttpRequestMessage, HttpResponseMessage> answer) : HttpMessageHandler
    {
        public int Requests { get; private set; }

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Requests++;
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(answer(request));
        }
    }

    private static HttpResponseMessage Ok(byte[] body, bool length = true)
    {
        var content = length ? new ByteArrayContent(body) : (HttpContent)new StreamContent(new NoLengthStream(body));
        return new HttpResponseMessage(HttpStatusCode.OK) { Content = content };
    }

    /// <summary>A body the server doesn't announce the length of (chunked).</summary>
    private sealed class NoLengthStream(byte[] data) : MemoryStream(data)
    {
        public override bool CanSeek => false;
    }

    private static readonly Uri Url = new("https://example.test/eng.traineddata");

    [Fact]
    public async Task ADownloadIsKeptOnlyWithItsPinnedSizeAndHash()
    {
        using var temp = new TempFolder();
        var body = Encoding.UTF8.GetBytes("language model bytes");
        var sha = Convert.ToHexStringLower(SHA256.HashData(body));
        var path = Path.Combine(temp.Path, "tessdata", "eng.traineddata");
        var seen = new List<long>();
        using (var http = new HttpClient(new FakeServer(_ => Ok(body))))
            await PinnedDownload.FetchAsync(http, Url, body.Length, sha, path, new DirectProgress<long>(seen.Add));
        Assert.Equal(body, File.ReadAllBytes(path));
        Assert.Equal(body.Length, seen.Last());
        Assert.True(PinnedDownload.Matches(path, body.Length, sha));
        Assert.False(PinnedDownload.Matches(path, body.Length, new string('0', 64)));

        foreach (var (server, problem) in new (Func<HttpRequestMessage, HttpResponseMessage>, DownloadProblem)[]
                 {
                     (_ => Ok(Encoding.UTF8.GetBytes("language model bytez")), DownloadProblem.WrongContent),
                     (_ => Ok([.. body, 1]), DownloadProblem.WrongSize),
                     (_ => Ok([.. body, 1], length: false), DownloadProblem.WrongSize),
                     (_ => Ok(body[..^1], length: false), DownloadProblem.WrongSize),
                     (_ => new HttpResponseMessage(HttpStatusCode.NotFound), DownloadProblem.Network),
                     (_ => throw new HttpRequestException("no route"), DownloadProblem.Network),
                 })
        {
            var other = Path.Combine(temp.Path, "tessdata", "spa.traineddata");
            using var http = new HttpClient(new FakeServer(server));
            var ex = await Assert.ThrowsAsync<PinnedDownloadException>(() => PinnedDownload.FetchAsync(http, Url, body.Length, sha, other));
            Assert.Equal(problem, ex.Problem);
            Assert.False(File.Exists(other));
            Assert.False(File.Exists(other + ".part"));
        }
    }

    [Fact]
    public async Task ACancelledDownloadLeavesNothing()
    {
        using var temp = new TempFolder();
        var path = Path.Combine(temp.Path, "x.traineddata");
        using var cancel = new CancellationTokenSource();
        using var http = new HttpClient(new FakeServer(_ =>
        {
            cancel.Cancel();
            return Ok(new byte[100_000]);
        }));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => PinnedDownload.FetchAsync(http, Url, 100_000, new string('0', 64), path, cancel: cancel.Token));
        Assert.False(File.Exists(path));
        Assert.False(File.Exists(path + ".part"));
        await Assert.ThrowsAsync<ArgumentException>(() => PinnedDownload.FetchAsync(http, new Uri("http://example.test/x"), 1, new string('0', 64), path));
    }

    [Fact]
    public void TheStoreSaysWhatIsThereAndDeletesWhatIsntThePinnedFile()
    {
        using var temp = new TempFolder();
        var store = new TesseractStore(temp.Path);
        var eng = TesseractCatalog.ByCode("eng")!;
        Assert.False(store.HasEngine);
        Assert.False(store.HasLanguage(eng));
        Directory.CreateDirectory(store.LanguageFolder);
        File.WriteAllBytes(store.LanguageFile(eng), new byte[eng.Size]); // the right size, not the right bytes
        Assert.True(store.HasLanguage(eng));
        Assert.False(store.Verify([eng]));
        Directory.CreateDirectory(store.EngineFolder);
        foreach (var f in TesseractCatalog.EngineFiles) File.WriteAllBytes(Path.Combine(store.EngineFolder, f.Name), []);
        Assert.False(store.HasEngine);
        Assert.False(store.Verify([]));
        Assert.False(File.Exists(store.Executable)); // not the pinned file: deleted, so it is downloaded again
    }

    // ---- Which languages, which engine ----

    private static readonly (string, string)[] WindowsHas = [("en-US", "English (United States)"), ("es-MX", "Spanish (Mexico)")];

    [Fact]
    public void WindowsLanguagesComeFirstThenTesseractsOthers()
    {
        var offer = OcrLanguages.Offer(WindowsHas, l => l.EnglishName);
        Assert.Equal(["en-US", "es-MX"], offer.Take(2).Select(c => c.Tag));
        Assert.All(offer.Take(2), c => Assert.True(c.Windows));
        Assert.Equal("eng", offer[0].Tesseract?.Code);
        Assert.DoesNotContain(offer.Skip(2), c => c.Tesseract!.Code is "eng" or "spa");
        Assert.Contains(offer, c => c.Tag == "hi" && !c.Windows);
        var rest = offer.Skip(2).Select(c => c.Name).ToList();
        Assert.Equal(rest.Order(StringComparer.CurrentCultureIgnoreCase), rest);
        Assert.Equal(TesseractCatalog.Languages.Length, offer.Count);
        Assert.Equal("hi", OcrLanguages.Find(offer, "HI")?.Tag);
        Assert.Null(OcrLanguages.Find(offer, "fr-FR"));
    }

    [Fact]
    public void AChoiceSaysWhichEngineReadsItAndWhatToDownload()
    {
        var offer = OcrLanguages.Offer(WindowsHas, l => l.EnglishName);
        var (english, spanish, hindi, thai) = (offer[0], offer[1], OcrLanguages.Find(offer, "hi")!, OcrLanguages.Find(offer, "th")!);

        var plan = OcrLanguages.Plan(english, null, hasEngine: false, _ => false);
        Assert.Equal(OcrEngine.Windows, plan.Engine);
        Assert.False(plan.NeedsDownload);

        plan = OcrLanguages.Plan(english, spanish, false, _ => false);
        Assert.Equal(OcrEngine.Windows, plan.Engine);
        Assert.False(plan.NeedsDownload);

        plan = OcrLanguages.Plan(hindi, null, false, _ => false);
        Assert.Equal(OcrEngine.Tesseract, plan.Engine);
        Assert.True(plan.NeedsEngine);
        Assert.Equal(["hin"], plan.ToDownload.Select(l => l.Code));
        Assert.Equal(TesseractCatalog.InstallerSize + hindi.Tesseract!.Size, plan.DownloadBytes);

        plan = OcrLanguages.Plan(hindi, english, true, l => l.Code == "hin");
        Assert.Equal(OcrEngine.Tesseract, plan.Engine);
        Assert.Equal(["hin", "eng"], plan.Tesseract.Select(l => l.Code));
        Assert.False(plan.NeedsEngine);
        Assert.Equal(["eng"], plan.ToDownload.Select(l => l.Code));

        plan = OcrLanguages.Plan(thai, thai, true, _ => true);
        Assert.Null(plan.Second);
        Assert.False(plan.NeedsDownload);

        // A language Windows reads that Tesseract hasn't, with one only Tesseract reads: each its own, line by line.
        var klingon = new OcrLanguageChoice("tlh", "Klingon", true, null);
        plan = OcrLanguages.Plan(klingon, hindi, true, _ => true);
        Assert.Equal(OcrEngine.WindowsAndTesseract, plan.Engine);
        Assert.Equal(["hin"], plan.Tesseract.Select(l => l.Code));
    }

    // ---- Two languages on a page ----

    private sealed class WordList(string language, params string[] words) : ISpelling
    {
        private readonly HashSet<string> _words = [.. words];
        public string Language => language;
        public bool IsKnown(string word) => _words.Contains(word.ToLowerInvariant());
        public IReadOnlyList<string> Suggest(string word) => [];
    }

    private sealed class Fixed(string language, params RecognizedWord[] words) : ITextRecognizer
    {
        public int Calls { get; private set; }
        public string Language => language;
        public string LanguageName => language;

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            Calls++;
            return words;
        }
    }

    private static RecognizedWord W(string text, double x, double y, int line, double? confidence = null) => new(text, x, y, 40, 20, line, confidence);

    private static readonly ISpelling English = new WordList("en-US", "the", "black", "cat", "sleeps", "here");
    private static readonly ISpelling Spanish = new WordList("es-MX", "el", "gato", "negro", "duerme", "aquí");

    [Fact]
    public void EachLineIsKeptFromTheLanguageThatReadsItBetter()
    {
        // Line 1 English, line 2 Spanish; each recognizer garbles the other language's line.
        RecognizedWord[] english = [W("The", 10, 10, 0), W("black", 60, 10, 0), W("cat", 110, 10, 0), W("Ei", 10, 50, 1), W("gato", 60, 50, 1), W("negr0", 110, 50, 1)];
        RecognizedWord[] spanish = [W("Tbe", 10, 11, 0), W("blaek", 60, 11, 0), W("cat", 110, 11, 0), W("El", 10, 51, 1), W("gato", 60, 51, 1), W("negro", 110, 51, 1),
            W("aquí", 10, 90, 2)];
        var chosen = MixedRecognizer.Choose(english, English, spanish, Spanish);
        Assert.Equal(["The", "black", "cat", "El", "gato", "negro", "aquí"], chosen.Select(w => w.Text));
        Assert.Equal([0, 0, 0, 1, 1, 1, 2], chosen.Select(w => w.Line));

        // A tie stays with the first language; a line only the second read is kept in its place.
        chosen = MixedRecognizer.Choose([W("1234", 10, 10, 0), W("here", 10, 90, 1)], English, [W("1284", 10, 10, 0), W("aquí", 10, 50, 1)], Spanish);
        Assert.Equal(["1234", "aquí", "here"], chosen.Select(w => w.Text));
    }

    [Fact]
    public void WithoutADictionaryTheEnginesConfidenceDecides()
    {
        var chosen = MixedRecognizer.Choose([W("नमस्ते", 10, 10, 0, 35)], null, [W("नमस्ते", 10, 10, 0, 92), W("दुनिया", 60, 10, 0, 90)], null);
        Assert.Equal(2, chosen.Count);
        Assert.Equal(92, chosen[0].Confidence);
        Assert.True(MixedRecognizer.Plausibility(W("cat", 0, 0, 0), English) > MixedRecognizer.Plausibility(W("cat", 0, 0, 0), null));
        Assert.Equal(0, MixedRecognizer.Plausibility(W("1234", 0, 0, 0, 99), null));
    }

    [Fact]
    public void TwoRecognizersReadThePageAndTheSpellingsAnswerTogether()
    {
        var first = new Fixed("en-US", W("cat", 10, 10, 0));
        var second = new Fixed("es-MX", W("cta", 10, 10, 0));
        var mixed = new MixedRecognizer(first, English, second, Spanish);
        Assert.Equal("en-US", mixed.Language);
        Assert.Equal("en-US + es-MX", mixed.LanguageName);
        Assert.Equal(["cat"], mixed.Recognize([0], 1, 1, 1).Select(w => w.Text));
        Assert.Equal((1, 1), (first.Calls, second.Calls));
        Assert.Same(first, mixed.Rereader);

        var either = EitherSpelling.Of(English, Spanish)!;
        Assert.True(either.IsKnown("gato") && either.IsKnown("cat"));
        Assert.False(either.IsKnown("chat"));
        Assert.Same(English, EitherSpelling.Of(English, null));
    }

    // ---- Through Recognize Text's pipeline ----

    /// <summary>Tesseract's way: one word with a confidence for a whole page, and no re-reading of places it left out.</summary>
    private sealed class SureOfNothing : ITextRecognizer, IRereadsMissed
    {
        public int Calls { get; private set; }
        public string Language => "hi";
        public string LanguageName => "Hindi";
        public ITextRecognizer? Rereader => null;

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            Calls++;
            return [new RecognizedWord("नमस्ते", width * 0.1, height * 0.1, width * 0.2, height * 0.02, 0, 31), new RecognizedWord("दुनिया", width * 0.4, height * 0.1, width * 0.2, height * 0.02, 0, 95)];
        }
    }

    [Fact]
    public void AWordTheEngineWasUnsureOfIsASuspectAndNothingIsReadAgain()
    {
        using var pdf = PdfEngine.Open(ScanCorpus.Make(ScanCorpus.Files.Single(f => f.Name == "en-skew3-light") with { Pages = 1 }).Pdf, InputFileTypes.PDF, null);
        var reader = new SureOfNothing();
        var words = ScanText.Recognize(pdf, 0, reader, new RecognizeOptions()).Words;
        Assert.Equal(SuspectReasons.Unsure, words[0].Suspect & SuspectReasons.Unsure);
        Assert.Equal(SuspectReasons.None, words[1].Suspect & SuspectReasons.Unsure);
        // The cleaned page and the page as scanned (suspect words compare them), and none of the ink no word covers read alone.
        Assert.InRange(reader.Calls, 2, 3);
        var plain = ScanText.Recognize(pdf, 0, new SureOfNothing(), RecognizeOptions.AsScanned with { CheckWords = true }).Words;
        Assert.True(plain[0].Suspect.HasFlag(SuspectReasons.Unsure));
        Assert.Null(ScanText.RereaderOf(new SerialRecognizer(reader, new Lock())));
    }

    // ---- The program ----

    [Fact]
    public void TheEngineIsGivenThePageAsPgmAndItsLanguagesAtOnce()
    {
        var pgm = TesseractRecognizer.Pgm([10, 20, 30, 40, 50, 60], 2, 1, 3);
        Assert.Equal("P5\n2 1\n255\n", Encoding.ASCII.GetString(pgm, 0, 11));
        Assert.Equal(13, pgm.Length);
        Assert.Equal((byte)((10 * 29 + 20 * 150 + 30 * 77 + 128) >> 8), pgm[11]);
        var r = new TesseractRecognizer("C:\\t\\tesseract.exe", "C:\\data dir", [TesseractCatalog.ByCode("hin")!, TesseractCatalog.ByCode("eng")!], "Hindi + English");
        Assert.Equal("hi", r.Language);
        Assert.Null(r.Rereader);
        var args = r.Arguments();
        Assert.Equal("hin+eng", args[args.ToList().IndexOf("-l") + 1]);
        Assert.Equal("C:\\data dir", args[args.ToList().IndexOf("--tessdata-dir") + 1]);
        Assert.Contains("tessedit_create_tsv=1", args);
        Assert.Throws<ArgumentException>(() => r.Recognize([1, 2], 2, 2, 1));
    }

    private static ProcessStartInfo Cmd(string command)
    {
        var start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"));
        start.ArgumentList.Add("/d");
        start.ArgumentList.Add("/c");
        start.ArgumentList.Add(command);
        return start;
    }

    [Fact]
    public void AProgramThatTakesTooLongOrWritesTooMuchIsStopped()
    {
        var watch = Stopwatch.StartNew();
        var slow = Assert.Throws<BoundedProcessException>(() => BoundedProcess.Run(Cmd("ping -n 30 127.0.0.1 >nul"), [], 1000, TimeSpan.FromSeconds(1)));
        Assert.Contains("longer", slow.Message);
        Assert.True(watch.Elapsed < Timing.Limit(TimeSpan.FromSeconds(15)));

        var loud = Assert.Throws<BoundedProcessException>(() => BoundedProcess.Run(Cmd("for /l %i in (1,1,100000) do @echo 0123456789012345678901234567890123456789"), [], 10_000, TimeSpan.FromSeconds(30)));
        Assert.Contains("more than", loud.Message);

        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(500));
        Assert.ThrowsAny<OperationCanceledException>(() => BoundedProcess.Run(Cmd("ping -n 30 127.0.0.1 >nul"), [], 1000, TimeSpan.FromSeconds(30), cancel.Token));

        var ok = BoundedProcess.Run(Cmd("more"), Encoding.ASCII.GetBytes("hello\r\n"), 1000, TimeSpan.FromSeconds(30));
        Assert.Equal(0, ok.ExitCode);
        Assert.Contains("hello", Encoding.ASCII.GetString(ok.Output));
        Assert.Equal(3, BoundedProcess.Run(Cmd("exit 3"), [], 1000, TimeSpan.FromSeconds(30)).ExitCode);
        Assert.Throws<BoundedProcessException>(() => BoundedProcess.Run(new ProcessStartInfo("C:\\no\\such\\tesseract.exe"), [], 1000, TimeSpan.FromSeconds(5)));
    }

    // ---- The real engine (opt-in) ----

    [Fact]
    public async Task RealTesseractReadsAPage()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_TESSERACT") is not { Length: > 0 } where) return;
        using var temp = new TempFolder();
        var eng = TesseractCatalog.ByCode("eng")!;
        string exe, tessdata;
        if (where == "download")
        {
            var store = new TesseractStore(temp.Path);
            using var http = new HttpClient();
            await store.InstallEngineAsync(http);
            await store.InstallLanguageAsync(http, eng);
            Assert.True(new TesseractStore(temp.Path).Verify([eng]));
            (exe, tessdata) = (store.Executable, store.LanguageFolder);
        }
        else (exe, tessdata) = (Path.Combine(where, "tesseract.exe"), Path.Combine(where, "tessdata"));

        using var pdf = PdfEngine.Open(ScanCorpus.Make(ScanCorpus.Files.Single(f => f.Name == "en-skew3-light") with { Pages = 1 }).Pdf, InputFileTypes.PDF, null);
        var page = ScanText.Recognize(pdf, 0, new TesseractRecognizer(exe, tessdata, [eng], "English"), new RecognizeOptions(CheckWords: true));
        var text = string.Join(' ', page.Words.Select(w => w.Text));
        Assert.True(page.Words.Count > 100, text);
        Assert.Contains("the", text);
    }

    private sealed class TempFolder : IDisposable
    {
        public string Path { get; } = System.IO.Path.Combine(System.IO.Path.GetTempPath(), $"inkvolt-tesseract-{Guid.NewGuid():N}");

        public TempFolder() => Directory.CreateDirectory(Path);

        public void Dispose()
        {
            try
            {
                Directory.Delete(Path, recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // a program that just ended (or a virus scanner) still holds a file: the temp folder keeps it
            }
        }
    }
}
