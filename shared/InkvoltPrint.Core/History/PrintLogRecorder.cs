using System.Buffers.Binary;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Core.History;

/// <summary>
/// What the spooler said about one job in one notice (JOB_NOTIFY_FIELD_*): only the fields it sent are set. The spooler's job ids are
/// its own across all queues on this PC, and used again: <see cref="Submitted"/> tells two jobs with one id apart.
/// </summary>
public sealed record JobChange(int Id)
{
    public string? Printer { get; init; }
    public string? Document { get; init; }
    public string? User { get; init; }
    public string? Machine { get; init; }
    public JobStatus? Status { get; init; }
    public int? TotalPages { get; init; }
    public int? PagesPrinted { get; init; }
    public DateTimeOffset? Submitted { get; init; }

    /// <summary>From the job's DEVMODE (<see cref="JobSettings.Read"/>), when it came.</summary>
    public JobSettings? Settings { get; init; }

    /// <summary>A SYSTEMTIME in UTC as the spooler gives a job's submission time (eight little-endian 16-bit numbers); null for one that isn't a date.</summary>
    public static DateTimeOffset? SystemTime(ReadOnlySpan<byte> b)
    {
        if (b.Length < 16) return null;
        static int U(ReadOnlySpan<byte> b, int i) => BinaryPrimitives.ReadUInt16LittleEndian(b[(i * 2)..]);
        int year = U(b, 0), month = U(b, 1), day = U(b, 3), hour = U(b, 4), minute = U(b, 5), second = U(b, 6), ms = U(b, 7);
        if (year is < 1990 or > 9000 || month is < 1 or > 12 || day < 1 || day > DateTime.DaysInMonth(year, month) || hour > 23 || minute > 59 || second > 59 || ms > 999)
            return null;
        return new DateTimeOffset(year, month, day, hour, minute, second, ms, TimeSpan.Zero);
    }

    /// <summary>Two changes for one job in one notice, the later's fields winning.</summary>
    public JobChange Merge(JobChange later) => this with
    {
        Printer = later.Printer ?? Printer,
        Document = later.Document ?? Document,
        User = later.User ?? User,
        Machine = later.Machine ?? Machine,
        Status = later.Status ?? Status,
        TotalPages = later.TotalPages ?? TotalPages,
        PagesPrinted = later.PagesPrinted ?? PagesPrinted,
        Submitted = later.Submitted ?? Submitted,
        Settings = later.Settings ?? Settings,
    };
}

/// <summary>What a job's DEVMODE says, where it says it (its dmFields): copies, color or black and white, one side or two.</summary>
public sealed record JobSettings(int? Copies, bool? Color, bool? TwoSided)
{
    private const uint DmCopies = 0x100, DmColor = 0x800, DmDuplex = 0x1000;

    /// <summary>
    /// A DEVMODEW as the spooler hands it over (wingdi.h): dmSize at 68, dmFields at 72, dmCopies at 86, dmColor at 92, dmDuplex at
    /// 94, each read only when dmFields says it's set and the structure is long enough to hold it. Null for anything shorter than the
    /// fields it would need, or a dmSize past what came (a driver's private part after it isn't read).
    /// </summary>
    public static JobSettings? Read(ReadOnlySpan<byte> devmode)
    {
        if (devmode.Length < 76) return null;
        int size = BinaryPrimitives.ReadUInt16LittleEndian(devmode[68..]);
        if (size < 76 || size > devmode.Length) return null;
        var fields = BinaryPrimitives.ReadUInt32LittleEndian(devmode[72..]);
        static short? Short(ReadOnlySpan<byte> d, int size, int at) => at + 2 <= size ? BinaryPrimitives.ReadInt16LittleEndian(d[at..]) : null;
        int? copies = (fields & DmCopies) != 0 && Short(devmode, size, 86) is { } c and > 0 ? Math.Min((int)c, PrintLog.MaxCopies) : null;
        bool? color = (fields & DmColor) != 0 ? Short(devmode, size, 92) switch { 1 => false, 2 => true, _ => null } : null;
        bool? twoSided = (fields & DmDuplex) != 0 ? Short(devmode, size, 94) switch { 1 => false, 2 or 3 => true, _ => null } : null;
        return new JobSettings(copies, color, twoSided);
    }
}

/// <summary>What one call from the spooler's job watcher is.</summary>
public enum JobNoticeKind
{
    /// <summary>Some jobs' fields changed.</summary>
    Changes,

