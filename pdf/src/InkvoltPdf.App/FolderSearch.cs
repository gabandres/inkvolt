using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Markup;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// The folders indexed in the app (Edit › Search Folders): kept in the settings, kept current while Inkvolt PDF is open and stopped
/// when it closes. Each has its own index file in the data folder's "FolderIndex"; nothing is written anywhere else.
/// </summary>
internal static class FolderSearches
{
    public static ObservableCollection<IndexedFolder> All { get; } = [];

    /// <summary>A folder's state changed (on any thread).</summary>
    public static event Action? Changed;

    public static void RaiseChanged() => Changed?.Invoke();

    /// <summary>Dev runs without their own data folder must not touch the user's: settings stay read-only then, and the index goes to the temp folder.</summary>
    public static string IndexDirectory => AppSettings.ReadOnly
        ? Path.Combine(Path.GetTempPath(), "InkvoltPdfDevFolderIndex")
        : Path.Combine(AppPaths.DataDirectory, "FolderIndex");

    public static void StartSaved()
    {
        foreach (var setting in AppSettings.Current.IndexedFolders)
        {
            var folder = new IndexedFolder(setting);
            All.Add(folder);
            folder.Start();
        }
        RaiseChanged();
    }

    /// <summary>What is wrong with indexing <paramref name="folder"/>, or null.</summary>
    public static string? Validate(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Path.IsPathFullyQualified(folder)) return "Choose a folder.";
        if (!Directory.Exists(folder)) return $"There is no folder {folder}.";
        var full = WithSeparator(folder);
        foreach (var other in All)
        {
            var known = WithSeparator(other.Folder);
            if (string.Equals(known, full, StringComparison.OrdinalIgnoreCase)) return "That folder is indexed already.";
            if (full.StartsWith(known, StringComparison.OrdinalIgnoreCase)) return $"That folder is inside {other.Folder}, which is indexed already.";
            if (known.StartsWith(full, StringComparison.OrdinalIgnoreCase)) return $"{other.Folder}, indexed already, is inside that folder. Remove it first, then add the larger one.";
        }
        return null;
    }

    private static string WithSeparator(string folder) => Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)) + Path.DirectorySeparatorChar;

    public static IndexedFolder Add(string folder)
    {
        var setting = new AppSettings.IndexedFolderSetting { Folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)) };
        AppSettings.Current.IndexedFolders.Add(setting);
        AppSettings.Current.Save();
        var added = new IndexedFolder(setting);
        All.Add(added);
        added.Start();
        RaiseChanged();
        return added;
    }

    /// <summary>Stops indexing the folder and deletes its index file. Its PDFs aren't touched.</summary>
    public static void Remove(IndexedFolder folder)
    {
        All.Remove(folder);
        AppSettings.Current.IndexedFolders.Remove(folder.Setting);
        AppSettings.Current.Save();
        folder.RemoveIndex();
        RaiseChanged();
    }

    /// <summary>Closing the app: ends the workers and commits what was read, briefly.</summary>
    public static void StopAll()
    {
        foreach (var f in All) f.Stop(TimeSpan.Zero);
        var until = DateTime.UtcNow.AddSeconds(5);
        foreach (var f in All) f.Stop(until - DateTime.UtcNow is { Ticks: > 0 } left ? left : TimeSpan.Zero);
    }
}

/// <summary>One folder in the app: its setting and its indexer.</summary>
internal sealed class IndexedFolder(AppSettings.IndexedFolderSetting setting)
{
    private FolderIndexer? _indexer;

    public AppSettings.IndexedFolderSetting Setting { get; } = setting;

    public string Folder => Setting.Folder;

    public FolderIndexer? Indexer => _indexer;

    public bool IsPaused => Setting.Paused;

    public string StatusText => _indexer?.Status.Text ?? (Pro.Allows(ProFeature.FolderSearch) ? "Stopped." : Pro.Locked(ProFeature.FolderSearch));

