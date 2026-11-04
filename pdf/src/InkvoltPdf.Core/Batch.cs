using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>A file of a batch.</summary>
/// <param name="Path">Its full path.</param>
/// <param name="RelativeFolder">The folder below an added folder it was found in ("" at the top or when added on its own):
/// with <see cref="BatchPlan.KeepSubfolders"/> its results go to the same folder below the output folder.</param>
/// <param name="Origin">Where the file came from when it is worked on elsewhere (a watched folder's file, moved aside while
/// it runs): names (&lt;&lt;folder&gt;&gt;) come from there. Null: <paramref name="Path"/>.</param>
public sealed record BatchFile(string Path, string RelativeFolder = "", string? Origin = null)
{
    public bool IsImage => BatchFiles.IsImage(Path);

    /// <summary>The path result names are made from.</summary>
    public string NamedAs => Origin ?? Path;
}

/// <summary>The files a batch can take: PDFs, and images (made into a PDF first).</summary>
public static class BatchFiles
{
    public static readonly IReadOnlyList<string> ImageExtensions = [".jpg", ".jpeg", ".png", ".tif", ".tiff", ".bmp", ".gif"];

    public static bool IsImage(string path) => ImageExtensions.Contains(System.IO.Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    public static bool IsSupported(string path) =>
        System.IO.Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase) || IsImage(path);

    /// <summary>
    /// The PDFs and images among <paramref name="paths"/> (files as given; folders as the files in them, in name order,
    /// with <paramref name="recursive"/> their subfolders too), each once. Hidden and system files, and anything inside
    /// <paramref name="excludeFolder"/> (the output folder, so results aren't read back in), are left out of folders.
    /// </summary>
    public static List<BatchFile> Expand(IEnumerable<string> paths, bool recursive, string? excludeFolder = null)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<BatchFile>();
        var exclude = excludeFolder is { Length: > 0 } ? Folder(excludeFolder) : null;
        foreach (var raw in paths)
        {
            var path = System.IO.Path.GetFullPath(raw);
            if (File.Exists(path))
            {
                if (IsSupported(path) && seen.Add(path)) result.Add(new BatchFile(path));
                continue;
            }
            if (!Directory.Exists(path)) continue;
            var options = new EnumerationOptions
            {
                RecurseSubdirectories = recursive,
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint,
            };
            var found = Directory.EnumerateFiles(path, "*", options)
                .Where(IsSupported)
                .Where(f => exclude is null || !f.StartsWith(exclude, StringComparison.OrdinalIgnoreCase))
                .Select(f => (Path: f, Relative: System.IO.Path.GetRelativePath(path, System.IO.Path.GetDirectoryName(f)!)))
                .OrderBy(f => f.Relative == "." ? "" : f.Relative, StringComparer.CurrentCultureIgnoreCase)
                .ThenBy(f => System.IO.Path.GetFileName(f.Path), StringComparer.CurrentCultureIgnoreCase);
            foreach (var (file, relative) in found)
                if (seen.Add(file)) result.Add(new BatchFile(file, relative == "." ? "" : relative));
        }
        return result;
    }

    private static string Folder(string path) => System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(path)) + System.IO.Path.DirectorySeparatorChar;
}

/// <summary>Output names: a template with tokens, made into a valid Windows file name (without extension).</summary>
public static partial class BatchNames
{
    public const string DefaultTemplate = "<<name>>";

    /// <summary>Longest name made (folders and extension come on top), well inside Windows' path limits.</summary>
    public const int MaxLength = 120;

    /// <summary>&lt;&lt;name&gt;&gt; the file's name, &lt;&lt;n&gt;&gt; its place in the list (&lt;&lt;n:3&gt;&gt; padded to 3 digits),
    /// &lt;&lt;date&gt;&gt; (yyyy-MM-dd, or a .NET format after a colon), &lt;&lt;folder&gt;&gt; the folder it is in.</summary>
    public static readonly IReadOnlyList<string> Tokens = ["<<name>>", "<<n>>", "<<date>>", "<<folder>>"];

    private static readonly HashSet<string> DeviceNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

    [GeneratedRegex(@"<<\s*(name|n|date|folder)\s*(?::([^<>]*))?>>", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex TokenPattern();

    /// <summary>An error for a template that can't make names, else null.</summary>
    public static string? Validate(string template) =>
        string.IsNullOrWhiteSpace(template) ? PdfStrings.Batch_NameTemplateEmpty : null;

    /// <param name="number">The file's place in the batch, from 1.</param>
    public static string Expand(string template, string sourcePath, int number, DateTime date)
    {
        var name = System.IO.Path.GetFileNameWithoutExtension(sourcePath);
        var expanded = TokenPattern().Replace(template, m =>
        {
            var format = m.Groups[2].Success ? m.Groups[2].Value.Trim() : "";
            switch (m.Groups[1].Value.ToLowerInvariant())
            {
                case "name":
                    return name;
                case "n":
                    return int.TryParse(format, NumberStyles.None, CultureInfo.InvariantCulture, out var digits) && digits is > 0 and <= 9
                        ? number.ToString("D" + digits, CultureInfo.InvariantCulture)
                        : number.ToString(CultureInfo.InvariantCulture);
                case "date":
                    try
                    {
                        return date.ToString(format.Length > 0 ? format : "yyyy-MM-dd", CultureInfo.InvariantCulture);
                    }
                    catch (FormatException)
                    {
                        return date.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
                    }
                default:
                    return System.IO.Path.GetFileName(System.IO.Path.GetDirectoryName(sourcePath)) ?? "";
            }
        });
        return Clean(expanded, name);
    }

    /// <summary><paramref name="text"/> as a file name: characters Windows refuses become "_", trailing dots and spaces go.</summary>
    private static string Clean(string text, string fallback)
    {
        var invalid = System.IO.Path.GetInvalidFileNameChars();
        var sb = new StringBuilder(text.Length);
        foreach (var c in text) sb.Append(invalid.Contains(c) || c < ' ' ? '_' : c);
        var s = sb.ToString().Trim();
        if (s.Length > MaxLength) s = s[..MaxLength];
        s = s.TrimEnd('.', ' ');
        if (s.Length == 0) s = fallback.Length > 0 ? fallback : "file";
        // CON, NUL, COM1 ... can't be file names, with or without an extension.
        var stem = s.Split('.')[0];
        if (DeviceNames.Contains(stem.TrimEnd())) s = "_" + s;
        return s;
    }
}

// ───────────────────────────── actions ─────────────────────────────

/// <summary>One action of a batch, applied to each file in turn (the order matters).</summary>
public abstract record BatchStep
{
    /// <summary>The action changes the PDF (an export only reads it).</summary>
    public virtual bool ChangesPdf => true;

    /// <summary>What the action is called in the list.</summary>
    public abstract string Title { get; }

    /// <summary>The Pro feature the action is part of (<see cref="Pro.Allows"/>), or null when it is free.</summary>
    public virtual ProFeature? Feature => null;
}

public sealed record OptimizeStep(OptimizeOptions Options) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepOptimize;
}

/// <summary>
/// AES-256 protection. Passwords are kept out of <see cref="ToString"/> (no log ever shows them). A password that is ""
/// is wanted but not given yet: a preset (<see cref="BatchPresets"/>) keeps which passwords are set, never the passwords.
/// </summary>
public sealed record ProtectStep(string? UserPassword, string? OwnerPassword, PdfPermissions Permissions, EncryptionMethod Method = EncryptionMethod.Aes256) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepProtect;

    /// <summary>A password is wanted but not given (a step read from a preset).</summary>
    public bool NeedsPasswords => UserPassword is "" || OwnerPassword is "";

    public override string ToString() => Title;
}

public sealed record UnprotectStep : BatchStep
{
    public override string Title => PdfStrings.Batch_StepUnprotect;
}

public sealed record SanitizeStep(IReadOnlySet<SanitizeItem> Items) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepSanitize;
}

/// <summary>Redaction by pattern on every page, applied at once (the pages with matches become images, as in the app).</summary>
public sealed record RedactPatternsStep(RedactionPatternOptions Options) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepRedactPatterns;

    public override ProFeature? Feature => ProFeature.PatternRedaction;
}

