using Microsoft.Win32;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App;

/// <summary>
/// Adds Inkvolt Print to Explorer's "Open with" menu for PDFs and pictures (per user, HKCU only). It never takes over the
/// default app; the user chooses. Written on start only when missing or pointing elsewhere (the exe moved). Packaged
/// copies (MSIX) skip this: their "Open with" entries come from the package manifest and go away with the package.
/// <c>InkvoltPrint.exe --unregister</c> removes it all again (<see cref="Unregister"/>), for uninstallers.
/// </summary>
public static class ShellIntegration
{
    public const string UnregisterArgument = "--unregister";

    public static void RegisterOpenWith()
    {
        if (InkvoltPrint.Windows.AppPackage.IsPackaged) return;
        var exe = Environment.ProcessPath;
        // Dev builds run from bin\: don't point Explorer at a build folder.
        if (exe is null || exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            RemoveLegacyOpenWith();
            var command = $"\"{exe}\" \"%1\"";
            if (IsCurrent(command)) return;
            Register(ShellRegistration.PdfProgId, "PDF document", ShellRegistration.PdfTypes, exe, command);
            Register(ShellRegistration.ImageProgId, "Picture", ShellRegistration.ImageTypes, exe, command);
            using var app = Registry.CurrentUser.CreateSubKey(ShellRegistration.ApplicationKey);
            app.SetValue("FriendlyAppName", "Inkvolt Print");
            using (var types = app.CreateSubKey("SupportedTypes"))
                foreach (var ext in ShellRegistration.PdfTypes.Concat(ShellRegistration.ImageTypes)) types.SetValue(ext, "");
            using (var cmd = app.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, command);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            Log.Write($"Open-with registration skipped: {ex.Message}");
        }
    }

    /// <summary>Both ProgIds and the Applications key already open files with this command, and the picture types are listed.</summary>
    private static bool IsCurrent(string command)
    {
        string? Command(string key)
        {
            using var k = Registry.CurrentUser.OpenSubKey(ShellRegistration.CommandKey(key));
            return k?.GetValue(null) as string;
        }
        if (Command(ShellRegistration.ProgIdKey(ShellRegistration.PdfProgId)) != command
            || Command(ShellRegistration.ProgIdKey(ShellRegistration.ImageProgId)) != command
            || Command(ShellRegistration.ApplicationKey) != command) return false;
        return ShellRegistration.ImageTypes.All(ext =>
        {
            using var k = Registry.CurrentUser.OpenSubKey(ShellRegistration.OpenWithKey(ext));
            return k?.GetValueNames().Contains(ShellRegistration.ImageProgId) == true;
        });
    }

    /// <summary>A ProgId that opens files with Inkvolt Print, offered (not made default) for <paramref name="extensions"/>.</summary>
    private static void Register(string progId, string typeName, string[] extensions, string exe, string command)
    {
        using (var prog = Registry.CurrentUser.CreateSubKey(ShellRegistration.ProgIdKey(progId)))
        {
            prog.SetValue(null, typeName);
            prog.SetValue("FriendlyTypeName", typeName);
            using (var icon = prog.CreateSubKey("DefaultIcon")) icon.SetValue(null, $"\"{exe}\",0");
            using (var open = prog.CreateSubKey(@"shell\open")) open.SetValue("FriendlyAppName", "Inkvolt Print");
            using (var cmd = prog.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, command);
        }
        foreach (var ext in extensions)
            using (var key = Registry.CurrentUser.CreateSubKey(ShellRegistration.OpenWithKey(ext)))
                key.SetValue(progId, Array.Empty<byte>(), RegistryValueKind.None);
    }

    /// <summary>
    /// <c>--unregister</c>: removes the "Open with" entries and the Start-with-Windows value this exe wrote (entries pointing at
    /// another copy stay). Returns the process exit code: 0 done (also when there was nothing), 1 the registry refused.
    /// </summary>
    public static int Unregister()
    {
        if (Environment.ProcessPath is not { } exe) return 1;
        try
        {
            var removed = ShellRegistration.Unregister(new CurrentUserRegistry(), exe);
            Log.Write(removed.Count == 0 ? "Unregister: nothing of this copy's was registered" : $"Unregister: removed {string.Join(", ", removed)}");
            return 0;
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            Log.Write($"Unregister failed: {ex.Message}");
            return 1;
        }
    }

    /// <summary>HKCU for <see cref="ShellRegistration.Unregister"/>.</summary>
    private sealed class CurrentUserRegistry : IUserRegistry
    {
        public bool KeyExists(string key)
        {
            using var k = Registry.CurrentUser.OpenSubKey(key);
            return k is not null;
        }

        public string? GetString(string key, string? name)
        {
            using var k = Registry.CurrentUser.OpenSubKey(key);
            return k?.GetValue(name) as string;
        }

        public bool ValueExists(string key, string name)
        {
            using var k = Registry.CurrentUser.OpenSubKey(key);
            return k?.GetValueNames().Contains(name, StringComparer.OrdinalIgnoreCase) == true;
        }

        public void DeleteValue(string key, string name)
        {
            using var k = Registry.CurrentUser.OpenSubKey(key, writable: true);
            k?.DeleteValue(name, throwOnMissingValue: false);
        }

        public void DeleteTree(string key) => Registry.CurrentUser.DeleteSubKeyTree(key, throwOnMissingSubKey: false);
    }

    /// <summary>Drops the "Open with" entry the app registered under its pre-rename name (PrintDesk), if still there.</summary>
    private static void RemoveLegacyOpenWith()
    {
        const string legacyProgId = "PrintDesk.Pdf";
        using (var ext = Registry.CurrentUser.OpenSubKey(@"Software\Classes\.pdf\OpenWithProgids", writable: true))
            ext?.DeleteValue(legacyProgId, throwOnMissingValue: false);
        Registry.CurrentUser.DeleteSubKeyTree($@"Software\Classes\{legacyProgId}", throwOnMissingSubKey: false);
        Registry.CurrentUser.DeleteSubKeyTree(@"Software\Classes\Applications\PrintDesk.exe", throwOnMissingSubKey: false);
    }
}
