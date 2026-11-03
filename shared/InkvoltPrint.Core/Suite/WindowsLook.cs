namespace InkvoltPrint.Core.Suite;

/// <summary>
/// What both apps' windows can count on from the Windows they run on. The Store packages allow Windows 10 (build 19041 and
/// later), whose window frame has no Mica behind it and whose icon font is Segoe MDL2 Assets, not Segoe Fluent Icons. Pure,
/// so it is tested here; the apps read the build once (<see cref="Effective"/>) and decide from it.
/// </summary>
public static class WindowsLook
{
    /// <summary>
    /// Set to 1 to run either app as on Windows 10 on a Windows 11 PC (a dev aid): the build reads as 19045, so WPF's Fluent
    /// theme and the apps take their Windows 10 path, and the icons come from Segoe MDL2 Assets only.
    /// </summary>
    public const string FakeWindows10Variable = "INKVOLT_FAKE_WIN10";

    /// <summary>Windows 10's last build (22H2): what <see cref="FakeWindows10Variable"/> pretends to run on.</summary>
    public const int Windows10Build = 19045;

    /// <summary>Windows 11's first build: WPF's Fluent windows expect its frame from here on.</summary>
    public const int Windows11Build = 22000;

    /// <summary>Windows 11 22H2: the first build that draws Mica behind a window (DWMWA_SYSTEMBACKDROP_TYPE).</summary>
    public const int MicaBuild = 22621;

    /// <summary>Windows 10 2004: the first build that takes a dark title bar (DWMWA_USE_IMMERSIVE_DARK_MODE = 20), the Store minimum.</summary>
    public const int DarkTitleBarBuild = 19041;

    /// <summary>The build the apps act on: the real one, or Windows 10's when <paramref name="fake"/> (the variable's value) says so.</summary>
    public static int Effective(int real, string? fake) => IsOn(fake) ? Math.Min(real, Windows10Build) : real;

    /// <summary>True when the variable's value turns the fake on: 1, true or yes.</summary>
    public static bool IsOn(string? value) => value?.Trim().ToLowerInvariant() is "1" or "true" or "yes";

    public static bool IsWindows11(int build) => build >= Windows11Build;

    /// <summary>
    /// True when the window can be see-through with Mica behind it. Before it (Windows 10, Windows 11 21H2) a window's
    /// background has to be opaque: a transparent one shows black, or the frame colour, not Mica.
    /// </summary>
    public static bool HasMica(int build) => build >= MicaBuild;

    public static bool HasDarkTitleBar(int build) => build >= DarkTitleBarBuild;

    /// <summary>The icon font: Segoe Fluent Icons on Windows 11, Segoe MDL2 Assets (which Windows 10 has) before.</summary>
    public static string IconFont(int build) => IsWindows11(build) ? "Segoe Fluent Icons, Segoe MDL2 Assets" : "Segoe MDL2 Assets";
}
