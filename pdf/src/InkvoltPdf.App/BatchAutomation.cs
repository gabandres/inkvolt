using System.Collections.ObjectModel;
using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>The presets saved on this PC: JSON files in the data folder's "presets" (one per preset, named after it).</summary>
internal static class PresetLibrary
{
    public static string Folder => Path.Combine(AppPaths.DataDirectory, "presets");

    /// <summary>The saved presets by name (files that can't be read are left out and logged).</summary>
    public static List<(string Name, string Path)> List()
    {
        var list = new List<(string, string)>();
        if (!Directory.Exists(Folder)) return list;
        foreach (var path in Directory.EnumerateFiles(Folder, "*" + BatchPresets.Extension).Order(StringComparer.CurrentCultureIgnoreCase))
        {
            try
            {
                list.Add((BatchPresets.Load(path).Name, path));
            }
            catch (BatchPresetException ex)
            {
                Log.Write($"Preset {Log.Name(path)} left out: {ex.Message}");
            }
        }
        return list;
    }

    public static string PathFor(string name) => Path.Combine(Folder, BatchPresets.FileName(name));

    public static string Save(BatchPreset preset)
    {
        var path = PathFor(preset.Name);
        BatchPresets.Save(preset, path);
        return path;
    }
}

/// <summary>The Pro check's face in the app: <see cref="Pro.Allows"/>; a feature that isn't unlocked opens <see cref="ProWindow"/> on what it does.</summary>
internal static class ProGate
{
    public static bool Check(Window owner, ProFeature feature)
    {
        if (Pro.Allows(feature)) return true;
        ProWindow.Open(owner, feature);
        return false;
    }
}

/// <summary>One watched folder in the app, with what it has done since the app started.</summary>
internal sealed class FolderWatch(AppSettings.WatchSetting setting)
{
    public AppSettings.WatchSetting Setting { get; } = setting;
    public string PresetName { get; private set; } = Path.GetFileNameWithoutExtension(setting.Preset);
    public string Output { get; private set; } = "";
    public string Status { get; private set; } = Strings.Batch_Stopped;
    public bool HasProblem { get; private set; }
    public int Done { get; private set; }
    public int Failed { get; private set; }
    public bool IsRunning => _run is { IsCompleted: false };

    private CancellationTokenSource? _cts;
    private Task? _run;

    /// <summary>
    /// Starts watching. A preset with Protect needs its passwords, asked here and kept in memory only (they aren't saved):
    /// without <paramref name="owner"/> (the app starting) it waits, saying so, until Start is clicked.
    /// </summary>
    public void Start(Window? owner)
    {
        if (IsRunning) return;
        if (!Pro.Allows(ProFeature.WatchedFolders))
        {
            Show(Pro.Locked(ProFeature.WatchedFolders), problem: true);
            return;
        }
        BatchPreset preset;
        try
        {
            preset = BatchPresets.Load(Setting.Preset);
        }
        catch (BatchPresetException ex)
        {
            Show(Loc.Format(Strings.Batch_NotWatching, ex.Message), problem: true);
            return;
        }
        PresetName = preset.Name;
        var steps = preset.Steps;
        // Long-term data goes online, which needs a person to see the addresses each run asks (LtvDialogs): said once,
        // here, rather than as a failure on every file the folder receives.
        if (steps.Any(s => s is AddLongTermStep))
        {
            Show(Loc.Format(Strings.Batch_NotWatching, Strings.Batch_WatchNotOnline), problem: true);
            return;
        }
        if (steps.OfType<ProtectStep>().Any(p => p.NeedsPasswords))
        {
            if (owner is null || SecurityActions.AskProtection(owner, Strings.Batch_WatchPasswordsTitle, Strings.Batch_Start, null,
                    Loc.Format(Strings.Batch_WatchPasswordsNote, preset.Name)) is not { } c)
            {
                Show(Strings.Batch_PausedPassword, problem: true);
                return;
            }
            steps = BatchPresets.WithPasswords(steps, c.UserPassword, c.OwnerPassword);
        }
        Output = Setting.Output is { Length: > 0 } o ? o : preset.OutputFolder ?? WatchedFolder.DefaultOutput(Setting.Folder);
        var plan = preset.ToPlan(Output) with { Steps = steps };
        var ocr = PageOcr.Engine;
        if ((WatchedFolder.Validate(Setting.Folder, Output) ?? plan.Validate(ocr is not null)) is { } error)
        {
            Show(Loc.Format(Strings.Batch_NotWatching, error), problem: true);
            return;
        }
        var host = new BatchHost
        {
            Ocr = PageOcr.ForBatch(ocr),
        };
        var progress = new Progress<WatchProgress>(p =>
        {
            if (p.Finished is { } e)
            {
                if (e.State == BatchItemState.Done) Done++;
                else Failed++;
                if (e.State != BatchItemState.Done) Log.Write($"Watched folder: {Log.Name(e.FileName)}: {e.State}: {e.Message}");
            }
            Show(p.Working > 0 ? Loc.Plural(p.Working, Strings.Batch_WorkingOn_One, Strings.Batch_WorkingOn_Many, Counts) : Watching(e: p.Finished));
        });
        Setting.Paused = false;
        _cts = new CancellationTokenSource();
        var token = _cts.Token;
        Show(Watching());
        Log.Write($"Watching {Log.Name(Setting.Folder)} with preset {Log.Name(Setting.Preset)}");
        // On a worker thread: closing the app waits for it (StopAll) without needing the UI thread.
        _run = Task.Run(async () =>
        {
            try
            {
                await WatchedFolder.RunAsync(Setting.Folder, plan, host, null, progress, token);
                Ui(() => Show(Strings.Batch_Stopped));
            }
            catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
            {
                Log.Write($"Watched folder {Log.Name(Setting.Folder)} stopped: {ex.Message}");
                Ui(() => Show(Loc.Format(Strings.Batch_NotWatching, ex.Message), problem: true));
            }
        });
    }

