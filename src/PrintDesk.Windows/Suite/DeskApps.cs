using System.Diagnostics;
using Microsoft.Win32;
using PrintDesk.Core.Suite;

namespace PrintDesk.Windows.Suite;

/// <summary>
/// Finds and starts the other Desk apps (PdfDesk, PrintDesk), packaged or not. Looks for the packaged app's execution
/// alias (%LOCALAPPDATA%\Microsoft\WindowsApps\pdfdesk.exe, declared by the MSIX manifest), then App Paths (per user,
/// then per machine), which the Desk installer registers, then the default install folders (<see cref="DeskPaths"/>).
/// A running copy of the app receives the arguments through its own single-instance pipe.
/// </summary>
public static class DeskApps
{
    public const string PdfDesk = "PdfDesk.exe";
    public const string PrintDesk = "PrintDesk.exe";

    private const string AppPathsKey = @"Software\Microsoft\Windows\CurrentVersion\App Paths\";

    /// <summary>Full path of the installed app, or null when it isn't installed.</summary>
    public static string? Find(string exeName)
    {
        var (alias, folders) = DeskPaths.AppCandidates(exeName, Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData));
        // An execution alias is a zero-byte reparse point: File.Exists sees it, and starting it launches the package.
        if (Usable(alias, exeName) is { } packaged) return packaged;
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
        return folders.Select(p => Usable(p, exeName)).FirstOrDefault(p => p is not null);
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
