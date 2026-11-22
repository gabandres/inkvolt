using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Search by meaning (roadmap 4.21, Pro): off until the user turns it on and names an embedding model. Before the pages
/// of a folder are embedded the send window shows every one of them (always, whatever was chosen for the endpoint: a
/// folder's text is a lot to send), and a query's own words are shown before they go unless the user chose not to be
/// asked. Core keeps the vectors (<see cref="MeaningIndex"/>, beside each folder index) and finds the nearest pages;
/// this asks, sends and reports.
/// </summary>
internal static class FolderMeaning
{
    /// <summary>The model the embeddings come from while search by meaning is on; null while it is off.</summary>
    public static string? Model => AppSettings.Current.MeaningEnabled && AppSettings.Current.MeaningModel.Trim() is { Length: > 0 } m ? m : null;

    /// <summary>Ollama's own API for the Ollama preset, the OpenAI-compatible one otherwise.</summary>
    public static EmbedApi ApiFor(AiConfig config) => config.IsOllama ? EmbedApi.Ollama : EmbedApi.OpenAi;

    /// <summary>The settings: on or off, and the embedding model. True when saved.</summary>
    public static bool ShowSettings(Window owner)
    {
        if (!ProGate.Check(owner, ProFeature.MeaningSearch)) return false;
        var s = AppSettings.Current;
        var config = AiService.Current(out _);
        var dlg = new FormDialog(owner, Strings.Meaning_Title, Strings.Common_Save, 520);
        dlg.AddNote(Strings.Meaning_Note);
        var on = dlg.AddCheck(Strings.Meaning_TurnOn, s.MeaningEnabled);
        var model = dlg.AddText(Strings.Meaning_Model, s.MeaningModel.Length > 0 ? s.MeaningModel : "nomic-embed-text");
        model.ToolTip = Strings.Meaning_ModelTip;
        dlg.AddNote(config is null ? Strings.Meaning_NeedsAssistant : Loc.Format(Strings.Meaning_Where, config.Endpoint.ReachText));
        dlg.Validate(() => on.IsChecked == true && model.Text.Trim().Length == 0 ? Strings.Meaning_ChooseModel : null);
        if (!dlg.ShowModal()) return false;
        s.MeaningEnabled = on.IsChecked == true;
        s.MeaningModel = model.Text.Trim();
        s.Save();
        return true;
    }

    /// <summary>The assistant's configuration with the embedding model ready, asking for whatever is missing; null when it stays off.</summary>
    public static AiConfig? Ready(Window owner)
    {
        if (!ProGate.Check(owner, ProFeature.MeaningSearch)) return null;
        if (AiService.Current(out var problem) is not { } config)
        {
            if (!AiActions.ShowSettings(owner, Loc.Format(Strings.TabAi_SetUpHere, problem)) || AiService.Current(out _) is not { } now) return null;
            config = now;
        }
        if (Model is null && (!ShowSettings(owner) || Model is null)) return null;
        return config;
    }

    /// <summary>One search by meaning at a time: the folders' indexes are read and written by one.</summary>
    private static readonly SemaphoreSlim Gate = new(1, 1);

    /// <summary>
    /// Brings the folders' meaning indexes up to date (the send window first, listing every page), embeds
    /// <paramref name="query"/> and returns the pages closest to it in each folder, best first (at most
    /// <paramref name="count"/> in all); null when not sent (said through <paramref name="say"/>).
    /// </summary>
    /// <exception cref="OperationCanceledException">Stopped: what was embedded so far is kept.</exception>
    /// <exception cref="AiException">The endpoint refused or failed.</exception>
    public static async Task<IReadOnlyList<(IndexedFolder Folder, MeaningHit Hit)>?> SearchAsync(Window owner, AiConfig config,
        IReadOnlyList<IndexedFolder> folders, string query, int count, Action<string> say, CancellationToken cancel)
    {
        await Gate.WaitAsync(cancel);
        try
        {
            if (await PrepareAsync(owner, config, folders, query, say, cancel) is not { } vector) return null;
            var model = Model ?? "";
            // Every vector of every folder compared: off the window's thread.
            return await Task.Run(() => (IReadOnlyList<(IndexedFolder, MeaningHit)>)[.. folders
                .SelectMany(f => f.MeaningFor(model, config.Endpoint.Key).Nearest(vector, count).Where(h => h.Score > 0).Select(h => (f, h)))
                .OrderByDescending(x => x.h.Score).Take(count)], cancel);
        }
        finally
        {
            Gate.Release();
        }
    }

