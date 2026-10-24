using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>A file of a batch.</summary>
/// <param name="Path">Its full path.</param>
/// <param name="RelativeFolder">The folder below an added folder it was found in ("" at the top or when added on its own):
/// with <see cref="BatchPlan.KeepSubfolders"/> its results go to the same folder below the output folder.</param>
public sealed record BatchFile(string Path, string RelativeFolder = "")
{
    public bool IsImage => BatchFiles.IsImage(Path);
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
        string.IsNullOrWhiteSpace(template) ? "Type a name for the results, for example <<name>>." : null;

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
}

public sealed record OptimizeStep(OptimizeOptions Options) : BatchStep
{
    public override string Title => "Reduce file size";
}

/// <summary>AES-256 protection. Passwords are kept out of <see cref="ToString"/> (no log ever shows them).</summary>
public sealed record ProtectStep(string? UserPassword, string? OwnerPassword, PdfPermissions Permissions, EncryptionMethod Method = EncryptionMethod.Aes256) : BatchStep
{
    public override string Title => "Protect with a password";

    public override string ToString() => Title;
}

public sealed record UnprotectStep : BatchStep
{
    public override string Title => "Remove password protection";
}

public sealed record SanitizeStep(IReadOnlySet<SanitizeItem> Items) : BatchStep
{
    public override string Title => "Sanitize";
}

public sealed record WatermarkStep(WatermarkOptions Options) : BatchStep
{
    public override string Title => "Add watermark";
}

/// <param name="ContinueBates">Bates numbers run on from one file to the next (in list order), instead of starting again.</param>
public sealed record HeaderFooterStep(HeaderFooterOptions Options, bool ContinueBates = false) : BatchStep
{
    public override string Title => Options.Bates is not null ? "Add header, footer & Bates numbers" : "Add header & footer";
}

/// <param name="Degrees">A multiple of 90, positive clockwise.</param>
public sealed record RotateStep(int Degrees) : BatchStep
{
    public override string Title => "Rotate pages";
}

public sealed record FlattenStep(FlattenOptions Options) : BatchStep
{
    public override string Title => "Flatten";
}

/// <summary>Text recognition of pages without text, added as an invisible text layer (the recognizer comes from <see cref="BatchHost.Recognize"/>).</summary>
public sealed record OcrStep : BatchStep
{
    public override string Title => "Recognize text (OCR)";
}

public enum BatchExportFormat { Word, Excel, Text, Png, Jpeg }

/// <param name="Dpi">Resolution of page images (PNG, JPEG).</param>
public sealed record ExportStep(BatchExportFormat Format, int Dpi = 150) : BatchStep
{
    public override bool ChangesPdf => false;

    public override string Title => Format switch
    {
        BatchExportFormat.Word => "Export to Word",
        BatchExportFormat.Excel => "Export tables to Excel",
        BatchExportFormat.Text => "Export as plain text",
        BatchExportFormat.Png => "Export pages as PNG images",
        _ => "Export pages as JPEG images",
    };

    public bool IsImages => Format is BatchExportFormat.Png or BatchExportFormat.Jpeg;
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

    /// <summary>Bates numbers run on across files, so the files are done one at a time, in order.</summary>
    public bool IsSequential => Steps.OfType<HeaderFooterStep>().Any(s => s.ContinueBates && s.Options.Bates is not null);

