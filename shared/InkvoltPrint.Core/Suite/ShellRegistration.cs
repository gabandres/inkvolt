namespace InkvoltPrint.Core.Suite;

/// <summary>The part of HKCU the unregistration reads and deletes (keys relative to HKCU; a null value name is the default value).</summary>
public interface IUserRegistry
{
    bool KeyExists(string key);
    string? GetString(string key, string? name);
    bool ValueExists(string key, string name);
    void DeleteValue(string key, string name);
    void DeleteTree(string key);
}

/// <summary>
/// What an installed, unpackaged Inkvolt Print writes to HKCU for Explorer, sign-in and notifications: "Open with" ProgIds
/// for PDFs and pictures, their OpenWithProgids entries, the Applications\InkvoltPrint.exe key, the Start-with-Windows Run
/// value and the toast identity (App/ShellIntegration, App/Tray/StartWithWindows, App/Tray/ToastAlerts).
/// <see cref="Unregister"/> removes exactly that, and only where it points at the given exe, so uninstalling one copy leaves
/// another copy's entries alone (<c>InkvoltPrint.exe --unregister</c>).
/// </summary>
public static class ShellRegistration
{
    public const string PdfProgId = "InkvoltPrint.Pdf", ImageProgId = "InkvoltPrint.Image";
    public const string ApplicationKey = @"Software\Classes\Applications\InkvoltPrint.exe";
    public const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    public const string RunValue = "Inkvolt Print";

    /// <summary>The Store package's startup task (<c>uap5:StartupTask</c> in packaging/AppxManifest.template.xml): Start with Windows there.</summary>
    public const string StartupTaskId = "InkvoltPrintTray";

    /// <summary>
    /// The application user model ID an unpackaged copy sends its toast notifications under, registered at
    /// <see cref="AppUserModelIdKey"/> (DisplayName, IconUri, and <see cref="AppUserModelIdExeValue"/> naming the copy that
    /// wrote it) so Windows shows them under the app's name. A packaged copy uses its package's own ID and registers nothing.
    /// </summary>
    public const string AppUserModelId = "BermudezSystems.InkvoltPrint";
    public const string AppUserModelIdKey = $@"Software\Classes\AppUserModelId\{AppUserModelId}";
    public const string AppUserModelIdExeValue = "InkvoltPrintExe";

    public static readonly string[] PdfTypes = [".pdf"];

    /// <summary>Pictures it prints in the Photos tab ("Open with" only; HEIC / WebP need Windows' codecs, which the tab says).</summary>
    public static readonly string[] ImageTypes = [".jpg", ".jpeg", ".png", ".bmp", ".gif", ".tif", ".tiff", ".heic", ".webp"];

    public static string ProgIdKey(string progId) => $@"Software\Classes\{progId}";
    public static string CommandKey(string key) => key + @"\shell\open\command";
    public static string OpenWithKey(string extension) => $@"Software\Classes\{extension}\OpenWithProgids";

    /// <summary>The program a shell command line starts: <c>"C:\x\InkvoltPrint.exe" "%1"</c> → <c>C:\x\InkvoltPrint.exe</c>.</summary>
    public static string? CommandExe(string? command)
    {
        command = command?.Trim();
        if (string.IsNullOrEmpty(command)) return null;
        if (command[0] == '"')
        {
            var end = command.IndexOf('"', 1);
            return end > 1 ? command[1..end] : null;
        }
        var exe = command.IndexOf(".exe", StringComparison.OrdinalIgnoreCase);
        return exe > 0 ? command[..(exe + 4)] : command.Split(' ')[0];
    }

    /// <summary>The command starts <paramref name="exePath"/> (case and slash direction don't matter).</summary>
    public static bool PointsAt(string? command, string exePath) =>
        CommandExe(command) is { } exe && string.Equals(Normalize(exe), Normalize(exePath), StringComparison.OrdinalIgnoreCase);

    private static string Normalize(string path) => path.Trim().Replace('/', '\\');

    private static bool SamePath(string a, string b) => string.Equals(Normalize(a), Normalize(b), StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// Whether the copy at <paramref name="exePath"/> may write the "Open with" entries (and the jump list): an installed copy
    /// (<paramref name="installedExes"/>, the installer's folders) always may; any other copy only when no entry points at
    /// another program that still exists. So a dev build or a copy in another folder never takes over the installed copy's
    /// entries (and its <c>--unregister</c> then finds nothing of its own), while a copy whose old exe is gone does.
    /// </summary>
    public static bool MayRegister(IUserRegistry registry, string exePath, IEnumerable<string> installedExes, Func<string, bool> fileExists)
    {
        if (installedExes.Any(i => SamePath(i, exePath))) return true;
        foreach (var key in new[] { ProgIdKey(PdfProgId), ProgIdKey(ImageProgId), ApplicationKey })
            if (CommandExe(registry.GetString(CommandKey(key), null)) is { } other && !SamePath(other, exePath) && fileExists(other))
                return false;
        return true;
    }

    /// <summary>
    /// Removes this copy's registrations: each ProgId whose open command starts <paramref name="exePath"/>, with its
    /// OpenWithProgids entries (also entries left behind by a ProgId that's already gone), the Applications key when its
    /// command starts this exe, and the Run value when it does. Returns what was removed, for the log.
    /// </summary>
    public static IReadOnlyList<string> Unregister(IUserRegistry registry, string exePath)
    {
        var removed = new List<string>();
        foreach (var (progId, types) in new[] { (PdfProgId, PdfTypes), (ImageProgId, ImageTypes) })
        {
            var key = ProgIdKey(progId);
            var exists = registry.KeyExists(key);
            if (exists && !PointsAt(registry.GetString(CommandKey(key), null), exePath)) continue; // another copy's
            if (exists)
            {
                registry.DeleteTree(key);
                removed.Add(key);
            }
            foreach (var ext in types)
            {
                var openWith = OpenWithKey(ext);
                if (!registry.ValueExists(openWith, progId)) continue;
                registry.DeleteValue(openWith, progId);
                removed.Add($@"{openWith}\{progId}");
            }
        }
        if (registry.KeyExists(ApplicationKey) && PointsAt(registry.GetString(CommandKey(ApplicationKey), null), exePath))
        {
            registry.DeleteTree(ApplicationKey);
            removed.Add(ApplicationKey);
        }
        if (PointsAt(registry.GetString(RunKey, RunValue), exePath))
        {
            registry.DeleteValue(RunKey, RunValue);
            removed.Add($@"{RunKey}\{RunValue}");
        }
        if (registry.KeyExists(AppUserModelIdKey) && PointsAt(registry.GetString(AppUserModelIdKey, AppUserModelIdExeValue), exePath))
        {
            registry.DeleteTree(AppUserModelIdKey);
            removed.Add(AppUserModelIdKey);
        }
        return removed;
    }
}
