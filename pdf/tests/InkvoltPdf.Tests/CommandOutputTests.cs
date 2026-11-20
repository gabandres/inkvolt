using System.Diagnostics;
using System.Text;

namespace InkvoltPdf.Tests;

/// <summary>
/// The command line's lines once MuPDF's messages are kept out (<see cref="Core.CommandOutput"/>): redirected to a pipe or a
/// file, each ends in one "\r\n". Found running --batch over a network share with its output in a file: MuPDF's redirect
/// had every line end "\r\r\n". The process is Bench.exe's "command-output", which does what the app's --batch does.
/// </summary>
public sealed class CommandOutputTests
{
    private static string Bench => Path.Combine(AppContext.BaseDirectory, "Bench.exe");

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
    public async Task LinesToAFileEndOnce()
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-command-output-");
        try
        {
            var outFile = Path.Combine(dir.FullName, "out.txt");
            var errFile = Path.Combine(dir.FullName, "err.txt");
            // cmd's own redirection: the child's handles are the files themselves, as in a scheduled task's or a script's "> log".
            var info = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, "cmd.exe"),
                $"/d /c \"\"{Bench}\" command-output >\"{outFile}\" 2>\"{errFile}\"\"")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            };
            using var process = Process.Start(info)!;
            await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(30)));
            Assert.Equal(0, process.ExitCode);
            Assert.Equal("line one\r\n", File.ReadAllText(outFile));
            Assert.Equal("line two\r\n", File.ReadAllText(errFile));
        }
        finally
        {
            try { dir.Delete(true); } catch (IOException) { }
        }
    }

    /// <summary>In a terminal the app writes through a console writer of its own (ConsoleOutput); MuPDF's redirect had
    /// replaced it with a writer over the C runtime's standard output, which a windowed app doesn't have: Inkvolt PDF 1.15.0's
    /// --batch and --help typed in a terminal ended at once (0xC0000409), printing nothing.</summary>
    [Fact]
    public async Task AWriterOfItsOwnStays()
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-command-output-");
        try
        {
            var file = Path.Combine(dir.FullName, "own.txt");
            var info = new ProcessStartInfo(Bench) { UseShellExecute = false, CreateNoWindow = true };
            info.ArgumentList.Add("command-output");
            info.ArgumentList.Add(file);
            using var process = Process.Start(info)!;
            await process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(30)));
            Assert.Equal(0, process.ExitCode);
            Assert.Equal("line one\r\nline two\r\n", File.ReadAllText(file));
        }
        finally
        {
            try { dir.Delete(true); } catch (IOException) { }
        }
    }

    private static async Task<string> ReadAllAsync(Stream stream)
    {
        using var buffer = new MemoryStream();
        await stream.CopyToAsync(buffer);
        return Encoding.UTF8.GetString(buffer.ToArray());
    }
}
