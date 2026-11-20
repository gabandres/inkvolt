using System.Diagnostics;
using System.Text.Json;

namespace InkvoltPdf.Tests;

/// <summary>
/// pdf.js (Mozilla's viewer) reading a PDF through <c>pdf/tools/pdfjs-check</c> (its README): opt-in with INKVOLTPDF_PDFJS
/// set; needs Node and npm on the PATH. The edited and translated copies' tests read with it.
/// </summary>
internal static class PdfJs
{
    /// <summary>pdf/tools/pdfjs-check, found upward from the test binaries (whose folder depth depends on the runtime identifier).</summary>
    public static readonly string Tool = FindUp(AppContext.BaseDirectory, Path.Combine("tools", "pdfjs-check", "index.mjs"))
                                         ?? Path.Combine(AppContext.BaseDirectory, "tools", "pdfjs-check");

    private static string? FindUp(string from, string relative)
    {
        for (var dir = new DirectoryInfo(from); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, relative))) return Path.GetDirectoryName(Path.Combine(dir.FullName, relative));
        return null;
    }

    /// <summary>A program on the PATH ("node", "npm"; Windows' .cmd and .exe wrappers found too), or null.</summary>
    public static string? OnPath(string name)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var ext in new[] { ".cmd", ".exe", "" }) // npm is also a shell script beside npm.cmd, which can't be started
            {
                var path = Path.Combine(dir.Trim('"'), name + ext);
                if (File.Exists(path)) return path;
            }
        return null;
    }

    /// <summary>
    /// Node when the check is asked for and can run (the tool's packages installed if they aren't); null when it isn't
    /// asked for, or with why it can't run.
    /// </summary>
    public static (string? Node, string? Skipped) Ready()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_PDFJS") is not { Length: > 0 }) return (null, null);
        var node = OnPath("node");
        var npm = OnPath("npm");
        if (node is null || npm is null) return (null, "Skipped: node or npm isn't on the PATH.");
        if (!File.Exists(Path.Combine(Tool, "index.mjs"))) throw new InvalidOperationException($"pdfjs-check isn't at {Tool}");
        if (!Directory.Exists(Path.Combine(Tool, "node_modules"))) Run(npm, "ci --no-audit --no-fund", Tool);
        return (node, null);
    }

    public static string Run(string exe, string args, string workDir)
    {
        var psi = new ProcessStartInfo(exe, args)
        {
            WorkingDirectory = workDir, RedirectStandardOutput = true, RedirectStandardError = true, UseShellExecute = false,
            StandardOutputEncoding = System.Text.Encoding.UTF8, StandardErrorEncoding = System.Text.Encoding.UTF8, // Node writes UTF-8, whatever the console's code page
        };
        using var p = Process.Start(psi)!;
        var stdout = p.StandardOutput.ReadToEndAsync();
        var stderr = p.StandardError.ReadToEndAsync();
        p.WaitForExit();
        if (p.ExitCode != 0) throw new InvalidOperationException($"{Path.GetFileName(exe)} {args}: exit {p.ExitCode}\n{stderr.Result}");
        return stdout.Result;
    }

    /// <summary>The text pdf.js reads from one page of a PDF (0-based), items in the order it reads them.</summary>
    public static string Text(string node, byte[] pdf, int page)
    {
        var file = Path.Combine(Path.GetTempPath(), $"inkvolt-pdfjs-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(file, pdf);
        try
        {
            var json = Run(node, $"index.mjs \"{file}\" {page + 1} {page + 1}", Tool);
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.GetProperty("pages")[0].GetProperty("text").GetString() ?? "";
        }
        finally
        {
            File.Delete(file);
        }
    }

    /// <summary>
    /// Null when every word of <paramref name="expected"/> appears in <paramref name="got"/>, in order (pdf.js may space
    /// the rest differently); else the first word missing and what pdf.js read after the last one found.
    /// </summary>
    public static string? FirstMiss(string expected, string got)
    {
        var words = got.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var at = 0;
        foreach (var w in expected.Split(' ', StringSplitOptions.RemoveEmptyEntries))
        {
            var from = at;
            while (at < words.Length && words[at] != w) at++;
            if (at == words.Length) return $"“{w}” missing; pdf.js reads on: {string.Join(' ', words.Skip(from).Take(12))}";
            at++;
        }
        return null;
    }
}
