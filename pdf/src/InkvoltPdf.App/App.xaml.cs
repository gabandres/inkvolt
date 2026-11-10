using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

public partial class App : Application
{
    private SingleInstance? _instance;
    private MainWindow? _ready;
    private readonly List<string[]> _pendingArgs = [];

    protected override void OnStartup(StartupEventArgs e)
    {
        // Crash logging first: everything after this (settings, single instance, the window) may throw.
        DispatcherUnhandledException += OnUnhandled;
        AppDomain.CurrentDomain.UnhandledException += (_, args) => Log.Write($"Fatal: {args.ExceptionObject}");
        TaskScheduler.UnobservedTaskException += (_, args) =>
        {
            Log.Write($"Unobserved task exception: {args.Exception}");
            args.SetObserved();
        };
        AppLanguage.UseEnglish(); // until the command line is ruled out (below): its output stays English
        TextScale.Start(this); // Windows' Text size, for every window from here on
        if (AppPaths.MovedLegacyData) Log.Write("Data folder carried over from its pre-rename location");
        Core.DocumentSession.Log = Log.Write;
        // The Pro check reads the key from the file both Inkvolt apps share, then from the settings, in the window and on the command line.
        Core.Pro.Store = new InkvoltPrint.Core.Suite.SharedProStore(new SettingsProStore(), Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));

        var args = e.Args;
        // The Office conversion helper (see OfficeConverter): no window, no single-instance check, exits when done.
        if (args.Length > 0 && args[0] == OfficeConverter.ChildSwitch)
        {
            Shutdown(OfficeConverter.RunChild(args));
            return;
        }
        // The command line (--batch, --watch, --help): no window, no single-instance handoff, exits with its code.
        if (Core.BatchCommandLine.IsCommand(args))
        {
            _ = RunCommandLineAsync(args);
            return;
        }
        // The interface's language, before any window asks for text; a dev aid's --lang isn't a file to open. Options come
        // before --convert-to only: after its format every argument is a file, "--lang" or "--script" included.
        var (leading, command) = Core.ConvertCommand.SplitOptions(args);
        string[] options = [.. leading];
        AppLanguage.Apply(AppSettings.Current.Language, options);
        options = AppLanguage.WithoutLanguageArgument(options);
        var script = Array.IndexOf(options, "--script");
        if (script >= 0 && script + 1 < options.Length)
        {
            if (DevScriptAllowed)
            {
                RunDevScript(e, [.. options, .. command], script);
                return;
            }
            // Release builds: a script can drive the UI and write files anywhere, so it needs an explicit opt-in.
            Log.Write("Ignored --script (set INKVOLTPDF_DEVSCRIPT=1 to allow dev scripts in this build).");
            options = [.. options.Where((_, i) => i != script && i != script + 1)];
        }
        args = [.. options, .. command];

        // Explorer's "Convert to Word with Inkvolt PDF" (--convert-to word <files…>): handed to a running copy as any launch
        // is, in its full form (the paths made absolute here); this copy, if it is the first, shows only a small window.
        Core.ConvertCommand.Request? convert = null;
        if (Core.ConvertCommand.IsCommand(args))
        {
            if (!Core.ConvertCommand.TryParse(args, out convert, out var error))
            {
                Log.Write($"Convert command refused: {error}");
                ApplyTheme();
                Prompt.Error(null, Strings.Explorer_CantConvert, ExplorerConvert.Explain(error));
                Shutdown(2);
                return;
            }
            args = Core.ConvertCommand.ToArguments(convert!);
        }

        _instance = SingleInstance.TryAcquire(args);
        if (_instance is null)
        {
            Shutdown();
            return;
        }
        // A check process starts while the window is made: the first page opened doesn't wait for one.
        Core.PageChecks.Prestart();

        // The app runs while its main window or Explorer's conversions do (MaybeExit), not only while the main window is
        // open: closing it mid-batch would stop a conversion half written.
        ShutdownMode = ShutdownMode.OnExplicitShutdown;

