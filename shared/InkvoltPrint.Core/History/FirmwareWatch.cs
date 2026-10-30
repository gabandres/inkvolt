using System.Globalization;

namespace InkvoltPrint.Core.History;

/// <summary>
/// One printer's firmware as remembered (roadmap 1.5): the version and the day it was first seen, and the last change, which the
/// status card shows until it's dismissed or <see cref="FirmwareWatch.NoticeDays"/> have passed. Kept in <c>state.json</c>.
/// </summary>
/// <param name="Version">As the printer reports it (<see cref="Model.FirmwareInfo.Display"/>).</param>
/// <param name="Since">The day this version was first seen.</param>
/// <param name="Previous">The version before it, when a change was seen; null for the first version seen.</param>
/// <param name="Dismissed">The notice of the change to <see cref="Version"/> was closed.</param>
public sealed record FirmwareRecord(string Version, DateOnly Since, string? Previous = null, bool Dismissed = false);

/// <summary>A firmware change to tell: "Firmware changed from X to Y on 12 October 2026".</summary>
public sealed record FirmwareChange(string From, string To, DateOnly On)
{
    public string Text => $"Firmware changed from {From} to {To} on {On.ToString("d MMMM yyyy", CultureInfo.CurrentCulture)}.";

    /// <summary>The alert's key: one per change, so the same change never alerts twice.</summary>
    public string Key => $"{From}→{To}";
}

/// <summary>
/// Firmware watch: remembers each printer's firmware version and notices when it changes (an update the printer installed by
/// itself, or one somebody installed). HP's firmware updates have brought "dynamic security", which stops cartridges with
/// non-HP chips from working, so a change is worth telling. Pure: the caller keeps the record and supplies the day.
/// </summary>
public static class FirmwareWatch
{
    /// <summary>How long a change stays on the status card when nobody closes it.</summary>
    public const int NoticeDays = 30;

    private const int MaxVersion = 80;

    /// <summary>
    /// The record after a connection reported <paramref name="version"/>: unchanged when the version is the one known (or
    /// unknown now: an empty version tells nothing), a new record with the change otherwise. The first version seen is no change.
    /// </summary>
    public static FirmwareRecord? Observe(FirmwareRecord? known, string? version, DateOnly today)
    {
        var v = Clean(version);
        if (v.Length == 0) return known;
        if (known is null) return new FirmwareRecord(v, today);
        if (string.Equals(known.Version, v, StringComparison.Ordinal)) return known;
        return new FirmwareRecord(v, today, known.Version);
    }

    /// <summary>The change to show now: the last one, while it isn't dismissed and is under <see cref="NoticeDays"/> old.</summary>
    public static FirmwareChange? Notice(FirmwareRecord? record, DateOnly today) =>
        record is { Previous: { } from, Dismissed: false } && today.DayNumber - record.Since.DayNumber < NoticeDays
            ? new FirmwareChange(from, record.Version, record.Since)
            : null;

    /// <summary>What a printer reports, fit to remember and show: one line, no control characters, cut to length.</summary>
    private static string Clean(string? version)
    {
        var clean = new string((version ?? "").Where(c => !char.IsControl(c)).ToArray()).Trim();
        return clean.Length <= MaxVersion ? clean : clean[..MaxVersion];
    }
}
