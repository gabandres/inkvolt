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

    /// <summary>Arguments other launches handed over before the window was up (null once it is).</summary>
    private List<string[]>? _forwardedEarly = [];

    /// <summary>The notification-area icon and alerts: normal runs, and demo runs given <c>--tray</c> (never the <c>--try</c> window).</summary>
    public TrayController? Tray { get; private set; }

    /// <summary>Quit from the tray menu or Windows signing out: the window really closes instead of going to the tray.</summary>
    public bool Quitting { get; private set; }

    /// <summary>Windows is signing out: unsaved scans stay on disk for the next start instead of being asked about.</summary>
    public bool SigningOut { get; private set; }

    /// <summary>Unsaved scans are kept on disk (<see cref="ScanKeeper"/>): normal runs, and demo runs that aren't snapshots.</summary>
    public bool KeepsScans => _keeper is not null;

    private ScanKeeper? _keeper;

    /// <summary>OnStartup got to its end: later errors keep the app running (even with the window in the tray).</summary>
    private bool _started;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Uninstallers: remove this copy's "Open with", Start-with-Windows and notification entries, then exit (no window, no single-instance hand-off).
        if (e.Args.Contains(ShellIntegration.UnregisterArgument))
        {
            Shutdown(ShellIntegration.Unregister());
            return;
        }
        // status --all (Inkvolt Pro): a list on standard output, no window, no single-instance hand-off, no state written.
        if (Core.Fleet.FleetCommand.IsFor(e.Args))
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            _ = RunStatusAsync(e.Args);
            return;
        }
        // The Store package started by its startup task behaves as --background; one started by a toast clicked after it
        // had exited opens that printer once the window is up.
        var activation = PackagedActivation.Read();
        var args = activation.StartupTask ? [.. e.Args, StartWithWindows.Argument] : e.Args;
        // --demo: one made-up printer, no network (Demo.cs). Like the dev aids, it runs beside a normal copy.
        // --try: the same, labelled as a demo (the "Try a demo printer" link on the no-printers screen).
        var tryDemo = args.Contains("--try");
        var demo = tryDemo || args.Contains("--demo");
        var devRun = demo || args.Any(a => a is "--snapshot" or "--autoprint");
        if (!devRun)
        {
            _instance = SingleInstance.TryAcquire(args);
            if (_instance is null)
            {
                Shutdown(); // the running copy got our arguments
                return;
            }
            // Listening at once: "Open with" on several files starts a copy per file, and those that lose the race hand their
            // file over while this one is still starting (held until the window is up, below).
            _instance.Listen(forwarded => Dispatcher.InvokeAsync(() =>
            {
                if (_forwardedEarly is { } early) early.Add(forwarded);
                else HandleForwarded(forwarded);
            }));
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
        TextScale.Start(this); // Windows' Text size, for every window from here on

        base.OnStartup(e);
        Log.Write($"Inkvolt Print started ({Environment.ProcessPath})");
        if (AppState.MovedLegacyData) Log.Write("Data folder carried over from its pre-rename location");

        SettingsViewModel.AskPassword = (printer, rejected, fingerprint) => PasswordDialog.AskAdmin(MainWindow, printer, rejected, fingerprint);
        PrintViewModel.AskPdfPassword = (file, wrong) => PasswordDialog.AskPdf(MainWindow, file, wrong);
        // Scanners that send only PDF: pages that aren't one JPEG picture are drawn by Windows' PDF engine (roadmap 1.3).
        Core.Escl.ScannerPdf.Renderer = new InkvoltPrint.Windows.Printing.ScannedPdfPages();
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

        var pc = !demo ? PcEnvironment.Real : args.Contains("--no-printers") ? Demo.EmptyPc : Demo.Pc; // chosen once: every view model takes its adapters from it
        _vm = new MainViewModel(pc.LoadState(), pc);
        // The Pro check reads the key from the file both Inkvolt apps share, then from state.json (demo: memory only).
        Core.Pro.Store = demo ? new Core.Suite.MemoryProStore()
            : new Core.Suite.SharedProStore(new StateProStore(_vm.State), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        WindowFrame.FollowAllWindows();
        WindowFrame.ApplyTheme(Array.IndexOf(args, "--theme") is var t and >= 0 && t + 1 < args.Length ? args[t + 1] : _vm.State.Theme);
        MainWindow = new MainWindow { DataContext = _vm };
        if (!devRun)
        {
            WindowFrame.Restore(MainWindow, _vm.State.Window);
            ((MainWindow)MainWindow).RemembersPlacement = true;
        }
        if (tryDemo)
        {
            MainWindow.Title = "Inkvolt Print (demo printer)";
            ((MainWindow)MainWindow).AppName.Text = "Inkvolt Print · Demo";
        }
        if (DevSnapshot.Size(args) is var (width, height))
        {
            MainWindow.Width = width;
            MainWindow.Height = height;
        }
        if (!tryDemo && (!devRun || args.Contains("--tray")))
        {
            if (demo) (_vm.State.Tray ??= new TraySettings()).Enabled = true; // demo state is in memory only
            Tray = new TrayController(this, _vm, _vm.State, pc);
            SessionEnding += (_, _) => Quitting = true; // never hold up signing out by hiding instead of closing
            if (!demo) StartWithWindows.KeepCurrent();
        }
        // After an update, What's New once, when the window is first on screen (now, or later from the notification area).
        // --demo --whatsnew-from 1.0.2: as if updated from that version (dev aid).
        var whatsNewFrom = demo && Array.IndexOf(args, "--whatsnew-from") is var wn and >= 0 && wn + 1 < args.Length ? args[wn + 1] : null;
        if (!devRun || whatsNewFrom is not null)
        {
            var window = MainWindow;
            var state = _vm.State;
            if (whatsNewFrom is not null) state.LastVersionSeen = whatsNewFrom;
            window.ContentRendered += WhatsNew;
            void WhatsNew(object? sender, EventArgs args)
            {
                window.ContentRendered -= WhatsNew;
                window.Dispatcher.BeginInvoke(() => AppHelp.ShowWhatsNewOnce(window, state), System.Windows.Threading.DispatcherPriority.ApplicationIdle);
            }
        }
        // Started with Windows (--background): straight to the notification area, when it's still turned on.
        if (Tray is { KeepsRunning: true } && args.Contains(StartWithWindows.Argument)) Tray.HideWindow(atStartup: true);
        else MainWindow.Show();
        // A toast clicked after the packaged app had exited: open that printer (the icon off: the window is up, which is all a click does then).
        if (activation.ToastArguments is { } toastArguments && Tray is { } tray) Dispatcher.BeginInvoke(() => tray.HandleToast(toastArguments));

        // Demo runs keep theirs apart, under %TEMP% like their scans; the --try window and snapshots keep none.
        if (!devRun || (demo && !tryDemo && !args.Contains("--snapshot")))
        {
            _keeper = new ScanKeeper(_vm, demo ? Path.Combine(Path.GetTempPath(), "Inkvolt Print demo recovery") : Path.Combine(AppState.DataDirectory, "recovery"));
            SessionEnding += (_, _) =>
            {
                SigningOut = true;
                Quitting = true;
                _keeper?.KeepForNextStart();
            };
        }
        if (!devRun)
        {
            _ = Task.Run(ShellIntegration.RegisterOpenWith);
            var vm = _vm;
            PresetJumpList.Update(this, vm.Presets.Items);
            vm.Presets.Changed += () => PresetJumpList.Update(this, vm.Presets.Items);
        }

        // "Open with Inkvolt Print" / InkvoltPrint.exe file.pdf → straight to Print for the last-used printer.
        if (FirstPdf(args) is { } pdf) _ = _vm.OpenPdfAsync(pdf);
        // InkvoltPrint.exe photo.jpg … ("Open with" on pictures) → Photos for the last-used printer.
        else if (Pictures(args) is { Count: > 0 } pictures) _ = _vm.OpenPhotosAsync(pictures);
        // The jump list's "Scan: <preset>" (InkvoltPrint.exe --preset id). Snapshots run it themselves, in order.
        if (PresetArg(args) is { } preset && !args.Contains("--snapshot")) _ = _vm.RunPresetWhenReadyAsync(preset);
        // Then what other launches handed over while this one was starting, in the order they came.
        var forwardedEarly = _forwardedEarly;
        _forwardedEarly = null;
        foreach (var forwarded in forwardedEarly ?? []) HandleForwarded(forwarded);
        if (Array.IndexOf(args, "--autoprint") is var ap and >= 0 && ap + 1 < args.Length)
            _ = DevAutoPrint.RunAsync(_vm, args[ap + 1],
                copies: int.TryParse(args.SkipWhile(x => x != "--copies").Skip(1).FirstOrDefault(), out var c) ? c : 1,
                twoSided: args.Contains("--two-sided"));
        if (args.Contains("--simulate-alerts") && demo && !args.Contains("--snapshot"))
            _ = DevSnapshot.SimulateAlertsAsync(Tray);
        if (Array.IndexOf(args, "--snapshot") is var i and >= 0 && i + 1 < args.Length)
            _ = DevSnapshot.RunAsync((MainWindow)MainWindow, args[i + 1], args.SkipWhile(a => a != "--tab").Skip(1).FirstOrDefault(),
                scans: !args.Contains("--scan") ? 0 : int.TryParse(args.SkipWhile(a => a != "--scan").Skip(1).FirstOrDefault(), out var n) ? n : 1,
                scrollToEnd: args.Contains("--scroll-end"),
                copy: args.SkipWhile(a => a != "--copy").Skip(1).FirstOrDefault(),
                crop: int.TryParse(args.SkipWhile(a => a != "--crop").Skip(1).FirstOrDefault(), out var page) ? page : 0,
                printer: int.TryParse(args.SkipWhile(a => a != "--printer").Skip(1).FirstOrDefault(), out var nth) ? nth : 0,
                fix: !args.Contains("--fix") ? null
                    : args.SkipWhile(a => a != "--fix").Skip(1).FirstOrDefault() is { } how && how is "all" or "waiting" or "cancel" ? how : "check",
                preset: PresetArg(args),
                then: args.SkipWhile(a => a != "--then").Skip(1).FirstOrDefault(),
                editPresets: !args.Contains("--presets") ? 0 : int.TryParse(args.SkipWhile(a => a != "--presets").Skip(1).FirstOrDefault(), out var p) ? p : 1,
                tray: args.SkipWhile(a => a != "--tray-shot").Skip(1).FirstOrDefault(), simulateAlerts: args.Contains("--simulate-alerts"),
                args: args);
        _started = true;
    }

    /// <summary>A hung printer's read may still be running when the list is done: the process ends here regardless.</summary>
    private static async Task RunStatusAsync(string[] args)
    {
        var code = await Task.Run(() => StatusCommand.RunAsync(args));
        Environment.Exit(code);
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
        if (!SigningOut) _keeper?.Dispose(); // signing out: KeepForNextStart left the scans for next time
        Tray?.Dispose();
        _vm?.Dispose();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