    /// <summary>Starts indexing, paused if it was left so. Locked: nothing runs, and the index file stays for when a key is back.</summary>
    public void Start()
    {
        if (_indexer is not null || !Pro.Allows(ProFeature.FolderSearch)) return;
        var indexer = new FolderIndexer(Folder, FolderIndex.BasePathFor(FolderSearches.IndexDirectory, Folder), new FolderIndexerOptions(), Setting.Paused);
        indexer.Changed += FolderSearches.RaiseChanged;
        _indexer = indexer;
        indexer.Start();
    }

    public void SetPaused(bool paused)
    {
        Setting.Paused = paused;
        AppSettings.Current.Save();
        if (paused) _indexer?.Pause();
        else _indexer?.Resume();
        FolderSearches.RaiseChanged();
    }

    public void Stop(TimeSpan wait) => _indexer?.Stop(wait);

    public void RemoveIndex()
    {
        var indexer = _indexer ?? new FolderIndexer(Folder, FolderIndex.BasePathFor(FolderSearches.IndexDirectory, Folder));
        _indexer = null;
        indexer.Changed -= FolderSearches.RaiseChanged;
        // Off this thread: a worker may need a moment to end.
        Task.Run(() =>
        {
            indexer.StopAndDelete(TimeSpan.FromSeconds(10));
            indexer.Dispose();
        });
    }
}

/// <summary>One page in the results list.</summary>
internal sealed class FolderResult(string folder, FolderHit hit)
{
    public string FullPath { get; } = Path.Combine(folder, hit.RelativePath);
    public string Name { get; } = Path.GetFileName(hit.RelativePath);
    public int Page { get; } = hit.Page;
    public string Where { get; } = $"page {hit.Page + 1}{(hit.Hits > 1 ? $", {hit.Hits} times" : "")}";
    public string Location { get; } = Path.GetDirectoryName(Path.Combine(folder, hit.RelativePath)) ?? folder;
    public string Before { get; } = hit.Excerpt[..hit.MatchStart];
    public string Match { get; } = hit.Excerpt.Substring(hit.MatchStart, hit.MatchLength);
    public string After { get; } = hit.Excerpt[(hit.MatchStart + hit.MatchLength)..];
    public string Description => $"{Name}, {Where}: {Before}{Match}{After}";
}

/// <summary>
/// Edit › Search Folders: a word across the indexed folders, answered from the index, with the text around each hit; a result opens at
/// the hit. Below it the folders, each with what the index has of it, Pause, what was skipped, Rebuild and Remove. A window of
/// its own, not owned by the main one, so a document opened from it comes in front.
/// </summary>
internal sealed class FolderSearchWindow : Window
{
    private static FolderSearchWindow? _open;

