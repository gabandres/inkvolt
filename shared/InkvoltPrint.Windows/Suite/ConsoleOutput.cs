using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPrint.Windows.Suite;

/// <summary>
/// A windowed app's command line (a console app would flash a console window each time a file is opened from Explorer): it writes
/// to the console of the terminal it was started from (attached), or to wherever its output is redirected. A terminal doesn't
/// wait for a windowed app: <c>start /wait</c> (cmd), <c>| Out-Default</c> or <c>Start-Process -Wait</c> (PowerShell) make it wait
/// and see the exit code; a scheduled task always waits.
/// </summary>
public static class ConsoleOutput
{
    /// <summary>Output to the redirected handles when there are some, else to the starting terminal's console.</summary>
    /// <param name="utf8Pipes">Redirected output is UTF-8, whatever the console's code page, so names in any script reach a script whole.</param>
    public static void Use(bool utf8Pipes = false)
    {
        if (Valid(GetStdHandle(StdOutput))) // redirected: a pipe or a file (a script, | Out-Default, a task's log)
        {
            if (utf8Pipes)
            {
                var utf8 = new UTF8Encoding(false);
                Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true });
                Console.SetError(new StreamWriter(Console.OpenStandardError(), utf8) { AutoFlush = true });
            }
            AttachConsole(AttachParentProcess); // a windowed app has no console of its own, so Ctrl+C wouldn't reach it, and "| Out-Default" would leave it printing
            return;
        }
        if (!AttachConsole(AttachParentProcess)) return; // started from Explorer or a task: nowhere to write, the exit code tells
        var console = CreateFile("CONOUT$", GenericRead | GenericWrite, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (!Valid(console)) return;
        var writer = TextWriter.Synchronized(new ConsoleWriter(new SafeFileHandle(console, ownsHandle: true)));
        writer.WriteLine(); // the prompt came back already (a windowed app isn't waited for): start on a line of our own
        Console.SetOut(writer);
        Console.SetError(writer);
    }

    /// <summary>Writes to the console as UTF-16 (WriteConsoleW), so names in any script show whatever the console's code page.</summary>
    private sealed class ConsoleWriter(SafeFileHandle console) : TextWriter
    {
        public override Encoding Encoding => Encoding.Unicode;

        public override void Write(char value) => Write(value.ToString());

        public override void Write(string? value)
        {
            if (!string.IsNullOrEmpty(value)) WriteConsole(console, value, value.Length, out _, IntPtr.Zero);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) console.Dispose();
            base.Dispose(disposing);
        }
    }

    private static bool Valid(IntPtr handle) => handle != IntPtr.Zero && handle != new IntPtr(-1);

    private const int AttachParentProcess = -1, StdOutput = -11;
    private const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, FileShareRead = 1, FileShareWrite = 2, OpenExisting = 3;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WriteConsoleW")]
    private static extern bool WriteConsole(SafeFileHandle console, string text, int length, out int written, IntPtr reserved);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
