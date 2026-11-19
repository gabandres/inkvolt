using System.Diagnostics;
using System.Runtime.InteropServices;

namespace InkvoltPdf.Core;

/// <summary>A program that didn't finish as it should: too slow, too much output, or it failed.</summary>
public sealed class BoundedProcessException(string message, Exception? inner = null, bool timedOut = false) : Exception(message, inner)
{
    /// <summary>It was stopped for taking longer than it may.</summary>
    public bool TimedOut { get; } = timedOut;
}

/// <summary>
/// Runs a program Inkvolt doesn't trust (the downloaded tesseract.exe): its input given on stdin, its output read from
/// stdout up to a limit, no window, no shell. Too slow, too much output or Cancel: the program and what it started are
/// killed. On Windows it runs in a job that ends it when Inkvolt ends (closed, or crashed) and holds it to
/// <see cref="MaxMemory"/>. Its error text is kept short, for the log only.
/// </summary>
public static partial class BoundedProcess
{
    private const int MaxErrors = 16 * 1024;

    /// <summary>The memory a program may commit (Tesseract reads a 300 dpi page in a few hundred MB).</summary>
    public const long MaxMemory = 3L << 30;

    public sealed record Result(int ExitCode, byte[] Output, string Errors);

    /// <param name="start">The program and its arguments (<see cref="ProcessStartInfo.ArgumentList"/>); the redirections are set here.</param>
    /// <param name="maxOutput">More stdout than this kills it.</param>
    public static Result Run(ProcessStartInfo start, byte[] input, int maxOutput, TimeSpan timeout, CancellationToken cancel = default)
    {
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardInput = start.RedirectStandardOutput = start.RedirectStandardError = true;
        using var process = new Process { StartInfo = start };
        try
        {
            process.Start();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            throw new BoundedProcessException($"{Path.GetFileName(start.FileName)} didn't start: {ex.Message}", ex);
        }
        Confine(process);
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(cancel);
        limit.CancelAfter(timeout);
        var tooMuch = false;
        try
        {
            var write = Task.Run(async () =>
            {
                try
                {
                    await process.StandardInput.BaseStream.WriteAsync(input, limit.Token).ConfigureAwait(false);
                    process.StandardInput.Close();
                }
                catch (IOException)
                {
                    // it stopped reading (it ended, or failed): its exit code says which
                }
            });
            var read = Task.Run(async () =>
            {
                using var output = new MemoryStream();
                var buffer = new byte[1 << 16];
                int n;
                while ((n = await process.StandardOutput.BaseStream.ReadAsync(buffer, limit.Token).ConfigureAwait(false)) > 0)
                {
                    if (output.Length + n > maxOutput)
                    {
                        tooMuch = true;
                        await limit.CancelAsync().ConfigureAwait(false);
                        break;
                    }
                    output.Write(buffer, 0, n);
                }
                return output.ToArray();
            });
            var errors = Task.Run(async () =>
            {
                var text = new System.Text.StringBuilder();
                var buffer = new char[4096];
                int n;
                while ((n = await process.StandardError.ReadAsync(buffer, limit.Token).ConfigureAwait(false)) > 0)
                    if (text.Length < MaxErrors) text.Append(buffer, 0, Math.Min(n, MaxErrors - text.Length));
                return text.ToString();
            });
            process.WaitForExitAsync(limit.Token).GetAwaiter().GetResult();
            Task.WaitAll([write, read, errors], limit.Token);
            if (tooMuch) throw new BoundedProcessException($"{Path.GetFileName(start.FileName)} wrote more than {maxOutput} bytes.");
            return new Result(process.ExitCode, read.Result, errors.Result);
        }
        catch (Exception ex) when (ex is OperationCanceledException || (ex is AggregateException a && a.InnerExceptions.All(e => e is OperationCanceledException)))
        {
            Kill(process);
            cancel.ThrowIfCancellationRequested();
            throw new BoundedProcessException(tooMuch
                ? $"{Path.GetFileName(start.FileName)} wrote more than {maxOutput} bytes."
                : $"{Path.GetFileName(start.FileName)} took longer than {timeout.TotalSeconds:0} s.", ex, timedOut: !tooMuch);
        }
        catch
        {
            Kill(process);
            throw;
        }
    }

    private static readonly Lazy<nint> Job = new(CreateJob);

    /// <summary>Puts the program in the job (best effort: where jobs can't be made, the time limit and Cancel still end it).</summary>
    private static void Confine(Process process)
    {
        if (!OperatingSystem.IsWindows() || Job.Value == 0) return;
        try
        {
            AssignProcessToJobObject(Job.Value, process.Handle);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            // it already ended
        }
    }

    /// <summary>One job for every program run here: killed when its last handle (Inkvolt's) closes, each process held to <see cref="MaxMemory"/>.</summary>
    private static nint CreateJob()
    {
        if (!OperatingSystem.IsWindows()) return 0;
        var job = CreateJobObjectW(0, null);
        if (job == 0) return 0;
        var info = new ExtendedLimits
        {
            Basic = new BasicLimits { LimitFlags = KillOnJobClose | ProcessMemory },
            ProcessMemoryLimit = (nuint)MaxMemory,
        };
        if (!SetInformationJobObject(job, ExtendedLimitInformation, ref info, (uint)Marshal.SizeOf<ExtendedLimits>()))
        {
            CloseHandle(job);
            return 0;
        }
        return job;
    }

    private const uint KillOnJobClose = 0x2000;
    private const uint ProcessMemory = 0x100;
    private const int ExtendedLimitInformation = 9;

    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public nuint MinimumWorkingSetSize;
        public nuint MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public nuint Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    {
        public BasicLimits Basic;
        public ulong ReadOperationCount, WriteOperationCount, OtherOperationCount, ReadTransferCount, WriteTransferCount, OtherTransferCount;
        public nuint ProcessMemoryLimit;
        public nuint JobMemoryLimit;
        public nuint PeakProcessMemoryUsed;
        public nuint PeakJobMemoryUsed;
    }

    [LibraryImport("kernel32.dll", SetLastError = true, StringMarshalling = StringMarshalling.Utf16)]
    private static partial nint CreateJobObjectW(nint attributes, string? name);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool SetInformationJobObject(nint job, int infoClass, ref ExtendedLimits info, uint length);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool AssignProcessToJobObject(nint job, nint process);

    [LibraryImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseHandle(nint handle);

    private static void Kill(Process process)
    {
        try
        {
            if (!process.HasExited) process.Kill(entireProcessTree: true);
            process.WaitForExit(5000);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException)
        {
            // already gone
        }
    }
}
