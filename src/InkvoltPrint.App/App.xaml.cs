using System.IO;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPrint.App.Presets;
using InkvoltPrint.App.Tray;
using InkvoltPrint.App.ViewModels;
using InkvoltPrint.App.Views;

namespace InkvoltPrint.App;

public partial class App : Application
{
    private MainViewModel? _vm;
    private SingleInstance? _instance;

    /// <summary>The notification-area icon and alerts: normal runs, and demo runs given <c>--tray</c> (never the <c>--try</c> window).</summary>
    public TrayController? Tray { get; private set; }

    /// <summary>Quit from the tray menu or Windows signing out: the window really closes instead of going to the tray.</summary>
    public bool Quitting { get; private set; }

    /// <summary>OnStartup got to its end: later errors keep the app running (even with the window in the tray).</summary>
    private bool _started;

    protected override void OnStartup(StartupEventArgs e)
    {
        // --demo: one made-up printer, no network (Demo.cs). Like the dev aids, it runs beside a normal copy.
        // --try: the same, labelled as a demo (the "Try a demo printer" link on the no-printers screen).
        var tryDemo = e.Args.Contains("--try");
        var demo = tryDemo || e.Args.Contains("--demo");
        var devRun = demo || e.Args.Any(a => a is "--snapshot" or "--autoprint");
        if (!devRun)
        {
            _instance = SingleInstance.TryAcquire(e.Args);
            if (_instance is null)
            {
                Shutdown(); // the running copy got our arguments
                return;
            }
        }

        // This UI is static; GPU rendering only costs memory (~200 MB on some ARM64 graphics drivers).
        RenderOptions.ProcessRenderMode = RenderMode.SoftwareOnly;

        DispatcherUnhandledException += OnUiException;
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Write($"Unobserved task exception: {args.Exception}");
            args.SetObserved();
        };
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Write($"FATAL: {args.ExceptionObject}");

        if (Array.IndexOf(e.Args, "--theme") is var t and >= 0 && t + 1 < e.Args.Length)
            ThemeMode = new ThemeMode(e.Args[t + 1]);

        base.OnStartup(e);
        Log.Write($"Inkvolt Print started ({Environment.ProcessPath})");
        if (AppState.MovedLegacyData) Log.Write("Data folder carried over from its pre-rename location");

        SettingsViewModel.AskPassword = (printer, rejected, fingerprint) => PasswordDialog.AskAdmin(MainWindow, printer, rejected, fingerprint);
        PrintViewModel.AskPdfPassword = (file, wrong) => PasswordDialog.AskPdf(MainWindow, file, wrong);
        Prompt.Confirm = (message, confirm) => ConfirmDialog.Ask(MainWindow, message, confirm);
        Prompt.Inform = message => ConfirmDialog.Tell(MainWindow, message);
        Prompt.EditPresets = (presets, printer) => ScanPresetsDialog.Open(MainWindow, presets, printer);
        Prompt.Announcer = message =>
        {
            if (MainWindow is { } w && (System.Windows.Automation.Peers.UIElementAutomationPeer.FromElement(w)
                                        ?? System.Windows.Automation.Peers.UIElementAutomationPeer.CreatePeerForElement(w)) is { } peer)
                peer.RaiseNotificationEvent(System.Windows.Automation.AutomationNotificationKind.Other,
                    System.Windows.Automation.AutomationNotificationProcessing.ImportantMostRecent, message, "InkvoltPrint.Announce");
        };