/// <summary>
/// Redaction check (<see cref="RedactionCheck"/>): the file fails when anything recoverable is found (it isn't saved).
/// After Redact Patterns, what that action redacted is looked for everywhere in the file.
/// </summary>
public sealed record CheckRedactionStep : BatchStep
{
    public override bool ChangesPdf => false;

    public override string Title => PdfStrings.Batch_StepCheckRedaction;
}

/// <summary>
/// Accessibility check (<see cref="AccessibilityCheck"/>, PDF/UA-1 through the Matterhorn Protocol): its report is saved beside
/// the result as a web page, and a file with any failure fails (its PDF isn't saved; the report is).
/// </summary>
public sealed record CheckAccessibilityStep : BatchStep
{
    public override bool ChangesPdf => false;

    public override string Title => PdfStrings.Batch_StepCheckAccessibility;
}

/// <summary>
/// What's in this PDF (<see cref="DocumentInventory"/>): its report is saved beside the result as a web page and as JSON.
/// Never fails a file: it reports, it doesn't judge.
/// </summary>
public sealed record ReportContentsStep : BatchStep
{
    public override bool ChangesPdf => false;

    public override string Title => PdfStrings.Batch_StepReportContents;
}

public sealed record WatermarkStep(WatermarkOptions Options) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepWatermark;
}

/// <param name="ContinueBates">Bates numbers run on from one file to the next (in list order), instead of starting again.</param>
public sealed record HeaderFooterStep(HeaderFooterOptions Options, bool ContinueBates = false) : BatchStep
{
    public override string Title => Options.Bates is not null ? PdfStrings.Batch_StepHeaderFooterBates : PdfStrings.Batch_StepHeaderFooter;
}

/// <param name="Degrees">A multiple of 90, positive clockwise.</param>
public sealed record RotateStep(int Degrees) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepRotate;
}

public sealed record FlattenStep(FlattenOptions Options) : BatchStep
{
    public override string Title => PdfStrings.Batch_StepFlatten;
}

/// <summary>An archival PDF/A-2b copy (<see cref="PdfA.Convert"/>); a file that can't be made one fails, saying why.</summary>
public sealed record SaveAsPdfAStep : BatchStep
{
    public override string Title => Conformance == PdfAConformance.A ? PdfStrings.Batch_StepPdfA2a : PdfStrings.Batch_StepPdfA;

    public override ProFeature? Feature => Conformance == PdfAConformance.A ? ProFeature.AccessibleOutput : null;

    /// <summary>A (PDF/A-2a) keeps the tags: the file must be tagged (Make Accessible before it in the list).</summary>
    public PdfAConformance Conformance { get; init; }
}

/// <summary>
/// Make Accessible (<see cref="AutoTag"/>): tags each file from its layout, with the title (metadata, else the first
/// heading, else the file name) and language (the file's, else read from the text) it proposes; tags a file had are
/// replaced. Pictures can't get alternate text here: the notes say how many need it.
/// </summary>
public sealed record MakeAccessibleStep : BatchStep
{
    public override string Title => PdfStrings.Batch_StepMakeAccessible;

    public override ProFeature? Feature => ProFeature.AutoTagging;

    /// <summary>The language when a file doesn't say one and it can't be told from the text (null: left unset).</summary>
    public string? Language { get; init; }
}

/// <summary>Text recognition of pages without text, added as an invisible text layer (the recognizer comes from <see cref="BatchHost.Recognize"/>).</summary>
public sealed record OcrStep : BatchStep
{
    public override string Title => PdfStrings.Batch_StepOcr;
}

public enum BatchExportFormat
{
    Word, Excel, Text, Png, Jpeg,
    /// <summary>Comments (<see cref="CommentFiles"/>).</summary>
    CommentsXfdf, CommentsFdf, CommentsCsv,
    /// <summary>Form data (<see cref="FormDataFiles"/>).</summary>
    FormDataXfdf, FormDataFdf, FormDataCsv, FormDataJson,
    /// <summary>A comment summary PDF (<see cref="CommentSummary"/>).</summary>
    CommentSummary,
    PowerPoint, Html,
}

/// <param name="Dpi">Resolution of page images (PNG, JPEG).</param>
public sealed record ExportStep(BatchExportFormat Format, int Dpi = 150) : BatchStep
{
    public override bool ChangesPdf => false;

    public override string Title => Format switch
    {
        BatchExportFormat.Word => PdfStrings.Batch_ExportWord,
        BatchExportFormat.Excel => PdfStrings.Batch_ExportExcel,
        BatchExportFormat.PowerPoint => PdfStrings.Batch_ExportPowerPoint,
        BatchExportFormat.Html => PdfStrings.Batch_ExportHtml,
        BatchExportFormat.Text => PdfStrings.Batch_ExportText,
        BatchExportFormat.CommentsXfdf => PdfStrings.Batch_ExportCommentsXfdf,
        BatchExportFormat.CommentsFdf => PdfStrings.Batch_ExportCommentsFdf,
        BatchExportFormat.CommentsCsv => PdfStrings.Batch_ExportCommentsCsv,
        BatchExportFormat.FormDataXfdf => PdfStrings.Batch_ExportFormXfdf,
        BatchExportFormat.FormDataFdf => PdfStrings.Batch_ExportFormFdf,
        BatchExportFormat.FormDataCsv => PdfStrings.Batch_ExportFormCsv,
        BatchExportFormat.FormDataJson => PdfStrings.Batch_ExportFormJson,
        BatchExportFormat.CommentSummary => PdfStrings.Batch_ExportCommentSummary,
        BatchExportFormat.Png => PdfStrings.Batch_ExportPng,
        _ => PdfStrings.Batch_ExportJpeg,
    };

    public bool IsImages => Format is BatchExportFormat.Png or BatchExportFormat.Jpeg;

    /// <summary>Comments, form data or a comment summary (not the pages' content).</summary>
    public bool IsReview => Format is >= BatchExportFormat.CommentsXfdf and <= BatchExportFormat.CommentSummary;
}

public enum SignedFilePolicy
{
    /// <summary>Signed PDFs are left alone (exports still read them).</summary>
    Skip,
    /// <summary>Signed PDFs are changed too; their signatures may show as changed or stop verifying.</summary>
    Edit,
}

public enum PasswordPolicy { Ask, Skip }

/// <summary>What a batch does with each file and where the results go.</summary>
public sealed record BatchPlan
{
    public required IReadOnlyList<BatchStep> Steps { get; init; }
    public required string OutputFolder { get; init; }
    public string NameTemplate { get; init; } = BatchNames.DefaultTemplate;

    /// <summary>A result whose name is taken gets a number ("report (2).pdf") instead of replacing the file. Inputs are
    /// never replaced either way.</summary>
    public bool NeverOverwrite { get; init; } = true;

    /// <summary>Results of files found in subfolders go to the same subfolders below <see cref="OutputFolder"/>.</summary>
    public bool KeepSubfolders { get; init; } = true;

    public SignedFilePolicy SignedFiles { get; init; }
    public PasswordPolicy Passwords { get; init; }

    /// <summary>The page size images are put on when they are made into a PDF.</summary>
    public PageSizeOption ImagePageSize { get; init; }

    /// <summary>Files worked on at the same time (also limited by <see cref="MemoryBudget"/>).</summary>
    public int MaxParallel { get; init; } = DefaultParallel;

    /// <summary>Bytes of estimated working memory the files being worked on may take together.</summary>
    public long MemoryBudget { get; init; } = DefaultMemoryBudget;

    /// <summary>For &lt;&lt;date&gt;&gt; in names.</summary>
    public DateTime Date { get; init; } = DateTime.Now;

    public static int DefaultParallel => Math.Clamp(Environment.ProcessorCount / 2, 1, 4);

    /// <summary>A quarter of the memory the process can use, between 256 MB and 3 GB.</summary>
    public static long DefaultMemoryBudget => Math.Clamp(GC.GetGCMemoryInfo().TotalAvailableMemoryBytes / 4, 256L << 20, 3L << 30);

    /// <summary>The PDF itself is saved: something changes it, or the file was an image made into one.</summary>
    public bool WritesPdf(BatchFile file) => file.IsImage || Steps.Any(s => s.ChangesPdf);

