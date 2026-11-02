using System.Diagnostics;
using System.Globalization;
using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Bench;

/// <summary>
/// Roadmap 3.5's test: a folder of PDFs indexed once, word queries timed, a changed file found again. The corpus is made on
/// the PC, outside the repository, and is the same on every PC: office-like files of 1 to 24 pages (a mean of about 8) of
/// made-up prose over a large vocabulary, with a reference number of their own on each page, so the list of terms grows as
/// it does on real files. A few words are planted so a query knows what to expect: "quillwort" on every 3,333rd file,
/// "résumé" with its accents on every 50th, and "lantern" from the prose on most pages. Six files aren't indexable
/// on purpose: damaged, cut short, password-protected, too big, and an image with no text.
/// </summary>
public static class FolderIndexBench
{
    private const string Fonts = "<< /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >> >> >>";

    /// <summary>One of 300,000 made-up words, the low numbers far more often than the high ones, as a real folder's words are: names, codes, typos.</summary>
    private static string Word(ref Rng rng)
    {
        var seed = new Rng(13_000_027UL * (ulong)(1 + rng.Next(1 + rng.Next(300_000))) + 3);
        return MadeUp(ref seed);
    }

    private static string MadeUp(ref Rng rng)
    {
        ReadOnlySpan<string> start = ["b", "br", "c", "ch", "d", "dr", "f", "g", "gl", "h", "j", "k", "l", "m", "n", "p", "pl", "qu", "r", "s", "sh", "st", "t", "tr", "v", "w", "z"];
        ReadOnlySpan<string> mid = ["a", "e", "i", "o", "u", "ai", "ea", "io", "ou"];
        ReadOnlySpan<string> end = ["", "n", "r", "s", "t", "l", "m", "nd", "st", "ck", "ng", "rt", "lm"];
        var sb = new StringBuilder();
        var syllables = 1 + rng.Next(3);
        for (var i = 0; i < syllables; i++)
        {
            sb.Append(start[rng.Next(start.Length)]);
            sb.Append(mid[rng.Next(mid.Length)]);
        }
        sb.Append(end[rng.Next(end.Length)]);
        return sb.ToString();
    }

    private static string Page(int file, int page, ref Rng rng)
    {
        var sb = new StringBuilder(2600);
        var y = 720.0;
        sb.Append($"BT /F1 14 Tf 72 {y} Td (Reference REF-{file:D6}-{page:D3}) Tj ET\n");
        y -= 26;
        sb.Append("BT /F1 11 Tf 14 TL 72 ").Append(y.ToString(CultureInfo.InvariantCulture)).Append(" Td\n");
        var line = new StringBuilder();
        for (var lines = 0; lines < 44; )
        {
            var word = rng.Next(5) == 0 ? Word(ref rng) : Prose.Word(ref rng);
            if (line.Length + word.Length > 90)
            {
                sb.Append(PdfFileWriter.Str(line.ToString())).Append(" Tj T*\n");
                line.Clear();
                lines++;
            }
            line.Append(word).Append(' ');
        }
        if (page == 0 && file % 3333 == 7) sb.Append("(a note on quillwort in the marsh) Tj T*\n");
        sb.Append("ET\n");
        // "résumé" in WinAnsi, written straight into the content's bytes (the content is Latin-1).
        if (page == 0 && file % 50 == 3) sb.Append("BT /F1 11 Tf 72 60 Td (Attached: my résumé and a CAFÉ receipt) Tj ET\n");
        return sb.ToString();
    }

    private static void WriteFile(string path, int file)
    {
        var rng = new Rng(7_000_003UL * (ulong)file + 11);
        var pages = 1 + rng.Next(rng.Next(4) == 0 ? 24 : 10);
        using var w = new PdfFileWriter(new BufferedStream(File.Create(path), 1 << 16));
        var info = w.Add($"<< /Title {PdfFileWriter.Str($"File {file}")} /Producer (Inkvolt PDF benchmark corpus) >>");
        var resources = w.Add(Fonts);
        var tree = new PageTree(w, pages);
        for (var p = 0; p < pages; p++)
        {
            var content = w.AddStream("", Encoding.Latin1.GetBytes(Page(file, p, ref rng)));
            var page = w.Add($"<< /Type /Page /Parent {tree.ParentOf(p)} 0 R /MediaBox [0 0 612 792] /Resources {resources} 0 R /Contents {content} 0 R >>");
            tree.Add(page);
        }
        tree.Write();
        var root = w.Add($"<< /Type /Catalog /Pages {tree.RootId} 0 R >>");
        w.Finish(root, info, $"{file:D32}");
    }

