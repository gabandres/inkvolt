using InkvoltPdf.Core;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Lines the recognizer skips, read again (<see cref="MissedLines"/>, through <see cref="ScanText"/>): Windows' recognizer
/// now and then leaves out a whole line that is plainly on the page (on the redaction corpus's first page it skips
/// "3434, card 4111 1111" and "1111 1111, born October"; pdf/tools/ocr-corpus measures that with the real one). Here a
/// stand-in reads every blob of ink as a word, and leaves out one line when it is handed a whole page.
/// </summary>
public class MissedLinesTests
{
    /// <summary>Reads lines of ink (rows with ink, split at white rows) and words in them (ink split at wide gaps).</summary>
    private sealed class BlobReader : ITextRecognizer
    {
        /// <summary>The line (counted from the top, from 0) not read when a whole page is.</summary>
        public int Skip { get; init; } = -1;
        public int PlacesRead { get; private set; }
        public string Language => "en-US";
        public string LanguageName => "English";

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
            var page = height > 1000;
            if (!page) PlacesRead++;
            var words = new List<RecognizedWord>();
            var line = 0;
            foreach (var (y0, y1) in Runs(height, y => Count(width, x => gray[y * width + x] < 128) >= 3, 2))
            {
                if (y1 - y0 >= 12 && !(page && line == Skip))
                {
                    foreach (var (x0, x1) in Runs(width, x => Count(y1 - y0, i => gray[(y0 + i) * width + x] < 128) > 0, 12))
                    {
                        if (x1 - x0 < 3) continue; // a narrow l or 1 is a word too
                        var rows = Enumerable.Range(y0, y1 - y0).Where(y => Enumerable.Range(x0, x1 - x0).Any(x => gray[y * width + x] < 128)).ToList();
                        words.Add(new RecognizedWord("word", x0, rows[0], x1 - x0, rows[^1] - rows[0] + 1, line));
                    }
                }
                if (y1 - y0 >= 12) line++;
            }
            return words;
        }

        private static int Count(int n, Func<int, bool> f)
        {
            var c = 0;
            for (var i = 0; i < n; i++)
                if (f(i)) c++;
            return c;
        }