    /// <summary>Some action renders pages (page images, OCR, redaction), which takes far more memory than the file's size says.</summary>
    public bool RendersPages => Steps.Any(s => s is OcrStep or RedactPatternsStep or CheckRedactionStep or ExportStep { IsImages: true });

    /// <summary>Bates numbers run on across files, so the files are done one at a time, in order.</summary>
    public bool IsSequential => Steps.OfType<HeaderFooterStep>().Any(s => s.ContinueBates && s.Options.Bates is not null);

    /// <summary>What is wrong with the plan (for the dialog), or null.</summary>
    public string? Validate(bool ocrAvailable)
    {
        if (Steps.Count == 0) return PdfStrings.Batch_PlanNoSteps;
        if (Steps.Select(s => s.Feature).FirstOrDefault(f => f is { } x && !Pro.Allows(x)) is { } locked) return Pro.Locked(locked);
        if (string.IsNullOrWhiteSpace(OutputFolder) || !Path.IsPathFullyQualified(OutputFolder)) return PdfStrings.Batch_PlanNoFolder;
        if (BatchNames.Validate(NameTemplate) is { } nameError) return nameError;
        var protect = Steps.ToList().FindIndex(s => s is ProtectStep);
        if (protect >= 0 && Steps.Skip(protect + 1).Any(s => s.ChangesPdf))
            return PdfStrings.Batch_PlanProtectLast;
        if (Steps.OfType<ProtectStep>().Any(p => p.NeedsPasswords))
            return PdfStrings.Batch_PlanProtectNeedsPasswords;
        if (Steps.OfType<ProtectStep>().Any(p => string.IsNullOrEmpty(p.UserPassword) && string.IsNullOrEmpty(p.OwnerPassword)))
            return PdfStrings.Batch_PlanProtectNoPassword;
        var pdfa = Steps.ToList().FindIndex(s => s is SaveAsPdfAStep);
        if (pdfa >= 0 && Steps.Any(s => s is ProtectStep))
            return PdfStrings.Batch_PlanPdfAProtected;
        if (pdfa >= 0 && Steps.Skip(pdfa + 1).Any(s => s.ChangesPdf))
            return PdfStrings.Batch_PlanPdfALast;
        if (Steps.OfType<ExportStep>().GroupBy(e => e.Format).FirstOrDefault(g => g.Count() > 1) is { } twice)
            return Loc.Format(PdfStrings.Batch_PlanTwice, twice.First().Title);
        if (Steps.OfType<RedactPatternsStep>().Any(r => r.Options.IsEmpty))
            return PdfStrings.Batch_PlanRedactEmpty;
        if (Steps.OfType<RedactPatternsStep>().Select(r => RedactionPatterns.Validate(r.Options)).FirstOrDefault(e => e is not null) is { } patternError)
            return patternError;
        var lastRedaction = Steps.ToList().FindLastIndex(s => s is RedactPatternsStep);
        if (lastRedaction > 0 && Steps.Take(lastRedaction).Any(s => s is ExportStep or ReportContentsStep))
            return PdfStrings.Batch_PlanRedactFirst;
        if (!ocrAvailable && Steps.Any(s => s is OcrStep))
            return PdfStrings.Batch_PlanNoOcr;
        return null;
    }
}

// ───────────────────────────── running ─────────────────────────────

public enum BatchPasswordKind
{
    /// <summary>The file needs a password to open.</summary>
    Open,
    /// <summary>The file is restricted: changing it needs its permissions (owner) password.</summary>
    Permissions,
    /// <summary>An AES-256 file opened with its permissions password: keeping its open password needs that one too.</summary>
    KeepOpen,
}

public sealed record BatchPasswordRequest(BatchFile File, BatchPasswordKind Kind, bool Wrong);

/// <summary>What the app gives a batch: password prompts and text recognition.</summary>
public sealed class BatchHost
{
    /// <summary>Asks for a file's password (one prompt at a time); null skips the file. Unset: files that need one are skipped.</summary>
    public Func<BatchPasswordRequest, CancellationToken, Task<string?>>? AskPassword { get; init; }

    /// <summary>Recognizes a page's words (page points, top-left origin); called from worker threads.</summary>
    public Func<PdfEngine, int, CancellationToken, IReadOnlyList<OcrWord>>? Recognize { get; init; }

    /// <summary>The same recognizer for Redact Patterns, which also reads single places of a page again; called from worker
    /// threads, one call at a time. Unset: scanned pages can't be searched, and a file that has them fails that action.</summary>
    public InkvoltPrint.Core.Imaging.ITextRecognizer? Recognizer { get; init; }
}

/// <summary>A recognizer that runs one call at a time under a lock it shares with the other users of one engine.</summary>
public sealed class SerialRecognizer(InkvoltPrint.Core.Imaging.ITextRecognizer inner, Lock gate) : InkvoltPrint.Core.Imaging.ITextRecognizer
{
    public string Language => inner.Language;

    public string LanguageName => inner.LanguageName;

    public IReadOnlyList<InkvoltPrint.Core.Imaging.RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        lock (gate) return inner.Recognize(pixels, width, height, channels, cancel);
    }
}

public enum BatchItemState { Waiting, Running, Done, Skipped, Failed, Cancelled }

/// <param name="Outputs">Files written (also for a file that failed in a later action).</param>
/// <param name="Notes">What else happened (pages recognized, nothing to export, ...).</param>
public sealed record BatchItemResult(BatchFile File, BatchItemState State, string Message, IReadOnlyList<string> Outputs, IReadOnlyList<string> Notes)
{
    /// <summary>What Redact Patterns did to this file (masked values only), when the plan has that action.</summary>
    public RedactionFileReport? Redaction { get; init; }
}

/// <param name="Index">The file's place in the list.</param>
/// <param name="Fraction">How far this file is (0..1).</param>
/// <param name="Result">Set once the file is finished.</param>
public sealed record BatchProgress(int Index, BatchItemState State, string Message, double Fraction, BatchItemResult? Result = null);

public sealed record BatchSummary(IReadOnlyList<BatchItemResult> Items)
{
    /// <summary>Where the removal report went (the plan has Redact Patterns and some file got that far).</summary>
    public string? RedactionReportPath { get; init; }

    /// <summary>Why the removal report couldn't be written; the files' own results stand.</summary>
    public string? RedactionReportProblem { get; init; }

    /// <summary>The removal report; null when the plan has no Redact Patterns.</summary>
    public RedactionReport? RedactionReport => Items.Any(i => i.Redaction is not null) ? new RedactionReport([.. Items.Select(i => i.Redaction).OfType<RedactionFileReport>()]) : null;

    /// <summary>Files done, with pages the search couldn't vouch for.</summary>
    public int ToLookAt => Items.Count(i => i.State == BatchItemState.Done && i.Redaction is { Looks.Count: > 0 });

    public int Done => Items.Count(i => i.State == BatchItemState.Done);
    public int Skipped => Items.Count(i => i.State == BatchItemState.Skipped);
    public int Failed => Items.Count(i => i.State == BatchItemState.Failed);
    public int Cancelled => Items.Count(i => i.State == BatchItemState.Cancelled);

    /// <summary>"3 done, 1 skipped, 2 failed."</summary>
    public string Text
    {
        get
        {
            var parts = new List<string>();
            if (Done > 0) parts.Add(ToLookAt > 0 ? Loc.Plural(Done, PdfStrings.Batch_SumDoneLook_One, PdfStrings.Batch_SumDoneLook_Many, ToLookAt) : Loc.Plural(Done, PdfStrings.Batch_SumDone_One, PdfStrings.Batch_SumDone_Many));
            if (Skipped > 0) parts.Add(Loc.Plural(Skipped, PdfStrings.Batch_SumSkipped_One, PdfStrings.Batch_SumSkipped_Many));
            if (Failed > 0) parts.Add(Loc.Plural(Failed, PdfStrings.Batch_SumFailed_One, PdfStrings.Batch_SumFailed_Many));
            if (Cancelled > 0) parts.Add(Loc.Plural(Cancelled, PdfStrings.Batch_SumCancelled_One, PdfStrings.Batch_SumCancelled_Many));
            var text = parts.Count == 0 ? PdfStrings.Batch_NoFiles : string.Join(", ", parts) + ".";
            return RedactionReportProblem is { } problem ? $"{text} {problem}" : text;
        }
    }
}

