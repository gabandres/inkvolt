using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Recovery copies of unsaved documents: each run keeps them in a folder of its own, locked while it runs; a clean exit
/// removes the folder, and a run that ended without one leaves it for the next start to offer back.
/// </summary>
public sealed class RecoveryTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), $"inkvoltpdf-recovery-{Guid.NewGuid():N}");

    public void Dispose()
    {
        if (Directory.Exists(_root)) Directory.Delete(_root, recursive: true);
    }

    private static RecoveryInfo Info(string name, string? path = null) =>
        new(name, path, null, null, new DateTime(2026, 10, 25, 12, 0, 0, DateTimeKind.Utc), 3);

    [Fact]
    public void A_running_copy_s_documents_are_not_offered()
    {
        using var store = RecoveryStore.Start(_root);
        store.Write("a", [1, 2, 3], Info("report.pdf"));
        Assert.Empty(RecoveryStore.FindLeftOver(_root));
    }

    [Fact]
    public void A_clean_exit_leaves_nothing()
    {
        using (var store = RecoveryStore.Start(_root)) store.Write("a", [1, 2, 3], Info("report.pdf"));
        Assert.Empty(RecoveryStore.FindLeftOver(_root));
        Assert.Empty(Directory.GetDirectories(_root));
    }

    [Fact]
    public void A_run_that_ended_without_cleaning_up_leaves_its_documents_with_where_they_came_from()
    {
        var store = RecoveryStore.Start(_root);
        store.Write("a", [1, 2, 3], Info("report.pdf", @"C:\Docs\report.pdf"));
        store.Write("b", [4, 5], Info("Combined.pdf"));
        store.Write("a", [7, 8, 9, 10], Info("report.pdf", @"C:\Docs\report.pdf")); // a later copy replaces the first
        store.Abandon(); // as a crash or a killed process would

        var left = RecoveryStore.FindLeftOver(_root).OrderBy(d => d.Info.DisplayName).ToList();
        Assert.Equal(["Combined.pdf", "report.pdf"], left.Select(d => d.Info.DisplayName));
        Assert.Equal(@"C:\Docs\report.pdf", left[1].Info.OriginalPath);
        Assert.Equal(3, left[1].Info.Page);
        Assert.Equal([7, 8, 9, 10], File.ReadAllBytes(left[1].PdfPath));
    }

    [Fact]
    public void A_removed_document_is_not_left_over()
    {
        var store = RecoveryStore.Start(_root);
        store.Write("a", [1], Info("a.pdf"));
        store.Write("b", [2], Info("b.pdf"));
        store.Remove("a");
        store.Abandon();
        Assert.Equal(["b.pdf"], RecoveryStore.FindLeftOver(_root).Select(d => d.Info.DisplayName));
    }

    [Fact]
    public void Half_written_or_damaged_copies_are_skipped()
    {
        var store = RecoveryStore.Start(_root);
        store.Write("good", [1], Info("good.pdf"));
        store.Abandon();
        var folder = Directory.GetDirectories(_root).Single();
        File.WriteAllBytes(Path.Combine(folder, "nodesc.pdf"), [1]);                  // a copy without its description
        File.WriteAllText(Path.Combine(folder, "nocopy.json"), "{}");                 // a description without its copy
        File.WriteAllBytes(Path.Combine(folder, "bad.pdf"), [1]);
        File.WriteAllText(Path.Combine(folder, "bad.json"), "not json");
        Assert.Equal(["good.pdf"], RecoveryStore.FindLeftOver(_root).Select(d => d.Info.DisplayName));
    }

    [Fact]
    public void Discarding_a_left_over_run_deletes_its_folder()
    {
        var store = RecoveryStore.Start(_root);
        store.Write("a", [1], Info("a.pdf"));
        store.Abandon();
        RecoveryStore.Discard(RecoveryStore.FindLeftOver(_root));
        Assert.Empty(RecoveryStore.FindLeftOver(_root));
        Assert.Empty(Directory.GetDirectories(_root));
    }

    [Fact]
    public void A_recovered_document_has_unsaved_changes_and_saves_back_to_its_file()
    {
        var path = Path.Combine(_root, "report.pdf");
        Directory.CreateDirectory(_root);
        File.WriteAllBytes(path, TestPdf.Make(1, "old"));
        using var session = DocumentSession.Recover(TestPdf.Make(2, "edited"), path, "report.pdf");
        Assert.True(session.IsDirty);
        Assert.Equal(Path.GetFullPath(path), session.FilePath);
        Assert.Equal(2, session.Engine.PageCount);
        session.SaveAs(session.FilePath!);
        Assert.False(session.IsDirty);
        Assert.Equal(2, TestPdf.PageNumbers(File.ReadAllBytes(path)).Length);
    }

    [Fact]
    public void A_protected_document_stays_protected_and_needs_its_password()
    {
        var data = TestPdf.Encrypted(1, "pw");
        Assert.Throws<PasswordRequiredException>(() => DocumentSession.Recover(data, null, "secret.pdf"));
        using var session = DocumentSession.Recover(data, null, "secret.pdf", password: "pw");
        Assert.True(session.IsDirty);
        Assert.Null(session.FilePath);
        Assert.Same(data, session.Data); // the copy is the protected bytes, as Save writes them
    }

    [Fact]
    public void A_recovered_document_whose_file_changed_since_says_so()
    {
        var path = Path.Combine(_root, "report.pdf");
        Directory.CreateDirectory(_root);
        File.WriteAllBytes(path, TestPdf.Make(1, "old"));
        var then = new FileInfo(path);
        var stamp = (then.Length, then.LastWriteTimeUtc);
        using (var same = DocumentSession.Recover(TestPdf.Make(2), path, "report.pdf", stamp)) Assert.False(same.HasChangedOnDisk());
        File.WriteAllBytes(path, TestPdf.Make(3, "someone else"));
        File.SetLastWriteTimeUtc(path, stamp.LastWriteTimeUtc.AddMinutes(5));
        using var changed = DocumentSession.Recover(TestPdf.Make(2), path, "report.pdf", stamp);
        Assert.True(changed.HasChangedOnDisk());
    }
}