    private static async Task<float[]?> PrepareAsync(Window owner, AiConfig config, IReadOnlyList<IndexedFolder> folders, string query,
        Action<string> say, CancellationToken cancel)
    {
        var model = Model!;
        var api = ApiFor(config);
        say(Strings.Meaning_Checking);
        var plans = await Task.Run(() => folders.Select(f => (Folder: f, Index: f.MeaningFor(model, config.Endpoint.Key), Pending: f.Indexer?.Index is { } fi
            ? f.MeaningFor(model, config.Endpoint.Key).Pending(fi, cancel) : new MeaningPending([], [], 0))).ToList(), cancel);
        var pieces = plans.Sum(p => p.Pending.Pieces.Count);
        var leftOut = plans.Sum(p => p.Pending.LeftOut);
        var queryRequest = (IReadOnlyList<AiMessage>)[new AiMessage("input", query)];
        var requests = plans.SelectMany(p => p.Pending.Pieces).Chunk(AiEmbeddings.BatchSize)
            .Select(b => (IReadOnlyList<AiMessage>)[.. b.Select(x => new AiMessage("input", x.Text))]).Append(queryRequest).ToList();
        var what = pieces == 0 ? Loc.Format(Strings.Meaning_SentQuery, model)
            : Loc.Format(Strings.Meaning_SentPages, Loc.Plural(plans.Sum(p => p.Pending.Pieces.Select(x => (x.RelativePath, x.Page)).Distinct().Count()), Strings.Folder_Pages_One, Strings.Folder_Pages_Many),
                Loc.Plural(plans.Sum(p => p.Pending.Pieces.Select(x => x.RelativePath).Distinct().Count()), Strings.Folder_Files_One, Strings.Folder_Files_Many), model);
        var listing = plans.SelectMany(p => p.Pending.Listing.Select(line => folders.Count > 1 ? $"{p.Folder.Folder}: {line}" : line)).ToList();
        if (leftOut > 0) listing.Add(Loc.Format(Strings.Meaning_LeftOut, MeaningIndex.MaxEntries));
        var outgoing = new AiOutgoing(requests, what, null) { Listing = listing, OnlyNote = pieces > 0 ? Strings.Meaning_OnlyThis : null };
        if (!AiActions.ConfirmSend(owner, config with { Model = model }, outgoing, false, force: pieces > 0, title: Strings.Meaning_SendTitle))
        {
            say(Strings.TabAi_NotSent);
            return null;
        }
        Log.Write($"AI: embeddings, {pieces} piece(s) and a query, {outgoing.Characters:N0} characters to {config.Endpoint.Host}"); // never the text
        using var client = AiService.CreateClient(config.Endpoint, model);
        var done = 0;
        foreach (var (folder, index, pending) in plans.Where(p => !p.Pending.IsEmpty))
        {
            var path = MeaningIndex.PathFor(FolderIndex.BasePathFor(FolderSearches.IndexDirectory, folder.Folder));
            var before = done;
            var progress = new Progress<int>(n => say(Loc.Format(Strings.Meaning_Embedding, before + n, pieces)));
            try
            {
                var full = await index.UpdateAsync(pending, (texts, ct) => client.EmbedAsync(texts, api, ct), path, progress, cancel);
                if (full > 0) Log.Write($"Search by meaning: a folder's index is full, {full} piece(s) left out");
            }
            catch (AiException ex) when (ex.Message == PdfStrings.Embed_LengthChanged)
            {
                folder.ForgetMeaning();
                throw;
            }
            done += pending.Pieces.Count;
        }
        var vectors = await client.EmbedAsync([query], api, cancel);
        return vectors[0];
    }
}
