using System.Security.Cryptography;

namespace InkvoltPrint.Core.Printing;

/// <summary>The bounds of a batch, so one file or one list can't take the PC or a ream of paper with it.</summary>
public static class BatchPrintLimits
{
    /// <summary>Files in a list (a folder's files count one by one).</summary>
    public const int MaxFiles = 2000;

    /// <summary>Copies of one file, as Print a PDF allows.</summary>
    public const int MaxCopies = 99;

    /// <summary>Pages of one file: each page is rendered to disk before anything is sent.</summary>
    public const int MaxPages = 5000;

    /// <summary>A file larger than this is read by nobody: it's hashed whole for the estimate.</summary>
    public const long MaxFileBytes = 2L << 30;

    /// <summary>A picture larger than this is refused before its pixels are decoded (a small file can claim a huge size), about 15,800 pixels square.</summary>
    public const long MaxPicturePixels = 250_000_000;

    /// <summary>Tries at one file's password before it's left out.</summary>
    public const int MaxPasswordTries = 3;

    /// <summary>The window asks before sending a batch of more sheets than this.</summary>
    public const int ConfirmSheets = 100;

    /// <summary>The command line and a watched folder stop short of more sheets than this in one run unless told otherwise.</summary>
    public const int DefaultMaxSheets = 500;

    /// <summary>Why a picture of this size won't be decoded, or null.</summary>
    public static string? PictureProblem(long width, long height) =>
        width <= 0 || height <= 0 ? "The picture is damaged: it has no size."
        : width * height > MaxPicturePixels ? $"The picture is too large to print ({width:N0} × {height:N0} pixels)."
        : null;

    /// <summary>Why a file of this many pages won't be printed, or null.</summary>
    public static string? PagesProblem(long pages) =>
        pages <= 0 ? "The file has no pages."
        : pages > MaxPages ? $"The file has {pages:N0} pages: a batch takes at most {MaxPages:N0} per file. Print a PDF or split it first."
        : null;
}

/// <summary>How one file of a batch prints. <see cref="Range"/> null or empty: all its pages; <see cref="Paper"/> null: the printer's default paper.</summary>
public sealed record BatchPrintSettings(int Copies = 1, string? Range = null, bool TwoSided = false, string? Paper = null)
{
    /// <summary>The sheets a job of this many pages takes: nothing else decides what the estimate says.</summary>
    public static int Sheets(int pages, int copies, bool twoSided)
    {
        var perCopy = twoSided ? ((long)pages + 1) / 2 : pages;
        return (int)Math.Min(int.MaxValue, perCopy * copies);
    }
}

/// <summary>A file's exact contents when it was looked at: the same fingerprint at print time means the estimate still holds.</summary>
public sealed record BatchFingerprint(long Length, string Sha256);

/// <summary>A file can't be printed, for a reason a person can read.</summary>
public class BatchFileException(string message) : Exception(message);

/// <summary>The PDF needs a password, or the one given doesn't open it.</summary>
public sealed class BatchPasswordException() : BatchFileException("This PDF needs a password.");

/// <summary>The printer's driver wouldn't take a setting (two-sided, the paper, the copies). Nothing was sent for this file; others may be fine.</summary>
public sealed class BatchSettingRefusedException(string message) : Exception(message);

/// <summary>The queue itself failed: the batch stops here. <see cref="MayHaveSent"/>: part of this file may have reached it, so it says to check before sending it again.</summary>
public sealed class BatchQueueException(string message, bool mayHaveSent) : Exception(message)
{
    public bool MayHaveSent { get; } = mayHaveSent;
}

/// <summary>
/// A file of a batch held open while it's read: nobody can write, rename or delete it until this is disposed, so what was
/// fingerprinted is what prints. Only files of a size the batch takes, never a link (it could point anywhere). The rendering
/// engines read through <see cref="Stream"/> or open the same path for reading.
/// </summary>
public sealed class BatchHeldFile : IDisposable
{
    private BatchHeldFile(string path, FileStream stream, BatchFingerprint fingerprint)
    {
        Path = path;
        Stream = stream;
        Fingerprint = fingerprint;
    }

    public string Path { get; }
    public FileStream Stream { get; }
    public BatchFingerprint Fingerprint { get; }

