using System.Diagnostics;
using System.Text.Json;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 2.1's test, the pdf.js half: an edited page opens in pdf.js with the same text (Acrobat isn't on the test
/// PC). Opt-in with INKVOLTPDF_PDFJS set; needs Node and npm on the PATH (else it skips itself) and
/// <c>pdf/tools/pdfjs-check</c> (its README). With INKVOLTPDF_CORPUS set, the export corpus's files are checked too.
/// </summary>
public partial class ParagraphEditTests
{
    /// <summary>pdf/tools/pdfjs-check, found upward from the test binaries (whose folder depth depends on the runtime identifier).</summary>
    private static readonly string PdfJsTool = FindUp(AppContext.BaseDirectory, Path.Combine("tools", "pdfjs-check", "index.mjs"))
                                               ?? Path.Combine(AppContext.BaseDirectory, "tools", "pdfjs-check");

    private static string? FindUp(string from, string relative)
    {
        for (var dir = new DirectoryInfo(from); dir is not null; dir = dir.Parent)
            if (File.Exists(Path.Combine(dir.FullName, relative))) return Path.GetDirectoryName(Path.Combine(dir.FullName, relative));
        return null;
    }

    /// <summary>A program on the PATH ("node", "npm"; Windows' .cmd and .exe wrappers found too), or null.</summary>
    private static string? OnPath(string name)
    {
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
            foreach (var ext in new[] { "", ".cmd", ".exe" })
            {
                var path = Path.Combine(dir.Trim('"'), name + ext);
                if (File.Exists(path)) return path;
            }
        return null;
    }

    private static string RunTool(string exe, string args, string workDir)
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
    private static string PdfJsText(string node, byte[] pdf, int page)
    {
        var file = Path.Combine(Path.GetTempPath(), $"inkvolt-pdfjs-{Guid.NewGuid():N}.pdf");
        File.WriteAllBytes(file, pdf);
        try
        {
            var json = RunTool(node, $"index.mjs \"{file}\" {page + 1} {page + 1}", PdfJsTool);
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
    private static string? FirstMiss(string expected, string got)
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

    [Fact]
    public void EditedParagraphsReadTheSameInPdfJs()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_PDFJS") is not { Length: > 0 }) return;
        var node = OnPath("node");
        var npm = OnPath("npm");
        if (node is null || npm is null)
        {
            output.WriteLine("Skipped: node or npm isn't on the PATH.");
            return;
        }
        Assert.True(File.Exists(Path.Combine(PdfJsTool, "index.mjs")), PdfJsTool);
        if (!Directory.Exists(Path.Combine(PdfJsTool, "node_modules"))) RunTool(npm, "ci --no-audit --no-fund", PdfJsTool);

        // The test's own pages: each alignment, a paragraph inside a form XObject, stand-in characters, and a one-run edit.
        var cases = new List<(string Name, byte[] Pdf, int Page, string Added)>();
        foreach (var align in new[] { ParagraphAlign.Left, ParagraphAlign.Right, ParagraphAlign.Center, ParagraphAlign.Justified })
            cases.Add(($"sample {align}", Page(align, gap: 120).Pdf, 0, Twenty));
        cases.Add(("sample form", ContentEditPdf.Make("q /Fm1 Do Q", form: FormBody(), fontText: Chars), 0, Twenty));
        cases.Add(("sample stand-ins", Page(ParagraphAlign.Left, gap: 120).Pdf, 0, "mail me @ home #1 for 5 " + Twenty));
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_CORPUS") is { Length: > 0 } dir && Directory.Exists(dir))
            foreach (var file in Directory.GetFiles(dir, "*.pdf").Order())
            {
                var pdf = File.ReadAllBytes(file);
                int pages;
                using (var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null)) pages = engine.PageCount;
                for (var page = 0; page < Math.Min(3, pages); page++) cases.Add(($"{Path.GetFileName(file)} p{page + 1}", pdf, page, ""));
            }

        var failures = new List<string>();
        foreach (var (name, pdf, page, addedWords) in cases)
        {
            PageContent content;
            try
            {
                content = ContentEditor.Read(pdf, null, page);
            }
            catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
            {
                output.WriteLine($"{name}: unreadable ({ex.Message})");
                continue;
            }
            var p = content.Paragraphs.Where(q => q.Blocked is null && q.Lines.Count > 1).MaxBy(q => q.Lines.Count);
            if (p is null)
            {
                output.WriteLine($"{name}: no editable paragraph of several lines");
                continue;
            }
            var words = p.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
            // As many of the 20 words as fit without running into what follows (a line that lands beside the next
            // block, on its baseline, would read into it in any viewer; the overlap warning is the corpus test's job).
            var added = addedWords.Length > 0 ? addedWords : string.Join(' ', Enumerable.Range(0, 20).Select(i => words[i % words.Length]));
            var text = p.Text + " " + added;
            var check = p.Check(text);
            foreach (var n in new[] { 10, 5, 2, 1 })
            {
                if (check.Overlaps is null || addedWords.Length > 0) break;
                added = string.Join(' ', Enumerable.Range(0, n).Select(i => words[i % words.Length]));
                text = p.Text + " " + added;
                check = p.Check(text);
            }
            if (check.Missing.Count > 0)
            {
                output.WriteLine($"{name}: refused, no font has {string.Join(" ", check.Missing.Take(5))}");
                continue;
            }
            if (check.Overlaps is not null)
            {
                output.WriteLine($"{name}: no room under the paragraph for even one more word");
                continue;
            }
            byte[] edited;
            try
            {
                edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
            }
            catch (ContentEditException ex)
            {
                failures.Add($"{name}: {ex.Message}");
                continue;
            }
            var got = Words(PdfJsText(node, edited, page));
            var miss = FirstMiss(Words(text), got) ?? (got.Contains(Words(added), StringComparison.Ordinal) ? null : "the added words aren't read together");
            output.WriteLine($"{name}: {p.Lines.Count} lines {p.Align} → {check.LineCount}; pdf.js {(miss is null ? "reads it in order" : "DIFFERS: " + miss)}; {(check.Borrowed.Count > 0 ? $"stand-ins {string.Join(" ", check.StandIns)}" : "")}");
            if (miss is not null) failures.Add($"{name}: pdf.js doesn't read the edited paragraph in order ({miss})");
        }
        // The one-run editor with a stand-in character.
        {
            var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td (Hello World) Tj ET BT /FA 9 Tf 72 600 Td (draft) Tj ET");
            var run = ContentEditor.Read(pdf, null, 0).Runs.Single(r => r.Text == "Hello World");
            var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello Zebra");
            var got = Words(PdfJsText(node, edited, 0));
            output.WriteLine($"one run with stand-ins: pdf.js reads \"{got}\"");
            if (!got.Contains("Hello Zebra", StringComparison.Ordinal)) failures.Add("one run with stand-ins: pdf.js doesn't read \"Hello Zebra\"");
        }
        foreach (var f in failures) output.WriteLine("FAIL " + f);
        Assert.Empty(failures);
    }
}
