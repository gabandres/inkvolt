using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>Another app holds the clipboard open: try again in a moment.</summary>
public sealed class ClipboardBusyException(Exception inner) : Exception("The clipboard is busy", inner);

/// <summary>
/// Print the clipboard (roadmap 4.13), the Windows half: reads what's on it (on the UI thread, as the clipboard wants), and makes the
/// file the Print tab or Photos opens: the picture as a PNG, the text drawn on pages as Core lays it out
/// (<see cref="ClipboardPrint.Pages"/>) and written as a black-and-white PDF (<see cref="PdfWriter"/>). The files go in a folder of
/// their own under %TEMP%, cleared of anything a day old each time.
/// </summary>
public static class ClipboardPrinting
{
    private const int Dpi = 300;

    public static string Folder => Path.Combine(Path.GetTempPath(), "Inkvolt Print clipboard");

    /// <summary>What's on the clipboard, and its picture. On the UI thread; a clipboard another app holds open is tried three times.</summary>
    /// <exception cref="ClipboardBusyException">It stayed busy.</exception>
    public static (ClipboardContent Content, BitmapSource? Picture) Read()
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                var files = Clipboard.ContainsFileDropList() ? Clipboard.GetFileDropList().Cast<string>().Take(ClipboardPrint.MaxFiles + 1).ToList() : [];
                var text = files.Count == 0 && Clipboard.ContainsText() ? Clipboard.GetText() : null;
                var picture = files.Count == 0 && Clipboard.ContainsImage() ? Clipboard.GetImage() : null;
                return (new ClipboardContent(text, picture is null ? null : (picture.PixelWidth, picture.PixelHeight), files), picture);
            }
            catch (COMException ex) when (attempt < 2)
            {
                Log.Write($"Clipboard busy, trying again: {ex.Message}");
                Thread.Sleep(100);
            }
            catch (COMException ex)
            {
                throw new ClipboardBusyException(ex);
            }
        }
    }

    /// <summary>The picture as a PNG named <paramref name="name"/> (colors as shown: some apps put an alpha channel that's all zero).</summary>
    public static string SavePicture(BitmapSource picture, string name)
    {
        Sweep();
        var path = Unique(name, ".png");
        var opaque = new FormatConvertedBitmap(picture, PixelFormats.Bgr24, null, 0);
        var png = new PngBitmapEncoder();
        png.Frames.Add(BitmapFrame.Create(opaque));
        using (var file = File.Create(path)) png.Save(file);
        return path;
    }

    /// <summary>
    /// The text on Letter (or A4 where the region is metric) as a black-and-white PDF named <paramref name="name"/>. Returns its
    /// path (null when nothing printable was left), its pages, and whether some was left out past <see cref="ClipboardPrint.MaxPages"/>.
    /// </summary>
    public static Task<(string? Path, int Pages, bool Cut)> TextPdfAsync(string text, string name, bool metric, CancellationToken ct = default)
    {
        Sweep();
        var (w, h) = metric ? (8.27, 11.69) : (8.5, 11.0);
        var layout = ClipboardPrint.Layout(w, h);
        var pages = ClipboardPrint.Pages(text, layout.Columns, layout.Lines, out var cut);
        if (pages.Count == 0) return Task.FromResult<(string?, int, bool)>((null, 0, cut));
        var path = Unique(name, ".pdf");
        var done = new TaskCompletionSource<(string?, int, bool)>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                var drawn = pages.Select(p =>
                {
                    ct.ThrowIfCancellationRequested();
                    return PdfPage.BlackAndWhite(Draw(p, layout), Dpi);
                }).ToList();
                var tmp = path + ".partial";
                using (var file = File.Create(tmp)) PdfWriter.Write(file, drawn, name);
                File.Move(tmp, path, overwrite: true);
                done.SetResult((path, pages.Count, cut));
            }
            catch (Exception ex)
            {
                done.SetException(ex);
            }
        })
        { IsBackground = true, Name = "Inkvolt Print clipboard" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }

    /// <summary>One page: white, the lines in a monospaced face at the layout's places, at 300 dpi, then 1 bit.</summary>
    private static BitImage Draw(IReadOnlyList<string> lines, ClipboardTextLayout layout)
    {
        var (width, height) = ((int)Math.Round(layout.PaperWidthInches * Dpi), (int)Math.Round(layout.PaperHeightInches * Dpi));
        var visual = new DrawingVisual();
        var face = new Typeface(new FontFamily("Consolas, Global Monospace"), FontStyles.Normal, FontWeights.Normal, FontStretches.Normal);
        var size = layout.FontPoints * 96 / 72;
        using (var dc = visual.RenderOpen())
        {
            dc.DrawRectangle(Brushes.White, null, new Rect(0, 0, layout.PaperWidthInches * 96, layout.PaperHeightInches * 96));
            for (var i = 0; i < lines.Count; i++)
            {
                if (lines[i].Length == 0) continue;
                var text = new FormattedText(lines[i], CultureInfo.CurrentCulture, FlowDirection.LeftToRight, face, size, Brushes.Black, 1.0);
                dc.DrawText(text, new Point(layout.MarginInches * 96, (layout.MarginInches + i * layout.LineInches) * 96));
            }
        }
        var bitmap = new RenderTargetBitmap(width, height, Dpi, Dpi, PixelFormats.Pbgra32);
        bitmap.Render(visual);
        var bgra = new byte[width * height * 4];
        bitmap.CopyPixels(bgra, width * 4, 0);
        var gray = new byte[width * height];
        for (var i = 0; i < gray.Length; i++) gray[i] = bgra[i * 4 + 1];
        return BitImage.FromGray(gray, width, height, 150);
    }

    /// <summary>A file name in <see cref="Folder"/> not taken yet.</summary>
    private static string Unique(string name, string extension)
    {
        Directory.CreateDirectory(Folder);
        var path = Path.Combine(Folder, name + extension);
        for (var n = 2; File.Exists(path); n++) path = Path.Combine(Folder, $"{name} ({n}){extension}");
        return path;
    }

    /// <summary>Files left from earlier clipboard prints, a day old or more, are deleted.</summary>
    private static void Sweep()
    {
        try
        {
            if (!Directory.Exists(Folder)) return;
            foreach (var file in Directory.EnumerateFiles(Folder).Take(1000))
                if (File.GetLastWriteTimeUtc(file) < DateTime.UtcNow.AddDays(-1)) File.Delete(file);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Clipboard files not cleared: {ex.Message}");
        }
    }
}