    /// <exception cref="BatchFileException">It's gone, held by another program, a link, empty or too large.</exception>
    public static async Task<BatchHeldFile> OpenAsync(string path, CancellationToken ct)
    {
        FileStream? stream = null;
        try
        {
            var info = new FileInfo(path);
            if (info.Exists && info.LinkTarget is not null) throw new BatchFileException("This is a link to a file elsewhere: add the file itself.");
            stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 16, FileOptions.Asynchronous | FileOptions.SequentialScan);
            if (stream.Length == 0) throw new BatchFileException("The file is empty.");
            if (stream.Length > BatchPrintLimits.MaxFileBytes) throw new BatchFileException($"The file is too large to print here ({stream.Length / (1 << 20):N0} MB).");
            var hash = await SHA256.HashDataAsync(stream, ct).ConfigureAwait(false);
            stream.Position = 0;
            return new BatchHeldFile(path, stream, new BatchFingerprint(stream.Length, Convert.ToHexString(hash)));
        }
        catch (Exception ex) when (ex is not BatchFileException and not OperationCanceledException)
        {
            stream?.Dispose();
            throw new BatchFileException(BatchPrintText.Describe(ex));
        }
        catch
        {
            stream?.Dispose();
            throw;
        }
    }

    public void Dispose() => Stream.Dispose();
}

/// <summary>One page drawn for printing: a JPEG and its size in inches.</summary>
public sealed record BatchPrintPage(byte[] Jpeg, double WidthInches, double HeightInches);

/// <summary>A file open for printing, held (<see cref="BatchHeldFile"/>) until disposed.</summary>
public interface IBatchDocument : IDisposable
{
    BatchFingerprint Fingerprint { get; }
    int PageCount { get; }

    /// <summary>A PDF's pages print at their size, a picture fills the paper.</summary>
    PageSizing Sizing { get; }

    /// <summary>Draws a 1-based page, off the UI thread.</summary>
    Task<BatchPrintPage> RenderAsync(int page, CancellationToken ct);
}

/// <summary>Opens the files of a batch: Windows' PDF engine and WIC in the app, a fake in the tests.</summary>
public interface IBatchDocuments
{
    /// <exception cref="BatchPasswordException">It needs a password, or <paramref name="password"/> is wrong.</exception>
    /// <exception cref="BatchFileException">It can't be read or printed.</exception>
    Task<IBatchDocument> OpenAsync(string path, string? password, CancellationToken ct);
}

/// <summary>A paper the printer offers.</summary>
public sealed record BatchPaper(string Key, string Label)
{
    public override string ToString() => Label;
}

/// <summary>What a printer takes.</summary>
public sealed record BatchQueueInfo(string Name, IReadOnlyList<BatchPaper> Papers, string? DefaultPaper, bool CanTwoSided);

/// <summary>One file as it's sent. Carries no password: the document was opened with it.</summary>
public sealed record BatchPrintJob(string Name, IReadOnlyList<int> Pages, int Copies, bool TwoSided, string? Paper, int Sheets);

/// <summary>What the queue took for a job.</summary>
public sealed record BatchReceipt(int Pages, int Sheets);

/// <summary>
/// Where a batch's jobs go: the printer's Windows queue, the made-up queue in demo mode, a fake in the tests. Roadmap 2.1 (print
/// straight to the printer over IPP) is another implementation of this: nothing above it knows which it is talking to.
/// </summary>
public interface IBatchQueue
{
    /// <summary>What the printer takes; null: it has no queue to print through.</summary>
    Task<BatchQueueInfo?> ReadAsync(CancellationToken ct);

    /// <summary>Why nothing should be sent now (offline, a jam, out of paper), or null.</summary>
    Task<string?> ProblemAsync(CancellationToken ct);

    /// <summary>
    /// Draws the job's pages, then hands them over as one job, or sends nothing. <paramref name="onSpooling"/> says the point of
    /// no return is reached: from there it finishes whatever <paramref name="ct"/> says.
    /// </summary>
    /// <exception cref="BatchSettingRefusedException">A setting wasn't kept: nothing was sent.</exception>
    /// <exception cref="BatchQueueException">The queue failed.</exception>
    /// <exception cref="BatchFileException">A page couldn't be drawn: nothing was sent.</exception>
    Task<BatchReceipt> SendAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, Action? onSpooling, CancellationToken ct);
}