    /// <summary>Makes <paramref name="count"/> PDFs in 100 subfolders of <paramref name="dir"/>, and the six that can't be indexed.</summary>
    public static void Make(string dir, int count, Action<string> log)
    {
        var sw = Stopwatch.StartNew();
        Directory.CreateDirectory(dir);
        var folders = Enumerable.Range(0, 100).Select(i => Directory.CreateDirectory(Path.Combine(dir, $"box{i:D2}")).FullName).ToArray();
        Parallel.For(0, count, file => WriteFile(Path.Combine(folders[file % 100], $"file{file:D6}.pdf"), file));

        var bad = Directory.CreateDirectory(Path.Combine(dir, "bad")).FullName;
        File.WriteAllBytes(Path.Combine(bad, "damaged.pdf"), Encoding.ASCII.GetBytes("%PDF-1.7\nthis is not a PDF at all\n"));
        File.WriteAllBytes(Path.Combine(bad, "empty.pdf"), []);
        var whole = Path.Combine(dir, "box00", "file000000.pdf");
        var bytes = File.ReadAllBytes(whole);
        File.WriteAllBytes(Path.Combine(bad, "cut-short.pdf"), bytes[..(bytes.Length / 3)]);
        // A file over the limit, without taking the disk: sparse, and refused before anything reads it.
        using (var huge = new FileStream(Path.Combine(bad, "huge.pdf"), FileMode.Create))
        {
            huge.Write(Encoding.ASCII.GetBytes("%PDF-1.7\n"));
            huge.SetLength(600L * 1048576);
        }
        WriteLocked(Path.Combine(bad, "password.pdf"));
        WriteImageOnly(Path.Combine(bad, "no-text.pdf"));
        var size = new DirectoryInfo(dir).EnumerateFiles("*.pdf", SearchOption.AllDirectories).Where(f => f.Name != "huge.pdf").Sum(f => f.Length);
        log($"{count:N0} PDFs and 6 bad ones in {dir}: {size / 1048576.0:N0} MB, in {sw.Elapsed.TotalSeconds:N1} s");
    }

    private static void WriteLocked(string path)
    {
        using var ms = new MemoryStream();
        WriteFile(path, 1);
        using var doc = PdfSharp.Pdf.IO.PdfReader.Open(path, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify);
        doc.SecuritySettings.UserPassword = "secret";
        doc.SecuritySettings.OwnerPassword = "owner";
        doc.Save(ms, false);
        doc.Dispose();
        File.WriteAllBytes(path, ms.ToArray());
    }

    private static void WriteImageOnly(string path)
    {
        using var w = new PdfFileWriter(new BufferedStream(File.Create(path), 1 << 16));
        var info = w.Add("<< /Title (No text) >>");
        var image = w.AddStream("/Type /XObject /Subtype /Image /Width 8 /Height 8 /ColorSpace /DeviceGray /BitsPerComponent 8", new byte[64]);
        var resources = w.Add($"<< /XObject << /I {image} 0 R >> >>");
        var tree = new PageTree(w, 1);
        var content = w.AddStream("", "q 612 0 0 792 0 0 cm /I Do Q\n"u8);
        tree.Add(w.Add($"<< /Type /Page /Parent {tree.ParentOf(0)} 0 R /MediaBox [0 0 612 792] /Resources {resources} 0 R /Contents {content} 0 R >>"));
        tree.Write();
        var root = w.Add($"<< /Type /Catalog /Pages {tree.RootId} 0 R >>");
        w.Finish(root, info, new string('0', 32));
    }

