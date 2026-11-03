using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Maintenance;

public enum MaintenanceKind
{
    ConfigurationPage, QualityReport, DiagnosticsPage, NetworkPage, WirelessTest,
    Cleaning, CleaningCheck, SmearCleaning, Alignment, Identify,
}

/// <summary>What the printer marks paper with, for the wording ("uses ink", "uses toner").</summary>
public enum Marking { Unknown, Ink, Toner }

/// <summary>
/// One maintenance action a printer advertised: the button's text, what it uses, the question asked before it's sent and
/// how to send it. Built only by <see cref="MaintenanceCatalog.Detect"/>, so every job type or operation is one the
/// printer listed and Inkvolt Print knows the meaning of.
/// </summary>
public sealed record MaintenanceAction
{
    /// <summary>Stable key: <c>ledm:&lt;job type&gt;</c>, <c>ledm:align</c>, <c>ipp:identify</c>.</summary>
    public required string Id { get; init; }
    public required MaintenanceKind Kind { get; init; }
    public required string Title { get; init; }

    /// <summary>The maker whose own interface this uses ("HP"); null for standard IPP.</summary>
    public string? Brand { get; init; }

    /// <summary>What happens and what it uses (paper, ink, toner, time), as the confirmation says it.</summary>
    public required string Uses { get; init; }

    /// <summary>The same in a few words, under the button ("1 page · plain paper · a little toner").</summary>
    public required string Summary { get; init; }

    /// <summary>The confirmation button's wording ("Print", "Clean", "Align", "Identify").</summary>
    public required string ConfirmButton { get; init; }

    /// <summary>Said once the printer took the request.</summary>
    public required string Sent { get; init; }

    /// <summary>Needs paper (and a printer free to print): a jam or a print job holds it back.</summary>
    public bool PrintsPage { get; init; }

    /// <summary>Cleaning level, 1 for the first; 0 for everything else.</summary>
    public int Level { get; init; }

    /// <summary>HP LEDM internal print job type (<c>configurationPage</c>…); null for other actions.</summary>
    public string? JobType { get; init; }

    /// <summary>LEDM: the path the request is POSTed to (InternalPrintDyn or the calibration session).</summary>
    public string? Target { get; init; }

    /// <summary>Identify-Printer: the <c>identify-actions</c> asked for (empty: the printer's default).</summary>
    public IReadOnlyList<string> IdentifyActions { get; init; } = [];

    /// <summary>Listed but can't be started from here (e.g. alignment by hand): the reason, shown with the disabled button.</summary>
    public string? Unavailable { get; init; }

    /// <summary>Button text: the title, with the maker's name when it's that maker's own feature.</summary>
    public string Label => Brand is null ? Title : $"{Title} ({Brand})";

    public string ConfirmText => string.Format(PrintsPage ? CoreStrings.Maint_ConfirmWithPaper : CoreStrings.Maint_Confirm, Label, Uses);
}

/// <summary>Everything the maintenance card shows for one printer.</summary>
/// <param name="SupplyPage">IPP <c>printer-supply-info-uri</c> (PWG 5100.13 §5.6.41): the printer's own page for supplies,
/// head alignment and self-test pages, only when it's on the printer itself.</param>
/// <param name="Note">Why something isn't offered (no maintenance interface, no standard for cleaning).</param>
public sealed record MaintenanceOptions(IReadOnlyList<MaintenanceAction> Actions, Uri? SupplyPage, string? Note)
{
    public static readonly MaintenanceOptions None = new([], null, null);
}

/// <summary>What <see cref="MaintenanceClient.DetectAsync"/> read from the printer.</summary>
public sealed record MaintenanceSources
{
    public required string Host { get; init; }

    /// <summary>HP's LEDM interface answered.</summary>
    public bool HasLedm { get; init; }

    /// <summary>A newer HP printer that answered HP's CDM interface instead (read only in Inkvolt Print).</summary>
    public bool HasCdm { get; init; }

    /// <summary>Read over SNMP only (no LEDM, CDM or IPP): SNMP has no maintenance requests.</summary>
    public bool HasSnmp { get; init; }

    /// <summary>Job types in the printer's InternalPrintCap document; null when it has none (404, unreadable).</summary>
    public IReadOnlyList<string>? LedmJobTypes { get; init; }

    /// <summary>Where internal print jobs are POSTed (the InternalPrint manifest's InternalPrintDyn, else HPLIP's path).</summary>
    public string? LedmDynPath { get; init; }

    /// <summary><c>dd:AlignmentMode</c> (automatic, semiAutomatic, manual), read only when the DiscoveryTree lists the calibration interface.</summary>
    public string? AlignmentMode { get; init; }