    /// <summary>The spooler's whole list, after it dropped notices.</summary>
    Everything,

    /// <summary>The whole list as watching begins (jobs already printed were there before).</summary>
    EverythingFirst,

    /// <summary>Watching stopped (the spooler restarted, or the app closes): no changes.</summary>
    Stopped,
}

/// <summary>
/// The print log as the app keeps it (roadmap 4.9): the job watcher's notices through a <see cref="PrintLogRecorder"/> into a
/// <see cref="PrintLogFile"/>, only while <see cref="On"/>. Thread-safe: notices come on the watcher's thread, the switch from the window.
/// </summary>
public sealed class PrintLogKeeper(PrintLogFile file, Func<DateTimeOffset>? clock = null)
{
    private readonly Lock _gate = new();
    private readonly PrintLogRecorder _recorder = new();
    private readonly Func<DateTimeOffset> _clock = clock ?? (() => DateTimeOffset.Now);
    private bool _on = true;

    public PrintLogFile File => file;

    /// <summary>Logging (the setting; on by default). Turned off, the jobs followed are forgotten and nothing more is written.</summary>
    public bool On
    {
        get { lock (_gate) return _on; }
        set
        {
            lock (_gate)
            {
                if (_on == value) return;
                _on = value;
                if (!value) _recorder.Reset();
            }
        }
    }

    /// <summary>Raised (on the watcher's thread) after jobs were added to the log.</summary>
    public event Action? Added;

    /// <summary>One call from the watcher.</summary>
    public void Notice(IReadOnlyList<JobChange> changes, JobNoticeKind kind)
    {
        IReadOnlyList<PrintLogEntry> done;
        var now = _clock();
        lock (_gate)
        {
            if (!_on) return;
            done = kind switch
            {
                JobNoticeKind.Changes => _recorder.Notice(changes, now),
                JobNoticeKind.Everything => _recorder.Refresh(changes, now, first: false),
                JobNoticeKind.EverythingFirst => _recorder.Refresh(changes, now, first: true),
                _ => Stop(),
            };
            if (done.Count > 0) file.Add(done, now);
        }
        if (done.Count > 0) Added?.Invoke();
    }

    private IReadOnlyList<PrintLogEntry> Stop()
    {
        _recorder.Reset();
        return [];
    }
}

/// <summary>
/// Turns the spooler's job notices into print log entries (roadmap 4.9): each job followed from the notices about it (its fields
/// arrive a few at a time), logged once when it has printed, or when it leaves the queue (deleted, or missing from the spooler's whole
/// list after notices were lost). A job already printed when the watching starts (a queue that keeps printed jobs) was there before:
/// not logged again. How it ended: printed when the spooler said so, or it had started printing or printed every page; cancelled when
/// it was deleted before printing; left when it went with neither. Not thread-safe: the watcher's one thread calls it.
/// </summary>
public sealed class PrintLogRecorder
{
    /// <summary>Most jobs followed at once (a spooler with more is a print server, and the log isn't for one).</summary>
    public const int MaxOpen = 2_000;

    private readonly Dictionary<int, Job> _jobs = [];

    /// <summary>Jobs followed now (for tests).</summary>
    public int Open => _jobs.Count;

    /// <summary>Notices: the entries for the jobs they finished.</summary>
    public IReadOnlyList<PrintLogEntry> Notice(IEnumerable<JobChange> changes, DateTimeOffset now)
    {
        var done = new List<PrintLogEntry>();
        foreach (var change in Group(changes)) Apply(change, now, done, quietlyIfFinished: false);
        return done;
    }

    /// <summary>
    /// The spooler's whole list (asked for after notices were lost, and when the watching starts: <paramref name="first"/>): each job as
    /// a notice, and every job followed that isn't on it has left. On the first list, a job already printed isn't logged.
    /// </summary>
    public IReadOnlyList<PrintLogEntry> Refresh(IEnumerable<JobChange> all, DateTimeOffset now, bool first)
    {
        var done = new List<PrintLogEntry>();
        var seen = new HashSet<int>();
        foreach (var change in Group(all))
        {
            seen.Add(change.Id);
            Apply(change, now, done, quietlyIfFinished: first);
        }
        foreach (var id in _jobs.Keys.Where(id => !seen.Contains(id)).ToList()) End(id, now, done);
        return done;
    }