    /// <summary>Indexes the folder once from nothing, runs the queries, changes a file: prints what each took. 1 if a target is missed.</summary>
    public static int Run(string dir, Action<string> log)
    {
        var indexDir = Path.Combine(Path.GetTempPath(), "inkvolt-index-bench-" + Guid.NewGuid().ToString("N"));
        var basePath = Path.Combine(indexDir, "bench");
        var exe = Environment.ProcessPath!;
        var missed = false;
        try
        {
            log($"Corpus {dir}: {Directory.EnumerateFiles(dir, "*.pdf", SearchOption.AllDirectories).Count():N0} files; {Environment.ProcessorCount} cores; " +
                $"optimized: {!(typeof(FolderIndexBench).Assembly.GetCustomAttributes(typeof(DebuggableAttribute), false).FirstOrDefault() is DebuggableAttribute { IsJITOptimizerDisabled: true })}.");
            var sw = Stopwatch.StartNew();
            var indexer = new FolderIndexer(dir, basePath, new FolderIndexerOptions { WorkerExe = exe, MaxWorkers = int.TryParse(Environment.GetEnvironmentVariable("INKVOLTPDF_BENCH_WORKERS"), out var workers) ? workers : new FolderIndexerOptions().MaxWorkers });
            var peak = 0L;
            using var done = new ManualResetEventSlim();
            var lastLog = Stopwatch.StartNew();
            indexer.Changed += () =>
            {
                if (indexer.Status.Phase == IndexerPhase.UpToDate) done.Set();
                if (lastLog.Elapsed.TotalSeconds > 10)
                {
                    lastLog.Restart();
                    log($"  {sw.Elapsed.TotalSeconds,5:N0} s: {indexer.Status.Text}");
                }
            };
            indexer.Start();
            while (!done.Wait(500))
            {
                using var me = Process.GetCurrentProcess();
                peak = Math.Max(peak, me.WorkingSet64);
            }
            var index = indexer.Index!;
            using (var me = Process.GetCurrentProcess())
                log($"Indexed in {sw.Elapsed.TotalSeconds:N1} s ({indexer.Status.Searchable / sw.Elapsed.TotalSeconds:N0} files/s); this process's working set at most {peak / 1048576.0:N0} MB, its CPU {me.TotalProcessorTime.TotalSeconds:N1} s.");
            log($"  {indexer.Status.Text}");
            var size = index.FileBytes;
            log($"  Index file: {size / 1048576.0:N0} MB, {index.Segments} segment(s), {index.TermsForBench:N0} terms, {index.Files.Values.Sum(f => f.Pages):N0} pages.");
            foreach (var s in indexer.Skipped()) log($"    {s.RelativePath}: {s.Reason}");

            missed |= !Queries(index, log);
            index.ForgetCaches();
            log("After forgetting the terms in memory, as after a restart:");
            missed |= !Queries(index, log);

            // A changed file: its old text goes out, a new word comes in, through the same path a save takes.
            var target = Path.Combine(dir, "box42", "file000042.pdf");
            var backup = File.ReadAllBytes(target);
            for (var round = 0; round < 3; round++)
            {
                var word = $"changedword{Environment.TickCount64}";
                WriteChanged(target, word);
                var changed = Stopwatch.StartNew();
                while (changed.Elapsed.TotalSeconds < 120 && Found(indexer.Index!, word) == 0) Thread.Sleep(50);
                var found = Found(indexer.Index!, word);
                log($"Changed file found again in {changed.Elapsed.TotalSeconds:N2} s ({found} page; target: within a minute).");
                missed |= found == 0 || changed.Elapsed.TotalSeconds > 60;
                Thread.Sleep(1000);
            }
            File.WriteAllBytes(target, backup);

            // Opening again from the file, the way a restart does.
            var stopped = Stopwatch.StartNew();
            indexer.Dispose();
            log($"Stopped in {stopped.Elapsed.TotalMilliseconds:N0} ms.");
            var reopen = Stopwatch.StartNew();
            using (var again = FolderIndex.Open(basePath))
            {
                log($"Opened again in {reopen.Elapsed.TotalMilliseconds:N0} ms: {again.Files.Count:N0} files.");
                missed |= !Queries(again, log);
            }
            log(missed ? "A TARGET WAS MISSED." : "Every target met.");
            return missed ? 1 : 0;
        }
        finally
        {
            try
            {
                Directory.Delete(indexDir, true);
            }
            catch (IOException) { }
        }
    }