        // Listen before opening the startup files: with a multi-file Explorer open, the other launches arrive now.
        // Their files wait in a queue until the window is ready.
        ListenForLaunches();
        ExplorerConvert.ChangeOptions = ChangeOptions;
        ExplorerConvert.MainFor = () => _ready;
        ExplorerConvert.Quiet = () => Dispatcher.BeginInvoke(MaybeExit);

        base.OnStartup(e);
        ApplyTheme();
        if (convert is not null)
        {
            ExplorerConvert.Route(convert);
            return;
        }
        StartMainWindow(args);
    }

    // Launches read from the pipe whose handling (OnForwarded) hasn't run yet.
    private int _forwardsQueued;

    private void ListenForLaunches() => _instance?.Listen(forwarded =>
        {
            Interlocked.Increment(ref _forwardsQueued);
            Dispatcher.BeginInvoke(() =>
            {
                Interlocked.Decrement(ref _forwardsQueued);
                OnForwarded(forwarded);
                if (_main is null) MaybeExit(); // a launch refused, or nothing left to do
            });
        },
        // A read that delivered nothing (a launch that gave up) may have been all that kept the app up.
        () => Dispatcher.BeginInvoke(() => { if (_main is null) MaybeExit(); }));

    /// <summary>
    /// Exits once nothing is left (<see cref="Core.ConvertCommand.MayExit"/>): no main window, no conversions, no launch
    /// read but not handled. New launches are refused first (they open on their own); one already being read keeps the
    /// app up and is handled, and the listening goes on.
    /// </summary>
    private void MaybeExit()
    {
        bool Done() => Core.ConvertCommand.MayExit(_main is not null, ExplorerConvert.ListOpen, ExplorerConvert.Converting,
            Volatile.Read(ref _forwardsQueued));
        if (!Done()) return;
        var stopped = _instance?.StopListening() ?? true;
        if (!stopped || _instance is { InFlight: > 0 } || !Done())
        {
            ListenForLaunches();
            // The listening didn't end in time: a launch may be connecting unseen. Try again shortly rather than exit on it.
            if (!stopped)
            {
                Log.Write("Exit put off: the launch listener didn't stop in time");
                var retry = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
                retry.Tick += (_, _) =>
                {
                    retry.Stop();
                    MaybeExit();
                };
                retry.Start();
            }
            return;
        }
        Log.Write("Exiting: no window and no conversions left");
        Shutdown();
    }

    /// <summary>The main window closed: the app exits, unless Explorer's conversions go on (their window shows them).</summary>
    private void OnMainClosed(MainWindow window)
    {
        if (_main != window) return;
        _main = null;
        _ready = null;
        ExplorerConvert.MainClosed();
        if (ExplorerConvert.ListOpen)
        {
            // As when the app exited with the window: the other windows go (the conversions' own stay).
            foreach (var w in Windows.OfType<Window>().ToList())
                if (w is not ConvertWindow && w.Owner is not ConvertWindow && w.Tag != ProgressPrompt.OutlivesMainWindow) w.Close();
        }
        MaybeExit();
    }

    /// <summary>Another launch's arguments: a conversion goes to <see cref="ExplorerConvert"/>, files open in the window.</summary>
    private void OnForwarded(string[] forwarded)
    {
        if (Core.ConvertCommand.IsCommand(forwarded))
        {
            if (!Core.ConvertCommand.TryParse(forwarded, out var request, out var error))
            {
                Log.Write($"Forwarded convert command refused: {error}");
                return;
            }
            if (_main is not null && _ready is null) _pendingConverts.Add(request!);
            else ExplorerConvert.Route(request!);
            return;
        }
        if (_main is null)
        {
            // The app ran only for conversions until now: this launch opens the window, as a first launch would.
            StartMainWindow(forwarded);
            return;
        }
        if (_ready is null)
        {
            _pendingArgs.Add(forwarded);
            return;
        }
        _ready.BringToFront();
        _ready.OpenForwarded(forwarded);
    }

    private MainWindow? _main;
    private readonly List<Core.ConvertCommand.Request> _pendingConverts = [];
    private readonly List<Func<MainWindow, Task>> _whenReady = [];
    private bool _foldersStarted;

    /// <summary>
    /// The main window, with <paramref name="args"/>' files (none: the last session's, unless <paramref name="reopenLast"/>
    /// is false). Once, when the app starts, or later when it ran only for Explorer's conversions.
    /// </summary>
    private void StartMainWindow(string[] args, bool reopenLast = true)
    {
        var window = new MainWindow();
        FitToScreen(window);
        _main = window;
        MainWindow = window;
        window.Closed += (_, _) => OnMainClosed(window);
        window.Show();
        if (_instance!.IsOwner && !_foldersStarted)
        {
            // A fallback copy would only find the folders locked.
            _foldersStarted = true;
            FolderWatches.StartSaved();
            FolderSearches.StartSaved();
        }
        _ = OpenStartupFilesAsync(window, args, reopenLast);
    }

    /// <summary>
    /// An Explorer conversion's Change options…: <paramref name="pdf"/> opened in the main window (started if the app ran
    /// only for conversions) and its Export window, as the in-app notice's link does.
    /// </summary>
    private void ChangeOptions(string pdf, Core.ExportFormat format)
    {
        Func<MainWindow, Task> export = w => w.ExportWithOptions(pdf, format);
        if (_ready is { } ready)
        {
            ready.BringToFront();
            _ = export(ready);
            return;
        }
        _whenReady.Add(export);
        if (_main is null) StartMainWindow([], reopenLast: false);
    }

    private async Task RunCommandLineAsync(string[] args) => Shutdown(await CommandLine.RunAsync(args));

    /// <summary>Documents left unsaved by an earlier run first (one may be a file asked for now), then the files asked for.</summary>
    private async Task OpenStartupFilesAsync(MainWindow window, string[] args, bool reopenLast = true)
    {
        try
        {
            await window.OfferRecoveryAsync();
        }
        catch (Exception ex)
        {
            Log.Write($"Recovery offer failed: {ex}");
        }
        if (args.Length > 0) window.OpenFiles(args);
        else if (reopenLast) window.ReopenLastSession();

        if (_main != window) return; // closed meanwhile (OnMainClosed)
        _ready = window;
        foreach (var queued in _pendingArgs) window.OpenFiles(queued);
        if (_pendingArgs.Count > 0) window.BringToFront();
        _pendingArgs.Clear();
        foreach (var request in _pendingConverts) ExplorerConvert.Route(request);
        _pendingConverts.Clear();
        foreach (var then in _whenReady) _ = then(window);
        _whenReady.Clear();
        AppHelp.ShowWhatsNewOnce(window);
        window.StartUpdateCheck();
    }

    /// <summary>Dev scripts run in Debug builds, or in any build when INKVOLTPDF_DEVSCRIPT=1.</summary>
    private static bool DevScriptAllowed =>
