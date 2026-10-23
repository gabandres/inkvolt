using System.Diagnostics;
using Microsoft.Win32;

namespace PrintDesk.Windows.Suite;

/// <summary>
/// Finds and starts the other Desk apps (PdfDesk, PrintDesk). Looks in App Paths (per user, then per machine), which the
/// Desk installer registers, then in the default install folders. A running copy of the app receives the arguments
/// through its own single-instance pipe.
/// </summary>
public static class DeskApps
{
    public const string PdfDesk = "PdfDesk.exe";
    public const string PrintDesk = "PrintDesk.exe";

    private const string AppPathsKey = @"Software\Microsoft\Windows\CurrentVersion\App Paths\";

    /// <summary>Full path of the installed app, or null when it isn't installed.</summary>
    public static string? Find(string exeName)
    {
        foreach (var hive in new[] { Registry.CurrentUser, Registry.LocalMachine })
        {
            try
            {
                using var key = hive.OpenSubKey(AppPathsKey + exeName);
                if (Usable(key?.GetValue(null) as string, exeName) is { } registered) return registered;
            }
            catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
            {
                // Unreadable key: try the next place.
            }
        }
        var programs = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs");
        var stem = Path.GetFileNameWithoutExtension(exeName);
        return new[] { Path.Combine(programs, "Desk", stem, exeName), Path.Combine(programs, stem, exeName) }
            .Select(p => Usable(p, exeName)).FirstOrDefault(p => p is not null);
    }

    /// <summary>Starts the app with <paramref name="args"/>. False when it isn't installed or wouldn't start.</summary>
    public static bool Launch(string exeName, params string[] args)
    {
        if (Find(exeName) is not { } exe) return false;
        try
        {
            var psi = new ProcessStartInfo(exe) { UseShellExecute = false, WorkingDirectory = Path.GetDirectoryName(exe)! };
            foreach (var a in args) psi.ArgumentList.Add(a);
            Process.Start(psi)?.Dispose();
            return true;
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or IOException)
        {
            Trace.WriteLine($"Could not start {exeName}: {ex.Message}");
            return false;
        }
    }

    /// <summary>The path, unquoted and expanded, if it names an existing <paramref name="exeName"/>.</summary>
    internal static string? Usable(string? path, string exeName)
    {
        if (string.IsNullOrWhiteSpace(path)) return null;
        try
        {
            var full = Path.GetFullPath(Environment.ExpandEnvironmentVariables(path.Trim().Trim('"')));
            return string.Equals(Path.GetFileName(full), exeName, StringComparison.OrdinalIgnoreCase) && File.Exists(full) ? full : null;
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return null;
        }
    }
}
