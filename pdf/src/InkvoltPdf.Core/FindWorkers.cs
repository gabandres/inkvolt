using System.Buffers.Binary;
using System.ComponentModel;
using System.Diagnostics;
using System.IO.MemoryMappedFiles;
using System.IO.Pipes;
using System.Runtime;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>How a search may use find workers: what to start and when it pays. Tests set their own on an engine.</summary>
/// <param name="Exe">The program to start: the app itself, with <see cref="FindWorkers.Switch"/> and the pipe's name.</param>
/// <param name="Args">Arguments before the switch (a dotnet host's dll).</param>
/// <param name="Workers">How many at most.</param>
internal sealed record FindWorkerPlan(string Exe, IReadOnlyList<string> Args, int Workers)
{
    /// <summary>
    /// Workers start once the search's pace says more than this is left, about 1,000 pages of a text. Measured on the busy
    /// Snapdragon X: they are reading some 400 ms after they are asked for, so a search with a second left (the bench's
    /// 250-page file) ends no sooner with them, while it takes eight more processes.
    /// </summary>
    public double PaysMs { get; init; } = 2000;

    /// <summary>The pace is read after this long at the earliest: the first page's time is mostly opening the document again.</summary>
    public double ProbeMs { get; init; } = 200;

    /// <summary>A search this far from its end by its pace gets all the workers; a shorter one, proportionally fewer (at least two).</summary>
    public double FullCrewMs { get; init; } = 4000;

    /// <summary>Fewer pages left than this never start workers, however slow each one is.</summary>
    public int MinPages { get; init; } = 16;

    /// <summary>Pages read ahead of the caller while workers read: more than in process, as there are more readers.</summary>
    public int ReadAhead { get; init; } = 256;

    /// <summary>How long a worker has to start and connect.</summary>
    public int ConnectMs { get; init; } = 15_000;

    /// <summary>A worker that answers nothing for this long is ended and its pages read in process (a page that takes longer than this is very rare).</summary>
    public int StallMs { get; init; } = 120_000;

    /// <summary>Tests: the search's own threads leave the pages to the workers from the start, until they connect or fail.</summary>
    public bool InProcessWaits { get; init; }
}

/// <summary>What the workers of the last search did: for the bench, the dev script and the tests.</summary>
/// <param name="Started">Processes started.</param>
/// <param name="Failed">Those that failed, couldn't start or were killed before the end; their pages were read in process.</param>
/// <param name="PagesFromWorkers">Pages they read.</param>
/// <param name="PeakBytes">Their peak working sets added up (an upper bound: what they share counts once for each).</param>
public sealed record FindWorkerStats(int Started, int Failed, int PagesFromWorkers, long PeakBytes);

/// <summary>
/// Reading a long document's text for Find in other processes. MuPDFCore's native wrapper serializes MuPDF's allocations
/// with process-wide mutexes, so threads can't speed it up, while processes scale with the cores. A worker is this same
/// program started with <see cref="Switch"/> and a pipe's name; it opens the document as the parent says, reads the pages
/// asked for and sends each one's text and hits back. It writes nothing and shows nothing, and ends when the parent does.
/// </summary>
public static class FindWorkers
{
    /// <summary>The command-line switch: <c>--find-worker InkvoltPdf.find.&lt;32 hex digits&gt;</c>, nothing else.</summary>
    public const string Switch = "--find-worker";

    /// <summary>Exit code: the arguments aren't a switch and a pipe name of ours. Nothing was touched.</summary>
    public const int BadArguments = 2;

    /// <summary>Exit code: no parent there, or the work failed. The parent reads the pages itself.</summary>
    public const int Failed = 1;

    private const string PipePrefix = "InkvoltPdf.find.";
    private const int PipeHexDigits = 32;
    private const int MaxCount = 8;                       // a long text gains nothing past 6 and the drawing set little past 8: tools/bench/RESULTS.md
    private const long MemoryBudget = 1200L * 1048576;    // the 1.5 GB target, less what the app itself holds
    private const long WorkerBytes = 100L * 1048576;      // measured peak of a worker: 77 MB on the long text, 56 MB on the drawing set