        private static List<(int, int)> Runs(int n, Func<int, bool> on, int gap)
        {
            var runs = new List<(int, int)>();
            int start = -1, end = -1;
            for (var i = 0; i < n; i++)
            {
                if (!on(i)) continue;
                if (start >= 0 && i - end <= gap) end = i + 1;
                else
                {
                    if (start >= 0) runs.Add((start, end));
                    (start, end) = (i, i + 1);
                }
            }
            if (start >= 0) runs.Add((start, end));
            return runs;
        }
    }

    private static byte[] LightScan() => ScanCorpus.Make(ScanCorpus.Files.Single(f => f.Name == "en-skew3-light") with { Pages = 1 }).Pdf;

    private static readonly RecognizeOptions Plain = new(CheckWords: false);

    [Fact]
    public void ALineTheRecognizerSkipsIsReadAgainAndPutInItsPlace()
    {
        using var pdf = PdfEngine.Open(LightScan(), InputFileTypes.PDF, null);
        var all = ScanText.Recognize(pdf, 0, new BlobReader(), Plain with { RereadMissed = false }).Words;
        var skipping = new BlobReader { Skip = 6 };
        var without = ScanText.Recognize(pdf, 0, new BlobReader { Skip = 6 }, Plain with { RereadMissed = false }).Words;
        var page = ScanText.Recognize(pdf, 0, skipping, Plain).Words;

        Assert.True(all.Count - without.Count >= 5, $"the skipped line had {all.Count - without.Count} words");
        // Read again on its own: every word back, where it is on the page, in reading order, none twice.
        Assert.Equal(all.Count, page.Count);
        for (var i = 0; i < all.Count; i++)
        {
            Assert.Equal(all[i].Rect.CenterX, page[i].Rect.CenterX, 1.5);
            Assert.Equal(all[i].Rect.CenterY, page[i].Rect.CenterY, 1.5);
        }
        Assert.InRange(skipping.PlacesRead, 1, MissedLines.MaxReads);
    }

    [Fact]
    public void NothingIsReadAgainWhenEveryLineWasRead()
    {
        using var pdf = PdfEngine.Open(LightScan(), InputFileTypes.PDF, null);
        var reader = new BlobReader();
        ScanText.Recognize(pdf, 0, reader, Plain);
        Assert.Equal(0, reader.PlacesRead); // the specks and the paper's noise aren't lines
    }

    /// <summary>A white 300 dpi page; <paramref name="draw"/> blackens rectangles (x, y, w, h).</summary>
    private static GrayImage Page(Action<Action<int, int, int, int>> draw)
    {
        const int w = 2550, h = 3300;
        var px = Enumerable.Repeat((byte)255, w * h).ToArray();
        draw((x0, y0, bw, bh) =>
        {
            for (var y = y0; y < y0 + bh; y++)
                for (var x = x0; x < x0 + bw; x++)
                    px[y * w + x] = 0;
        });
        return new GrayImage(w, h, px);
    }

    /// <summary>A line of "type" at (x, y): words of letters, each letter a 5 px stroke 34 px tall, 14 px apart.</summary>
    private static void Type(Action<int, int, int, int> box, int x, int y, int words)
    {
        for (var word = 0; word < words; word++, x += 24)
            for (var letter = 0; letter < 5; letter++, x += 19)
                box(x, y + (letter % 2) * 8, 5, 34 - (letter % 2) * 8);
    }

    [Fact]
    public void OnlyInkThatLooksLikeTypeIsReadAgain()
    {
        var gray = Page(box =>
        {
            box(300, 400, 1800, 4);   // a rule
            box(300, 600, 1800, 40);  // a filled bar
            box(300, 800, 200, 200);  // a block (a picture, say)
            for (var i = 0; i < 30; i++) box(300 + i * 60, 1200 + i * 7 % 20, 3, 3); // dust along a line
            Type(box, 300, 1700, 6);
        });
        var place = Assert.Single(MissedLines.Find(gray, [], 300));
        Assert.Equal((300, 1700), (place.X, place.Y));
        Assert.Equal(34, place.Height);
    }

    [Fact]
    public void TheRestOfAWordReadShortIsNotReadAgain()
    {
        var gray = Page(box => Type(box, 300, 1700, 6));
        // Read as two words where there are six: the ink beside them is that line's, not a line skipped.
        RecognizedWord[] read = [new("short", 300, 1700, 100, 34, 0), new("read", 420, 1700, 80, 34, 0)];
        Assert.Empty(MissedLines.Find(gray, read, 300));
        // A line below them that nobody read is.
        var two = Page(box =>
        {
            Type(box, 300, 1700, 6);
            Type(box, 300, 1800, 6);
        });
        Assert.Equal(1800, Assert.Single(MissedLines.Find(two, [new("line", 300, 1700, 690, 34, 0)], 300)).Y);
    }

    [Fact]
    public void ReadingAgainStopsWhenCancelled()
    {
        var gray = Page(box => Type(box, 300, 1700, 6));
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => MissedLines.Reread(gray, [], 300, new BlobReader(), cancel.Token));
    }

    [Fact]
    public void AtMostAFewPlacesArePickedOnAPageOfUnreadLines()
    {
        var gray = Page(box =>
        {
            for (var line = 0; line < 40; line++) Type(box, 300, 300 + line * 70, 8);
        });
        var places = MissedLines.Find(gray, [], 300);
        Assert.Equal(MissedLines.MaxRereads, places.Count);
        Assert.Equal(places.OrderBy(p => p.Y).ToList(), places); // top to bottom
    }

    /// <summary>
    /// Reads strokes the way Windows' recognizer fails on them: lines (rows of ink), words (ink closer than 16 px), and in a
    /// word each stroke (columns of ink) one character. A word of strokes all 34 px tall is that many 1s, any other a
    /// "word". Four 1s or more in a word, and the whole line they are in isn't read (as "1111"); a lone 1 isn't read either.
    /// <see cref="Drop"/>: a word (line, word, counted from 0) left out when a whole page is read, read when alone.
    /// </summary>
    private sealed class StrokeReader : ITextRecognizer
    {
        public (int Line, int Word)? Drop { get; init; }
        public int PlacesRead { get; private set; }
        public string Language => "en-US";
        public string LanguageName => "English";

        public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
        {
            var page = height > 1000;
            if (!page) PlacesRead++;
            bool Ink(int x, int y) => pixels[(y * width + x) * channels] < 128;
            var words = new List<RecognizedWord>();
            var line = 0;
            foreach (var (y0, y1) in Runs(height, y => Enumerable.Range(0, width).Any(x => Ink(x, y)), 2))
            {
                var row = new List<RecognizedWord>();
                var ones = false;
                var index = 0;
                foreach (var (x0, x1) in Runs(width, x => Enumerable.Range(y0, y1 - y0).Any(y => Ink(x, y)), 16))
                {
                    var strokes = Runs(x1 - x0, i => Enumerable.Range(y0, y1 - y0).Any(y => Ink(x0 + i, y)), 0)
                        .Select(s => Enumerable.Range(y0, y1 - y0).Count(y => Enumerable.Range(x0 + s.Item1, s.Item2 - s.Item1).Any(x => Ink(x, y)))).ToList();
                    var text = strokes.All(h => h == 34) ? new string('1', strokes.Count) : "word";
                    ones |= text.Length >= 4 && text.All(c => c == '1');
                    var skip = text == "1" || (page && Drop == (line, index));
                    index++;
                    if (!skip) row.Add(new RecognizedWord(text, x0, y0, x1 - x0, y1 - y0, line));
                }
                if (!ones) words.AddRange(row);
                line++;
            }
            return words;
        }

        private static List<(int, int)> Runs(int n, Func<int, bool> on, int gap)
        {
            var runs = new List<(int, int)>();
            int start = -1, end = -1;
            for (var i = 0; i < n; i++)
            {
                if (!on(i)) continue;
                if (start >= 0 && i - end <= gap) end = i + 1;
                else
                {
                    if (start >= 0) runs.Add((start, end));
                    (start, end) = (i, i + 1);
                }
            }
            if (start >= 0) runs.Add((start, end));
            return runs;
        }
    }

    /// <summary>A word of letters at (x, y): five strokes 3 px apart, tall and short by turns (as type has); returns the x after it and a space.</summary>
    private static int Letters(Action<int, int, int, int> box, int x, int y)
    {
        for (var letter = 0; letter < 5; letter++, x += 8)
            box(x, y + (letter % 2) * 10, 5, 34 - (letter % 2) * 10);
        return x + 37;
    }

    /// <summary>A number of 1s at (x, y): <paramref name="n"/> strokes 34 px tall, 14 px apart; returns the x after it and a space.</summary>
    private static int Ones(Action<int, int, int, int> box, int x, int y, int n)
    {
        for (var i = 0; i < n; i++, x += 19) box(x, y, 5, 34);
        return x + 26;
    }

    private static List<string> Line(IReadOnlyList<RecognizedWord> words, int y) =>
        [.. words.Where(w => Math.Abs(w.Y + w.Height / 2 - (y + 17)) < 17).OrderBy(w => w.X).Select(w => w.Text)];

    [Fact]
    public void FourOnesInARowAreReadInPiecesAndTheLineTheyWereInComesBack()
    {
        var gray = Page(box =>
        {
            Letters(box, Letters(box, 300, 1000), 1000);
            Letters(box, Ones(box, Letters(box, 300, 1100), 1100, 4), 1100);   // "word 1111 word": the recognizer leaves the line out
            Ones(box, Ones(box, 300, 1200, 4), 1200, 4);                         // "1111 1111": two numbers, a space apart
            Letters(box, Ones(box, Letters(box, 300, 1300), 1300, 7), 1300);   // "word 1111111 word"
            Letters(box, Ones(box, Letters(box, 300, 1400), 1400, 3), 1400);   // "word 111 word" is read as it is
        });
        var reader = new StrokeReader();
        var page = reader.Recognize(gray.Pixels, gray.Width, gray.Height, 1);
        Assert.Empty(Line(page, 1100));
        Assert.Equal(["word", "111", "word"], Line(page, 1400));

        var words = MissedLines.Reread(gray, page, 300, reader);
        Assert.Equal(["word", "word"], Line(words, 1000));
        Assert.Equal(["word", "1111", "word"], Line(words, 1100));
        Assert.Equal(["1111", "1111"], Line(words, 1200));
        Assert.Equal(["word", "1111111", "word"], Line(words, 1300));
        Assert.Equal(["word", "111", "word"], Line(words, 1400));
        Assert.InRange(reader.PlacesRead, 1, MissedLines.MaxReads);
        // In page order: the lines read again go where they are on the page.
        Assert.Equal(words.OrderBy(w => w.Y).Select(w => w.Y).ToList(), words.Select(w => w.Y).ToList());
    }

    [Fact]
    public void AWordLeftOutInsideALineReadIsReadAgainAndPutInItsPlace()
    {
        var gray = Page(box =>
        {
            for (var line = 0; line < 3; line++)
            {
                var x = 300;
                for (var word = 0; word < 6; word++) x = word == 3 && line == 1 ? Ones(box, x, 1000 + line * 100, 3) : Letters(box, x, 1000 + line * 100);
            }
        });
        var all = new StrokeReader().Recognize(gray.Pixels, gray.Width, gray.Height, 1);
        foreach (var drop in new[] { (1, 3), (1, 0), (1, 5), (2, 2) })
        {
            var reader = new StrokeReader { Drop = drop };
            var page = reader.Recognize(gray.Pixels, gray.Width, gray.Height, 1);
            Assert.Equal(all.Count - 1, page.Count);
            var words = MissedLines.Reread(gray, page, 300, reader);
            // Every word back once, where it was, in its line's order, as one of that line.
            Assert.Equal(all.Select(w => (w.Text, w.X, w.Y, w.Line)), words.Select(w => (w.Text, w.X, w.Y, w.Line)));
            Assert.InRange(reader.PlacesRead, 1, 3);
        }
    }

    [Fact]
    public void NothingInsideALineIsReadAgainWhenItsWordsWereAllRead()
    {
        var gray = Page(box =>
        {
            Letters(box, Letters(box, 300, 1000), 1000);
            box(560, 1028, 5, 9);  // a comma after it
            box(300, 1100, 5, 34); // a 1 alone (the recognizer never reads it), far from any line read
        });
        // Read short: the box ends inside "word", the rest of its ink touches it.
        RecognizedWord[] read = [new("wo", 300, 1000, 20, 34, 0), new("word", 377, 1000, 37, 34, 0)];
        Assert.Empty(MissedLines.FindInLines(gray, read, 300));
        Assert.Empty(MissedLines.FindInLines(gray, [new("word", 300, 1000, 37, 34, 0), new("word", 377, 1000, 37, 34, 0)], 300));
    }

    [Theory]
    [InlineData("word", true)]
    [InlineData("(river),", true)]
    [InlineData("don't", true)]
    [InlineData("922.04", true)]
    [InlineData("4", true)]
    [InlineData("IY).70", false)]
    [InlineData("105;OO", false)]
    [InlineData("Vt\\e", false)]
    [InlineData("-", false)]
    [InlineData("c0de", false)]
    public void OnlyPlainWordsAreTakenFromInsideALine(string text, bool plain) => Assert.Equal(plain, MissedLines.Plain(text));
}