        _vm = demo ? new MainViewModel(Demo.CreateState(), Demo.CreateTransport) : new MainViewModel(AppState.Load());
        MainWindow = new MainWindow { DataContext = _vm };
        if (tryDemo)
        {
            MainWindow.Title = "Inkvolt Print (demo printer)";
            ((MainWindow)MainWindow).AppName.Text = "Inkvolt Print · Demo";
        }
        if (DevSnapshot.Size(e.Args) is var (width, height))
        {
            MainWindow.Width = width;
            MainWindow.Height = height;
        }
        if (!tryDemo && (!devRun || e.Args.Contains("--tray")))
        {
            if (demo) (_vm.State.Tray ??= new TraySettings()).Enabled = true; // demo state is in memory only
            Tray = new TrayController(this, _vm, _vm.State, demo);
            SessionEnding += (_, _) => Quitting = true; // never hold up signing out by hiding instead of closing
            if (!demo) StartWithWindows.KeepCurrent();
        }
        else
        {
            ((MainWindow)MainWindow).AlertsLink.Visibility = Visibility.Collapsed; // the --try window and dev runs have no tray
        }
        // Started with Windows (--background): straight to the notification area, when it's still turned on.
        if (Tray is { KeepsRunning: true } && e.Args.Contains(StartWithWindows.Argument)) Tray.HideWindow(atStartup: true);
        else MainWindow.Show();

        _instance?.Listen(args => Dispatcher.InvokeAsync(() => HandleForwarded(args)));
        if (!devRun)
        {
            _ = Task.Run(ShellIntegration.RegisterOpenWith);
            var vm = _vm;
            PresetJumpList.Update(this, vm.Presets.Items);
            vm.Presets.Changed += () => PresetJumpList.Update(this, vm.Presets.Items);
        }

