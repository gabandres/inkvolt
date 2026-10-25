using System.Diagnostics;
using System.IO;

namespace InkvoltPrint.App;

/// <summary>
/// Plain-text log at %LOCALAPPDATA%\InkvoltPrint\logs\inkvoltprint.log (kept under ~1 MB, one rotation).
/// Local only; nothing is sent anywhere. Never log passwords or document contents.
/// </summary>
public static class Log
{
    private static readonly Lock Gate = new();
    private const long MaxBytes = 1_000_000;

    public static string FilePath { get; } = Path.Combine(AppState.DataDirectory, "logs", "inkvoltprint.log");

    public static void Write(string message)
    {
        // Printer-supplied text (names, errors) must not be able to forge extra log lines.
        message = string.Create(message.Length, message, (span, m) =>
        {
            for (var i = 0; i < m.Length; i++) span[i] = char.IsControl(m[i]) && m[i] is not ('\n' or '\r' or '\t') ? ' ' : m[i];
        }).Replace("\r\n", "\n").Replace("\n", "\n    ");
        Trace.WriteLine(message);
        try
        {
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > MaxBytes)
                    File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Logging must never take the app down.
        }
    }
}

/// <summary>Opens URLs, files and settings pages without letting a missing handler crash the app.</summary>
public static class Shell
{
    public static void Open(string target)
    {
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            Log.Write($"Could not open {target}: {ex.Message}");
        }
    }

    public static void ShowInFolder(string path)
    {
        try
        {
            Process.Start("explorer.exe", $"/select,\"{path}\"")?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Log.Write($"Could not show {path}: {ex.Message}");
        }
    }
}