    public void Stop()
    {
        _cts?.Cancel();
        Setting.Paused = true;
        Show(Strings.Batch_Stopping);
    }

    /// <summary>Stops and waits (up to <paramref name="wait"/>) so files being worked on go back rather than stay in "working".</summary>
    public void StopAndWait(TimeSpan wait)
    {
        _cts?.Cancel();
        try
        {
            _run?.Wait(wait);
        }
        catch (AggregateException) { }
    }

    private string Counts => Done + Failed == 0 ? "" : Failed > 0 ? Loc.Format(Strings.Batch_CountsFailed, Done, Failed) : Loc.Format(Strings.Batch_Counts, Done);

    private string Watching(WatchEntry? e = null) =>
        (Loc.Format(Strings.Batch_Watching, Counts) + (e is null ? "" : " " + Loc.Format(Strings.Batch_WatchLast, e.FileName, StateWord(e.State), e.Time))).TrimEnd();

    private static string StateWord(BatchItemState s) => s switch
    {
        BatchItemState.Done => Strings.Batch_StateDone,
        BatchItemState.Failed => Strings.Batch_StateFailed,
        BatchItemState.Skipped => Strings.Batch_StateSkipped,
        BatchItemState.Cancelled => Strings.Batch_StateCancelled,
        _ => s.ToString().ToLowerInvariant(),
    };

    private void Show(string status, bool problem = false)
    {
        Status = status;
        HasProblem = problem;
        FolderWatches.RaiseChanged();
    }

    private static void Ui(Action action) => Application.Current?.Dispatcher.BeginInvoke(action);
}

/// <summary>
/// The app's watched folders (Batch › Watched Folders): kept in the settings, started when the app starts and stopped when
/// it closes, so a folder is watched while Inkvolt PDF is open, with its status in the title bar and the Watched Folders
/// window. For a folder watched with the app closed: <c>inkvoltpdf --watch</c> in a terminal or a scheduled task.
/// </summary>
internal static class FolderWatches
{
    public static ObservableCollection<FolderWatch> All { get; } = [];

    /// <summary>A watch started, stopped, or finished a file (on the UI thread).</summary>
    public static event Action? Changed;

    public static void RaiseChanged() => Changed?.Invoke();

    /// <summary>The watches saved in the settings; started unless the user stopped them.</summary>
    public static void StartSaved()
    {
        foreach (var setting in AppSettings.Current.WatchedFolders)
        {
            var watch = new FolderWatch(setting);
            All.Add(watch);
            if (!setting.Paused) watch.Start(null);
        }
        RaiseChanged();
    }

    /// <summary>Adds a watch, saves it in the settings and starts it.</summary>
    public static FolderWatch Add(Window owner, string folder, string preset, string output)
    {
        var setting = new AppSettings.WatchSetting { Folder = folder, Preset = preset, Output = output };
        AppSettings.Current.WatchedFolders.Add(setting);
        AppSettings.Current.Save();
        var watch = new FolderWatch(setting);
        All.Add(watch);
        watch.Start(owner);
        RaiseChanged();
        return watch;
    }

    public static void Remove(FolderWatch watch)
    {
        watch.Stop();
        All.Remove(watch);
        AppSettings.Current.WatchedFolders.Remove(watch.Setting);
        AppSettings.Current.Save();
        RaiseChanged();
    }

    public static void SaveState() => AppSettings.Current.Save();