/// <summary>
/// A batch: a list of actions done to each of many files, the results saved in an output folder (the originals stay as
/// they are). Files run on worker threads, a few at a time (<see cref="BatchPlan.MaxParallel"/>, and only as many as fit
/// <see cref="BatchPlan.MemoryBudget"/>: a large file runs alone). A file that fails or is skipped is listed with the
/// reason and the batch goes on; nothing is written for it (each result is written whole, through a temporary file).
/// Passwords are asked through the host, one prompt at a time; encrypted files keep their protection
/// (<see cref="KeptProtection"/>), and signed files are skipped unless the plan says otherwise.
/// </summary>
public static class BatchRunner
{
    /// <summary>Estimated working memory per byte of file (the bytes, PDFsharp's object tree, MuPDF, a copy per action).</summary>
    private const int MemoryPerByte = 8;

    private const long MinWeight = 32L << 20;

    /// <exception cref="ArgumentException">The plan isn't valid (see <see cref="BatchPlan.Validate"/>).</exception>
    public static async Task<BatchSummary> RunAsync(IReadOnlyList<BatchFile> files, BatchPlan plan, BatchHost host, IProgress<BatchProgress>? progress,
        CancellationToken cancel)
    {
        if (plan.Validate(host.Recognize is not null) is { } error) throw new ArgumentException(error, nameof(plan));
        var results = new BatchItemResult?[files.Count];
        var names = new OutputNames(!plan.NeverOverwrite, files.Select(f => f.Path));
        using var prompts = new SemaphoreSlim(1, 1);
        var gate = new WeightedGate(plan.MemoryBudget);
        var parallel = plan.IsSequential ? 1 : Math.Max(1, plan.MaxParallel);
        using var slots = new SemaphoreSlim(parallel, parallel);
        var running = new List<Task>();
        var bates = 0L; // pages numbered so far, when Bates numbers run on (sequential)

        for (var i = 0; i < files.Count; i++)
        {
            var index = i;
            var file = files[i];
            try
            {
                await slots.WaitAsync(cancel).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            long weight;
            try
            {
                weight = Weight(new FileInfo(file.Path).Length, plan.RendersPages ? LargestPage(file) : null, plan);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                weight = MinWeight; // reading it will fail and say why
            }
            try
            {
                await gate.EnterAsync(weight, cancel).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                slots.Release();
                break;
            }
            var offset = bates;
            var job = new Job(file, index, plan, host, names, prompts, progress, cancel) { BatesOffset = offset };
            running.Add(Task.Run(async () =>
            {
                try
                {
                    var result = await job.RunAsync().ConfigureAwait(false);
                    results[index] = result;
                    progress?.Report(new BatchProgress(index, result.State, result.Message, 1, result));
                }
                finally
                {
                    gate.Release(weight);
                    slots.Release();
                }
            }, CancellationToken.None));
            if (plan.IsSequential)
            {
                await running[^1].ConfigureAwait(false);
                bates += job.PageCount;
            }
        }
        await Task.WhenAll(running).ConfigureAwait(false);
        for (var i = 0; i < results.Length; i++)
        {
            if (results[i] is not null) continue;
            results[i] = new BatchItemResult(files[i], BatchItemState.Cancelled, PdfStrings.Batch_Cancelled, [], [])
            {
                Redaction = plan.Steps.Any(s => s is RedactPatternsStep) ? new RedactionFileReport(ReportName(files[i]), [], [], PdfStrings.Batch_Cancelled) : null,
            };
            progress?.Report(new BatchProgress(i, BatchItemState.Cancelled, PdfStrings.Batch_Cancelled, 0, results[i]));
        }
        var summary = new BatchSummary([.. results.Select(r => r!)]);
        if (summary.RedactionReport is not { } report) return summary;
        // Beside the results; its name carries the time so a later run doesn't replace it. Masked values only.
        var name = $"Redaction report {plan.Date:yyyy-MM-dd HHmmss}.csv";
        try
        {
            return summary with { RedactionReportPath = names.Place(plan.OutputFolder, name, temp => File.WriteAllBytes(temp, report.ToCsv())) };
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // The results are made and said for; a folder that won't take the report mustn't lose them.
            return summary with { RedactionReportProblem = PdfStrings.Batch_ReportNotSaved };
        }
    }

    /// <summary>A file in the removal report: by its name within the batch. Where it lives on this PC is no business of a report that gets passed on.</summary>
    private static string ReportName(BatchFile file) => Path.Combine(file.RelativeFolder, Path.GetFileName(file.NamedAs));

    /// <summary>OCR renders pages at this resolution (see the app's recognizer), within this many pixels.</summary>
    private const double OcrDpi = 300, OcrMaxPixels = 60_000_000;

    /// <summary>Redacted pages are drawn again at this resolution (<see cref="Redaction.Apply"/>'s), whole.</summary>
    private const double RedactDpi = 300;

    /// <summary>The redaction check draws every page at this resolution (<see cref="RedactionCheck"/>'s first look).</summary>
    private const double CheckDpi = 54;

    /// <summary>
    /// Estimated working memory of a file: its bytes (and the copies its actions make), plus, when the plan renders pages
    /// (page images, OCR), the largest page's pixels at the highest resolution asked, 4 bytes each.
    /// </summary>
    /// <param name="largestPage">The largest page in points (null: unknown, a Letter page is assumed).</param>
    internal static long Weight(long fileSize, (double Width, double Height)? largestPage, BatchPlan plan)
    {
        var weight = Math.Max(MinWeight, fileSize * MemoryPerByte);
        if (!plan.RendersPages) return weight;
        var (w, h) = largestPage ?? (612, 792);
        double pixels = 0;
        foreach (var step in plan.Steps)
        {
            var (dpi, max) = step switch
            {
                ExportStep { IsImages: true } e => ((double)e.Dpi, PageImages.MaxPixels),
                OcrStep => (OcrDpi, OcrMaxPixels),
                RedactPatternsStep => (RedactDpi, double.MaxValue),
                CheckRedactionStep => (CheckDpi, double.MaxValue),
                _ => (0d, 0d),
            };
            pixels = Math.Max(pixels, Math.Min(max, w / 72 * dpi * (h / 72 * dpi)));
        }
        return weight + (long)(pixels * 4);
    }

    /// <summary>The largest page of a file (points), read in place; null when it can't be told (encrypted, damaged).</summary>
    private static (double, double)? LargestPage(BatchFile file)
    {
        try
        {
            using var engine = PdfEngine.OpenPreview(file.Path);
            if (engine is null || engine.PageCount == 0) return null;
            var max = Enumerable.Range(0, engine.PageCount).Select(engine.GetPage).MaxBy(g => g.Width * g.Height);
            return (max.Width, max.Height);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null;
        }
    }

    /// <summary>The file is left out, with the reason (a password not given, a signed file).</summary>
    private sealed class SkipException(string reason) : Exception(reason);

    /// <summary>The redaction check found something: the file fails.</summary>
    private sealed class RedactionCheckFailedException(string message) : Exception(message);

    /// <summary>The accessibility check found failures, or couldn't check all of the file: the file fails (its report is kept).</summary>
    private sealed class AccessibilityCheckFailedException(string message) : Exception(message);

    private sealed class Job(BatchFile file, int index, BatchPlan plan, BatchHost host, OutputNames names, SemaphoreSlim prompts,
        IProgress<BatchProgress>? progress, CancellationToken cancel)
    {
        public long BatesOffset { get; init; }
        public int PageCount { get; private set; }

        private readonly List<string> _outputs = [];
        private readonly List<string> _notes = [];
        private string? _password; // opens / edits the file (owner password once known)
        private string? _openPassword; // the open password, for KeptProtection (AES-256 opened with the owner password)
        private string _baseName = "";
        /// <summary>What Redact Patterns removed (the text, the areas) and the file before it: for a later check.</summary>
        private readonly List<string> _redactedValues = [];
        private readonly Dictionary<int, List<RectD>> _redactedAreas = [];
        private byte[]? _beforeRedaction;
        private string _folder = "";
        private RedactionFileReport? _redaction;

        private void Report(string message, double fraction) => progress?.Report(new BatchProgress(index, BatchItemState.Running, message, fraction));

        private BatchItemResult Result(BatchItemState state, string message) => new(file, state, message, [.. _outputs], [.. _notes])
        {
            // Whatever stopped the file, nothing it found was removed from a saved result. Stopped before the search, it is still in the report.
            Redaction = state == BatchItemState.Done ? _redaction
                : (_redaction ?? (plan.Steps.Any(s => s is RedactPatternsStep) ? new RedactionFileReport(ReportName(file), [], [], null) : null))?.WithoutResult(message),
        };

        public async Task<BatchItemResult> RunAsync()
        {
            try
            {
                cancel.ThrowIfCancellationRequested();
                Report(PdfStrings.Batch_Reading, 0);
                _baseName = BatchNames.Expand(plan.NameTemplate, file.NamedAs, index + 1, plan.Date);
                _folder = plan.KeepSubfolders && file.RelativeFolder.Length > 0 ? Path.Combine(plan.OutputFolder, file.RelativeFolder) : plan.OutputFolder;
                var data = await File.ReadAllBytesAsync(file.Path, cancel).ConfigureAwait(false);
                if (file.IsImage)
                {
                    Report(PdfStrings.Batch_ImageToPdf, 0);
                    data = ImageImport.ImagesToPdf([(data, Path.GetFileName(file.Path))], plan.ImagePageSize);
                }
                else
                {
                    if (!LooksLikePdf(data)) return Result(BatchItemState.Failed, PdfStrings.Batch_NotPdf);
                    if (PdfSecurity.NeedsOpenPassword(data)) await UnlockAsync(data).ConfigureAwait(false);
                }
                var changes = plan.Steps.Any(s => s.ChangesPdf);
                // A signed file is left as it is (its signatures stay valid); its exports are still made from it.
                var keepSigned = changes && plan.SignedFiles == SignedFilePolicy.Skip && IsSigned(data, _password);
                // Redaction left out, its exports would hold what it was meant to remove: nothing is made from such a file.
                if (keepSigned && plan.Steps.Any(s => s is RedactPatternsStep))
                    return Result(BatchItemState.Skipped, PdfStrings.Batch_SignedNotRedacted);
                if (keepSigned && plan.Steps.All(s => s.ChangesPdf))
                    return Result(BatchItemState.Skipped, PdfStrings.Batch_SignedLeft);
                if (keepSigned) _notes.Add(PdfStrings.Batch_SignedExportedOnly);
                PageCount = Pages(data);

                for (var s = 0; s < plan.Steps.Count; s++)
                {
                    cancel.ThrowIfCancellationRequested();
                    var step = plan.Steps[s];
                    if (keepSigned && step.ChangesPdf) continue;
                    Report($"{step.Title}…", (double)s / plan.Steps.Count);
                    switch (step)
                    {
                        case ExportStep export:
                            await Task.Run(() => Export(data, export), cancel).ConfigureAwait(false);
                            break;
                        case CheckRedactionStep:
                            await Task.Run(() => CheckRedaction(data), cancel).ConfigureAwait(false);
                            break;
                        case CheckAccessibilityStep:
                            await Task.Run(() => CheckAccessibility(data), cancel).ConfigureAwait(false);
                            break;
                        case ReportContentsStep:
                            await Task.Run(() => ReportContents(data), cancel).ConfigureAwait(false);
                            break;
                        case OcrStep:
                            var words = await Task.Run(() => Recognize(data), cancel).ConfigureAwait(false);
                            if (words.Count > 0) data = await EditAsync(data, (d, pw) => TextLayer.AddInvisibleText(d, pw, words)).ConfigureAwait(false);
                            break;
                        case RedactPatternsStep redact:
                            data = await RedactPatternsAsync(data, redact).ConfigureAwait(false);
                            break;
                        default:
                            data = await EditAsync(data, (d, pw) => Apply(step, d, pw)).ConfigureAwait(false);
                            AfterStep(step);
                            break;
                    }
                }
                cancel.ThrowIfCancellationRequested();
                if (plan.WritesPdf(file) && !keepSigned)
                    _outputs.Insert(0, names.Place(_folder, _baseName + ".pdf", temp => File.WriteAllBytes(temp, data)));
                var finished = _outputs.Count == 0 ? PdfStrings.Batch_DoneNothingSaved : PdfStrings.Batch_Done;
                return Result(BatchItemState.Done, _redaction is { Looks.Count: > 0 } r ? Loc.Format(PdfStrings.Batch_DoneLookByHand, finished, RedactionReport.Pages(r.Looks.Select(l => l.Page))) : finished);
            }
            catch (OperationCanceledException)
            {
                return Result(BatchItemState.Cancelled, PdfStrings.Batch_Cancelled);
            }
            catch (SkipException ex)
            {
                return Result(BatchItemState.Skipped, ex.Message);
            }
            catch (Exception ex)
            {
                return Result(BatchItemState.Failed, Describe(ex));
            }
        }

        /// <summary>Asks for the open password until it opens the file (or the user skips it).</summary>
        private async Task UnlockAsync(byte[] data)
        {
            var wrong = false;
            while (true)
            {
                var given = await AskAsync(BatchPasswordKind.Open, wrong).ConfigureAwait(false)
                            ?? throw new SkipException(PdfStrings.Batch_NeedsOpenPasswordSkipped);
                try
                {
                    using (PdfEngine.Open(data, InputFileTypes.PDF, given)) { }
                    _password = given;
                    _openPassword = PdfSecurity.IsOpenPassword(data, given) ? given : null;
                    return;
                }
                catch (PasswordRequiredException)
                {
                    wrong = true;
                }
            }
        }

        private async Task<string?> AskAsync(BatchPasswordKind kind, bool wrong)
        {
            if (plan.Passwords == PasswordPolicy.Skip || host.AskPassword is null) return null;
            await prompts.WaitAsync(cancel).ConfigureAwait(false);
            try
            {
                cancel.ThrowIfCancellationRequested();
                return await host.AskPassword(new BatchPasswordRequest(file, kind, wrong), cancel).ConfigureAwait(false);
            }
            finally
            {
                prompts.Release();
            }
        }

        /// <summary>
        /// Runs an edit on a worker thread the way the app's edits run (keeping the protection, appending to a signed file
        /// when it can, else rewriting it as the plan allows), asking for the permissions password when the file is
        /// restricted.
        /// </summary>
        private async Task<byte[]> EditAsync(byte[] data, Func<byte[], string?, byte[]> edit)
        {
            var allowRewrite = plan.SignedFiles == SignedFilePolicy.Edit;
            while (true)
            {
                var (pw, open) = (_password, _openPassword);
                try
                {
                    return await Task.Run(() => KeptProtection.Run(open, false, () => SignedEdits.Run(() => edit(data, pw), allowRewrite).Data), cancel)
                        .ConfigureAwait(false);
                }
                catch (OwnerPasswordRequiredException ex)
                {
                    _password = await AskAsync(BatchPasswordKind.Permissions, ex.WrongPassword && pw is not null).ConfigureAwait(false)
                                ?? throw new SkipException(PdfStrings.Batch_RestrictedSkipped);
                }
                catch (OpenPasswordUnknownException)
                {
                    _openPassword = await AskAsync(BatchPasswordKind.KeepOpen, open is not null).ConfigureAwait(false)
                                    ?? throw new SkipException(PdfStrings.Batch_NeedsOpenToKeepSkipped);
                }
            }
        }

        private byte[] Apply(BatchStep step, byte[] d, string? pw)
        {
            var all = Enumerable.Range(0, PageCount).ToArray();
            switch (step)
            {
                case OptimizeStep o:
                {
                    var r = Optimizer.Optimize(d, pw, o.Options);
                    if (r.IsWorthIt) return r.Data;
                    _notes.Add(PdfStrings.Batch_AlreadyCompact);
                    return d;
                }
                case ProtectStep p: return PdfSecurity.Protect(d, pw, p.UserPassword, p.OwnerPassword, p.Permissions, p.Method);
                case UnprotectStep: return PdfSecurity.Unprotect(d, pw);
                case SanitizeStep s: return Sanitizer.Sanitize(d, pw, s.Items).Data;
                case WatermarkStep w: return Watermarks.Apply(d, pw, all, w.Options);
                case HeaderFooterStep h:
                    return HeaderFooter.Apply(d, pw, all, h.Options with
                    {
                        FileName = Path.GetFileName(file.NamedAs),
                        BatesOffset = h.ContinueBates ? (int)Math.Min(int.MaxValue, BatesOffset) : 0,
                    });
                case RotateStep r: return PageEditor.Rotate(d, pw, all, r.Degrees);
                case FlattenStep f: return Flattener.Flatten(d, pw, f.Options);
                case SaveAsPdfAStep a:
                {
                    var r = PdfA.Convert(d, pw, conformance: a.Conformance);
                    var level = a.Conformance == PdfAConformance.A ? "PDF/A-2a" : "PDF/A-2b";
                    _notes.Add(r.Changes.Count == 0 ? Loc.Format(PdfStrings.Batch_PdfANothingChanged, level) : $"{level}: {string.Join("; ", r.Changes)}");
                    return r.Data;
                }
                case MakeAccessibleStep m:
                {
                    using var engine = PdfEngine.Open(d, InputFileTypes.PDF, pw);
                    var tags = AutoTag.Plan(engine, d, pw, cancel: cancel);
                    var title = tags.Title ?? Path.GetFileNameWithoutExtension(file.NamedAs);
                    var language = tags.Language ?? m.Language;
                    var tagged = AutoTag.Write(d, pw, tags, new AccessibleOptions { Title = title, Language = language }, cancel);
                    _notes.Add(Loc.Plural(tags.Blocks.Count, PdfStrings.Batch_Tagged_One, PdfStrings.Batch_Tagged_Many, title,
                        language is null ? PdfStrings.Batch_TaggedNoLanguage
                        : Loc.Format(tags.LanguageGuessed && tags.Language is not null ? PdfStrings.Batch_TaggedLanguageRead : PdfStrings.Batch_TaggedLanguage, language),
                        tags.WasTagged ? PdfStrings.Batch_TaggedReplaced : ""));
                    if (tags.FiguresWithoutAlt > 0)
                        _notes.Add(Loc.Plural(tags.FiguresWithoutAlt, PdfStrings.Batch_FiguresNeedAlt_One, PdfStrings.Batch_FiguresNeedAlt_Many));
                    return tagged;
                }
                default: throw new NotSupportedException(step.Title);
            }
        }

        /// <summary>
        /// Redact Patterns: finds the matches (through OCR on scans), blacks them out, reads the result back and searches it
        /// again, then looks for what it removed in everything else the file holds. A match still there, a scan nothing could
        /// read, or a part of the file that couldn't be searched fails the file: nothing is saved for it.
        /// </summary>
        private async Task<byte[]> RedactPatternsAsync(byte[] data, RedactPatternsStep step)
        {
            var options = step.Options;
            var ocr = host.Recognizer;
            IProgress<(int Done, int Total)> Pages(string doing) =>
                new Progress<(int Done, int Total)>(p => Report(Loc.Format(PdfStrings.Batch_PageProgress, doing, p.Done, p.Total), (double)p.Done / Math.Max(1, p.Total)));

            var found = await Task.Run(() =>
            {
                using var engine = PdfEngine.Open(data, InputFileTypes.PDF, _password);
                return RedactionSearch.Find(engine, options, ocr, Pages(PdfStrings.Batch_SearchingPages), cancel);
            }, cancel).ConfigureAwait(false);
            var hits = found.Hits;
            var rows = hits.Select(h => RedactionReport.Row(h, RedactionOutcome.NotSaved)).ToList();
            var reportName = ReportName(file);
            _redaction = Merge(new RedactionFileReport(reportName, rows, found.Looks, null));

            if (found.UnreadScans.Any())
                throw new RedactionCheckFailedException(Loc.Plural(found.UnreadScans.Count(), PdfStrings.Batch_CantSearch_One, PdfStrings.Batch_CantSearch_Many, RedactionReport.Pages(found.UnreadScans)));

            var result = data;
            if (hits.Count > 0)
            {
                var areas = RedactionSearch.Areas(hits);
                result = await EditAsync(data, (d, pw) => Redaction.Apply(d, pw, areas)).ConfigureAwait(false);
                _beforeRedaction ??= data;
                _redactedValues.AddRange(RedactionSearch.SoughtValues(hits));
                foreach (var (page, list) in areas)
                    (_redactedAreas.TryGetValue(page, out var all) ? all : _redactedAreas[page] = []).AddRange(list);
                var remaining = await Task.Run(() => RedactionSearch.ReadBack(result, _password, options, ocr, areas.Keys.ToHashSet(), [], Pages(PdfStrings.Batch_ReadingBack), cancel), cancel).ConfigureAwait(false);
                if (remaining.Count > 0)
                {
                    _redaction = Merge(new RedactionFileReport(reportName, [.. remaining.Select(h => RedactionReport.Row(h, RedactionOutcome.StillThere))], [], null));
                    throw new RedactionCheckFailedException(Loc.Plural(remaining.Count, PdfStrings.Batch_StillThere_One, PdfStrings.Batch_StillThere_Many, RedactionReport.Pages(remaining.Select(h => h.Page))));
                }
                _notes.Add(areas.Count == 1
                    ? Loc.Plural(hits.Count, PdfStrings.Batch_RedactedOnePage_One, PdfStrings.Batch_RedactedOnePage_Many, areas.Count, RedactionPatterns.Summary(hits))
                    : Loc.Plural(hits.Count, PdfStrings.Batch_Redacted_One, PdfStrings.Batch_Redacted_Many, areas.Count, RedactionPatterns.Summary(hits)));
                _redaction = _redaction with { Removals = [.. _redaction.Removals.Select(r => r.Outcome == RedactionOutcome.NotSaved ? r with { Outcome = RedactionOutcome.Removed } : r)] };
            }
            else _notes.Add(PdfStrings.Batch_RedactNothingFound);

            // What no page shows: the values just removed, and whatever the patterns find, in comments, fields, properties, ...
            var check = await Task.Run(() => RedactionCheck.Run(result, _password, new RedactionCheckOptions { Values = _redactedValues, Patterns = options, ValuesOnly = true }, null, cancel), cancel).ConfigureAwait(false);
            if (!check.IsClean)
            {
                foreach (var f in check.Findings.Take(10)) _notes.Add(NoteOn(f));
                if (check.Findings.Count > 10) _notes.Add(Loc.Format(PdfStrings.Batch_AndMore, check.Findings.Count - 10));
                throw new RedactionCheckFailedException(Loc.Format(PdfStrings.Batch_RedactionCheckFailed, check.Summary));
            }
            if (check.Incomplete) throw new RedactionCheckFailedException(Loc.Format(PdfStrings.Batch_RedactionCheckIncomplete, string.Join(" ", check.Notes)));
            _notes.AddRange(check.Notes);

            if (found.Looks.Where(l => l.Reason == RedactionLookReason.PicturesNotRead).Select(l => l.Page).ToList() is { Count: > 0 } unread)
                _notes.Add(Loc.Format(PdfStrings.Batch_LookUnread, RedactionReport.Pages(unread)));
            if (found.Looks.Where(l => l.Reason != RedactionLookReason.PicturesNotRead).Select(l => l.Page).ToList() is { Count: > 0 } read)
                _notes.Add(Loc.Format(PdfStrings.Batch_LookOcr, RedactionReport.Pages(read)));
            return result;
        }

        /// <summary>
        /// A finding as a note: its kind and page. Notes go to the console and to a watched folder's log, and where a finding is
        /// can be named by the file itself (an attachment called "123-45-6789.pdf", a field's name), which may be what was looked for.
        /// </summary>
        private static string NoteOn(RedactionFinding f) => f.Page >= 0 ? Loc.Format(PdfStrings.Batch_NotePage, f.Page + 1, RedactionCheck.Name(f.Kind)) : RedactionCheck.Name(f.Kind);

        /// <summary>This Redact Patterns action's report added to an earlier one's (a plan can hold two).</summary>
        private RedactionFileReport Merge(RedactionFileReport next) => _redaction is not { } before ? next : before with
        {
            Removals = [.. before.Removals, .. next.Removals],
            Looks = [.. before.Looks, .. next.Looks.Where(l => !before.Looks.Any(o => o.Page == l.Page))],
        };

        /// <summary>The passwords that open and edit the result of <paramref name="step"/>.</summary>
        private void AfterStep(BatchStep step)
        {
            switch (step)
            {
                case ProtectStep p:
                    _password = string.IsNullOrEmpty(p.OwnerPassword) ? p.UserPassword : p.OwnerPassword;
                    _openPassword = string.IsNullOrEmpty(p.UserPassword) ? null : p.UserPassword;
                    break;
                case UnprotectStep or SaveAsPdfAStep: // PDF/A files aren't encrypted
                    _password = _openPassword = null;
                    break;
            }
        }

        /// <summary>The redaction check: anything found fails the file (the first findings go in its notes).</summary>
        private void CheckRedaction(byte[] data)
        {
            var report = RedactionCheck.Run(data, _password, new RedactionCheckOptions
            {
                Values = _redactedValues,
                Areas = _redactedAreas.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<RectD>)kv.Value),
                Original = _beforeRedaction,
            }, new Progress<(int Done, int Total)>(p => Report(PdfStrings.Batch_CheckingRedaction, (double)p.Done / Math.Max(1, p.Total))), cancel);
            if (report.Incomplete) _notes.AddRange(report.Notes);
            if (report.IsClean) return;
            foreach (var f in report.Findings.Take(10)) _notes.Add(NoteOn(f));
            if (report.Findings.Count > 10) _notes.Add(Loc.Format(PdfStrings.Batch_AndMore, report.Findings.Count - 10));
            throw new RedactionCheckFailedException(Loc.Format(PdfStrings.Batch_RedactionCheck, report.Summary));
        }

