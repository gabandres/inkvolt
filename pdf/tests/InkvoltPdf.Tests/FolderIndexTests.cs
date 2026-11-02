using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>The index file by itself: what goes in comes out as Find would find it, and a crash at any point loses nothing committed.</summary>
public sealed class FolderIndexTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "inkvolt-index-" + Guid.NewGuid().ToString("N"));
    private string Base => Path.Combine(_dir, "test");

    public void Dispose()
    {
        try
        {
            Directory.Delete(_dir, true);
        }
        catch (IOException) { }
    }

    private static void Add(IndexBatch batch, string path, params string?[] pages)
    {
        batch.Add(path, 100, 5, pages.Any(p => !string.IsNullOrEmpty(p)) ? IndexedState.Indexed : IndexedState.NoText, pages.Length, 0, FolderIndex.PackPages(pages), pages);
    }

    private static void Commit(FolderIndex index, Action<IndexBatch> fill)
    {
        var batch = index.NewBatch();
        fill(batch);
        index.Commit(batch);
    }

    private static List<FolderHit> Search(FolderIndex index, string query, FolderSearchOptions? options = null)
    {
        using var run = index.Search(query, options);
        return [.. run.Hits()];
    }

    private static string[] Where(FolderIndex index, string query, FolderSearchOptions? options = null) =>
        [.. Search(index, query, options).Select(h => $"{h.RelativePath}#{h.Page + 1}")];

    [Fact]
    public void A_word_is_found_with_its_page_and_context()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            Add(b, @"a\one.pdf", "nothing here", "the Lantern shines over the bay", null);
            Add(b, @"b\two.pdf", "a lantern and another LANTERN on one page");
            Add(b, "three.pdf", "no such word");
        });

        var hits = Search(index, "lantern");
        Assert.Equal([@"a\one.pdf#2", @"b\two.pdf#1"], hits.Select(h => $"{h.RelativePath}#{h.Page + 1}"));
        Assert.Equal(1, hits[0].Hits);
        Assert.Equal(2, hits[1].Hits);
        Assert.Contains("the Lantern shines", hits[0].Excerpt);
        Assert.Equal("Lantern", hits[0].Excerpt.Substring(hits[0].MatchStart, hits[0].MatchLength));
    }

    [Fact]
    public void The_excerpt_marks_the_hit_where_text_was_cut_before_it()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", new string('x', 100) + " target " + new string('y', 100)));
        var hit = Assert.Single(Search(index, "target"));
        Assert.StartsWith("…", hit.Excerpt);
        Assert.EndsWith("…", hit.Excerpt);
        Assert.Equal("target", hit.Excerpt.Substring(hit.MatchStart, hit.MatchLength));
    }

    [Theory]
    [InlineData("resume", "Résumé attached")]
    [InlineData("RÉSUMÉ", "resume attached")]
    [InlineData("straße", "STRASSE 5")]
    [InlineData("strasse", "Hauptstraße 5")]
    [InlineData("Ærø", "aero")]
    [InlineData("final", "the ﬁnal page")]
    [InlineData("example", "an exam-\nple broken over two lines")]
    [InlineData("soft", "so\u00ADft hyphen")]
    public void Accents_case_and_hyphens_are_read_as_Find_reads_them(string query, string page)
    {
        Assert.NotEmpty(PageText.FindIn(page, query, false, false, ignoreAccents: true)); // Find finds it...
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", page));
        Assert.Single(Search(index, query)); // ...and so does the index
    }

    [Theory]
    [InlineData("ntern")]   // inside a word, as Find finds it
    [InlineData("lant")]
    [InlineData("LANTERN")]
    [InlineData("brass lantern")] // a phrase
    [InlineData("brass   lantern")]
    public void What_Find_finds_inside_words_and_across_spaces(string query)
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", "an old brass\nlantern hung here"));
        Assert.Single(Search(index, query));
    }

    [Fact]
    public void A_phrase_needs_its_words_side_by_side_and_options_are_Finds()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            Add(b, "apart.pdf", "brass and a lantern");
            Add(b, "whole.pdf", "Brass Lantern");
            Add(b, "accent.pdf", "brâss lantern");
        });
        Assert.Equal(["accent.pdf#1", "whole.pdf#1"], Where(index, "brass lantern"));
        Assert.Equal(["whole.pdf#1"], Where(index, "brass lantern", new FolderSearchOptions(IgnoreAccents: false)));
        Assert.Empty(Where(index, "brass lantern", new FolderSearchOptions(MatchCase: true, IgnoreAccents: false)));
        Assert.Equal(["whole.pdf#1"], Where(index, "Brass Lantern", new FolderSearchOptions(MatchCase: true)));
        Assert.Empty(Where(index, "bras", new FolderSearchOptions(WholeWord: true)));
    }

    [Theory]
    [InlineData("the lantern", "by the lantern", true)]
    [InlineData("the lantern", "other lanterns", false)]
    [InlineData("he lant", "by the lantern", true)]
    [InlineData("big red dog", "a big red dogs", true)]
    [InlineData("big red dog", "a big redder dog", false)]
    [InlineData("big red dog", "a big blue red dog", false)]
    [InlineData("foo-bar baz", "foo bar  baz", true)] // a phrase by terms: Find itself still says no to this one
    [InlineData("東京 都", "東京 都", true)]
    [InlineData("the the", "and the the end", true)]
    public void Side_by_side_reads_a_phrase_as_terms(string query, string page, bool expected) =>
        Assert.Equal(expected, FolderIndex.SideBySide(page, IndexTerms.Of(query)));

    [Theory]
    [InlineData("bye bye baby", "bye bye bye baby")]
    [InlineData("a a b", "x a a a b y")]
    [InlineData("big big big dog", "big big big big dog")]
    [InlineData("a b a c", "a b a b a c")]
    public void A_phrase_that_starts_again_inside_itself_is_found(string query, string page)
    {
        Assert.NotEmpty(PageText.FindIn(page, query, false, false, true));
        Assert.True(FolderIndex.SideBySide(page, IndexTerms.Of(query)));
    }

    [Theory]
    [InlineData("a a b", "a a c a b")]
    [InlineData("a b a c", "a b a a c")]
    public void A_phrase_starting_again_doesn_t_join_what_isn_t_side_by_side(string query, string page) =>
        Assert.False(FolderIndex.SideBySide(page, IndexTerms.Of(query)));

    private static byte[] Varint(long value)
    {
        var bytes = new List<byte>();
        var v = (ulong)value;
        while (v >= 0x80)
        {
            bytes.Add((byte)(v | 0x80));
            v >>= 7;
        }
        bytes.Add((byte)v);
        return [.. bytes];
    }

    [Theory]
    [InlineData((long)int.MaxValue, true)] // a file number past what there can be, once added to the last
    [InlineData(-50L, true)]               // a file number below zero
    [InlineData(int.MaxValue + 5L, false)] // a page past what there can be
    [InlineData(-5L, false)]               // a page below zero
    public void Postings_out_of_range_are_damage(long difference, bool file)
    {
        byte[] list = [.. Varint((5 << 1) | 1), 3, .. Varint(file ? (difference << 1) | 1 : difference << 1), 0];
        Assert.Throws<FolderIndexDamagedException>(() =>
        {
            var reader = new FolderIndex.PostingReader(list);
            while (reader.Next(out _, out _)) { }
        });
    }

    [Theory]
    [InlineData(-5L)]
    [InlineData(int.MinValue * 4L)]
    public void A_damaged_posting_in_a_file_rebuilds_rather_than_stopping_a_search(long difference)
    {
        string?[] pages = [.. Enumerable.Range(0, 40).Select(i => (string?)$"hello page{i}")];
        using (var index = FolderIndex.Open(Base)) Commit(index, b => Add(b, "a.pdf", pages));
        var path = Directory.GetFiles(_dir, "*.idx").Single();
        var bytes = File.ReadAllBytes(path);
        // "hello" on all 40 pages: file 0, page 0, then a step of one page each. The checksums cover neither postings nor text.
        byte[] postings = [1, 0, .. Enumerable.Repeat((byte)2, 39)];
        var at = bytes.AsSpan().IndexOf(postings);
        Assert.True(at > 0);
        Varint((difference << 1) | 1).CopyTo(bytes, at);
        File.WriteAllBytes(path, bytes);
        using var damaged = FolderIndex.Open(Base);
        Assert.Throws<FolderIndexDamagedException>(() => Search(damaged, "hello"));
        Assert.Throws<FolderIndexDamagedException>(() => damaged.Compact());
    }

    [Theory]
    [InlineData("the the")]
    [InlineData("big big dog")]
    [InlineData("exam-\nple page")]
    public void A_phrase_Find_finds_passes_side_by_side(string phrase)
    {
        var page = phrase.Replace("\\n", "\n");
        var query = page.Replace("-\n", "");
        Assert.NotEmpty(PageText.FindIn("before " + page + " after", query, false, false, true));
        Assert.True(FolderIndex.SideBySide("before " + page + " after", IndexTerms.Of(query)));
    }

    [Theory]
    [InlineData("東京", "東京都の地図", true)]
    [InlineData("京", "東京都の地図", true)]
    [InlineData("都の地", "東京都の地図", true)]
    [InlineData("大阪", "東京都の地図", false)]
    [InlineData("ค้นหา", "การค้นหาเอกสาร", true)]
    public void Text_without_spaces_is_found(string query, string page, bool found)
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", page));
        Assert.Equal(found, Search(index, query).Count == 1);
    }

    [Fact]
    public void A_query_of_only_punctuation_says_so()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", "a + b"));
        using var run = index.Search("+");
        Assert.False(run.HasWords);
        Assert.Empty(run.Hits());
    }

    [Fact]
    public void Results_come_in_order_of_path_and_page_across_rounds_of_pages()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            for (var f = 0; f < 200; f++) Add(b, $"f{199 - f:000}.pdf", "shared word", "nothing", "shared again");
        });
        var hits = Where(index, "shared", new FolderSearchOptions(MaxPages: 10_000));
        Assert.Equal(400, hits.Length);
        Assert.Equal(Enumerable.Range(0, 200).SelectMany(f => new[] { $"f{f:000}.pdf#1", $"f{f:000}.pdf#3" }), hits);
    }

    [Fact]
    public void A_phrase_is_found_when_many_pages_have_its_words_apart()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            for (var f = 0; f < 300; f++) Add(b, $"f{f:000}.pdf", f == 250 ? "the brass lantern" : "lantern and the brass");
        });
        Assert.Equal(["f250.pdf#1"], Where(index, "brass lantern"));
    }

    [Fact]
    public void Candidates_are_counted_and_the_listing_stops_at_the_limit()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            for (var f = 0; f < 10; f++) Add(b, $"f{f}.pdf", "common word", "common word", "other");
        });
        using var run = index.Search("common", new FolderSearchOptions(MaxPages: 3));
        Assert.Equal(20, run.CandidatePages);
        Assert.Equal(10, run.CandidateFiles);
        Assert.Equal(3, run.Hits().Count());
    }

    [Fact]
    public void A_changed_or_removed_file_drops_out()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            Add(b, "keep.pdf", "alpha");
            Add(b, "change.pdf", "alpha");
            Add(b, "remove.pdf", "alpha");
        });
        Assert.Equal(3, Search(index, "alpha").Count);
        Commit(index, b =>
        {
            b.Remove(index.Files["change.pdf"]);
            b.Remove(index.Files["remove.pdf"]);
            Add(b, "change.pdf", "beta");
        });
        Assert.Equal(["keep.pdf#1"], Where(index, "alpha"));
        Assert.Equal(["change.pdf#1"], Where(index, "beta"));
        Assert.True(index.HasDeadText);
        Assert.False(index.Files.ContainsKey("remove.pdf"));
    }

    [Fact]
    public void Paths_are_case_insensitive_as_Windows_reads_them()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, @"Dir\File.pdf", "alpha"));
        Assert.True(index.Files.ContainsKey(@"dir\file.PDF"));
    }

    [Fact]
    public void It_comes_back_the_same_after_closing()
    {
        using (var index = FolderIndex.Open(Base))
        {
            Commit(index, b => Add(b, "one.pdf", "alpha", "beta"));
            Commit(index, b => Add(b, "two.pdf", "gamma"));
            Commit(index, b => b.Remove(index.Files["one.pdf"]));
        }
        using var again = FolderIndex.Open(Base);
        Assert.Empty(Where(again, "alpha"));
        Assert.Equal(["two.pdf#1"], Where(again, "gamma"));
        Assert.Equal(new[] { "two.pdf" }, again.Files.Keys);
        Assert.Equal(1, again.Files["two.pdf"].Pages);
        Assert.Equal(100, again.Files["two.pdf"].Size);
        Assert.Equal(5, again.Files["two.pdf"].WriteTicks);
        Assert.True(again.HasDeadText);
    }

    [Fact]
    public void Skipped_files_are_remembered_with_why()
    {
        using (var index = FolderIndex.Open(Base))
            Commit(index, b => b.Add("locked.pdf", 7, 8, IndexedState.Password, 0, 0, FolderIndex.PackPages([]), []));
        using var again = FolderIndex.Open(Base);
        Assert.Equal(IndexedState.Password, again.Files["locked.pdf"].State);
    }

    [Fact]
    public void A_second_open_is_refused_while_the_first_holds_it()
    {
        using var index = FolderIndex.Open(Base);
        Assert.Throws<FolderIndexBusyException>(() => FolderIndex.Open(Base));
    }

    /// <summary>
    /// A file cut at any byte, as a crash can leave it, opens at its last whole commit: everything before is there, nothing
    /// after is. Commits are flushed before their footer is written, so a cut is all a crash can do to the order of what reaches the disk.
    /// </summary>
    [Fact]
    public void A_file_cut_anywhere_opens_at_its_last_whole_commit()
    {
        var lengths = new List<long>();
        var names = new[] { "alpha", "beta", "gamma" };
        string file;
        using (var index = FolderIndex.Open(Base))
        {
            lengths.Add(index.FileBytes);
            foreach (var name in names)
            {
                Commit(index, b => Add(b, name + ".pdf", $"the word {name} on a page", "and another page"));
                lengths.Add(index.FileBytes);
            }
            file = Directory.GetFiles(_dir, "test.*.idx").Single();
            File.Copy(file, Path.Combine(_dir, "whole.bin"));
        }
        var whole = File.ReadAllBytes(Path.Combine(_dir, "whole.bin"));

        var cut = Path.Combine(_dir, "cut");
        for (var length = 0; length <= whole.Length; length += length < lengths[1] ? 1 : 7)
        {
            foreach (var f in Directory.GetFiles(_dir, "cut.*")) File.Delete(f);
            File.WriteAllBytes(cut + ".1.idx", whole.AsSpan(0, length).ToArray());
            using var index = FolderIndex.Open(cut);
            var commits = lengths.Count(l => l <= length) - 1;
            for (var n = 0; n < names.Length; n++)
                Assert.Equal(n < commits ? 1 : 0, Search(index, names[n]).Count);
            Assert.Equal(Math.Max(0, commits), index.Files.Count);
            // And it goes on working: a new commit lands after the last whole one.
            Commit(index, b => Add(b, "later.pdf", "afterwards"));
            Assert.Single(Search(index, "afterwards"));
        }
    }

    /// <summary>A flipped byte in the part that says what the file holds stops the reading there; in terms it is found when searching.</summary>
    [Fact]
    public void A_damaged_footer_or_file_list_loses_that_commit_and_those_after()
    {
        long firstEnd;
        using (var index = FolderIndex.Open(Base))
        {
            Commit(index, b => Add(b, "one.pdf", "alpha"));
            firstEnd = index.FileBytes;
            Commit(index, b => Add(b, "two.pdf", "beta"));
        }
        var file = Directory.GetFiles(_dir, "test.*.idx").Single();
        var bytes = File.ReadAllBytes(file);
        bytes[^10] ^= 0x40; // in the last footer
        File.WriteAllBytes(file, bytes);
        using var again = FolderIndex.Open(Base);
        Assert.Equal(new[] { "one.pdf" }, again.Files.Keys);
        Assert.Equal(firstEnd, again.FileBytes);
    }

    [Fact]
    public void A_damaged_header_starts_over()
    {
        using (var index = FolderIndex.Open(Base)) Commit(index, b => Add(b, "one.pdf", "alpha"));
        var file = Directory.GetFiles(_dir, "test.*.idx").Single();
        var bytes = File.ReadAllBytes(file);
        bytes[3] ^= 1;
        File.WriteAllBytes(file, bytes);
        using var again = FolderIndex.Open(Base);
        Assert.Empty(again.Files);
        Commit(again, b => Add(b, "two.pdf", "beta"));
        Assert.Single(Search(again, "beta"));
    }

    [Fact]
    public void Damaged_terms_are_reported_not_believed()
    {
        using (var index = FolderIndex.Open(Base))
        {
            Commit(index, b => Add(b, "one.pdf", "alpha uniqueword"));
            index.ForgetCaches();
        }
        var file = Directory.GetFiles(_dir, "test.*.idx").Single();
        var bytes = File.ReadAllBytes(file);
        var at = bytes.AsSpan().IndexOf("uniqueword"u8);
        Assert.True(at > 0);
        bytes[at] ^= 1;
        File.WriteAllBytes(file, bytes);
        using var again = FolderIndex.Open(Base);
        Assert.Throws<FolderIndexDamagedException>(() => again.Search("alpha"));
    }

    [Fact]
    public void A_damaged_page_is_reported_from_the_threads_that_read_it()
    {
        long textAt;
        using (var index = FolderIndex.Open(Base))
        {
            Commit(index, b => Add(b, "one.pdf", "alpha " + string.Join(' ', Enumerable.Range(0, 500).Select(i => $"w{i}"))));
            textAt = index.Files["one.pdf"].TextOffset;
        }
        var file = Directory.GetFiles(_dir, "test.*.idx").Single();
        var bytes = File.ReadAllBytes(file);
        for (var i = 8; i < 40; i++) bytes[textAt + i] ^= 0x5A;
        File.WriteAllBytes(file, bytes);
        using var again = FolderIndex.Open(Base);
        using var run = again.Search("alpha");
        Assert.Throws<FolderIndexDamagedException>(() => run.Hits().ToList());
    }

    /// <summary>A page's text is whatever a PDF says it is: nothing in it may break the reading of words, the filing or the search.</summary>
    [Fact]
    public void Any_text_at_all_can_be_filed()
    {
        var random = new Random(7);
        var chars = new char[0x10000 + 4000];
        for (var c = 0; c < 0x10000; c++) chars[c] = (char)c;
        for (var c = 0x10000; c < chars.Length; c++) chars[c] = (char)random.Next(0x10000);
        var all = new string(chars);
        var shuffled = new string(chars.OrderBy(_ => random.Next()).ToArray());
        var supplementary = string.Concat(Enumerable.Range(0, 3000).Select(_ => char.ConvertFromUtf32(random.Next(0x10000, 0x10FFFF))));
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "any.pdf", all, shuffled, supplementary, new string('\uD83D', 100), new string('x', 200_000)));
        Commit(index, b => Add(b, "two.pdf", "ordinary words"));
        index.Compact();
        Assert.Single(Search(index, "ordinary"));
        foreach (var query in new[] { all[1000..1040], shuffled[..30], supplementary[..20], "\uD83D", "\uDC00x" })
        {
            using var run = index.Search(query);
            _ = run.Hits().ToList();
        }
    }

    [Fact]
    public void Compacting_keeps_what_is_live_and_lets_go_of_what_is_not()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            Add(b, "keep.pdf", "alpha keepword", "second page alpha");
            Add(b, "gone.pdf", "alpha secretword");
        });
        Commit(index, b => Add(b, "later.pdf", "alpha laterword"));
        Commit(index, b => b.Remove(index.Files["gone.pdf"]));
        var before = index.FileBytes;
        Assert.True(index.Segments == 2);

        // Until compacted, the word is still in the file, though no search shows it...
        Assert.Empty(Where(index, "secretword"));
        Assert.True(FileHas("secretword"));

        index.Compact();

        // ...afterwards it isn't.
        Assert.False(FileHas("secretword"));
        Assert.Equal(1, index.Segments);
        Assert.False(index.HasDeadText);
        Assert.True(index.FileBytes < before);
        Assert.Equal(["keep.pdf#1", "keep.pdf#2", "later.pdf#1"], Where(index, "alpha"));
        Assert.Equal(["later.pdf#1"], Where(index, "laterword"));
        Assert.Single(Directory.GetFiles(_dir, "test.*.idx"));

        // It goes on from there, and opens again.
        Commit(index, b => Add(b, "after.pdf", "alpha afterword"));
        index.Dispose();
        using var again = FolderIndex.Open(Base);
        Assert.Equal(["after.pdf#1", "keep.pdf#1", "keep.pdf#2", "later.pdf#1"], Where(again, "alpha"));
    }

    private bool FileHas(string word)
    {
        using var stream = new FileStream(Directory.GetFiles(_dir, "test.*.idx").OrderBy(p => p).Last(), FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var ms = new MemoryStream();
        stream.CopyTo(ms);
        return ms.GetBuffer().AsSpan(0, (int)ms.Length).IndexOf(System.Text.Encoding.UTF8.GetBytes(word)) >= 0;
    }

    [Fact]
    public void A_search_under_way_finishes_on_the_file_it_began_with()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b =>
        {
            for (var i = 0; i < 20; i++) Add(b, $"f{i:00}.pdf", "alpha");
        });
        Commit(index, b => Add(b, "z.pdf", "alpha"));
        using var run = index.Search("alpha");
        using var hits = run.Hits().GetEnumerator();
        Assert.True(hits.MoveNext());

        index.Compact();
        Commit(index, b => b.Remove(index.Files["z.pdf"]));
        index.Compact();

        var count = 1;
        while (hits.MoveNext()) count++;
        Assert.Equal(21, count);
    }

    [Fact]
    public void Compacting_stops_when_cancelled_and_nothing_changes()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", "alpha"));
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => index.Compact(cts.Token));
        Assert.Single(Search(index, "alpha"));
        Assert.Empty(Directory.GetFiles(_dir, "*.tmp"));
    }

    [Fact]
    public void A_crash_during_compaction_leaves_the_old_file_in_charge()
    {
        using (var index = FolderIndex.Open(Base)) Commit(index, b => Add(b, "a.pdf", "alpha"));
        File.WriteAllBytes(Base + ".2.idx.tmp", [1, 2, 3]); // what a compaction leaves when the power goes
        using var again = FolderIndex.Open(Base);
        Assert.Single(Search(again, "alpha"));
        Assert.Empty(Directory.GetFiles(_dir, "*.tmp"));
    }

    [Fact]
    public void An_unreadable_newer_file_gives_way_to_the_one_before()
    {
        using (var index = FolderIndex.Open(Base)) Commit(index, b => Add(b, "a.pdf", "alpha"));
        File.WriteAllBytes(Base + ".9.idx", [1, 2, 3]);
        using var again = FolderIndex.Open(Base);
        Assert.Single(Search(again, "alpha"));
    }

    [Fact]
    public void Clearing_empties_it_and_the_old_file_goes()
    {
        using var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", "alpha"));
        index.Clear();
        Assert.Empty(index.Files);
        Assert.Empty(Search(index, "alpha"));
        Assert.Single(Directory.GetFiles(_dir, "test.*.idx"));
        Commit(index, b => Add(b, "b.pdf", "beta"));
        Assert.Single(Search(index, "beta"));
    }

    [Fact]
    public void Deleting_removes_every_trace()
    {
        var index = FolderIndex.Open(Base);
        Commit(index, b => Add(b, "a.pdf", "alpha"));
        index.DisposeAndDelete();
        Assert.Empty(Directory.GetFiles(_dir, "test*"));
    }

    [Fact]
    public void Every_commit_is_searched_and_many_words_stay_in_order()
    {
        using var index = FolderIndex.Open(Base);
        for (var c = 0; c < 5; c++)
        {
            var round = c;
            Commit(index, b =>
            {
                for (var f = 0; f < 40; f++)
                    Add(b, $"c{round}f{f:00}.pdf", string.Join(' ', Enumerable.Range(0, 200).Select(i => $"w{i}x{(f + i) % 37}")), $"page two shared{round}");
            });
        }
        Assert.Equal(5, index.Segments);
        Assert.Equal(40, Search(index, "shared3").Count);
        Assert.Equal(200, Search(index, "shared").Count);
        index.Compact();
        Assert.Equal(1, index.Segments);
        Assert.Equal(40, Search(index, "shared3").Count);
        Assert.Equal(200, Search(index, "shared").Count);
        Assert.Equal(Search(index, "w5x7").Count, Search(index, "w5x7").Count);
        Assert.Contains(Search(index, "w5x7"), h => h.RelativePath == "c0f02.pdf"); // (2 + 5) % 37
    }

    [Fact]
    public void A_folder_name_gives_one_index_however_it_is_written()
    {
        var a = FolderIndex.BasePathFor(_dir, @"C:\Papers\");
        Assert.Equal(a, FolderIndex.BasePathFor(_dir, @"c:\papers"));
        Assert.NotEqual(a, FolderIndex.BasePathFor(_dir, @"C:\Other"));
        Assert.DoesNotContain("papers", Path.GetFileName(a), StringComparison.OrdinalIgnoreCase);
    }
}
