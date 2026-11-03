using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App;

/// <summary>
/// The look Inkvolt PDF has too: the theme chosen in Settings (System follows Windows), a title bar drawn dark when the app
/// is (Windows draws it, not WPF) with Mica behind it on Windows 11 (an opaque themed background and Segoe MDL2 Assets icons on
/// Windows 10), and every window kept on its screen: the main window put back where it was, on a monitor that's still there.
/// </summary>
internal static class WindowFrame
{
    /// <summary>The Windows build the app acts on, read once (<see cref="WindowsLook.FakeWindows10Variable"/> pretends 19045).</summary>
    public static readonly int Build = WindowsLook.Effective(Environment.OSVersion.Version.Build,
        Environment.GetEnvironmentVariable(WindowsLook.FakeWindows10Variable));

    /// <summary>False while a snapshot sets the window's size itself (<c>--size</c>): that size wins.</summary>
    public static bool KeepsOnScreen { get; set; } = true;

    /// <summary>
    /// <see cref="WindowsLook.FakeWindows10Variable"/>: WPF reads the build once, for its Fluent theme's Windows 10 path
    /// (opaque window background, no backdrop); this makes it read 19045 too. Runs before any WPF code.
    /// </summary>
    [System.Runtime.CompilerServices.ModuleInitializer]
    internal static void FakeWindows10()
    {
        if (!WindowsLook.IsOn(Environment.GetEnvironmentVariable(WindowsLook.FakeWindows10Variable))) return;
        typeof(Environment).GetField("s_osVersion", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static)
            ?.SetValue(null, new OperatingSystem(PlatformID.Win32NT, new Version(10, 0, WindowsLook.Windows10Build, 0)));
    }

    /// <summary>
    /// Before Windows 11 the icons come from Segoe MDL2 Assets alone (Windows 10 has no Segoe Fluent Icons; every glyph the
    /// app uses is in both, IconGlyphTests): the app's and the Fluent theme's own (SymbolThemeFontFamily). Before any window loads.
    /// </summary>
    public static void UseWindowsIcons(Application app)
    {
        if (WindowsLook.IsWindows11(Build)) return;
        var icons = new FontFamily(WindowsLook.IconFont(Build));
        app.Resources["Icons"] = icons;
        app.Resources["SymbolThemeFontFamily"] = icons;
        if (app.Resources["Icon"] is Style icon)
        {
            var style = new Style(typeof(TextBlock), icon);
            style.Setters.Add(new Setter(TextBlock.FontFamilyProperty, icons));
            app.Resources["Icon"] = style;
        }
    }
    public static readonly string[] Themes = ["System", "Light", "Dark"];

    /// <summary>The theme in force: "System", "Light" or "Dark".</summary>
    public static string Theme { get; private set; } = "System";

    /// <summary>Applies a theme to the app and every open window's frame. Unknown names follow the system.</summary>
    public static void ApplyTheme(string? theme)
    {
        Theme = theme is "Light" or "Dark" ? theme : "System";
        Application.Current.ThemeMode = Theme switch
        {
            "Light" => ThemeMode.Light,
            "Dark" => ThemeMode.Dark,
            _ => ThemeMode.System,
        };
        foreach (Window w in Application.Current.Windows) ApplyFrame(w);
    }

