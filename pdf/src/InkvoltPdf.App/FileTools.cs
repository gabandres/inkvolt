using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media.Imaging;
using Microsoft.Win32;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// File commands that make or reshape a whole document: New from Images / Clipboard (and image files dropped on the
/// window or the thumbnails), Reduce File Size, Flatten.
/// </summary>
public static class FileTools
{
    /// <summary>Image types <see cref="ImageImport"/> reads.</summary>
    private static readonly string[] ImageExtensions = [".jpg", ".jpeg", ".jfif", ".png", ".bmp", ".gif", ".tif", ".tiff"];

    public static string ImageFilter => Strings.File_ImageFilter;

    public static bool IsImage(string path) => ImageExtensions.Contains(Path.GetExtension(path).ToLowerInvariant());

    /// <summary>Image files in a file drop (none when anything else is dropped along with them).</summary>
    public static string[] DroppedImages(DragEventArgs e) =>
        e.Data.GetData(DataFormats.FileDrop) is string[] files && files.Length > 0 && files.All(f => IsImage(f) && File.Exists(f)) ? files : [];

    /// <summary>The page size chosen last (this session).</summary>
    private static int _imagePageSize;

    private static string[] PageSizeNames => [Strings.File_SizeFitImage, Strings.File_SizeLetter, Strings.File_SizeA4];

    // ───────────────────────────── New from images ─────────────────────────────

    public static async Task NewFromImages(MainWindow host)
    {
        string[] files;
        if (DevScript.TakeSavePath(out var scripted)) files = scripted is null ? [] : scripted.Split(';');
        else
        {
            var dlg = new OpenFileDialog { Title = Strings.File_FromImagesTitle, Filter = ImageFilter, Multiselect = true, InitialDirectory = AppSettings.Current.LastFolder };
            if (dlg.ShowDialog(host) != true) return;
            files = dlg.FileNames;
        }
        if (files.Length == 0) return;
        if (AskPageSize(host, files.Length) is not { } size) return;
        await CreateFromFiles(host, files, size);
    }

    /// <summary>Asks how big the pages should be. Null when cancelled.</summary>
    private static PageSizeOption? AskPageSize(Window owner, int count)
    {
        var dlg = new FormDialog(owner, Strings.File_FromImagesTitle, Strings.File_Create);
        dlg.AddNote(count == 1 ? Strings.File_OneImage : Loc.Format(Strings.File_ImagesBecome, count));
        var size = dlg.AddChoice(Strings.File_PageSize, PageSizeNames, _imagePageSize);
        if (!dlg.ShowModal()) return null;
        _imagePageSize = size.SelectedIndex;
        return (PageSizeOption)size.SelectedIndex;
    }

    private static async Task CreateFromFiles(MainWindow host, IReadOnlyList<string> files, PageSizeOption size)
    {
        host.ShowStatus(files.Count == 1 ? Loc.Format(Strings.File_ConvertingOne, Path.GetFileName(files[0])) : Loc.Format(Strings.File_ConvertingImages, files.Count));
        try
        {
            var bytes = await Task.Run(() => ImageImport.ImagesToPdf([.. files.Select(f => (File.ReadAllBytes(f), Path.GetFileName(f)))], size));
            host.OpenSession(DocumentSession.FromBytes(bytes, Strings.File_UntitledPdf));
            host.ShowStatus(files.Count == 1 ? Loc.Format(Strings.File_MadeFromOne, Path.GetFileName(files[0])) : Loc.Format(Strings.File_MadeFromImages, files.Count));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            Log.Write($"Images to PDF failed: {ex}");
            Prompt.Error(host, Strings.File_CouldntMakeImages, ex.Message);
        }
    }

    // ───────────────────────────── New from clipboard ─────────────────────────────

