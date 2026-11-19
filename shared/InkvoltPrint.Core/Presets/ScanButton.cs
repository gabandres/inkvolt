using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Presets;

/// <summary>What the person chose for one printer's scan button (the app keeps it with its settings).</summary>
/// <param name="On">Turned on. Off by default: on an HP panel it adds this PC to the printer's list, a change on the printer.</param>
/// <param name="PresetId">The preset a press runs; null or gone: the first preset.</param>
/// <param name="Destination">This PC's resource on the printer's panel as this app added it, so a run after a crash finds it again.</param>
public sealed record ScanButtonChoice(bool On = false, string? PresetId = null, string? Destination = null);

/// <summary>How a press of the printer's button reaches this PC.</summary>
public enum ScanButtonWay
{
    /// <summary>Not known yet (no connection or scanner has been looked at).</summary>
    Unknown,

    /// <summary>Neither way: the Scan tab says so.</summary>
    None,

    /// <summary>HP's Scan to Computer on the printer's panel (LEDM: <see cref="ScanToComputer"/>).</summary>
    Panel,

    /// <summary>The scanner's button through its Windows driver (WIA: a WSD scanner's <c>ScanAvailableEvent</c>, a USB scanner's button).</summary>
    Driver,
}

/// <summary>
/// One printer's scan button (print/ROADMAP.md 2.2): a press on the printer runs the chosen scan preset on this PC. HP's Scan to
/// Computer when the printer's panel offers it (this PC added to its list while turned on and the app or its notification-area
/// icon runs, removed when turned off and on exit), else the button its Windows scanner's driver reports. Off until the person
/// turns it on. The app hands it each new connection and its Windows scanner; it tells the app <see cref="Changed"/> and each
/// press (both from any thread). Calls are serialized; the app makes them from its dispatcher.
/// </summary>
public sealed class ScanButton
{
    private readonly Action<ScanButtonChoice> _save;
    private readonly Action _pressed;
    private readonly Action<string> _log;
    private readonly SemaphoreSlim _calls = new(1, 1);
    private readonly Lock _gate = new();

    private ScanButtonChoice _choice;
    private ScanToComputer? _panel;
    private bool _panelKnown, _driverKnown;
    private (IWiaSystem System, string DeviceId, IReadOnlyList<string> Buttons)? _driver;
    private CancellationTokenSource? _run;
    private Task _running = Task.CompletedTask;
    private IDisposable? _watch;
    private PanelState? _panelState;
    private bool _driverFailed;

    /// <param name="panelName">This PC's name on the printer's panel (<see cref="LedmWalkupScan.PanelName"/>).</param>
    /// <param name="save">Keeps the choice (with the destination this app added) when it changes.</param>
    /// <param name="pressed">A press: run the chosen preset.</param>
    public ScanButton(string panelName, ScanButtonChoice? choice, Action<ScanButtonChoice> save, Action pressed, Action<string>? log = null)
    {
        PanelName = panelName;
        _choice = choice ?? new ScanButtonChoice();
        _save = save;
        _pressed = pressed;
        _log = log ?? (_ => { });
    }

    public string PanelName { get; }

    /// <summary>Something the Scan tab shows changed.</summary>
    public event Action? Changed;

    public ScanButtonChoice Choice
    {
        get { lock (_gate) return _choice; }
    }

    public bool On => Choice.On;

    /// <summary>How a press reaches this PC: the panel when the printer offers it, else the driver's button.</summary>
    public ScanButtonWay Way
    {
        get
        {
            lock (_gate)
                return _panel is not null ? ScanButtonWay.Panel
                    : _driver is { Buttons.Count: > 0 } ? ScanButtonWay.Driver
                    : _panelKnown || _driverKnown ? ScanButtonWay.None : ScanButtonWay.Unknown;
        }
    }

    /// <summary>The panel's last check (null before one).</summary>
    public PanelState? PanelState
    {
        get { lock (_gate) return _panelState; }
    }

