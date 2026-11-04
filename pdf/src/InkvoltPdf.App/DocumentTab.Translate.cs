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
            if (!AiActions.ShowSettings(owner, Loc.Format(Strings.TabAi_SetUpHere, problem))) return;
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
            using (var reading = new ProgressPrompt(owner, Strings.Translate_Title, Strings.Translate_ReadingParagraphs))
            {
                reading.Cancelled += run.Cancel;
                if (config.IsOllama)
                {
                    reading.Report(Strings.TabAi_AskingOllama);
                    config = await AiService.ResolveAsync(config, run.Token);
                }
                var read = new Progress<int>(done => reading.Report(Loc.Format(Strings.Translate_ReadingPage, Math.Min(done + 1, pages.Length), pages.Length), (double)done / Math.Max(1, pages.Length)));
                var pieceTokens = Translation.PieceTokens(config.ContextTokens);
                var wrong = false;
                var openPassword = Session.OpenPassword;
                var dropOpenPassword = false;
                while (true)
                {
                    try
                    {
                        var (open, keep, drop) = (password, openPassword, dropOpenPassword);
                        (plan, jobs, requests) = await Task.Run(() =>
                        {
                            var p = Translation.MakePlan(data, open, pages, read, run.Token, keep, drop);
                            var j = Translation.Jobs(p, pieceTokens);
                            return (p, j, Translation.Requests(j, language));
                        }, run.Token);
                        break;
                    }
                    catch (OwnerPasswordRequiredException ex)
                    {
                        // Opened for viewing only: a copy with other text needs the permissions password, as any edit does.
                        reading.Pause();
                        if (PdfFiles.PromptOwnerPassword(owner, name, wrong || ex.WrongPassword && password is not null) is not { } typed) return;
                        reading.Resume();
                        password = typed;
                        wrong = true;
                    }
                    catch (OpenPasswordUnknownException)
                    {
                        // AES-256 opened with its permissions password: the copy can't keep its protection without the open password.
                        reading.Pause();
                        if (SecurityActions.PromptOpenPassword(owner, name, data) is not { } answer) return;
                        reading.Resume();
                        if (answer.DropIt) dropOpenPassword = true;
                        else openPassword = answer.Password;
                    }
                }
            }
            if (_disposed) return;
            if (jobs.Count == 0)
            {
                Prompt.Info(owner, Strings.Translate_NothingTitle, NothingToTranslate(plan, pages));
                return;
            }

            // ── What is sent, where ──
            var restricted = await AiActions.IsCopyRestrictedAsync(Session);
            if (_disposed) return;
            var repeats = plan.ParagraphCount - jobs.Count;
            var outgoing = new AiOutgoing(requests,
                repeats > 0
                    ? Loc.Format(Strings.Translate_SentParagraphsRepeats, AiText.PagesText(pages), plan.ParagraphCount, language, repeats)
                    : Loc.Format(Strings.Translate_SentParagraphs, AiText.PagesText(pages), plan.ParagraphCount, language),
                Strings.Translate_SentRetries);
            if (!AiActions.ConfirmSend(owner, config, outgoing, restricted, title: Strings.Translate_SendTitle)) return;

            // ── Translate ──
            Log.Write($"Translate: {requests.Count} request(s), {outgoing.Characters:N0} characters to {config.Endpoint.Host}"); // never the text
            TranslationAnswers answers;
            using var client = AiService.CreateClient(config);
            using (var sending = new ProgressPrompt(owner, Loc.Format(Strings.Translate_TranslatingInto, language), Loc.Format(Strings.TabAi_Sending, config.Endpoint.Host)))
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
                        left = minutes <= 1 ? Strings.Translate_AboutAMinute : Loc.Format(Strings.Translate_AboutMinutes, minutes);
                    }
                    sending.Report(Loc.Format(Strings.Translate_ParagraphProgress, Math.Min(p.Done + 1, p.Total), p.Total, p.Page + 1) + left + (p.Failed > 0 ? Loc.Format(Strings.Translate_WithoutAnswer, p.Failed) : ""), (double)p.Done / Math.Max(1, p.Total));
                });
                answers = await Task.Run(() => Translation.TranslateAsync(jobs, language,
                    (messages, onText, cancel) => client.ChatAsync(messages, onText, cancel), null, progress, run.Token));
            }
            if (_disposed) return;

            // ── What to do with a part ──
            if (answers.Done.Count == 0)
            {
                if (!answers.Cancelled) Prompt.Error(owner, Strings.Translate_NothingTranslated, answers.StoppedBecause ?? FirstFailure(answers));
                return;
            }
            if (answers.Cancelled || answers.StoppedBecause is not null)
            {
                var body = answers.Cancelled ? Loc.Format(Strings.Translate_KeepStopped, answers.Done.Count, jobs.Count)
                    : answers.StoppedBecause + "\n " + Loc.Format(Strings.Translate_KeepCount, answers.Done.Count, jobs.Count);
                var keep = Prompt.Choose(owner, Strings.Translate_KeepTitle, body,
                    (Strings.Translate_MakeCopy, true), (Strings.Common_Discard, false));
                if (keep != 0) return;
            }

            // ── Write the copy, in a new tab beside the original ──
            TranslationResult result;
            PdfEngine? original;
            using (var writing = new ProgressPrompt(owner, Strings.Translate_Title, Strings.Translate_Writing))
            {
                using var stop = new CancellationTokenSource();
                writing.Cancelled += stop.Cancel;
                var wrote = new Progress<int>(done => writing.Report(Loc.Format(Strings.Translate_WritingPage, Math.Min(done + 1, plan.Pages.Count), plan.Pages.Count), (double)done / Math.Max(1, plan.Pages.Count)));
                result = await Task.Run(() => Translation.Apply(plan, answers, languageTag, progress: wrote, cancel: stop.Token));
                original = result.Data is null ? null : await Task.Run(() => PdfEngine.Open(data, MuPDFCore.InputFileTypes.PDF, password));
            }
            if (result.Data is null)
            {
                Prompt.Info(owner, Strings.Translate_NothingTranslated, Summary(result.Report, language, plan));
                return;
            }
            var copy = DocumentSession.FromBytes(result.Data, Translation.CopyName(name, language), password);
            copy.UseOpenPassword(plan.DropOpenPassword ? null : plan.OpenPassword); // so an edit of the copy doesn't ask again
            if (host is null || !host.OpenSession(copy) || host.ActiveTab is not { } tab)
            {
                original?.Dispose();
                return;
            }
            tab.ShowBeside(original!, name);
            if (result.Report.Notes > 0) tab.ShowPane(NavPaneKind.Comments);
            var summary = Summary(result.Report, language, plan);
            LastTranslationSummary = summary;
            Prompt.Info(owner, Strings.Translate_CopyReady, summary);
            tab.Notify(Strings.Translate_OriginalLeft);
        }
        catch (OperationCanceledException)
        {
            // Stopped before anything was sent, or while the copy was being written.
        }
        catch (Exception ex)
        {
            // Called without awaiting by the menu: nothing may get out of here, running out of memory on a crafted file included.
            Log.Write($"Translate failed: {ex.GetType().Name}"); // not the message: a server may echo text back
            if (!_disposed) Prompt.Error(owner, Strings.Translate_CouldntFinish, ex is AiException or ContentEditException or OpenPasswordUnknownException ? ex.Message : Strings.Translate_PagesUnreadable);
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
        answers.Failed.Values.FirstOrDefault() is { } why ? Loc.Format(Strings.Translate_NoUsableAnswer, why) : Strings.Translate_NoAnswer;

    private static string NothingToTranslate(TranslationPlan plan, int[] pages)
    {
        if (plan.ScanPages.Count > 0)
            return Loc.Plural(plan.ScanPages.Count, Strings.Translate_NothingScans_One, Strings.Translate_NothingScans_Many, Capital(AiText.PagesText(plan.ScanPages)));
        if (plan.CrowdedPages.Count > 0)
            return Loc.Plural(plan.CrowdedPages.Count, Strings.Translate_NothingCrowded_One, Strings.Translate_NothingCrowded_Many, Capital(AiText.PagesText(plan.CrowdedPages)));
        if (plan.Blocked.Count > 0) return Loc.Format(Strings.Translate_NothingBlocked, AiText.PagesText(plan.Blocked.Select(b => b.Page)), plan.Blocked[0].Why);
        return Loc.Plural(pages.Length, Strings.Translate_NothingWords_One, Strings.Translate_NothingWords_Many, Capital(AiText.PagesText(pages)));
    }

    private static string Capital(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

    /// <summary>What the copy holds, in words. The model's text never appears here, only counts and pages.</summary>
    internal static string Summary(TranslationReport r, string language, TranslationPlan plan)
    {
        var sb = new StringBuilder();
        sb.Append(r.Shrunk == 0 ? Loc.Plural(r.Translated, Strings.Translate_SumParagraphs_One, Strings.Translate_SumParagraphs_Many, language)
            : r.Shrunk == 1 ? Loc.Plural(r.Translated, Strings.Translate_SumShrunkOne_One, Strings.Translate_SumShrunkOne_Many, language)
            : Loc.Format(Strings.Translate_SumShrunkMany, r.Translated, language, r.Shrunk));
        if (r.DoNotFit > 0)
            sb.Append('\n').Append(Loc.Plural(r.DoNotFit, Strings.Translate_SumDoNotFit_One, Strings.Translate_SumDoNotFit_Many,
                AiText.PagesText(r.Flags.Where(f => f.Kind == TranslationFlagKind.DoesNotFit).Select(f => f.Page))));
        if (r.NotTranslated > 0)
            sb.Append('\n').Append(Loc.Plural(r.NotTranslated, Strings.Translate_SumNotTranslated_One, Strings.Translate_SumNotTranslated_Many,
                AiText.PagesText(r.Flags.Where(f => f.Kind == TranslationFlagKind.NotTranslated).Select(f => f.Page).DefaultIfEmpty(plan.Pages.Count > 0 ? plan.Pages[0].Page : 0))));
        if (r.Unchanged > 0) sb.Append('\n').Append(Loc.Plural(r.Unchanged, Strings.Translate_SumUnchanged_One, Strings.Translate_SumUnchanged_Many));
        if (r.Notes > 0) sb.Append('\n').Append(Loc.Plural(r.Notes, Strings.Translate_SumNotes_One, Strings.Translate_SumNotes_Many));
        if (r.Cancelled) sb.Append('\n').Append(Strings.Translate_SumStopped);
        else if (r.StoppedBecause is { } why) sb.Append('\n').Append(Loc.Format(Strings.Translate_SumStoppedBecause, why));
        if (r.Fonts.Count > 0) sb.Append('\n').Append(Loc.Format(Strings.Translate_SumFonts, string.Join(", ", r.Fonts)));
        if (r.ScanPages.Count > 0) sb.Append('\n').Append(Loc.Format(Strings.Translate_SumScanPages, AiText.PagesText(r.ScanPages)));
        if (r.TurnedTextPages.Count > 0) sb.Append('\n').Append(Loc.Format(Strings.Translate_SumTurnedPages, AiText.PagesText(r.TurnedTextPages)));
        if (r.CrowdedPages.Count > 0) sb.Append('\n').Append(Loc.Format(Strings.Translate_SumCrowdedPages, AiText.PagesText(r.CrowdedPages)));
        if (r.FailedPages.Count > 0) sb.Append('\n').Append(Loc.Format(Strings.Translate_SumFailedPages, AiText.PagesText(r.FailedPages)));
        sb.Append("\n\n").Append(Strings.Translate_SumAiGenerated);
        return sb.ToString();
    }

    internal string DevTranslateState() => $"translating={IsTranslating} {DevSplitState()}" + (_beside is null ? "" : $" beside: main={Viewer.ViewCorner()} second={_second?.ViewCorner()}");
}