    public static async Task NewFromClipboard(MainWindow host)
    {
        try
        {
            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList().Cast<string>().Where(File.Exists).ToList();
                var images = files.Where(IsImage).ToList();
                if (images.Count > 0)
                {
                    await CreateFromFiles(host, images, (PageSizeOption)_imagePageSize);
                    return;
                }
                var pdfs = files.Where(f => f.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)).ToList();
                if (pdfs.Count > 0)
                {
                    host.OpenFiles(pdfs);
                    return;
                }
            }
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
            {
                var frozen = SignatureImages.FromClipboard((BitmapSource)image.GetAsFrozen()); // frozen here: the encoding runs on a worker thread
                var bytes = await Task.Run(() => ImageImport.ImagesToPdf([(EncodePng(frozen), "Clipboard.png")], PageSizeOption.FitImage));
                host.OpenSession(DocumentSession.FromBytes(bytes, Strings.File_UntitledPdf));
                host.ShowStatus(Strings.File_MadeFromClipboard);
                return;
            }
        }
        catch (Exception ex) when (ex is COMException or ExternalException or InvalidOperationException or IOException)
        {
            Log.Write($"New from clipboard failed: {ex}");
            Prompt.Error(host, Strings.File_CouldntReadClipboard, ex.Message);
            return;
        }
        Prompt.Info(host, Strings.File_NothingToMake, Strings.File_NothingToMakeBody);
    }

    /// <param name="frozen">A frozen bitmap (usable from any thread).</param>
    private static byte[] EncodePng(BitmapSource frozen)
    {
        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(frozen));
        using var ms = new MemoryStream();
        encoder.Save(ms);
        return ms.ToArray();
    }

    // ───────────────────────────── Dropped images ─────────────────────────────

    /// <summary>
    /// Image files dropped on the window (not on the thumbnails): asks whether to make a new PDF of them, add them as
    /// pages of the open document, or view each one. True when the drop was handled here (the caller opens nothing).
    /// </summary>
    public static bool HandleWindowDrop(MainWindow host, string[] files)
    {
        if (files.Length == 0 || !files.All(f => IsImage(f) && File.Exists(f))) return false;
        var tab = host.ActiveTab;
        var canInsert = tab is { IsDisposed: false, IsBusy: false } && tab.Session.IsPdf && tab.PageView.PageCount > 0;
        var dlg = new FormDialog(host, files.Length == 1 ? Loc.Format(Strings.File_OpenOne, Path.GetFileName(files[0])) : Loc.Format(Strings.File_OpenImages, files.Length), Strings.Common_OK, 480);
        List<string> choices = [files.Length == 1 ? Strings.File_MakeNewPdf : Strings.File_CombineImages];
        if (canInsert) choices.Add(Loc.Format(Strings.File_AddAtEnd, tab!.Session.DisplayName));
        choices.Add(files.Length == 1 ? Strings.File_JustView : Strings.File_ViewEach);
        var what = dlg.AddChoice(Strings.File_WhatToDo, choices);
        var size = dlg.AddChoice(Strings.File_PageSize, PageSizeNames, _imagePageSize);
        what.SelectionChanged += (_, _) => size.IsEnabled = what.SelectedIndex < choices.Count - 1;
        if (!dlg.ShowModal()) return true;
        _imagePageSize = size.SelectedIndex;
        var pageSize = (PageSizeOption)size.SelectedIndex;
        if (what.SelectedIndex == choices.Count - 1) return false; // view them, as any other file
        if (what.SelectedIndex == 1 && canInsert) _ = InsertImages(tab!, files, tab!.PageView.PageCount, pageSize);
        else _ = CreateFromFiles(host, files, pageSize);
        return true;
    }

    /// <summary>Converts images to pages and inserts them before page <paramref name="before"/> (one undoable edit).</summary>
    public static async Task InsertImages(DocumentTab tab, IReadOnlyList<string> files, int before, PageSizeOption? size = null)
    {
        var pageSize = size ?? (PageSizeOption)_imagePageSize;
        var label = files.Count == 1 ? Loc.Format(Strings.File_InsertOne, Path.GetFileName(files[0])) : Loc.Format(Strings.File_InsertImages, files.Count);
        await tab.RunEdit(label, (d, pw) =>
        {
            var pdf = ImageImport.ImagesToPdf([.. files.Select(f => (File.ReadAllBytes(f), Path.GetFileName(f)))], pageSize);
            return PageEditor.Insert(d, pw, new PdfSource(pdf, null, label), null, before);
        }, before);
    }

    // ───────────────────────────── Reduce file size ─────────────────────────────

    internal static (string Name, double? Dpi, int Quality)[] Qualities =>
    [
        (Strings.File_QualityHigh, 200, 85),
        (Strings.File_QualityMedium, 150, 75),
        (Strings.File_QualityLow, 96, 60),
        (Strings.File_QualityKeep, null, 75),
    ];

    public static async Task ReduceSize(Window owner, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var dlg = new FormDialog(owner, Strings.File_ReduceTitle, Strings.File_Reduce, 480);
        dlg.AddNote(Loc.Format(Strings.File_ReduceNote, FileActions.FormatSize(tab.Session.Data.Length)));
        var quality = dlg.AddChoice(Strings.File_ImageQuality, Qualities.Select(q => q.Name), 1);
        dlg.Add(Strings.File_Also, new System.Windows.Controls.StackPanel());
        var thumbs = dlg.AddCheck(Strings.File_RemoveThumbs, true);
        var pieces = dlg.AddCheck(Strings.File_RemovePieces, true);
        var dedupe = dlg.AddCheck(Strings.File_Dedupe, true);
        var metadata = dlg.AddCheck(Strings.File_RemoveMetadata);
        if (!dlg.ShowModal() || !await tab.SettleAsync()) return;

        var q = Qualities[quality.SelectedIndex];
        var options = new OptimizeOptions
        {
            MaxImageDpi = q.Dpi,
            JpegQuality = q.Quality,
            RemoveThumbnails = thumbs.IsChecked == true,
            RemovePieceInfo = pieces.IsChecked == true,
            DeduplicateStreams = dedupe.IsChecked == true,
            RemoveMetadata = metadata.IsChecked == true,
        };
        OptimizeResult? result = null;
        using var taskbar = new TaskbarProgress(Window.GetWindow(tab));
        var outcome = await tab.TryEdit(Strings.File_ReduceLabel, (d, pw) =>
        {
            var r = Optimizer.Optimize(d, pw, options);
            result = r;
            // Savings under 1% (or a bigger file) aren't worth a rewrite: keep the original.
            return r.IsWorthIt ? r.Data : d;
        }, quiet: true);
        if (result is not { } res) return;
        if (outcome == EditOutcome.NoChange)
        {
            tab.ShowNotice(res.Saved <= 0
                ? Loc.Format(Strings.File_AlreadyCompact, FileActions.FormatSize(res.SizeBefore))
                : Loc.Format(Strings.File_OnlySaved, FileActions.FormatSize(res.Saved)));
            return;
        }
        if (outcome == EditOutcome.Done)
            tab.ShowNotice(Loc.Format(Strings.File_Reduced, FileActions.FormatSize(res.SizeBefore), FileActions.FormatSize(res.SizeAfter), 100.0 * res.Saved / Math.Max(1, res.SizeBefore)), undo: true);
    }

    // ───────────────────────────── Flatten ─────────────────────────────

    public static async Task Flatten(Window owner, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var dlg = new FormDialog(owner, Strings.File_Flatten, Strings.File_Flatten, 460);
        dlg.AddNote(Strings.File_FlattenNote);
        var comments = dlg.AddCheck(Strings.File_FlattenComments, true);
        var fields = dlg.AddCheck(Strings.File_FlattenFields, true);
        var printable = dlg.AddCheck(Strings.File_FlattenPrintable);
        dlg.Validate(() => comments.IsChecked != true && fields.IsChecked != true ? Strings.File_FlattenChoose : null);
        if (!dlg.ShowModal()) return;
        var options = new FlattenOptions
        {
            Annotations = comments.IsChecked == true,
            FormFields = fields.IsChecked == true,
            PrintableOnly = printable.IsChecked == true,
        };
        var label = options.Annotations && options.FormFields ? Strings.File_FlattenBoth : options.Annotations ? Strings.File_FlattenOnlyComments : Strings.File_FlattenOnlyFields;
        await tab.RunEdit(label, (d, pw) => Flattener.Flatten(d, pw, options));
    }
}
