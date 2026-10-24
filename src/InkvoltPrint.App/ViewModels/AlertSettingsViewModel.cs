using CommunityToolkit.Mvvm.ComponentModel;
using CommunityToolkit.Mvvm.Input;
using InkvoltPrint.App.Tray;

namespace InkvoltPrint.App.ViewModels;

/// <summary>"Notification area and alerts": every change applies right away, like Windows Settings.</summary>
public sealed partial class AlertSettingsViewModel : ObservableObject
{
    private readonly TrayController _tray;
    private TraySettings S => _tray.Settings;

    public AlertSettingsViewModel(TrayController tray)
    {
        _tray = tray;
        StartupUnavailable = StartWithWindows.Unavailable(tray.IsDemo);
        _startWithWindows = StartupUnavailable is null && StartWithWindows.IsOn;
        tray.Changed += OnTrayChanged;
    }

    /// <summary>The dialog closed.</summary>
    public void Detach() => _tray.Changed -= OnTrayChanged;

    private void OnTrayChanged()
    {
        OnPropertyChanged(nameof(PauseText));
        OnPropertyChanged(nameof(IsPaused));
    }

    public bool Enabled
    {
        get => S.Enabled;
        set
        {
            if (S.Enabled == value) return;
            S.Enabled = value;
            if (!value && StartWithWindowsOn) StartWithWindowsOn = false; // starting hidden without an icon would be invisible
            _tray.Apply();
            OnPropertyChanged();
            OnPropertyChanged(nameof(CanStartWithWindows));
        }
    }

    // ---------------------------------------------------------------- start with Windows

    /// <summary>Why "Start with Windows" isn't offered here (Store package, dev build, demo), or null.</summary>
    public string? StartupUnavailable { get; }

    public bool CanStartWithWindows => StartupUnavailable is null && Enabled;

    private bool _startWithWindows;

    public bool StartWithWindowsOn
    {
        get => _startWithWindows;
        set
        {
            if (_startWithWindows == value || StartupUnavailable is not null) return;
            if (StartWithWindows.Set(value)) _startWithWindows = value;
            OnPropertyChanged();
            OnPropertyChanged(nameof(StartupNote));
        }
    }

    /// <summary>A note under the checkbox: why it's unavailable, or that Task Manager turned it off.</summary>
    public string? StartupNote => StartupUnavailable
        ?? (_startWithWindows && StartWithWindows.TurnedOffInTaskManager ? "Turned off in Task Manager › Startup apps; turn it on there." : null);

    // ---------------------------------------------------------------- alerts

    public bool Alerts
    {
        get => S.Alerts;
        set => Set(S.Alerts, value, v => S.Alerts = v);
    }

    public IReadOnlyList<int> LowChoices => TraySettings.LowChoices;

    public int LowPercent
    {
        get => S.LowPercent;
        set => Set(S.LowPercent, value, v => S.LowPercent = v);
    }

    public bool OfflineAlerts
    {
        get => S.OfflineAlerts;
        set => Set(S.OfflineAlerts, value, v => S.OfflineAlerts = v);
    }

    public bool QuietHours
    {
        get => S.QuietHours;
        set => Set(S.QuietHours, value, v => S.QuietHours = v);
    }

    public IReadOnlyList<HourChoice> Hours { get; } = Enumerable.Range(0, 24).Select(h => new HourChoice(h)).ToList();

    public HourChoice QuietFrom
    {
        get => Hours[S.QuietFrom];
        set => Set(S.QuietFrom, value.Hour, v => S.QuietFrom = v);
    }

    public HourChoice QuietTo
    {
        get => Hours[S.QuietTo];
        set => Set(S.QuietTo, value.Hour, v => S.QuietTo = v);
    }

    public bool IsPaused => _tray.IsPaused;

    public string? PauseText => _tray.PausedUntil is { } until ? $"Alerts are paused until {until.LocalDateTime:t}{(until.Date > DateTime.Today ? " tomorrow" : "")}." : null;

    [RelayCommand]
    private void ResumeAlerts() => _tray.ResumeAlerts();

    private void Set<T>(T old, T value, Action<T> store, [System.Runtime.CompilerServices.CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(old, value)) return;
        store(value);
        _tray.Apply();
        OnPropertyChanged(name);
    }
}

/// <summary>An hour of the day as the user's clock shows it ("22:00" or "10:00 PM").</summary>
public sealed record HourChoice(int Hour)
{
    public override string ToString() => DateTime.Today.AddHours(Hour).ToString("t");
}
