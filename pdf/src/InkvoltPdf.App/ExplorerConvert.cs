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
                job.Pdf, job.Format, () => false, job.Answers, cancel)); // a notice's result opens once the launches have settled (OpenWhenSettled)
        queue.Changed += OnChanged;
        return queue;
    }

    /// <summary>The jobs listed or noticed so far (a dev script's <c>explorerwait</c>).</summary>
    internal static IReadOnlyList<ConvertJob> Jobs => _queue?.Jobs ?? [];

    /// <summary>Done once the gathered launches have been handed out and every conversion has ended.</summary>
    internal static async Task Idle()
    {
        while (!Gather.IsEmpty) await Task.Delay(100);
        if (_queue is { } q) await q.Idle;
    }

    /// <summary>The main window once it is ready, null while the app runs only for conversions (the app sets it).</summary>
    internal static Func<MainWindow?> MainFor { get; set; } = () => null;

    /// <summary>Called when nothing is left to show or convert (the app then exits if its main window is closed).</summary>
    internal static Action? Quiet { get; set; }

    /// <summary>The conversions window is open.</summary>
    internal static bool ListOpen => _list is not null;

    /// <summary>Launches are being gathered, or conversions wait or run.</summary>
    internal static bool Converting => !Gather.IsEmpty || _queue is { IsBusy: true };

    // Explorer starts one launch per file: those that come together are one batch (ConvertGather).
    private static readonly ConvertGather Gather = new();
    private static System.Windows.Threading.DispatcherTimer? _timer;

    /// <summary>
    /// Converts <paramref name="request"/>'s files, together with the launches that come with it: the batch is handed
    /// out once they stop coming (<see cref="ConvertGather"/>).
    /// </summary>
    public static void Route(ConvertCommand.Request request)
    {
        Gather.Add(request, DateTime.UtcNow);
        if (_timer is null)
        {
            _timer = new System.Windows.Threading.DispatcherTimer();
            _timer.Tick += (_, _) => Flush();
        }
        Arm();
    }

    private static void Arm()
    {
        _timer!.Stop();
        if (Gather.DueAt is not { } due) return;
        var wait = due - DateTime.UtcNow;
        _timer.Interval = wait > TimeSpan.Zero ? wait : TimeSpan.FromMilliseconds(1);
        _timer.Start();
    }

    private static void Flush()
    {
        if (!Gather.IsDue(DateTime.UtcNow))
        {
            Arm();
            return;
        }
        _timer!.Stop();
        foreach (var batch in Gather.Take()) RouteNow(batch, MainFor());
        if (!ListOpen && !Converting) Quiet?.Invoke();
    }

    /// <summary>
    /// One batch: the notice in <paramref name="main"/> for one file (opened when written, as the one-click), the list
    /// otherwise (nothing opened: a selection of thirty would open thirty Word windows).
    /// </summary>
    private static void RouteNow(ConvertCommand.Request request, MainWindow? main)
    {
        _main = main;
        var queue = Queue;
        // A flood of launches can't grow the list for good (ConvertQueue.MaxWaiting): what doesn't fit is said apart.
        (request, var cut) = queue.Fit(request);
        var leftOut = ConvertCommand.AddLeftOut(ConvertCommand.AddLeftOut(request.OverLimit, request.Refused), cut);
        // A notice still converting, or whose result waits to open, came from the same selection when another launch
        // follows (a loaded PC spaces them out past ConvertGather.Quiet): it joins the list, and nothing opens.
        var folded = Fold();
        var notice = !folded && leftOut == 0 && ConvertCommand.ShowsNotice(main is not null, _list is not null, queue.IsBusy, request.Files.Count);
        Log.Write($"Convert from Explorer: {request.Files.Count} file(s) to {request.Format}{(leftOut > 0 ? $", {request.OverLimit} over the limit, {request.Refused} refused, {cut} past the waiting list" : "")}, {(notice ? "notice" : "listed")}");
        if (notice)
        {
            main!.BringToFront();
        }
        else
        {
            ShowList();
            _list!.SayLeftOut(request.OverLimit, request.Refused, cut);
        }
        _nextNoticed = notice;
        try
        {
            queue.Add(request, open: notice);
        }
        finally
        {
            _nextNoticed = false;
        }
    }

    // A notice's saved result, opened once no launch has come for ConvertGather.Settle.
    private static readonly List<(ConvertJob Job, string Output)> OpenLater = [];
    private static System.Windows.Threading.DispatcherTimer? _openTimer;

    private static void OpenWhenSettled(ConvertJob job, string output)
    {
        OpenLater.Add((job, output));
        OpenSettled();
    }

    private static void OpenSettled()
    {
        _openTimer ??= new System.Windows.Threading.DispatcherTimer();
        _openTimer.Stop();
        if (OpenLater.Count == 0) return;
        if (!Gather.Settled(DateTime.UtcNow))
        {
            var wait = Gather.SettledAt!.Value - DateTime.UtcNow;
            _openTimer.Interval = wait > TimeSpan.Zero ? wait : TimeSpan.FromMilliseconds(1);
            _openTimer.Tick -= OnOpenTimer;
            _openTimer.Tick += OnOpenTimer;
            _openTimer.Start();
            return;
        }
        foreach (var (job, output) in OpenLater.ToList())
            if (job.Open)
                Shell.Open(output);
        OpenLater.Clear();
    }

    private static void OnOpenTimer(object? sender, EventArgs e) => OpenSettled();

    /// <summary>
    /// Moves the notice's conversion (running, or saved with its result still to open) into the list: it opens nothing,
    /// and the list shows it with the rest of the selection. False when there was none.
    /// </summary>
    private static bool Fold()
    {
        var jobs = Noticed.Where(j => j.State != ConvertJob.States.Done).Concat(OpenLater.Select(o => o.Job)).Distinct().ToList();
        if (jobs.Count == 0) return false;
        ShowList();
        foreach (var job in jobs)
        {
            job.StopOpening();
            Noticed.Remove(job);
            _list!.Track(job);
        }
        OpenLater.Clear();
        Log.Write($"Convert from Explorer: a later launch came; the notice's {jobs.Count} file(s) joined the list");
        return true;
    }

    // Never owned by the main window: it outlives it, for the conversions left when the main window closes.
    private static void ShowList()
    {
        if (_list is null)
        {
            _list = new ConvertWindow(Queue);
            _list.Closed += (_, _) =>
            {
                _list = null;
                if (!Converting) Quiet?.Invoke();
            };
            _list.Show();
        }
        _list.Activate();
    }

    /// <summary>
    /// The main window closed while conversions are left: they go on, in the conversions window (a notice's conversion
    /// too), so nothing is stopped half written; the app exits once that window closes.
    /// </summary>
    public static void MainClosed()
    {
        _main = null;
        if (_queue is not { IsBusy: true } && Gather.IsEmpty) return;
        ShowList();
        foreach (var job in Queue.Jobs.Where(j => j.State != ConvertJob.States.Done && Noticed.Remove(j)).ToList()) _list!.Track(job);
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
                if (job.Open) OpenWhenSettled(job, outcome.Output!);
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
        _ = _queue.Idle.ContinueWith(_ => Dispatcher.BeginInvoke(CloseWhenIdle), TaskScheduler.Default);
    }

    // The pending close, unless a request came meanwhile (Track called it off: those files are shown, and X works again).
    private void CloseWhenIdle()
    {
        if (!_closeWhenIdle) return;
        _closeWhenIdle = false;
        if (_queue.IsBusy) return;
        Close();
    }

    /// <summary>Lists <paramref name="job"/> (just queued); a close waiting for the cancelled ones is called off.</summary>
    public void Track(ConvertJob job)
    {
        _closeWhenIdle = false;
        var row = new StackPanel { Margin = new Thickness(0, 8, 0, 4) };
        _tracked.Add((job, row));
        _rows.Children.Add(row);
        // The rows follow the queue's list (it keeps the last ConvertQueue.MaxListed finished): no row for good per file.
        if (_tracked.Count > _queue.Jobs.Count)
        {
            var listed = _queue.Jobs.ToHashSet();
            foreach (var gone in _tracked.Where(t => !listed.Contains(t.Job)).ToList())
            {
                _rows.Children.Remove(gone.Row);
                _tracked.Remove(gone);
                // Still counted in the heading (the queue trims finished ones only).
                _goneDone++;
                if (gone.Job.Outcome?.Result == ConvertResult.Saved) _goneSaved++;
            }
        }
        Fill(job, row);
        Refresh();
    }

    private int _goneDone, _goneSaved;
    private int _overLimit, _refused, _cut;

    /// <summary>
    /// What the launches left out, said apart: past the 500-file limit, names that can't be a file, and files past the
    /// waiting list (<see cref="ConvertQueue.MaxWaiting"/>).
    /// </summary>
    public void SayLeftOut(int overLimit, int refused, int cut)
    {
        _overLimit = ConvertCommand.AddLeftOut(_overLimit, overLimit);
        _refused = ConvertCommand.AddLeftOut(_refused, refused);
        _cut = ConvertCommand.AddLeftOut(_cut, cut);
        var lines = new List<string>();
        if (_overLimit > 0) lines.Add(Loc.Plural(_overLimit, Strings.Explorer_Dropped_One, Strings.Explorer_Dropped_Many, ConvertCommand.MaxFiles));
        if (_refused > 0) lines.Add(Loc.Plural(_refused, Strings.Explorer_Refused_One, Strings.Explorer_Refused_Many));
        if (_cut > 0) lines.Add(Loc.Plural(_cut, Strings.Explorer_TooMany_One, Strings.Explorer_TooMany_Many, ConvertQueue.MaxWaiting));
        _dropped.Text = string.Join(Environment.NewLine, lines);
        _dropped.Visibility = lines.Count > 0 ? Visibility.Visible : Visibility.Collapsed;
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
        var total = _tracked.Count + _goneDone;
        var done = _tracked.Count(t => t.Job.State == ConvertJob.States.Done) + _goneDone;
        var saved = _tracked.Count(t => t.Job.Outcome?.Result == ConvertResult.Saved) + _goneSaved;
        _heading.Text = done < total || total == 0
            ? Loc.Plural(total, Strings.Explorer_Converting_One, Strings.Explorer_Converting_Many)
            : Loc.Format(Strings.Explorer_Finished, saved, total);
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
