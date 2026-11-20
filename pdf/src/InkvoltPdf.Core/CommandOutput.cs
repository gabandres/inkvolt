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
/// <c>ConsoleOutput</c>'s console writer, the first line ended the process (0xC0000409, nothing printed). Writers over
/// copies of the redirected handles, taken before and set after, keep the command line's lines going straight to where
/// they were sent; any other writer (the console writer) is put back as it was.
/// </summary>
public static partial class CommandOutput
{
    /// <summary>Sends MuPDF's messages nowhere, keeping <see cref="Console.Out"/> and <see cref="Console.Error"/> where they wrote.</summary>
    /// <param name="redirected">Standard output is redirected (a file, a pipe) and Console's writers are still its own.</param>
    public static async Task QuietMuPdfAsync(bool redirected)
    {
        var output = Console.Out;
        var error = Console.Error;
        if (redirected && OperatingSystem.IsWindows())
        {
            output = Copy(StdOutput) ?? output;
            error = Copy(StdError) ?? error;
        }
        try
        {
            await MuPDFCore.MuPDF.RedirectOutput().ConfigureAwait(false);
        }
        finally
        {
            Console.SetOut(output);
            Console.SetError(error);
        }
    }

    /// <summary>A writer over a copy of a standard handle (a file, a pipe, the console when only the other one is redirected), in the encoding Console would use; null when there is none.</summary>
    private static TextWriter? Copy(int which)
    {
        var handle = GetStdHandle(which);
        if (handle == 0 || handle == -1) return null;
        var process = GetCurrentProcess();
        if (!DuplicateHandle(process, handle, process, out var copy, 0, false, DuplicateSameAccess)) return null;
        var owned = new SafeFileHandle(copy, ownsHandle: true);
        FileStream stream;
        try
        {
            stream = new FileStream(owned, FileAccess.Write, 1, isAsync: false);
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            owned.Dispose();
            return null;
        }
        var encoding = Console.OutputEncoding.CodePage == Encoding.UTF8.CodePage ? new UTF8Encoding(false) : Console.OutputEncoding; // no byte-order mark
        return TextWriter.Synchronized(new StreamWriter(stream, encoding) { AutoFlush = true });
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
}
