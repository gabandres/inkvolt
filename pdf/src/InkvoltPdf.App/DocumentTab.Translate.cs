using System.Text;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Translate side by side (roadmap 3.1): reads the pages' paragraphs, shows what goes where, sends them through the
/// user's endpoint with progress and Cancel, and opens a translated copy in a new tab with the original beside it. The
/// document stays as it was, and can be used meanwhile: the job works on its bytes as they were when it started.
/// </summary>
public partial class DocumentTab
{
    private CancellationTokenSource? _translating;

    /// <summary>True from the moment a translation starts reading the pages until its copy opens.</summary>
    public bool IsTranslating => _translating is not null;

    /// <summary>Translates the pages into <paramref name="language"/>. Awaits the whole job; the UI stays free.</summary>
    /// <param name="languageTag">For the copy's language setting; null for a language typed in.</param>
    public async Task AiTranslate(string language, string? languageTag, int[] pages)
    {
        if (_disposed || IsTranslating || Window.GetWindow(this) is not { } owner) return;
        if (AiService.Current(out var problem) is not { } config)
        {
            if (!AiActions.ShowSettings(owner, problem + " Set it up here, or Cancel.")) return;
            if (AiService.Current(out _) is not { } now) return;
            config = now;
        }

        using var run = new CancellationTokenSource();
        _translating = run;
        RaiseState();
        var data = Session.Data;
        var password = Session.Password;
        var name = Session.DisplayName;
        var host = owner as MainWindow;
        try
        {
            // ── Read the pages, nothing sent ──
            TranslationPlan plan;
            IReadOnlyList<TranslationJob> jobs;
            IReadOnlyList<IReadOnlyList<AiMessage>> requests;
            using (var reading = new ProgressPrompt(owner, "Translate with AI", "Reading the paragraphs…"))
            {
                reading.Cancelled += run.Cancel;
                if (config.IsOllama)
                {
                    reading.Report("Asking Ollama how much text the model reads at once…");
                    config = await AiService.ResolveAsync(config, run.Token);
                }
                var read = new Progress<int>(done => reading.Report($"Reading the paragraphs… page {Math.Min(done + 1, pages.Length):N0} of {pages.Length:N0}", (double)done / Math.Max(1, pages.Length)));
                var pieceTokens = Translation.PieceTokens(config.ContextTokens);
                var wrong = false;
                while (true)
                {
                    try
                    {
                        var open = password;
                        (plan, jobs, requests) = await Task.Run(() =>
                        {
                            var p = Translation.MakePlan(data, open, pages, read, run.Token);
                            var j = Translation.Jobs(p, pieceTokens);
                            return (p, j, Translation.Requests(j, language));
                        }, run.Token);
                        break;
                    }
                    catch (OwnerPasswordRequiredException ex)
                    {
                        // Opened for viewing only: a copy with other text needs the permissions password, as any edit does.
                        if (PdfFiles.PromptOwnerPassword(owner, name, wrong || ex.WrongPassword && password is not null) is not { } typed) return;
                        password = typed;
                        wrong = true;
                    }
                }
            }
            if (_disposed) return;
            if (jobs.Count == 0)
            {
                Prompt.Info(owner, "Nothing to translate", NothingToTranslate(plan, pages));
                return;
            }

            // ── What is sent, where ──
            var restricted = await AiActions.IsCopyRestrictedAsync(Session);
            if (_disposed) return;
            var repeats = plan.ParagraphCount - jobs.Count;
            var outgoing = new AiOutgoing(requests,
                $"The paragraphs of {AiText.PagesText(pages)} ({plan.ParagraphCount:N0}{(repeats > 0 ? $", of which {repeats:N0} repeat and go once" : "")}), one by one, to be put into {language}",
                "any whose answer can't be used, once more");
            if (!AiActions.ConfirmSend(owner, config, outgoing, restricted, title: "Send for translation?")) return;

            // ── Translate ──
            Log.Write($"Translate: {requests.Count} request(s), {outgoing.Characters:N0} characters to {config.Endpoint.Host}"); // never the text
            TranslationAnswers answers;
            using var client = AiService.CreateClient(config);
            using (var sending = new ProgressPrompt(owner, $"Translating into {language}", $"Sending to {config.Endpoint.Host}…"))
            {
                sending.Cancelled += run.Cancel;
                var started = Environment.TickCount64;
                var progress = new Progress<TranslationProgress>(p =>
                {
                    var left = "";
                    if (p.Done >= 3 && p.Done < p.Total)
                    {
                        var ms = (Environment.TickCount64 - started) * (p.Total - p.Done) / p.Done;
                        var minutes = (int)Math.Ceiling(ms / 60000.0);
                        left = minutes <= 1 ? " About a minute left." : $" About {minutes:N0} minutes left.";
                    }
                    sending.Report($"Paragraph {Math.Min(p.Done + 1, p.Total):N0} of {p.Total:N0}, on page {p.Page + 1:N0}.{left}{(p.Failed > 0 ? $" {p.Failed:N0} without a usable answer." : "")}", (double)p.Done / Math.Max(1, p.Total));
                });
                answers = await Task.Run(() => Translation.TranslateAsync(jobs, language,
                    (messages, onText, cancel) => client.ChatAsync(messages, onText, cancel), null, progress, run.Token));
            }
            if (_disposed) return;

            // ── What to do with a part ──
            if (answers.Done.Count == 0)
            {
                if (!answers.Cancelled) Prompt.Error(owner, "Nothing was translated", answers.StoppedBecause ?? FirstFailure(answers));
                return;
            }
            if (answers.Cancelled || answers.StoppedBecause is not null)
            {
                var head = answers.Cancelled ? "Stopped." : answers.StoppedBecause + "\n";
                var keep = Prompt.Choose(owner, "Keep what was translated?",
                    $"{head} {answers.Done.Count:N0} of {jobs.Count:N0} texts are translated. A copy can be made with those, and the rest left in the original language.",
                    ("Make the copy", true), ("Discard", false));
                if (keep != 0) return;
            }

            // ── Write the copy, in a new tab beside the original ──
            TranslationResult result;
            PdfEngine? original;
            using (var writing = new ProgressPrompt(owner, "Translate with AI", "Writing the translated copy…"))
            {
                using var stop = new CancellationTokenSource();
                writing.Cancelled += stop.Cancel;
                var wrote = new Progress<int>(done => writing.Report($"Writing the translated copy… page {Math.Min(done + 1, plan.Pages.Count):N0} of {plan.Pages.Count:N0}", (double)done / Math.Max(1, plan.Pages.Count)));
                result = await Task.Run(() => Translation.Apply(plan, answers, languageTag, progress: wrote, cancel: stop.Token));
                original = result.Data is null ? null : await Task.Run(() => PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, password));
            }
            if (result.Data is null)
            {
                Prompt.Info(owner, "Nothing was translated", Summary(result.Report, language, plan));
                return;
            }
            if (host is null || !host.OpenSession(DocumentSession.FromBytes(result.Data, Translation.CopyName(name, language), password)) || host.ActiveTab is not { } tab)
            {
                original?.Dispose();
                return;
            }
            tab.ShowBeside(original!, name);
            if (result.Report.Notes > 0) tab.ShowPane(NavPaneKind.Comments);
            var summary = Summary(result.Report, language, plan);
            LastTranslationSummary = summary;
            Prompt.Info(owner, "Translated copy ready", summary);
            tab.Notify("The original is on the left, and they scroll together. Save the copy to keep it.");
        }
        catch (OperationCanceledException)
        {
            // Stopped before anything was sent, or while the copy was being written.
        }
        catch (Exception ex)
        {
            // Called without awaiting by the menu: nothing may get out of here, running out of memory on a crafted file included.
            Log.Write($"Translate failed: {ex.GetType().Name}"); // not the message: a server may echo text back
            if (!_disposed) Prompt.Error(owner, "The translation couldn't be finished", ex is AiException or ContentEditException or OpenPasswordUnknownException ? ex.Message : "This PDF's pages couldn't be read for translating. The document wasn't changed.");
        }
        finally
        {
            _translating = null;
            if (!_disposed) RaiseState();
        }
    }

    /// <summary>The summary of the last copy made (for the dev script's log).</summary>
    internal static string? LastTranslationSummary { get; private set; }

    private void CancelTranslation() => _translating?.Cancel();

    private static string FirstFailure(TranslationAnswers answers) =>
        answers.Failed.Values.FirstOrDefault() is { } why ? $"No answer could be used: {why}." : "The endpoint gave no answer.";

    private static string NothingToTranslate(TranslationPlan plan, int[] pages)
    {
        if (plan.ScanPages.Count > 0)
            return $"{Capital(AiText.PagesText(plan.ScanPages))} {(plan.ScanPages.Count == 1 ? "is a scan: its" : "are scans: their")} words are part of a picture, and a translated copy can't rewrite them.";
        if (plan.CrowdedPages.Count > 0) return $"{Capital(AiText.PagesText(plan.CrowdedPages))} {(plan.CrowdedPages.Count == 1 ? "has" : "have")} too many pieces of text to work out paragraphs from. Nothing was sent.";
        if (plan.Blocked.Count > 0) return $"The text of {AiText.PagesText(plan.Blocked.Select(b => b.Page))} can't be rewritten: {plan.Blocked[0].Why}. Nothing was sent.";
        return $"{Capital(AiText.PagesText(pages))} {(pages.Length == 1 ? "has" : "have")} no words to translate. Nothing was sent.";
    }

    private static string Capital(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    /// <summary>What the copy holds, in words. The model's text never appears here, only counts and pages.</summary>
    internal static string Summary(TranslationReport r, string language, TranslationPlan plan)
    {
        string Count(int n, string one, string many) => n == 1 ? $"1 {one}" : $"{n:N0} {many}";
        var sb = new StringBuilder();
        sb.Append($"{Count(r.Translated, "paragraph", "paragraphs")} in {language}");
        sb.Append(r.Shrunk > 0 ? $", {r.Shrunk:N0} in smaller type to stay in {(r.Shrunk == 1 ? "its box" : "their boxes")}." : ".");
        if (r.DoNotFit > 0) sb.Append($"\n{Count(r.DoNotFit, "doesn't", "don't")} fit even at the smallest size ({AiText.PagesText(r.Flags.Where(f => f.Kind == TranslationFlagKind.DoesNotFit).Select(f => f.Page))}).");
        if (r.NotTranslated > 0) sb.Append($"\n{Count(r.NotTranslated, "paragraph stays", "paragraphs stay")} in the original language ({AiText.PagesText(r.Flags.Where(f => f.Kind == TranslationFlagKind.NotTranslated).Select(f => f.Page).DefaultIfEmpty(plan.Pages.Count > 0 ? plan.Pages[0].Page : 0))}).");
        if (r.Unchanged > 0) sb.Append($"\nThe model gave {Count(r.Unchanged, "paragraph", "paragraphs")} back unchanged (a name or a code, perhaps).");
        if (r.Notes > 0) sb.Append($"\n{Count(r.Notes, "comment in the copy marks", "comments in the copy mark")} what to look at (the Comments pane lists them).");
        if (r.Cancelled) sb.Append("\nThe translation was stopped before the end.");
        else if (r.StoppedBecause is { } why) sb.Append($"\nThe endpoint stopped the translation: {why}");
        if (r.Fonts.Count > 0) sb.Append($"\nThe page's fonts don't have all the letters, so some text is drawn in {string.Join(", ", r.Fonts)}.");
        if (r.ScanPages.Count > 0) sb.Append($"\nNot translated: {AiText.PagesText(r.ScanPages)}, scanned (the words are part of a picture).");
        if (r.TurnedTextPages.Count > 0) sb.Append($"\nNot translated: turned text on {AiText.PagesText(r.TurnedTextPages)}.");
        if (r.CrowdedPages.Count > 0) sb.Append($"\nNot translated: {AiText.PagesText(r.CrowdedPages)}, with too many pieces of text to work out.");
        if (r.FailedPages.Count > 0) sb.Append($"\nNot translated: {AiText.PagesText(r.FailedPages)}, which couldn't be read or rewritten.");
        sb.Append("\n\nAI-generated: check it against the original. Comments, form fields, bookmarks and text inside pictures aren't translated.");
        return sb.ToString();
    }

    internal string DevTranslateState() => $"translating={IsTranslating} {DevSplitState()}" + (_beside is null ? "" : $" beside: main={Viewer.ViewCorner()} second={_second?.ViewCorner()}");
}
