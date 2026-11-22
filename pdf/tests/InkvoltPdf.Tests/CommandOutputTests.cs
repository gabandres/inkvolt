using System.Diagnostics;
using System.Text;

namespace InkvoltPdf.Tests;

/// <summary>
/// The command line's lines once MuPDF's messages are kept out (<see cref="Core.CommandOutput"/>), through the app's own
/// wiring (ConsoleOutput, then CommandOutput) in Bench.exe's "command-output", started as a windowed app is (no console of
/// its own). Redirected to a pipe or a file, each line ends in one "\r\n" (MuPDF's redirect had them end "\r\r\n"), and a
/// file shared with the other stream or with the shell is written in turn, never over itself.
/// </summary>
public sealed class CommandOutputTests : IDisposable
{
    private static string Bench => Path.Combine(AppContext.BaseDirectory, "Bench.exe");
    private readonly DirectoryInfo _dir = Directory.CreateTempSubdirectory("inkvolt-command-output-");

    public void Dispose()
    {
        try { _dir.Delete(true); } catch (IOException) { }
    }

    [Fact]
    public async Task LinesToAPipeEndOnce()
    {
        var info = new ProcessStartInfo(Bench, "command-output")
        {
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = Process.Start(info)!;
        var output = ReadAllAsync(process.StandardOutput.BaseStream);
        var error = ReadAllAsync(process.StandardError.BaseStream);
        await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(30)));
        Assert.Equal(0, process.ExitCode);
        Assert.Equal("line one\r\n", await output);
        Assert.Equal("line two\r\n", await error);
    }

    [Fact]
    public async Task LinesToTwoFilesEndOnce()
    {
        await CmdAsync($"\"{Bench}\" command-output >\"{File("out.txt")}\" 2>\"{File("err.txt")}\"");
        Assert.Equal("line one\r\n", Read("out.txt"));
        Assert.Equal("line two\r\n", Read("err.txt"));
    }

    [Fact]
    public async Task BothToOneFileFollowEachOther()
    {
        // ">log 2>&1": two copies of one handle; each writing at a position of its own, the error line went over the first.
        await CmdAsync($"\"{Bench}\" command-output >\"{File("log.txt")}\" 2>&1");
        Assert.Equal("line one\r\nline two\r\n", Read("log.txt"));
    }

    [Fact]
    public async Task TheShellWritesOnAfterThem()
    {
        // The shell's own handle to the file moves on past the lines, so what it writes next follows them.
        await CmdAsync($"(\"{Bench}\" command-output & echo after)>\"{File("log.txt")}\" 2>&1");
        Assert.Equal("line one\r\nline two\r\nafter\r\n", Read("log.txt"));
    }

    [Fact]
    public async Task AppendingKeepsWhatWasThere()
    {
        System.IO.File.WriteAllText(File("log.txt"), "before\r\n");
        await CmdAsync($"\"{Bench}\" command-output >>\"{File("log.txt")}\" 2>&1");
        Assert.Equal("before\r\nline one\r\nline two\r\n", Read("log.txt"));
    }

    /// <summary>A windowed app started with only its errors redirected (no standard output at all): the errors still go
    /// where they were sent, not to the console.</summary>
    [Fact]
    public async Task OnlyErrorsRedirectedStillGetThem()
    {
        var info = new ProcessStartInfo(Bench, "command-output no-output")
        {
            RedirectStandardError = true,
            UseShellExecute = false,
            CreateNoWindow = true,
        };
        using var process = Process.Start(info)!;
        var error = ReadAllAsync(process.StandardError.BaseStream);
        await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(30)));
        Assert.Equal(0, process.ExitCode);
        Assert.Equal("line two\r\n", await error);
    }

    /// <summary>In a terminal the app writes through a console writer of its own (ConsoleOutput); MuPDF's redirect had
    /// replaced it with a writer over the C runtime's standard output, which a windowed app doesn't have: Inkvolt PDF 1.15.0's
    /// --batch and --help typed in a terminal ended at once (0xC0000409), printing nothing.</summary>
    [Fact]
    public async Task AWriterOfItsOwnStays()
    {
        var info = new ProcessStartInfo(Bench) { UseShellExecute = false, CreateNoWindow = true };
        info.ArgumentList.Add("command-output");
        info.ArgumentList.Add("own-writer");
        info.ArgumentList.Add(File("own.txt"));
        using var process = Process.Start(info)!;
        await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(30)));
        Assert.Equal(0, process.ExitCode);
        Assert.Equal("line one\r\nline two\r\n", Read("own.txt"));
    }

    /// <summary>
    /// Started by a shell that passes "ignore Ctrl+C" down to what it starts (Git Bash does), --watch went on after Ctrl+C:
    /// Inkvolt PDF 1.18.0's smoke test, run from Git Bash, failed on it. A PowerShell in a hidden console of its own starts
    /// Bench's "command-output ctrl-c" with Ctrl+C ignored, waits for its "ready", then presses Ctrl+C on that console.
    /// </summary>
    [Fact]
    public async Task CtrlCStopsItThoughTheShellIgnoredIt()
    {
        const string script = """
            Add-Type -Namespace Inkvolt -Name Keys -MemberDefinition '[DllImport("kernel32")] public static extern bool GenerateConsoleCtrlEvent(uint e, uint g); [DllImport("kernel32")] public static extern bool SetConsoleCtrlHandler(IntPtr h, bool a);'
            [void][Inkvolt.Keys]::SetConsoleCtrlHandler([IntPtr]::Zero, $true) # passed down to what this starts, as Git Bash passes it
            $i = New-Object Diagnostics.ProcessStartInfo $env:TEST_EXE
            $i.Arguments = 'command-output ctrl-c'
            $i.UseShellExecute = $false
            $i.RedirectStandardOutput = $true
            $p = [Diagnostics.Process]::Start($i)
            if ($p.StandardOutput.ReadLine() -ne 'ready') { $p.Kill(); exit 98 }
            [void][Inkvolt.Keys]::GenerateConsoleCtrlEvent(0, 0)
            if (-not $p.WaitForExit(30000)) { $p.Kill(); exit 99 }
            exit $p.ExitCode
            """;
        var info = new ProcessStartInfo("powershell.exe") { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "-NoProfile", "-NonInteractive", "-Command", script }) info.ArgumentList.Add(a);
        info.Environment["TEST_EXE"] = Bench;
        using var process = Process.Start(info)!;
        var (output, error) = (process.StandardOutput.ReadToEndAsync(), process.StandardError.ReadToEndAsync());
        try
        {
            await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(90)));
        }
        catch (TimeoutException)
        {
            process.Kill(entireProcessTree: true);
            throw;
        }
        Assert.True(process.ExitCode == 0, $"exit {process.ExitCode} (99: Ctrl+C didn't stop it)\n{await output}\n{await error}");
    }

    private string File(string name) => Path.Combine(_dir.FullName, name);

    private string Read(string name) => System.IO.File.ReadAllText(File(name));

    /// <summary>Runs a command line in cmd, whose own redirection hands the child the files themselves (as a scheduled task's
    /// or a script's "&gt; log").</summary>
    private async Task CmdAsync(string command)
    {
        var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"), $"/d /c \"{command}\"")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            WorkingDirectory = _dir.FullName,
        };
        using var process = Process.Start(info)!;
        await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(30)));
        Assert.Equal(0, process.ExitCode);
    }

    private static async Task<string> ReadAllAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer);
        return Encoding.UTF8.GetString(buffer.ToArray());
    }
}
