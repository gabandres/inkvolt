namespace InkvoltPdf.Core;

/// <summary>
/// Explorer's "Convert to Word with Inkvolt PDF" and the command line behind it: <c>inkvoltpdf --convert-to word
/// &lt;files…&gt;</c> (also <c>excel</c>, <c>powerpoint</c>, <c>text</c>, <c>html</c>, or the extension), the command bar's
/// one-click Convert for each file, with its defaults. The launch hands the request to a running copy (the app's single
/// instance) with <see cref="ToArguments"/>; the copy reads it back with <see cref="TryParse"/>.
/// </summary>
/// <remarks>
/// Every argument after the format is a file, whatever it looks like (Explorer passes full paths; a name may start with
/// "--"). Relative ones are made full against this launch's folder; full ones (UNC, <c>\\?\</c> long paths) are kept as
/// given, so Windows 10's device mapping (<c>C:\x\CON.pdf</c> → <c>\\.\CON</c>) never changes one. An argument holding a
/// control character is dropped: forwarding puts one argument per line, and no Windows file name holds one.
/// </remarks>
public static class ConvertCommand
{
    public const string Switch = "--convert-to";

    /// <summary>The most files one request converts (Explorer passes a whole selection); the rest are counted as dropped.</summary>
    public const int MaxFiles = 500;

    public enum ParseError { None, NotACommand, NoFormat, UnknownFormat, NoFiles }

    /// <summary>
    /// What to convert: the format, the files (full paths, in order, each once), and what was left out: files past
    /// <see cref="MaxFiles"/> (<paramref name="OverLimit"/>) and arguments that can't be a file name (a control character,
    /// a path Windows refuses: <paramref name="Refused"/>), said apart.
    /// </summary>
    public sealed record Request(ExportFormat Format, IReadOnlyList<string> Files, int OverLimit = 0, int Refused = 0);

    /// <summary>
    /// The app's own options (<c>--lang</c>, <c>--script</c>) come before <c>--convert-to</c>; from it on, everything is the
    /// command, every argument after the format a file. Without the command, all of it is options and files.
    /// </summary>
    public static (IReadOnlyList<string> Options, IReadOnlyList<string> Command) SplitOptions(IReadOnlyList<string> args)
    {
        for (var i = 0; i < args.Count; i++)
            if (IsCommand([args[i]]))
                return ([.. args.Take(i)], [.. args.Skip(i)]);
        return ([.. args], []);
    }

    /// <summary>
    /// Several launches' requests as one batch per format (Explorer starts one launch per selected file): files in the
    /// order they came, each once, at most <see cref="MaxFiles"/>; what each left out added up.
    /// </summary>
    public static IReadOnlyList<Request> Merge(IReadOnlyList<Request> requests)
    {
        var merged = new List<Request>();
        foreach (var format in requests.Select(r => r.Format).Distinct())
        {
            var files = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            int over = 0, refused = 0;
            foreach (var r in requests.Where(r => r.Format == format))
            {
                over += r.OverLimit;
                refused += r.Refused;
                foreach (var f in r.Files)
                {
                    if (!seen.Add(f)) continue;
                    if (files.Count >= MaxFiles) over++;
                    else files.Add(f);
                }
            }
            merged.Add(new Request(format, files, over, refused));
        }
        return merged;
    }

    /// <summary>
    /// Whether the app may exit: no main window, no conversions window, no conversion gathering, waiting or running, and
    /// no launch's files read but not handled yet (closing the main window mid-batch would leave an empty name.docx).
    /// </summary>
    public static bool MayExit(bool mainOpen, bool listOpen, bool converting, int forwards) =>
        !mainOpen && !listOpen && !converting && forwards == 0;

    private static readonly (string Name, ExportFormat Format)[] Names =
    [
        ("word", ExportFormat.Word), ("docx", ExportFormat.Word),
        ("excel", ExportFormat.Excel), ("xlsx", ExportFormat.Excel),
        ("powerpoint", ExportFormat.PowerPoint), ("pptx", ExportFormat.PowerPoint),
        ("text", ExportFormat.Text), ("txt", ExportFormat.Text),
        ("html", ExportFormat.Html),
    ];

    /// <summary>True when the first argument is <c>--convert-to</c> or <c>--convert-to=…</c> (any case).</summary>
    public static bool IsCommand(IReadOnlyList<string> args) =>
        args.Count > 0 && (args[0].Equals(Switch, StringComparison.OrdinalIgnoreCase)
                           || args[0].StartsWith(Switch + "=", StringComparison.OrdinalIgnoreCase));

