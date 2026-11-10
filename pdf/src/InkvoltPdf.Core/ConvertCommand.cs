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

    /// <summary>What to convert: the format, the files (full paths, in order, each once) and how many were left out.</summary>
    public sealed record Request(ExportFormat Format, IReadOnlyList<string> Files, int Dropped);

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
        if (FormatNamed(name.Trim()) is not { } format)
        {
            error = ParseError.UnknownFormat;
            return false;
        }
        var files = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var dropped = 0;
        for (var i = filesFrom; i < args.Count; i++)
        {
            var arg = args[i];
            if (string.IsNullOrWhiteSpace(arg)) continue;
            if (arg.Any(char.IsControl) || Full(arg) is not { } full)
            {
                dropped++;
                continue;
            }
            if (!seen.Add(full)) continue;
            if (files.Count >= MaxFiles)
            {
                dropped++;
                continue;
            }
            files.Add(full);
        }
        if (files.Count == 0)
        {
            error = ParseError.NoFiles;
            return false;
        }
        request = new Request(format, files, dropped);
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
    public static string[] ToArguments(Request request) =>
        [$"{Switch}={Names.First(n => n.Format == request.Format).Name}", .. request.Files];

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

    /// <summary>Opened when written: the request was this one file (as the one-click opens it); a selection isn't.</summary>
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

    /// <summary>Queues each file of <paramref name="request"/> not already waiting or converting; returns those added.</summary>
    public IReadOnlyList<ConvertJob> Add(ConvertCommand.Request request)
    {
        var added = new List<ConvertJob>();
        foreach (var pdf in request.Files)
        {
            if (_jobs.Any(j => j.State != ConvertJob.States.Done && j.Format == request.Format
                               && string.Equals(j.Pdf, pdf, StringComparison.OrdinalIgnoreCase)))
                continue;
            var job = new ConvertJob { Pdf = pdf, Format = request.Format, Open = request.Files.Count == 1 };
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