        /// <summary>The accessibility check: its report beside the result, and a failure or a part not checked fails the file (the first ones go in its notes).</summary>
        private void CheckAccessibility(byte[] data)
        {
            var report = AccessibilityCheck.Run(data, _password,
                new Progress<(int Done, int Total)>(p => Report(PdfStrings.Batch_CheckingAccessibility, (double)p.Done / Math.Max(1, p.Total))), cancel);
            var html = AccessibilityReportHtml.Write(report, Path.GetFileName(file.NamedAs), DateTime.Now);
            _outputs.Add(names.Place(_folder, _baseName + " accessibility.html", temp => File.WriteAllText(temp, html, new UTF8Encoding(false))));
            if (report.Passed) return;
            foreach (var f in report.Failures.Take(10)) _notes.Add($"{f.Condition} · {f.Where}: {f.Problem}");
            if (report.Failures.Count > 10) _notes.Add(Loc.Format(PdfStrings.Batch_AndMoreSeeReport, report.Failures.Count - 10));
            foreach (var n in report.Notes.Take(10)) _notes.Add(Loc.Format(PdfStrings.Batch_NotChecked, n));
            if (report.Notes.Count > 10) _notes.Add(Loc.Format(PdfStrings.Batch_AndMoreNotChecked, report.Notes.Count - 10));
            throw new AccessibilityCheckFailedException(Loc.Format(PdfStrings.Batch_AccessibilityCheck, report.Summary));
        }

