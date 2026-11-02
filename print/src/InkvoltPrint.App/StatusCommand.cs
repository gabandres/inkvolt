using InkvoltPrint.Core.Fleet;
using InkvoltPrint.Core.Suite;

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
        InkvoltPrint.Windows.Suite.ConsoleOutput.Use(utf8Pipes: true);
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
}
