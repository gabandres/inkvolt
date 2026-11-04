using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;
using Microsoft.Win32;

namespace InkvoltPdf.App;

/// <summary>
/// File › Create PDF from Office File… / from Web Page…, and File › Open for .docx, .xlsx, .pptx (and the other Office
/// formats) and .html/.mht: the file is converted (Office through <see cref="OfficeConverter"/>, web pages through
/// <see cref="WebCapture"/>) and opens as a new, unsaved PDF tab; the original isn't changed.
/// </summary>
internal static class Converting
{
    /// <summary>Files Open converts instead of reading itself.</summary>
    public static bool Handles(string path) => OfficeFiles.AppFor(path) is not null || WebFiles.IsWebFile(path);

    /// <summary>The Open dialog's filter: what MuPDF reads, plus Office files (of the apps installed) and web pages.</summary>
    public static string OpenFilter()
    {
        var office = OfficeFiles.FilterPattern(OfficeConverter.InstalledApps);
        var web = string.Join(";", WebFiles.Extensions.Select(e => "*" + e));
        var all = "*.pdf;*.xps;*.oxps;*.epub;*.cbz;*.fb2;*.png;*.jpg;*.jpeg;*.tif;*.tiff;*.bmp;*.gif" + (office.Length > 0 ? ";" + office : "") + ";" + web;
        return $"{Strings.Convert_FilterSupported}|{all}|{Strings.Compare_FilterPdf}|*.pdf" +
               (office.Length > 0 ? $"|{Strings.Compare_FilterOffice}|{office}" : "") +
               $"|{Strings.Convert_FilterWeb}|{web}|{Strings.Compare_FilterAll}|*.*";
    }

    /// <summary>Converts <paramref name="path"/> and opens the PDF in a new tab. False when it wasn't (cancelled or failed; said so).</summary>
    public static async Task<bool> OpenConverted(MainWindow host, string path)
    {
        var name = Path.GetFileName(path);
        if (OfficeFiles.AppFor(path) is { } app)
        {
            var appName = OfficeFiles.AppName(app);
            if (OfficeConverter.Precheck(path, app) is { } problem)
            {
                Prompt.Info(host, Loc.Format(Strings.Convert_CantOpen, name), problem);
                return false;
            }
            // Automation opens files without Office's Protected View: one marked as from the internet needs an OK first.
            var internet = OfficeConverter.ZoneOf(path) >= 3;
            if (internet && !Prompt.Confirm(host, Loc.Format(Strings.Compare_FromInternet, name),
                    Loc.Format(Strings.Compare_FromInternetBody, appName),
                    Strings.Compare_ConvertAnyway, warning: true))
                return false;
            string? note = null;
            var ok = await Run(host, Loc.Format(Strings.Convert_Opening, name), Loc.Format(Strings.Compare_ConvertingWith, appName), OfficeFiles.PdfName(path), async token =>
            {
                var r = await OfficeConverter.ConvertAsync(path, app, internet, token);
                note = r.Note;
                return r.Pdf;
            }, Loc.Format(Strings.Convert_MadeWith, name, appName));
            if (note is not null) host.ShowStatus(note);
            return ok;
        }
        if (WebCapture.RuntimeVersion is null)
        {
            Prompt.Info(host, Loc.Format(Strings.Convert_CantOpen, name), WebCapture.Unavailable);
            return false;
        }
        var options = SavedWebOptions();
        return await Run(host, Loc.Format(Strings.Convert_Opening, name), Strings.Convert_OpeningPage, Path.GetFileNameWithoutExtension(path) + ".pdf",
            token => WebCapture.PrintAsync(new Uri(Path.GetFullPath(path)), options, null, token),
            Loc.Format(Strings.Convert_MadeFromPage, name, Describe(options)));
    }

    /// <summary>File › Create PDF › From Office File…</summary>
    public static async Task FromOfficeFile(MainWindow host)
    {
        var apps = OfficeConverter.InstalledApps;
        if (apps.Count == 0)
        {
            Prompt.Info(host, Strings.Convert_NoOffice, Strings.Convert_NoOfficeBody);
            return;
        }
        var dlg = new OpenFileDialog
        {
            Title = Strings.Convert_FromOfficeTitle,
            Filter = $"{Strings.Convert_FilterOffice}|{OfficeFiles.FilterPattern(apps)}" + string.Concat(apps.Select(a => $"|{OfficeFiles.AppName(a)}|{OfficeFiles.FilterPattern([a])}")),
            Multiselect = true,
            InitialDirectory = AppSettings.Current.LastFolder,
        };
        if (dlg.ShowDialog(host) != true) return;
        foreach (var file in dlg.FileNames)
            if (!await OpenConverted(host, file)) break;
    }