/// <summary>What a driver's validated print ticket kept of what was asked, compared before anything prints.</summary>
public static class BatchTicketCheck
{
    /// <param name="askedPaper">The paper's size asked for in DIPs; null: the printer's default, nothing to compare.</param>
    /// <param name="gotTwoSided">Null: the driver doesn't say (it has no two-sided setting).</param>
    /// <returns>Why this job must not be sent, or null.</returns>
    public static string? Problem(int askedCopies, bool askedTwoSided, (double Width, double Height)? askedPaper,
        int? gotCopies, bool? gotTwoSided, (double Width, double Height)? gotPaper)
    {
        if (gotCopies is { } copies && copies != askedCopies)
            return $"The printer's driver would print {copies} {(copies == 1 ? "copy" : "copies")} instead of {askedCopies}.";
        if (askedTwoSided && gotTwoSided != true) return "The printer's driver wouldn't print this two-sided, which would take more paper than the estimate.";
        if (!askedTwoSided && gotTwoSided == true) return "The printer's driver would print this two-sided though one-sided was asked for.";
        if (askedPaper is { } paper && (gotPaper is not { } got || Math.Abs(got.Width - paper.Width) > 2 || Math.Abs(got.Height - paper.Height) > 2))
            return "The printer's driver wouldn't keep the paper chosen for this file.";
        return null;
    }
}

/// <summary>Plain words for what can go wrong reading a file.</summary>
public static class BatchPrintText
{
    public static string Describe(Exception ex) => ex switch
    {
        BatchFileException => ex.Message,
        FileNotFoundException or DirectoryNotFoundException or DriveNotFoundException => "The file is gone.",
        UnauthorizedAccessException => "Windows doesn't let Inkvolt Print read this file.",
        IOException when (ex.HResult & 0xFFFF) is 32 or 33 => "Another program is using the file: it may still be being written.",
        PathTooLongException => "The file's path is too long.",
        _ => ex.Message,
    };

    /// <summary>A file's name for a line of text: anything that would move the cursor or color a terminal is taken out.</summary>
    public static string Clean(string text)
    {
        foreach (var c in text)
            if (char.IsControl(c)) return string.Concat(text.Select(x => char.IsControl(x) ? ' ' : x));
        return text;
    }

    public static string Count(int n, string word) => n == 1 ? $"1 {word}" : $"{n:N0} {word}s";

    public static string Sheets(int n) => Count(n, "sheet");
}

/// <summary>Order in a folder: as Explorer sorts by name, so "page 2" comes before "page 10".</summary>
public sealed class NaturalOrder : IComparer<string>
{
    public static readonly NaturalOrder Instance = new();

    public int Compare(string? a, string? b)
    {
        if (a is null || b is null) return a is null ? (b is null ? 0 : -1) : 1;
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsAsciiDigit(a[i]) && char.IsAsciiDigit(b[j]))
            {
                var (startA, startB) = (i, j);
                while (i < a.Length && char.IsAsciiDigit(a[i])) i++;
                while (j < b.Length && char.IsAsciiDigit(b[j])) j++;
                var digitsA = a.AsSpan(startA, i - startA).TrimStart('0');
                var digitsB = b.AsSpan(startB, j - startB).TrimStart('0');
                var order = digitsA.Length != digitsB.Length ? digitsA.Length.CompareTo(digitsB.Length) : digitsA.SequenceCompareTo(digitsB);
                if (order != 0) return order;
                continue;
            }
            var (x, y) = (char.ToUpperInvariant(a[i]), char.ToUpperInvariant(b[j]));
            if (x != y) return x.CompareTo(y);
            i++;
            j++;
        }
        var rest = (a.Length - i).CompareTo(b.Length - j);
        return rest != 0 ? rest : string.CompareOrdinal(a, b);
    }
}

/// <summary>The files a batch takes, and what a folder comes to.</summary>
public static class BatchPrintFiles
{
    private static readonly string[] Pictures = [".jpg", ".jpeg", ".jpe", ".jfif", ".png", ".bmp", ".dib", ".gif", ".tif", ".tiff", ".heic", ".heif", ".hif", ".webp"];