        /// <summary>What's in this PDF: its report beside the result, as a web page and as JSON.</summary>
        private void ReportContents(byte[] data)
        {
            var report = DocumentInventory.Run(data, _password,
                new Progress<(int Done, int Total)>(p => Report(PdfStrings.Batch_LookingThrough, (double)p.Done / Math.Max(1, p.Total))), cancel);
            var name = Path.GetFileName(file.NamedAs);
            var now = DateTime.Now;
            var html = InventoryReportFiles.Html(report, name, now);
            var json = InventoryReportFiles.Json(report, name, now);
            _outputs.Add(names.Place(_folder, _baseName + " contents.html", temp => File.WriteAllText(temp, html, new UTF8Encoding(false))));
            _outputs.Add(names.Place(_folder, _baseName + " contents.json", temp => File.WriteAllText(temp, json, new UTF8Encoding(false))));
            if (!report.IsEmpty) _notes.Add(Loc.Format(PdfStrings.Batch_Contents, report.Summary));
        }

        private int Pages(byte[] data)
        {
            using var engine = PdfEngine.Open(data, InputFileTypes.PDF, _password);
            return engine.PageCount;
        }

        private Dictionary<int, IReadOnlyList<OcrWord>> Recognize(byte[] data)
        {
            var words = new Dictionary<int, IReadOnlyList<OcrWord>>();
            using var engine = PdfEngine.Open(data, InputFileTypes.PDF, _password);
            int hadText = 0;
            for (var p = 0; p < engine.PageCount; p++)
            {
                cancel.ThrowIfCancellationRequested();
                Report(Loc.Format(PdfStrings.Batch_Recognizing, p + 1, engine.PageCount), (double)p / engine.PageCount);
                if (TextLayer.HasText(engine, p))
                {
                    hadText++;
                    continue;
                }
                var found = host.Recognize!(engine, p, cancel);
                if (found.Count > 0) words[p] = found;
            }
            if (words.Count > 0) _notes.Add(Loc.Plural(words.Count, PdfStrings.Batch_TextRecognized_One, PdfStrings.Batch_TextRecognized_Many));
            else if (hadText < engine.PageCount) _notes.Add(PdfStrings.Batch_NoTextRecognized);
            return words;
        }

