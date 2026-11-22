using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Edit › Ask Across Folders (roadmap 4.11, Pro): a question over the indexed folders or a set of PDFs, answered by the
/// user's own AI endpoint. Core picks the pages and passages and reads the answer's citations back
/// (<see cref="FolderAsk"/>, <see cref="FolderIndex.Rank"/>); this asks, shows the send window with every page and file,
/// streams the answer and opens a cited file at its page. A window of its own, not owned by the main one, as Search Folders.
/// </summary>
internal sealed class FolderAskWindow : Window
{
    private static FolderAskWindow? _open;

    private readonly MainWindow _host;
    private readonly RadioButton _inFolders = new() { Content = Strings.FolderAsk_InFolders, IsChecked = true, Margin = new Thickness(0, 0, 16, 0) };
    private readonly RadioButton _inFiles = new() { Content = Strings.FolderAsk_InFiles };
    private readonly Button _choose = new() { Content = Strings.FolderAsk_ChooseFiles, Margin = new Thickness(8, 0, 0, 0), Padding = new Thickness(10, 3, 10, 3) };
    private readonly CheckBox _meaning = new() { Content = Strings.FolderAsk_AlsoMeaning, Margin = new Thickness(0, 6, 0, 0), ToolTip = Strings.FolderAsk_AlsoMeaningTip };
    private readonly TextBlock _filesText = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0) };
    private readonly TextBlock _where = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 0) };
    private readonly TextBox _question = new() { AcceptsReturn = false, TextWrapping = TextWrapping.Wrap, Padding = new Thickness(8, 6, 8, 6) };
    private readonly Button _ask = new() { Content = Strings.Ai_Ask, MinWidth = 88, Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
    private readonly Button _stop = new() { Content = Strings.Common_Stop, MinWidth = 88, Margin = new Thickness(8, 0, 0, 0), Visibility = Visibility.Collapsed };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) };
    private readonly StackPanel _list = new();
    private readonly ScrollViewer _scroll;
    private readonly List<string> _files = [];
    private CancellationTokenSource? _cancel;

    /// <summary>What the last question did, for the dev script.</summary>
    public Task LastAsk { get; private set; } = Task.CompletedTask;

    /// <summary>The last request sent, for the dev script.</summary>
    internal FolderAskRequest? LastRequest { get; private set; }

    public static FolderAskWindow Open(MainWindow host, bool offScreen = false)
    {
        if (_open is { } existing)
        {
            if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal;
            existing.Activate();
            existing._question.Focus();
            return existing;
        }
        var w = new FolderAskWindow(host);
        if (offScreen)
        {
            w.WindowStartupLocation = WindowStartupLocation.Manual;
            w.Left = -20000;
            w.Top = 0;
            w.ShowActivated = false;
        }
        _open = w;
        w.Closed += (_, _) => _open = null;
        w.Show();
        return w;
    }

    private FolderAskWindow(MainWindow host)
    {
        _host = host;
        Title = Strings.FolderAsk_Title;
        Width = Math.Min(820, SystemParameters.WorkArea.Width * 0.9);
        Height = Math.Min(720, SystemParameters.WorkArea.Height * 0.9);
        MinWidth = 480;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SourceInitialized += (_, _) => App.ApplyFrame(this);
        _scroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled };
        Content = Build();
        _ask.Click += (_, _) => Ask();
        _stop.Click += (_, _) => _cancel?.Cancel();
        _choose.Click += (_, _) => ChooseFiles();
        _inFiles.Checked += (_, _) =>
        {
            if (_files.Count == 0) ChooseFiles();
        };
        _meaning.IsChecked = FolderMeaning.Model is not null;
        _meaning.Click += (_, _) =>
        {
            if (_meaning.IsChecked == true && FolderMeaning.Model is null && (!FolderMeaning.ShowSettings(this) || FolderMeaning.Model is null))
                _meaning.IsChecked = false;
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            if (_cancel is not null) _cancel.Cancel();
            else Close();
        };
        Loaded += (_, _) => _question.Focus();
        Closed += (_, _) => _cancel?.Cancel();
        ShowWhere();
        ShowFiles();
    }

    private UIElement Build()
    {
        var caption = (Style)Application.Current.FindResource("Caption");
        var top = new StackPanel();
        top.Children.Add(new TextBlock { Text = Strings.FolderAsk_Title, FontSize = 20, FontWeight = FontWeights.SemiBold });
        top.Children.Add(new TextBlock { Text = Strings.FolderAsk_Intro, Style = caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 10) });

        var scope = new WrapPanel();
        scope.Children.Add(_inFolders);
        scope.Children.Add(_inFiles);
        scope.Children.Add(_choose);
        AutomationProperties.SetName(scope, Strings.FolderAsk_AskIn);
        top.Children.Add(scope);
        top.Children.Add(_meaning);
        _filesText.Style = caption;
        top.Children.Add(_filesText);
        _where.Style = caption;
        top.Children.Add(_where);

        AutomationProperties.SetName(_question, Strings.FolderAsk_Question);
        Placeholder.SetText(_question, Strings.FolderAsk_Placeholder);
        _ask.SetResourceReference(StyleProperty, "AccentButtonStyle");
        var row = new DockPanel { Margin = new Thickness(0, 12, 0, 0) };
        DockPanel.SetDock(_stop, Dock.Right);
        DockPanel.SetDock(_ask, Dock.Right);
        row.Children.Add(_stop);
        row.Children.Add(_ask);
        row.Children.Add(_question);
        top.Children.Add(row);
        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        _status.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");
        top.Children.Add(_status);

        AutomationProperties.SetName(_list, Strings.FolderAsk_Answers);
        var body = new DockPanel { Margin = new Thickness(24, 18, 24, 12) };
        DockPanel.SetDock(top, Dock.Top);
        body.Children.Add(top);
        body.Children.Add(_scroll);

        var close = new Button { Content = Strings.Common_Close, MinWidth = 104 };
        close.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(24, 12, 24, 12) };
        buttons.Children.Add(close);
        var footer = new Border { Child = buttons, BorderThickness = new Thickness(0, 1, 0, 0) };
        footer.SetResourceReference(Border.BackgroundProperty, "LayerFillColorDefaultBrush");
        footer.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(body);
        return root;
    }

    private void ShowWhere()
    {
        var config = AiService.Current(out var problem);
        _where.Text = config is null ? problem ?? Strings.Ai_NotSetUp : $"{config.Model} · {config.Endpoint.ReachText}"; // only names and values
    }

    private void ShowFiles()
    {
        _filesText.Text = _files.Count == 0 ? Strings.FolderAsk_NoFiles
            : Loc.Plural(_files.Count, Strings.FolderAsk_FilesChosen_One, Strings.FolderAsk_FilesChosen_Many, string.Join(", ", _files.Take(5).Select(Path.GetFileName)) + (_files.Count > 5 ? ", …" : ""));
        _filesText.Visibility = _inFiles.IsChecked == true || _files.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
    }

    private void ChooseFiles()
    {
        var dlg = new Microsoft.Win32.OpenFileDialog { Title = Strings.FolderAsk_ChooseFiles, Filter = PdfFiles.PdfFilter, Multiselect = true, InitialDirectory = AppSettings.Current.LastFolder };
        if (dlg.ShowDialog(this) == true) SetFiles(dlg.FileNames);
        else if (_files.Count == 0) _inFolders.IsChecked = true;
        ShowFiles();
    }

    internal void DevMeaning(bool on) => _meaning.IsChecked = on;

    internal void SetFiles(IEnumerable<string> paths)
    {
        _files.Clear();
        _files.AddRange(paths);
        _inFiles.IsChecked = _files.Count > 0;
        _inFolders.IsChecked = _files.Count == 0;
        ShowFiles();
    }

    private void Ask()
    {
        var q = _question.Text.Trim();
        if (q.Length == 0 || _cancel is not null) return;
        LastAsk = AskAsync(q);
    }

    private void SetBusy(bool busy)
    {
        _stop.Visibility = busy ? Visibility.Visible : Visibility.Collapsed;
        _ask.IsEnabled = !busy;
    }

    private void Say(string text)
    {
        _status.Text = text;
        AiActions.Announce(_status, text);
    }

    private async Task AskAsync(string question)
    {
        if (!ProGate.Check(this, ProFeature.FolderAsk)) return;
        if (AiService.Current(out var problem) is not { } config)
        {
            if (!AiActions.ShowSettings(this, Loc.Format(Strings.TabAi_SetUpHere, problem)) || AiService.Current(out _) is not { } now) return;
            config = now;
            ShowWhere();
        }
        var inFiles = _inFiles.IsChecked == true;
        if (inFiles && _files.Count == 0)
        {
            Say(Strings.FolderAsk_ChooseFilesFirst);
            return;
        }
        var folders = FolderSearches.All.Where(f => f.Indexer?.Index is not null).ToList();
        if (!inFiles && folders.Count == 0)
        {
            Say(FolderSearches.All.Count == 0 ? Strings.Folder_NoneIndexed : Strings.Folder_NotOpenYet);
            return;
        }

        using var cts = new CancellationTokenSource();
        _cancel = cts;
        SetBusy(true);
        try
        {
            if (config.IsOllama)
            {
                Say(Strings.TabAi_AskingOllama);
                config = await AiService.ResolveAsync(config, cts.Token);
            }
            Say(inFiles ? Strings.FolderAsk_ReadingFiles : Strings.FolderAsk_ReadingIndex);
            var files = _files.ToList();
            var notes = new List<string>();
            var pages = await Task.Run(() => inFiles ? FromFiles(files, notes, cts.Token) : FromFolders(folders, question, notes, cts.Token), cts.Token);
            if (_meaning.IsChecked == true && inFiles) notes.Add(Strings.FolderAsk_MeaningFoldersOnly);
            else if (_meaning.IsChecked == true)
            {
                // The pages closest in meaning join those sharing the question's words (their embeddings shown before they go).
                if (FolderMeaning.Ready(this) is null || await FolderMeaning.SearchAsync(this, config, folders, question, MeaningPages, Say, cts.Token) is not { } hits)
                {
                    Say(Strings.TabAi_NotSent);
                    return;
                }
                pages = await Task.Run(() => WithMeaning(pages, hits, cts.Token), cts.Token);
            }
            var request = FolderAsk.Build(question, pages, config.InputTokens);
            if (request is null)
            {
                Say(string.Join(" ", notes.Prepend(pages.Count == 0 ? Strings.FolderAsk_NoText : Strings.FolderAsk_NothingRelated)));
                return;
            }
            LastRequest = request;
            Say(Strings.FolderAsk_CheckingPermissions);
            var restricted = await Task.Run(() => request.Sources.Where(s => Restricted(s.Path)).Select(s => s.Name).ToList(), cts.Token);
            var listing = FolderAsk.SentList(request).ToList();
            if (restricted.Count > 0) listing.Add(Loc.Format(Strings.FolderAsk_RestrictedFiles, string.Join(", ", restricted)));
            var what = Loc.Format(request.Trimmed ? Strings.FolderAsk_SentTrimmed : Strings.FolderAsk_Sent,
                Loc.Plural(request.Pages.Count, Strings.Folder_Pages_One, Strings.Folder_Pages_Many),
                Loc.Plural(request.Sources.Count, Strings.Folder_Files_One, Strings.Folder_Files_Many));
            if (!AiActions.ConfirmSend(this, config, new AiOutgoing([request.Messages], what, null) { Listing = listing, OnlyNote = Strings.FolderAsk_OnlyThis }, restricted.Count > 0))
            {
                Say(Strings.TabAi_NotSent);
                return;
            }

            AddQuestion(question);
            var sent = request;
            var card = new AiAnswerCard(config.Model, text => Links(text, sent), ScrollToEnd, null);
            _list.Children.Add(card);
            ScrollToEnd();
            Say(Loc.Format(Strings.TabAi_Sending, config.Endpoint.Host));
            Log.Write($"AI: ask across files, {request.Pages.Count} page(s) of {request.Sources.Count} file(s), {request.Messages.Sum(m => m.Content.Length):N0} characters to {config.Endpoint.Host}"); // never the text
            var finished = false;
            try
            {
                using var client = AiService.CreateClient(config);
                var reply = await client.ChatAsync(request.Messages, piece => Dispatcher.BeginInvoke(() => { if (!finished) card.Append(piece); }), cts.Token);
                await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background);
                finished = true;
                var answer = AiText.WithoutThinking(reply.Text, out _).Trim();
                var note = reply.WasCutOff ? Strings.TabAi_CutOff : answer.Length == 0 ? Strings.TabAi_EmptyAnswer : null;
                if (notes.Count > 0) note = string.Join(" ", notes.Prepend(note ?? "").Where(n => n.Length > 0));
                card.Finish(answer, note);
                Say(Strings.TabAi_AnswerReady);
            }
            catch (OperationCanceledException)
            {
                finished = true;
                card.Finish(null, Strings.TabAi_Stopped);
                throw;
            }
            catch (AiException ex)
            {
                finished = true;
                Log.Write($"AI: ask across files to {config.Endpoint.Host} failed"); // not the message: a server may echo text back
                card.Finish(null, ex.Message, error: true);
                Say(ex.Message);
            }
        }
        catch (OperationCanceledException)
        {
            Say(Strings.TabAi_Stopped);
        }
        catch (AiException ex)
        {
            Say(ex.Message);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Ask across folders failed: {ex.GetType().Name}");
            Say(Loc.Format(Strings.Folder_SearchError, ex.Message));
        }
        finally
        {
            _cancel = null;
            SetBusy(false);
        }
    }

    /// <summary>The pages the folders' indexes propose for the question, best first, with their text.</summary>
    private static List<FolderAskPage> FromFolders(List<IndexedFolder> folders, string question, List<string> notes, CancellationToken cancel)
    {
        var words = FolderAsk.Words(question);
        var ranked = new List<(IndexedFolder Folder, RankedPage Page)>();
        foreach (var folder in folders)
        {
            if (folder.Indexer?.Index is not { } index) continue;
            try
            {
                ranked.AddRange(index.Rank(words, FolderAsk.MaxCandidatePages, cancel).Select(r => (folder, r)));
            }
            catch (FolderIndexDamagedException)
            {
                folder.Indexer?.Rebuild();
                notes.Add(Loc.Format(Strings.Folder_Damaged, folder.Folder));
            }
            catch (ObjectDisposedException)
            {
            }
        }
        var pages = new List<FolderAskPage>();
        foreach (var group in ranked.OrderByDescending(r => r.Page.Words).Take(FolderAsk.MaxCandidatePages).GroupBy(r => r.Folder))
        {
            if (group.Key.Indexer?.Index is not { } index) continue;
            try
            {
                var chosen = group.Select(r => (r.Page.RelativePath, r.Page.Page)).ToList();
                var texts = index.PageTexts(chosen, cancel);
                for (var i = 0; i < chosen.Count; i++)
                    pages.Add(new FolderAskPage(Path.Combine(group.Key.Folder, chosen[i].RelativePath), chosen[i].RelativePath, chosen[i].Page, texts[i]));
            }
            catch (FolderIndexDamagedException)
            {
                group.Key.Indexer?.Rebuild();
                notes.Add(Loc.Format(Strings.Folder_Damaged, group.Key.Folder));
            }
            catch (ObjectDisposedException)
            {
            }
        }
        if (FolderSearches.All.Any(f => f.Indexer?.Status.Phase is IndexerPhase.Indexing or IndexerPhase.Scanning)) notes.Add(Strings.Folder_StillIndexing);
        return pages;
    }

    /// <summary>Pages closest in meaning brought to a question by search by meaning.</summary>
    private const int MeaningPages = 30;

    /// <summary>The pages with their closeness in meaning: those already proposed get it, the others are read and added.</summary>
    private static List<FolderAskPage> WithMeaning(List<FolderAskPage> pages, IReadOnlyList<(IndexedFolder Folder, MeaningHit Hit)> hits, CancellationToken cancel)
    {
        var byPage = pages.Select((p, i) => (p, i)).ToDictionary(x => (x.p.Path.ToUpperInvariant(), x.p.Page), x => x.i);
        var result = pages.ToList();
        foreach (var group in hits.GroupBy(h => h.Folder))
        {
            var missing = new List<(string RelativePath, int Page, double Score)>();
            foreach (var (_, hit) in group)
            {
                var path = Path.Combine(group.Key.Folder, hit.RelativePath);
                if (byPage.TryGetValue((path.ToUpperInvariant(), hit.Page), out var at)) result[at] = result[at] with { Meaning = hit.Score };
                else missing.Add((hit.RelativePath, hit.Page, hit.Score));
            }
            if (missing.Count == 0 || group.Key.Indexer?.Index is not { } index) continue;
            var texts = index.PageTexts([.. missing.Select(m => (m.RelativePath, m.Page))], cancel);
            for (var i = 0; i < missing.Count; i++)
                result.Add(new FolderAskPage(Path.Combine(group.Key.Folder, missing[i].RelativePath), missing[i].RelativePath, missing[i].Page, texts[i]) { Meaning = missing[i].Score });
        }
        return result;
    }

    private static List<FolderAskPage> FromFiles(List<string> files, List<string> notes, CancellationToken cancel)
    {
        var read = FolderAsk.ReadFiles(files, FolderAsk.MaxFilePages, cancel);
        string Names(IReadOnlyList<string> paths) => string.Join(", ", paths.Select(Path.GetFileName));
        if (read.NeedPassword.Count > 0) notes.Add(Loc.Format(Strings.FolderAsk_NeedPassword, Names(read.NeedPassword)));
        if (read.Unreadable.Count > 0) notes.Add(Loc.Format(Strings.FolderAsk_Unreadable, Names(read.Unreadable)));
        if (read.NotAllRead.Count > 0) notes.Add(Loc.Format(Strings.FolderAsk_NotAllRead, FolderAsk.MaxFilePages, Names(read.NotAllRead)));
        return [.. read.Pages];
    }

    /// <summary>The PDF forbids copying its text, or its permissions can't be read (then asked about as if it did).</summary>
    private static bool Restricted(string path)
    {
        try
        {
            if (new FileInfo(path).Length > 512L << 20) return true;
            return FolderAsk.CopyRestricted(File.ReadAllBytes(path));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    private IEnumerable<AnswerLink> Links(string text, FolderAskRequest request) =>
        FolderAsk.Citations(text, request).Select(c => new AnswerLink(c.Start, c.Length, Loc.Format(Strings.FolderAsk_OpenAt, c.Source.Name, c.Page + 1),
            () => _ = _host.OpenAtPage(c.Source.Path, c.Page)));

    private void AddQuestion(string text)
    {
        var bubble = new Border
        {
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 6, 10, 6),
            Margin = new Thickness(40, 10, 0, 4),
            HorizontalAlignment = HorizontalAlignment.Right,
            Child = new TextBlock { Text = text, TextWrapping = TextWrapping.Wrap },
        };
        bubble.SetResourceReference(BackgroundProperty, "SubtleFillColorSecondaryBrush");
        AutomationProperties.SetName(bubble, Loc.Format(Strings.Ai_You, text));
        _list.Children.Add(bubble);
    }

    private void ScrollToEnd() => Dispatcher.BeginInvoke(() => _scroll.ScrollToEnd(), DispatcherPriority.Background);

    // ---- The dev script ----

    internal async Task<string> DevAsk(string question)
    {
        _question.Text = question;
        Ask();
        await LastAsk;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background);
        return DevState();
    }

    internal string DevState()
    {
        var card = _list.Children.OfType<AiAnswerCard>().LastOrDefault();
        var sent = LastRequest is { } r ? string.Join(" | ", FolderAsk.SentList(r)) : "";
        return $"folderask: status '{_status.Text}'; sent [{sent}]; answer {card?.DevText ?? "none"}";
    }

    /// <summary>Clicks the last answer's link <paramref name="index"/>.</summary>
    internal bool DevOpenLink(int index)
    {
        if (_list.Children.OfType<AiAnswerCard>().LastOrDefault()?.LinkList is not { } links || index >= links.Count) return false;
        links[index].RaiseEvent(new RoutedEventArgs(System.Windows.Documents.Hyperlink.ClickEvent));
        return true;
    }
}
