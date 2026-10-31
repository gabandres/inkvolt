using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Suite;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPrint.App;

/// <summary>
/// <c>inkvoltprint status --all [--json] [--out file]</c> without a window, in the copy people have (the developer CLI isn't packaged or
/// installed). Inkvolt Print is a windowed app, so it writes to wherever its output is redirected, else to the console of the terminal it
/// was started from. A terminal doesn't wait for a windowed app: <c>start /wait</c> (cmd), <c>| Out-Default</c> (PowerShell), or a
/// scheduled task, which always waits, see the exit code. Runs before the single-instance hand-off, so it never asks a running
/// copy; writes no state, so it runs beside one. Started by <see cref="App"/>; the command itself is <see cref="FleetCommand"/>.
/// </summary>
internal static class StatusCommand
{
    public static async Task<int> RunAsync(string[] args)
    {
        UseConsole();
        using var stop = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true; // stop the reads, then exit with the command's code
            stop.Cancel();
        };
        var demo = args.Contains("--demo");
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var command = args.Where(a => a is not ("--no-printers" or "--pro-enforce")).ToList();
        int code;
        try
        {
            // Not PcEnvironment.Real or AppState: opening those may move the data folder, and this writes nothing.
            IFleetPc pc = demo ? Demo.FleetPc(args.Contains("--no-printers")) : new Windows.Fleet.WindowsFleetPc(local);
            Core.Pro.Store = pc is Windows.Fleet.WindowsFleetPc real ? real.ProStore(local) : new MemoryProStore();
            if (demo && args.Contains("--pro-enforce")) Core.Pro.Enforced = true; // the locked path (demo only: memory)
            code = await FleetCommand.RunAsync(command, Console.Out, Console.Error, pc, () => DateTimeOffset.Now, Diagnostics.Identity.Current, stop.Token);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Inkvolt Print stopped: {ex.Message}");
            code = FleetCommand.Wrong;
        }
        Console.Out.Flush();
        Console.Error.Flush();
        return code;
    }

    /// <summary>Output to the redirected handles when there are some, else to the starting terminal's console.</summary>
    private static void UseConsole()
    {
        if (Valid(GetStdHandle(StdOutput))) // a pipe or a file (a script, | Out-Default, a task's log): UTF-8, whatever a windowed app's code page is
        {
            var utf8 = new UTF8Encoding(false);
            Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), utf8) { AutoFlush = true });
            Console.SetError(new StreamWriter(Console.OpenStandardError(), utf8) { AutoFlush = true });
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

    /// <summary>Writes to the console as UTF-16, so names in any script show whatever the console's code page.</summary>
    private sealed class ConsoleWriter(SafeFileHandle console) : TextWriter
    {
        public override Encoding Encoding => Encoding.Unicode;
        public override void Write(char value) => Write(value.ToString());

        public override void Write(string? value)
        {
            if (!string.IsNullOrEmpty(value)) WriteConsole(console, value, value.Length, out _, IntPtr.Zero);
        }
    }

    private static bool Valid(IntPtr handle) => handle != IntPtr.Zero && handle != new IntPtr(-1);

    private const int StdOutput = -11, AttachParentProcess = -1;
    private const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, FileShareRead = 1, FileShareWrite = 2, OpenExisting = 3;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int handle);

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

    [DllImport("kernel32.dll", EntryPoint = "WriteConsoleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool WriteConsole(SafeFileHandle console, string text, int count, out int written, IntPtr reserved);
}