        private void Export(byte[] data, ExportStep step)
        {
            if (step.IsReview)
            {
                ExportReview(data, step);
                return;
            }
            using var engine = PdfEngine.Open(data, InputFileTypes.PDF, _password);
            if (step.IsImages)
            {
                var jpeg = step.Format == BatchExportFormat.Jpeg;
                for (var p = 0; p < engine.PageCount; p++)
                {
                    cancel.ThrowIfCancellationRequested();
                    Report(Loc.Format(PdfStrings.Batch_SavingPage, p + 1, engine.PageCount), (double)p / engine.PageCount);
                    var dpi = PageImages.ClampDpi(engine.GetPage(p), step.Dpi);
                    _outputs.Add(names.Place(_folder, $"{_baseName} - page {p + 1}.{(jpeg ? "jpg" : "png")}",
                        temp => engine.SaveImage(p, dpi, temp, jpeg, cancel)));
                }
                return;
            }

            var format = step.Format switch
            {
                BatchExportFormat.Word => ExportFormat.Word,
                BatchExportFormat.Excel => ExportFormat.Excel,
                BatchExportFormat.PowerPoint => ExportFormat.PowerPoint,
                BatchExportFormat.Html => ExportFormat.Html,
                _ => ExportFormat.Text,
            };
            using var ms = new MemoryStream();
            var report = DocumentExport.Export(engine, format, ms, new ExportOptions { Title = Path.GetFileNameWithoutExtension(file.Path), Source = data, SourcePassword = _password }, cancel);
            foreach (var problem in report.Unreadable) _notes.Add(Loc.Format(PdfStrings.Batch_PageUnreadable, problem.Page + 1));
            if (!report.Saved)
            {
                _notes.Add(format switch
                {
                    ExportFormat.Word => PdfStrings.Batch_WordNothing,
                    ExportFormat.Excel => PdfStrings.Batch_ExcelNothing,
                    ExportFormat.PowerPoint => PdfStrings.Batch_PowerPointNothing,
                    ExportFormat.Html => PdfStrings.Batch_HtmlNothing,
                    _ => PdfStrings.Batch_TextNothing,
                });
                return;
            }
            cancel.ThrowIfCancellationRequested();
            var bytes = ms.ToArray();
            _outputs.Add(names.Place(_folder, _baseName + DocumentExport.Extension(format), temp => File.WriteAllBytes(temp, bytes)));
        }

