using Microsoft.Win32;

namespace PrintDesk.App;

/// <summary>
/// Adds PrintDesk to Explorer's "Open with" menu for PDFs (per user, HKCU only). It never takes over the default
/// PDF app; the user chooses. Re-registered on start so the path stays right if the exe moves. Packaged copies (MSIX)
/// skip this: their "Open with" entry comes from the package manifest and goes away with the package.
/// </summary>
public static class ShellIntegration
{
    private const string ProgId = "PrintDesk.Pdf";

    public static void RegisterOpenWith()
    {
        if (PrintDesk.Windows.AppPackage.IsPackaged) return;
        var exe = Environment.ProcessPath;
        // Dev builds run from bin\: don't point Explorer at a build folder.
        if (exe is null || exe.Contains(@"\bin\", StringComparison.OrdinalIgnoreCase)) return;
        try
        {
            var command = $"\"{exe}\" \"%1\"";
            using (var prog = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ProgId}"))
            {
                if (prog.OpenSubKey(@"shell\open\command")?.GetValue(null) as string == command) return; // already current
                prog.SetValue(null, "PDF document");
                prog.SetValue("FriendlyTypeName", "PDF document");
                using (var icon = prog.CreateSubKey("DefaultIcon")) icon.SetValue(null, $"\"{exe}\",0");
                using (var open = prog.CreateSubKey(@"shell\open")) open.SetValue("FriendlyAppName", "PrintDesk");
                using (var cmd = prog.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, command);
            }
            using (var ext = Registry.CurrentUser.CreateSubKey(@"Software\Classes\.pdf\OpenWithProgids"))
                ext.SetValue(ProgId, Array.Empty<byte>(), RegistryValueKind.None);
            using (var app = Registry.CurrentUser.CreateSubKey(@"Software\Classes\Applications\PrintDesk.exe"))
            {
                app.SetValue("FriendlyAppName", "PrintDesk");
                using (var types = app.CreateSubKey("SupportedTypes")) types.SetValue(".pdf", "");
                using (var cmd = app.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, command);
            }
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            Log.Write($"Open-with registration skipped: {ex.Message}");
        }
    }
}
