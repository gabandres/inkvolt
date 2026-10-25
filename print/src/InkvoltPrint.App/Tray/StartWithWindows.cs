using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using InkvoltPrint.Windows;

namespace InkvoltPrint.App.Tray;

/// <summary>
/// "Start with Windows" for installed, unpackaged copies: a value under HKCU's Run key starting
/// <c>InkvoltPrint.exe --background</c> (straight into the notification area). Per user, no admin. Not offered in the Microsoft
/// Store package (its way is the manifest's StartupTask, not built or tried yet), nor in dev builds run from bin\, nor in
/// demo mode. Task Manager's Startup apps can turn the entry off; that is read (StartupApproved) and said, never changed.
/// </summary>
public static class StartWithWindows
{
    private const string RunKey = Core.Suite.ShellRegistration.RunKey; // InkvoltPrint.exe --unregister removes it too
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = Core.Suite.ShellRegistration.RunValue;
    public const string Argument = "--background";

    /// <summary>Why it can't be offered here, or null when it can.</summary>
    public static string? Unavailable(bool demo) =>
        demo ? "Not in demo mode."
        : AppPackage.IsPackaged ? "Not in the Microsoft Store version yet."
        : Environment.ProcessPath is not { } exe || exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase) ? "Only for installed copies."
        : null;

    private static string Command => $"\"{Environment.ProcessPath}\" {Argument}";

    public static bool IsOn
    {
        get
        {
            try
            {
                using var run = Registry.CurrentUser.OpenSubKey(RunKey);
                return run?.GetValue(ValueName) is string;
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
            {
                return false;
            }
        }
    }

    /// <summary>Turned off in Task Manager › Startup apps (StartupApproved: an odd first byte means off).</summary>
    public static bool TurnedOffInTaskManager
    {
        get
        {
            try
            {
                using var approved = Registry.CurrentUser.OpenSubKey(ApprovedKey);
                return approved?.GetValue(ValueName) is byte[] { Length: > 0 } b && (b[0] & 1) == 1;
            }
            catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
            {
                return false;
            }
        }
    }

    /// <summary>Adds or removes the Run entry. Returns false when the registry refused.</summary>
    public static bool Set(bool on)
    {
        try
        {
            using var run = Registry.CurrentUser.CreateSubKey(RunKey);
            if (on) run.SetValue(ValueName, Command);
            else run.DeleteValue(ValueName, throwOnMissingValue: false);
            return true;
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            Log.Write($"Start with Windows not changed: {ex.Message}");
            return false;
        }
    }

    /// <summary>The exe moved (installed again elsewhere): point the entry at this copy.</summary>
    public static void KeepCurrent()
    {
        if (Unavailable(demo: false) is null && IsOn)
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(ValueName) as string != Command) Set(true);
        }
    }
}

/// <summary>Whether to check printers less often: on battery, or on a metered network.</summary>
internal static class PowerInfo
{
    public static bool OnBattery()
    {
        try { return GetSystemPowerStatus(out var s) && s.ACLineStatus == 0; }
        catch (EntryPointNotFoundException) { return false; }
    }

    public static bool Metered()
    {
        try
        {
            var cost = global::Windows.Networking.Connectivity.NetworkInformation.GetInternetConnectionProfile()?.GetConnectionCost();
            return cost is not null && cost.NetworkCostType is global::Windows.Networking.Connectivity.NetworkCostType.Fixed
                or global::Windows.Networking.Connectivity.NetworkCostType.Variable;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    public static bool NetworkUp() => NetworkInterface.GetIsNetworkAvailable();

    [StructLayout(LayoutKind.Sequential)]
    private struct SystemPowerStatus
    {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public int BatteryLifeTime, BatteryFullLifeTime;
    }

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetSystemPowerStatus(out SystemPowerStatus status);
}