    public static bool IsPdf(string path) => Path.GetExtension(path).Equals(".pdf", StringComparison.OrdinalIgnoreCase);

    /// <summary>A PDF or a picture, by its name. What it really is, is read when it's opened.</summary>
    public static bool IsSupported(string path) => IsPdf(path) || Pictures.Contains(Path.GetExtension(path), StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// The PDFs and pictures among <paramref name="paths"/>: files as given, folders as the files at their top (below too with
    /// <paramref name="recursive"/>) in Explorer's name order, each once. Links, hidden and system files aren't taken from a folder; a
    /// cloud drive's placeholders are (opening one downloads it). <paramref name="leftOut"/> counts what was given but isn't printable.
    /// </summary>
    public static List<string> Expand(IEnumerable<string> paths, bool recursive, out int leftOut)
    {
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        leftOut = 0;
        foreach (var raw in paths)
        {
            string path;
            try { path = Path.GetFullPath(raw); }
            catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
            {
                leftOut++;
                continue;
            }
            if (Directory.Exists(path))
            {
                foreach (var file in ListFolder(path, recursive))
                    if (seen.Add(file)) result.Add(file);
            }
            else if (IsSupported(path) && File.Exists(path))
            {
                if (seen.Add(path)) result.Add(path);
            }
            else leftOut++;
        }
        return result;
    }

    /// <summary>The printable files of a folder, in order.</summary>
    public static IEnumerable<string> ListFolder(string folder, bool recursive)
    {
        var options = new EnumerationOptions
        {
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.Temporary,
        };
        // Folder by folder, not RecurseSubdirectories: that goes through a junction, out of the folder or round in a loop.
        var files = new List<FileInfo>();
        var folders = new Stack<DirectoryInfo>([new DirectoryInfo(folder)]);
        while (folders.TryPop(out var at))
        {
            try
            {
                files.AddRange(at.EnumerateFiles("*", options).Where(f => IsSupported(f.Name) && !f.Name.StartsWith("~$", StringComparison.Ordinal) && !IsLink(f)));
                if (recursive)
                    foreach (var below in at.EnumerateDirectories("*", options).Where(d => !IsLink(d))) folders.Push(below);
            }
            catch (IOException) when (at.FullName != new DirectoryInfo(folder).FullName)
            {
                // a folder below that went while looking: the rest still counts
            }
        }
        return files
            .Select(f => (f.FullName, Relative: Path.GetRelativePath(folder, f.FullName)))
            .OrderBy(f => Path.GetDirectoryName(f.Relative) ?? "", NaturalOrder.Instance)
            .ThenBy(f => Path.GetFileName(f.Relative), NaturalOrder.Instance)
            .Select(f => f.FullName)
            .ToList();
    }

    /// <summary>A symbolic link or junction, as against a cloud drive's placeholder. Asking reads no file's data, so downloads nothing.</summary>
    private static bool IsLink(FileSystemInfo entry)
    {
        if ((entry.Attributes & FileAttributes.ReparsePoint) == 0) return false;
        try
        {
            return entry.LinkTarget is not null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return true; // can't tell: left alone
        }
    }
}

public enum BatchMeasureState
{
    /// <summary>It opened: its pages are counted.</summary>
    Ready,

    /// <summary>It needs a password nobody gave.</summary>
    NeedsPassword,

    /// <summary>The password given, or every try, was wrong.</summary>
    WrongPassword,

    /// <summary>It can't be printed (<see cref="BatchMeasure.Problem"/>).</summary>
    Problem,
}

/// <summary>A file as it was when last looked at. A password that opened it stays here in memory, never in any text or file.</summary>
public sealed class BatchMeasure
{
    public required BatchMeasureState State { get; init; }
    public string? Problem { get; init; }
    public int PageCount { get; init; }
    public BatchFingerprint? Fingerprint { get; init; }
    public string? Password { get; init; }

    public override string ToString() => State == BatchMeasureState.Ready ? $"{PageCount} pages" : Problem ?? State.ToString();
}

/// <summary>The timeouts around calls into engines and drivers that may hang on a hostile file or a stuck spooler: the batch goes on, or says where it stopped.</summary>
public sealed record BatchPrintOptions
{
    /// <summary>How long a file has to open (the engine hung on it, or it's a slow network file).</summary>
    public TimeSpan OpenTimeout { get; init; } = TimeSpan.FromSeconds(90);