    /// <summary>Closing the app: stop them all, giving the files being worked on a few seconds to finish or go back.</summary>
    public static void StopAll()
    {
        var running = All.Where(w => w.IsRunning).ToList();
        if (running.Count == 0) return;
        var until = DateTime.UtcNow.AddSeconds(10);
        foreach (var w in running) w.StopAndWait(TimeSpan.Zero);
        foreach (var w in running) w.StopAndWait(until - DateTime.UtcNow is { Ticks: > 0 } left ? left : TimeSpan.Zero);
    }

    /// <summary>For the title bar: "Watching 2 folders", or what needs a look; null when no folder is watched.</summary>
    public static string? Summary
    {
        get
        {
            if (All.Count == 0) return null;
            var running = All.Count(w => w.IsRunning);
            if (All.Any(w => w.HasProblem)) return Strings.Batch_WatchNeedsLook;
            return running == 0 ? Strings.Batch_WatchStopped : Loc.Plural(running, Strings.Batch_WatchingFolders_One, Strings.Batch_WatchingFolders_Many);
        }
    }
}

/// <summary>Batch › Watched Folders: the folders watched while the app is open, each with its preset, status and log.</summary>
internal sealed class WatchWindow : Window
{
    private static WatchWindow? _open;
    private readonly StackPanel _list = new();

    public static WatchWindow Open(Window owner)
    {
        if (_open is { } existing)
        {
            existing.Activate();
            return existing;
        }
        var w = new WatchWindow(owner);
        _open = w;
        w.Closed += (_, _) =>
        {
            FolderWatches.Changed -= w.Refresh;
            _open = null;
        };
        w.Show();
        return w;
    }