    private static readonly Lock Gate = new();
    private static string? _exe;
    private static string[] _args = [];
    private static int _running;

    /// <summary>Lets searches use workers from now on, started as <paramref name="exe"/> (with these arguments before the switch).</summary>
    public static void Use(string exe, params string[] args)
    {
        _exe = exe;
        _args = args;
    }

    public static bool IsCommand(string[] args) => args.Length > 0 && args[0] == Switch;

    /// <summary>
    /// How many workers to start: two cores stay free for the app and everything else, at most <see cref="MaxCount"/>,
    /// and together they may take half the free memory, up to the budget (less the document's one shared copy). One
    /// worker isn't worth it: the search's two threads do as well.
    /// </summary>
    internal static int CountFor(int cores, long availableBytes, long sharedBytes)
    {
        var budget = Math.Min(availableBytes / 2, MemoryBudget) - sharedBytes;
        var count = (int)Math.Min(Math.Clamp(cores - 2, 0, MaxCount), Math.Max(0, budget) / WorkerBytes);
        return count < 2 ? 0 : count;
    }

    /// <summary>The plan for a search of a document whose bytes in memory are <paramref name="sharedBytes"/>; null when workers aren't on or wouldn't pay.</summary>
    internal static FindWorkerPlan? PlanFor(long sharedBytes)
    {
        if (_exe is not { } exe) return null;
        var status = new MemoryStatus { Length = (uint)Marshal.SizeOf<MemoryStatus>() };
        var available = GlobalMemoryStatusEx(ref status) ? (long)status.AvailablePhysical : 0;
        var count = CountFor(Environment.ProcessorCount, available, sharedBytes);
        return count == 0 ? null : new FindWorkerPlan(exe, _args, count);
    }

    /// <summary>Takes up to <paramref name="want"/> workers, <paramref name="most"/> at most in this process: several tabs searching at once share them.</summary>
    internal static int Reserve(int want, int most)
    {
        lock (Gate)
        {
            var granted = Math.Clamp(most - _running, 0, want);
            _running += granted;
            return granted;
        }
    }

    internal static void Release(int count)
    {
        lock (Gate) _running -= count;
    }

