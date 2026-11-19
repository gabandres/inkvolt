using System.IO;
using System.Net.Http;
using System.Windows;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Windows.Ocr;

namespace InkvoltPdf.App;

/// <summary>
/// Text recognition with Windows' built-in OCR (Windows.Media.Ocr, on the device, nothing leaves the PC) and, for the
/// languages Windows has no recognizer for, Tesseract: an optional download into the app's data, only when the person
/// asks (<see cref="EnsureAsync"/>, <see cref="TesseractStore"/>). Pages are read through <see cref="ScanText"/>: rendered
/// at 300 dpi, straightened, turned upright, despeckled and whitened, then recognized. The default language is the first
/// of the user's Windows display languages that has an OCR pack, else English, else any installed OCR language;
/// Recognize Text lets the user pick another (<see cref="OcrLanguages"/>), and a second language on the same pages. What
/// Recognize Text last chose is what Batch, Scan and the exports read with (<see cref="Chosen"/>), never downloading.
/// </summary>
internal static class PageOcr
{
    private static readonly Lock Gate = new();
    private static readonly Dictionary<string, WindowsRecognizer?> ByLanguage = [];
    private static readonly Dictionary<string, WindowsSpelling?> Spellings = [];
    private static WindowsRecognizer? _engine;
    private static bool _tried;

    /// <summary>
    /// Tesseract's files on this PC: the data folder's <c>tesseract</c>; in the Store package, its own LocalCache folder
    /// (a real path: a program run from %LOCALAPPDATA% as the package sees it, redirected into the package, starts but
    /// can't load the DLLs beside it, so tesseract.exe hung there with no error).
    /// </summary>
    public static TesseractStore Tesseract { get; } = new(Path.Combine(TesseractRoot(), "tesseract"));

    private static string TesseractRoot()
    {
        if (AppEnvironment.IsPackaged)
        {
            try
            {
                return global::Windows.Storage.ApplicationData.Current.LocalCacheFolder.Path;
            }
            catch (Exception ex) when (ex is InvalidOperationException or System.Runtime.InteropServices.COMException)
            {
                Log.Write($"No package data folder for Tesseract: {ex.Message}");
            }
        }
        return AppPaths.DataDirectory;
    }

