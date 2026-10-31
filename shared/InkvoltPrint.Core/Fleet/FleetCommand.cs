using System.Text;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Fleet;

/// <summary>
/// <c>inkvoltprint status --all [--json] [--out file]</c>, for a script or a scheduled task (Inkvolt Pro): reads every printer once
/// (<see cref="FleetReader"/>) and writes the list, most trouble first, as JSON (<c>print/schemas/fleet-status.schema.json</c>) or a
/// line per printer. Both Inkvolt Print's window app and the developer CLI run it. Exit codes are Inkvolt PDF's: a printer in
/// trouble is what the report says, not a failure; <see cref="SomeFailed"/> means the report couldn't be written.
/// </summary>
public static class FleetCommand
{
    public const int Done = 0, SomeFailed = 1, Wrong = 2, Stopped = 3;

    private const string Usage = "Usage: inkvoltprint status --all [--json] [--out file]";

    /// <summary>The arguments ask for this command, not for a window: the first one past the demo's own switches is <c>status</c>.</summary>
    public static bool IsFor(IReadOnlyList<string> args) =>
        args.FirstOrDefault(a => a is not ("--demo" or "--no-printers" or "--pro-enforce")) == "status";

    public static async Task<int> RunAsync(IReadOnlyList<string> args, TextWriter output, TextWriter error, IFleetPc pc, Func<DateTimeOffset> clock,
        Diagnostics.Identity who, CancellationToken ct)
    {
        if (!Pro.Allows(ProFeature.FleetExport))
        {
            error.WriteLine(Pro.Locked(ProFeature.FleetExport));
            error.WriteLine(Pro.HowToGet);
            return Wrong;
        }
        bool all = false, json = false;
        string? file = null;
        var rest = args.Where(a => a != "--demo").Skip(1).ToList();
        for (var i = 0; i < rest.Count; i++)
        {
            switch (rest[i])
            {
                case "--all": all = true; break;
                case "--json": json = true; break;
                case "--out" when i + 1 < rest.Count && !rest[i + 1].StartsWith("--", StringComparison.Ordinal): file = rest[++i]; break;
                default:
                    error.WriteLine(Usage);
                    return Wrong;
            }
        }
        if (!all)
        {
            error.WriteLine(Usage);
            return Wrong;
        }

        FleetRead read;
        try
        {
            read = await FleetReader.ReadAllAsync(pc, clock(), ct: ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            error.WriteLine("Stopped before every printer was read; nothing was written.");
            return Stopped;
        }
        var now = clock();
        var text = json ? FleetExport.Json(read.Printers, read.Notes, now, who) + Environment.NewLine : Lines(read, now, who);
        if (file is null)
        {
            output.Write(text);
            return Done;
        }
        try
        {
            WriteWhole(file, text);
            return Done;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            error.WriteLine($"Could not write {file}: {ex.Message}");
            return SomeFailed;
        }
    }

    /// <summary>A line per printer: what a person reads in a terminal. Names may be in any script, so the console writes them as it can.</summary>
    private static string Lines(FleetRead read, DateTimeOffset now, Diagnostics.Identity who)
    {
        var printers = read.Printers.Select(p => FleetExport.Scrubbed(p, who)).ToList();
        var lines = new StringBuilder(FleetPage.Summary(printers)).AppendLine();
        foreach (var row in FleetPage.Rows(printers, now))
        {
            var supplies = row.Supplies.Count > 0 ? string.Join(", ", row.Supplies.Select(s => s.Text)) : row.NoSuppliesText;
            lines.AppendLine(string.Join(" | ", row.Printer.Name, row.StatusLine, supplies, row.PagesText, row.FirmwareText, row.LastReadText));
        }
        foreach (var note in read.Notes) lines.AppendLine(note);
        return lines.ToString();
    }

    /// <summary>Written beside the file and moved over it, so a script never reads half a report.</summary>
    private static void WriteWhole(string file, string text)
    {
        var temporary = $"{file}.{Guid.NewGuid():N}.tmp";
        try
        {
            File.WriteAllText(temporary, text, new UTF8Encoding(false));
            File.Move(temporary, file, overwrite: true);
        }
        catch
        {
            try { File.Delete(temporary); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            throw;
        }
    }
}
