using System.Text.Json;
using InkvoltPrint.Core.History;

namespace InkvoltPrint.Tests;

/// <summary>
/// Recent scans (roadmap 4.15): the last saves newest first, a file saved again moved up rather than listed twice, entries whose
/// files are gone dropped when shown, and the list read back from the settings file as hostile input (<see cref="RecentScans"/>).
/// </summary>
public class RecentScansTests
{
    private static readonly DateTimeOffset Noon = new(2026, 11, 22, 12, 0, 0, TimeSpan.Zero);

    private static RecentScan Scan(string file, int minutes = 0, int pages = 1) =>
        new([file], Noon.AddMinutes(minutes), pages, "Demo laser", "Receipts");

    [Fact]
    public void Newest_first_and_at_most_twenty()
    {
        IReadOnlyList<RecentScan> list = [];
        for (var i = 0; i < 25; i++) list = RecentScans.Add(list, Scan($@"C:\Scans\scan {i}.pdf", i));
        Assert.Equal(RecentScans.Max, list.Count);
        Assert.Equal("scan 24.pdf", list[0].Name);
        Assert.Equal("scan 5.pdf", list[^1].Name);
    }

    [Fact]
    public void A_file_saved_again_moves_to_the_top_once()
    {
        var list = RecentScans.Add([], Scan(@"C:\Scans\a.pdf"));
        list = RecentScans.Add(list, Scan(@"C:\Scans\b.pdf", 1));
        list = RecentScans.Add(list, Scan(@"c:\scans\A.PDF", 2, pages: 3));
        Assert.Equal(["A.PDF", "b.pdf"], list.Select(r => r.Name));
        Assert.Equal(3, list[0].Pages);
        // A batch sharing one of its files with an older entry replaces it too.
        list = RecentScans.Add(list, new RecentScan([@"C:\Scans\b.pdf", @"C:\Scans\c.pdf"], Noon, 4));
        Assert.Equal(2, list.Count);
        Assert.Equal(2, list[0].Files.Count);
    }

    [Fact]
    public void Gone_files_drop_out_and_an_entry_with_none_left_goes()
    {
        var list = RecentScans.Add([], new RecentScan([@"C:\Scans\p (1).jpg", @"C:\Scans\p (2).jpg"], Noon, 2));
        list = RecentScans.Add(list, Scan(@"D:\Away\gone.pdf", 1));
        var there = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { @"C:\Scans\p (2).jpg" };
        var shown = RecentScans.Present(list, there.Contains);
        Assert.Single(shown);
        Assert.Equal([@"C:\Scans\p (2).jpg"], shown[0].Files);
        Assert.False(shown[0].IsPdf);
        // A check that throws (a share that refuses) counts as gone, never as an error.
        Assert.Empty(RecentScans.Present(list, _ => throw new UnauthorizedAccessException()));
    }

    [Fact]
    public void Dropping_the_files_found_missing_keeps_a_scan_saved_since()
    {
        var before = RecentScans.Add([], Scan(@"C:\Scans\gone.pdf"));
        var gone = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { @"C:\Scans\gone.pdf" };
        var now = RecentScans.Add(before, Scan(@"C:\Scans\new.pdf", 1)); // saved while the disk was being checked
        Assert.Equal(["new.pdf"], RecentScans.Present(now, f => !gone.Contains(f)).Select(r => r.Name));
    }

    [Fact]
    public void Remove_takes_out_one_entry()
    {
        var list = RecentScans.Add(RecentScans.Add([], Scan(@"C:\a.pdf")), Scan(@"C:\b.pdf"));
        Assert.Equal(["a.pdf"], RecentScans.Remove(list, list[0]).Select(r => r.Name));
    }

    [Theory]
    [InlineData(@"C:\Scans\a.pdf", true)]
    [InlineData(@"\\nas\scans\a.pdf", true)]
    [InlineData(@"Scans\a.pdf", false)] // relative
    [InlineData(@"\\.\PhysicalDrive0", false)] // a device
    [InlineData(@"\\?\C:\a.pdf", false)]
    [InlineData(@"C:\Scans\a.pdf:hidden", false)] // an alternate data stream
    [InlineData("https://example.com/a.pdf", false)]
    [InlineData(@"C:\Scans\", false)] // a folder
    [InlineData("", false)]
    public void Only_plain_full_paths_are_kept(string path, bool kept) => Assert.Equal(kept, RecentScans.Usable(path));

    [Fact]
    public void A_hand_edited_settings_file_is_bounded()
    {
        var json = JsonSerializer.Serialize(new object?[]
        {
            null,
            new { Files = (string[]?)null, SavedAt = Noon, Pages = 1 },
            new { Files = Enumerable.Range(0, 500).Select(i => $@"C:\Scans\x{i}.jpg").Append("relative.jpg").ToArray(), SavedAt = Noon, Pages = -5,
                Printer = "Demo\r\nlaser" + new string('x', 500), Preset = "  " },
        });
        var read = RecentScans.Clean(JsonSerializer.Deserialize<List<RecentScan?>>(json));
        var only = Assert.Single(read);
        Assert.Equal(RecentScans.MaxFiles, only.Files.Count);
        Assert.Equal(0, only.Pages);
        Assert.Equal(RecentScans.MaxText, only.Printer!.Length);
        Assert.DoesNotContain('\n', only.Printer);
        Assert.Null(only.Preset);
        Assert.Equal(RecentScans.Max, RecentScans.Clean(Enumerable.Range(0, 1000).Select(i => Scan($@"C:\s{i}.pdf"))).Count);
    }

    [Fact]
    public void An_unusable_scan_isnt_added()
    {
        var list = RecentScans.Add([], Scan(@"C:\a.pdf"));
        Assert.Single(RecentScans.Add(list, Scan("not a path")));
    }

    [Fact]
    public void Today_yesterday_or_earlier_by_the_local_calendar()
    {
        var now = new DateTimeOffset(DateTime.Today.AddHours(12)); // local noon
        Assert.Equal(RecentScanDay.Today, RecentScans.Day(now.AddHours(-11), now));
        Assert.Equal(RecentScanDay.Yesterday, RecentScans.Day(now.AddDays(-1), now));
        Assert.Equal(RecentScanDay.Earlier, RecentScans.Day(now.AddDays(-2), now));
    }

    [Fact]
    public void Pdfs_print_as_pdfs_and_pictures_as_photos()
    {
        Assert.True(new RecentScan([@"C:\a.pdf", @"C:\b.PDF"], Noon, 2).IsPdf);
        Assert.False(new RecentScan([@"C:\a.pdf", @"C:\b.jpg"], Noon, 2).IsPdf);
    }
}