    /// <summary>The Scan tab's line; <paramref name="presetName"/> is what a press runs (null: no preset to run).</summary>
    public string Text(string? presetName)
    {
        var preset = presetName ?? CoreStrings.ScanButton_NoPreset;
        bool failed;
        PanelState? state;
        lock (_gate) (failed, state) = (_driverFailed, _panelState);
        return Way switch
        {
            ScanButtonWay.Unknown => "",
            ScanButtonWay.None => CoreStrings.ScanButton_None,
            ScanButtonWay.Panel when !On => string.Format(CoreStrings.ScanButton_PanelOff, PanelName),
            ScanButtonWay.Panel => state switch
            {
                Ledm.PanelState.Listed => string.Format(CoreStrings.ScanButton_Listed, PanelName, preset),
                Ledm.PanelState.ListedByOther => string.Format(CoreStrings.ScanButton_ListedByOther, PanelName),
                Ledm.PanelState.NeedsPassword => CoreStrings.ScanButton_NeedsPassword,
                Ledm.PanelState.Refused => CoreStrings.ScanButton_Refused,
                Ledm.PanelState.NotReached => CoreStrings.ScanButton_NotReached,
                _ => CoreStrings.ScanButton_Adding,
            },
            ScanButtonWay.Driver when !On => CoreStrings.ScanButton_DriverOff,
            _ => failed ? CoreStrings.ScanButton_DriverFailed : string.Format(CoreStrings.ScanButton_DriverOn, preset),
        };
    }

    /// <summary>The check box's words for the way offered.</summary>
    public string SwitchText => Way == ScanButtonWay.Driver ? CoreStrings.ScanButton_DriverSwitch : CoreStrings.ScanButton_PanelSwitch;

