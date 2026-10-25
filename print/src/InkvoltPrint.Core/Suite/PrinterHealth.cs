using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Suite;

public enum Readiness { Ready, Sleeping, Busy, Attention, Error, Offline, Unknown }

/// <summary>
/// A printer's state reduced to what matters before printing: ready / sleeping / busy / needs attention / error / offline,
/// toner level and paper problems. Built from Inkvolt Print's protocol-neutral status and supplies.
/// </summary>
public sealed record PrinterHealth(
    Readiness State,
    string Text,
    int? TonerPercent,
    IReadOnlyList<string> PaperProblems,
    IReadOnlyList<string> Problems,
    IReadOnlyList<string> Supplies)
{
    /// <summary>Printing now would likely fail or wait: offline, or an error (jam, no paper, door open, empty toner).</summary>
    public bool ShouldWarn => State is Readiness.Offline or Readiness.Error;

    public static PrinterHealth Offline(string why) => new(Readiness.Offline, why, null, [], [], []);

    /// <summary>One line: "Ready · toner 45%", "Sleeping · toner 8% (low)", "Tray empty or open".</summary>
    public string Summary
    {
        get
        {
            var parts = new List<string> { Text };
            foreach (var p in PaperProblems.Concat(Problems))
                if (!parts.Contains(p, StringComparer.OrdinalIgnoreCase)) parts.Add(p);
            if (TonerPercent is { } t) parts.Add($"toner {t}%");
            return string.Join(" · ", parts);
        }
    }

    public static PrinterHealth From(PrinterStatus status, IReadOnlyList<Consumable> supplies)
    {
        var paper = status.Alerts.Where(a => IsPaper(a.Id) && a.Severity >= Severity.Warning).Select(a => a.Message).Distinct().ToList();
        var problems = status.Alerts.Where(a => !IsPaper(a.Id) && a.Severity >= Severity.Warning).Select(a => a.Message).Distinct().ToList();
        var toners = supplies.Where(c => c.Kind.Contains("toner", StringComparison.OrdinalIgnoreCase) || c.Name.Contains("toner", StringComparison.OrdinalIgnoreCase)).ToList();
        if (toners.Count == 0) toners = supplies.Where(c => c.Kind.Contains("ink", StringComparison.OrdinalIgnoreCase) || c.Kind.Contains("cartridge", StringComparison.OrdinalIgnoreCase)).ToList();
        int? toner = toners.Select(c => c.PercentRemaining).Where(p => p is not null).Min();
        var supplyText = supplies.Where(c => c.PercentRemaining is not null)
            .Select(c => $"{c.Name}: {c.PercentRemaining}%{(c.IsLow ? " (low)" : "")}").ToList();

        var state = status.Code switch
        {
            "offline" => Readiness.Offline,
            "unavailable" or "unknown" when status.Alerts.Count == 0 => Readiness.Unknown,
            _ when status.Severity == Severity.Error => Readiness.Error,
            "inPowerSave" => Readiness.Sleeping,
            "ready" or "idle" => status.Severity == Severity.Warning ? Readiness.Attention : Readiness.Ready,
            "stopped" => Readiness.Error,
            _ when status.Severity == Severity.Warning => Readiness.Attention,
            "processing" or "copying" or "scanProcessing" or "initializing" or "coolDownMode" or "cancelJob" or "upgrading"
                or "connectingToWeb" or "deviceInteraction" or "waitingForSupplyAssessment" => Readiness.Busy,
            _ => Readiness.Unknown,
        };
        var text = state switch
        {
            Readiness.Sleeping => "Sleeping",
            Readiness.Ready => "Ready",
            _ => status.Message,
        };
        return new PrinterHealth(state, text, toner, paper, problems, supplyText);
    }

    /// <summary>Paper path problems (LEDM ids and IPP printer-state-reasons), not the scanner's document feeder.</summary>
    internal static bool IsPaper(string id) =>
        !id.StartsWith("scanner", StringComparison.OrdinalIgnoreCase) &&
        (id.Contains("media", StringComparison.OrdinalIgnoreCase) || id.Contains("tray", StringComparison.OrdinalIgnoreCase) ||
         id.Contains("jam", StringComparison.OrdinalIgnoreCase) || id.Contains("mispick", StringComparison.OrdinalIgnoreCase) ||
         id.Contains("paper", StringComparison.OrdinalIgnoreCase) || id.Contains("feed", StringComparison.OrdinalIgnoreCase));
}