    /// <summary>File › Create PDF › From Web Page…: an address or a saved page, with paper, margins and backgrounds.</summary>
    public static async Task FromWebPage(MainWindow host)
    {
        if (WebCapture.RuntimeVersion is null)
        {
            Prompt.Info(host, Strings.Convert_WebCantConvert, WebCapture.Unavailable);
            return;
        }
        var saved = SavedWebOptions();
        var dlg = new FormDialog(host, Strings.Convert_FromWebTitle, Strings.Convert_CreatePdf, 520);
        var address = new TextBox();
        System.Windows.Automation.AutomationProperties.SetName(address, Strings.Convert_WebAddressOrFile);
        var browse = new Button { Content = Strings.Common_Browse, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        var row = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        row.Children.Add(browse);
        row.Children.Add(address);
        dlg.Add(Strings.Convert_WebAddressLabel, row);
        browse.Click += (_, _) =>
        {
            var pick = new OpenFileDialog { Title = Strings.Convert_SavedWebPage, Filter = $"{Strings.Convert_FilterWebPages}|{string.Join(";", WebFiles.Extensions.Select(e => "*" + e))}|{Strings.Compare_FilterAll}|*.*" };
            if (pick.ShowDialog(dlg) == true) address.Text = pick.FileName;
        };
        dlg.Loaded += (_, _) => address.Focus();
        var paper = dlg.AddChoice(Strings.Convert_Paper, [Strings.Convert_PaperLetter, Strings.Convert_PaperA4, Strings.Convert_PaperLegal], (int)saved.Paper);
        var orientation = dlg.AddChoice(Strings.Convert_Orientation, [Strings.Convert_Portrait, Strings.Convert_Landscape], saved.Landscape ? 1 : 0);
        var margins = dlg.AddChoice(Strings.Convert_Margins, [Strings.Common_None, Strings.Convert_MarginsNarrow, Strings.Convert_MarginsNormal, Strings.Convert_MarginsWide], (int)saved.Margins);
        var backgrounds = dlg.AddCheck(Strings.Convert_Backgrounds, saved.Backgrounds);
        backgrounds.Margin = new Thickness(0, 12, 0, 0);
        var headers = dlg.AddCheck(Strings.Convert_HeaderFooter, saved.HeaderAndFooter);
        dlg.AddNote(Strings.Convert_WebNote);
        Uri? source = null;
        dlg.Validate(() =>
        {
            var text = address.Text.Trim().Trim('"');
            if (text.Length > 0 && (File.Exists(text) || Path.IsPathFullyQualified(text)))
            {
                if (!File.Exists(text)) return Strings.Convert_FileNotFound;
                source = new Uri(Path.GetFullPath(text));
                return null;
            }
            return WebFiles.TryParseAddress(text, out source, out var error) ? null : error;
        });
        if (!dlg.ShowModal() || source is null) return;
        var options = new WebPdfOptions
        {
            Paper = (WebPaper)Math.Max(0, paper.SelectedIndex),
            Landscape = orientation.SelectedIndex == 1,
            Margins = (WebMargins)Math.Max(0, margins.SelectedIndex),
            Backgrounds = backgrounds.IsChecked == true,
            HeaderAndFooter = headers.IsChecked == true,
        };
        var s = AppSettings.Current;
        (s.WebPaper, s.WebLandscape, s.WebMargins, s.WebBackgrounds, s.WebHeaderFooter) =
            (options.Paper.ToString(), options.Landscape, options.Margins.ToString(), options.Backgrounds, options.HeaderAndFooter);
        s.Save();
        var name = source.IsFile ? Path.GetFileNameWithoutExtension(source.LocalPath) + ".pdf" : WebFiles.PdfName(source);
        var label = source.IsFile ? Path.GetFileName(source.LocalPath) : source.Host;
        await Run(host, Strings.Convert_FromWebTitle, source.IsFile ? Strings.Web_OpeningFile : Loc.Format(Strings.Web_Loading, source.Host), name,
            token => WebCapture.PrintAsync(source, options, null, token), Loc.Format(Strings.Convert_MadeFrom, label));
    }

    /// <summary>The page options last used (paper by the region's measurement system at first).</summary>
    private static WebPdfOptions SavedWebOptions()
    {
        var s = AppSettings.Current;
        var paper = Enum.TryParse<WebPaper>(s.WebPaper, out var p) ? p : RegionInfo.CurrentRegion.IsMetric ? WebPaper.A4 : WebPaper.Letter;
        return new WebPdfOptions
        {
            Paper = paper,
            Landscape = s.WebLandscape,
            Margins = Enum.TryParse<WebMargins>(s.WebMargins, out var m) ? m : WebMargins.Normal,
            Backgrounds = s.WebBackgrounds,
            HeaderAndFooter = s.WebHeaderFooter,
        };
    }

    private static string Describe(WebPdfOptions o) => Loc.Format(o.Landscape ? Strings.Convert_DescribeLandscape : Strings.Convert_DescribePortrait,
        o.Paper switch { WebPaper.A4 => Strings.Convert_PaperA4, WebPaper.Legal => Strings.Convert_PaperLegal, _ => Strings.Convert_PaperLetter },
        o.Margins switch { WebMargins.None => Strings.Convert_MarginsPhraseNone, WebMargins.Narrow => Strings.Convert_MarginsPhraseNarrow, WebMargins.Wide => Strings.Convert_MarginsPhraseWide, _ => Strings.Convert_MarginsPhraseNormal });

    /// <summary>Runs a conversion behind a progress window with Cancel, then opens the PDF in a new tab.</summary>
    private static async Task<bool> Run(MainWindow host, string title, string text, string pdfName, Func<CancellationToken, Task<byte[]>> convert, string done)
    {
        using var progress = new ProgressPrompt(host, title, text);
        using var taskbar = new TaskbarProgress(host);
        try
        {
            var pdf = await convert(progress.Token);
            progress.Dispose();
            host.OpenSession(DocumentSession.FromBytes(pdf, pdfName));
            host.ShowStatus(done);
            Log.Write($"Converted to {Log.Name(pdfName)}");
            return true;
        }
        catch (OperationCanceledException ex)
        {
            progress.Dispose();
            host.ShowStatus(Strings.Convert_CancelledNothing + (ex.Data[OfficeConverter.LeftRunning] is true ? " " + ex.Message : ""));
            return false;
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            progress.Dispose();
            Log.Write($"Conversion failed: {ex.Message}");
            Prompt.Error(host, Strings.Convert_CouldntMake, ex.Message);
            return false;
        }
    }
}
