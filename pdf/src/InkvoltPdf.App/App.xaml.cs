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
        // The interface's language, before any window asks for text; a dev aid's --lang isn't a file to open.
        AppLanguage.Apply(AppSettings.Current.Language, args);
        args = AppLanguage.WithoutLanguageArgument(args);
        var script = Array.IndexOf(args, "--script");
        if (script >= 0 && script + 1 < args.Length)
        {
            if (DevScriptAllowed)
            {
                RunDevScript(e, args, script);
                return;
            }
            // Release builds: a script can drive the UI and write files anywhere, so it needs an explicit opt-in.
            Log.Write("Ignored --script (set INKVOLTPDF_DEVSCRIPT=1 to allow dev scripts in this build).");
            args = [.. args.Where((_, i) => i != script && i != script + 1)];
        }

        _instance = SingleInstance.TryAcquire(args);
        if (_instance is null)
        {
            Shutdown();
            return;
        }
        // A check process starts while the window is made: the first page opened doesn't wait for one.
        Core.PageChecks.Prestart();

        // Listen before opening the startup files: with a multi-file Explorer open, the other launches arrive now.
        // Their files wait in a queue until the window is ready.
        _instance.Listen(forwarded => Dispatcher.BeginInvoke(() =>
        {
            if (_ready is null)
            {
                _pendingArgs.Add(forwarded);
                return;
            }
            _ready.BringToFront();
            _ready.OpenForwarded(forwarded);
        }));

        base.OnStartup(e);
        ApplyTheme();
        var window = new MainWindow();
        FitToScreen(window);
        MainWindow = window;
        window.Show();
        if (_instance.IsOwner)
        {
            // A fallback copy would only find the folders locked.
            FolderWatches.StartSaved();
            FolderSearches.StartSaved();
        }
        _ = OpenStartupFilesAsync(window, args);
    }

    private async Task RunCommandLineAsync(string[] args) => Shutdown(await CommandLine.RunAsync(args));

    /// <summary>Documents left unsaved by an earlier run first (one may be a file asked for now), then the files asked for.</summary>
    private async Task OpenStartupFilesAsync(MainWindow window, string[] args)
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
        else window.ReopenLastSession();

        _ready = window;
        foreach (var queued in _pendingArgs) window.OpenFiles(queued);
        if (_pendingArgs.Count > 0) window.BringToFront();
        _pendingArgs.Clear();
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