    /// <summary>What is wrong with the plan (for the dialog), or null.</summary>
    public string? Validate(bool ocrAvailable)
    {
        if (Steps.Count == 0) return "Add at least one action.";
        if (string.IsNullOrWhiteSpace(OutputFolder) || !Path.IsPathFullyQualified(OutputFolder)) return "Choose a folder for the results.";
        if (BatchNames.Validate(NameTemplate) is { } nameError) return nameError;
        var protect = Steps.ToList().FindIndex(s => s is ProtectStep);
        if (protect >= 0 && Steps.Skip(protect + 1).Any(s => s.ChangesPdf))
            return "Put \"Protect with a password\" after the other changes: they would need its password.";
        if (Steps.OfType<ProtectStep>().Any(p => string.IsNullOrEmpty(p.UserPassword) && string.IsNullOrEmpty(p.OwnerPassword)))
            return "Protect with a password needs an open password, a permissions password, or both.";
        if (Steps.OfType<ExportStep>().GroupBy(e => e.Format).FirstOrDefault(g => g.Count() > 1) is { } twice)
            return $"\"{twice.First().Title}\" is in the list twice.";
        if (!ocrAvailable && Steps.Any(s => s is OcrStep))
            return "Text recognition isn't available: Windows has no OCR language installed.";
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
}

public enum BatchItemState { Waiting, Running, Done, Skipped, Failed, Cancelled }

/// <param name="Outputs">Files written (also for a file that failed in a later action).</param>
/// <param name="Notes">What else happened (pages recognized, nothing to export, ...).</param>
public sealed record BatchItemResult(BatchFile File, BatchItemState State, string Message, IReadOnlyList<string> Outputs, IReadOnlyList<string> Notes);

/// <param name="Index">The file's place in the list.</param>
/// <param name="Fraction">How far this file is (0..1).</param>
/// <param name="Result">Set once the file is finished.</param>
public sealed record BatchProgress(int Index, BatchItemState State, string Message, double Fraction, BatchItemResult? Result = null);

public sealed record BatchSummary(IReadOnlyList<BatchItemResult> Items)
{
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
            if (Done > 0) parts.Add($"{Done} done");
            if (Skipped > 0) parts.Add($"{Skipped} skipped");
            if (Failed > 0) parts.Add($"{Failed} failed");
            if (Cancelled > 0) parts.Add($"{Cancelled} cancelled");
            return parts.Count == 0 ? "No files." : string.Join(", ", parts) + ".";
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
                weight = Math.Max(MinWeight, new FileInfo(file.Path).Length * MemoryPerByte);
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
            results[i] = new BatchItemResult(files[i], BatchItemState.Cancelled, "Cancelled", [], []);
            progress?.Report(new BatchProgress(i, BatchItemState.Cancelled, "Cancelled", 0, results[i]));
        }
        return new BatchSummary([.. results.Select(r => r!)]);
    }

    /// <summary>The file is left out, with the reason (a password not given, a signed file).</summary>
    private sealed class SkipException(string reason) : Exception(reason);

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
        private string _folder = "";

        private void Report(string message, double fraction) => progress?.Report(new BatchProgress(index, BatchItemState.Running, message, fraction));

        private BatchItemResult Result(BatchItemState state, string message) => new(file, state, message, [.. _outputs], [.. _notes]);

        public async Task<BatchItemResult> RunAsync()
        {
            try
            {
                cancel.ThrowIfCancellationRequested();
                Report("Reading…", 0);
                _baseName = BatchNames.Expand(plan.NameTemplate, file.Path, index + 1, plan.Date);
                _folder = plan.KeepSubfolders && file.RelativeFolder.Length > 0 ? Path.Combine(plan.OutputFolder, file.RelativeFolder) : plan.OutputFolder;
                var data = await File.ReadAllBytesAsync(file.Path, cancel).ConfigureAwait(false);
                if (file.IsImage)
                {
                    Report("Making a PDF of the image…", 0);
                    data = ImageImport.ImagesToPdf([(data, Path.GetFileName(file.Path))], plan.ImagePageSize);
                }
                else
                {
                    if (!LooksLikePdf(data)) return Result(BatchItemState.Failed, "This file isn't a PDF.");
                    if (PdfSecurity.NeedsOpenPassword(data)) await UnlockAsync(data).ConfigureAwait(false);
                }
                var changes = plan.Steps.Any(s => s.ChangesPdf);
                if (changes && plan.SignedFiles == SignedFilePolicy.Skip && IsSigned(data, _password))
                    return Result(BatchItemState.Skipped, "Signed: left as it is so its signatures stay valid");
                PageCount = Pages(data);

                for (var s = 0; s < plan.Steps.Count; s++)
                {
                    cancel.ThrowIfCancellationRequested();
                    var step = plan.Steps[s];
                    Report($"{step.Title}…", (double)s / plan.Steps.Count);
                    switch (step)
                    {
                        case ExportStep export:
                            await Task.Run(() => Export(data, export), cancel).ConfigureAwait(false);
                            break;
                        case OcrStep:
                            var words = await Task.Run(() => Recognize(data), cancel).ConfigureAwait(false);
                            if (words.Count > 0) data = await EditAsync(data, (d, pw) => TextLayer.AddInvisibleText(d, pw, words)).ConfigureAwait(false);
                            break;
                        default:
                            data = await EditAsync(data, (d, pw) => Apply(step, d, pw)).ConfigureAwait(false);
                            AfterStep(step);
                            break;
                    }
                }
                cancel.ThrowIfCancellationRequested();
                if (plan.WritesPdf(file))
                {
                    var path = names.Reserve(_folder, _baseName + ".pdf");
                    WriteAtomic(path, data);
                    _outputs.Insert(0, path);
                }
                return Result(BatchItemState.Done, _outputs.Count == 0 ? "Done (nothing to save)" : "Done");
            }
            catch (OperationCanceledException)
            {
                return Result(BatchItemState.Cancelled, "Cancelled");
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
                            ?? throw new SkipException("Needs a password to open (skipped)");
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
                                ?? throw new SkipException("Restricted: needs its permissions password to be changed (skipped)");
                }
                catch (OpenPasswordUnknownException)
                {
                    _openPassword = await AskAsync(BatchPasswordKind.KeepOpen, open is not null).ConfigureAwait(false)
                                    ?? throw new SkipException("Needs its open password to keep it protected (skipped)");
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
                    _notes.Add("Already compact: size left as it was");
                    return d;
                }
                case ProtectStep p: return PdfSecurity.Protect(d, pw, p.UserPassword, p.OwnerPassword, p.Permissions, p.Method);
                case UnprotectStep: return PdfSecurity.Unprotect(d, pw);
                case SanitizeStep s: return Sanitizer.Sanitize(d, pw, s.Items).Data;
                case WatermarkStep w: return Watermarks.Apply(d, pw, all, w.Options);
                case HeaderFooterStep h:
                    return HeaderFooter.Apply(d, pw, all, h.Options with
                    {
                        FileName = Path.GetFileName(file.Path),
                        BatesOffset = h.ContinueBates ? (int)Math.Min(int.MaxValue, BatesOffset) : 0,
                    });
                case RotateStep r: return PageEditor.Rotate(d, pw, all, r.Degrees);
                case FlattenStep f: return Flattener.Flatten(d, pw, f.Options);
                default: throw new NotSupportedException(step.Title);
            }
        }

        /// <summary>The passwords that open and edit the result of <paramref name="step"/>.</summary>
        private void AfterStep(BatchStep step)
        {
            switch (step)
            {
                case ProtectStep p:
                    _password = string.IsNullOrEmpty(p.OwnerPassword) ? p.UserPassword : p.OwnerPassword;
                    _openPassword = string.IsNullOrEmpty(p.UserPassword) ? null : p.UserPassword;
                    break;
                case UnprotectStep:
                    _password = _openPassword = null;
                    break;
            }
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
                Report($"Recognizing text: page {p + 1} of {engine.PageCount}…", (double)p / engine.PageCount);
                if (TextLayer.HasText(engine, p))
                {
                    hadText++;
                    continue;
                }
                var found = host.Recognize!(engine, p, cancel);
                if (found.Count > 0) words[p] = found;
            }
            if (words.Count > 0) _notes.Add($"Text recognized on {Plural(words.Count, "page")}");
            else if (hadText < engine.PageCount) _notes.Add("No text recognized");
            return words;
        }

        private void Export(byte[] data, ExportStep step)
        {
            using var engine = PdfEngine.Open(data, InputFileTypes.PDF, _password);
            if (step.IsImages)
            {
                var jpeg = step.Format == BatchExportFormat.Jpeg;
                for (var p = 0; p < engine.PageCount; p++)
                {
                    cancel.ThrowIfCancellationRequested();
                    Report($"Saving page {p + 1} of {engine.PageCount}…", (double)p / engine.PageCount);
                    var path = names.Reserve(_folder, $"{_baseName} - page {p + 1}.{(jpeg ? "jpg" : "png")}");
                    try
                    {
                        engine.SaveImage(p, PageImages.ClampDpi(engine.GetPage(p), step.Dpi), path, jpeg, cancel);
                    }
                    catch
                    {
                        TryDelete(path); // no half an image
                        throw;
                    }
                    _outputs.Add(path);
                }
                return;
            }

            var pages = new List<(int Number, ExportPage Page)>();
            for (var p = 0; p < engine.PageCount; p++)
            {
                cancel.ThrowIfCancellationRequested();
                try
                {
                    pages.Add((p + 1, engine.GetExportPage(p, step.Format == BatchExportFormat.Word, cancel)));
                }
                catch (MuPDFException)
                {
                    var g = engine.GetPage(p);
                    pages.Add((p + 1, new ExportPage(g.Width, g.Height, [], [], [])));
                    _notes.Add($"Page {p + 1} couldn't be read");
                }
            }
            var title = Path.GetFileNameWithoutExtension(file.Path);
            var withText = pages.Any(p => p.Page.HasText);
            switch (step.Format)
            {
                case BatchExportFormat.Word:
                    if (!withText && pages.All(p => p.Page.Images.Count == 0))
                    {
                        _notes.Add("Word: no text or pictures, nothing saved");
                        return;
                    }
                    Save(".docx", s => DocumentExport.WriteDocx(s, pages.Select(p => p.Page), title));
                    break;
                case BatchExportFormat.Excel:
                    var tables = DocumentExport.Tables(pages);
                    if (tables.Count == 0)
                    {
                        _notes.Add("Excel: no tables found, nothing saved");
                        return;
                    }
                    Save(".xlsx", s => XlsxWriter.Write(s, tables, title));
                    break;
                default:
                    if (!withText)
                    {
                        _notes.Add("Text: no text found, nothing saved");
                        return;
                    }
                    var text = DocumentExport.PlainText(pages.Select(p => p.Page));
                    Save(".txt", s => s.Write([.. Encoding.UTF8.GetPreamble(), .. Encoding.UTF8.GetBytes(text)]));
                    break;
            }
        }

        private void Save(string extension, Action<Stream> write)
        {
            using var ms = new MemoryStream();
            write(ms);
            cancel.ThrowIfCancellationRequested();
            var path = names.Reserve(_folder, _baseName + extension);
            WriteAtomic(path, ms.ToArray());
            _outputs.Add(path);
        }
    }

    private static string Plural(int n, string word) => n == 1 ? $"1 {word}" : $"{n} {word}s";

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
        PasswordRequiredException => "Needs a password to open",
        OutOfMemoryException or InsufficientMemoryException => "Not enough memory for this file",
        FileNotFoundException or DirectoryNotFoundException => "The file isn't there any more",
        UnauthorizedAccessException => $"No access: {ex.Message}",
        IOException => ex.Message,
        MuPDFException => "This PDF is damaged and can't be read",
        _ when string.IsNullOrWhiteSpace(ex.Message) => ex.GetType().Name,
        _ => ex.Message,
    };

    /// <summary>Writes through a temporary file next to <paramref name="path"/>, so a failure leaves no half-written file.</summary>
    private static void WriteAtomic(string path, byte[] bytes)
    {
        var temp = Path.Combine(Path.GetDirectoryName(path)!, $".{Path.GetFileName(path)}.{Guid.NewGuid():N}.tmp");
        try
        {
            File.WriteAllBytes(temp, bytes);
            File.Move(temp, path, overwrite: true);
        }
        catch
        {
            TryDelete(temp);
            throw;
        }
    }

    private static void TryDelete(string path)
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
