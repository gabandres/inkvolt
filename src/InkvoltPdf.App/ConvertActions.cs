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
        return $"Supported documents|{all}|PDF files (*.pdf)|*.pdf" +
               (office.Length > 0 ? $"|Office files (converted with Microsoft Office)|{office}" : "") +
               $"|Web pages (*.html, *.mht)|{web}|All files (*.*)|*.*";
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
                Prompt.Info(host, $"Can't open {name}", problem);
                return false;
            }
            return await Run(host, $"Opening {name}", $"Converting with {appName}…", OfficeFiles.PdfName(path),
                token => OfficeConverter.ConvertAsync(path, app, token), $"Made from {name} with {appName}. Save it to keep it.");
        }
        if (WebCapture.RuntimeVersion is null)
        {
            Prompt.Info(host, $"Can't open {name}", WebCapture.Unavailable);
            return false;
        }
        var options = SavedWebOptions();
        return await Run(host, $"Opening {name}", "Opening the page…", Path.GetFileNameWithoutExtension(path) + ".pdf",
            token => WebCapture.PrintAsync(new Uri(Path.GetFullPath(path)), options, null, token),
            $"Made from {name} ({Describe(options)}). File › Create PDF › From Web Page… has the page options. Save it to keep it.");
    }

    /// <summary>File › Create PDF › From Office File…</summary>
    public static async Task FromOfficeFile(MainWindow host)
    {
        var apps = OfficeConverter.InstalledApps;
        if (apps.Count == 0)
        {
            Prompt.Info(host, "Microsoft Office isn't installed", "Making PDFs from Word, Excel and PowerPoint files uses Microsoft Office on this PC, and it wasn't found.");
            return;
        }
        var dlg = new OpenFileDialog
        {
            Title = "Create PDF from Office File",
            Filter = $"Office files|{OfficeFiles.FilterPattern(apps)}" + string.Concat(apps.Select(a => $"|{OfficeFiles.AppName(a)}|{OfficeFiles.FilterPattern([a])}")),
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
            Prompt.Info(host, "Web pages can't be converted", WebCapture.Unavailable);
            return;
        }
        var saved = SavedWebOptions();
        var dlg = new FormDialog(host, "Create PDF from Web Page", "Create PDF", 520);
        var address = new TextBox();
        System.Windows.Automation.AutomationProperties.SetName(address, "Web address or file");
        var browse = new Button { Content = "Browse…", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        var row = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        row.Children.Add(browse);
        row.Children.Add(address);
        dlg.Add("Web address, or a saved page (.html, .mht)", row);
        browse.Click += (_, _) =>
        {
            var pick = new OpenFileDialog { Title = "Saved web page", Filter = $"Web pages|{string.Join(";", WebFiles.Extensions.Select(e => "*" + e))}|All files (*.*)|*.*" };
            if (pick.ShowDialog(dlg) == true) address.Text = pick.FileName;
        };
        dlg.Loaded += (_, _) => address.Focus();
        var paper = dlg.AddChoice("Paper", ["Letter", "A4", "Legal"], (int)saved.Paper);
        var orientation = dlg.AddChoice("Orientation", ["Portrait", "Landscape"], saved.Landscape ? 1 : 0);
        var margins = dlg.AddChoice("Margins", ["None", "Narrow (0.25 in)", "Normal (0.4 in)", "Wide (1 in)"], (int)saved.Margins);
        var backgrounds = dlg.AddCheck("Background colors and pictures", saved.Backgrounds);
        backgrounds.Margin = new Thickness(0, 12, 0, 0);
        var headers = dlg.AddCheck("Header and footer (title, address, date, page numbers)", saved.HeaderAndFooter);
        dlg.AddNote("The page is loaded on this PC by Microsoft Edge WebView2: an address from the internet, as a browser would, in a private session that keeps no cookies or history. Scripts on the page run; pop-ups, downloads and permission requests are blocked.");
        Uri? source = null;
        dlg.Validate(() =>
        {
            var text = address.Text.Trim().Trim('"');
            if (text.Length > 0 && (File.Exists(text) || Path.IsPathFullyQualified(text)))
            {
                if (!File.Exists(text)) return "That file wasn't found.";
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
        await Run(host, "Create PDF from Web Page", source.IsFile ? "Opening the file…" : $"Loading {source.Host}…", name,
            token => WebCapture.PrintAsync(source, options, null, token), $"Made from {label}. Save it to keep it.");
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

    private static string Describe(WebPdfOptions o) => $"{o.Paper}{(o.Landscape ? " landscape" : "")}, {o.Margins.ToString().ToLowerInvariant()} margins";

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
        catch (OperationCanceledException)
        {
            progress.Dispose();
            host.ShowStatus("Cancelled. Nothing was opened.");
            return false;
        }
        catch (Exception ex) when (ex is InvalidOperationException or IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException or ArgumentException)
        {
            progress.Dispose();
            Log.Write($"Conversion failed: {ex.Message}");
            Prompt.Error(host, "Couldn't make the PDF", ex.Message);
            return false;
        }
    }
}
