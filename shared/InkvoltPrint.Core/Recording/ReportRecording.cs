using System.Globalization;
using System.IO.Compression;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Recording;

/// <summary>A recording made for a report: its folder, the .zip of it to attach, and what the command says about it.</summary>
public sealed record ReportRecordingDone(string Folder, string Zip, RecordResult Result);

/// <summary>
/// Help › Report a problem's way to <see cref="PrinterRecorder"/> (print/ROADMAP.md 1.2): the same recording as
/// <c>inkvoltprint record</c>, so the same scrubbing and the same read-only rules, never with scanned pages. The folder is new each
/// time and named by the clock, never by anything the printer says, and holds nothing if the recording fails or is cancelled.
/// Nothing is sent: the user attaches the .zip by hand.
/// </summary>
public static class ReportRecording
{
    public const string Prefix = "printer-recording-";

    public static async Task<ReportRecordingDone> RunAsync(string host, string parent, RecordOptions options, DateTime now, CancellationToken ct = default)
    {
        Directory.CreateDirectory(parent);
        var folder = NewFolder(parent, now);
        var zip = folder + ".zip";
        try
        {
            var result = await PrinterRecorder.RecordAsync(host, folder, options with { Scan = false }, ct).ConfigureAwait(false);
            await Task.Run(() => ZipFile.CreateFromDirectory(folder, zip), ct).ConfigureAwait(false);
            return new ReportRecordingDone(folder, zip, result);
        }
        catch
        {
            Remove(folder, zip);
            throw;
        }
    }

    /// <summary>The line the report's details get: what was recorded and the file's name, no folder and nothing to identify the printer.</summary>
    public static string ReportLine(ReportRecordingDone done, Diagnostics.Identity who)
    {
        var what = Diagnostics.Scrub($"{done.Result.Model ?? "A printer"} ({string.Join(", ", done.Result.Interfaces)}), {done.Result.Files.Count} files", who);
        return $"Printer recording: {what}, {Path.GetFileName(done.Zip)}";
    }

    /// <summary>Why it didn't work, as the report's scrubbing would show it: the address a message quotes stays out of what's copied.</summary>
    public static string FailureText(Exception ex, Diagnostics.Identity who) => "Nothing recorded: " + Diagnostics.Scrub(ex.Message, who);

    private static string NewFolder(string parent, DateTime now)
    {
        var name = Prefix + now.ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
        var folder = Path.Combine(parent, name);
        for (var i = 2; Directory.Exists(folder) || File.Exists(folder + ".zip"); i++) folder = Path.Combine(parent, $"{name}-{i}");
        return folder;
    }

    private static void Remove(string folder, string zip)
    {
        try
        {
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
            if (File.Exists(zip)) File.Delete(zip);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { } // the failure itself is what gets told
    }
}
