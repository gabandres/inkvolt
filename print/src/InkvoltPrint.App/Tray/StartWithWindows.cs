using System.Net.NetworkInformation;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows;
using Windows.ApplicationModel;

namespace InkvoltPrint.App.Tray;

/// <summary>
/// "Start with Windows" (straight into the notification area). Installed, unpackaged copies: a value under HKCU's Run key
/// starting <c>InkvoltPrint.exe --background</c>; per user, no admin; Task Manager's Startup apps can turn the entry off,
/// which is read (StartupApproved) and said, never changed. The Microsoft Store package: the manifest's startup task
/// (<see cref="ShellRegistration.StartupTaskId"/>, off until asked for with <c>RequestEnableAsync</c>; Windows keeps its own
/// state, read here each time: Task Manager and Settings › Apps › Startup turn it off too), and the app started by it
/// sees a StartupTask activation (<see cref="PackagedActivation"/>) instead of the argument. Not offered in dev builds run
/// from bin\, nor in demo mode.
/// </summary>
public static class StartWithWindows
{
    private const string RunKey = ShellRegistration.RunKey; // InkvoltPrint.exe --unregister removes it too
    private const string ApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";
    private const string ValueName = ShellRegistration.RunValue;
    public const string Argument = "--background";

    /// <summary>The packaged task's state as last read (<see cref="RefreshAsync"/>, <see cref="SetAsync"/>); null until read.</summary>
    private static StartupTaskState? _packaged;

    /// <summary>Why it can't be offered here, or null when it can.</summary>
    public static string? Unavailable(bool demo) =>
        demo ? "Not in demo mode."
        : AppPackage.IsPackaged ? null
        : Environment.ProcessPath is not { } exe || exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase) ? "Only for installed copies."
        : null;

    private static string Command => $"\"{Environment.ProcessPath}\" {Argument}";

    /// <summary>On, as last known (the Run value; packaged: the task state read last).</summary>
    public static bool IsOn
    {
        get
        {
            if (AppPackage.IsPackaged) return _packaged is StartupTaskState.Enabled or StartupTaskState.EnabledByPolicy;
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

    /// <summary>Turned off in Task Manager › Startup apps (StartupApproved: an odd first byte means off; packaged: DisabledByUser).</summary>
    public static bool TurnedOffInTaskManager
    {
        get
        {
            if (AppPackage.IsPackaged) return _packaged == StartupTaskState.DisabledByUser;
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

    /// <summary>A note for the settings: why the checkbox doesn't do what it says, or null.</summary>
    public static string? Note =>
        TurnedOffInTaskManager ? "Turned off in Task Manager › Startup apps; turn it on there."
        : _packaged == StartupTaskState.DisabledByPolicy ? "Turned off by a policy on this PC."
        : null;

    /// <summary>Reads Windows' own state (packaged: the startup task; else the Run value). The state as <see cref="IsOn"/> then says.</summary>
    public static async Task<bool> RefreshAsync()
    {
        if (!AppPackage.IsPackaged) return IsOn;
        try
        {
            var task = await StartupTask.GetAsync(ShellRegistration.StartupTaskId);
            _packaged = task.State;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or System.IO.FileNotFoundException or ArgumentException)
        {
            Log.Write($"Startup task not read: {ex.Message}");
            _packaged = null;
        }
        return IsOn;
    }

    /// <summary>Turns it on or off. False when Windows refused (the registry, or a task the person or a policy turned off).</summary>
    public static async Task<bool> SetAsync(bool on)
    {
        if (!AppPackage.IsPackaged) return Set(on);
        try
        {
            var task = await StartupTask.GetAsync(ShellRegistration.StartupTaskId);
            if (on)
            {
                _packaged = await task.RequestEnableAsync();
                Log.Write($"Start with Windows asked for: {_packaged}");
                return IsOn;
            }
            task.Disable();
            _packaged = task.State;
            return !IsOn;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or System.IO.FileNotFoundException or ArgumentException)
        {
            Log.Write($"Start with Windows not changed: {ex.Message}");
            return false;
        }
    }

    /// <summary>Adds or removes the Run entry (unpackaged). Returns false when the registry refused.</summary>
    private static bool Set(bool on)
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

    /// <summary>At startup: the exe moved (installed again elsewhere), point the entry at this copy; packaged, read the task's state.</summary>
    public static void KeepCurrent()
    {
        if (AppPackage.IsPackaged)
        {
            _ = RefreshAsync();
            return;
        }
        if (Unavailable(demo: false) is null && IsOn)
        {
            using var run = Registry.CurrentUser.OpenSubKey(RunKey);
            if (run?.GetValue(ValueName) as string != Command) Set(true);
        }
    }
}

/// <summary>
/// How the Store package was started, from the activation Windows hands a packaged app: by its startup task (go straight to
/// the notification area, as <c>--background</c> does for unpackaged copies) or by a toast clicked after the app had exited
/// (its arguments: which printer to open). Unpackaged copies get neither.
/// </summary>
internal static class PackagedActivation
{
    public static (bool StartupTask, string? ToastArguments) Read()
    {
        if (!AppPackage.IsPackaged) return default;
        try
        {
            var activation = AppInstance.GetActivatedEventArgs();
            return activation?.Kind switch
            {
                global::Windows.ApplicationModel.Activation.ActivationKind.StartupTask => (true, null),
                global::Windows.ApplicationModel.Activation.ActivationKind.ToastNotification =>
                    (false, (activation as global::Windows.ApplicationModel.Activation.ToastNotificationActivatedEventArgs)?.Argument),
                _ => default,
            };
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException or NotImplementedException or InvalidOperationException)
        {
            Log.Write($"Activation not read: {ex.Message}");
            return default;
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
