using System.Diagnostics;
using System.Runtime.InteropServices;
using InkvoltPdf.Core;
using PdfSharp.Drawing;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>The indexer on real PDFs through real worker processes (the bench tool takes the app's switch): keeping up, skipping what can't be read, pause and stop.</summary>
public sealed class FolderIndexerTests : IDisposable
{
    private static string WorkerExe => Path.Combine(AppContext.BaseDirectory, "Bench.exe");
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "inkvolt-indexer-" + Guid.NewGuid().ToString("N"));
    private readonly List<FolderIndexer> _indexers = [];
    private string Folder => Path.Combine(_dir, "folder");
    private string Base => Path.Combine(_dir, "index", "folder");

    public FolderIndexerTests() => Directory.CreateDirectory(Folder);

    public void Dispose()
    {
        foreach (var i in _indexers) i.Dispose();
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                Directory.Delete(_dir, true);
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
    }

    private FolderIndexer Start(FolderIndexerOptions? options = null, bool paused = false)
    {
        var indexer = new FolderIndexer(Folder, Base, (options ?? Quick()) with { WorkerExe = (options ?? Quick()).WorkerExe ?? WorkerExe }, paused);
        _indexers.Add(indexer);
        indexer.Start();
        return indexer;
    }

    /// <summary>Quick to notice and to look again, with no waiting for a file to settle (each test's files are complete when it writes them).</summary>
    private static FolderIndexerOptions Quick() => new()
    {
        Quiet = TimeSpan.Zero,
        Debounce = TimeSpan.FromMilliseconds(100),
        Rescan = TimeSpan.FromSeconds(30),
        CommitEvery = TimeSpan.FromMilliseconds(200),
        MaxWorkers = 2,
    };

    /// <summary>Workers run below normal priority, so on a busy PC they wait their turn: the waits here are long, and no test times one closely.</summary>
    private static void WaitUntil(Func<bool> condition, string what, int seconds = 240, FolderIndexer? about = null)
    {
        var sw = Stopwatch.StartNew();
        while (!condition())
        {
            Assert.True(sw.Elapsed.TotalSeconds < seconds, $"Waited {seconds} s for {what}. {about?.Status.Text}");
            Thread.Sleep(20);
        }
    }

    private static void UpToDate(FolderIndexer indexer, int searchable) =>
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.UpToDate && indexer.Status.Searchable == searchable, $"{searchable} files up to date", about: indexer);

    private static List<FolderHit> Search(FolderIndexer indexer, string query, FolderSearchOptions? options = null)
    {
        using var run = indexer.Index!.Search(query, options);
        return [.. run.Hits()];
    }

    private string Put(string name, string marker, int pages = 1)
    {
        var path = Path.Combine(Folder, name);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        File.WriteAllBytes(path, TestPdf.Make(pages, marker));
        return path;
    }

    [Fact]
    public void A_folder_is_indexed_with_its_subfolders_and_opened_at_the_hit()
    {
        Put("one.pdf", "alpha", 2);
        Put(@"sub\deep\two.pdf", "bravo", 3);
        File.WriteAllText(Path.Combine(Folder, "notes.txt"), "alpha in a file that is no PDF");
        using var indexer = TakeOwnership(Start());
        UpToDate(indexer, 2);

        var alpha = Search(indexer, "alpha");
        Assert.Equal(new[] { "one.pdf" }, alpha.Select(h => h.RelativePath).Distinct());
        Assert.Equal([0, 1], alpha.Select(h => h.Page));
        Assert.Contains("Page 2 alpha", alpha[1].Excerpt);
        Assert.Equal(new[] { @"sub\deep\two.pdf" }, Search(indexer, "bravo").Select(h => h.RelativePath).Distinct());
        Assert.Empty(indexer.Skipped());
    }

    private FolderIndexer TakeOwnership(FolderIndexer indexer)
    {
        _indexers.Remove(indexer);
        return indexer;
    }

    [Fact]
    public void Accents_and_case_are_ignored_as_Find_does_on_a_real_pdf()
    {
        TestPdf.UseFonts();
        using (var doc = new PdfDocument())
        {
            var page = doc.AddPage();
            using (var gfx = XGraphics.FromPdfPage(page))
                gfx.DrawString("Le RÉSUMÉ du Café", new XFont("Arial", 14), XBrushes.Black, new XPoint(72, 100));
            doc.Save(Path.Combine(Folder, "fr.pdf"));
        }
        using var indexer = TakeOwnership(Start());
        UpToDate(indexer, 1);
        Assert.Single(Search(indexer, "resume"));
        Assert.Single(Search(indexer, "CAFE"));
        Assert.Empty(Search(indexer, "resume", new FolderSearchOptions(IgnoreAccents: false)));
    }

    [Fact]
    public void A_text_layer_from_OCR_is_found()
    {
        // A page that is a picture with the recognizer's invisible text over it, as Recognize Text leaves it.
        var bytes = TextLayer.AddInvisibleText(TestPdf.Make(1, "visible"), null,
            new Dictionary<int, IReadOnlyList<OcrWord>> { [0] = [new OcrWord("invisibleword", RectD.FromEdges(72, 100, 192, 114))] });
        File.WriteAllBytes(Path.Combine(Folder, "scan.pdf"), bytes);
        using var indexer = TakeOwnership(Start());
        UpToDate(indexer, 1);
        Assert.Single(Search(indexer, "invisibleword"));
    }

    [Fact]
    public void A_changed_file_is_found_again_and_its_old_words_are_gone()
    {
        var path = Put("doc.pdf", "oldword");
        // No regular look in the time this test takes: the system's change notice is what finds it.
        using var indexer = TakeOwnership(Start(Quick() with { Rescan = TimeSpan.FromHours(1) }));
        UpToDate(indexer, 1);
        Assert.Single(Search(indexer, "oldword"));

        File.WriteAllBytes(path, TestPdf.Make(1, "newword"));
        WaitUntil(() => Search(indexer, "newword").Count == 1, "the new word");
        Assert.Empty(Search(indexer, "oldword"));
        Assert.Single(indexer.Index!.Files);
    }

    [Fact]
    public void A_new_file_and_a_removal_and_a_rename_are_all_noticed()
    {
        var keep = Put("keep.pdf", "keepword");
        var gone = Put("gone.pdf", "goneword");
        using var indexer = TakeOwnership(Start());
        UpToDate(indexer, 2);

        Put("new.pdf", "freshword");
        WaitUntil(() => Search(indexer, "freshword").Count == 1, "a new file");
        File.Delete(gone);
        WaitUntil(() => Search(indexer, "goneword").Count == 0, "a removal");
        File.Move(keep, Path.Combine(Folder, "renamed.pdf"));
        WaitUntil(() => Search(indexer, "keepword").FirstOrDefault()?.RelativePath == "renamed.pdf", "a rename");
        Assert.Equal(2, indexer.Index!.Files.Count);
    }

    [Fact]
    public void Without_change_notices_the_regular_look_finds_a_change()
    {
        var path = Put("doc.pdf", "firstword");
        using var indexer = TakeOwnership(Start(Quick() with { Rescan = TimeSpan.FromMilliseconds(300) }));
        UpToDate(indexer, 1);
        File.WriteAllBytes(path, TestPdf.Make(1, "secondword"));
        WaitUntil(() => Search(indexer, "secondword").Count == 1, "the change");
    }

    [Fact]
    public void A_file_still_being_written_waits_until_it_is_finished()
    {
        var path = Path.Combine(Folder, "copying.pdf");
        var bytes = TestPdf.Make(1, "lateword");
        using var indexer = TakeOwnership(Start(Quick() with { Rescan = TimeSpan.FromMilliseconds(200) }));
        using (var writing = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read))
        {
            writing.Write(bytes.AsSpan(0, bytes.Length / 2));
            writing.Flush();
            WaitUntil(() => indexer.Status is { Phase: IndexerPhase.UpToDate, Unavailable: 1 }, "it to say it couldn't open the file", about: indexer);
            Assert.Empty(indexer.Index!.Files); // not recorded as damaged
            writing.Write(bytes.AsSpan(bytes.Length / 2));
        }
        WaitUntil(() => Search(indexer, "lateword").Count == 1, "the finished file");
        Assert.Empty(indexer.Skipped());
    }

    [Fact]
    public void Damaged_password_protected_and_too_big_files_are_skipped_counted_and_said()
    {
        Put("good.pdf", "goodword");
        File.WriteAllBytes(Path.Combine(Folder, "damaged.pdf"), "%PDF-1.7\nnot really a PDF"u8.ToArray());
        File.WriteAllBytes(Path.Combine(Folder, "empty.pdf"), []);
        var whole = TestPdf.Make(4, "cutword");
        File.WriteAllBytes(Path.Combine(Folder, "cut.pdf"), whole[..(whole.Length / 2)]);
        File.WriteAllBytes(Path.Combine(Folder, "locked.pdf"), TestPdf.Encrypted(2, "secret"));
        File.WriteAllBytes(Path.Combine(Folder, "bigfile.pdf"), new byte[1024 * 1024 + 1]);
        using var indexer = TakeOwnership(Start(Quick() with { MaxFileBytes = 1024 * 1024 }));
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.UpToDate && indexer.Index!.Files.Count == 6, "everything looked at", about: indexer);

        Assert.Single(Search(indexer, "goodword"));
        var skipped = indexer.Skipped().ToDictionary(s => s.RelativePath, s => s.Why);
        Assert.Equal(IndexedState.Damaged, skipped["damaged.pdf"]);
        Assert.Equal(IndexedState.Damaged, skipped["empty.pdf"]);
        Assert.Equal(IndexedState.Password, skipped["locked.pdf"]);
        Assert.Equal(IndexedState.TooBig, skipped["bigfile.pdf"]);
        var status = indexer.Status;
        Assert.Equal(1, status.Skipped[IndexedState.Password]);
        Assert.Equal(1, status.Skipped[IndexedState.TooBig]);
        Assert.Contains("password protected", status.Text);
        Assert.Contains("too big", status.Text);
        Assert.Contains("skipped", status.Text);
    }

    [Fact]
    public void A_file_with_no_text_is_counted_and_nothing_runs_on_it()
    {
        TestPdf.UseFonts();
        using (var doc = new PdfDocument())
        {
            doc.AddPage();
            doc.Save(Path.Combine(Folder, "blank.pdf"));
        }
        using var indexer = TakeOwnership(Start());
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.UpToDate && indexer.Index!.Files.Count == 1, "the file");
        Assert.Equal(IndexedState.NoText, indexer.Index!.Files["blank.pdf"].State);
        Assert.Contains("no text yet", indexer.Status.Text);
    }

    [Fact]
    public void A_file_that_kills_the_reader_is_skipped_and_the_rest_are_indexed()
    {
        Put("a.pdf", "aword");
        var bad = Put("killer.pdf", "killword");
        Put("z.pdf", "zword");
        var options = Quick() with { WorkerArgs = ["index-worker-fault", "die", "killer.pdf"], MaxWorkers = 1 };
        using var indexer = TakeOwnership(Start(options));
        UpToDate(indexer, 2);
        Assert.Single(Search(indexer, "aword"));
        Assert.Single(Search(indexer, "zword"));
        Assert.Empty(Search(indexer, "killword"));
        Assert.Equal(IndexedState.Crashed, indexer.Index!.Files["killer.pdf"].State);
        Assert.Contains("crashed the reader", indexer.Status.Text);

        // Not read again until it changes: a hostile file costs two workers, once.
        var seen = indexer.Index!.Files["killer.pdf"].Id;
        indexer.Refresh();
        Thread.Sleep(500);
        Assert.Equal(seen, indexer.Index!.Files["killer.pdf"].Id);
    }

    [Fact]
    public void A_file_that_never_ends_is_given_up_and_the_rest_are_indexed()
    {
        Put("a.pdf", "aword");
        Put("sleeper.pdf", "sleepword");
        Put("z.pdf", "zword");
        var options = Quick() with { WorkerArgs = ["index-worker-fault", "hang", "sleeper.pdf"], MaxWorkers = 1, Stall = TimeSpan.FromSeconds(15) }; // long enough that a busy PC doesn't stall the healthy files too
        using var indexer = TakeOwnership(Start(options));
        UpToDate(indexer, 2);
        Assert.Equal(IndexedState.TooSlow, indexer.Index!.Files["sleeper.pdf"].State);
        Assert.Contains("too slow", indexer.Status.Text);
    }

    [Fact]
    public void A_file_that_keeps_the_processor_busy_is_given_up_by_the_time_it_took()
    {
        Put("a.pdf", "aword");
        Put("spinner.pdf", "spinword");
        var options = Quick() with { WorkerArgs = ["index-worker-fault", "spin", "spinner.pdf"], MaxWorkers = 1, FileDeadline = TimeSpan.FromSeconds(1) };
        using var indexer = TakeOwnership(Start(options));
        UpToDate(indexer, 1);
        Assert.Equal(IndexedState.TooSlow, indexer.Index!.Files["spinner.pdf"].State);
    }

    [Fact]
    public void A_file_that_takes_all_the_memory_stops_at_the_limit_and_the_rest_are_indexed()
    {
        Put("a.pdf", "aword");
        Put("glutton.pdf", "gluttonword");
        var options = Quick() with { WorkerArgs = ["index-worker-fault", "eat", "glutton.pdf"], MaxWorkers = 1, Stall = TimeSpan.FromSeconds(30) };
        using var indexer = TakeOwnership(Start(options));
        UpToDate(indexer, 1);
        Assert.Equal(IndexedState.Crashed, indexer.Index!.Files["glutton.pdf"].State); // not "too slow": the job's limit ended it, not the wait
    }

    [Fact]
    public void Workers_that_cant_start_are_a_problem_said_and_no_file_is_marked()
    {
        Put("a.pdf", "aword");
        var options = Quick() with { WorkerExe = Path.Combine(_dir, "no-such-program.exe"), Rescan = TimeSpan.FromSeconds(30) };
        using var indexer = TakeOwnership(Start(options));
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.Problem, "the problem");
        Assert.Contains("Couldn't start", indexer.Status.Text);
        Assert.Empty(indexer.Index!.Files);
    }

    [Fact]
    public void A_folder_that_goes_away_keeps_its_index_until_it_is_back()
    {
        Put("doc.pdf", "stayword");
        var moved = Folder + "-away";
        using var indexer = TakeOwnership(Start(Quick() with { Rescan = TimeSpan.FromMilliseconds(200) }));
        UpToDate(indexer, 1);
        indexer.Pause();
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.Paused, "the pause");
        indexer.Resume();
        Directory.Move(Folder, moved);
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.Problem, "it to notice");
        Assert.Contains("isn't there", indexer.Status.Text);
        Assert.Single(Search(indexer, "stayword"));
        Directory.Move(moved, Folder);
        UpToDate(indexer, 1);
        Assert.Single(Search(indexer, "stayword"));
    }

    [Fact]
    public void Pausing_stops_reading_and_resuming_finishes()
    {
        for (var i = 0; i < 40; i++) Put($"f{i:00}.pdf", $"w{i:00}x", 2);
        using var indexer = TakeOwnership(Start(Quick() with { PauseGrace = TimeSpan.FromMilliseconds(200) }));
        WaitUntil(() => indexer.Status.Done > 0 || indexer.Status.Phase == IndexerPhase.UpToDate, "the first files");
        indexer.Pause();
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.Paused, "the pause", 60);
        var atPause = indexer.Index!.Files.Count;
        Thread.Sleep(600);
        Assert.Equal(atPause, indexer.Index!.Files.Count);
        indexer.Resume();
        UpToDate(indexer, 40);
    }

    [Fact]
    public void Started_paused_it_reads_nothing_until_resumed()
    {
        Put("doc.pdf", "wordhere");
        using var indexer = TakeOwnership(Start(paused: true));
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.Paused, "the pause");
        Thread.Sleep(300);
        Assert.Empty(indexer.Index!.Files);
        indexer.Resume();
        UpToDate(indexer, 1);
    }

    [Fact]
    public void Stopping_ends_the_workers_and_what_was_read_is_there_next_time()
    {
        for (var i = 0; i < 60; i++) Put($"f{i:00}.pdf", $"w{i:00}x", 2);
        var indexer = Start();
        WaitUntil(() => indexer.Status.Done >= 5, "some files");
        var sw = Stopwatch.StartNew();
        indexer.Dispose();
        _indexers.Remove(indexer);
        Assert.True(sw.Elapsed.TotalSeconds < 30, $"{sw.Elapsed.TotalSeconds} s to stop");

        int count;
        using (var index = FolderIndex.Open(Base)) count = index.Files.Count; // the lock is free, and what was read is kept
        Assert.True(count >= 1);

        using var again = TakeOwnership(Start());
        UpToDate(again, 60);
    }

    [Fact]
    public void Nothing_is_read_twice()
    {
        Put("doc.pdf", "wordhere");
        long id;
        using (var first = TakeOwnership(Start()))
        {
            UpToDate(first, 1);
            id = first.Index!.Files["doc.pdf"].Id;
        }
        using var second = TakeOwnership(Start());
        UpToDate(second, 1);
        Assert.Equal(id, second.Index!.Files["doc.pdf"].Id);
    }

    [Fact]
    public void Rebuilding_reads_everything_again_and_gives_skipped_files_another_chance()
    {
        Put("good.pdf", "goodword");
        var options = Quick() with { WorkerArgs = ["index-worker-fault", "die", "bad.pdf"] };
        Put("bad.pdf", "badword");
        using (var first = TakeOwnership(Start(options)))
        {
            UpToDate(first, 1);
            Assert.Equal(IndexedState.Crashed, first.Index!.Files["bad.pdf"].State);
        }
        using var second = TakeOwnership(Start());
        UpToDate(second, 1);
        second.Rebuild();
        UpToDate(second, 2);
        Assert.Single(Search(second, "badword"));
    }

    [Fact]
    public void Removing_the_folder_deletes_its_index_file()
    {
        Put("doc.pdf", "wordhere");
        var indexer = Start();
        UpToDate(indexer, 1);
        indexer.StopAndDelete(TimeSpan.FromSeconds(10));
        Assert.Empty(Directory.GetFiles(Path.GetDirectoryName(Base)!));
        indexer.Dispose();
        _indexers.Remove(indexer);
    }

    [Fact]
    public void Two_indexers_on_one_folder_the_second_says_so()
    {
        Put("doc.pdf", "wordhere");
        using var first = TakeOwnership(Start());
        UpToDate(first, 1);
        using var second = TakeOwnership(Start());
        WaitUntil(() => second.Status.Phase == IndexerPhase.Problem, "the second to say so");
        Assert.Contains("Another Inkvolt PDF", second.Status.Text);
    }

    [Fact]
    public void A_cloud_placeholder_is_told_apart_from_a_file_on_this_pc()
    {
        Assert.True(FolderIndexer.IsCloudOnly(FileAttributes.Offline | FileAttributes.Normal));
        Assert.True(FolderIndexer.IsCloudOnly((FileAttributes)0x400000));
        Assert.True(FolderIndexer.IsCloudOnly((FileAttributes)0x40000));
        Assert.False(FolderIndexer.IsCloudOnly(FileAttributes.Archive));
    }

    /// <summary>A real Cloud Files sync root in the test's folder, as OneDrive has: no provider is connected, so nothing can come down.</summary>
    private sealed class SyncRoot : IDisposable
    {
        private readonly string _path;
        private SyncRoot(string path) => _path = path;

        [StructLayout(LayoutKind.Sequential)]
        private struct Registration
        {
            public uint Size;
            [MarshalAs(UnmanagedType.LPWStr)] public string Name, Version;
            public IntPtr RootIdentity;
            public uint RootIdentityLength;
            public IntPtr FileIdentity;
            public uint FileIdentityLength;
            public Guid Provider;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct Policies
        {
            public uint Size;
            public ushort HydrationPrimary, HydrationModifier, PopulationPrimary, PopulationModifier;
            public uint InSync, HardLink, Placeholders;
        }

        [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
        private static extern int CfRegisterSyncRoot(string path, ref Registration registration, ref Policies policies, uint flags);

        [DllImport("cldapi.dll", CharSet = CharSet.Unicode)]
        private static extern int CfUnregisterSyncRoot(string path);

        [DllImport("cldapi.dll")]
        private static extern int CfConvertToPlaceholder(SafeHandle file, byte[] identity, uint identityLength, uint flags, out long usn, IntPtr overlapped);

        /// <summary>Null where this Windows has no Cloud Files filter to do it with (a build server, say).</summary>
        public static SyncRoot? TryRegister(string path)
        {
            var registration = new Registration { Name = "InkvoltTest", Version = "1.0", Provider = Guid.NewGuid() };
            registration.Size = (uint)Marshal.SizeOf<Registration>();
            var policies = new Policies { HydrationPrimary = 2, PopulationPrimary = 3 }; // a file comes down whole if asked; folders are always there, with no provider running to list them
            policies.Size = (uint)Marshal.SizeOf<Policies>();
            try
            {
                return CfRegisterSyncRoot(path, ref registration, ref policies, 0) >= 0 ? new SyncRoot(path) : null;
            }
            catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
            {
                return null;
            }
        }

        /// <param name="online">Its bytes dropped, as a file that is only in the cloud.</param>
        public bool Convert(string file, bool online)
        {
            using var handle = File.OpenHandle(file, FileMode.Open, FileAccess.ReadWrite, FileShare.Read);
            const uint inSync = 1, dehydrate = 2;
            return CfConvertToPlaceholder(handle, [1], 1, inSync | (online ? dehydrate : 0), out _, IntPtr.Zero) >= 0;
        }

        public void Dispose() => CfUnregisterSyncRoot(_path);
    }

    [DllImport("ntdll.dll")]
    private static extern sbyte RtlSetProcessPlaceholderCompatibilityMode(sbyte mode);

    /// <summary>
    /// Disguised is what the app itself gets from Windows (measured: mode 1, with the app's manifest): a placeholder reads as a plain file,
    /// its recall attribute still on. Exposed is what PowerShell asks for: the reparse point shows too, as it may for a process Windows treats so.
    /// </summary>
    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void A_folder_kept_by_a_cloud_drive_is_indexed_and_what_is_only_in_the_cloud_stays_there(bool exposed)
    {
        Directory.CreateDirectory(Path.Combine(Folder, "sub"));
        var here = Put("here.pdf", "wordhere");
        var nested = Put(Path.Combine("sub", "nested.pdf"), "wordnested");
        var away = Put("away.pdf", "wordaway");
        using var root = SyncRoot.TryRegister(Folder);
        if (root is null || !root.Convert(here, false) || !root.Convert(nested, false) || !root.Convert(away, true)) return; // no Cloud Files on this Windows
        var mode = RtlSetProcessPlaceholderCompatibilityMode(exposed ? (sbyte)2 : (sbyte)1);
        using var restore = new Finally(() => RtlSetProcessPlaceholderCompatibilityMode(mode));
        Assert.Equal(exposed, File.GetAttributes(here).HasFlag(FileAttributes.ReparsePoint));
        Assert.True(FolderIndexer.IsCloudOnly(File.GetAttributes(away)), File.GetAttributes(away).ToString());
        var awayBefore = File.GetAttributes(away);

        using var indexer = TakeOwnership(Start());
        WaitUntil(() => indexer.Status.Phase == IndexerPhase.UpToDate, "the first look", about: indexer);
        Assert.True(indexer.Status.Searchable == 2, indexer.Status.Text);
        Assert.Single(Search(indexer, "wordhere"));
        Assert.Single(Search(indexer, "wordnested"));
        Assert.Empty(Search(indexer, "wordaway"));
        Assert.Equal(1, indexer.Status.CloudOnly);
        Assert.Equal(awayBefore, File.GetAttributes(away)); // still not on this PC
    }

    private sealed class Finally(Action then) : IDisposable
    {
        public void Dispose() => then();
    }

    [Fact]
    public void A_link_out_of_the_folder_isn_t_followed()
    {
        Put("inside.pdf", "wordinside");
        var outside = Path.Combine(_dir, "outside");
        Directory.CreateDirectory(outside);
        File.WriteAllBytes(Path.Combine(outside, "beyond.pdf"), TestPdf.Make(1, "wordbeyond"));
        using var mklink = Process.Start(new ProcessStartInfo("cmd", ["/c", "mklink", "/J", Path.Combine(Folder, "linked"), outside]) { RedirectStandardOutput = true, UseShellExecute = false })!;
        mklink.WaitForExit();
        Assert.Equal(0, mklink.ExitCode);
        using var indexer = TakeOwnership(Start());
        UpToDate(indexer, 1);
        Assert.Empty(Search(indexer, "wordbeyond"));
        Directory.Delete(Path.Combine(Folder, "linked")); // the junction, not what it leads to
    }

    /// <summary>
    /// The crash test proper: a process commits to an index and is killed at unplanned moments, again and again, on the same file.
    /// Each time the index opens, every file in it is found by its own word, and the next process goes on from there.
    /// </summary>
    [Fact]
    public void Killed_in_the_middle_of_committing_the_index_opens_whole()
    {
        var random = new Random(1234);
        var total = 0;
        for (var round = 0; round < 8; round++)
        {
            using var writer = Process.Start(new ProcessStartInfo(WorkerExe, ["index-writer", Base]) { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true })!;
            // After a first commit is reported, some moments more.
            Assert.NotNull(writer.StandardOutput.ReadLine());
            Thread.Sleep(random.Next(1, 120));
            writer.Kill();
            writer.WaitForExit();

            using var index = FolderIndex.Open(Base);
            Assert.True(index.Files.Count >= total, "A commit that was whole is gone.");
            Assert.Equal(0, index.Files.Count % 5); // batches are all or nothing
            total = index.Files.Count;
            foreach (var n in new[] { 0, total / 2, total - 1 })
            {
                using var run = index.Search($"unique{n}x");
                var hit = Assert.Single(run.Hits());
                Assert.Equal($"f{n:D7}.pdf", hit.RelativePath);
            }
        }
        Assert.True(total >= 5);
    }

    [Fact]
    public void The_worker_refuses_arguments_that_arent_a_pipe_of_ours()
    {
        Assert.Equal(FindWorkers.BadArguments, IndexWorkers.Run(["--index-worker"]));
        Assert.Equal(FindWorkers.BadArguments, IndexWorkers.Run(["--index-worker", "not-a-pipe"]));
        Assert.Equal(FindWorkers.BadArguments, IndexWorkers.Run(["--other", FindWorkers.NewPipeName()]));
    }

    [Fact]
    public void No_worker_runs_once_it_is_up_to_date()
    {
        Put("doc.pdf", "wordhere");
        using var indexer = TakeOwnership(Start());
        UpToDate(indexer, 1);
        Thread.Sleep(200);
        Assert.Equal(0, indexer.LiveWorkers);
    }
}