    private static int Found(FolderIndex index, string word)
    {
        using var run = index.Search(word);
        return run.Hits().Count();
    }

    private static void WriteChanged(string path, string word)
    {
        var tmp = path + ".tmp";
        using (var w = new PdfFileWriter(new BufferedStream(File.Create(tmp), 1 << 16)))
        {
            var info = w.Add("<< /Title (Changed) >>");
            var resources = w.Add(Fonts);
            var tree = new PageTree(w, 1);
            var content = w.AddStream("", Encoding.Latin1.GetBytes($"BT /F1 14 Tf 72 700 Td ({word}) Tj ET\n"));
            tree.Add(w.Add($"<< /Type /Page /Parent {tree.ParentOf(0)} 0 R /MediaBox [0 0 612 792] /Resources {resources} 0 R /Contents {content} 0 R >>"));
            tree.Write();
            var root = w.Add($"<< /Type /Catalog /Pages {tree.RootId} 0 R >>");
            w.Finish(root, info, new string('1', 32));
        }
        File.Move(tmp, path, overwrite: true);
    }

    private static bool Queries(FolderIndex index, Action<string> log)
    {
        var ok = true;
        foreach (var (query, what, wanted) in new (string, string, int?)[]
                 {
                     ("quillwort", "a rare word", null),
                     ("QUILLWORT", "in capitals", null),
                     ("resume", "accents in the files, none in the query", null),
                     ("résumé", "accents in the query", null),
                     ("lantern", "on most pages", null),
                     ("lant", "the start of a word", null),
                     ("ntern", "inside a word", null),
                     ("e", "one letter", null),
                     ("REF-000042-000", "a reference, cut into words", null),
                     ("nosuchwordanywhere", "not there", 0),
                 })
        {
            ok &= OneQuery(index, query, what, wanted, log);
        }
        // Phrases aren't what the target is about, but a person will type them: both words common, and rarely or never side by side.
        foreach (var (query, what) in new[]
                 {
                     ("the lantern", "a phrase of two common words"),
                     ("lantern quietly harbor", "three words, never side by side"),
                     ("a note on quillwort", "a phrase with a rare word"),
                 })
            OneQuery(index, query, what, null, log, target: false);
        return ok;
    }

    private static bool OneQuery(FolderIndex index, string query, string what, int? wanted, Action<string> log, bool target = true)
    {
        var ok = true;
        {
            var sw = Stopwatch.StartNew();
            using var run = index.Search(query, new FolderSearchOptions());
            var narrowed = sw.Elapsed.TotalMilliseconds;
            var first = -1.0;
            var pages = 0;
            foreach (var _ in run.Hits())
            {
                if (pages++ == 0) first = sw.Elapsed.TotalMilliseconds;
            }
            var all = sw.Elapsed.TotalMilliseconds;
            var miss = target && all >= 1000;
            ok &= !miss;
            if (wanted is { } n && pages != n) ok = false;
            log($"  {query,-22} {what,-44} {run.CandidatePages,8:N0} pages in {run.CandidateFiles,7:N0} files; narrowed {narrowed,7:N1} ms, first result {first,7:N1} ms, {pages,4} listed {all,8:N1} ms{(miss ? "  OVER 1 s" : "")}");
        }
        return ok;
    }

    /// <summary>Commits small batches for ever, for a test to kill at any moment. A line with each commit, once it has returned.</summary>
    public static int WriteForever(string basePath)
    {
        using var index = FolderIndex.Open(basePath);
        var n = index.Files.Count;
        Console.Out.Flush();
        while (true)
        {
            var batch = index.NewBatch();
            for (var i = 0; i < 5; i++, n++)
            {
                string?[] pages = [string.Join(' ', Enumerable.Range(0, 400).Select(w => $"w{(w * 7 + n) % 1000}")) + $" unique{n}x"];
                batch.Add($"f{n:D7}.pdf", n, n, IndexedState.Indexed, 1, 0, FolderIndex.PackPages(pages), pages);
            }
            index.Commit(batch);
            Console.WriteLine(n);
            Console.Out.Flush();
        }
    }
}