    /// <summary>Get-Printer-Attributes with <see cref="MaintenanceClient.IppAttributes"/>; null without IPP.</summary>
    public IppResponse? Ipp { get; init; }

    public Marking Marking { get; init; }
}

/// <summary>
/// Turns what a printer advertises into actions. Sources, re-checked 2026-10 (none of it tried on hardware):
/// <list type="bullet">
/// <item>HP LEDM internal pages: <c>GET /DevMgmt/InternalPrintCap.xml</c> lists <c>ipdyn:JobType</c> values; a POST of
/// <c>ipdyn:InternalPrintDyn</c> to <c>/DevMgmt/InternalPrintDyn.xml</c> runs one. HPLIP base/maint.py (cleaningPage,
/// cleaningPageLevel1/2, cleaningVerificationPage; https://developers.hp.com/hp-linux-imaging-and-printing),
/// github.com/YannKr/hp-printer-maintenance src/hpmaint/ews.py (MIT; configurationPage, pqDiagnosticsPage,
/// diagnosticsPage, cleaningPageLevel2/3) and github.com/stacksjs/ts-printers src/drivers/hp/maintenance.ts
/// (networkSummary, wirelessNetworkPage, ribSmearCleaningPage). DiscoveryTrees published in
/// github.com/manuc66/node-hp-scan-to list it as <c>ledm:hpLedmInternalPrintManifest</c>.</item>
/// <item>HP alignment: <c>dd:AlignmentMode</c> in ConsumableConfigDyn, then <c>POST /Calibration/Session</c> with
/// <c>cal:CalibrationState</c> "Printing" (HPLIP maint.py dataModelHelper; the DiscoveryTree's
/// <c>ledm:hpCnxCalibrationManifest</c>). Manual alignment (choosing patterns by hand) is left to the printer.</item>
/// <item>IPP: Identify-Printer (0x003C, PWG 5100.13 §4.1, "identify-actions" §5.1.4: display, flash, sound, speak) when
/// <c>operations-supported</c> lists it; <c>printer-supply-info-uri</c> (§5.6.41). IPP defines no cleaning, nozzle check or
/// alignment operation (PWG 5100.13 leaves them to the supply page), and the PWG System Service doesn't cover them.</item>
/// </list>
/// The LaserJet MFP M234dw lists neither HP interface (its InternalPrintCap is 404), so it gets the web page only.
/// </summary>
public static class MaintenanceCatalog
{
    private static readonly string[] Reports = ["configurationPage", "pqDiagnosticsPage", "diagnosticsPage", "networkSummary", "wirelessNetworkPage"];
    private static readonly string[] Cleanings = ["cleaningPage", "cleaningPageLevel1", "cleaningPageLevel2", "cleaningPageLevel3"];

    /// <summary>Every LEDM job type Inkvolt Print may send; anything else a printer lists is ignored.</summary>
    public static IReadOnlySet<string> KnownJobTypes { get; } =
        new HashSet<string>([.. Reports, .. Cleanings, "cleaningVerificationPage", "ribSmearCleaningPage"], StringComparer.Ordinal);

    /// <summary>Identify-Printer actions Inkvolt Print asks for, in this order ("speak" reads a message aloud: left out).</summary>
    private static readonly string[] IdentifyOrder = ["flash", "sound", "display"];

    public static MaintenanceOptions Detect(MaintenanceSources s)
    {
        var actions = new List<MaintenanceAction>();
        var supply = s.Marking switch { Marking.Toner => CoreStrings.Maint_Toner, Marking.Ink => CoreStrings.Maint_Ink, _ => CoreStrings.Maint_InkOrToner };
        if (s.LedmJobTypes is { } jobs && s.LedmDynPath is { } dyn)
        {
            var listed = jobs.ToHashSet(StringComparer.Ordinal);
            foreach (var job in Reports.Where(listed.Contains))
                actions.Add(Report(job, supply, dyn));
            var levels = Cleanings.Where(listed.Contains).ToList();
            for (var i = 0; i < levels.Count; i++)
                actions.Add(Cleaning(levels[i], i + 1, s.Marking, dyn));
            if (listed.Contains("cleaningVerificationPage"))
                actions.Add(Hp("cleaningVerificationPage", MaintenanceKind.CleaningCheck, CoreStrings.Maint_CleaningCheck, dyn, CoreStrings.Maint_OnePagePlain,
                    string.Format(CoreStrings.Maint_CleaningCheck_Uses, supply),
                    CoreStrings.Maint_PrintButton, CoreStrings.Maint_CleaningCheck_Sent));
            if (listed.Contains("ribSmearCleaningPage") && s.Marking != Marking.Toner)
                actions.Add(Hp("ribSmearCleaningPage", MaintenanceKind.SmearCleaning, CoreStrings.Maint_Smear, dyn, CoreStrings.Maint_Smear_Summary,
                    CoreStrings.Maint_Smear_Uses,
                    CoreStrings.Maint_CleanButton, CoreStrings.Maint_Smear_Sent));
        }
        if (s.AlignmentMode is { } mode) actions.Add(Alignment(mode));
        if (s.Ipp is { } ipp && ipp.Ints("operations-supported").Contains(IppCodec.IdentifyPrinter))
            actions.Add(Identify(ipp));

        var supplyPage = s.Ipp?.Str("printer-supply-info-uri") is { } u ? OnPrinter(u, s.Host) : null;
        var hpActions = actions.Any(a => a.Brand is not null);
        string? note = (s.HasLedm, hpActions) switch
        {
            (false, _) when s.HasCdm => CoreStrings.Maint_NoteCdm,
            (true, false) => CoreStrings.Maint_NoteLedmNone,
            (false, _) when s.HasSnmp => CoreStrings.Maint_NoteSnmp,
            (false, _) => supplyPage is null ? CoreStrings.Maint_NoteIppWebPage : CoreStrings.Maint_NoteIppMaintenancePage,
            _ => null,
        };
        return new MaintenanceOptions(actions, supplyPage, note);
    }