        /// <summary>Comments, form data or a comment summary beside the result; a file without any gets a note, no file.</summary>
        private void ExportReview(byte[] data, ExportStep step)
        {
            var name = System.IO.Path.GetFileName(file.NamedAs);
            byte[]? bytes = null;
            string extension;
            switch (step.Format)
            {
                case BatchExportFormat.CommentsXfdf or BatchExportFormat.CommentsFdf or BatchExportFormat.CommentsCsv:
                {
                    var format = step.Format switch
                    {
                        BatchExportFormat.CommentsXfdf => CommentFileFormat.Xfdf,
                        BatchExportFormat.CommentsFdf => CommentFileFormat.Fdf,
                        _ => CommentFileFormat.Csv,
                    };
                    var export = CommentFiles.Export(data, _password, format, name);
                    if (export.Count > 0) bytes = export.Data;
                    else _notes.Add(PdfStrings.Batch_CommentsNothing);
                    extension = (step.Format == BatchExportFormat.CommentsCsv ? " comments" : "") + CommentFiles.Extension(format);
                    break;
                }
                case BatchExportFormat.CommentSummary:
                    try
                    {
                        bytes = CommentSummary.Make(data, _password, name);
                    }
                    catch (InvalidOperationException)
                    {
                        _notes.Add(PdfStrings.Batch_CommentSummaryNothing);
                    }
                    extension = " comments.pdf";
                    break;
                default:
                {
                    var format = step.Format switch
                    {
                        BatchExportFormat.FormDataXfdf => FormDataFormat.Xfdf,
                        BatchExportFormat.FormDataFdf => FormDataFormat.Fdf,
                        BatchExportFormat.FormDataJson => FormDataFormat.Json,
                        _ => FormDataFormat.Csv,
                    };
                    if (FormEditor.DataFields(data, _password).Count > 0) bytes = FormDataFiles.Export(data, _password, format, name);
                    else _notes.Add(PdfStrings.Batch_FormDataNothing);
                    extension = (format == FormDataFormat.Csv ? " data" : "") + FormDataFiles.Extension(format);
                    break;
                }
            }
            cancel.ThrowIfCancellationRequested();
            if (bytes is not null) _outputs.Add(names.Place(_folder, _baseName + extension, temp => File.WriteAllBytes(temp, bytes)));
        }
    }

    private static bool LooksLikePdf(byte[] data) => data.AsSpan(0, Math.Min(data.Length, 1024)).IndexOf("%PDF-"u8) >= 0;

    private static bool IsSigned(byte[] data, string? password)
    {
        if (!Incremental.LooksSigned(data)) return false;
        try
        {
            return Signatures.Verify(data, password).Any(s => s.Status != SignatureStatus.Unsigned);
        }
        catch (Exception ex) when (ex is InvalidOperationException or PdfSharp.PdfSharpException or MuPDFException)
        {
            return true; // can't tell: treat it as signed rather than break a signature
        }
    }

    /// <summary>Why a file failed, in words for the list.</summary>
    internal static string Describe(Exception ex) => ex switch
    {
        PasswordRequiredException => PdfStrings.Batch_NeedsOpenPassword,
        OutOfMemoryException or InsufficientMemoryException => PdfStrings.Batch_NoMemory,
        FileNotFoundException or DirectoryNotFoundException => PdfStrings.Batch_FileGone,
        UnauthorizedAccessException => Loc.Format(PdfStrings.Batch_NoAccess, ex.Message),
        IOException => ex.Message,
        MuPDFException => PdfStrings.Batch_Damaged,
        _ when string.IsNullOrWhiteSpace(ex.Message) => ex.GetType().Name,
        _ => ex.Message,
    };

    internal static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}

/// <summary>
/// Output paths for a batch, reserved so two files never get the same one. Existing files are kept (a number is added:
/// "report (2).pdf") unless overwriting is allowed; inputs of the batch are never overwritten.
/// </summary>
internal sealed class OutputNames(bool overwrite, IEnumerable<string> inputs)
{
    private readonly Lock _gate = new();
    private readonly HashSet<string> _taken = new(inputs.Select(Path.GetFullPath), StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _inputs = new(inputs.Select(Path.GetFullPath), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Writes a result: <paramref name="write"/> fills a temporary file next to it, which is then moved to a free name for
    /// <paramref name="fileName"/>. Without overwriting, the move never replaces a file: one that appeared since the name was
    /// picked (another program) makes it take the next name. Returns where it went; nothing is left behind on failure.
    /// </summary>
    public string Place(string folder, string fileName, Action<string> write)
    {
        Directory.CreateDirectory(folder);
        var temp = Path.Combine(folder, $".{Path.GetFileName(fileName)}.{Guid.NewGuid():N}.tmp");
        try
        {
            write(temp);
            for (var attempt = 0; ; attempt++)
            {
                var path = Reserve(folder, fileName);
                try
                {
                    File.Move(temp, path, overwrite);
                    return path;
                }
                catch (IOException) when (!overwrite && File.Exists(path) && attempt < 100)
                {
                    // taken in the meantime: Reserve skips it now
                }
            }
        }
        finally
        {
            BatchRunner.TryDelete(temp);
        }
    }

    /// <summary>A free path for <paramref name="fileName"/> in <paramref name="folder"/> (created if missing).</summary>
    public string Reserve(string folder, string fileName)
    {
        Directory.CreateDirectory(folder);
        var stem = Path.GetFileNameWithoutExtension(fileName);
        var ext = Path.GetExtension(fileName);
        lock (_gate)
        {
            for (var n = 1; ; n++)
            {
                var path = Path.GetFullPath(Path.Combine(folder, n == 1 ? fileName : $"{stem} ({n}){ext}"));
                if (_taken.Contains(path) || _inputs.Contains(path)) continue;
                if (!overwrite && File.Exists(path)) continue;
                _taken.Add(path);
                return path;
            }
        }
    }
}

/// <summary>
/// An async gate with a weight budget (bytes of memory): a job enters when its weight fits beside those inside, in
/// arrival order. A job heavier than the whole budget enters when the gate is empty, and runs alone.
/// </summary>
internal sealed class WeightedGate(long budget)
{
    private readonly Lock _gate = new();
    private readonly Queue<(long Weight, TaskCompletionSource Entered)> _waiting = new();
    private long _used;
    private int _inside;

    private bool Fits(long weight) => _inside == 0 || _used + weight <= budget;

    public bool TryEnter(long weight)
    {
        lock (_gate)
        {
            if (_waiting.Count > 0 || !Fits(weight)) return false;
            _used += weight;
            _inside++;
            return true;
        }
    }

    public Task EnterAsync(long weight, CancellationToken cancel)
    {
        TaskCompletionSource entered;
        lock (_gate)
        {
            if (_waiting.Count == 0 && Fits(weight))
            {
                _used += weight;
                _inside++;
                return Task.CompletedTask;
            }
            entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
            _waiting.Enqueue((weight, entered));
        }
        if (!cancel.CanBeCanceled) return entered.Task;
        var registration = cancel.Register(() =>
        {
            lock (_gate)
            {
                if (entered.Task.IsCompleted) return; // already inside: the caller releases it
                var rest = _waiting.Where(w => w.Entered != entered).ToList();
                _waiting.Clear();
                foreach (var w in rest) _waiting.Enqueue(w);
                entered.TrySetCanceled(cancel);
            }
            Wake(); // the jobs behind it may fit now
        });
        _ = entered.Task.ContinueWith(_ => registration.Dispose(), TaskScheduler.Default);
        return entered.Task;
    }

    public void Release(long weight)
    {
        lock (_gate)
        {
            _used -= weight;
            _inside--;
        }
        Wake();
    }

    private void Wake()
    {
        var ready = new List<TaskCompletionSource>();
        lock (_gate)
        {
            while (_waiting.TryPeek(out var next) && Fits(next.Weight))
            {
                _waiting.Dequeue();
                _used += next.Weight;
                _inside++;
                ready.Add(next.Entered);
            }
        }
        foreach (var r in ready) r.TrySetResult();
    }
}

/// <summary>Page images (Export Pages as Images, batch exports).</summary>
public static class PageImages
{
    /// <summary>Largest image written, in pixels: A0 at 600 dpi would be ~560 MP (about 1.6 GB while rendering).</summary>
    public const double MaxPixels = 64_000_000;

    /// <summary>The requested dpi, lowered if the page would exceed <see cref="MaxPixels"/> at that resolution.</summary>
    public static double ClampDpi(PageGeometry g, double dpi)
    {
        var squareInches = Math.Max(1e-6, g.Width / 72 * (g.Height / 72));
        return Math.Min(dpi, Math.Floor(Math.Sqrt(MaxPixels / squareInches)));
    }
}
