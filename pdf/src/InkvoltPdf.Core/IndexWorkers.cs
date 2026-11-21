using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>How a file came out of an index worker.</summary>
internal enum WorkerEnd
{
    Read,
    Password,
    Damaged,
    TooBig,

    /// <summary>Couldn't be opened just now (someone is writing it, or access is refused): not recorded, tried on a later pass.</summary>
    Unavailable,
}

/// <summary>What a worker may spend on one file.</summary>
internal sealed record IndexLimits(long MaxFileBytes, int MaxPages, long MaxChars);

/// <summary>
/// Reading PDFs for the folder index in another process. Indexing goes through every PDF in a folder by itself, whatever
/// they are, with nobody watching, so a file built to crash MuPDF or to eat memory ends a worker and not the app, and the
/// index is left one file short. A worker is this same program started with <see cref="Switch"/> and a pipe's name (the
/// pattern and handshake of <see cref="FindWorkers"/>): it is told a path, reads the file's pages and sends their text back
/// over the pipe. It writes nothing, shows nothing, runs below normal priority inside a job that limits its memory, and ends
/// when the parent does.
/// </summary>
public static class IndexWorkers
{
    /// <summary>The command-line switch: <c>--index-worker InkvoltPdf.find.&lt;32 hex digits&gt;</c>, nothing else.</summary>
    public const string Switch = "--index-worker";

    private const int AskFile = 1;
    internal const int FramePage = 1, FrameEnd = 2;
    internal const int MaxPathChars = 32_768;

    private static string? _exe;
    private static string[] _args = [];

    /// <summary>Lets indexers start workers as <paramref name="exe"/> (with these arguments before the switch).</summary>
    public static void Use(string exe, params string[] args)
    {
        _exe = exe;
        _args = args;
    }

    internal static (string? Exe, string[] Args) Program => (_exe, _args);

    public static bool IsCommand(string[] args) => args.Length > 0 && args[0] == Switch;

    /// <summary>Test hook (the bench tool sets it, FolderIndexerTests): called with each file before it is read.</summary>
    internal static Action<string>? TestFileFault { get; set; }

