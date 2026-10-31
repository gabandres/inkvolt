using System.Collections.Specialized;
using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;
using Microsoft.Win32;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.Core.Alerts;

namespace InkvoltPrint.App.Tray;

/// <summary>
/// The notification-area icon and its alerts, when turned on (<see cref="TraySettings.Enabled"/>; off by default). The icon shows
/// the worst state across the remembered printers (<see cref="AlertTracker.Overall"/>), its tooltip a line per printer, its
/// menu the printers, scan presets, pause and quit. Closing the window then leaves Inkvolt Print running here: the printers'
/// live connections stop (<see cref="PrinterViewModel.Suspend"/>) and each printer is read every 5 minutes instead (15 on
/// battery or a metered network, backing off to an hour from one that doesn't answer; nothing at all with no printers or no
/// network), with the same read-only status calls as the window. Whichever reads a printer, the window or these checks,
/// feeds the <see cref="AlertTracker"/>, whose alerts go out as toast notifications, one per printer with Open printer and
/// Pause alerts buttons (<see cref="ToastAlerts"/>), or where those aren't available as the icon's balloons; clicking one
/// opens that printer.
/// </summary>
public sealed class TrayController : IDisposable
{
    private readonly Application _app;
    private readonly MainViewModel _vm;
    private readonly AppState _state;
    private readonly TraySettings _settings;
    private AlertTracker _tracker;
    private readonly DispatcherTimer _timer;
    private readonly HashSet<PrinterViewModel> _watched = [];
    private readonly Dictionary<string, (DateTimeOffset Due, int Failures, DateTimeOffset Checked)> _schedule = new(StringComparer.OrdinalIgnoreCase);
    private NotifyIcon? _icon;
    private ToastAlerts? _toasts;
    private bool _toastsTried;
    private CancellationTokenSource? _poll, _wake;
    private string? _noticeUuid, _savedShown;
    private bool _hidden, _powerEvents, _alertsOn;