    /// <summary>How long the queue has to say whether it's ready.</summary>
    public TimeSpan QueueTimeout { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>A job's time to be drawn and handed over: this much, plus <see cref="SendTimePerPage"/> for each page.</summary>
    public TimeSpan SendTimeout { get; init; } = TimeSpan.FromMinutes(5);

    public TimeSpan SendTimePerPage { get; init; } = TimeSpan.FromSeconds(30);
}

/// <summary>Looking at a file: its pages, and its password when it has one, asked a bounded number of times.</summary>
public static class BatchMeasurer
{
    /// <summary>
    /// Opens the file to read what the estimate needs. Only a file that asks gets a password: <paramref name="offered"/> first (one that
    /// opened it before, or a command line's), once, then <paramref name="ask"/> (file, wrong: the last password didn't open it; null
    /// back: leave it out), at most <see cref="BatchPrintLimits.MaxPasswordTries"/> times. With no <paramref name="ask"/> (a command line,
    /// a watched folder) nobody is asked. Never throws for the file.
    /// </summary>
    public static async Task<BatchMeasure> MeasureAsync(string path, string? offered, IBatchDocuments documents, Func<string, bool, Task<string?>>? ask,
        BatchPrintOptions? options, CancellationToken ct)
    {
        options ??= new BatchPrintOptions();
        string? password = null;
        var asked = 0;
        while (true)
        {
            try
            {
                using var document = await OpenAsync(path, password, documents, options, ct).ConfigureAwait(false);
                if (BatchPrintLimits.PagesProblem(document.PageCount) is { } pages) return new BatchMeasure { State = BatchMeasureState.Problem, Problem = pages };
                return new BatchMeasure { State = BatchMeasureState.Ready, PageCount = document.PageCount, Fingerprint = document.Fingerprint, Password = password };
            }
            catch (BatchPasswordException)
            {
                var wrong = password is not null;
                if (offered is not null)
                {
                    (password, offered) = (offered, null);
                    continue;
                }
                if (ask is null || asked >= BatchPrintLimits.MaxPasswordTries)
                    return wrong
                        ? new BatchMeasure { State = BatchMeasureState.WrongPassword, Problem = "The password doesn't open this PDF: it's left out." }
                        : new BatchMeasure { State = BatchMeasureState.NeedsPassword, Problem = "This PDF needs a password: it's left out." };
                asked++;
                password = await ask(Path.GetFileName(path), wrong).ConfigureAwait(false);
                if (password is null) return new BatchMeasure { State = BatchMeasureState.NeedsPassword, Problem = "This PDF needs a password: it's left out." };
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return new BatchMeasure { State = BatchMeasureState.Problem, Problem = BatchPrintText.Describe(ex) };
            }
        }
    }

    /// <summary>Opens a document within the time allowed; one that opens after giving up on it is closed then.</summary>
    internal static async Task<IBatchDocument> OpenAsync(string path, string? password, IBatchDocuments documents, BatchPrintOptions options, CancellationToken ct)
    {
        var opening = documents.OpenAsync(path, password, ct);
        try
        {
            return await opening.WaitAsync(options.OpenTimeout, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is TimeoutException or OperationCanceledException && !opening.IsCompleted)
        {
            _ = opening.ContinueWith(t => t.Result.Dispose(), CancellationToken.None, TaskContinuationOptions.OnlyOnRanToCompletion, TaskScheduler.Default);
            if (ex is TimeoutException) throw new BatchFileException("The file took too long to open: it may be damaged. It's left out.");
            throw;
        }
    }
}

/// <summary>One line of a batch: a file, how it prints, and what that comes to now that its pages are known.</summary>
public sealed class BatchPrintLine
{
    public BatchPrintLine(string path, BatchPrintSettings settings, BatchMeasure measure, BatchQueueInfo? queue)
    {
        Path = path;
        Settings = settings;
        Measure = measure;
        Problem = Check(settings, measure, queue, out var pages);
        Pages = pages;
        Sheets = Problem is null ? BatchPrintSettings.Sheets(pages.Count, settings.Copies, settings.TwoSided) : 0;
    }

