using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace InkvoltPrint.App;

/// <summary>
/// The look Inkvolt PDF has too: the theme chosen in Settings (System follows Windows), a title bar drawn dark when the app
/// is (Windows draws it, not WPF) with Mica behind it, and the main window put back where it was, on a monitor that's
/// still there.
/// </summary>
internal static class WindowFrame
{
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
        EventManager.RegisterClassHandler(typeof(Window), FrameworkElement.LoadedEvent, new RoutedEventHandler((s, _) => ApplyFrame((Window)s)));

    /// <summary>True when the app shows dark: an explicit choice, or Windows' app mode when following the system.</summary>
    public static bool IsDark => Theme switch
    {
        "Dark" => true,
        "Light" => false,
        _ => Microsoft.Win32.Registry.GetValue(@"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize", "AppsUseLightTheme", 1) is int light && light == 0,
    };

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    /// <summary>Title bar and caption buttons follow the app's theme (also when it differs from Windows'), with Mica behind them.</summary>
    public static void ApplyFrame(Window window)
    {
        var hwnd = new WindowInteropHelper(window).Handle;
        if (hwnd == IntPtr.Zero) return;
        var dark = IsDark ? 1 : 0;
        DwmSetWindowAttribute(hwnd, 20, ref dark, sizeof(int)); // DWMWA_USE_IMMERSIVE_DARK_MODE
        var mica = 2;
        DwmSetWindowAttribute(hwnd, 38, ref mica, sizeof(int)); // DWMWA_SYSTEMBACKDROP_TYPE = Mica (Windows 11; ignored before)
    }

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
        foreach (var work in MonitorWorkAreas())
        {
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
    private static List<Rect> MonitorWorkAreas()
    {
        var areas = new List<Rect>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr _, ref RECT _, IntPtr _) =>
        {
            var info = new MONITORINFO { Size = Marshal.SizeOf<MONITORINFO>() };
            if (!GetMonitorInfo(monitor, ref info)) return true;
            var scale = GetDpiForMonitor(monitor, 0, out var dpi, out _) == 0 && dpi > 0 ? dpi / 96.0 : 1.0; // MDT_EFFECTIVE_DPI
            var r = info.Work;
            areas.Add(new Rect(r.Left / scale, r.Top / scale, (r.Right - r.Left) / scale, (r.Bottom - r.Top) / scale));
            return true;
        }, IntPtr.Zero);
        return areas;
    }
}
