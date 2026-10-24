using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;

namespace InkvoltPrint.App.Tray;

/// <summary>
/// The notification-area icon through <c>Shell_NotifyIcon</c> (no Windows Forms): a hidden window receives its clicks;
/// the icon is re-added when Explorer restarts (TaskbarCreated) and redrawn at the taskbar's scale when displays or
/// settings change, from the .ico frame of exactly the small-icon size (16 px at 100%, 20 at 125%, … 64 at 400%).
/// Notifications go out as the icon's balloons, which Windows 10 and 11 show as ordinary notifications (Notification
/// Center, Do not disturb); clicking one raises <see cref="BalloonClicked"/>. Keyboard: Win+B reaches the icon, Enter
/// opens the window, Shift+F10 or the menu key opens the menu; the tooltip is the icon's accessible name.
/// </summary>
public sealed class NotifyIcon : IDisposable
{
    private const int CallbackMessage = 0x8000 + 0x4C; // WM_APP + n
    private const int IconId = 1;
    private readonly HwndSource _window;
    private readonly int _taskbarCreated;
    private IntPtr _icon, _balloonIcon;
    private string _iconResource = "", _tip = "Inkvolt Print";
    private bool _added;

    public NotifyIcon()
    {
        _window = new HwndSource(new HwndSourceParameters("Inkvolt Print notification icon")
        {
            Width = 0, Height = 0, WindowStyle = unchecked((int)0x80000000), ExtendedWindowStyle = 0x80, // WS_POPUP, WS_EX_TOOLWINDOW
        });
        _window.AddHook(WndProc);
        _taskbarCreated = RegisterWindowMessage("TaskbarCreated");
    }

    /// <summary>Left click, or Enter / Space on the focused icon.</summary>
    public event Action? Activated;

    /// <summary>Right click, Shift+F10 or the menu key: where to open it (DIPs, from the shell's anchor point scaled by that
    /// display's DPI), and whether a keyboard opened it.</summary>
    public event Action<Point, bool>? MenuRequested;

    private bool _rightButton;

    public event Action? BalloonClicked;

    /// <summary>The hidden window: the menu must belong to the foreground app to close when clicked away from.</summary>
    public IntPtr Handle => _window.Handle;

    /// <summary>Shows or updates the icon. <paramref name="resource"/>: a pack URI path to an .ico.</summary>
    public void Show(string resource, string tip)
    {
        var tipChanged = tip != _tip;
        _tip = tip;
        if (_added && resource == _iconResource && !tipChanged) return;
        if (resource != _iconResource || _icon == IntPtr.Zero)
        {
            _iconResource = resource;
            Replace(ref _icon, TrayIcons.Load(resource, TrayIcons.SmallIconSize()));
        }
        var data = Data(NifMessage | NifIcon | NifTip | NifShowTip);
        if (!_added || !ShellNotifyIcon(NimModify, ref data)) Add(ref data); // new, or Explorer lost it
    }

    /// <summary>NIM_ADD, then NOTIFYICON_VERSION_4 every time: without it the callbacks below arrive in the old format.</summary>
    private void Add(ref NotifyIconData data)
    {
        _added = ShellNotifyIcon(NimAdd, ref data);
        if (!_added)
        {
            Log.Write("Notification-area icon not added (Explorer not running yet?); added when the taskbar starts");
            return;
        }
        data.uTimeoutOrVersion = 4;
        if (!ShellNotifyIcon(NimSetVersion, ref data)) Log.Write("Notification-area icon: version 4 refused");
    }

    public void Hide()
    {
        if (!_added) return;
        var data = Data(0);
        ShellNotifyIcon(NimDelete, ref data);
        _added = false;
    }

    /// <summary>A notification. Windows shows one at a time per icon; a newer one replaces it.</summary>
    public void Notify(string title, string text, string iconResource)
    {
        if (!_added) return;
        Replace(ref _balloonIcon, TrayIcons.Load(iconResource, TrayIcons.LargeIconSize()));
        var data = Data(NifInfo);
        data.szInfoTitle = Cut(title, 63);
        data.szInfo = Cut(text, 255);
        data.dwInfoFlags = NiifUser | NiifLargeIcon;
        data.hBalloonIcon = _balloonIcon;
        if (!ShellNotifyIcon(NimModify, ref data)) Log.Write("Notification not shown: Windows refused it");
    }

