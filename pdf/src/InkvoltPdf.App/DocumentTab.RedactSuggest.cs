using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>What Suggest Redactions was asked for: the kinds the AI assistant looks for, the user's description, the list, the pages.</summary>
public sealed record RedactSuggestPlan(SuggestKinds Kinds, string? Description, bool UseTerms, int[] Pages)
{
    public bool AsksAi => Kinds != SuggestKinds.None || RedactionSuggestions.CleanDescription(Description).Length > 0;
}

/// <summary>
/// Suggest Redactions (roadmap 4.10, Pro): the user's own AI endpoint proposes what to redact by meaning, and the user's
/// names and terms list adds its own; the proposals go into Redact by Pattern's review list, then apply, read-back, check
/// and report as for patterns (<see cref="ReviewAndRedact"/>). Core decides what a proposal is and whether the text holds
/// it (<see cref="RedactionSuggestions"/>); this only asks, shows and passes on. Nothing is sent unless the assistant is on
/// and the user chose a kind, and the send window always shows what goes and where.
/// </summary>
public partial class DocumentTab
{
    /// <summary>What the last suggestions kept and left out, for the developer script.</summary>
    internal RedactionSuggestResult? LastSuggestion { get; private set; }

    public async Task<bool> SuggestRedactions(RedactSuggestPlan plan)
    {
        if (!Session.IsPdf || _disposed || Window.GetWindow(this) is not { } owner) return false;
        var proposals = new List<RedactionProposal>();
        var notes = new List<string>();
        LastSuggestion = null;
        if (plan.AsksAi && AiService.IsEnabled)
        {
            if (await AskForSuggestions(owner, plan, notes) is not { } result) return false;
            LastSuggestion = result;
            proposals.AddRange(result.Kept);
            if (result.Dropped > 0) notes.Add(Loc.Plural(result.Dropped, Strings.Redact_SuggestDropped_One, Strings.Redact_SuggestDropped_Many));
            if (result.Unreadable > 0) notes.Add(Loc.Plural(result.Unreadable, Strings.Redact_SuggestUnreadable_One, Strings.Redact_SuggestUnreadable_Many));
        }
        if (plan.UseTerms) proposals.AddRange(RedactionTerms.AsProposals(RedactionTerms.Load(RedactSuggestActions.TermsPath)));
        var note = notes.Count > 0 ? string.Join(" ", notes) : null;
        if (proposals.Count == 0)
        {
            Notify(note is null ? Strings.Redact_SuggestNothing : Strings.Redact_SuggestNothing + " " + note);
            return false;
        }

        var options = RedactionSuggestions.SearchOptions(proposals, plan.Pages);
        if (await SearchPatterns(options) is not { } found) return false;
        found = RedactionSuggestions.Label(found, proposals);
        if (found.Hits.Count == 0 && found.Looks.Count == 0)
        {
            Notify(Strings.Review_NothingMatching);
            return false;
        }
        return await ReviewAndRedact(options, found, note);
    }

    /// <summary>
    /// The pages' text to the user's model, shown first in the send window (always, whatever was chosen for this
    /// endpoint: this is the text the user wants kept private), then its proposals read and checked against that text.
    /// Null when not sent, stopped or failed (said in the assistant's pane or a message).
    /// </summary>
    private async Task<RedactionSuggestResult?> AskForSuggestions(Window owner, RedactSuggestPlan plan, List<string> notes)
    {
        if (await AiPrepare() is not { } config) return null;
        var texts = await AiReadPages(plan.Pages);
        if (texts is null) return null;
        var requests = RedactionSuggestions.Requests(texts, plan.Kinds, plan.Description, config.InputTokens);
        if (requests.Count == 0)
        {
            // Scans without text: nothing to send; the search after reads them through recognition, and the list says so.
            notes.Add(Loc.Plural(plan.Pages.Length, Strings.Redact_SuggestNoText_One, Strings.Redact_SuggestNoText_Many, AiText.PagesText(plan.Pages)));
            return new RedactionSuggestResult([], 0, 0);
        }
        var restricted = await AiActions.IsCopyRestrictedAsync(Session);
        if (_disposed) return null;
        var outgoing = new AiOutgoing([.. requests.Select(r => r.Messages)], Loc.Format(Strings.Redact_SuggestSent, AiText.PagesText(plan.Pages)), null);
        if (!AiActions.ConfirmSend(owner, config, outgoing, restricted, force: true, title: Strings.Redact_SuggestSendTitle))
        {
            _aiPane!.ShowStatus(Strings.TabAi_NotSent);
            return null;
        }

        using var prompt = new ProgressPrompt(owner, Strings.Redact_SuggestTitle, Loc.Format(Strings.TabAi_Sending, config.Endpoint.Host));
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(prompt.Token);
        _aiCancel = cts;
        _aiPane!.SetBusy(true);
        _aiPane.ShowStatus(Loc.Format(Strings.TabAi_Sending, config.Endpoint.Host));
        RaiseState();
        Log.Write($"AI: redaction suggestions, {requests.Count} request(s), {outgoing.Characters:N0} characters to {config.Endpoint.Host}"); // never the text
        try
        {
            using var client = AiService.CreateClient(config);
            var result = await RedactionSuggestions.SuggestAsync(requests, async (messages, step, ct) =>
            {
                var what = step.Total > 1 ? Loc.Format(Strings.TabAi_StepOf, step.What, step.Index, step.Total) : Loc.Format(Strings.TabAi_Step, step.What);
                prompt.Report(what, (double)(step.Index - 1) / step.Total);
                _aiPane.ShowStatus(what);
                var reply = await client.ChatAsync(messages, null, ct);
                return reply.Text;
            }, cts.Token);
            _aiPane.ShowStatus(Loc.Plural(result.Kept.Count, Strings.Redact_SuggestDone_One, Strings.Redact_SuggestDone_Many));
            return result;
        }
        catch (OperationCanceledException)
        {
            _aiPane.ShowStatus(Strings.TabAi_Stopped);
            return null;
        }
        catch (AiException ex)
        {
            Log.Write($"AI: redaction suggestions from {config.Endpoint.Host} failed"); // not the message: a server may echo text back
            _aiPane.ShowStatus(ex.Message);
            Prompt.Error(owner, Strings.Redact_SuggestFailed, ex.Message);
            return null;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Log.Write($"AI: redaction suggestions from {config.Endpoint.Host} failed unexpectedly: {ex.GetType().Name}");
            var message = Loc.Format(Strings.TabAi_Unexpected, config.Endpoint.Host, ex.GetType().Name);
            _aiPane.ShowStatus(message);
            Prompt.Error(owner, Strings.Redact_SuggestFailed, message);
            return null;
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
}
