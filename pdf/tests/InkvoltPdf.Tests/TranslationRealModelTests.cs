using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using Xunit;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// A real model, run only when asked: INKVOLTPDF_REAL_MODEL = "url|model" (llama.cpp's llama-server, Ollama, LM Studio),
/// INKVOLTPDF_REAL_PAGES = "file|1-based page|language;…". It prints what a person checks by reading: every paragraph the
/// model gave back unchanged or that wasn't used, and how long each page took. It fails on what no answer should leave in
/// a copy: reasoning tags, a preamble, control characters; on a line that doesn't show; and on words lost from the copy.
/// INKVOLTPDF_REAL_OUT saves each answer and copy.
/// </summary>
public class TranslationRealModelTests(ITestOutputHelper output)
{
    /// <summary>Marked texts over all pages: all tags kept, some dropped, all dropped, not trusted.</summary>
    private readonly int[] _totals = new int[5];

    [Fact]
    public async Task A_real_models_answers_leave_nothing_of_its_own_in_the_copy()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_REAL_MODEL") is not { Length: > 0 } model
            || Environment.GetEnvironmentVariable("INKVOLTPDF_REAL_PAGES") is not { Length: > 0 } list) return;
        var outDir = Environment.GetEnvironmentVariable("INKVOLTPDF_REAL_OUT");
        var parts = model.Split('|');
        Assert.True(AiEndpoint.TryParse(parts[0], out var endpoint, out var error), error);
        using var client = new AiClient(endpoint!, parts[1], null);
        var failures = new List<string>(); // every page is run, and what went wrong on each is told at the end
        foreach (var job in list.Split(';'))
        {
            var (file, page, language) = (job.Split('|')[0], int.Parse(job.Split('|')[1]) - 1, job.Split('|')[2]);
            void Fail(string what)
            {
                failures.Add($"{Path.GetFileName(file)} p{page + 1} {language}: {what}");
                output.WriteLine($"  FAIL {what}");
            }
            var pdf = File.ReadAllBytes(file);
            var plan = Translation.MakePlan(pdf, null, [page]);
            var jobs = Translation.Jobs(plan, Translation.PieceTokens(8192));
            var started = DateTime.UtcNow;
            var raw = new Dictionary<string, string>();
            var answers = await Translation.TranslateAsync(jobs, language, async (m, t, c) =>
            {
                var reply = await client.ChatAsync(m, t, c);
                lock (raw) raw[m[^1].Content] = reply.Text;
                return reply;
            });
            var result = Translation.Apply(plan, answers, null);
            var took = DateTime.UtcNow - started;
            var r = result.Report;
            output.WriteLine($"{Path.GetFileName(file)} p{page + 1}: {jobs.Count} texts in {took.TotalSeconds:0}s; {r.Translated} written, {r.Shrunk} shrunk, {r.DoNotFit} don't fit, {r.Unchanged} unchanged, {r.NotTranslated} left");
            foreach (var (source, text) in answers.Done.Where(a => a.Key == a.Value)) output.WriteLine($"  unchanged: \"{source}\"");
            foreach (var (source, why) in answers.Failed) output.WriteLine($"  not used: \"{source}\": {why}; said \"{(raw.TryGetValue(source, out var said) ? AiProtocol.Shorten(said, 200) : "")}\"");
            foreach (var (source, reply) in raw.Where(kv => TranslationText.CleanReply(kv.Value, kv.Key, plan.Marked.Contains(kv.Key)).Text != kv.Value.Trim()))
                output.WriteLine($"  cleaned: \"{AiProtocol.Shorten(reply, 120)}\"");
            // How often the model kept the looks' tags: every stretch back and trusted, some dropped, none, or not trusted.
            int marked = 0, all = 0, some = 0, none = 0, untrusted = 0;
            foreach (var (sent, answer) in answers.Done.Where(a => plan.Marked.Contains(a.Key)))
            {
                marked++;
                var (text, spans) = plan.Sources[sent];
                var (had, back, trusted) = TranslationMarkup.TagsKept(answer, text, spans); // judged as the copy reads it
                if (trusted is null) none++;
                else if (trusted == false) untrusted++;
                else if (back >= had) all++;
                else some++;
                if (trusted != true || back < had) output.WriteLine($"  tags {(trusted is null ? "dropped" : trusted == false ? "not trusted" : $"{back} of {had}")}: \"{AiProtocol.Shorten(sent, 100)}\" => \"{AiProtocol.Shorten(answer, 100)}\"");
            }
            output.WriteLine($"  marked {marked}: all tags kept {all}, some dropped {some}, all dropped {none}, not trusted {untrusted}");
            _totals[0] += marked; _totals[1] += all; _totals[2] += some; _totals[3] += none; _totals[4] += untrusted;
            output.WriteLine($"  so far: marked {_totals[0]}, all kept {_totals[1]}, some dropped {_totals[2]}, all dropped {_totals[3]}, not trusted {_totals[4]}");
            foreach (var text in answers.Done.Values)
            {
                if (Regex.IsMatch(text, "</?think>|<\\|", RegexOptions.IgnoreCase)) Fail($"reasoning tags: {text}");
                if (Regex.IsMatch(text, @"^(here is|here's|translation:|aquí (está|tienes)|traducción:)", RegexOptions.IgnoreCase)) Fail($"a preamble: {text}");
                if (text.Any(char.IsControl)) Fail($"control characters: {text}");
            }
            if (outDir is not null)
            {
                Directory.CreateDirectory(outDir);
                var stem = $"{Path.GetFileNameWithoutExtension(file)}-{page + 1}-{language}";
                File.WriteAllLines(Path.Combine(outDir, stem + ".txt"), answers.Done.Select(a => $"{a.Key}\n  => {a.Value}\n"));
                if (result.Data is { } copy) File.WriteAllBytes(Path.Combine(outDir, stem + ".pdf"), copy);
            }
            if (result.Data is not { } data) continue;
            using var engine = PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, null);
            var shown = TranslationInk.Solid(engine.GetText(page, cache: false).Text);
            foreach (var (source, answer) in answers.Done.Where(a => a.Value != a.Key).Take(200))
            {
                // A marked answer's words, as the copy has them (its tags are looks, not text).
                var text = TranslationInk.Solid(plan.Marked.Contains(source) ? TranslationMarkup.Plain(answer) : answer);
                if (!shown.Contains(text[..Math.Min(40, text.Length)], StringComparison.Ordinal)) Fail($"not read back by MuPDF: {text[..Math.Min(40, text.Length)]}");
            }
            var problems = TranslationInk.Problems(engine, page);
            foreach (var problem in problems) output.WriteLine($"  doesn't show: {problem}");
            if (problems.Count > r.DoNotFit) Fail(string.Join("; ", problems));
        }
        Assert.Empty(failures);

    }
}