    private static MaintenanceAction Report(string job, string supply, string dyn) => job switch
    {
        "configurationPage" => Hp(job, MaintenanceKind.ConfigurationPage, CoreStrings.Maint_ConfigPage, dyn, string.Format(CoreStrings.Maint_ConfigPage_Summary, supply),
            string.Format(CoreStrings.Maint_ConfigPage_Uses, supply),
            CoreStrings.Maint_PrintButton, CoreStrings.Maint_ConfigPage_Sent),
        "pqDiagnosticsPage" => Hp(job, MaintenanceKind.QualityReport, CoreStrings.Maint_QualityReport, dyn, string.Format(CoreStrings.Maint_QualityReport_Summary, supply),
            string.Format(CoreStrings.Maint_QualityReport_Uses, supply),
            CoreStrings.Maint_PrintButton, CoreStrings.Maint_QualityReport_Sent),
        "diagnosticsPage" => Hp(job, MaintenanceKind.DiagnosticsPage, CoreStrings.Maint_DiagnosticsPage, dyn, CoreStrings.Maint_DiagnosticsPage_Summary,
            string.Format(CoreStrings.Maint_DiagnosticsPage_Uses, supply),
            CoreStrings.Maint_PrintButton, CoreStrings.Maint_DiagnosticsPage_Sent),
        "networkSummary" => Hp(job, MaintenanceKind.NetworkPage, CoreStrings.Maint_NetworkPage, dyn, CoreStrings.Maint_OnePagePlain,
            string.Format(CoreStrings.Maint_NetworkPage_Uses, supply),
            CoreStrings.Maint_PrintButton, CoreStrings.Maint_NetworkPage_Sent),
        _ => Hp(job, MaintenanceKind.WirelessTest, CoreStrings.Maint_WirelessTest, dyn, CoreStrings.Maint_WirelessTest_Summary,
            string.Format(CoreStrings.Maint_WirelessTest_Uses, supply),
            CoreStrings.Maint_PrintButton, CoreStrings.Maint_WirelessTest_Sent),
    };

    private static MaintenanceAction Cleaning(string job, int level, Marking marking, string dyn)
    {
        if (marking == Marking.Toner)
        {
            // A LaserJet's cleaning page cleans the paper path (fuser), not a printhead.
            return Hp(job, MaintenanceKind.Cleaning, level == 1 ? CoreStrings.Maint_CleaningPage : string.Format(CoreStrings.Maint_CleaningPageLevel, level), dyn,
                CoreStrings.Maint_CleaningPage_Summary, CoreStrings.Maint_CleaningPage_Uses, CoreStrings.Maint_PrintButton, CoreStrings.Maint_CleaningPage_Sent)
                with { Level = level };
        }
        var uses = level == 1
            ? CoreStrings.Maint_CleanHead_Uses
            : string.Format(CoreStrings.Maint_CleanHeadDeeper_Uses, level - 1);
        return Hp(job, MaintenanceKind.Cleaning, level == 1 ? CoreStrings.Maint_CleanHead : string.Format(CoreStrings.Maint_CleanHeadLevel, level), dyn,
            level == 1 ? CoreStrings.Maint_CleanHead_Summary : CoreStrings.Maint_CleanHeadDeeper_Summary, uses, CoreStrings.Maint_CleanButton,
            CoreStrings.Maint_CleanHead_Sent) with { Level = level };
    }

