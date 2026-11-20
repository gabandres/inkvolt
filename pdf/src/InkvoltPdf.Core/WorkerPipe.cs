using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPdf.Core;

/// <summary>
/// This process's end of a worker's pipe (find, page checks, the folder index), connected, read and written without the
/// thread pool. A pipe opened for overlapped use, which a wait for a worker's connection needs, has .NET finish even a
/// blocking read on a pool thread: with the pool busy (renders' Parallel.For, a test run's other tests), a worker's answer
/// sat unread for minutes, so the index took a worker for stuck and a page's check came back too slow. Here each wait is
/// on an event of its own, and the system is told not to post the operation's end to the pool's completion port (the
/// event's low bit set, ReadFile's documented way). One read and one write may be under way at once, from two threads.
/// </summary>
internal sealed unsafe class WorkerPipe : Stream
{
    private readonly NamedPipeServerStream _pipe;
    private readonly Op _read = new(), _write = new();
    private int _disposed;

    /// <summary>A pipe only this user's processes may open, and only this one instance under this name, not yet connected.</summary>
    public WorkerPipe(string name) =>
        _pipe = new(name, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly | PipeOptions.FirstPipeInstance, 1 << 16, 1 << 18);

    /// <summary>One operation's overlapped structure and event, which must outlive it: freed only once none is under way.</summary>
    private sealed class Op
    {
        public readonly Lock Gate = new();
        public readonly ManualResetEvent Done = new(false);
        public IoBlock* Overlapped = (IoBlock*)NativeMemory.AllocZeroed((nuint)sizeof(IoBlock));
        public bool Busy, Freed, FreeWhenDone;

        public void Free()
        {
            if (Freed) return;
            Freed = true;
            NativeMemory.Free(Overlapped);
            Overlapped = null;
            Done.Dispose();
        }
    }

    /// <summary>
    /// Waits for <paramref name="process"/> to open the pipe, for <paramref name="connectMs"/> at most, until it ends or
    /// <paramref name="ended"/> is cancelled, and makes sure it is the one that did.
    /// </summary>
    /// <exception cref="InvalidOperationException">It didn't connect, or another process did.</exception>
    public void Connect(Process process, int connectMs, CancellationToken ended)
    {
        using var exited = new HandleWait(process.Handle);
        Run(_read, null, 0, Kind.Connect, connectMs, [exited, ended.WaitHandle]);
        // Whoever got in must be the process just started.
        if (!GetNamedPipeClientProcessId(_pipe.SafePipeHandle, out var client)) throw new Win32Exception();
        if (client != process.Id) throw new InvalidOperationException("Another process answered the pipe.");
    }

    /// <summary>Fills <paramref name="buffer"/> within <paramref name="limit"/> in all.</summary>
    /// <exception cref="TimeoutException">It didn't all come in time.</exception>
    /// <exception cref="EndOfStreamException">The worker closed its end first.</exception>
    public void ReadExactly(Span<byte> buffer, TimeSpan limit)
    {
        var since = Stopwatch.GetTimestamp();
        while (buffer.Length > 0)
        {
            var left = limit - Stopwatch.GetElapsedTime(since);
            if (left <= TimeSpan.Zero) throw new TimeoutException();
            var n = Read(buffer, (int)Math.Min(left.TotalMilliseconds + 1, int.MaxValue));
            if (n == 0) throw new EndOfStreamException();
            buffer = buffer[n..];
        }
    }

