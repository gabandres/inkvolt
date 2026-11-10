using System.IO;
using System.Windows;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Explorer's "Convert to Word with Inkvolt PDF" (<c>--convert-to word &lt;files…&gt;</c>, <see cref="ConvertCommand"/>), in
/// the one copy of the app: every request, from this launch or forwarded by another, goes into one
/// <see cref="ConvertQueue"/> and is converted by <see cref="ExportActions.ConvertFile"/>. One file with the main window
/// up shows the in-app one-click's notice there; otherwise the small <see cref="ConvertWindow"/> lists each file and what
/// became of it (<see cref="ConvertCommand.ShowsNotice"/>). Change options… opens the PDF in the main window (started if
/// it isn't) and its Export window.
/// </summary>
internal static class ExplorerConvert
{
    private static ConvertQueue? _queue;
    private static ConvertWindow? _list;
    private static MainWindow? _main;
    private static readonly HashSet<ConvertJob> Noticed = [];
    private static bool _nextNoticed;

    /// <summary>Opens <c>pdf</c> in the main window (starting it when the app runs only for conversions) and its Export window.</summary>
    internal static Action<string, ExportFormat>? ChangeOptions { get; set; }

    private static ConvertQueue Queue => _queue ??= Make();

    private static ConvertQueue Make()
    {
        var queue = new ConvertQueue((job, cancel) =>
            ExportActions.ConvertFile(Noticed.Contains(job) && _main is { } m ? m : (Window?)_list ?? Application.Current.MainWindow!,
                job.Pdf, job.Format, job.Open, cancel));
        queue.Changed += OnChanged;
        return queue;
    }

    /// <summary>The jobs listed or noticed so far (a dev script's <c>explorerstate</c>).</summary>
    internal static IReadOnlyList<ConvertJob> Jobs => _queue?.Jobs ?? [];

    internal static Task Idle => _queue?.Idle ?? Task.CompletedTask;

    /// <summary>
    /// Converts <paramref name="request"/>'s files; <paramref name="main"/> is the main window once it is ready (null while
    /// the app runs only for conversions).
    /// </summary>
    public static void Route(ConvertCommand.Request request, MainWindow? main)
    {
        _main = main;
        var queue = Queue;
        var notice = ConvertCommand.ShowsNotice(main is not null, _list is not null, queue.IsBusy, request.Files.Count);
        Log.Write($"Convert from Explorer: {request.Files.Count} file(s) to {request.Format}{(request.Dropped > 0 ? $", {request.Dropped} left out" : "")}, {(notice ? "notice" : "listed")}");
        if (notice)
        {
            main!.BringToFront();
        }
        else
        {
            if (_list is null)
            {
                _list = new ConvertWindow(queue);
                _list.Closed += (_, _) => _list = null;
                if (main is { IsLoaded: true }) _list.Owner = main;
                else if (Application.Current.MainWindow is null or ConvertWindow) Application.Current.MainWindow = _list;
                _list.Show();
            }
            _list.Activate();
            if (request.Dropped > 0) _list.SayDropped(request.Dropped);
        }
        _nextNoticed = notice;
        try
        {
            queue.Add(request);
        }
        finally
        {
            _nextNoticed = false;
        }
    }

    private static void OnChanged(ConvertJob job)
    {
        if (job.State == ConvertJob.States.Waiting)
        {
            if (_nextNoticed) Noticed.Add(job);
            else _list?.Track(job);
            return;
        }
        if (job.State != ConvertJob.States.Done || !Noticed.Remove(job)) return;
        if (_main is not { } main || job.Outcome is not { } outcome) return;
        // As the command bar's one-click: "Saved report.docx · Show in folder · Change options…".
        switch (outcome.Result)
        {
            case ConvertResult.Saved:
                var saved = SavedText(outcome);
                main.ShowToast(new Toast(saved, Strings.Export_ShowInFolder, () => Shell.ShowInFolder(outcome.Output!),
                    Action2Label: Strings.Export_ChangeOptions, Action2: () => ChangeOptions?.Invoke(job.Pdf, job.Format)));
                break;
            case ConvertResult.Cancelled:
                main.ShowStatus(Strings.Export_Cancelled);
                break;
            case ConvertResult.NotFound:
                main.ShowToast(new Toast(outcome.Message ?? Strings.Export_Failed, IsError: true));
                break;
            default:
                main.ShowToast(new Toast(outcome.Message ?? Strings.Export_Failed, Strings.Export_ChangeOptions,
                    () => ChangeOptions?.Invoke(job.Pdf, job.Format), IsError: true));
                break;
        }
    }

