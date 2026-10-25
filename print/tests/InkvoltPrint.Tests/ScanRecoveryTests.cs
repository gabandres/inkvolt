using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Tests;

/// <summary>
/// Unsaved scans kept on disk while Inkvolt Print runs: each printer's pages (the scanner's JPEGs as they came, and the
/// review's turns, crops, skips and file starts), in a folder of the run's own; left over only when the run didn't exit cleanly.
/// </summary>
public sealed class ScanRecoveryTests : IDisposable
{
    private const string Laser = "12345678-1234-4abc-8def-123456789abc", Inkjet = "2f1e6c3a-5b7d-4e8f-9a0b-1c2d3e4f5a6b";
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"inkvoltprint-scans-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private static KeptScan Scan(string printer, params KeptPage[] pages) =>
        new(printer, printer == Laser ? "Office laser" : "Inkjet", new DateTime(2026, 10, 25, 19, 30, 0, DateTimeKind.Utc), pages);

    [Fact]
    public void A_running_copy_s_scans_are_not_left_over()
    {
        using var store = ScanRecoveryStore.Start(_root);
        store.Keep(Scan(Laser, new KeptPage(store.KeepPage([1, 2]), 300, true)));
        Assert.Empty(ScanRecoveryStore.FindLeftOver(_root));
    }

    [Fact]
    public void A_clean_exit_leaves_nothing()
    {
        using (var store = ScanRecoveryStore.Start(_root)) store.Keep(Scan(Laser, new KeptPage(store.KeepPage([1, 2]), 300, true)));
        Assert.Empty(ScanRecoveryStore.FindLeftOver(_root));
        Assert.Empty(Directory.GetDirectories(_root));
    }

    [Fact]
    public void A_run_that_ended_without_a_clean_exit_leaves_each_printer_s_pages_in_order_with_their_edits()
    {
        var store = ScanRecoveryStore.Start(_root);
        var a = store.KeepPage([1, 1]);
        var b = store.KeepPage([2, 2]);
        var crop = new CropBox(0.1, 0.2, 0.5, 0.6);
        store.Keep(Scan(Laser, new KeptPage(b, 300, true, 1, 1.5, crop, Skipped: true), new KeptPage(a, 200, false, StartsFile: true)));
        store.Keep(Scan(Inkjet, new KeptPage(store.KeepPage([3]), 600, false)));
        store.KeepForNextStart();

        var left = ScanRecoveryStore.FindLeftOver(_root).OrderBy(s => s.Scan.PrinterName).ToList();
        Assert.Equal(["Inkjet", "Office laser"], left.Select(s => s.Scan.PrinterName));
        var laser = left[1];
        Assert.Equal(Laser, laser.Scan.PrinterId);
        Assert.Equal([[2, 2], [1, 1]], laser.Scan.Pages.Select(p => File.ReadAllBytes(laser.PagePath(p))));
        Assert.Equal(new PageEdits(1, 1.5, crop), laser.Scan.Pages[0].Edits);
        Assert.True(laser.Scan.Pages[0].Skipped);
        Assert.Equal((200, false, true), (laser.Scan.Pages[1].Dpi, laser.Scan.Pages[1].Ocr, laser.Scan.Pages[1].StartsFile));
    }

    [Fact]
    public void Pages_no_longer_in_a_scan_are_deleted_and_a_saved_scan_is_forgotten()
    {
        var store = ScanRecoveryStore.Start(_root);
        var a = store.KeepPage([1]);
        var b = store.KeepPage([2]);
        store.Keep(Scan(Laser, new KeptPage(a, 300, true), new KeptPage(b, 300, true)));
        store.Keep(Scan(Laser, new KeptPage(b, 300, true))); // page a deleted in the review
        store.Keep(Scan(Inkjet, new KeptPage(store.KeepPage([3]), 300, true)));
        store.Forget(Inkjet); // saved
        store.KeepForNextStart();

        var left = Assert.Single(ScanRecoveryStore.FindLeftOver(_root));
        Assert.Equal(b, Assert.Single(left.Scan.Pages).File);
        Assert.Equal([b], Directory.GetFiles(left.Folder, "*.jpg").Select(Path.GetFileName));
    }

    [Fact]
    public void A_scan_whose_pages_are_missing_or_whose_list_is_damaged_is_skipped()
    {
        var store = ScanRecoveryStore.Start(_root);
        store.Keep(Scan(Laser, new KeptPage(store.KeepPage([1]), 300, true)));
        store.Keep(Scan(Inkjet, new KeptPage(store.KeepPage([2]), 300, true)));
        store.KeepForNextStart();
        var inkjet = ScanRecoveryStore.FindLeftOver(_root).Single(s => s.Scan.PrinterId == Inkjet);
        File.Delete(inkjet.PagePath(inkjet.Scan.Pages[0]));
        File.WriteAllText(Path.Combine(inkjet.Folder, "scan-damaged.json"), "not json");
        Assert.Equal([Laser], ScanRecoveryStore.FindLeftOver(_root).Select(s => s.Scan.PrinterId));
    }

    [Fact]
    public void Restored_or_discarded_scans_are_deleted_with_their_folder()
    {
        var store = ScanRecoveryStore.Start(_root);
        store.Keep(Scan(Laser, new KeptPage(store.KeepPage([1]), 300, true)));
        store.Keep(Scan(Inkjet, new KeptPage(store.KeepPage([2]), 300, true)));
        store.KeepForNextStart();
        var left = ScanRecoveryStore.FindLeftOver(_root);
        ScanRecoveryStore.Remove(left[0]);
        Assert.Single(ScanRecoveryStore.FindLeftOver(_root));
        ScanRecoveryStore.Remove(left[1]);
        Assert.Empty(Directory.GetDirectories(_root));
    }

    [Fact]
    public void A_run_folder_is_left_over_only_once_its_run_has_ended()
    {
        using var running = RunFolder.Start(_root);
        var crashed = RunFolder.Start(_root);
        crashed.Abandon();
        Assert.Equal([crashed.Path], RunFolder.LeftOver(_root));
        RunFolder.Delete(running.Path); // never a running one's
        Assert.True(Directory.Exists(running.Path));
        RunFolder.Delete(crashed.Path);
        Assert.Empty(RunFolder.LeftOver(_root));
    }
}
