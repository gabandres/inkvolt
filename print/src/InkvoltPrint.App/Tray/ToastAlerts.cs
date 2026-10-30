using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using Microsoft.Win32;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows;
using Windows.Data.Xml.Dom;
using Windows.UI.Notifications;

namespace InkvoltPrint.App.Tray;

/// <summary>
/// Alerts as Windows toast notifications (<see cref="Core.Alerts.AlertToasts"/> writes them): one per printer, with Open
/// printer and Pause alerts buttons, a newer alert for a printer replacing the one still showing, kept in Notification
/// Center. The packaged (Microsoft Store) copy sends them under its package identity; an installed unpackaged copy under
/// an application user model ID it registers in HKCU (<see cref="ShellRegistration.AppUserModelIdKey"/>: the app's name
/// and its icon, written to the data folder), which <c>--unregister</c> removes. Clicks come back to the running app
/// through the toast's Activated event (both copies); a toast clicked after the packaged app exited starts it with the
/// arguments (<see cref="PackagedActivation"/>), an unpackaged one just starts it (no COM activator). Where neither
/// identity is available (a dev build from bin\, demo mode unpackaged, a registry that refused) the icon's balloons are
/// used instead (<see cref="NotifyIcon.Notify"/>).
/// </summary>
public sealed class ToastAlerts
{
    private readonly ToastNotifier _notifier;
    private readonly Action<string?> _activated;

    private ToastAlerts(ToastNotifier notifier, Action<string?> activated) => (_notifier, _activated) = (notifier, activated);

    /// <summary>The toasts, or null where balloons must do. <paramref name="activated"/> gets a click's arguments, on the UI thread.</summary>
    public static ToastAlerts? TryCreate(bool demo, Action<string?> activated)
    {
        try
        {
            if (AppPackage.IsPackaged) return new ToastAlerts(ToastNotificationManager.CreateToastNotifier(), Marshal(activated));
            if (demo || !IdentityRegistered()) return null;
            return new ToastAlerts(ToastNotificationManager.CreateToastNotifier(ShellRegistration.AppUserModelId), Marshal(activated));
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or UnauthorizedAccessException or IOException or ArgumentException)
        {
            Log.Write($"Toast notifications unavailable, using balloons: {ex.Message}");
            return null;
        }
    }

    private static Action<string?> Marshal(Action<string?> activated) =>
        arguments => Application.Current?.Dispatcher.InvokeAsync(() => activated(arguments));

    /// <summary>One printer's alerts (all with one <see cref="AlertNotice.Uuid"/>). False when Windows refused it.</summary>
    public bool Show(IReadOnlyList<AlertNotice> notices)
    {
        try
        {
            var xml = new XmlDocument();
            xml.LoadXml(AlertToasts.Xml(notices));
            var toast = new ToastNotification(xml) { Tag = AlertToasts.Tag(notices[0].Uuid), Group = AlertToasts.Group };
            toast.Activated += (_, args) => _activated((args as ToastActivatedEventArgs)?.Arguments);
            _notifier.Show(toast);
            return true;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or ArgumentException)
        {
            Log.Write($"Toast not shown: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// The unpackaged copy's identity for toasts, written by the installed copy (or one that may register, as the "Open
    /// with" entries: <see cref="ShellIntegration.MayRegister"/>) and used by any copy that finds it. Dev builds from bin\
    /// write nothing.
    /// </summary>
    private static bool IdentityRegistered()
    {
        var exe = Environment.ProcessPath;
        if (exe is null || exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase)) return false;
        using (var existing = Registry.CurrentUser.OpenSubKey(ShellRegistration.AppUserModelIdKey))
        {
            if (existing?.GetValue("DisplayName") is string && existing.GetValue("IconUri") is string icon && File.Exists(icon)) return true;
        }
        if (!ShellIntegration.MayRegister(exe)) return false;
        var iconPath = Path.Combine(AppState.DataDirectory, "InkvoltPrint.ico");
        if (!File.Exists(iconPath))
        {
            var info = Application.GetResourceStream(new Uri("pack://application:,,,/InkvoltPrint.ico")) ?? throw new IOException("InkvoltPrint.ico is missing.");
            Directory.CreateDirectory(AppState.DataDirectory);
            using var file = File.Create(iconPath);
            info.Stream.CopyTo(file);
        }
        using var key = Registry.CurrentUser.CreateSubKey(ShellRegistration.AppUserModelIdKey);
        key.SetValue("DisplayName", "Inkvolt Print");
        key.SetValue("IconUri", iconPath);
        key.SetValue(ShellRegistration.AppUserModelIdExeValue, exe);
        Log.Write("Toast identity registered for this copy");
        return true;
    }
}