    public TrayController(Application app, MainViewModel vm, AppState state, PcEnvironment pc)
    {
        _app = app;
        _vm = vm;
        _state = state;
        _pc = pc;
        _settings = state.Tray ??= new TraySettings();
        _tracker = new AlertTracker(Rules(), _settings.Shown.ToDictionary(kv => kv.Key, kv => (IReadOnlyList<string>)kv.Value))
        {
            PausedUntil = _settings.PausedUntil,
        };
        _savedShown = ShownText();
        _alertsOn = _settings.Enabled && _settings.Alerts;
        vm.Printers.CollectionChanged += OnPrintersChanged;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMinutes(1) };
        _timer.Tick += (_, _) =>
        {
            try { Tick(); }
            catch (Exception ex) { Log.Write($"Tray timer: {ex}"); }
        };
        Apply();
        foreach (var p in vm.Printers) Watch(p); // after Apply: the icon exists to show what was read already
    }

    private readonly PcEnvironment _pc;

    /// <summary>Demo mode's made-up PC (for the wording of what isn't offered, and the dev aid's simulated alerts).</summary>
    public bool IsDemo => _pc.IsDemo;

    public TraySettings Settings => _settings;

    /// <summary>Closing the window leaves Inkvolt Print running in the notification area.</summary>
    public bool KeepsRunning => _settings.Enabled;

    public bool IsPaused => _tracker.PausedUntil > DateTimeOffset.Now;

    public DateTimeOffset? PausedUntil => IsPaused ? _tracker.PausedUntil : null;

    /// <summary>The last alerts shown (for the snapshot aid's notification preview).</summary>
    public IReadOnlyList<AlertNotice> LastNotices { get; private set; } = [];

    /// <summary>Raised after settings, state or pause change (the settings dialog listens).</summary>
    public event Action? Changed;

    private AlertRules Rules() => new()
    {
        Enabled = _settings.Alerts,
        LowPercent = _settings.LowPercent,
        Offline = _settings.OfflineAlerts,
        Quiet = _settings.QuietHours ? new QuietHours(new TimeOnly(_settings.QuietFrom, 0), new TimeOnly(_settings.QuietTo, 0)) : null,
    };

    /// <summary>Settings changed: rules, icon on or off, saved.</summary>
    public void Apply()
    {
        _tracker.Rules = Rules();
        // Alerts (or the icon) just turned on: start from scratch, so a problem that's already there (a low toner noticed
        // silently while they were off) is told now instead of counting as shown.
        var alertsOn = _settings.Enabled && _settings.Alerts;
        if (alertsOn && !_alertsOn) ResetTracker();
        _alertsOn = alertsOn;
        if (_settings.Enabled)
        {
            if (_icon is null)
            {
                _icon = new NotifyIcon();
                _icon.Activated += () => ShowWindow();
                _icon.MenuRequested += OpenMenu;
                _icon.BalloonClicked += () => { if (_noticeUuid is { } uuid) OpenPrinter(uuid); else ShowWindow(); };
            }
            if (!_toastsTried)
            {
                _toastsTried = true;
                _toasts = ToastAlerts.TryCreate(IsDemo, HandleToast);
                Log.Write(_toasts is null ? "Alerts go out as the icon's balloons" : "Alerts go out as toast notifications");
            }
            _timer.Start();
            if (!_powerEvents)
            {
                SystemEvents.PowerModeChanged += OnPowerModeChanged;
                _powerEvents = true;
            }
            UpdateIcon();
        }
        else
        {
            _icon?.Dispose();
            _icon = null;
            _timer.Stop();
            if (_hidden) ShowWindow(); // turned off from the menu's settings while hidden: never leave an invisible app behind
        }
        _state.Save();
        Changed?.Invoke();
    }

    private void ResetTracker()
    {
        _tracker = new AlertTracker(Rules()) { PausedUntil = _settings.PausedUntil };
        _settings.Shown.Clear();
        _savedShown = ShownText();
    }

    /// <summary>An unexpected error while the window is in the notification area: said there (details in the log).</summary>
    public void ShowError(string message)
    {
        if (_icon is null) return;
        _noticeUuid = null;
        _icon.Notify("Something went wrong", $"Inkvolt Print is still running. {message} Details were saved to {Log.FilePath}", TrayIcons.Error);
    }

    // ---------------------------------------------------------------- printers and alerts

    private void OnPrintersChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        foreach (var p in e.OldItems?.OfType<PrinterViewModel>() ?? [])
        {
            p.Observed -= OnObserved;
            _watched.Remove(p);
            if (!_vm.Printers.Any(o => string.Equals(o.Uuid, p.Uuid, StringComparison.OrdinalIgnoreCase)))
            {
                _tracker.Forget(p.Uuid);
                _schedule.Remove(p.Uuid);
            }
        }
        foreach (var p in e.NewItems?.OfType<PrinterViewModel>() ?? [])
        {
            Watch(p);
            if (_hidden) p.Suspend(); // found by discovery while hidden: checked like the others
        }
        UpdateIcon();
        _wake?.Cancel();
    }

    private void Watch(PrinterViewModel p)
    {
        if (!_watched.Add(p)) return;
        p.Observed += OnObserved;
        // Read before the tray was set up (demo printers answer at once, while the window is still being built).
        if (p.LastSnapshot is { } snap && _settings.Enabled) Show(_tracker.Observe(snap, DateTimeOffset.Now));
    }

    private void OnObserved(PrinterSnapshot snap)
    {
        if (!_settings.Enabled) return; // icon off: nothing is tracked, nothing saved
        try
        {
            Show(_tracker.Observe(snap, DateTimeOffset.Now));
        }
        catch (Exception ex)
        {
            Log.Write($"Tray update failed: {ex}"); // never let the icon disturb the printer's own connection loop
        }
    }

    private void Tick()
    {
        if (_settings.PausedUntil is { } until && until <= DateTimeOffset.Now)
        {
            _settings.PausedUntil = _tracker.PausedUntil = null;
            _state.Save();
            Changed?.Invoke();
        }
        Show(_tracker.Release(DateTimeOffset.Now)); // quiet hours over
    }

    private void Show(IReadOnlyList<AlertNotice> notices)
    {
        if (notices.Count > 0 && _icon is not null)
        {
            LastNotices = notices;
            var (title, text) = NoticeText(notices);
            _noticeUuid = notices[0].Uuid;
            // One toast per printer; a balloon for all of them where toasts aren't available (Windows shows one balloon at a time).
            var toasted = _toasts is not null && AlertToasts.PerPrinter(notices).All(_toasts.Show);
            if (!toasted) _icon.Notify(title, text, IconFor(notices.Max(n => n.Level)));
            Log.Write($"Alert shown ({(toasted ? "toast" : "balloon")}): {string.Join(", ", notices.Select(n => n.Kind))}"); // kinds only, no names or addresses
            Prompt.Announce(title);
        }
        UpdateIcon();
        var shown = ShownText();
        if (shown != _savedShown)
        {
            _savedShown = shown;
            _settings.Shown = _tracker.Shown().ToDictionary(kv => kv.Key, kv => kv.Value.ToList(), StringComparer.OrdinalIgnoreCase);
            _state.Save();
        }
    }

    private string ShownText() => JsonSerializer.Serialize(_tracker.Shown().OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase));

    /// <summary>A balloon's text. One alert: its own title and text. Several at once (Windows shows one balloon at a time): a line each.</summary>
    public static (string Title, string Text) NoticeText(IReadOnlyList<AlertNotice> notices) =>
        notices.Count == 1
            ? (notices[0].Title, notices[0].Body)
            : ($"{notices.Count} printer alerts", string.Join("\n", notices.Select(n => $"{n.PrinterName}: {n.Title}")));

    /// <summary>A toast's body or button was clicked (also a toast clicked after the packaged app exited, at its next start).</summary>
    public void HandleToast(string? arguments)
    {
        switch (AlertToasts.ParseArguments(arguments))
        {
            case (ToastAction.OpenPrinter, var uuid):
                OpenPrinter(uuid);
                break;
            case (ToastAction.PauseAlerts, _):
                Pause(AlertToasts.PauseFor);
                Log.Write("Alerts paused from a notification");
                break;
            default:
                ShowWindow();
                break;
        }
    }

    private static string IconFor(AlertLevel level) => level switch
    {
        AlertLevel.Error => TrayIcons.Error,
        AlertLevel.Warning => TrayIcons.Warning,
        AlertLevel.Offline => TrayIcons.Offline,
        _ => TrayIcons.Ok,
    };

    public IReadOnlyList<(PrinterViewModel Printer, PrinterLine Line)> Lines() =>
        _vm.Printers.Select(p => (p, new PrinterLine(p.Name, Max(_tracker.Level(p.Uuid), !p.IsOnline && !p.IsConnecting ? AlertLevel.Offline : AlertLevel.Ok),
            _tracker.Problem(p.Uuid) ?? p.StatusMessage))).ToList();

    /// <summary>A printer not answering right now shows grey in the menu at once; the icon waits for the offline hold.</summary>
    private static AlertLevel Max(AlertLevel a, AlertLevel b) => a > b ? a : b;

    public AlertLevel Overall => _tracker.Overall;

    private void UpdateIcon() => _icon?.Show(IconFor(_tracker.Overall), TrayText.Tooltip(Lines().Select(l => l.Line).ToList(), IsPaused));

    /// <summary>Demo mode (snapshot aid <c>--simulate-alerts</c>): a toner drop on the first printer and a jam on the second, as
    /// if read twice two minutes apart, through the same rules as real reads.</summary>
    public void Simulate()
    {
        if (!IsDemo) return;
        var now = DateTimeOffset.Now;
        var notices = new List<AlertNotice>();
        if (_vm.Printers.ElementAtOrDefault(0) is { } laser)
        {
            var toner = laser.Supplies.Select(s => s.Supply).Select(c => c.Kind.Contains("toner", StringComparison.OrdinalIgnoreCase) || c.Name.Contains("toner", StringComparison.OrdinalIgnoreCase)
                ? c with { PercentRemaining = 9, State = "low", EstimatedPagesRemaining = 140 } : c).ToList();
            var status = new Core.Model.PrinterStatus("ready", "Ready", Core.Model.Severity.Info, []);
            notices.AddRange(_tracker.Observe(new PrinterSnapshot(laser.Uuid, laser.Name, true, status, toner), now));
        }
        if (_vm.Printers.ElementAtOrDefault(1) is { } inkjet)
        {
            var jam = new Core.Model.PrinterStatus("stopped", "Paper jam", Core.Model.Severity.Error,
                [new Core.Model.PrinterAlert("media-jam", Core.Model.Severity.Error, "Paper jam")]);
            var supplies = inkjet.Supplies.Select(s => s.Supply).ToList();
            _tracker.Observe(new PrinterSnapshot(inkjet.Uuid, inkjet.Name, true, jam, supplies), now.AddMinutes(-2));
            notices.AddRange(_tracker.Observe(new PrinterSnapshot(inkjet.Uuid, inkjet.Name, true, jam, supplies), now));
        }
        Show(notices); // read at the same moment: a toast per printer, or one balloon for both
    }

    // ---------------------------------------------------------------- pause

    public void Pause(TimeSpan? span)
    {
        var until = span is { } s ? DateTimeOffset.Now + s : TomorrowMorning();
        _settings.PausedUntil = _tracker.PausedUntil = until;
        _state.Save();
        UpdateIcon();
        Changed?.Invoke();
    }

    public void ResumeAlerts()
    {
        _settings.PausedUntil = _tracker.PausedUntil = null;
        _state.Save();
        UpdateIcon();
        Changed?.Invoke();
    }

    private static DateTimeOffset TomorrowMorning() => new DateTimeOffset(DateTime.Today.AddDays(1).AddHours(8));

    // ---------------------------------------------------------------- window

    /// <summary>The window's close button with the icon on: hide instead (unsaved scans stay in memory).</summary>
    public void HideWindow(bool atStartup = false)
    {
        if (_app.MainWindow is not { } w) return;
        if (w.IsVisible) w.Hide();
        if (_hidden) return;
        _hidden = true;
        foreach (var p in _vm.Printers) p.Suspend();
        StartPolling(atStartup ? TimeSpan.FromMinutes(1) : null);
        if (!_settings.HintShown && !atStartup && _icon is not null)
        {
            _settings.HintShown = true;
            _state.Save();
            _noticeUuid = null;
            _icon.Notify("Inkvolt Print is still running",
                "It checks your printers now and then and tells you about low supplies, jams and other problems. Quit from this icon's menu.",
                TrayIcons.Ok);
        }
    }

    public void ShowWindow()
    {
        if (_app.MainWindow is not { } w) return;
        StopPolling();
        if (_hidden)
        {
            _hidden = false;
            foreach (var p in _vm.Printers) p.Resume();
        }
        if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
        w.Show();
        w.Activate();
        w.Topmost = true; // Windows won't let a background process steal focus; flash to the top instead
        w.Topmost = false;
    }

    public void OpenPrinter(string uuid)
    {
        ShowWindow();
        if (_vm.Printers.FirstOrDefault(p => string.Equals(p.Uuid, uuid, StringComparison.OrdinalIgnoreCase)) is { } printer)
        {
            _vm.ShowPrinter(printer);
            printer.SelectedSection = PrinterViewModel.OverviewSection;
        }
    }

    // ---------------------------------------------------------------- polling while hidden

    private void StartPolling(TimeSpan? first)
    {
        StopPolling();
        _schedule.Clear();
        var now = DateTimeOffset.Now;
        foreach (var p in _vm.Printers)
            _schedule[p.Uuid] = (now + (first ?? AlertPolling.Interval(PowerInfo.OnBattery(), PowerInfo.Metered(), 0)), 0, now);
        _poll = new CancellationTokenSource();
        NetworkChange.NetworkAvailabilityChanged += OnNetworkChanged;
        _ = PollAsync(_poll.Token);
    }

    private void StopPolling()
    {
        if (_poll is not null) NetworkChange.NetworkAvailabilityChanged -= OnNetworkChanged;
        _poll?.Cancel();
        _poll = null;
    }

    private async Task PollAsync(CancellationToken ct)
    {
        try
        {
            while (!ct.IsCancellationRequested)
            {
                var now = DateTimeOffset.Now;
                var battery = PowerInfo.OnBattery();
                var metered = PowerInfo.Metered();
                var printers = _vm.Printers.ToList();
                var online = _pc.NetworkUp();
                if (online)
                    foreach (var p in printers)
                    {
                        if (!_schedule.TryGetValue(p.Uuid, out var s)) _schedule[p.Uuid] = s = (now + AlertPolling.Interval(battery, metered, 0), 0, now);
                        if (s.Due > now && !PendingDue(p.Uuid, s.Checked, now)) continue;
                        var ok = await p.CheckOnceAsync(ct);
                        var failures = ok ? 0 : s.Failures + 1;
                        var checkedAt = DateTimeOffset.Now;
                        _schedule[p.Uuid] = (checkedAt + AlertPolling.Interval(battery, metered, failures), failures, checkedAt);
                    }
                // Nothing remembered: no timer at all until a printer appears (OnPrintersChanged wakes this up). No network:
                // wait for it to come back (NetworkAvailabilityChanged wakes this up), at most an hour.
                var next = printers.Count == 0 ? (DateTimeOffset?)null
                    : !online ? now + AlertPolling.Longest
                    : printers.Select(p => _schedule.TryGetValue(p.Uuid, out var s)
                        ? Earliest(s.Due, _tracker.PendingUntil(p.Uuid) is { } pending && pending > s.Checked ? pending : null)
                        : now + AlertPolling.Normal).Min();
                var wait = next is { } n ? n - DateTimeOffset.Now : Timeout.InfiniteTimeSpan;
                if (wait != Timeout.InfiniteTimeSpan && wait < TimeSpan.FromSeconds(5)) wait = TimeSpan.FromSeconds(5);
                using var wake = CancellationTokenSource.CreateLinkedTokenSource(ct);
                _wake = wake;
                try { await Task.Delay(wait, wake.Token); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { } // woken: a printer was added, or the PC woke up
                finally { _wake = null; }
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            Log.Write($"Tray checks stopped: {ex}");
        }
    }

    /// <summary>Snapshot aid (<c>--tray-shot hidden</c>): one background check of every printer right away.</summary>
    internal async Task CheckNowAsync()
    {
        foreach (var p in _vm.Printers.ToList()) await p.CheckOnceAsync(CancellationToken.None);
    }

    /// <summary>A problem seen at the last check is due to be confirmed: check once more (only once per check, never in a loop).</summary>
    private bool PendingDue(string uuid, DateTimeOffset lastChecked, DateTimeOffset now) =>
        _tracker.PendingUntil(uuid) is { } pending && pending <= now && pending > lastChecked;

    private void OnNetworkChanged(object? sender, NetworkAvailabilityEventArgs e)
    {
        if (e.IsAvailable) _app.Dispatcher.InvokeAsync(() => _wake?.Cancel());
    }

    private static DateTimeOffset Earliest(DateTimeOffset a, DateTimeOffset? b) => b is { } x && x < a ? x : a;

    /// <summary>The PC woke up: the time asleep doesn't count toward "offline for 15 minutes"; check again in a minute (network back).</summary>
    private void OnPowerModeChanged(object? sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode != PowerModes.Resume) return;
        _app.Dispatcher.InvokeAsync(() =>
        {
            _tracker.ResetPending();
            var soon = DateTimeOffset.Now + TimeSpan.FromMinutes(1);
            foreach (var key in _schedule.Keys.ToList()) _schedule[key] = _schedule[key] with { Due = soon };
            _wake?.Cancel();
        });
    }

    // ---------------------------------------------------------------- menu

    /// <summary>The icon's menu: open, each printer and its state, scan presets, pause alerts, settings, quit.</summary>
    public ContextMenu BuildMenu()
    {
        var menu = new ContextMenu();
        AutomationName(menu, "Inkvolt Print");
        var open = Item("Open Inkvolt Print", () => ShowWindow());
        open.FontWeight = FontWeights.SemiBold;
        menu.Items.Add(open);
        var lines = Lines();
        if (lines.Count > 0) menu.Items.Add(new Separator());
        foreach (var (printer, line) in lines)
        {
            var uuid = printer.Uuid;
            var item = Item($"{line.Name}: {line.Text}", () => OpenPrinter(uuid));
            item.Icon = new Ellipse { Width = 10, Height = 10, Fill = DotBrush(line.Level) };
            AutomationName(item, $"{line.Name}, {line.Text}. Open");
            menu.Items.Add(item);
        }
        menu.Items.Add(new Separator());
        if (_vm.Presets.Items.Count > 0 && _vm.Printers.Any(p => p.Scan is not null))
        {
            var scan = new MenuItem { Header = "_Scan with" };
            foreach (var preset in _vm.Presets.Items.Take(9))
            {
                var id = preset.Id;
                scan.Items.Add(Item(preset.Name.Replace("_", "__"), () =>
                {
                    ShowWindow();
                    _ = _vm.RunPresetWhenReadyAsync(id);
                }));
            }
            menu.Items.Add(scan);
        }
        if (IsPaused)
        {
            menu.Items.Add(Item($"_Resume alerts (paused until {PausedUntil!.Value.LocalDateTime:t})", ResumeAlerts));
        }
        else
        {
            var pause = new MenuItem { Header = "_Pause alerts", IsEnabled = _settings.Alerts };
            pause.Items.Add(Item("For 1 hour", () => Pause(TimeSpan.FromHours(1))));
            pause.Items.Add(Item("For 8 hours", () => Pause(TimeSpan.FromHours(8))));
            pause.Items.Add(Item("Until tomorrow morning", () => Pause(null)));
            menu.Items.Add(pause);
        }
        menu.Items.Add(Item("_Alert settings…", () => Views.SettingsWindow.Open(_app.MainWindow is { IsVisible: true } w ? w : null, _vm, this, alerts: true)));
        menu.Items.Add(new Separator());
        menu.Items.Add(Item("_Quit Inkvolt Print", Quit));
        return menu;
    }

    private static MenuItem Item(string header, Action click)
    {
        var item = new MenuItem { Header = header };
        item.Click += (_, _) => click();
        return item;
    }

    private static void AutomationName(DependencyObject d, string name) => System.Windows.Automation.AutomationProperties.SetName(d, name);

    public static Brush DotBrush(AlertLevel level) => level switch
    {
        AlertLevel.Error => new SolidColorBrush(Color.FromRgb(0xE5, 0x20, 0x2E)),
        AlertLevel.Warning => new SolidColorBrush(Color.FromRgb(0xFF, 0xB9, 0x00)),
        AlertLevel.Offline => new SolidColorBrush(Color.FromRgb(0x76, 0x76, 0x76)),
        _ => new SolidColorBrush(Color.FromRgb(0x10, 0x9F, 0x4A)),
    };

    private ContextMenu? _menu;

    /// <param name="point">Where the shell anchors the menu (the click, or the icon for the keyboard), in DIPs.</param>
    private void OpenMenu(Point point, bool byKeyboard)
    {
        if (_icon is null) return;
        if (_menu is { IsOpen: true }) _menu.IsOpen = false;
        _menu = BuildMenu();
        SetForegroundWindow(_icon.Handle); // else the menu wouldn't close when clicking elsewhere
        _menu.Placement = PlacementMode.AbsolutePoint;
        _menu.HorizontalOffset = point.X;
        _menu.VerticalOffset = point.Y;
        if (byKeyboard) _menu.Opened += (_, _) => (_menu.Items[0] as MenuItem)?.Focus();
        _menu.IsOpen = true;
    }

    /// <summary>Quit from the menu: really closes (asking first about unsaved scans, with the window shown).</summary>
    public void Quit() => (_app as App)?.Quit();

    public void Dispose()
    {
        if (_powerEvents) SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        StopPolling();
        _timer.Stop();
        _icon?.Dispose();
        _icon = null;
        _vm.Printers.CollectionChanged -= OnPrintersChanged;
        foreach (var p in _watched) p.Observed -= OnObserved;
    }

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hwnd);
}
