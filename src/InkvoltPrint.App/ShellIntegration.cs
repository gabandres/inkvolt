using Microsoft.Win32;

namespace InkvoltPrint.App;

/// <summary>
/// Adds Inkvolt Print to Explorer's "Open with" menu for PDFs and pictures (per user, HKCU only). It never takes over the
/// default app; the user chooses. Re-registered on start so the path stays right if the exe moves. Packaged copies (MSIX)
/// skip this: their "Open with" entry comes from the package manifest and goes away with the package.
/// </summary>
public static class ShellIntegration
{
    private const string ProgId = "InkvoltPrint.Pdf", ImageProgId = "InkvoltPrint.Image";

    /// <summary>Pictures it prints in the Photos tab ("Open with" only; HEIC / WebP need Windows' codecs, which the tab says).</summary>
    public static readonly string[] ImageTypes = [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".heic", ".webp"];

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
            Register(ProgId, "PDF document", [".pdf"], exe, command);
            Register(ImageProgId, "Picture", ImageTypes, exe, command);
            using var app = Registry.CurrentUser.CreateSubKey(@"Software\Classes\Applications\InkvoltPrint.exe");
            app.SetValue("FriendlyAppName", "Inkvolt Print");
            using (var types = app.CreateSubKey("SupportedTypes"))
                foreach (var ext in ImageTypes.Prepend(".pdf")) types.SetValue(ext, "");
            using (var cmd = app.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, command);
        }
        catch (Exception ex) when (ex is UnauthorizedAccessException or System.Security.SecurityException or System.IO.IOException)
        {
            Log.Write($"Open-with registration skipped: {ex.Message}");
        }
    }

    /// <summary>A ProgId that opens files with Inkvolt Print, offered (not made default) for <paramref name="extensions"/>.</summary>
    private static void Register(string progId, string typeName, string[] extensions, string exe, string command)
    {
        using (var prog = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{progId}"))
        {
            prog.SetValue(null, typeName);
            prog.SetValue("FriendlyTypeName", typeName);
            using (var icon = prog.CreateSubKey("DefaultIcon")) icon.SetValue(null, $"\"{exe}\",0");
            using (var open = prog.CreateSubKey(@"shell\open")) open.SetValue("FriendlyAppName", "Inkvolt Print");
            using (var cmd = prog.CreateSubKey(@"shell\open\command")) cmd.SetValue(null, command);
        }
        foreach (var ext in extensions)
            using (var key = Registry.CurrentUser.CreateSubKey($@"Software\Classes\{ext}\OpenWithProgids"))
                key.SetValue(progId, Array.Empty<byte>(), RegistryValueKind.None);
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