    public string Path { get; }
    public string Name => System.IO.Path.GetFileName(Path);
    public BatchPrintSettings Settings { get; }
    public BatchMeasure Measure { get; }

    /// <summary>Why this line won't print, or null. Never quietly another range, paper or side: it says so and doesn't print.</summary>
    public string? Problem { get; }

    /// <summary>The pages it prints; none with a <see cref="Problem"/>.</summary>
    public IReadOnlyList<int> Pages { get; }

    public int Sheets { get; }

    public override string ToString() => $"{BatchPrintText.Clean(Name)}: {Problem ?? BatchPrintText.Sheets(Sheets)}";

    private static string? Check(BatchPrintSettings s, BatchMeasure measure, BatchQueueInfo? queue, out IReadOnlyList<int> pages)
    {
        pages = [];
        if (measure.State != BatchMeasureState.Ready) return measure.Problem ?? "This file can't be read.";
        if (s.Copies is < 1 or > BatchPrintLimits.MaxCopies) return $"Copies must be 1 to {BatchPrintLimits.MaxCopies}.";
        if (s.TwoSided && queue is { CanTwoSided: false }) return "This printer doesn't print two-sided.";
        if (s.Paper is { } paper && queue is not null && !queue.Papers.Any(p => string.Equals(p.Key, paper, StringComparison.OrdinalIgnoreCase)))
            return $"This printer doesn't offer the paper \"{BatchPrintText.Clean(paper)}\".";
        return PageRange.TryParse(s.Range, measure.PageCount, out pages, out var error) ? null : $"The pages \"{BatchPrintText.Clean(s.Range ?? "")}\" can't be printed: {error}.";
    }
}

/// <summary>Where a file got to in a batch.</summary>
public enum BatchPrintState
{
    Waiting,
    Sending,

    /// <summary>Handed to the printer's queue. Whether paper came out is the printer's to say.</summary>
    Sent,

    /// <summary>Left out before sending (a password, a range, a damaged file).</summary>
    Skipped,

    /// <summary>It couldn't be sent: it changed or vanished, or sending failed.</summary>
    Failed,

    /// <summary>The batch stopped before it: not sent.</summary>
    Stopped,
}

/// <summary>One file's result.</summary>
public sealed record BatchPrintResult(int Index, string Path, BatchPrintState State, string Message, int Pages, int Copies, bool TwoSided, string? Paper,
    int SheetsEstimated, int SheetsSent, DateTime Time)
{
    public string Name => System.IO.Path.GetFileName(Path);

    /// <summary>Sending failed part-way: some of it may be in the queue, so it's never sent again without someone choosing to.</summary>
    public bool MayHaveSent { get; init; }

    /// <summary>Print sends this file (again): it hasn't reached the queue, for sure. Pressing Print twice or resuming a stopped batch never prints a file twice.</summary>
    public bool StillToSend => State is BatchPrintState.Waiting or BatchPrintState.Stopped or BatchPrintState.Skipped;
}

/// <param name="Index">The file's place in the list.</param>
/// <param name="Result">Set when the file's finished.</param>
public sealed record BatchPrintProgress(int Index, BatchPrintState State, string Message, BatchPrintResult? Result = null);

/// <summary>What a batch did.</summary>
/// <param name="StoppedAt">The first file not sent because the batch stopped; null: it went to the end.</param>
public sealed record BatchPrintSummary(IReadOnlyList<BatchPrintResult> Items, int? StoppedAt, string? StopReason)
{
    /// <summary>Exit codes, the same as Inkvolt PDF's command line: every file sent; a file failed or was skipped; wrong command line (nothing done); stopped before the end.</summary>
    public const int Done = 0, SomeFailed = 1, Wrong = 2, Stopped = 3;

    public int Sent => Items.Count(i => i.State == BatchPrintState.Sent);
    public int Skipped => Items.Count(i => i.State == BatchPrintState.Skipped);
    public int Failed => Items.Count(i => i.State == BatchPrintState.Failed);
    public int NotSent => Items.Count(i => i.State == BatchPrintState.Stopped);
    public int SheetsSent => Items.Sum(i => i.SheetsSent);