    /// <summary>Reads <c>--convert-to format file…</c> or <c>--convert-to=format file…</c>.</summary>
    public static bool TryParse(IReadOnlyList<string> args, out Request? request, out ParseError error)
    {
        request = null;
        if (!IsCommand(args))
        {
            error = ParseError.NotACommand;
            return false;
        }
        var first = args[0];
        string? name;
        int filesFrom;
        if (first.Length > Switch.Length)
        {
            name = first[(Switch.Length + 1)..];
            filesFrom = 1;
        }
        else
        {
            name = args.Count > 1 ? args[1] : null;
            filesFrom = 2;
        }
        if (string.IsNullOrWhiteSpace(name))
        {
            error = ParseError.NoFormat;
            return false;
        }
        // A forwarded launch's own leftovers: "word:3:1" (ToArguments); each count bounded.
        var parts = name.Trim().Split(':');
        int over = 0, refused = 0;
        if (FormatNamed(parts[0]) is not { } format
            || parts.Length is not (1 or 3)
            || parts.Length == 3 && !(int.TryParse(parts[1], out over) && int.TryParse(parts[2], out refused)
                                      && over is >= 0 and <= 1_000_000 && refused is >= 0 and <= 1_000_000))
        {
            error = ParseError.UnknownFormat;
            return false;
        }
        var files = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        for (var i = filesFrom; i < args.Count; i++)
        {
            var arg = args[i];
            if (string.IsNullOrWhiteSpace(arg)) continue;
            if (arg.Any(char.IsControl) || Full(arg) is not { } full)
            {
                refused++;
                continue;
            }
            if (!seen.Add(full)) continue;
            if (files.Count >= MaxFiles)
            {
                over++;
                continue;
            }
            files.Add(full);
        }
        if (files.Count == 0)
        {
            error = ParseError.NoFiles;
            return false;
        }
        request = new Request(format, files, over, refused);
        error = ParseError.None;
        return true;
    }

    private static ExportFormat? FormatNamed(string name)
    {
        foreach (var (n, f) in Names)
            if (n.Equals(name, StringComparison.OrdinalIgnoreCase))
                return f;
        return null;
    }

    private static string? Full(string arg)
    {
        if (Path.IsPathFullyQualified(arg)) return arg;
        try
        {
            return Path.GetFullPath(arg);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException or IOException)
        {
            return null;
        }
    }

    /// <summary>The request as one launch hands it to another: the format joined to the switch, then the full paths.</summary>
    /// <remarks>What the launch left out travels in the switch (<c>--convert-to=word:3:1</c>: over the limit, refused), so the
    /// running copy says so; every argument after it stays a file.</remarks>
    public static string[] ToArguments(Request request) =>
        [$"{Switch}={Names.First(n => n.Format == request.Format).Name}{(request.OverLimit + request.Refused > 0 ? $":{request.OverLimit}:{request.Refused}" : "")}",
            .. request.Files];

    /// <summary>
    /// The output's name: the PDF's, with the format's extension (<c>report.pdf</c> → <c>report.docx</c>). A name Windows
    /// maps to a device gets "_" (<c>_CON.docx</c>), as Split and Extract do; an empty one is "Untitled".
    /// </summary>
    public static string OutputName(string pdfPath, ExportFormat format)
    {
        var stem = Path.GetFileNameWithoutExtension(pdfPath).Trim().TrimEnd('.', ' ');
        if (stem.Length == 0) stem = "Untitled";
        if (InkvoltPrint.Core.DeviceNames.IsReserved(stem)) stem = "_" + stem;
        return stem + DocumentExport.Extension(format);
    }

    /// <summary>
    /// Where a request's result shows: the in-app one-click's notice ("Saved report.docx · Show in folder · Change
    /// options…") when the main window is up, nothing else is converting or listed, and the request is one file; the small
    /// conversions window otherwise (several files, the app not open, or Explorer's launches arriving one per file).
    /// </summary>
    public static bool ShowsNotice(bool windowReady, bool listOpen, bool busy, int files) =>
        windowReady && !listOpen && !busy && files == 1;
}

/// <summary>How one conversion ended.</summary>
public enum ConvertResult { Saved, NotFound, NotOpened, NothingToSave, Cancelled, Failed }

/// <summary>
/// A conversion's result: the file written (and whether it went to Documents) with its notes ("2 pages recognized"), or
/// the message that says why nothing was written, ready to show.
/// </summary>
public sealed record ConvertOutcome(ConvertResult Result, string? Output, bool InDocuments, string? Message)
{
    public static ConvertOutcome Saved(string output, bool inDocuments, string? notes) => new(ConvertResult.Saved, output, inDocuments, notes);

    public static ConvertOutcome Failed(ConvertResult result, string? message) => new(result, null, false, message);
}

/// <summary>One file of a request in the <see cref="ConvertQueue"/>.</summary>
public sealed class ConvertJob
{
    public enum States { Waiting, Converting, Done }

    public required string Pdf { get; init; }
    public required ExportFormat Format { get; init; }

    /// <summary>Opened when written: asked for (the notice of a batch of this one file, as the one-click opens it); a listed one never is.</summary>
    public bool Open { get; init; }

    public States State { get; internal set; }
    public ConvertOutcome? Outcome { get; internal set; }
}

/// <summary>
/// The conversions one copy of the app runs for Explorer: one at a time, in the order asked, on the caller's thread (the
/// conversion may ask, as for a password), each file once while it waits or runs. A conversion that throws ends as
/// <see cref="ConvertResult.Failed"/> with its message and the next one starts. The list keeps the last
/// <see cref="MaxListed"/>; finished ones go first.
/// </summary>
public sealed class ConvertQueue(Func<ConvertJob, CancellationToken, Task<ConvertOutcome>> convert)
{
    public const int MaxListed = 1000;