    private static MaintenanceAction Alignment(string mode) => new()
    {
        Id = "ledm:align",
        Kind = MaintenanceKind.Alignment,
        Title = CoreStrings.Maint_Align,
        Brand = "HP",
        Target = MaintenanceRequests.CalibrationSessionPath,
        PrintsPage = true,
        ConfirmButton = CoreStrings.Maint_AlignButton,
        Summary = mode == "semiAutomatic" ? CoreStrings.Maint_AlignSemi_Summary : CoreStrings.Maint_Align_Summary,
        Uses = mode == "semiAutomatic" ? CoreStrings.Maint_AlignSemi_Uses : CoreStrings.Maint_Align_Uses,
        Sent = mode == "semiAutomatic" ? CoreStrings.Maint_AlignSemi_Sent : CoreStrings.Maint_Align_Sent,
        Unavailable = mode is "automatic" or "semiAutomatic" ? null : CoreStrings.Maint_AlignByHand,
    };

    private static MaintenanceAction Identify(IppResponse ipp)
    {
        var supported = ipp.Strs("identify-actions-supported").ToHashSet(StringComparer.Ordinal);
        var chosen = IdentifyOrder.Where(supported.Contains).ToList();
        var what = chosen.Select(a => a switch
        {
            "flash" => CoreStrings.Maint_IdentifyFlashes,
            "sound" => CoreStrings.Maint_IdentifySounds,
            _ => CoreStrings.Maint_IdentifyShowsMessage,
        }).ToList();
        var signal = chosen.Count == 0 ? CoreStrings.Maint_IdentifyUsualSignal
            : string.Join(CoreStrings.Maint_ListAnd, chosen.Select(a => a switch { "flash" => CoreStrings.Maint_IdentifyLights, "sound" => CoreStrings.Maint_IdentifySound, _ => CoreStrings.Maint_IdentifyAMessage }));
        signal = char.ToUpperInvariant(signal[0]) + signal[1..];
        var does = what.Count == 0 ? CoreStrings.Maint_IdentifyAsSet
            : what.Count == 1 ? what[0] : string.Join(", ", what[..^1]) + CoreStrings.Maint_ListAnd + what[^1];
        return new MaintenanceAction
        {
            Id = "ipp:identify",
            Kind = MaintenanceKind.Identify,
            Title = CoreStrings.Maint_Identify,
            Uses = string.Format(CoreStrings.Maint_Identify_Uses, does),
            ConfirmButton = CoreStrings.Maint_IdentifyButton,
            Summary = string.Format(CoreStrings.Maint_Identify_Summary, signal),
            Sent = string.Format(CoreStrings.Maint_Identify_Sent, does),
            IdentifyActions = chosen,
        };
    }

    private static MaintenanceAction Hp(string job, MaintenanceKind kind, string title, string dyn, string summary, string uses, string button, string sent) => new()
    {
        Summary = summary,
        Id = "ledm:" + job,
        Kind = kind,
        Title = title,
        Brand = "HP",
        Uses = uses,
        ConfirmButton = button,
        Sent = sent,
        PrintsPage = true,
        JobType = job,
        Target = dyn,
    };

    /// <summary>An http(s) URL from the printer, only when it points back at the printer itself (never another host).</summary>
    internal static Uri? OnPrinter(string url, string host) =>
        Uri.TryCreate(url, UriKind.Absolute, out var u) && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps)
        && string.Equals(u.IdnHost, host, StringComparison.OrdinalIgnoreCase) && u.UserInfo.Length == 0
            ? u : null;
}

/// <summary>Whether an action can be sent now, and if not, why (shown next to the disabled button).</summary>
public static class MaintenanceAvailability
{
    public static string? WhyNot(MaintenanceAction action, bool online, PrinterStatus? status, bool busy)
    {
        if (action.Unavailable is { } reason) return reason;
        if (!online) return CoreStrings.Maint_NotAnswering;
        if (busy) return CoreStrings.Maint_WaitingForLast;
        if (!action.PrintsPage || status is null) return null;
        if (status.Severity == Severity.Error) return string.Format(CoreStrings.Maint_FixFirst, status.Message.TrimEnd('.'));
        if (status.Code is "processing" or "printing") return CoreStrings.Maint_PrinterPrinting;
        if (Busy.Contains(status.Code)) return string.Format(CoreStrings.Maint_PrinterBusy, status.Message.TrimEnd('.'));
        return null;
    }

    /// <summary>LEDM states (<c>Ledm/StatusText</c>) in which the printer can't take an internal page: it's doing something else.</summary>
    private static readonly HashSet<string> Busy =
        ["copying", "scanProcessing", "initializing", "coolDownMode", "cancelJob", "shuttingDown", "upgrading", "deviceInteraction", "manualDuplex", "manuallyFeed"];
}