        // "Open with Inkvolt Print" / InkvoltPrint.exe file.pdf → straight to Print for the last-used printer.
        if (FirstPdf(e.Args) is { } pdf) _ = _vm.OpenPdfAsync(pdf);
        // InkvoltPrint.exe photo.jpg … ("Open with" on pictures) → Photos for the last-used printer.
        else if (Pictures(e.Args) is { Count: > 0 } pictures) _ = _vm.OpenPhotosAsync(pictures);
        // The jump list's "Scan: <preset>" (InkvoltPrint.exe --preset id). Snapshots run it themselves, in order.
        if (PresetArg(e.Args) is { } preset && !e.Args.Contains("--snapshot")) _ = _vm.RunPresetWhenReadyAsync(preset);
        if (Array.IndexOf(e.Args, "--autoprint") is var ap and >= 0 && ap + 1 < e.Args.Length)
            _ = DevAutoPrint.RunAsync(_vm, e.Args[ap + 1],
                copies: int.TryParse(e.Args.SkipWhile(x => x != "--copies").Skip(1).FirstOrDefault(), out var c) ? c : 1,
                twoSided: e.Args.Contains("--two-sided"));
        if (e.Args.Contains("--simulate-alerts") && demo && !e.Args.Contains("--snapshot"))
            _ = DevSnapshot.SimulateAlertsAsync(Tray);
        if (Array.IndexOf(e.Args, "--snapshot") is var i and >= 0 && i + 1 < e.Args.Length)
            _ = DevSnapshot.RunAsync((MainWindow)MainWindow, e.Args[i + 1], e.Args.SkipWhile(a => a != "--tab").Skip(1).FirstOrDefault(),
                scans: !e.Args.Contains("--scan") ? 0 : int.TryParse(e.Args.SkipWhile(a => a != "--scan").Skip(1).FirstOrDefault(), out var n) ? n : 1,
                scrollToEnd: e.Args.Contains("--scroll-end"),
                copy: e.Args.SkipWhile(a => a != "--copy").Skip(1).FirstOrDefault(),
                crop: int.TryParse(e.Args.SkipWhile(a => a != "--crop").Skip(1).FirstOrDefault(), out var page) ? page : 0,
                printer: int.TryParse(e.Args.SkipWhile(a => a != "--printer").Skip(1).FirstOrDefault(), out var nth) ? nth : 0,
                fix: !e.Args.Contains("--fix") ? null : e.Args.SkipWhile(a => a != "--fix").Skip(1).FirstOrDefault() == "all" ? "all" : "check",
                preset: PresetArg(e.Args),
                then: e.Args.SkipWhile(a => a != "--then").Skip(1).FirstOrDefault(),
                editPresets: !e.Args.Contains("--presets") ? 0 : int.TryParse(e.Args.SkipWhile(a => a != "--presets").Skip(1).FirstOrDefault(), out var p) ? p : 1,
                tray: e.Args.SkipWhile(a => a != "--tray-shot").Skip(1).FirstOrDefault(), simulateAlerts: e.Args.Contains("--simulate-alerts"),
                args: e.Args);
        _started = true;
    }

    private static string? PresetArg(string[] args) =>
        Array.IndexOf(args, "--preset") is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;

    private static string? FirstPdf(IEnumerable<string> args) =>
        args.FirstOrDefault(a => a.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) && File.Exists(a));

    /// <summary>Picture files among the arguments; the dev aids' output files (<c>--snapshot shot.png</c>) are not.</summary>
    private static List<string> Pictures(string[] args) =>
        args.Where((a, i) => !a.StartsWith("--", StringComparison.Ordinal) && (i == 0 || args[i - 1] is not ("--snapshot" or "--autoprint" or "--photo-sheets"))
                             && (Printing.PhotoFiles.IsPicture(a) || Printing.PhotoFiles.MissingCodec(a) is not null) && File.Exists(a)).ToList();

    /// <summary>Quit (tray menu): closes the window for real; unsaved scans are asked about first, with the window shown.</summary>
    public void Quit()
    {
        if (MainWindow is not { } w) return;
        Quitting = true;
        if (_vm?.PrintersWithUnsavedScans.Count > 0 && !w.IsVisible) Tray?.ShowWindow();
        w.Close();
        if (w.IsLoaded && w.IsVisible) Quitting = false; // they chose to keep the scans
    }

    /// <summary>Another launch handed us its arguments: bring the window forward and open its PDF, if any.</summary>
    private void HandleForwarded(string[] args)
    {
        if (MainWindow is not { } w) return;
        // A copy started at sign-in while this one already runs: stay where we are.
        if (args is [StartWithWindows.Argument]) return;
        // Owned WPF dialogs, and Win32 Open/Save dialogs (which register as thread-modal), must close first.
        static bool DialogOpen(Window w) => w.OwnedWindows.Count > 0 || System.Windows.Interop.ComponentDispatcher.IsThreadModal;
        if (DialogOpen(w))
        {
            // A dialog (password, confirmation) is open: opening a PDF now would stack dialogs. Try again shortly.
            var timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            timer.Tick += (_, _) =>
            {
                if (DialogOpen(w)) return;
                timer.Stop();
                HandleForwarded(args);
            };
            timer.Start();
            return;
        }
        if (Tray is not null) Tray.ShowWindow();
        else
        {
            if (w.WindowState == WindowState.Minimized) w.WindowState = WindowState.Normal;
            w.Show();
            w.Activate();
            w.Topmost = true; // Windows won't let a background process steal focus; flash to the top instead
            w.Topmost = false;
        }
        if (FirstPdf(args) is { } pdf && _vm is not null) _ = _vm.OpenPdfAsync(pdf);
        else if (Pictures(args) is { Count: > 0 } pictures && _vm is not null) _ = _vm.OpenPhotosAsync(pictures);
        if (PresetArg(args) is { } preset && _vm is not null) _ = _vm.RunPresetWhenReadyAsync(preset);
    }

    /// <summary>Last line of defence: log it, tell the user, keep running (and keep their scanned pages).</summary>
    private void OnUiException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log.Write($"Unhandled UI exception: {e.Exception}");
        e.Handled = true;
        if (!_started)
        {
            // Failed before the window was up: a windowless process would keep the single-instance lock and
            // silently swallow every later launch. Say so and exit instead.
            MessageBox.Show($"Inkvolt Print couldn't start.\n\n{e.Exception.Message}\n\nDetails were saved to {Log.FilePath}",
                "Inkvolt Print", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
            return;
        }
        var owner = MainWindow is { IsLoaded: true, IsVisible: true } w ? w : null;
        if (owner is null)
        {
            // In the notification area: no window to show it over; the log has it.
            Tray?.ShowError(e.Exception.Message);
            return;
        }
        MessageBox.Show(owner,
            $"Something went wrong, but Inkvolt Print is still running and nothing you were working on was lost.\n\n{e.Exception.Message}\n\nDetails were saved to {Log.FilePath}",
            "Inkvolt Print", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        Tray?.Dispose();
        _vm?.Dispose();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
