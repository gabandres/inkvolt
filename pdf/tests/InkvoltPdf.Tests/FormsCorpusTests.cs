using System.Diagnostics;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// The forms corpus (pdf/tools/forms-corpus): real public forms filled through FormEditor, saved, reopened and read back
/// by Inkvolt, MuPDF and pdf.js. Opt-in with INKVOLTPDF_FORMS set (it downloads the corpus once, ~70 MB, and takes
/// about 15 minutes); passes while every form fails at most the ways baseline.json lists, so a fix that makes a form pass
/// stays green and a new failure turns it red. pdf.js is read when node is on the PATH and pdf/tools/pdfjs-check has
/// its node_modules (npm ci there).
/// </summary>
public class FormsCorpusTests(ITestOutputHelper output)
{
    private static readonly string? ToolDir = FindUp(AppContext.BaseDirectory, Path.Combine("tools", "forms-corpus", "corpus.json"));

    private static string? FindUp(string from, string relative)
    {
        for (var dir = new DirectoryInfo(from); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, "pdf", relative))) return Path.GetDirectoryName(Path.Combine(dir.FullName, "pdf", relative));
        return null;
    }

    [Fact]
    public void CorpusFormsFillNoWorseThanTheBaseline()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_FORMS") is not { Length: > 0 }) return;
        Assert.NotNull(ToolDir);

        if (!Directory.Exists(Path.Combine(ToolDir, ".cache", "pdfs")))
        {
            var (fetchCode, fetchOut) = Run("pwsh", ["-NoProfile", "-File", Path.Combine(ToolDir, "fetch.ps1")], TimeSpan.FromMinutes(20));
            output.WriteLine(fetchOut);
            Assert.True(fetchCode == 0, "fetch.ps1 failed");
        }

        var (code, text) = Run("dotnet", ["run", "--project", ToolDir, "-c", "Release", "--", "run"], TimeSpan.FromMinutes(60));
        // The summary and any regression lines; the per-form progress lines stay in the tool's own output.
        foreach (var line in text.Split('\n').Where(l => !l.StartsWith('[')))
            output.WriteLine(line.TrimEnd());
        Assert.True(code == 0, "forms that fail in a way baseline.json doesn't list (REGRESSION lines above), or the harness didn't run");
    }

    private static (int Code, string Output) Run(string exe, string[] args, TimeSpan limit)
    {
        var psi = new ProcessStartInfo(exe) { RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false };
        foreach (var a in args) psi.ArgumentList.Add(a);
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(limit))
        {
            p.Kill(true);
            return (-1, $"{exe} still running after {limit.TotalMinutes} min\n{stdout.Result}");
        }
        return (p.ExitCode, stdout.Result + stderr.Result);
    }
}