    /// <summary>Every window, dialogs included, gets the frame when it's shown.</summary>
    public static void FollowAllWindows() =>
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler((s, _) =>
        {
            ApplyFrame((Window)s);
            KeepOnScreen((Window)s);
        }));

    /// <summary>True when the app shows dark: an explicit choice, or Windows' app mode when following the system.</summary>
    public static bool IsDark => Theme switch
    {
        "Dark" => true,
        "Light" => false,
        _ => Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int light && light == 0,
    };

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>
    /// Title bar and caption buttons follow the app's theme (also when it differs from Windows'), with Mica behind them on
    /// Windows 11 22H2 and later. Before it the window gets the theme's opaque background: WPF's Fluent style leaves it
    /// transparent from build 22000 on, which shows black without Mica (Windows 11 21H2).
    /// </summary>
    public static void ApplyFrame(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        if (WindowsLook.HasDarkTitleBar(Build))
        {
            var dark = IsDark ? 1 : 0;
            DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
        }
        if (WindowsLook.HasMica(Build))
        {
            var mica = 2;
            DwmSetWindowAttribute(hwnd, 38, ref mica, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE = Mica
        }
        else if (window.ReadLocalValue(Control.BackgroundProperty) == DependencyProperty.UnsetValue)
            window.SetResourceReference(Control.BackgroundProperty, "WindowBackground");
    }

    /// <summary>
    /// Before the main window shows: no larger than the primary monitor's working area, its minimum size too, so it opens
    /// centred with its title bar on screen (1180 x 800 doesn't fit a 1366 x 768 laptop, nor 1920 x 1080 at 175 %).
    /// </summary>
    public static void FitBeforeShow(Window window)
    {
        if (!KeepsOnScreen) return;
        var work = PrimaryWorkArea();
        window.MinWidth = ScreenFit.Minimum(window.MinWidth, work.Width);
        window.MinHeight = ScreenFit.Minimum(window.MinHeight, work.Height);
        window.Width = Math.Min(window.Width, work.Width);
        window.Height = Math.Min(window.Height, work.Height);
    }

    /// <summary>A window shown larger than its monitor's working area, or partly off it, is shrunk and moved onto it (ScreenFit).</summary>
    public static void KeepOnScreen(Window window)
    {
        if (!KeepsOnScreen || window.WindowState != WindowState.Normal || double.IsNaN(window.Left) || double.IsNaN(window.Top)) return;
        var bounds = new ScreenRect(window.Left, window.Top, window.ActualWidth, window.ActualHeight);
        if (bounds.Width <= 0 || bounds.Height <= 0 || bounds.Left < -10000) return; // not laid out, or parked off screen on purpose
        if (ScreenFit.Best(bounds, MonitorWorkAreas()) is not { } work || work.Contains(bounds)) return;
        var fit = ScreenFit.Fit(bounds, work);
        window.MinWidth = ScreenFit.Minimum(window.MinWidth, work.Width);
        window.MinHeight = ScreenFit.Minimum(window.MinHeight, work.Height);
        if (fit.Width < bounds.Width) window.Width = fit.Width;
        if (fit.Height < bounds.Height)
        {
            if (window.SizeToContent.HasFlag(SizeToContent.Height)) window.MaxHeight = fit.Height;
            else window.Height = fit.Height;
        }
        window.Left = fit.Left;
        window.Top = fit.Top;
        Log.Write($"Window kept on screen: {bounds} in {work} -> {fit}");
    }

    private static ScreenRect PrimaryWorkArea() => FakeWorkArea()
        ?? new ScreenRect(SystemParameters.WorkArea.Left, SystemParameters.WorkArea.Top, SystemParameters.WorkArea.Width, SystemParameters.WorkArea.Height);

    /// <summary>
    /// A dev aid: <c>INKVOLT_FAKE_WORKAREA=1092x582</c> makes the primary monitor's working area that size (DIPs, from its
    /// top-left corner), as on a 1366 x 768 laptop at 125 %, to see a window kept on a small screen.
    /// </summary>
    private static ScreenRect? FakeWorkArea() =>
        ScreenFit.ParseSize(Environment.GetEnvironmentVariable(ScreenFit.FakeWorkAreaVariable)) is var (width, height)
            ? new ScreenRect(SystemParameters.WorkArea.Left, SystemParameters.WorkArea.Top, width, height) : null;

    /// <summary>Puts the window where <paramref name="saved"/> says, when its title bar still lands on a monitor; else it stays centred.</summary>
    public static void Restore(Window window, WindowPlacement? saved)
    {
        if (saved is null || saved.Width <= 0 || saved.Height <= 0) return;
        if (FitToMonitor(new Rect(saved.Left, saved.Top, Math.Max(window.MinWidth, saved.Width), Math.Max(window.MinHeight, saved.Height))) is not { } fit)
            return;
        window.WindowStartupLocation = WindowStartupLocation.Manual;
        window.Left = fit.Left;
        window.Top = fit.Top;
        window.Width = Math.Max(window.MinWidth, fit.Width);
        window.Height = Math.Max(window.MinHeight, fit.Height);
        if (saved.Maximized) window.WindowState = WindowState.Maximized;
    }

    /// <summary>The window's normal rectangle (its restore bounds when maximized or minimized) and whether it's maximized.</summary>
    public static WindowPlacement? Placement(Window window)
    {
        var bounds = window.WindowState == WindowState.Normal ? new Rect(window.Left, window.Top, window.Width, window.Height) : window.RestoreBounds;
        return bounds.IsEmpty || double.IsNaN(bounds.Left) ? null
            : new WindowPlacement(bounds.Left, bounds.Top, bounds.Width, bounds.Height, window.WindowState == WindowState.Maximized);
    }

    /// <summary>
    /// The saved rectangle (DIPs) moved and shrunk to fit the working area of the monitor it mostly lies on, or null when its
    /// title bar wouldn't be reachable on any monitor (one was unplugged, or the layout changed).
    /// </summary>
    private static Rect? FitToMonitor(Rect saved)
    {
        Rect? best = null;
        var bestArea = 0.0;
        foreach (var screen in MonitorWorkAreas())
        {
            var work = new Rect(screen.Left, screen.Top, screen.Width, screen.Height);
            var caption = Rect.Intersect(new Rect(saved.Left, saved.Top, saved.Width, 40), work);
            if (caption.IsEmpty || caption.Width < 100 || caption.Height < 20) continue;
            var overlap = Rect.Intersect(saved, work);
            var area = overlap.IsEmpty ? 0 : overlap.Width * overlap.Height;
            if (best is not null && area <= bestArea) continue;
            bestArea = area;
            var w = Math.Min(saved.Width, work.Width);
            var h = Math.Min(saved.Height, work.Height);
            best = new Rect(Math.Clamp(saved.Left, work.Left, work.Right - w), Math.Clamp(saved.Top, work.Top, work.Bottom - h), w, h);
        }
        return best;
    }

    [DllImport("user32.dll")]
    private static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc callback, IntPtr data);

    private delegate bool MonitorEnumProc(IntPtr monitor, IntPtr hdc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

    [StructLayout(LayoutKind.Sequential)]
    private struct RECT
    {
        public int Left, Top, Right, Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MONITORINFO
    {
        public int Size;
        public RECT Monitor, Work;
        public int Flags;
    }

    /// <summary>Each monitor's working area (without the taskbar) in DIPs at that monitor's own scale.</summary>
    private static List<ScreenRect> MonitorWorkAreas()
    {
        if (FakeWorkArea() is { } fake) return [fake];
        var areas = new List<ScreenRect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
            if (!GetMonitorInfo(monitor, ref info)) return true;
            var scale = GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1.0; // MDT_EFFECTIVE_DPI
            var r = info.Work;
            areas.Add(new ScreenRect(r.Left / scale, r.Top / scale, (r.Right - r.Left) / scale, (r.Bottom - r.Top) / scale));
            return true;
        }, IntPtr.Zero);
        return areas;
    }
}
