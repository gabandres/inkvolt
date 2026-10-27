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

/// <summary>The Pro check's face in the app: <see cref="Pro.Allows"/>, and a word on what isn't unlocked.</summary>
internal static class ProGate
{
    public static bool Check(Window owner, ProFeature feature)
    {
        if (Pro.Allows(feature)) return true;
        Prompt.Info(owner, "Inkvolt Pro", Pro.Locked(feature));
        return false;
    }
}

/// <summary>One watched folder in the app, with what it has done since the app started.</summary>
internal sealed class FolderWatch(AppSettings.WatchSetting setting)
{
    public AppSettings.WatchSetting Setting { get; } = setting;
    public string PresetName { get; private set; } = Path.GetFileNameWithoutExtension(setting.Preset);
    public string Output { get; private set; } = "";
    public string Status { get; private set; } = "Stopped";
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
            Show($"Not watching: {ex.Message}", problem: true);
            return;
        }
        PresetName = preset.Name;
        var steps = preset.Steps;
        if (steps.OfType<ProtectStep>().Any(p => p.NeedsPasswords))
        {
            if (owner is null || SecurityActions.AskProtection(owner, "Passwords for the Watched Folder", "Start", null,
                    $"\"{preset.Name}\" protects each file with a password. Type the passwords: they are kept only while Inkvolt PDF is open, never saved.") is not { } c)
            {
                Show("Paused: the preset protects files with a password, which isn't saved. Start to type it.", problem: true);
                return;
            }
            steps = BatchPresets.WithPasswords(steps, c.UserPassword, c.OwnerPassword);
        }
        Output = Setting.Output is { Length: > 0 } o ? o : preset.OutputFolder ?? WatchedFolder.DefaultOutput(Setting.Folder);
        var plan = preset.ToPlan(Output) with { Steps = steps };
        var ocr = PageOcr.Engine;
        if ((WatchedFolder.Validate(Setting.Folder, Output) ?? plan.Validate(ocr is not null)) is { } error)
        {
            Show($"Not watching: {error}", problem: true);
            return;
        }
        var ocrGate = new Lock();
        var host = new BatchHost
        {
            Recognize = ocr is null ? null : (engine, page, cancel) =>
            {
                lock (ocrGate) return PageOcr.Recognize(ocr, engine, page, cancel);
            },
        };
        var progress = new Progress<WatchProgress>(p =>
        {
            if (p.Finished is { } e)
            {
                if (e.State == BatchItemState.Done) Done++;
                else Failed++;
                if (e.State != BatchItemState.Done) Log.Write($"Watched folder: {Log.Name(e.FileName)}: {e.State}: {e.Message}");
            }
            Show(p.Working > 0 ? $"Working on {Files(p.Working)}… {Counts}" : Watching(e: p.Finished));
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
                Ui(() => Show("Stopped"));
            }
            catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException)
            {
                Log.Write($"Watched folder {Log.Name(Setting.Folder)} stopped: {ex.Message}");
                Ui(() => Show($"Not watching: {ex.Message}", problem: true));
            }
        });
    }

    public void Stop()
    {
        _cts?.Cancel();
        Setting.Paused = true;
        Show("Stopping: the files being worked on finish their current action…");
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

    private string Counts => Done + Failed == 0 ? "" : $"{Done:N0} done{(Failed > 0 ? $", {Failed:N0} failed" : "")} since Inkvolt PDF started.";

    private string Watching(WatchEntry? e = null) =>
        $"Watching. {Counts}{(e is null ? "" : $" Last: {e.FileName}, {e.State.ToString().ToLowerInvariant()} at {e.Time:t}.")}".TrimEnd();

    private static string Files(int n) => n == 1 ? "1 file" : $"{n:N0} files";

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
            if (All.Any(w => w.HasProblem)) return "Watched folder needs a look";
            return running == 0 ? "Watched folders stopped" : running == 1 ? "Watching 1 folder" : $"Watching {running} folders";
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
        Title = "Watched Folders";
        Width = 720;
        Height = 520;
        MinWidth = 520;
        MinHeight = 360;
        ShowInTaskbar = false;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        var caption = (Style)Application.Current.FindResource("Caption");

        var heading = new StackPanel { Margin = new Thickness(0, 0, 0, 14) };
        heading.Children.Add(new TextBlock { Text = "Watched Folders", FontSize = 20, FontWeight = FontWeights.SemiBold });
        heading.Children.Add(new TextBlock
        {
            Text = "Each PDF or image put in a watched folder runs through its preset once it has stopped growing; the original moves to \"done\" or \"failed\" " +
                   "in that folder, and inkvolt-watch.log there gets a line for it. Folders are watched while Inkvolt PDF is open; with it closed, use " +
                   "inkvoltpdf --watch <folder> --preset <file> in a terminal or a scheduled task.",
            Style = caption, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 0),
        });
        var scroll = new ScrollViewer { Content = _list, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        AutomationProperties.SetName(_list, "Watched folders");
        var body = new DockPanel { Margin = new Thickness(24, 20, 24, 16) };
        DockPanel.SetDock(heading, Dock.Top);
        body.Children.Add(heading);
        body.Children.Add(scroll);

        var add = new Button { Content = "Watch a Folder…", MinWidth = 104, Margin = new Thickness(0, 0, 8, 0), IsDefault = true };
        add.SetResourceReference(StyleProperty, "AccentButtonStyle");
        add.Click += (_, _) => AskAdd();
        var close = new Button { Content = "Close", MinWidth = 104, IsCancel = true };
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
        if (FolderWatches.All.Count == 0)
            _list.Children.Add(new TextBlock { Text = "No folder is watched. Watch a Folder chooses one and the preset it runs.", Style = caption, TextWrapping = TextWrapping.Wrap });
        foreach (var w in FolderWatches.All)
        {
            var card = new Border { Padding = new Thickness(14, 10, 14, 10), Margin = new Thickness(0, 0, 0, 8), CornerRadius = new CornerRadius(6), BorderThickness = new Thickness(1) };
            card.SetResourceReference(Border.BackgroundProperty, "CardBackgroundFillColorDefaultBrush");
            card.SetResourceReference(Border.BorderBrushProperty, "CardStrokeColorDefaultBrush");
            var panel = new StackPanel();
            panel.Children.Add(new TextBlock { Text = w.Setting.Folder, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis, ToolTip = w.Setting.Folder });
            panel.Children.Add(new TextBlock
            {
                Text = $"Preset: {w.PresetName}{(w.Output.Length > 0 ? $" · Results: {w.Output}" : "")}",
                Style = caption, TextTrimming = TextTrimming.CharacterEllipsis,
            });
            var status = new TextBlock { Text = w.Status, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 4, 0, 6) };
            if (w.HasProblem) status.SetResourceReference(TextBlock.ForegroundProperty, "SystemFillColorCriticalBrush");
            panel.Children.Add(status);
            var actions = new WrapPanel();
            actions.Children.Add(Small(w.IsRunning ? "Stop" : "Start", () =>
            {
                if (w.IsRunning) w.Stop();
                else w.Start(this);
                FolderWatches.SaveState();
            }));
            actions.Children.Add(Small("Open Folder", () => Shell.Open(w.Setting.Folder)));
            actions.Children.Add(Small("Open Log", () =>
            {
                var log = Path.Combine(w.Setting.Folder, WatchedFolder.LogName);
                if (File.Exists(log)) Shell.Open(log);
                else Prompt.Info(this, "No log yet", "The log is written when the first file is finished.");
            }));
            actions.Children.Add(Small("Remove", () =>
            {
                if (Prompt.Confirm(this, "Stop watching this folder?", $"{w.Setting.Folder} is no longer watched. Its files, \"done\" and \"failed\" stay as they are.", "Remove"))
                    FolderWatches.Remove(w);
            }));
            panel.Children.Add(actions);
            card.Child = panel;
            AutomationProperties.SetName(card, $"{w.Setting.Folder}: {w.Status}");
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
            Prompt.Info(this, "Save a preset first", "A watched folder runs a saved preset. In Batch, choose the actions, then Save Preset.");
            return;
        }
        var dlg = new FormDialog(this, "Watch a Folder", "Watch", 520);
        var folder = new TextBox();
        AutomationProperties.SetName(folder, "Folder to watch");
        dlg.Add("Folder to watch", Browsing(folder, "Watch this folder"));
        var preset = dlg.AddChoice("Preset", presets.Select(p => p.Name));
        var output = new TextBox();
        AutomationProperties.SetName(output, "Save results to");
        dlg.Add("Save results to", Browsing(output, "Save the results to"));
        dlg.AddNote("Empty: the preset's folder, or a \"results\" folder inside the watched one.");
        dlg.Validate(() =>
        {
            var f = folder.Text.Trim().Trim('"');
            if (FolderWatches.All.Any(w => string.Equals(Path.GetFullPath(w.Setting.Folder), f, StringComparison.OrdinalIgnoreCase))) return "That folder is watched already.";
            var o = output.Text.Trim().Trim('"');
            if (o.Length > 0 && !Path.IsPathFullyQualified(o)) return "Give the results folder as a full path, or leave it empty.";
            return WatchedFolder.Validate(f, o.Length > 0 ? o : Path.IsPathFullyQualified(f) ? WatchedFolder.DefaultOutput(f) : "");
        });
        if (!dlg.ShowModal()) return;
        FolderWatches.Add(this, Path.GetFullPath(folder.Text.Trim().Trim('"')), presets[Math.Max(0, preset.SelectedIndex)].Path, output.Text.Trim().Trim('"'));
    }

    private DockPanel Browsing(TextBox box, string title)
    {
        var browse = new Button { Content = "Browse…", Margin = new Thickness(6, 0, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
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
