using System.Diagnostics;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// A child that talks back through its output (the Office conversion helper) inherits its two pipes and nothing else:
/// Process.Start would pass it MuPDF's handle to every file open in place, and a save over one would fail while it runs.
/// The child here is cmd.exe.
/// </summary>
[Collection(Timing.Alone)] // checks that a file is let go: see Timing.Alone
public sealed class PipedChildTests
{
    private static string Cmd => Path.Combine(Environment.SystemDirectory, "cmd.exe");

    [Fact]
    public void AChildWithPipesDoesntKeepAFileOpenInPlace()
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-piped-child-");
        PipedProcess? child = null;
        try
        {
            var path = Path.Combine(dir.FullName, "big.pdf");
            var copy = Path.Combine(dir.FullName, "big copy.pdf");
            File.WriteAllBytes(path, TestPdf.Make(2, "file b"));
            File.WriteAllBytes(copy, TestPdf.Make(2, "file b, saved"));
            var tab = DocumentSession.Open(path, null, inPlaceBytes: 1);
            Assert.True(tab.IsInPlace);
            Assert.Equal(2, tab.Engine.PageCount);
            // Stays a while (a conversion may take minutes), saying nothing.
            child = FindWorkers.StartWithOnlyPipes(Cmd, ["/c", "ping -n 60 127.0.0.1 >nul"], dir.FullName);
            Assert.False(child.Process.HasExited);
            tab.Dispose(); // what a save does: MuPDF lets go, the copy goes over the file
            File.Move(copy, path, overwrite: true);
            Assert.False(child.Process.HasExited); // it was there all along
            using var saved = DocumentSession.Open(path, null, inPlaceBytes: 1);
            Assert.Contains("saved", saved.Engine.GetText(0).Text);
        }
        finally
        {
            if (child is not null)
            {
                try { child.Process.Kill(entireProcessTree: true); } catch (InvalidOperationException) { }
                child.Process.WaitForExit(10_000);
                child.Dispose();
            }
            GC.Collect();
            GC.WaitForPendingFinalizers();
            try { dir.Delete(true); } catch (IOException) { }
        }
    }

    [Fact]
    public async Task ItsOutputErrorOutputAndExitCodeComeBack()
    {
        using var child = FindWorkers.StartWithOnlyPipes(Cmd, ["/c", "echo pid 5& echo it broke 1>&2& echo note é done& exit 3"], Path.GetTempPath());
        var errors = child.Error.ReadToEndAsync();
        Assert.Equal("pid 5", child.Output.ReadLine()?.TrimEnd());
        Assert.StartsWith("note", child.Output.ReadLine());
        Assert.Null(child.Output.ReadLine()); // the end comes: this process holds no copy of the child's end of the pipe
        Assert.Equal("it broke", (await errors.WaitAsync(Timing.Limit(TimeSpan.FromSeconds(10)))).Trim());
        Assert.True(child.Process.WaitForExit(10_000));
        Assert.Equal(3, child.Process.ExitCode);
    }

    [Fact]
    public async Task WaitingForItAndKillingItWork()
    {
        using var child = FindWorkers.StartWithOnlyPipes(Cmd, ["/c", "ping -n 60 127.0.0.1 >nul"], Path.GetTempPath());
        using var timeout = new CancellationTokenSource(200);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => child.Process.WaitForExitAsync(timeout.Token));
        child.Process.Kill(entireProcessTree: true);
        await child.Process.WaitForExitAsync().WaitAsync(Timing.Limit(TimeSpan.FromSeconds(10)));
        Assert.Null(child.Output.ReadLine());
    }

    [Fact]
    public void AMissingProgramThrows()
    {
        Assert.Throws<System.ComponentModel.Win32Exception>(() => FindWorkers.StartWithOnlyPipes(Path.Combine(Path.GetTempPath(), "no-such-helper.exe"), [], Path.GetTempPath()));
    }
}
