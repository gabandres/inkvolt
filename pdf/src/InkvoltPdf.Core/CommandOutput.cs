using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPdf.Core;

/// <summary>
/// The command line's output when MuPDF's own messages are kept out of it. MuPDF's <c>RedirectOutput</c> moves the process's
/// standard output and error onto pipes of its own (the C runtime's <c>dup2</c>, which closes the handles .NET wrote to) and
/// sets <see cref="Console.Out"/> and <see cref="Console.Error"/> to writers of its own over the C runtime's copies of the
/// real ones, in text mode: redirected to a file or a pipe, every line ended "\r\r\n" (a blank line after each in
/// PowerShell, a stray "\r" in a script); in a terminal, where a windowed app has no C runtime output and writes through
/// <c>ConsoleOutput</c>'s console writer, the first line ended the process (0xC0000409, nothing printed). So a redirected
/// stream gets a writer over a copy of its handle, taken before and set after, that writes with <c>WriteFile</c> at the
/// handle's own file position: a file shared with the other stream (<c>&gt;log 2&gt;&amp;1</c>) or with the shell
/// (<c>(app &amp; echo done) &gt;log</c>, <c>&gt;&gt;log</c>) is written in turn, never over itself. Any other writer (the console
/// writer) is put back as it was; a redirected stream whose handle can't be copied keeps MuPDF's writer, which works.
/// </summary>
public static partial class CommandOutput
{
    /// <summary>Sends MuPDF's messages nowhere, keeping <see cref="Console.Out"/> and <see cref="Console.Error"/> writing where they did.</summary>
    /// <param name="output">Standard output is redirected (a file, a pipe) and Console's writer for it is still its own.</param>
    /// <param name="error">The same for standard error.</param>
    public static async Task QuietMuPdfAsync(bool output, bool error)
    {
        var (before, beforeError) = (Console.Out, Console.Error);
        var copy = output && OperatingSystem.IsWindows() ? Copy(StdOutput) : null;
        var copyError = error && OperatingSystem.IsWindows() ? Copy(StdError) : null;
        try
        {
            await MuPDFCore.MuPDF.RedirectOutput().ConfigureAwait(false);
        }
        finally
        {
            if (!output) Console.SetOut(before);
            else if (copy is not null) Console.SetOut(copy);
            if (!error) Console.SetError(beforeError);
            else if (copyError is not null) Console.SetError(copyError);
        }
    }

    /// <summary>A writer over a copy of a standard handle, in the encoding Console would use; null when there is none or it is
    /// opened for overlapped writes (which need a position of their own).</summary>
    private static TextWriter? Copy(int which)
    {
        var handle = GetStdHandle(which);
        if (handle == 0 || handle == -1) return null;
        var process = GetCurrentProcess();
        if (!DuplicateHandle(process, handle, process, out var copy, 0, false, DuplicateSameAccess)) return null;
        var owned = new SafeFileHandle(copy, ownsHandle: true);
        bool overlapped;
        try
        {
            overlapped = owned.IsAsync;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            overlapped = true;
        }
        if (overlapped)
        {
            owned.Dispose();
            return null;
        }
        var encoding = Console.OutputEncoding.CodePage == Encoding.UTF8.CodePage ? new UTF8Encoding(false) : Console.OutputEncoding; // no byte-order mark
        return TextWriter.Synchronized(new StreamWriter(new SharedPositionStream(owned), encoding, 256) { AutoFlush = true });
    }

    /// <summary>Writes with <c>WriteFile</c> and no offset, so the handle's file position, shared by every copy of it, moves
    /// (a FileStream keeps a position of its own and writes there).</summary>
    private sealed class SharedPositionStream(SafeFileHandle handle) : Stream
    {
        public override bool CanRead => false;
        public override bool CanSeek => false;
        public override bool CanWrite => !handle.IsClosed;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();

        public override void Write(byte[] buffer, int offset, int count) => Write(buffer.AsSpan(offset, count));

        public override unsafe void Write(ReadOnlySpan<byte> buffer)
        {
            while (!buffer.IsEmpty)
            {
                int written;
                fixed (byte* p = buffer)
                {
                    if (!WriteFile(handle, p, buffer.Length, out written, 0)) throw new IOException(Marshal.GetLastPInvokeErrorMessage());
                }
                if (written <= 0) throw new IOException("Nothing was written.");
                buffer = buffer[written..];
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) handle.Dispose();
            base.Dispose(disposing);
        }
    }

    private const int StdOutput = -11, StdError = -12;
    private const uint DuplicateSameAccess = 2;

    [LibraryImport("kernel32.dll", SetLastError = true)]
    private static partial nint GetStdHandle(int which);

    [LibraryImport("kernel32.dll")]
    private static partial nint GetCurrentProcess();

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool DuplicateHandle(nint sourceProcess, nint source, nint targetProcess, out nint target, uint access,
        [MarshalAs(UnmanagedType.Bool)] bool inherit, uint options);

    [LibraryImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static unsafe partial bool WriteFile(SafeFileHandle file, byte* buffer, int count, out int written, nint overlapped);
}