    internal static string NewPipeName() => PipePrefix + Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(PipeHexDigits / 2));

    internal static bool IsPipeName(string name)
    {
        if (name.Length != PipePrefix.Length + PipeHexDigits || !name.StartsWith(PipePrefix, StringComparison.Ordinal)) return false;
        foreach (var c in name.AsSpan(PipePrefix.Length))
            if (!char.IsAsciiHexDigitLower(c)) return false;
        return true;
    }

    /// <summary>The worker's whole life, from the command line to its exit code.</summary>
    public static int Run(string[] args) => Run(args, 10_000);

    internal static int Run(string[] args, int connectMs)
    {
        if (args.Length != 2 || args[0] != Switch || !IsPipeName(args[1])) return BadArguments;
        try
        {
            using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.CurrentUserOnly);
            pipe.Connect(connectMs);
            BecomeWorker(pipe);
            Serve(pipe);
            return 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return Failed; // the parent sees the pipe close: no message for anyone, and no file or log touched
        }
    }

    /// <summary>Ends this process with its parent, whatever it is doing (the pipe's server is the parent: the system says who that is).</summary>
    private static void WatchParent(NamedPipeClientStream pipe)
    {
        if (!GetNamedPipeServerProcessId(pipe.SafePipeHandle, out var parent)) throw new Win32Exception();
        var process = Process.GetProcessById((int)parent);
        var watch = new Thread(() =>
        {
            process.WaitForExit();
            Process.GetCurrentProcess().Kill();
        }) { IsBackground = true, Name = "Inkvolt PDF parent watch" };
        watch.Start();
    }

    /// <summary>Test hook: <see cref="PdfEngine.PageFault"/> for this worker's engine (the bench tool sets it, FindWorkerTests).</summary>
    internal static Action<int>? TestPageFault { get; set; }

    private static void Serve(Stream pipe)
    {
        using var output = new BufferedStream(pipe, 1 << 16);
        var open = OpenRequest.Read(pipe);
        var engine = open.OpenEngine(out var view);
        try
        {
            engine.PageFault = TestPageFault;
            if (engine.PageCount != open.Pages) return;
            WriteInt(output, ReadyWord);
            output.Flush();
            engine.ServeFind(pipe, output, open);
        }
        finally
        {
            engine.Dispose();
            view?.Dispose();
        }
    }

    internal const int ReadyWord = 0x4B4E4946; // "FINK": the document opened as the parent's did

    /// <summary>What a worker is told once, over the pipe: the document, the search, and how much whole text is still wanted.</summary>
    internal sealed record OpenRequest(string? Path, string? SectionName, long SectionBytes, InputFileTypes Type, int Pages,
        string Query, bool MatchCase, bool WholeWord, bool IgnoreAccents, long KeepChars)
    {
        public void Write(Stream s)
        {
            WriteString(s, Path ?? "");
            WriteString(s, SectionName ?? "");
            WriteLong(s, SectionBytes);
            WriteInt(s, (int)Type);
            WriteInt(s, Pages);
            WriteString(s, Query);
            WriteInt(s, (MatchCase ? 1 : 0) | (WholeWord ? 2 : 0) | (IgnoreAccents ? 4 : 0));
            WriteLong(s, KeepChars);
        }

        public static OpenRequest Read(Stream s)
        {
            var path = ReadString(s, 32_768);
            var section = ReadString(s, 256);
            var bytes = ReadLong(s);
            var type = (InputFileTypes)ReadInt(s);
            var pages = ReadInt(s);
            var query = ReadString(s, 1 << 20);
            var flags = ReadInt(s);
            var keep = ReadLong(s);
            if (path.Length == 0 == (section.Length == 0)) throw new InvalidDataException("One document, by path or in shared memory.");
            if (section.Length > 0 && (!IsPipeName(section) || bytes <= 0)) throw new InvalidDataException("Not a section of ours.");
            if (type != InputFileTypes.PDF || pages <= 0) throw new InvalidDataException("Not a search of a PDF.");
            return new OpenRequest(path.Length > 0 ? path : null, section.Length > 0 ? section : null, bytes, type, pages, query, (flags & 1) != 0, (flags & 2) != 0, (flags & 4) != 0, keep);
        }

        /// <summary>Opens the document as the parent has it: its file, or the copy of its bytes it shares (read-only, in memory).</summary>
        public PdfEngine OpenEngine(out IDisposable? view)
        {
            view = null;
            if (Path is { } path) return PdfEngine.OpenFile(path, Type, null);
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            var shared = new SharedView(SectionName!, SectionBytes);
            view = shared;
            return PdfEngine.OpenMemory(shared.Pointer, SectionBytes, Type);
        }
    }

    /// <summary>A worker's read-only view of the document's bytes in the parent's section.</summary>
    [System.Runtime.Versioning.SupportedOSPlatform("windows")]
    private sealed unsafe class SharedView : IDisposable
    {
        private readonly MemoryMappedFile _file;
        private readonly MemoryMappedViewAccessor _view;
        public IntPtr Pointer { get; }

        public SharedView(string name, long bytes)
        {
            _file = MemoryMappedFile.OpenExisting(name, MemoryMappedFileRights.Read);
            _view = _file.CreateViewAccessor(0, bytes, MemoryMappedFileAccess.Read);
            byte* p = null;
            _view.SafeMemoryMappedViewHandle.AcquirePointer(ref p);
            Pointer = (IntPtr)(p + _view.PointerOffset);
        }

        public void Dispose()
        {
            _view.SafeMemoryMappedViewHandle.ReleasePointer();
            _view.Dispose();
            _file.Dispose();
        }
    }

    /// <summary>The command line of a program started by hand, as Windows' C runtime splits it again (nothing else reads it).</summary>
    internal static string CommandLine(string exe, IEnumerable<string> args)
    {
        var line = new System.Text.StringBuilder();
        foreach (var arg in args.Prepend(exe))
        {
            if (line.Length > 0) line.Append(' ');
            if (arg.Length > 0 && arg.AsSpan().IndexOfAny(' ', '\t', '"') < 0)
            {
                line.Append(arg);
                continue;
            }
            line.Append('"');
            var slashes = 0;
            foreach (var c in arg)
            {
                if (c == '\\')
                {
                    slashes++;
                    continue;
                }
                line.Append('\\', c == '"' ? slashes * 2 + 1 : slashes).Append(c);
                slashes = 0;
            }
            line.Append('\\', slashes * 2).Append('"');
        }
        return line.ToString();
    }

    /// <summary>
    /// Starts a worker that inherits no handle: Process.Start always passes on the inheritable ones, and MuPDF's for files
    /// open in place are, so a worker on one tab's search would keep another tab's file from being saved over. It needs none:
    /// its pipe and its document's bytes go by name. Held suspended until this process has hold of it, so it can't end first.
    /// </summary>
    internal static Process StartWithoutHandles(string exe, IEnumerable<string> args, string directory)
    {
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        if (!CreateProcess(null, new System.Text.StringBuilder(CommandLine(exe, args)), IntPtr.Zero, IntPtr.Zero, false, CreateNoWindow | CreateSuspended, IntPtr.Zero, directory, ref startup, out var info))
            throw new Win32Exception();
        try
        {
            var process = Process.GetProcessById(info.ProcessId);
            _ = process.Handle; // held from here on, whenever it ends
            if (ResumeThread(info.Thread) == uint.MaxValue)
            {
                var error = new Win32Exception();
                process.Kill();
                process.Dispose();
                throw error;
            }
            return process;
        }
        catch (ArgumentException)
        {
            throw new InvalidOperationException("The worker didn't start.");
        }
        finally
        {
            CloseHandle(info.Thread);
            CloseHandle(info.Process);
        }
    }

    /// <summary>Ends every worker with this process, even if it crashes: they all belong to a job that dies with its handle.</summary>
    internal static class Job
    {
        private static readonly Lazy<IntPtr> Handle = new(() => Create(0));
        private static readonly Lazy<IntPtr> Limited = new(() => Create(LimitedBytes));

        /// <summary>What a process reading untrusted files for the index may hold: over this it fails, the app doesn't.</summary>
        private const long LimitedBytes = 2048L * 1048576;

        /// <summary>False if it couldn't be done (the worker's parent watch still ends it).</summary>
        public static bool Add(Process process) => Handle.Value != IntPtr.Zero && AssignProcessToJobObject(Handle.Value, process.Handle);

        /// <summary><see cref="Add"/>, with a limit to the process's memory: a file built to make a reader take it all stops at that.</summary>
        public static bool AddLimited(Process process) => Limited.Value != IntPtr.Zero && AssignProcessToJobObject(Limited.Value, process.Handle);

        private static IntPtr Create(long processBytes)
        {
            var job = CreateJobObject(IntPtr.Zero, null);
            if (job == IntPtr.Zero) return job;
            var limits = new ExtendedLimits { Basic = new BasicLimits { LimitFlags = JobKillOnClose | (processBytes > 0 ? JobLimitProcessMemory : 0) }, ProcessMemoryLimit = (nuint)processBytes };
            return SetInformationJobObject(job, JobExtendedLimitInformation, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>()) ? job : IntPtr.Zero;
        }
    }

    /// <summary>A pipe only this user's processes may open, and only this one instance under this name.</summary>
    internal static NamedPipeServerStream NewPipe(string name) =>
        new(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | PipeOptions.FirstPipeInstance, 1 << 16, 1 << 18);

    /// <summary>Waits for <paramref name="process"/> to open <paramref name="pipe"/>, and makes sure it is the one that did.</summary>
    internal static void AwaitConnection(NamedPipeServerStream pipe, Process process, int connectMs, CancellationToken ended)
    {
        using var waiting = CancellationTokenSource.CreateLinkedTokenSource(ended);
        waiting.CancelAfter(connectMs);
        var connect = pipe.WaitForConnectionAsync(waiting.Token);
        _ = connect.ContinueWith(t => t.Exception, TaskContinuationOptions.OnlyOnFaulted); // observed, should it fail after the wait
        Task.WhenAny(connect, process.WaitForExitAsync(waiting.Token)).GetAwaiter().GetResult();
        if (!connect.IsCompletedSuccessfully) throw new InvalidOperationException("The worker didn't connect.");
        // Whoever got in must be the process just started.
        if (!GetNamedPipeClientProcessId(pipe.SafePipeHandle, out var client)) throw new Win32Exception();
        if (client != process.Id) throw new InvalidOperationException("Another process answered the pipe.");
    }

    /// <summary>What every worker does once it has its pipe: no box for a crash, batch-friendly memory, and it ends with the parent.</summary>
    internal static void BecomeWorker(NamedPipeClientStream pipe)
    {
        // No "stopped working" box for a page that crashes MuPDF: the parent reads it in its place.
        SetErrorMode(SemFailCriticalErrors | SemNoGpFaultErrorBox);
        GCSettings.LatencyMode = GCLatencyMode.Batch;
        WatchParent(pipe);
    }

    internal static void WriteInt(Stream s, int value)
    {
        Span<byte> b = stackalloc byte[4];
        BinaryPrimitives.WriteInt32LittleEndian(b, value);
        s.Write(b);
    }

    internal static int ReadInt(Stream s)
    {
        Span<byte> b = stackalloc byte[4];
        s.ReadExactly(b);
        return BinaryPrimitives.ReadInt32LittleEndian(b);
    }

    internal static void WriteLong(Stream s, long value)
    {
        Span<byte> b = stackalloc byte[8];
        BinaryPrimitives.WriteInt64LittleEndian(b, value);
        s.Write(b);
    }

    internal static long ReadLong(Stream s)
    {
        Span<byte> b = stackalloc byte[8];
        s.ReadExactly(b);
        return BinaryPrimitives.ReadInt64LittleEndian(b);
    }

    /// <summary>A string as it is in memory (UTF-16): whatever a PDF's text holds, even half a surrogate pair, comes back the same.</summary>
    internal static void WriteString(Stream s, string value)
    {
        WriteInt(s, value.Length);
        s.Write(MemoryMarshal.AsBytes(value.AsSpan()));
    }

    internal static string ReadString(Stream s, int maxChars)
    {
        var length = ReadInt(s);
        if (length < 0 || length > maxChars) throw new InvalidDataException($"A string of {length} characters.");
        return string.Create(length, s, static (chars, stream) => stream.ReadExactly(MemoryMarshal.AsBytes(chars)));
    }

    private const uint SemFailCriticalErrors = 1, SemNoGpFaultErrorBox = 2;
    private const uint JobKillOnClose = 0x2000, JobLimitProcessMemory = 0x100;
    private const int JobExtendedLimitInformation = 9;
    private const uint CreateNoWindow = 0x08000000, CreateSuspended = 4;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size;
        public string? Reserved, Desktop, Title;
        public int X, Y, Width, Height, CountChars, CountLines, FillAttribute, Flags;
        public short ShowWindow, Reserved2;
        public IntPtr Reserved3, StdInput, StdOutput, StdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ProcessInformation
    {
        public IntPtr Process, Thread;
        public int ProcessId, ThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long PerProcessUserTimeLimit, PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize, MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass, SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        public nuint ProcessMemoryLimit, JobMemoryLimit, PeakProcessMemoryUsed, PeakJobMemoryUsed;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryStatus
    {
        public uint Length, MemoryLoad;
        public ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile, TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryStatus status);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CreateJobObject(IntPtr attributes, string? name);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetInformationJobObject(IntPtr job, int infoClass, ref ExtendedLimits info, uint size);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, EntryPoint = "CreateProcessW")]
    private static extern bool CreateProcess(string? application, System.Text.StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
        bool inheritHandles, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInformation info);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint ResumeThread(IntPtr thread);

    [DllImport("kernel32.dll")]
    private static extern bool CloseHandle(IntPtr handle);

    [DllImport("kernel32.dll")]
    private static extern uint SetErrorMode(uint mode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeServerProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint process);

    [DllImport("kernel32.dll", SetLastError = true)]
    internal static extern bool GetNamedPipeClientProcessId(Microsoft.Win32.SafeHandles.SafePipeHandle pipe, out uint process);
}