    public override int Read(Span<byte> buffer) => Read(buffer, Timeout.Infinite);

    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count), Timeout.Infinite);

    private int Read(Span<byte> buffer, int ms)
    {
        if (buffer.IsEmpty) return 0;
        fixed (byte* p = buffer) return Run(_read, p, buffer.Length, Kind.Read, ms, []);
    }

    public override void Write(ReadOnlySpan<byte> buffer)
    {
        while (!buffer.IsEmpty)
        {
            int n;
            fixed (byte* p = buffer) n = Run(_write, p, buffer.Length, Kind.Write, Timeout.Infinite, []);
            buffer = buffer[n..];
        }
    }

    public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));

    private enum Kind { Connect, Read, Write }

    /// <summary>
    /// One operation, waited for on its own event (and <paramref name="also"/>: any of them set ends the wait as a timeout
    /// does); an operation given up is cancelled and waited for, so the buffer is free when this returns. A read of a pipe
    /// the worker closed gives 0.
    /// </summary>
    private int Run(Op op, byte* buffer, int count, Kind kind, int ms, WaitHandle[] also)
    {
        lock (op.Gate)
        {
            ObjectDisposedException.ThrowIf(op.Freed || Volatile.Read(ref _disposed) != 0, this);
            op.Busy = true;
        }
        SafePipeHandle? handle = null;
        var added = false;
        try
        {
            handle = _pipe.SafePipeHandle; // inside: a Dispose meanwhile throws here, and Busy is still undone
            handle.DangerousAddRef(ref added);
            var h = handle.DangerousGetHandle();
            op.Done.Reset();
            *op.Overlapped = default;
            op.Overlapped->Event = op.Done.SafeWaitHandle.DangerousGetHandle() | 1; // no completion packet for the pool
            var ok = kind switch
            {
                Kind.Connect => ConnectNamedPipe(h, op.Overlapped),
                Kind.Read => ReadFile(h, buffer, count, IntPtr.Zero, op.Overlapped),
                _ => WriteFile(h, buffer, count, IntPtr.Zero, op.Overlapped),
            };
            if (!ok)
            {
                var error = Marshal.GetLastPInvokeError();
                if (kind == Kind.Connect && error == ErrorPipeConnected) return 0;
                if (error != ErrorIoPending) return Failed(kind, error);
                // Closed while this started: Dispose's cancel may have come first and missed it.
                if (Volatile.Read(ref _disposed) != 0) CancelIoEx(h, op.Overlapped);
                var signalled = WaitHandle.WaitAny([op.Done, .. also], ms);
                if (signalled != 0)
                {
                    CancelIoEx(h, op.Overlapped);
                    op.Done.WaitOne(); // ended (cancelled, or done just now): the buffer is ours again
                    if (!GetOverlappedResult(h, op.Overlapped, out _, false) || kind == Kind.Connect)
                        throw kind == Kind.Connect ? new InvalidOperationException("The worker didn't connect.") : new TimeoutException();
                    // Done just as the wait ended: what it did counts.
                }
            }
            if (!GetOverlappedResult(h, op.Overlapped, out var done, false)) return Failed(kind, Marshal.GetLastPInvokeError());
            return done;
        }
        finally
        {
            if (added) handle!.DangerousRelease();
            lock (op.Gate)
            {
                op.Busy = false;
                if (op.FreeWhenDone) op.Free();
            }
        }
    }

    private static int Failed(Kind kind, int error)
    {
        if (kind == Kind.Read && error is ErrorBrokenPipe or ErrorPipeNotConnected or ErrorNoData) return 0; // the worker closed its end
        if (kind == Kind.Connect) throw new InvalidOperationException("The worker didn't connect.");
        throw new IOException(new Win32Exception(error).Message, error);
    }

    public override void Flush() { } // nothing is kept here: each write is the system's at once

    /// <summary>Ends whatever is under way (a read waiting on a worker ended or never answering) and closes the pipe.</summary>
    protected override void Dispose(bool disposing)
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
        if (disposing)
        {
            try
            {
                var handle = _pipe.SafePipeHandle;
                if (!handle.IsClosed && !handle.IsInvalid) CancelIoEx(handle.DangerousGetHandle(), null);
            }
            catch (ObjectDisposedException) { }
            _pipe.Dispose();
            foreach (var op in (Op[])[_read, _write])
                lock (op.Gate)
                {
                    if (op.Busy) op.FreeWhenDone = true;
                    else op.Free();
                }
        }
        base.Dispose(disposing);
    }

    public override bool CanRead => true;
    public override bool CanWrite => true;
    public override bool CanSeek => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    /// <summary>A handle this class doesn't own (a process's), waited on as any wait handle.</summary>
    private sealed class HandleWait : WaitHandle
    {
        public HandleWait(IntPtr handle) => SafeWaitHandle = new SafeWaitHandle(handle, ownsHandle: false);
    }

    /// <summary>The system's OVERLAPPED: where an operation stands, and the event set when it ends.</summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct IoBlock
    {
        public IntPtr Internal, InternalHigh;
        public int Offset, OffsetHigh;
        public IntPtr Event;
    }

    private const int ErrorBrokenPipe = 109, ErrorNoData = 232, ErrorPipeNotConnected = 233, ErrorPipeConnected = 535, ErrorIoPending = 997;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ConnectNamedPipe(IntPtr pipe, IoBlock* overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool ReadFile(IntPtr file, byte* buffer, int count, IntPtr read, IoBlock* overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(IntPtr file, byte* buffer, int count, IntPtr written, IoBlock* overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetOverlappedResult(IntPtr file, IoBlock* overlapped, out int transferred, bool wait);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CancelIoEx(IntPtr file, IoBlock* overlapped);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetNamedPipeClientProcessId(SafePipeHandle pipe, out uint clientProcessId);
}