    /// <summary>The worker's whole life, from the command line to its exit code.</summary>
    public static int Run(string[] args)
    {
        if (args.Length != 2 || args[0] != Switch || !FindWorkers.IsPipeName(args[1])) return FindWorkers.BadArguments;
        try
        {
            using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.CurrentUserOnly);
            pipe.Connect(10_000);
            FindWorkers.BecomeWorker(pipe);
            try
            {
                Process.GetCurrentProcess().PriorityClass = ProcessPriorityClass.BelowNormal; // what indexing takes, the PC doesn't miss
            }
            catch (Win32Exception) { }
            Serve(pipe);
            return 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return FindWorkers.Failed; // the parent sees the pipe close
        }
    }

    private static void Serve(Stream pipe)
    {
        using var output = new BufferedStream(pipe, 1 << 16);
        while (FindWorkers.ReadInt(pipe) == AskFile)
        {
            var path = FindWorkers.ReadString(pipe, MaxPathChars);
            var limits = new IndexLimits(FindWorkers.ReadLong(pipe), FindWorkers.ReadInt(pipe), FindWorkers.ReadLong(pipe));
            ReadFile(path, limits, output);
            output.Flush();
        }
    }

    /// <summary>Sends each page with text, then how the file ended.</summary>
    private static void ReadFile(string path, IndexLimits limits, Stream output)
    {
        void End(WorkerEnd end, int pages, int failed)
        {
            FindWorkers.WriteInt(output, FrameEnd);
            FindWorkers.WriteInt(output, (int)end);
            FindWorkers.WriteInt(output, pages);
            FindWorkers.WriteInt(output, failed);
        }

        TestFileFault?.Invoke(path);
        byte[] bytes;
        try
        {
            // Not while someone writes it, and not in anyone's way: another program may delete or replace it, and only for this long.
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 1, FileOptions.SequentialScan);
            if (file.Length > limits.MaxFileBytes)
            {
                End(WorkerEnd.TooBig, 0, 0);
                return;
            }
            bytes = new byte[file.Length];
            file.ReadExactly(bytes);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            End(WorkerEnd.Unavailable, 0, 0);
            return;
        }

        PdfEngine engine;
        try
        {
            engine = PdfEngine.Open(bytes, InputFileTypes.PDF, null);
        }
        catch (PasswordRequiredException)
        {
            End(WorkerEnd.Password, 0, 0);
            return;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            End(WorkerEnd.Damaged, 0, 0);
            return;
        }
        using (engine)
        {
            if (engine.PageCount > limits.MaxPages)
            {
                End(WorkerEnd.TooBig, engine.PageCount, 0);
                return;
            }
            var chars = 0L;
            var failed = 0;
            for (var page = 0; page < engine.PageCount; page++)
            {
                string text;
                try
                {
                    text = engine.ReadTextForIndex(page);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    failed++; // a damaged page: the others are worth having
                    continue;
                }
                if (text.Length == 0) continue;
                if (chars + text.Length > limits.MaxChars)
                {
                    End(WorkerEnd.TooBig, engine.PageCount, failed);
                    return;
                }
                chars += text.Length;
                FindWorkers.WriteInt(output, FramePage);
                FindWorkers.WriteInt(output, page);
                FindWorkers.WriteString(output, text);
                output.Flush(); // so the parent sees it is getting somewhere
            }
            End(WorkerEnd.Read, engine.PageCount, failed);
        }
    }

    /// <summary>The parent's end of one worker. A worker reads an untrusted file, so what it says is checked.</summary>
    internal sealed class Link : IDisposable
    {
        private readonly Lock _gate = new();
        private readonly CancellationTokenSource _ended = new();
        private readonly WorkerPipe _pipe;
        private Stream? _input; // a page's answer is several small reads, each a trip to the system on its own
        private Process? _process;
        private int _signs;              // grows with everything the worker says about the file
        private int _reading;            // 1 while a file is being read
        private int _seenSigns;          // for Watch, on the watchdog's thread
        private TimeSpan _quiet;
        private TimeSpan _cpuAtStart;
        private TimeSpan _cpuSeen;       // the worker's processor time when its quiet spell began

        /// <summary>The least processor time that ends a quiet spell (<see cref="Watch"/>).</summary>
        private static readonly TimeSpan MinWork = TimeSpan.FromMilliseconds(50);

        private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;

        /// <summary>A tick in which the worker only waited for its turn on a processor counts this much less toward a stall (<see cref="Watch"/>).</summary>
        private const int StarvedShare = 4;

        private static bool Worked(ProcessThread t)
        {
            try
            {
                return t.TotalProcessorTime >= MinWork;
            }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
            {
                return false; // ended meanwhile
            }
        }

        /// <summary>
        /// Whether one of the worker's working threads is ready to run and waiting for a processor (or running): it wants to
        /// work and the PC hasn't given it a turn. A working thread has done work (its own processor time past
        /// <see cref="MinWork"/>): the runtime's idle helpers of a hung worker wake now and then, and on a busy PC wait for
        /// their turn too. Read only in a quiet spell short of work (a snapshot of the PC's threads).
        /// </summary>
        private static bool WaitsForATurn(Process? process)
        {
            if (process is null) return false;
            try
            {
                process.Refresh();
                foreach (ProcessThread t in process.Threads)
                    if (t.ThreadState is System.Diagnostics.ThreadState.Ready or System.Diagnostics.ThreadState.Running or System.Diagnostics.ThreadState.Standby
                        && Worked(t))
                        return true;
            }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
            {
                // Ended, or its threads can't be read: as quiet as it looks.
            }
            return false;
        }

        /// <summary>Why this link was ended from outside (the watchdog); null: it wasn't.</summary>
        public volatile string? EndedFor;

        public int Files { get; private set; }

        public string? ReadingPath { get; private set; }

        /// <summary>Starts a worker and waits until it has connected.</summary>
        public Link(string exe, IReadOnlyList<string> args, int connectMs)
        {
            var name = FindWorkers.NewPipeName();
            _pipe = FindWorkers.NewPipe(name);
            try
            {
                var process = FindWorkers.StartWithoutHandles(exe, [.. args, Switch, name], Path.GetDirectoryName(exe) ?? "");
                lock (_gate) _process = process;
                FindWorkers.Job.AddLimited(process);
                FindWorkers.AwaitConnection(_pipe, process, connectMs, _ended.Token);
            }
            catch
            {
                Dispose();
                throw;
            }
        }

        /// <summary>
        /// For the watchdog, about every tick of <paramref name="tick"/>: the processor time this file has taken, and how long the worker has said nothing
        /// and done no work (a quarter of that time on the processor) while the PC was awake (a tick it only waited for a turn on one counts a quarter); null while it isn't reading. Not the clock on the wall: at low priority on a busy PC a file may take
        /// a long time without being any trouble, and nothing counts while a laptop sleeps.
        /// </summary>
        public (TimeSpan Cpu, TimeSpan Quiet)? Watch(TimeSpan tick)
        {
            if (Volatile.Read(ref _reading) == 0)
            {
                _quiet = TimeSpan.Zero;
                return null;
            }
            var signs = Volatile.Read(ref _signs);
            Process? process;
            lock (_gate) process = _process;
            TimeSpan? cpu;
            try
            {
                cpu = process?.TotalProcessorTime;
            }
            catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
            {
                cpu = null; // just ended: the read says so
            }
            // Work is a sign of life too: a worker at low priority on a busy PC can go long without a page to say (starting
            // up, a big first page), and isn't stuck while it works. Work, not a tick now and then: a hung worker's runtime
            // threads still take 15 ms at times, so the quiet spell ends only once the worker has used a quarter of it
            // (50 ms at least) on the processor. Short of that, a worker with a thread waiting for its turn (the PC's
            // processors taken by other work: a busy worker given a fifth of one) counts a quarter of the tick: a stuck one's
            // threads wait on nothing the processor gives and count all of it. A starved worker that only ticks still waits
            // for its turns, so it is given up too, at worst four stalls on.
            if (signs != _seenSigns)
            {
                _quiet = TimeSpan.Zero;
                _cpuSeen = cpu ?? _cpuSeen;
            }
            else if (cpu is { } now && now - _cpuSeen >= Max((_quiet + tick) / 4, MinWork)) (_quiet, _cpuSeen) = (TimeSpan.Zero, now);
            else _quiet += WaitsForATurn(process) ? tick / StarvedShare : tick;
            _seenSigns = signs;
            return (cpu is { } used ? used - _cpuAtStart : TimeSpan.Zero, _quiet);
        }

        /// <summary>The worker reads the file; each page with text goes to <paramref name="pages"/> as it comes. Throws when the worker dies or says something wrong.</summary>
        public (WorkerEnd End, int Pages, int Failed) Read(string path, IndexLimits limits, Dictionary<int, string> pages)
        {
            ReadingPath = path;
            lock (_gate) _cpuSeen = _cpuAtStart = _process?.TotalProcessorTime ?? TimeSpan.Zero;
            Interlocked.Increment(ref _signs);
            Volatile.Write(ref _reading, 1);
            try
            {
                using (var ask = new MemoryStream())
                {
                    FindWorkers.WriteInt(ask, AskFile);
                    FindWorkers.WriteString(ask, path);
                    FindWorkers.WriteLong(ask, limits.MaxFileBytes);
                    FindWorkers.WriteInt(ask, limits.MaxPages);
                    FindWorkers.WriteLong(ask, limits.MaxChars);
                    _pipe.Write(ask.GetBuffer().AsSpan(0, (int)ask.Length));
                    _pipe.Flush();
                }
                var input = _input ??= new BufferedStream(_pipe, 1 << 16);
                var chars = 0L;
                var last = -1;
                while (true)
                {
                    var frame = FindWorkers.ReadInt(input);
                    Interlocked.Increment(ref _signs);
                    if (frame == FramePage)
                    {
                        var page = FindWorkers.ReadInt(input);
                        if (page <= last || page >= limits.MaxPages) throw new InvalidDataException("A page out of order.");
                        var left = limits.MaxChars - chars;
                        var text = FindWorkers.ReadString(input, (int)Math.Min(left, int.MaxValue));
                        chars += text.Length;
                        pages[page] = text;
                        last = page;
                        Interlocked.Increment(ref _signs);
                    }
                    else if (frame == FrameEnd)
                    {
                        var end = (WorkerEnd)FindWorkers.ReadInt(input);
                        var count = FindWorkers.ReadInt(input);
                        var failed = FindWorkers.ReadInt(input);
                        if (end is < WorkerEnd.Read or > WorkerEnd.Unavailable || count < 0 || failed < 0 || failed > count || last >= count && pages.Count > 0)
                            throw new InvalidDataException("Not an end of a file.");
                        Files++;
                        return (end, count, failed);
                    }
                    else throw new InvalidDataException("Not a worker's answer.");
                }
            }
            finally
            {
                Volatile.Write(ref _reading, 0);
                ReadingPath = null;
            }
        }

        /// <summary>Ends the worker now, saying why; a read under way then throws, as the pipe breaks.</summary>
        public void EndFor(string why)
        {
            EndedFor ??= why;
            Kill();
        }

        private void Kill()
        {
            _ended.Cancel();
            lock (_gate)
            {
                try
                {
                    _process?.Kill();
                }
                catch (Exception ex) when (ex is InvalidOperationException or Win32Exception) { }
            }
        }

        public void Dispose()
        {
            Kill();
            lock (_gate)
            {
                _process?.Dispose();
                _process = null;
            }
            _pipe.Dispose();
        }
    }
}