#if DEBUG
        true;
#else
        Environment.GetEnvironmentVariable("INKVOLTPDF_DEVSCRIPT") == "1";
#endif

    private void RunDevScript(StartupEventArgs e, string[] args, int script)
    {
        // Dev mode: run UI steps off-screen, separate from any running instance.
        // Never touch the user's settings: save to INKVOLTPDF_DATA if given, else not at all.
        AppSettings.ReadOnly = Environment.GetEnvironmentVariable("INKVOLTPDF_DATA") is not { Length: > 0 };
        Core.PageChecks.Prestart(); // as the app does
        base.OnStartup(e);
        var dev = new MainWindow { WindowStartupLocation = WindowStartupLocation.Manual, Left = -20000, Top = 0, Width = 1400, Height = 900, ShowActivated = false };
        dev.WindowState = WindowState.Normal;
        MainWindow = dev;
        dev.Show();
        dev.OpenFiles(args.Where((_, i) => i != script && i != script + 1));
        _ = DevScript.RunAsync(dev, args[script + 1]);
    }

    /// <summary>Applies the theme chosen in Settings (System follows Windows light/dark).</summary>
    public static void ApplyTheme()
    {
        Current.ThemeMode = AppSettings.Current.Theme switch
        {
            "Light" => ThemeMode.Light,
            "Dark" => ThemeMode.Dark,
            _ => ThemeMode.System,
        };
        foreach (Window w in Current.Windows) ApplyFrame(w);
        ApplyBarColors();
    }

    private static bool _barColorsWatched;

    /// <summary>A dev script's high contrast (<c>highcontrast on</c>): Fluent's high-contrast resources and no bar colors, without Windows' setting.</summary>
    internal static bool? DevHighContrast { get; private set; }

    private static ResourceDictionary? _devHighContrast;

    /// <summary>
    /// The command bar's few colors (<see cref="BarColors"/>: Convert's file types, Apply Redactions' red) for the theme
    /// shown, each an application resource by its key. Under high contrast every key is the system's text color, so the
    /// icons follow Windows' high-contrast theme like the rest. Again when the theme, Windows' light/dark or its high
    /// contrast changes.
    /// </summary>
    public static void ApplyBarColors()
    {
        if (!_barColorsWatched)
        {
            _barColorsWatched = true;
            SystemParameters.StaticPropertyChanged += (_, e) =>
            {
                if (e.PropertyName == nameof(SystemParameters.HighContrast)) Current.Dispatcher.BeginInvoke(ApplyBarColors);
            };
            Microsoft.Win32.SystemEvents.UserPreferenceChanged += (_, e) =>
            {
                if (e.Category is Microsoft.Win32.UserPreferenceCategory.General or Microsoft.Win32.UserPreferenceCategory.Color)
                    Current.Dispatcher.BeginInvoke(ApplyBarColors);
            };
        }
        var highContrast = DevHighContrast ?? SystemParameters.HighContrast;
        var colors = BarColors.For(IsDark, highContrast);
        foreach (var tint in BarColors.All)
        {
            Brush brush = colors.TryGetValue(tint.Key, out var hex) && BarColors.Rgb(hex) is var (r, g, b)
                ? new SolidColorBrush(Color.FromRgb(r, g, b))
                : SystemColors.WindowTextBrush;
            brush.Freeze();
            Current.Resources[tint.Key] = brush;
        }
    }

    /// <summary>Dev aid: Fluent's own high-contrast dictionary over the current theme, and the bar's colors given way.</summary>
    internal static void SetDevHighContrast(bool? on)
    {
        DevHighContrast = on;
        if (_devHighContrast is not null) Current.Resources.MergedDictionaries.Remove(_devHighContrast);
        _devHighContrast = null;
        if (on == true)
        {
            _devHighContrast = new ResourceDictionary { Source = new Uri("pack://application:,,,/PresentationFramework.Fluent;component/Resources/Theme/HC.xaml") };
            Current.Resources.MergedDictionaries.Add(_devHighContrast);
        }
        ApplyBarColors();
    }

    /// <summary>True when the app shows dark (an explicit choice, or Windows' app mode when following the system).</summary>
    public static bool IsDark => AppSettings.Current.Theme switch
    {
        "Dark" => true,
        "Light" => false,
        _ => Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int light && light == 0,
    };

    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>
    /// A small screen (1366 x 768, or 1920 x 1080 at 175 %): the window no larger than the primary monitor's working area,
    /// its minimum size too, and centred, so its caption buttons aren't off the right edge (ScreenFit, as Inkvolt Print).
    /// INKVOLT_FAKE_WORKAREA=1092x582 pretends that working area (a dev aid).
    /// </summary>
    private static void FitToScreen(Window window)
    {
        var area = SystemParameters.WorkArea;
        var work = InkvoltPrint.Core.Suite.ScreenFit.ParseSize(Environment.GetEnvironmentVariable(InkvoltPrint.Core.Suite.ScreenFit.FakeWorkAreaVariable)) is var (w, h)
            ? new InkvoltPrint.Core.Suite.ScreenRect(area.Left, area.Top, w, h)
            : new InkvoltPrint.Core.Suite.ScreenRect(area.Left, area.Top, area.Width, area.Height);
        if (window.Width <= work.Width && window.Height <= work.Height) return; // fits: Windows places it, as always
        window.MinWidth = InkvoltPrint.Core.Suite.ScreenFit.Minimum(window.MinWidth, work.Width);
        window.MinHeight = InkvoltPrint.Core.Suite.ScreenFit.Minimum(window.MinHeight, work.Height);
        var fit = InkvoltPrint.Core.Suite.ScreenFit.Centre(window.Width, window.Height, work);
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        (window.Left, window.Top, window.Width, window.Height) = (fit.Left, fit.Top, fit.Width, fit.Height);
    }

    /// <summary>
    /// Makes the window frame, caption buttons and Mica follow the app theme (also when it differs from Windows'),
    /// since the title bar is drawn by Windows, not WPF.
    /// </summary>
    public static void ApplyFrame(Window window)
    {
        var hwnd = new System.Windows.Interop.WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = IsDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
        var mica = 2;
        DwmSetWindowAttribute(hwnd, 38, ref mica, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE = Mica
    }

    // Rate limiting for the error dialog: a layout or render exception can repeat many times a second.
    private readonly Dictionary<string, DateTime> _lastErrorShown = [];
    private readonly Queue<DateTime> _recentErrors = new();
    private DateTime _quitOfferedAt = DateTime.MinValue;
    private bool _showingError;
    private const int ErrorStormCount = 8;
    private static readonly TimeSpan ErrorRepeatWindow = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ErrorStormWindow = TimeSpan.FromSeconds(10);

    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        e.Handled = true;
        var ex = e.Exception;
        var now = DateTime.UtcNow;
        var key = ErrorKey(ex);
        var repeat = _lastErrorShown.TryGetValue(key, out var last) && now - last < ErrorRepeatWindow;
        _recentErrors.Enqueue(now);
        while (_recentErrors.Count > 0 && now - _recentErrors.Peek() > ErrorStormWindow) _recentErrors.Dequeue();

        if (repeat || _showingError)
        {
            Log.Write($"Unhandled (again, not shown): {ex.GetType().Name}: {ex.Message}");
        }
        else
        {
            Log.Write($"Unhandled: {ex}");
        }
        if (_showingError) return;

        if (_recentErrors.Count >= ErrorStormCount && now - _quitOfferedAt > TimeSpan.FromMinutes(1))
        {
            _quitOfferedAt = now;
            _showingError = true;
            try
            {
                if (Prompt.Confirm(null, Strings.Dialog_KeepsFailingTitle,
                        Loc.Format(Strings.Dialog_KeepsFailingBody, ex.Message, Log.FilePath),
                        Strings.Dialog_QuitApp, warning: true))
                {
                    Log.Write("Quitting after repeated errors (user choice).");
                    Shutdown(1);
                }
            }
            finally
            {
                _showingError = false;
                _recentErrors.Clear();
            }
            return;
        }
        if (repeat) return;

        _lastErrorShown[key] = now;
        _showingError = true;
        try
        {
            Prompt.Error(null, Strings.Dialog_SomethingWrong, Loc.Format(Strings.Dialog_ErrorDetails, ex.Message, Log.FilePath));
        }
        finally
        {
            _showingError = false;
            // Errors raised while the dialog was open shouldn't immediately reopen it.
            _lastErrorShown[key] = DateTime.UtcNow;
        }
    }

    /// <summary>Same exception type thrown from the same place = the same error.</summary>
    private static string ErrorKey(Exception ex)
    {
        var site = ex.TargetSite is { } m ? $"{m.DeclaringType?.FullName}.{m.Name}" : ex.StackTrace?.Split('\n', 2)[0].Trim() ?? "";
        return $"{ex.GetType().FullName}@{site}";
    }

    protected override void OnExit(ExitEventArgs e)
    {
        FolderWatches.StopAll();
        FolderSearches.StopAll();
        _instance?.Dispose();
        base.OnExit(e);
    }
}