    /// <summary>
    /// A new connection to the printer (the session closed the one before), or null: none, or another device answers at the address
    /// (nothing may reach it). Looks for the panel by reading only; the PC is added only while turned on.
    /// </summary>
    public async Task UsePrinterAsync(PrinterConnection? connection, CancellationToken ct = default)
    {
        var generation = Interlocked.Increment(ref _generation);
        ScanToComputer? panel = null;
        if (connection is not null)
        {
            try
            {
                panel = await ScanToComputer.DetectAsync(connection, Choice.Destination, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _log($"Scan to Computer not checked: {ex.Message}");
            }
        }
        await UsePanelAsync(panel, known: connection is not null, generation).ConfigureAwait(false);
    }

    /// <summary>Connections handed over so far: a slow check of an older one never replaces a newer one's.</summary>
    private int _generation;

    /// <summary>The printer's panel as found on the current connection (null: it offers none, or there's no connection).</summary>
    public Task UsePanelAsync(ScanToComputer? panel, bool known = true) => UsePanelAsync(panel, known, Interlocked.Increment(ref _generation));

    private Task UsePanelAsync(ScanToComputer? panel, bool known, int generation) => Serialized(async () =>
    {
        if (Volatile.Read(ref _generation) != generation) return; // a newer connection came meanwhile
        await StopAsync().ConfigureAwait(false);
        lock (_gate)
        {
            _panel = panel;
            _panelKnown |= known;
            _panelState = null;
        }
        await StartAsync().ConfigureAwait(false);
    });

    /// <summary>The printer's Windows scanner as connected (null: none), with the scan-button events its driver lists.</summary>
    public Task UseDriverAsync(IWiaSystem? system, string? deviceId, IReadOnlyList<string>? buttons) => Serialized(async () =>
    {
        await StopAsync().ConfigureAwait(false);
        lock (_gate)
        {
            _driver = system is null || deviceId is null ? null : (system, deviceId, buttons ?? []);
            _driverKnown = true;
            _driverFailed = false;
        }
        await StartAsync().ConfigureAwait(false);
    });

    /// <summary>Turned on (the PC goes on the printer's panel, or the driver's button is heard) or off (taken off the panel).</summary>
    public Task SetOnAsync(bool on) => Serialized(async () =>
    {
        if (On == on) return;
        await StopAsync().ConfigureAwait(false);
        if (!on) await RemoveAsync(CancellationToken.None).ConfigureAwait(false);
        Save(Choice with { On = on });
        await StartAsync().ConfigureAwait(false);
    });

    /// <summary>The preset a press runs (its id; null: the first).</summary>
    public void SetPreset(string? presetId)
    {
        if (Choice.PresetId == presetId) return;
        Save(Choice with { PresetId = presetId });
    }

    /// <summary>
    /// The app is closing, or the printer is forgotten: stop hearing presses and take this PC off the printer's panel (one DELETE,
    /// within <paramref name="ct"/>). The choice stays on, so the next run adds it again.
    /// </summary>
    public Task CloseAsync(CancellationToken ct) => Serialized(async () =>
    {
        Interlocked.Increment(ref _generation); // a check still under way doesn't start it again
        await StopAsync().ConfigureAwait(false);
        await RemoveAsync(ct).ConfigureAwait(false);
        lock (_gate)
        {
            _panel = null;
            _driver = null;
        }
    });

    private async Task StartAsync()
    {
        ScanToComputer? panel;
        (IWiaSystem System, string DeviceId, IReadOnlyList<string> Buttons)? driver;
        lock (_gate) (panel, driver) = (_panel, _driver);
        if (On && panel is not null)
        {
            var run = new CancellationTokenSource();
            lock (_gate)
            {
                _run = run;
                _panelState = Ledm.PanelState.Adding;
            }
            _running = Task.Run(() => panel.RunAsync(PanelName, state => Panel(panel, state), Pressed, run.Token));
        }
        else if (On && driver is { Buttons.Count: > 0 } d)
        {
            try
            {
                var watch = await d.System.WatchButtonsAsync(d.DeviceId, d.Buttons, Pressed, CancellationToken.None).ConfigureAwait(false);
                lock (_gate) _watch = watch;
            }
            catch (Exception ex) when (ex is WiaException or InvalidOperationException)
            {
                _log($"Scanner's button not heard: {ex.Message}");
                lock (_gate) _driverFailed = true;
            }
        }
        Changed?.Invoke();
    }

    /// <summary>Stops hearing presses (the PC stays on the panel).</summary>
    private async Task StopAsync()
    {
        CancellationTokenSource? run;
        IDisposable? watch;
        lock (_gate)
        {
            (run, watch) = (_run, _watch);
            _run = null;
            _watch = null;
        }
        watch?.Dispose();
        if (run is null) return;
        await run.CancelAsync().ConfigureAwait(false);
        try { await _running.ConfigureAwait(false); }
        catch (Exception ex) when (ex is not OutOfMemoryException) { _log($"Scan to Computer stopped: {ex.Message}"); }
        run.Dispose();
    }

    /// <summary>Takes this PC off the panel when this app put it there.</summary>
    private async Task RemoveAsync(CancellationToken ct)
    {
        ScanToComputer? panel;
        lock (_gate) panel = _panel;
        if (panel?.Path is null) return;
        if (await panel.RemoveAsync(ct).ConfigureAwait(false))
        {
            Save(Choice with { Destination = null });
            lock (_gate) _panelState = null;
        }
        else _log("This PC couldn't be taken off the printer's panel (no answer, or refused).");
    }

    private void Panel(ScanToComputer panel, PanelState state)
    {
        lock (_gate)
        {
            if (_panel != panel) return; // a run that's being stopped
            _panelState = state;
        }
        if (Choice.Destination != panel.Path) Save(Choice with { Destination = panel.Path });
        Changed?.Invoke();
    }

    private void Pressed()
    {
        if (!On) return;
        _pressed();
    }

    private void Save(ScanButtonChoice choice)
    {
        lock (_gate)
        {
            if (_choice == choice) return;
            _choice = choice;
        }
        _save(choice);
        Changed?.Invoke();
    }

    private async Task Serialized(Func<Task> work)
    {
        await _calls.WaitAsync().ConfigureAwait(false);
        try { await work().ConfigureAwait(false); }
        finally { _calls.Release(); }
    }
}
