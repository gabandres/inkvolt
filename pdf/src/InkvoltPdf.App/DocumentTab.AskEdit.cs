using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Edit by Asking (roadmap 4.23, free): a request in the person's words goes to their own AI endpoint with a few of the
/// command palette's commands as tools (<see cref="AskEdit"/>: only the request, the page count and the page in view go,
/// shown first in the send window). The steps it proposes are listed, checked, for the person to untick; nothing runs
/// until they press Run, and each edit is one undo step. Page numbers follow the pages a step before deleted.
/// </summary>
public partial class DocumentTab
{
    /// <summary>What the last Edit by Asking proposed and did, for the dev script.</summary>
    internal string LastAskEdit { get; private set; } = "none";

    /// <summary>Asks for the request (unless given), sends it, shows the steps and runs those the person keeps.</summary>
    public async Task AskEditAsync(string? request = null)
    {
        if (!Session.IsPdf || _disposed || Window.GetWindow(this) is not { } owner || Viewer.PageCount == 0) return;
        request ??= AskEditRequest(owner);
        if (request is null) return;
        if (await AiPrepare() is not { } config) return;
        var pageCount = Viewer.PageCount;
        var messages = AskEdit.Messages(request, pageCount, ActiveView.CurrentPage);
        var outgoing = new AiOutgoing([messages], Strings.AskEdit_Sent, null)
        {
            PreviewText = () => AiPrompts.Preview([messages]) + "\n── tools ──\n" + AskEdit.ToolsJson.Trim() + "\n",
            OnlyNote = Strings.AskEdit_OnlyThis,
        };
        if (!AiActions.ConfirmSend(owner, config, outgoing, copyRestricted: false, title: Strings.AskEdit_SendTitle))
        {
            _aiPane!.ShowStatus(Strings.TabAi_NotSent);
            return;
        }

        AskEditPlan plan;
        using (var cts = new CancellationTokenSource())
        {
            _aiCancel = cts;
            _aiPane!.SetBusy(true);
            _aiPane.ShowStatus(Loc.Format(Strings.TabAi_Sending, config.Endpoint.Host));
            RaiseState();
            Log.Write($"AI: edit by asking, {outgoing.Characters:N0} characters to {config.Endpoint.Host}"); // never the text
            try
            {
                using var client = AiService.CreateClient(config);
                plan = await client.AskEditAsync(messages, pageCount, cts.Token);
            }
            catch (OperationCanceledException)
            {
                _aiPane.ShowStatus(Strings.TabAi_Stopped);
                return;
            }
            catch (AiException ex)
            {
                Log.Write($"AI: edit by asking to {config.Endpoint.Host} failed"); // not the message: a server may echo text back
                _aiPane.ShowStatus(ex.Message);
                LastAskEdit = $"failed: {ex.Message}";
                Prompt.Error(owner, Strings.AskEdit_Title, ex.Message);
                return;
            }
            finally
            {
                _aiCancel = null;
                if (!_disposed)
                {
                    _aiPane.SetBusy(false);
                    RaiseState();
                }
            }
        }
        _aiPane.ShowStatus(null);
        LastAskEdit = $"proposed [{string.Join(" | ", plan.Steps.Select(s => s.Describe()))}] refused [{string.Join(" | ", plan.Refused)}] said '{plan.Said}'";
        if (_disposed || pageCount != Viewer.PageCount) return; // the document changed meanwhile: the steps' pages no longer hold
        if (plan.Steps.Count == 0)
        {
            var why = new List<string> { Strings.AskEdit_NoSteps };
            why.AddRange(plan.Refused);
            if (plan.Said is { } said) why.Add(Loc.Format(Strings.AskEdit_ModelSaid, said));
            Prompt.Info(owner, Strings.AskEdit_Title, string.Join("\n\n", why));
            return;
        }
        if (ChooseAskEditSteps(owner, plan) is not { Count: > 0 } chosen) return;
        await RunAskEditSteps(chosen);
    }

    private static string? AskEditRequest(Window owner)
    {
        var dlg = new FormDialog(owner, Strings.AskEdit_Title, Strings.Common_Next, 520);
        dlg.AddNote(Strings.AskEdit_Intro);
        var box = dlg.AddText(Strings.AskEdit_Request);
        box.MaxLength = AskEdit.MaxRequestChars;
        Placeholder.SetText(box, Strings.AskEdit_Placeholder);
        dlg.AddNote(Strings.AskEdit_WhatGoes);
        dlg.Validate(() => box.Text.Trim().Length == 0 ? Strings.AskEdit_TypeRequest : null);
        return dlg.ShowModal() ? box.Text.Trim() : null;
    }