    private WatchWindow(Window owner)
    {
        Owner = owner;
        Title = Strings.Batch_WatchedFolders;
        Width = 720;
        Height = 520;
        MinWidth = 520;
        MinHeight = 360;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var caption = (Style)Application.Current.FindResource("Caption");

        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        heading.Children.Add(new TextBlock { Text = Strings.Batch_WatchedFolders, FontSize = 20, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock
        {
            Text = Strings.Batch_WatchIntro,
            Style = caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });
        var scroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetName(_list, Strings.Batch_WatchedFoldersName);
        var body = new DockPanel { Margin = new Thickness(24, 20, 24, 16) };
        DockPanel.SetDock(heading, Dock.Top);
        body.Children.Add(heading);
        body.Children.Add(scroll);

        var add = new Button { Content = Strings.Batch_WatchAFolder, MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        add.SetResourceReference(StyleProperty, "AccentButtonStyle");
        add.Click += (_, _) => AskAdd();
        var close = new Button { Content = Strings.Common_Close, MinWidth = 104, IsCancel = true };
        close.Click += (_, _) => Close();
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(24, 16, 24, 16) };
        buttons.Children.Add(add);
        buttons.Children.Add(close);
        var footer = new Border { Child = buttons, BorderThickness = new Thickness(0, 1, 0, 0) };
        footer.SetResourceReference(Border.BackgroundProperty, "LayerFillColorDefaultBrush");
        footer.SetResourceReference(Border.BorderBrushProperty, "DividerStrokeColorDefaultBrush");
        var root = new DockPanel();
        DockPanel.SetDock(footer, Dock.Bottom);
        root.Children.Add(footer);
        root.Children.Add(body);
        Content = root;

        FolderWatches.Changed += Refresh;
        Refresh();
    }

    private void Refresh()
    {
        var caption = (Style)Application.Current.FindResource("Caption");
        _list.Children.Clear();
        if (!Pro.Allows(ProFeature.WatchedFolders))
        {
            // Locked: say what it does and where Pro is; the folders listed below stay as they are (nothing made is taken away).
            var banner = new Border { Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 12), CornerRadius = new CornerRadius(6) };
            banner.SetResourceReference(Border.BackgroundProperty, "SystemFillColorAttentionBackgroundBrush");
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = Pro.Locked(ProFeature.WatchedFolders), FontWeight = FontWeights.SemiBold });
            text.Children.Add(new TextBlock { Text = Pro.Describe(ProFeature.WatchedFolders), TextWrapping = TextWrapping.Wrap, Style = caption, Margin = new Thickness(0, 4, 0, 8) });
            text.Children.Add(Small(Strings.Batch_AboutPro, () => ProWindow.Open(this, ProFeature.WatchedFolders)));
            banner.Child = text;
            _list.Children.Add(banner);
        }
        if (FolderWatches.All.Count == 0)
            _list.Children.Add(new TextBlock { Text = Strings.Batch_NoFolder, Style = caption, TextWrapping = TextWrapping.Wrap });
        foreach (var w in FolderWatches.All)
        {
            var card = new Border { Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 8), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
            card.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
            card.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
            var panel = new StackPanel();
            panel.Children.Add(new TextBlock { Text = w.Setting.Folder, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = w.Setting.Folder });
            panel.Children.Add(new TextBlock
            {
                Text = w.Output.Length > 0 ? Loc.Format(Strings.Batch_PresetResults, w.PresetName, w.Output) : Loc.Format(Strings.Batch_PresetLine, w.PresetName),
                Style = caption, TextTrimming = TextTrimming.CharacterEllipsis,
            });
            var status = new TextBlock { Text = w.Status, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 6) };
            if (w.HasProblem) status.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
            panel.Children.Add(status);
            var actions = new WrapPanel();
            actions.Children.Add(Small(w.IsRunning ? Strings.Common_Stop : Strings.Batch_Start, () =>
            {
                if (w.IsRunning) w.Stop();
                else w.Start(this);
                FolderWatches.SaveState();
            }));
            actions.Children.Add(Small(Strings.FormData_OpenFolder, () => Shell.Open(w.Setting.Folder)));
            actions.Children.Add(Small(Strings.Batch_OpenLog, () =>
            {
                var log = Path.Combine(w.Setting.Folder, WatchedFolder.LogName);
                if (File.Exists(log)) Shell.Open(log);
                else Prompt.Info(this, Strings.Batch_NoLog, Strings.Batch_NoLogBody);
            }));
            actions.Children.Add(Small(Strings.Common_Remove, () =>
            {
                if (Prompt.Confirm(this, Strings.Batch_StopWatching, Loc.Format(Strings.Batch_StopWatchingBody, w.Setting.Folder), Strings.Common_Remove))
                    FolderWatches.Remove(w);
            }));
            panel.Children.Add(actions);
            card.Child = panel;
            AutomationProperties.SetName(card, $"{w.Setting.Folder}: {w.Status}"); // in every language: only names and values, no words
            _list.Children.Add(card);
        }
    }

    private static Button Small(string text, Action onClick)
    {
        var b = new Button { Content = text, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 3, 10, 3) };
        b.Click += (_, _) => onClick();
        return b;
    }

    /// <summary>Watch a Folder…: the folder, the preset (one saved on this PC) and, if not the preset's own, where results go.</summary>
    private void AskAdd()
    {
        if (!ProGate.Check(this, ProFeature.WatchedFolders)) return;
        var presets = PresetLibrary.List();
        if (presets.Count == 0)
        {
            Prompt.Info(this, Strings.Batch_SavePresetFirst, Strings.Batch_SavePresetFirstBody);
            return;
        }
        var dlg = new FormDialog(this, Strings.Batch_WatchFolderTitle, Strings.Batch_Watch, 520);
        var folder = new TextBox();
        AutomationProperties.SetName(folder, Strings.Batch_FolderToWatch);
        dlg.Add(Strings.Batch_FolderToWatch, Browsing(folder, Strings.Batch_WatchThisFolder));
        var preset = dlg.AddChoice(Strings.Batch_Preset, presets.Select(p => p.Name));
        var output = new TextBox();
        AutomationProperties.SetName(output, Strings.Batch_SaveResultsTo);
        dlg.Add(Strings.Batch_SaveResultsTo, Browsing(output, Strings.Batch_SaveTheResultsTo));
        dlg.AddNote(Strings.Batch_EmptyOutputNote);
        dlg.Validate(() =>
        {
            var f = folder.Text.Trim().Trim('"');
            if (FolderWatches.All.Any(w => string.Equals(Path.GetFullPath(w.Setting.Folder), f, StringComparison.OrdinalIgnoreCase))) return Strings.Batch_AlreadyWatched;
            var o = output.Text.Trim().Trim('"');
            if (o.Length > 0 && !Path.IsPathFullyQualified(o)) return Strings.Batch_FullPath;
            return WatchedFolder.Validate(f, o.Length > 0 ? o : Path.IsPathFullyQualified(f) ? WatchedFolder.DefaultOutput(f) : "");
        });
        if (!dlg.ShowModal()) return;
        FolderWatches.Add(this, Path.GetFullPath(folder.Text.Trim().Trim('"')), presets[Math.Max(0, preset.SelectedIndex)].Path, output.Text.Trim().Trim('"'));
    }

    private DockPanel Browsing(TextBox box, string title)
    {
        var browse = new Button { Content = Strings.Common_Browse, Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
        browse.Click += (_, _) =>
        {
            if (PdfFiles.PickFolder(this, title, Directory.Exists(box.Text) ? box.Text : null) is { } f) box.Text = f;
        };
        var row = new DockPanel();
        DockPanel.SetDock(browse, Dock.Right);
        row.Children.Add(browse);
        row.Children.Add(box);
        return row;
    }

    internal string DevState() => string.Join(" | ", FolderWatches.All.Select(w => $"{w.Setting.Folder}: {w.PresetName}: {w.Status}"));
}