    private readonly MainWindow _host;
    private readonly TextBox _box = new() { Padding = new Thickness(8, 6, 8, 6) };
    private readonly CheckBox _matchCase = new() { Content = "Match _case", Margin = new Thickness(0, 0, 14, 0) };
    private readonly CheckBox _wholeWords = new() { Content = "_Whole words", Margin = new Thickness(0, 0, 14, 0) };
    private readonly CheckBox _ignoreAccents = new() { Content = "Ignore _accents", IsChecked = true, ToolTip = "Find é, è and ê when you type e" };
    private readonly ObservableCollection<FolderResult> _results = [];
    private readonly ListBox _list = new() { BorderThickness = new Thickness(0), Background = System.Windows.Media.Brushes.Transparent };
    private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 8, 0, 8) };
    private readonly StackPanel _folders = new();
    private readonly Border _locked = new() { Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 12), CornerRadius = new CornerRadius(6), Visibility = Visibility.Collapsed };
    private readonly Dictionary<IndexedFolder, FolderCard> _cards = [];
    private readonly DispatcherTimer _typing = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly DispatcherTimer _refresh = new() { Interval = TimeSpan.FromMilliseconds(400) };
    private CancellationTokenSource? _search;
    private bool _dirty = true;

    /// <summary>The last search, for the find bar a result opens with.</summary>
    private (string Query, FolderSearchOptions Options)? _last;

    /// <summary>What the last search did, for the dev script.</summary>
    public Task LastSearch { get; private set; } = Task.CompletedTask;

    public static FolderSearchWindow Open(MainWindow host, bool offScreen = false)
    {
        if (_open is { } existing)
        {
            if (existing.WindowState == WindowState.Minimized) existing.WindowState = WindowState.Normal;
            existing.Activate();
            existing._box.Focus();
            existing._box.SelectAll();
            return existing;
        }
        var w = new FolderSearchWindow(host);
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

    private FolderSearchWindow(MainWindow host)
    {
        _host = host;
        Title = "Search Folders";
        Width = Math.Min(900, SystemParameters.WorkArea.Width * 0.9);
        Height = Math.Min(720, SystemParameters.WorkArea.Height * 0.9);
        MinWidth = 520;
        MinHeight = 420;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SourceInitialized += (_, _) => App.ApplyFrame(this);
        Content = Build();

        _typing.Tick += (_, _) =>
        {
            _typing.Stop();
            Search();
        };
        _box.TextChanged += (_, _) =>
        {
            _typing.Stop();
            _typing.Start();
        };
        _box.PreviewKeyDown += OnBoxKey;
        foreach (var box in new[] { _matchCase, _wholeWords, _ignoreAccents }) box.Click += (_, _) => Search();
        _list.MouseDoubleClick += (_, e) =>
        {
            if (e.OriginalSource is DependencyObject d && ItemsControl.ContainerFromElement(_list, d) is ListBoxItem) OpenSelected();
        };
        _list.PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter || _list.SelectedItem is null) return;
            e.Handled = true;
            OpenSelected();
        };
        PreviewKeyDown += (_, e) =>
        {
            if (e.Key != Key.Escape) return;
            e.Handled = true;
            Close();
        };

        FolderSearches.Changed += OnChanged;
        _refresh.Tick += (_, _) =>
        {
            if (!_dirty) return;
            _dirty = false;
            RefreshFolders();
        };
        _refresh.Start();
        RefreshFolders();
        Loaded += (_, _) => _box.Focus();
        Closed += (_, _) =>
        {
            FolderSearches.Changed -= OnChanged;
            _refresh.Stop();
            _typing.Stop();
            _search?.Cancel();
            foreach (var f in FolderSearches.All) f.Indexer?.Index?.ForgetCaches(); // what a search kept in memory, until the next one
        };
    }

    private void OnChanged() => _dirty = true;

    private UIElement Build()
    {
        var caption = (Style)Application.Current.FindResource("Caption");
        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 12) };
        heading.Children.Add(new TextBlock { Text = "Search Folders", FontSize = 20, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock
        {
            Text = "Find a word in every PDF of a folder and its subfolders. The index stays on this PC, kept up to date while Inkvolt PDF is open, and holds the text of those PDFs (never of files with a password). Scans are found once they have a text layer: Recognize Text adds one.",
            Style = caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });

        _locked.SetResourceReference(Border.BackgroundProperty, "SystemFillColorAttentionBackgroundBrush");
        var lockedText = new StackPanel();
        lockedText.Children.Add(new TextBlock { Text = Pro.Locked(ProFeature.FolderSearch), FontWeight = FontWeights.SemiBold });
        lockedText.Children.Add(new TextBlock { Text = Pro.Describe(ProFeature.FolderSearch), TextWrapping = TextWrapping.Wrap, Style = caption, Margin = new Thickness(0, 4, 0, 8) });
        var about = new Button { Content = "About Inkvolt Pro…", HorizontalAlignment = HorizontalAlignment.Left, Padding = new Thickness(10, 3, 10, 3) };
        about.Click += (_, _) => ProWindow.Open(this, ProFeature.FolderSearch);
        lockedText.Children.Add(about);
        _locked.Child = lockedText;

        AutomationProperties.SetName(_box, "Search the indexed folders");
        Placeholder.SetText(_box, "A word or phrase");
        var find = new Button { Content = "Search", MinWidth = 88, Margin = new Thickness(8, 0, 0, 0), IsDefault = true };
        find.SetResourceReference(StyleProperty, "AccentButtonStyle");
        find.Click += (_, _) => Search();
        var searchRow = new DockPanel();
        DockPanel.SetDock(find, Dock.Right);
        searchRow.Children.Add(find);
        searchRow.Children.Add(_box);

        var options = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
        options.Children.Add(_matchCase);
        options.Children.Add(_wholeWords);
        options.Children.Add(_ignoreAccents);

        AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Polite);
        _status.SetResourceReference(TextBlock.ForegroundProperty, "TextFillColorSecondaryBrush");

        _list.ItemsSource = _results;
        _list.ItemTemplate = (DataTemplate)XamlReader.Parse(
            "<DataTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation'>" +
            "<StackPanel Margin='2,4,2,4'>" +
            "<TextBlock TextTrimming='CharacterEllipsis'><Run Text='{Binding Name, Mode=OneWay}' FontWeight='SemiBold' /><Run Text=' · ' /><Run Text='{Binding Where, Mode=OneWay}' /></TextBlock>" +
            "<TextBlock TextTrimming='CharacterEllipsis'><Run Text='{Binding Before, Mode=OneWay}' /><Run Text='{Binding Match, Mode=OneWay}' FontWeight='Bold' Background='{DynamicResource SystemFillColorAttentionBackgroundBrush}' /><Run Text='{Binding After, Mode=OneWay}' /></TextBlock>" +
            "<TextBlock Text='{Binding Location, Mode=OneWay}' TextTrimming='CharacterEllipsis' FontSize='11' Foreground='{DynamicResource TextFillColorSecondaryBrush}' />" +
            "</StackPanel></DataTemplate>");
        var itemStyle = new Style(typeof(ListBoxItem), (Style)FindResource("SubtleListItem"));
        itemStyle.Setters.Add(new Setter(AutomationProperties.NameProperty, new Binding(nameof(FolderResult.Description))));
        _list.ItemContainerStyle = itemStyle;
        ScrollViewer.SetHorizontalScrollBarVisibility(_list, ScrollBarVisibility.Disabled);
        VirtualizingPanel.SetIsVirtualizing(_list, true);
        VirtualizingPanel.SetVirtualizationMode(_list, VirtualizationMode.Recycling);
        AutomationProperties.SetName(_list, "Results");

        var foldersHeader = new DockPanel { Margin = new Thickness(0, 12, 0, 6) };
        var add = new Button { Content = "A_dd a Folder…", Padding = new Thickness(10, 3, 10, 3) };
        add.Click += (_, _) => AskAdd();
        DockPanel.SetDock(add, Dock.Right);
        foldersHeader.Children.Add(add);
        foldersHeader.Children.Add(new TextBlock { Text = "Folders", FontWeight = FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center });
        AutomationProperties.SetName(_folders, "Indexed folders");
        var foldersScroll = new ScrollViewer { Content = _folders, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 190 };

        var top = new StackPanel();
        top.Children.Add(heading);
        top.Children.Add(_locked);
        top.Children.Add(searchRow);
        top.Children.Add(options);
        top.Children.Add(_status);
        var bottom = new StackPanel();
        bottom.Children.Add(foldersHeader);
        bottom.Children.Add(foldersScroll);

        var listBorder = new Border { Child = _list, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(4) };
        listBorder.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");

        var body = new DockPanel { Margin = new Thickness(24, 18, 24, 12) };
        DockPanel.SetDock(top, Dock.Top);
        DockPanel.SetDock(bottom, Dock.Bottom);
        body.Children.Add(top);
        body.Children.Add(bottom);
        body.Children.Add(listBorder);

        var close = new Button { Content = "Close", MinWidth = 104 };
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

    private void OnBoxKey(object sender, KeyEventArgs e)
    {
        if (e.Key != Key.Down || _results.Count == 0) return;
        e.Handled = true;
        _list.SelectedIndex = Math.Max(0, _list.SelectedIndex);
        _list.UpdateLayout();
        (_list.ItemContainerGenerator.ContainerFromIndex(_list.SelectedIndex) as UIElement)?.Focus();
    }

    // ---- Searching ----

    private void Search()
    {
        _typing.Stop();
        _search?.Cancel();
        var cts = _search = new CancellationTokenSource();
        LastSearch = RunAsync(_box.Text.Trim(), cts);
    }

    private async Task RunAsync(string query, CancellationTokenSource cts)
    {
        _results.Clear();
        _last = null;
        if (query.Length == 0)
        {
            _status.Text = "";
            return;
        }
        if (!Pro.Allows(ProFeature.FolderSearch))
        {
            _status.Text = Pro.Locked(ProFeature.FolderSearch);
            return;
        }
        var folders = FolderSearches.All.Where(f => f.Indexer?.Index is not null).ToList();
        if (folders.Count == 0)
        {
            _status.Text = FolderSearches.All.Count == 0 ? "No folder is indexed yet. Add a Folder chooses one." : "The index isn't open yet. Try again in a moment.";
            return;
        }
        const int Limit = 500;
        var options = new FolderSearchOptions(_matchCase.IsChecked == true, _wholeWords.IsChecked == true, _ignoreAccents.IsChecked == true, Limit);
        _last = (query, options);
        _status.Text = "Searching…";
        var clock = System.Diagnostics.Stopwatch.StartNew();
        var candidates = 0;
        var hasWords = true;
        var problems = new List<string>();
        try
        {
            await Task.Run(async () =>
            {
                var batch = new List<FolderResult>();
                var listed = 0;
                var last = Environment.TickCount64;
                foreach (var folder in folders)
                {
                    if (listed >= Limit || folder.Indexer?.Index is not { } index) continue;
                    try
                    {
                        using var run = index.Search(query, options with { MaxPages = Limit - listed }, cts.Token);
                        hasWords &= run.HasWords;
                        candidates += run.CandidatePages;
                        foreach (var hit in run.Hits(cts.Token))
                        {
                            batch.Add(new FolderResult(folder.Folder, hit));
                            listed++;
                            if (batch.Count >= 40 || Environment.TickCount64 - last > 100)
                            {
                                var ready = batch;
                                batch = [];
                                last = Environment.TickCount64;
                                await Dispatcher.InvokeAsync(() => Take(ready, cts));
                            }
                        }
                    }
                    catch (FolderIndexDamagedException)
                    {
                        // Its text is all in the PDFs: the search goes on with what the others have.
                        folder.Indexer?.Rebuild();
                        problems.Add($"The index of {folder.Folder} was damaged and is being built again.");
                    }
                    catch (ObjectDisposedException)
                    {
                        // Removed or stopped while this ran.
                    }
                }
                await Dispatcher.InvokeAsync(() => Take(batch, cts));
            }, cts.Token);
        }
        catch (OperationCanceledException)
        {
            return;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Folder search failed: {ex.Message}");
            if (!cts.IsCancellationRequested) _status.Text = $"The search stopped on an error: {ex.Message}";
            return;
        }
        if (cts.IsCancellationRequested) return;
        var ms = clock.Elapsed.TotalMilliseconds;
        var pages = _results.Select(r => r.FullPath).Distinct(StringComparer.OrdinalIgnoreCase).Count();
        string said;
        if (!hasWords) said = "Type a word with letters or digits: the index keeps those. To find punctuation, use Find in an open document.";
        else if (_results.Count == 0) said = $"No matches for \"{query}\".";
        else if (_results.Count >= Limit) said = candidates > Limit ? $"The first {Limit:N0} pages are listed, of up to {candidates:N0} with these words." : $"The first {Limit:N0} pages are listed.";
        else said = $"{_results.Count:N0} {(_results.Count == 1 ? "page" : "pages")} in {pages:N0} {(pages == 1 ? "file" : "files")}.";
        if (FolderSearches.All.Any(f => f.Indexer?.Status.Phase is IndexerPhase.Indexing or IndexerPhase.Scanning)) said += " Still indexing: more may turn up.";
        foreach (var problem in problems) said += " " + problem;
        _status.Text = said;
        Log.Write($"Folder search: {_results.Count} results in {ms:0} ms");
    }

    private void Take(List<FolderResult> batch, CancellationTokenSource cts)
    {
        if (cts.IsCancellationRequested) return;
        foreach (var r in batch) _results.Add(r);
    }

    private void OpenSelected()
    {
        if (_list.SelectedItem is not FolderResult result || _last is not { } last) return;
        _ = _host.OpenFolderHit(result.FullPath, result.Page, last.Query, last.Options.MatchCase, last.Options.WholeWord, last.Options.IgnoreAccents);
    }

    // ---- The folders ----

    private void AskAdd()
    {
        if (!ProGate.Check(this, ProFeature.FolderSearch)) return;
        if (PdfFiles.PickFolder(this, "Index this folder and its subfolders") is not { } folder) return;
        if (FolderSearches.Validate(folder) is { } problem)
        {
            Prompt.Info(this, "Can't index this folder", problem);
            return;
        }
        FolderSearches.Add(folder);
        RefreshFolders();
    }

    private void RefreshFolders()
    {
        var allowed = Pro.Allows(ProFeature.FolderSearch);
        _locked.Visibility = allowed ? Visibility.Collapsed : Visibility.Visible;
        foreach (var gone in _cards.Keys.Where(f => !FolderSearches.All.Contains(f)).ToList())
        {
            _folders.Children.Remove(_cards[gone].Root);
            _cards.Remove(gone);
        }
        if (FolderSearches.All.Count == 0 && _folders.Children.Count == 0)
            _folders.Children.Add(new TextBlock { Text = "No folder is indexed yet. Add a Folder chooses one.", Style = (Style)Application.Current.FindResource("Caption"), TextWrapping = TextWrapping.Wrap });
        else if (FolderSearches.All.Count > 0 && _folders.Children.Count > 0 && _folders.Children[0] is TextBlock)
            _folders.Children.RemoveAt(0);
        foreach (var f in FolderSearches.All)
        {
            if (allowed) f.Start(); // a key was entered since the app started
            if (!_cards.TryGetValue(f, out var card))
            {
                _cards[f] = card = new FolderCard(this, f);
                _folders.Children.Add(card.Root);
            }
            card.Refresh();
        }
    }

    /// <summary>One folder's row. Kept from one refresh to the next, so a button keeps its focus.</summary>
    private sealed class FolderCard
    {
        private readonly IndexedFolder _folder;
        private readonly TextBlock _status = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 6) };
        private readonly Button _pause;
        private readonly Button _skipped;

        public Border Root { get; }

        public FolderCard(FolderSearchWindow window, IndexedFolder folder)
        {
            _folder = folder;
            Root = new Border { Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 0, 0, 6), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
            Root.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
            Root.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
            var panel = new StackPanel();
            panel.Children.Add(new TextBlock { Text = folder.Folder, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = folder.Folder });
            panel.Children.Add(_status);
            AutomationProperties.SetLiveSetting(_status, AutomationLiveSetting.Off);
            var actions = new WrapPanel();
            _pause = Small("Pause", () =>
            {
                folder.SetPaused(!folder.IsPaused);
                Refresh();
            });
            actions.Children.Add(_pause);
            _skipped = Small("Skipped Files…", () => ShowSkipped(window, folder));
            actions.Children.Add(_skipped);
            actions.Children.Add(Small("Open Folder", () => Shell.Open(folder.Folder)));
            actions.Children.Add(Small("Rebuild", () =>
            {
                if (Prompt.Confirm(window, "Build this index again?", $"Every PDF in {folder.Folder} is read again, and files skipped earlier get another chance. Searches find what has been read so far.", "Rebuild"))
                    folder.Indexer?.Rebuild();
            }));
            actions.Children.Add(Small("Remove", () =>
            {
                if (Prompt.Confirm(window, "Stop indexing this folder?", $"Its index file is deleted. The PDFs in {folder.Folder} aren't touched.", "Remove"))
                    FolderSearches.Remove(folder);
            }));
            panel.Children.Add(actions);
            Root.Child = panel;
        }

        public void Refresh()
        {
            var status = _folder.StatusText;
            _status.Text = status;
            _pause.Content = _folder.IsPaused ? "Resume" : "Pause";
            _pause.IsEnabled = _folder.Indexer is not null;
            _skipped.IsEnabled = _folder.Indexer?.Index?.Files.Values.Any(f => f.State != IndexedState.Indexed || f.FailedPages > 0) == true;
            AutomationProperties.SetName(Root, $"{_folder.Folder}: {status}");
        }

        private static Button Small(string text, Action onClick)
        {
            var b = new Button { Content = text, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 3, 10, 3) };
            b.Click += (_, _) => onClick();
            return b;
        }

        private static void ShowSkipped(Window owner, IndexedFolder folder)
        {
            if (folder.Indexer is not { } indexer) return;
            var skipped = indexer.Skipped();
            var dlg = new FormDialog(owner, "Skipped Files", "Close", 620);
            dlg.AddNote($"{skipped.Count:N0} {(skipped.Count == 1 ? "file" : "files")} in {folder.Folder} the index has no text, or not all the text, of. They are read again when they change, or with Rebuild.");
            var list = new ListBox { MaxHeight = 320, ItemsSource = skipped.Select(s => $"{s.RelativePath}: {s.Reason}").ToList() };
            AutomationProperties.SetName(list, "Skipped files");
            VirtualizingPanel.SetIsVirtualizing(list, true);
            dlg.Add(null, list);
            dlg.ShowModal();
        }
    }

    // ---- The dev script ----

    internal string DevState() =>
        $"folders: {string.Join(" | ", FolderSearches.All.Select(f => $"{f.Folder}: {f.StatusText}"))}; results {_results.Count}; status '{_status.Text}'";

    internal async Task<string> DevSearch(string query)
    {
        _box.Text = query;
        Search();
        await LastSearch;
        await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Background);
        RefreshFolders();
        var first = _results.Take(3).Select(r => $"{r.Name} p{r.Page + 1} [{r.Before}<{r.Match}>{r.After}]");
        return $"indexsearch {query}: {_results.Count} results; {_status.Text} {string.Join(" ; ", first)}";
    }

    internal void DevOption(string which, bool on)
    {
        (which switch { "case" => _matchCase, "whole" => _wholeWords, _ => _ignoreAccents }).IsChecked = on;
    }

    internal void DevSelect(int index)
    {
        _list.SelectedIndex = index;
        _list.ScrollIntoView(_list.SelectedItem);
        OpenSelected();
    }

    internal void DevRefresh() => RefreshFolders();

    /// <summary>The window's longest wait for its turn on the UI thread over <paramref name="ms"/>, in ms: how responsive it stays.</summary>
    internal async Task<double> DevLatency(int ms)
    {
        var longest = 0.0;
        var whole = System.Diagnostics.Stopwatch.StartNew();
        while (whole.ElapsedMilliseconds < ms)
        {
            var one = System.Diagnostics.Stopwatch.StartNew();
            await Dispatcher.InvokeAsync(() => { }, DispatcherPriority.Input);
            longest = Math.Max(longest, one.Elapsed.TotalMilliseconds);
            await Task.Delay(10);
        }
        return longest;
    }
}