    /// <summary>The watching stopped (the app closes, the spooler restarted): jobs still in a queue are seen again on the next start.</summary>
    public void Reset() => _jobs.Clear();

    private static IEnumerable<JobChange> Group(IEnumerable<JobChange> changes)
    {
        var order = new List<int>();
        var byId = new Dictionary<int, JobChange>();
        foreach (var c in changes)
        {
            if (byId.TryGetValue(c.Id, out var had)) byId[c.Id] = had.Merge(c);
            else
            {
                byId[c.Id] = c;
                order.Add(c.Id);
            }
        }
        return order.Select(id => byId[id]);
    }

    private void Apply(JobChange change, DateTimeOffset now, List<PrintLogEntry> done, bool quietlyIfFinished)
    {
        if (_jobs.TryGetValue(change.Id, out var job) && change.Submitted is { } submitted && job.Submitted is { } known && submitted != known)
        {
            End(change.Id, now, done); // the id is used again: the job it was is gone
            job = null;
        }
        if (job is null)
        {
            if (_jobs.Count >= MaxOpen) return;
            _jobs[change.Id] = job = new Job();
            job.Quiet = quietlyIfFinished && change.Status is { } s && Finished(s);
        }
        job.Take(change);
        if (job.Status.HasFlag(JobStatus.Deleted))
        {
            End(change.Id, now, done);
            return;
        }
        if (!job.Logged && Finished(job.Status))
        {
            job.Logged = true;
            if (!job.Quiet) done.Add(job.Entry(PrintLogOutcome.Printed, now));
        }
    }

    /// <summary>Printed and kept, or completed: the spooler is done with it (a job being deleted is ended by its deletion).</summary>
    private static bool Finished(JobStatus s) =>
        (s & (JobStatus.Printed | JobStatus.Completed)) != 0
        || (s.HasFlag(JobStatus.Retained) && (s & (JobStatus.Printing | JobStatus.Error | JobStatus.Blocked | JobStatus.UserIntervention | JobStatus.Deleting)) == 0);

    private void End(int id, DateTimeOffset now, List<PrintLogEntry> done)
    {
        if (!_jobs.Remove(id, out var job) || job.Logged || job.Quiet) return;
        var outcome = job.PrintedSeen || job.PrintingSeen || (job.Pages > 0 && job.PagesPrinted >= job.Pages) ? PrintLogOutcome.Printed
            : job.DeletingSeen ? PrintLogOutcome.Cancelled
            : PrintLogOutcome.Left;
        done.Add(job.Entry(outcome, now));
    }

    private sealed class Job
    {
        public string? Printer, Document, User, Machine;
        public JobStatus Status;
        public int Pages, PagesPrinted;
        public DateTimeOffset? Submitted;
        public JobSettings? Settings;
        public bool Logged, Quiet, PrintedSeen, PrintingSeen, DeletingSeen;

        public void Take(JobChange c)
        {
            Printer = c.Printer ?? Printer;
            Document = c.Document ?? Document;
            User = c.User ?? User;
            Machine = c.Machine ?? Machine;
            Submitted ??= c.Submitted;
            if (c.Settings is { } settings) Settings = settings;
            if (c.TotalPages is { } total) Pages = Math.Max(Pages, Math.Clamp(total, 0, PrintLog.MaxPages));
            if (c.PagesPrinted is { } printed) PagesPrinted = Math.Max(PagesPrinted, Math.Clamp(printed, 0, PrintLog.MaxPages));
            if (c.Status is { } s)
            {
                Status = s;
                PrintedSeen |= (s & (JobStatus.Printed | JobStatus.Completed)) != 0;
                PrintingSeen |= s.HasFlag(JobStatus.Printing) && !DeletingSeen;
                DeletingSeen |= s.HasFlag(JobStatus.Deleting);
            }
        }

        public PrintLogEntry Entry(PrintLogOutcome outcome, DateTimeOffset now) =>
            PrintLog.Clean(new PrintLogEntry(Submitted ?? now, Printer ?? "", AlertText.DocumentName(Document, PrintLog.MaxText), User ?? "",
                Pages > 0 ? Pages : PagesPrinted / Math.Max(1, Settings?.Copies ?? 1), Settings?.Copies ?? 1, Settings?.Color, Settings?.TwoSided, outcome,
                Machine, PagesPrinted))!;
    }
}