    /// <summary>The proposed steps, each ticked, for the person to keep or untick; null when cancelled.</summary>
    private static List<AskEditStep>? ChooseAskEditSteps(Window owner, AskEditPlan plan)
    {
        var dlg = new FormDialog(owner, Strings.AskEdit_StepsTitle, Strings.AskEdit_Run, 560);
        dlg.AddNote(Strings.AskEdit_StepsNote);
        var boxes = plan.Steps.Select((s, i) => (Step: s, Box: dlg.AddCheck(Loc.Format(Strings.AskEdit_StepLine, i + 1, s.Describe()), true))).ToList();
        foreach (var why in plan.Refused) dlg.AddNote(why).SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCautionBrush");
        if (plan.Said is { } said) dlg.AddNote(Loc.Format(Strings.AskEdit_ModelSaid, said)).FontStyle = FontStyles.Italic;
        dlg.Validate(() => boxes.Any(b => b.Box.IsChecked == true) ? null : Strings.AskEdit_TickOne);
        return dlg.ShowModal() ? [.. boxes.Where(b => b.Box.IsChecked == true).Select(b => b.Step)] : null;
    }

    /// <summary>Runs the steps in order, each edit its own undo step, the pages of later steps following pages deleted before them.</summary>
    private async Task RunAskEditSteps(IReadOnlyList<AskEditStep> steps)
    {
        var deleted = new List<int>(); // pages of the document as it was asked about
        var done = 0;
        var notes = new List<string>();
        foreach (var original in steps)
        {
            if (_disposed) return;
            if (AskEdit.AfterDelete(original, deleted) is not { } step)
            {
                notes.Add(Loc.Format(Strings.AskEdit_SkippedGone, original.Describe()));
                continue;
            }
            var ok = true;
            switch (step.Kind)
            {
                case AskEditKind.GoToPage:
                    SetOrganizing(false);
                    ActiveView.GoToPage(Math.Clamp(step.Pages[0], 0, Math.Max(0, Viewer.PageCount - 1)));
                    break;
                case AskEditKind.RotatePages:
                {
                    var pages = step.Pages.Where(p => p < Viewer.PageCount).ToArray();
                    var degrees = step.Degrees == 270 ? -90 : step.Degrees;
                    ok = pages.Length > 0 && await RunEdit(Loc.Plural(pages.Length, Strings.Organize_EditRotate_One, Strings.Organize_EditRotate_Many),
                        (d, pw) => PageEditor.Rotate(d, pw, pages, degrees));
                    break;
                }
                case AskEditKind.DeletePages:
                {
                    var pages = step.Pages.Where(p => p < Viewer.PageCount).ToArray();
                    if (pages.Length == 0 || pages.Length >= Viewer.PageCount)
                    {
                        notes.Add(Loc.Format(Strings.AskEdit_SkippedAll, step.Describe()));
                        continue;
                    }
                    ok = await RunEdit(Loc.Plural(pages.Length, Strings.Organize_EditDelete_One, Strings.Organize_EditDelete_Many),
                        (d, pw) => PageEditor.Delete(d, pw, pages), pages.Min());
                    if (ok) deleted.AddRange(original.Pages.Where(p => !deleted.Contains(p)));
                    break;
                }
                case AskEditKind.AddBookmark:
                {
                    var (title, page) = (step.Text, step.Pages[0]);
                    ok = await RunEdit(Strings.AskEdit_BookmarkUndo,
                        (d, pw) => Bookmarks.SetOutline(d, pw, [.. Bookmarks.Read(d, pw), new Bookmark(title, page)]), contentOnly: true);
                    break;
                }
                case AskEditKind.HighlightText:
                    ok = await HighlightEvery(step.Text, notes);
                    break;
                case AskEditKind.FindForRedaction:
                    // Redact by Pattern's own review list: nothing is removed unless the person accepts it there.
                    ok = await RedactByPattern(new RedactionPatternOptions
                    {
                        Patterns = step.Patterns,
                        Phrases = step.Text.Length > 0 ? [step.Text] : [],
                    });
                    break;
            }
            if (ok) done++;
            else notes.Add(Loc.Format(Strings.AskEdit_StepNotDone, step.Describe()));
        }
        LastAskEdit += $"; ran {done} of {steps.Count}" + (notes.Count > 0 ? $": {string.Join(" ", notes)}" : "");
        Notify(string.Join(" ", notes.Prepend(Loc.Plural(done, Strings.AskEdit_Done_One, Strings.AskEdit_Done_Many))));
    }

    /// <summary>Every place <paramref name="text"/> is (Find's way: any case), highlighted as comments in one undo step.</summary>
    private async Task<bool> HighlightEvery(string text, List<string> notes)
    {
        var engine = Viewer.Engine;
        if (engine is null) return false;
        var hits = await Task.Run(() => engine.FindAll(text, false, false)
            .Where(m => m.Text is not null)
            .SelectMany(m => m.Hits.Select(h => new HitToMark(m.Page, m.Text!.GetRects(h.Start, h.End))))
            .ToList());
        if (_disposed) return false;
        if (hits.Count == 0)
        {
            notes.Add(Loc.Format(Strings.AskEdit_NotFound, text));
            return true; // nothing to do is done
        }
        var author = Author;
        return await TryEdit(Loc.Plural(hits.Count, Strings.Marks_Highlight_One, Strings.Marks_Highlight_Many),
            (d, pw) => SearchMarks.Apply(d, pw, hits, TextMarkupKind.Highlight, author).Data, contentOnly: true) is EditOutcome.Done or EditOutcome.NoChange;
    }
}