    public int ExitCode => StoppedAt is not null ? Stopped : Failed + Skipped > 0 ? SomeFailed : Done;

    /// <summary>"Stopped at file 7 of 50 (report.pdf): Paper jam. 6 sent, 44 not sent." or "48 sent (87 sheets), 1 skipped, 1 failed."</summary>
    public string Text
    {
        get
        {
            var parts = new List<string>();
            if (Sent > 0 || Items.Count == 0) parts.Add($"{Sent:N0} sent ({BatchPrintText.Sheets(SheetsSent)})");
            if (Skipped > 0) parts.Add($"{Skipped:N0} skipped");
            if (Failed > 0) parts.Add($"{Failed:N0} failed");
            if (NotSent > 0) parts.Add($"{NotSent:N0} not sent");
            var counts = string.Join(", ", parts) + ".";
            if (StoppedAt is not { } at) return counts;
            var where = at < Items.Count ? $"Stopped at file {at + 1:N0} of {Items.Count:N0} ({BatchPrintText.Clean(Items[at].Name)})" : "Stopped";
            return $"{where}: {StopReason} {counts}";
        }
    }
}

/// <summary>
/// Sends a batch: one file at a time, in the order given, each as one job. Just before sending, a file is opened and held and
/// must be byte for byte what the estimate saw, or it isn't printed. A file that can't be sent is listed and the batch goes on;
/// a queue that fails or reports a problem stops it, and the rest are listed as not sent. Stopping (<paramref name="ct"/> in
/// <see cref="RunAsync"/>) takes effect between files and between pages being drawn; a job already handed over finishes.
/// </summary>
public static class BatchPrintRunner
{
    public static async Task<BatchPrintSummary> RunAsync(IReadOnlyList<BatchPrintLine> lines, IBatchQueue queue, IBatchDocuments documents, BatchPrintOptions? options,
        IProgress<BatchPrintProgress>? progress, CancellationToken ct)
    {
        options ??= new BatchPrintOptions();
        var results = new List<BatchPrintResult>(lines.Count);
        int? stoppedAt = null;
        string? stopReason = null;

        void Stop(int at, string why)
        {
            stoppedAt ??= at;
            stopReason ??= why;
        }
        void Finish(int index, BatchPrintLine line, BatchPrintState state, string message, int sheetsSent = 0, bool unsure = false)
        {
            var result = new BatchPrintResult(index, line.Path, state, message, line.Pages.Count, line.Settings.Copies, line.Settings.TwoSided, line.Settings.Paper,
                line.Sheets, sheetsSent, DateTime.Now) { MayHaveSent = unsure };
            results.Add(result);
            progress?.Report(new BatchPrintProgress(index, state, message, result));
        }

        for (var i = 0; i < lines.Count; i++)
        {
            var line = lines[i];
            if (line.Problem is { } problem)
            {
                Finish(i, line, BatchPrintState.Skipped, problem);
                continue;
            }
            if (stoppedAt is not null)
            {
                Finish(i, line, BatchPrintState.Stopped, "Not sent: the batch stopped before it.");
                continue;
            }
            if (ct.IsCancellationRequested)
            {
                Stop(i, "You stopped the batch.");
                Finish(i, line, BatchPrintState.Stopped, "Not sent: the batch stopped before it.");
                continue;
            }

            progress?.Report(new BatchPrintProgress(i, BatchPrintState.Sending, "Getting it ready…"));
            var (state, message, sheets, stop, unsure) = await SendOneAsync(line, queue, documents, options, progress, i, ct).ConfigureAwait(false);
            if (stop is not null) Stop(i, stop);
            Finish(i, line, state, message, sheets, unsure);
        }
        return new BatchPrintSummary(results, stoppedAt, stopReason);
    }