    /// <summary>"Saved report.docx" (or "… in Documents"), its notes after it.</summary>
    internal static string SavedText(ConvertOutcome outcome) =>
        Loc.Format(outcome.InDocuments ? Strings.Export_SavedDocuments : Strings.Export_Saved, Path.GetFileName(outcome.Output))
        + (outcome.Message is { Length: > 0 } notes ? $" ({notes})" : "");

    /// <summary>What a wrong command line says (the launch shows it, then exits).</summary>
    internal static string Explain(ConvertCommand.ParseError error) => error switch
    {
        ConvertCommand.ParseError.NoFormat => Strings.Explorer_NoFormat,
        ConvertCommand.ParseError.UnknownFormat => Strings.Explorer_UnknownFormat,
        _ => Strings.Explorer_NoFiles,
    };
}

/// <summary>
/// The small window that lists Explorer's conversions when the app isn't open or several files were chosen: each file,
/// its state, and when done "Saved report.docx · Open · Show in folder · Change options…" or the message saying why
/// not. Cancel stops the one running and those waiting; closing it while it works does the same, then closes.
/// </summary>
internal sealed class ConvertWindow : Window
{
    private const int MaxNameWidth = 420;
    private readonly ConvertQueue _queue;
    private readonly TextBlock _heading = new() { FontSize = 18, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap };
    private readonly TextBlock _dropped = new() { TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 6, 0, 0), Visibility = Visibility.Collapsed };
    private readonly StackPanel _rows = new();
    private readonly Button _button = new() { MinWidth = 104, HorizontalAlignment = HorizontalAlignment.Right };
    private readonly List<(ConvertJob Job, StackPanel Row)> _tracked = [];
    private bool _closeWhenIdle;

    public ConvertWindow(ConvertQueue queue)
    {
        _queue = queue;
        Title = Strings.Explorer_Title;
        Width = 520;
        MaxHeight = 640;
        SizeToContent = SizeToContent.Height;
        ResizeMode = ResizeMode.CanMinimize;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SourceInitialized += (_, _) => App.ApplyFrame(this);
        _button.Click += (_, _) =>
        {
            if (_queue.IsBusy) _queue.CancelAll();
            else Close();
        };
        var head = new StackPanel { Margin = new Thickness(24, 20, 24, 8) };
        head.Children.Add(_heading);
        head.Children.Add(_dropped);
        var scroll = new ScrollViewer { VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Content = _rows, Padding = new Thickness(24, 0, 24, 16) };
        var footer = new Border { Padding = new Thickness(24, 14, 24, 14), Child = _button, BorderThickness = new Thickness(0, 1, 0, 0) };
        footer.SetResourceReference(Border.BackgroundProperty, "LayerFillColorDefaultBrush");
        footer.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");
        var root = new DockPanel();
        DockPanel.SetDock(head, Dock.Top);
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(head);
        root.Children.Add(footer);
        root.Children.Add(scroll);
        Content = root;
        _queue.Changed += OnChanged;
        Closed += (_, _) => _queue.Changed -= OnChanged;
        Refresh();
    }

    protected override void OnClosing(System.ComponentModel.CancelEventArgs e)
    {
        base.OnClosing(e);
        if (!_queue.IsBusy || e.Cancel) return;
        // Nothing is left half done: the running one stops (its empty reserved file goes), then the window closes.
        e.Cancel = true;
        if (_closeWhenIdle) return;
        _closeWhenIdle = true;
        _queue.CancelAll();
        _ = _queue.Idle.ContinueWith(_ => Dispatcher.BeginInvoke(Close), TaskScheduler.Default);
    }

    /// <summary>Lists <paramref name="job"/> (just queued).</summary>
    public void Track(ConvertJob job)
    {
        var row = new StackPanel { Margin = new Thickness(0, 8, 0, 4) };
        _tracked.Add((job, row));
        _rows.Children.Add(row);
        Fill(job, row);
        Refresh();
    }

    public void SayDropped(int count)
    {
        _dropped.Text = Loc.Plural(count, Strings.Explorer_Dropped_One, Strings.Explorer_Dropped_Many, ConvertCommand.MaxFiles);
        _dropped.Visibility = Visibility.Visible;
    }

    private void OnChanged(ConvertJob job)
    {
        if (!Dispatcher.CheckAccess())
        {
            Dispatcher.BeginInvoke(() => OnChanged(job));
            return;
        }
        foreach (var (j, row) in _tracked)
            if (j == job)
            {
                Fill(job, row);
                if (job.State == ConvertJob.States.Converting) row.BringIntoView();
            }
        Refresh();
    }

    private void Refresh()
    {
        var done = _tracked.Count(t => t.Job.State == ConvertJob.States.Done);
        var saved = _tracked.Count(t => t.Job.Outcome?.Result == ConvertResult.Saved);
        _heading.Text = done < _tracked.Count || _tracked.Count == 0
            ? Loc.Plural(_tracked.Count, Strings.Explorer_Converting_One, Strings.Explorer_Converting_Many)
            : Loc.Format(Strings.Explorer_Finished, saved, _tracked.Count);
        _button.Content = _queue.IsBusy ? Strings.Common_Cancel : Strings.Common_Close;
        _button.IsCancel = true;
    }

    private void Fill(ConvertJob job, StackPanel row)
    {
        row.Children.Clear();
        // The name comes from outside: one line, cut with "…".
        var name = new TextBlock
        {
            Text = Path.GetFileName(job.Pdf),
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis,
            MaxWidth = MaxNameWidth,
            HorizontalAlignment = HorizontalAlignment.Left,
            ToolTip = job.Pdf,
        };
        row.Children.Add(name);
        var outcome = job.Outcome;
        var state = new TextBlock { TextWrapping = TextWrapping.Wrap, MaxHeight = 64, TextTrimming = TextTrimming.CharacterEllipsis };
        state.SetResourceReference(TextBlock.ForegroundProperty, outcome is { Result: not (ConvertResult.Saved or ConvertResult.Cancelled) }
            ? "SystemFillColorCriticalBrush" : "TextFillColorSecondaryBrush");
        state.Text = job.State switch
        {
            ConvertJob.States.Waiting => Strings.Explorer_Waiting,
            ConvertJob.States.Converting => Strings.Explorer_Working,
            _ => outcome?.Result switch
            {
                ConvertResult.Saved => ExplorerConvert.SavedText(outcome),
                ConvertResult.Cancelled => Strings.Explorer_Cancelled,
                _ => outcome?.Message ?? Strings.Export_Failed,
            },
        };
        System.Windows.Automation.AutomationProperties.SetName(row, $"{name.Text}: {state.Text}");
        row.Children.Add(state);
        if (job.State != ConvertJob.States.Done || outcome is null) return;
        var links = new WrapPanel { Margin = new Thickness(-8, 2, 0, 0) };
        if (outcome is { Result: ConvertResult.Saved, Output: { } output })
        {
            links.Children.Add(Link(Strings.Common_Open, () => Shell.Open(output)));
            links.Children.Add(Link(Strings.Export_ShowInFolder, () => Shell.ShowInFolder(output)));
        }
        if (outcome.Result is not ConvertResult.NotFound)
            links.Children.Add(Link(Strings.Export_ChangeOptions, () => ExplorerConvert.ChangeOptions?.Invoke(job.Pdf, job.Format)));
        row.Children.Add(links);
    }

    private Button Link(string text, Action click)
    {
        var b = new Button { Content = text, Style = (Style)FindResource("TextButton") };
        b.Click += (_, _) => click();
        return b;
    }
}