    private readonly List<ConvertJob> _jobs = [];
    private CancellationTokenSource _cancel = new();
    private TaskCompletionSource _idle = Done();
    private bool _running;

    public IReadOnlyList<ConvertJob> Jobs => _jobs;

    /// <summary>A job was added, started or finished.</summary>
    public event Action<ConvertJob>? Changed;

    /// <summary>Done when nothing waits or runs.</summary>
    public Task Idle => _idle.Task;

    /// <summary>A job waits or runs (false already when the last one's Done is reported).</summary>
    public bool IsBusy => _jobs.Any(j => j.State != ConvertJob.States.Done);

    private static TaskCompletionSource Done()
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        done.SetResult();
        return done;
    }

    /// <summary>
    /// Queues each file of <paramref name="request"/> not already waiting or converting; returns those added. With
    /// <paramref name="open"/>, a request of one file opens its result when written.
    /// </summary>
    public IReadOnlyList<ConvertJob> Add(ConvertCommand.Request request, bool open = false)
    {
        var added = new List<ConvertJob>();
        foreach (var pdf in request.Files)
        {
            if (_jobs.Any(j => j.State != ConvertJob.States.Done && j.Format == request.Format
                               && string.Equals(j.Pdf, pdf, StringComparison.OrdinalIgnoreCase)))
                continue;
            var job = new ConvertJob { Pdf = pdf, Format = request.Format, Open = open && request.Files.Count == 1 };
            _jobs.Add(job);
            added.Add(job);
            Changed?.Invoke(job);
        }
        Trim();
        if (added.Count > 0 && !_running) _ = RunAsync();
        return added;
    }

    /// <summary>Stops the conversion running and those waiting (each ends Cancelled).</summary>
    public void CancelAll()
    {
        _cancel.Cancel();
        foreach (var job in _jobs.Where(j => j.State == ConvertJob.States.Waiting).ToList()) Finish(job, ConvertOutcome.Failed(ConvertResult.Cancelled, null));
    }

    private async Task RunAsync()
    {
        _running = true;
        if (_idle.Task.IsCompleted) _idle = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        try
        {
            while (_jobs.FirstOrDefault(j => j.State == ConvertJob.States.Waiting) is { } job)
            {
                if (_cancel.IsCancellationRequested) _cancel = new CancellationTokenSource();
                job.State = ConvertJob.States.Converting;
                Changed?.Invoke(job);
                ConvertOutcome outcome;
                try
                {
                    outcome = await convert(job, _cancel.Token);
                }
                catch (OperationCanceledException)
                {
                    outcome = ConvertOutcome.Failed(ConvertResult.Cancelled, null);
                }
                catch (Exception ex)
                {
                    outcome = ConvertOutcome.Failed(ConvertResult.Failed, ex.Message);
                }
                Finish(job, outcome);
            }
        }
        finally
        {
            _running = false;
            _idle.TrySetResult();
        }
    }

    private void Finish(ConvertJob job, ConvertOutcome outcome)
    {
        job.Outcome = outcome;
        job.State = ConvertJob.States.Done;
        Changed?.Invoke(job);
    }

    private void Trim()
    {
        for (var i = 0; i < _jobs.Count && _jobs.Count > MaxListed;)
        {
            if (_jobs[i].State == ConvertJob.States.Done) _jobs.RemoveAt(i);
            else i++;
        }
    }
}

/// <summary>
/// Explorer starts one launch per selected file, each a moment after the last: the running copy gathers the requests
/// that come within <see cref="Quiet"/> of each other (at most <see cref="Longest"/> after the first) and handles them as
/// one batch (<see cref="ConvertCommand.Merge"/>), so nine files make one list, not a notice and a list of eight.
/// </summary>
public sealed class ConvertGather
{
    public static readonly TimeSpan Quiet = TimeSpan.FromMilliseconds(400);
    public static readonly TimeSpan Longest = TimeSpan.FromSeconds(2);

    private readonly List<ConvertCommand.Request> _requests = [];
    private DateTime _first, _last;

    public bool IsEmpty => _requests.Count == 0;

    /// <summary>When the batch is complete: <see cref="Quiet"/> after the last request, or <see cref="Longest"/> after the first.</summary>
    public DateTime? DueAt => IsEmpty ? null : Min(_last + Quiet, _first + Longest);

    private static DateTime Min(DateTime a, DateTime b) => a < b ? a : b;

    public void Add(ConvertCommand.Request request, DateTime now)
    {
        if (IsEmpty) _first = now;
        _last = now;
        _requests.Add(request);
    }

    public bool IsDue(DateTime now) => DueAt is { } due && now >= due;

    /// <summary>The batch, one request per format, and nothing gathered after.</summary>
    public IReadOnlyList<ConvertCommand.Request> Take()
    {
        var merged = ConvertCommand.Merge(_requests);
        _requests.Clear();
        return merged;
    }
}