    private static async Task<(BatchPrintState State, string Message, int Sheets, string? Stop, bool Unsure)> SendOneAsync(BatchPrintLine line, IBatchQueue queue, IBatchDocuments documents,
        BatchPrintOptions options, IProgress<BatchPrintProgress>? progress, int index, CancellationToken ct)
    {
        const string NotSent = "Not sent: the batch stopped before it.";
        try
        {
            string? problem;
            try
            {
                problem = await queue.ProblemAsync(ct).WaitAsync(options.QueueTimeout, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                problem = ex is TimeoutException ? "Windows doesn't answer about the printer." : ex.Message;
            }
            if (problem is not null) return (BatchPrintState.Stopped, NotSent, 0, problem, false);

            IBatchDocument document;
            try
            {
                document = await BatchMeasurer.OpenAsync(line.Path, line.Measure.Password, documents, options, ct).ConfigureAwait(false);
            }
            catch (BatchPasswordException)
            {
                return (BatchPrintState.Failed, "The file changed since the estimate: its password no longer opens it. Not printed.", 0, null, false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                return (BatchPrintState.Failed, $"{BatchPrintText.Describe(ex)} Not printed.", 0, null, false);
            }

            using (document)
            {
                if (document.Fingerprint != line.Measure.Fingerprint || document.PageCount != line.Measure.PageCount)
                    return (BatchPrintState.Failed, "The file changed since the estimate" +
                        (document.PageCount != line.Measure.PageCount ? $" ({BatchPrintText.Count(line.Measure.PageCount, "page")} then, {document.PageCount:N0} now)" : "") +
                        ". Not printed: check the list again to print it.", 0, null, false);

                var job = new BatchPrintJob(line.Name, line.Pages, line.Settings.Copies, line.Settings.TwoSided, line.Settings.Paper, line.Sheets);
                var limit = options.SendTimeout + options.SendTimePerPage * line.Pages.Count;
                var spooling = false;
                var report = progress is null ? null : new Relay(m => progress.Report(new BatchPrintProgress(index, BatchPrintState.Sending, m)));
                // The wait isn't cancelled by the token: the queue takes it up to the point of no return, and a job past it has to finish.
                using var sendCancel = CancellationTokenSource.CreateLinkedTokenSource(ct);
                var sending = queue.SendAsync(document, job, report, () => spooling = true, sendCancel.Token);
                BatchReceipt receipt;
                try
                {
                    receipt = await sending.WaitAsync(limit, CancellationToken.None).ConfigureAwait(false);
                }
                catch (TimeoutException)
                {
                    sendCancel.Cancel(); // a drawing that hung sends nothing if it ever wakes up
                    return (BatchPrintState.Failed, spooling ? "Windows didn't finish taking it in time: check the queue before sending it again."
                        : "It took too long to draw: it may be damaged. Not printed.", 0,
                        spooling ? "Windows stopped taking jobs." : null, spooling);
                }
                if (receipt.Sheets > line.Sheets)
                    return (BatchPrintState.Failed, $"The queue took {BatchPrintText.Sheets(receipt.Sheets)}, more than the {line.Sheets:N0} estimated.", receipt.Sheets,
                        "A job came to more sheets than its estimate, so nothing more is sent.", true);
                return (BatchPrintState.Sent, $"Sent to the queue: {BatchPrintText.Sheets(receipt.Sheets)}.", receipt.Sheets, null, false);
            }
        }
        catch (OperationCanceledException)
        {
            return (BatchPrintState.Stopped, NotSent, 0, "You stopped the batch.", false);
        }
        catch (BatchSettingRefusedException ex)
        {
            return (BatchPrintState.Failed, $"{ex.Message} Not printed.", 0, null, false);
        }
        catch (BatchFileException ex)
        {
            return (BatchPrintState.Failed, $"{ex.Message} Not printed.", 0, null, false);
        }
        catch (BatchQueueException ex) when (ex.MayHaveSent)
        {
            return (BatchPrintState.Failed, "Sending failed part-way: check the queue before sending it again.", 0, ex.Message, true);
        }
        catch (BatchQueueException ex)
        {
            return (BatchPrintState.Stopped, NotSent, 0, ex.Message, false);
        }
        catch (Exception ex)
        {
            // Spooler, driver and serializer errors come in many types. Whether any of the job got there isn't known.
            return (BatchPrintState.Failed, "Sending failed: check the queue before sending it again.", 0, ex.Message, true);
        }
    }

    /// <summary>Reports on the reporting thread (Progress&lt;T&gt; would post them later, after the summary line).</summary>
    private sealed class Relay(Action<string> report) : IProgress<string>
    {
        public void Report(string value) => report(value);
    }
}