    /// <summary>The default recognizer, or null when no OCR language is installed on this PC.</summary>
    public static WindowsRecognizer? Engine
    {
        get
        {
            lock (Gate)
            {
                if (_tried) return _engine;
                _tried = true;
                try
                {
                    _engine = WindowsRecognizer.Create();
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"OCR isn't available: {ex.Message}");
                    _engine = null;
                }
                return _engine;
            }
        }
    }

    /// <summary>The installed OCR languages (tag, name).</summary>
    public static IReadOnlyList<(string Tag, string Name)> Languages => WindowsRecognizer.Languages();

    /// <summary>What Recognize Text offers: Windows' installed OCR languages, then Tesseract's that none of them reads.</summary>
    public static List<OcrLanguageChoice> Offer() => OcrLanguages.Offer(Languages, NameOf);

    private static readonly Dictionary<string, string> Names = [];

    /// <summary>A Tesseract language's name in Windows' display language, else its English name.</summary>
    public static string NameOf(TesseractLanguage language)
    {
        lock (Gate)
        {
            if (!Names.TryGetValue(language.Code, out var name)) Names[language.Code] = name = WindowsName(language);
            return name;
        }
    }

    private static string WindowsName(TesseractLanguage language)
    {
        try
        {
            var name = new global::Windows.Globalization.Language(language.Tag).DisplayName;
            if (!string.IsNullOrWhiteSpace(name) && !string.Equals(name, language.Tag, StringComparison.OrdinalIgnoreCase)) return name;
        }
        catch (Exception ex) when (ex is ArgumentException or System.Runtime.InteropServices.COMException)
        {
            // a tag Windows doesn't know
        }
        return language.EnglishName;
    }

    /// <summary>How <paramref name="first"/> (and <paramref name="second"/> on the same pages) are read, and what to download first.</summary>
    public static OcrPlan Plan(OcrLanguageChoice first, OcrLanguageChoice? second) =>
        OcrLanguages.Plan(first, second, Tesseract.HasEngine, Tesseract.HasLanguage);

    /// <summary>
    /// The plan Recognize Text last chose (<see cref="AppSettings.OcrLanguage"/>, <see cref="AppSettings.OcrSecondLanguage"/>);
    /// null when nothing is chosen (Windows' default then). A language no longer offered counts as not chosen.
    /// </summary>
    public static OcrPlan? ChosenPlan(IReadOnlyList<OcrLanguageChoice>? offer = null)
    {
        offer ??= Offer();
        var settings = AppSettings.Current;
        var first = OcrLanguages.Find(offer, settings.OcrLanguage) ?? (Engine is { } e ? OcrLanguages.Find(offer, e.Language) : null);
        return first is null ? null : Plan(first, OcrLanguages.Find(offer, settings.OcrSecondLanguage));
    }

    /// <summary>
    /// The recognizer for what Recognize Text last chose, when it can read without downloading anything (else Windows'
    /// default, <see cref="Engine"/>); null when there is none at all.
    /// </summary>
    public static ITextRecognizer? Chosen
    {
        get
        {
            try
            {
                if (ChosenPlan() is { NeedsDownload: false } plan && Build(plan) is { } chosen) return chosen;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                Log.Write($"OCR as chosen isn't available: {ex.Message}");
            }
            return Engine;
        }
    }

    /// <summary>
    /// The recognizer for a plan whose files are all on this PC (Tesseract's checked against their pins, once a run);
    /// null when something it needs isn't there or isn't the pinned file.
    /// </summary>
    public static ITextRecognizer? Build(OcrPlan plan)
    {
        if (plan.NeedsDownload) return null;
        ITextRecognizer? TesseractFor(IReadOnlyList<TesseractLanguage> languages, string name) =>
            Tesseract.Verify(languages) ? new TesseractRecognizer(Tesseract.Executable, Tesseract.LanguageFolder, languages, name) : null;
        var name = plan.Second is { } s ? $"{plan.First.Name} + {s.Name}" : plan.First.Name;
        switch (plan.Engine)
        {
            case OcrEngine.Tesseract:
                return TesseractFor(plan.Tesseract, name);
            case OcrEngine.Windows when plan.Second is null:
                return WindowsFor(plan.First.Tag);
            case OcrEngine.Windows:
                return WindowsFor(plan.First.Tag) is { } a && WindowsFor(plan.Second.Tag) is { } b
                    ? new MixedRecognizer(a, Spelling(a.Language), b, Spelling(b.Language))
                    : null;
            default:
                var (windows, other) = plan.First.Windows ? (plan.First, plan.Second!) : (plan.Second!, plan.First);
                if (WindowsFor(windows.Tag) is not { } w || TesseractFor(plan.Tesseract, other.Name) is not { } t) return null;
                return plan.First.Windows
                    ? new MixedRecognizer(w, Spelling(w.Language), t, Spelling(t.Language))
                    : new MixedRecognizer(t, Spelling(t.Language), w, Spelling(w.Language));
        }
    }

    /// <summary>Windows' recognizer for an installed language, or null when it isn't installed.</summary>
    private static WindowsRecognizer? WindowsFor(string language)
    {
        lock (Gate)
        {
            if (!ByLanguage.TryGetValue(language, out var r))
            {
                try
                {
                    r = WindowsRecognizer.Create(language);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"OCR for {language} isn't available: {ex.Message}");
                    r = null;
                }
                ByLanguage[language] = r;
            }
            return r;
        }
    }

    /// <summary>The recognizer for an installed language (the default one for null or a language no longer installed).</summary>
    public static WindowsRecognizer? For(string? language) =>
        string.IsNullOrEmpty(language) ? Engine : WindowsFor(language) ?? Engine;

    /// <summary>
    /// Downloads what <paramref name="plan"/> needs, after asking (true when there is nothing to download, or it was
    /// downloaded and checked). Nothing is sent but the requests for the files; Cancel stops it and keeps nothing half-done.
    /// </summary>
    public static async Task<bool> EnsureAsync(Window owner, OcrPlan plan)
    {
        if (!plan.NeedsDownload) return true;
        var names = plan.Second is { } s ? $"{plan.First.Name} + {s.Name}" : plan.First.Name;
        var size = FileActions.FormatSize(plan.DownloadBytes);
        var body = plan.NeedsEngine ? Loc.Format(Strings.Ocr_DownloadEngineBody, names, size) : Loc.Format(Strings.Ocr_DownloadLanguageBody, names, size);
        if (!Prompt.Confirm(owner, Strings.Ocr_DownloadTitle, body, Loc.Format(Strings.Ocr_DownloadButton, size))) return false;

        using var progress = new ProgressPrompt(owner, Strings.Ocr_DownloadingTitle, plan.NeedsEngine ? Strings.Ocr_DownloadingEngine : Strings.Ocr_DownloadingTitle);
        var total = Math.Max(1, plan.DownloadBytes);
        long done = 0;
        try
        {
            if (plan.NeedsEngine)
            {
                await Tesseract.InstallEngineAsync(Http, new DirectProgress<double>(f =>
                    progress.Report(Strings.Ocr_DownloadingEngine, f * TesseractCatalog.InstallerSize / total)), progress.Token);
                done += TesseractCatalog.InstallerSize;
                Log.Write($"Tesseract {TesseractCatalog.Version} downloaded and checked");
            }
            foreach (var language in plan.ToDownload)
            {
                var text = Loc.Format(Strings.Ocr_DownloadingLanguage, plan.First.Tesseract == language ? plan.First.Name : plan.Second?.Tesseract == language ? plan.Second.Name : NameOf(language));
                var before = done;
                await Tesseract.InstallLanguageAsync(Http, language, new DirectProgress<double>(f => progress.Report(text, (before + f * language.Size) / total)), progress.Token);
                done += language.Size;
                Log.Write($"Tesseract's {language.Code} downloaded and checked");
            }
            return true;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
        catch (Exception ex) when (ex is PinnedDownloadException or InvalidDataException or IOException or UnauthorizedAccessException)
        {
            Log.Write($"Tesseract's download failed: {ex.GetType().Name}: {ex.Message}");
            var message = ex switch
            {
                PinnedDownloadException { Problem: DownloadProblem.Network } => Strings.Ocr_DownloadNetwork,
                PinnedDownloadException { Problem: DownloadProblem.Disk } or IOException or UnauthorizedAccessException => Strings.Ocr_DownloadDisk,
                _ => Strings.Ocr_DownloadNotPinned,
            };
            Prompt.Error(owner, Strings.Ocr_DownloadFailedTitle, message);
            return false;
        }
    }

    /// <summary>For Tesseract's downloads only (github.com and raw.githubusercontent.com, https, pinned files).</summary>
    private static readonly HttpClient Http = new(new SocketsHttpHandler { UseCookies = false, ConnectTimeout = TimeSpan.FromSeconds(30) })
    {
        Timeout = TimeSpan.FromMinutes(15),
    };

    /// <summary>Windows' spell checker for a language (or another region of it), or null when Windows has none.</summary>
    public static WindowsSpelling? Spelling(string? language)
    {
        if (string.IsNullOrEmpty(language)) return null;
        lock (Gate)
        {
            if (!Spellings.TryGetValue(language, out var s))
            {
                try
                {
                    s = WindowsSpelling.Create(language);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    Log.Write($"No spell checker for {language}: {ex.Message}");
                    s = null;
                }
                Spellings[language] = s;
            }
            return s;
        }
    }

    /// <summary>The spell checkers for what a recognizer reads: each language's, as one when it reads two.</summary>
    public static ISpelling? SpellingFor(ITextRecognizer ocr) => ocr switch
    {
        MixedRecognizer mixed => EitherSpelling.Of(SpellingFor(mixed.First), SpellingFor(mixed.Second)),
        TesseractRecognizer { Languages.Count: > 1 } t => t.Languages.Select(l => (ISpelling?)Spelling(l.Tag)).Aggregate(EitherSpelling.Of),
        _ => Spelling(ocr.Language),
    };

    public static string Unavailable => Strings.Ocr_NoLanguage;

    /// <summary>A page recognizer reading as <paramref name="options"/> say, with the spell checker for its language when they mark suspect words.</summary>
    public static PageRecognizer Pages(ITextRecognizer ocr, RecognizeOptions options) =>
        new(ocr, options, options.CheckWords ? SpellingFor(ocr) : null);

    /// <summary>
    /// A page recognizer reading as Recognize Text was last set: cleaned or as scanned (<see cref="AppSettings.OcrClean"/>),
    /// suspect words marked or not (<see cref="AppSettings.OcrSuspects"/>), no cleaned page kept. Export and the scan dialog
    /// read through it, and Batch (<see cref="ForBatch"/>).
    /// </summary>
    public static PageRecognizer AsSet(ITextRecognizer ocr) =>
        Pages(ocr, new RecognizeOptions(Clean: AppSettings.Current.OcrClean, CheckWords: AppSettings.Current.OcrSuspects));

    /// <summary>
    /// Batch's text recognition (the Batch window, a watched folder, the command line): <paramref name="ocr"/> one call at a
    /// time (the files running together share it), reading as Recognize Text was last set (<see cref="AsSet"/>). Null without one.
    /// </summary>
    public static PageRecognizer? ForBatch(ITextRecognizer? ocr) =>
        ocr is null ? null : new PageRecognizer(new SerialRecognizer(ocr, new Lock()),
            new RecognizeOptions(Clean: AppSettings.Current.OcrClean, CheckWords: AppSettings.Current.OcrSuspects),
            AppSettings.Current.OcrSuspects ? SpellingFor(ocr) : null);

    /// <summary>
    /// The words on a page (page space: points, top-left of the displayed page), the page cleaned first, no suspect words
    /// marked, nothing written back (Compare).
    /// </summary>
    public static List<OcrWord> Recognize(ITextRecognizer engine, PdfEngine pdf, int page, CancellationToken cancel) =>
        [.. ScanText.Recognize(pdf, page, engine, new RecognizeOptions(CheckWords: false), null, cancel).Words];
}