    private static string Cut(string s, int max) => s.Length <= max ? s : s[..(max - 1)] + "…";

    private NotifyIconData Data(int flags) => new()
    {
        cbSize = Marshal.SizeOf<NotifyIconData>(),
        hWnd = _window.Handle,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = Cut(_tip, 127),
        szInfo = "",
        szInfoTitle = "",
    };

    private static void Replace(ref IntPtr icon, IntPtr next)
    {
        var old = icon;
        icon = next;
        if (old != IntPtr.Zero) DestroyIcon(old);
    }

    /// <summary>Redraws the icon at the current scale (a display or the taskbar's DPI changed).</summary>
    private void Refresh()
    {
        if (_iconResource.Length == 0) return;
        Replace(ref _icon, TrayIcons.Load(_iconResource, TrayIcons.SmallIconSize()));
        if (!_added) return;
        var data = Data(NifIcon);
        ShellNotifyIcon(NimModify, ref data);
    }

    private IntPtr WndProc(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg == CallbackMessage)
        {
            var ev = (int)(lParam.ToInt64() & 0xFFFF);
            var x = (short)(wParam.ToInt64() & 0xFFFF);
            var y = (short)((wParam.ToInt64() >> 16) & 0xFFFF);
            switch (ev)
            {
                case NinSelect or NinKeySelect:
                    Activated?.Invoke();
                    break;
                case WmRButtonUp:
                    _rightButton = true; // version 4: a right click sends WM_RBUTTONUP, then WM_CONTEXTMENU
                    break;
                case WmContextMenu:
                    var byKeyboard = !_rightButton;
                    _rightButton = false;
                    MenuRequested?.Invoke(ToDips(x, y), byKeyboard);
                    break;
                case NinBalloonUserClick:
                    BalloonClicked?.Invoke();
                    break;
            }
            handled = true;
        }
        else if (msg == _taskbarCreated && _taskbarCreated != 0)
        {
            _added = false; // Explorer restarted: add the icon again (Show adds it and sets version 4)
            Refresh();
            if (_iconResource.Length > 0) Show(_iconResource, _tip);
        }
        else if (msg is WmDisplayChange or WmSettingChange or WmDpiChanged)
        {
            Refresh();
        }
        return IntPtr.Zero;
    }

    /// <summary>A screen point in pixels as WPF's popup placement wants it: divided by the scale of the display it's on.</summary>
    private static Point ToDips(int x, int y)
    {
        double dpi = 96;
        try
        {
            var monitor = MonitorFromPoint(new NativePoint { X = x, Y = y }, 2); // MONITOR_DEFAULTTONEAREST
            if (GetDpiForMonitor(monitor, 0, out var dpiX, out _) == 0 && dpiX > 0) dpi = dpiX; // MDT_EFFECTIVE_DPI
        }
        catch (Exception ex) when (ex is EntryPointNotFoundException or DllNotFoundException) { }
        return new Point(x * 96.0 / dpi, y * 96.0 / dpi);
    }

    public void Dispose()
    {
        Hide();
        Replace(ref _icon, IntPtr.Zero);
        Replace(ref _balloonIcon, IntPtr.Zero);
        _window.RemoveHook(WndProc);
        _window.Dispose();
    }

    // ---------------------------------------------------------------- Win32

    private const int NimAdd = 0, NimModify = 1, NimDelete = 2, NimSetVersion = 4;
    private const int NifMessage = 0x1, NifIcon = 0x2, NifTip = 0x4, NifInfo = 0x10, NifShowTip = 0x80;
    private const int NiifUser = 0x4, NiifLargeIcon = 0x20;
    private const int WmRButtonUp = 0x205;
    private const int WmContextMenu = 0x7B, WmDisplayChange = 0x7E, WmSettingChange = 0x1A, WmDpiChanged = 0x2E0;
    private const int NinSelect = 0x400, NinKeySelect = 0x401, NinBalloonUserClick = 0x405;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public int cbSize;
        public IntPtr hWnd;
        public int uID;
        public int uFlags;
        public int uCallbackMessage;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public int dwState;
        public int dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public int uTimeoutOrVersion;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public int dwInfoFlags;
        public Guid guidItem;
        public IntPtr hBalloonIcon;
    }

    [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShellNotifyIcon(int message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int RegisterWindowMessage(string name);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativePoint
    {
        public int X, Y;
    }

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromPoint(NativePoint point, int flags);

    [DllImport("shcore.dll")]
    private static extern int GetDpiForMonitor(IntPtr monitor, int type, out uint dpiX, out uint dpiY);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIcon(IntPtr icon);
}

/// <summary>Icons for the notification area: the .ico frame of exactly the size the shell draws, as an HICON.</summary>
internal static class TrayIcons
{
    public const string Ok = "/InkvoltPrint.ico", Warning = "/Tray/InkvoltPrint-warning.ico", Error = "/Tray/InkvoltPrint-error.ico",
        Offline = "/Tray/InkvoltPrint-offline.ico";

    /// <summary>The DPI of the taskbar's display (the notification area draws its icons at that scale).</summary>
    private static uint TaskbarDpi()
    {
        try
        {
            var taskbar = FindWindow("Shell_TrayWnd", null);
            var dpi = taskbar != IntPtr.Zero ? GetDpiForWindow(taskbar) : 0;
            return dpi > 0 ? dpi : GetDpiForSystem();
        }
        catch (EntryPointNotFoundException)
        {
            return 96;
        }
    }

    public static int SmallIconSize() => Metric(49); // SM_CXSMICON

    public static int LargeIconSize() => Metric(11); // SM_CXICON

    private static int Metric(int index)
    {
        try
        {
            var size = GetSystemMetricsForDpi(index, TaskbarDpi());
            return size > 0 ? size : index == 49 ? 16 : 32;
        }
        catch (EntryPointNotFoundException)
        {
            return index == 49 ? 16 : 32;
        }
    }

    /// <summary>The smallest frame at least <paramref name="size"/> pixels wide (else the largest), as an HICON the caller destroys.</summary>
    public static IntPtr Load(string resource, int size)
    {
        var info = Application.GetResourceStream(new Uri($"pack://application:,,,{resource}")) ?? throw new IOException($"{resource} is missing.");
        byte[] ico;
        using (var ms = new MemoryStream())
        {
            info.Stream.CopyTo(ms);
            info.Stream.Dispose();
            ico = ms.ToArray();
        }
        var (offset, length, width) = PickFrame(ico, size);
        var frame = ico.AsSpan(offset, length).ToArray();
        var handle = CreateIconFromResourceEx(frame, frame.Length, true, 0x00030000, size, size, 0);
        return handle != IntPtr.Zero ? handle : throw new IOException($"{resource}: Windows couldn't load its {width} px frame.");
    }

    /// <summary>ICONDIR: 6-byte header, then a 16-byte entry per frame (width 0 means 256).</summary>
    internal static (int Offset, int Length, int Width) PickFrame(byte[] ico, int size)
    {
        if (ico.Length < 6 || BitConverter.ToUInt16(ico, 2) != 1) throw new IOException("Not an icon file.");
        var count = BitConverter.ToUInt16(ico, 4);
        var frames = new List<(int Offset, int Length, int Width)>();
        for (var i = 0; i < count && 6 + 16 * (i + 1) <= ico.Length; i++)
        {
            var e = 6 + 16 * i;
            var width = ico[e] == 0 ? 256 : ico[e];
            var length = BitConverter.ToInt32(ico, e + 8);
            var offset = BitConverter.ToInt32(ico, e + 12);
            if (offset > 0 && length > 0 && (long)offset + length <= ico.Length) frames.Add((offset, length, width));
        }
        if (frames.Count == 0) throw new IOException("The icon file has no frames.");
        return frames.Where(f => f.Width >= size).OrderBy(f => f.Width).FirstOrDefault() is { Length: > 0 } fit ? fit : frames.MaxBy(f => f.Width);
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string className, string? windowName);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(IntPtr hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetDpiForSystem();

    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);

    [DllImport("user32.dll")]
    private static extern IntPtr CreateIconFromResourceEx(byte[] bits, int size, [MarshalAs(UnmanagedType.Bool)] bool icon, int version,
        int cx, int cy, int flags);
}
