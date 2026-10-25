using System.Xml.Linq;

namespace InkvoltPrint.Core.Maintenance;

/// <summary>
/// HP LEDM maintenance documents: what is read to find the actions and the exact bodies sent to start one. Sources: see
/// <see cref="MaintenanceCatalog"/>. Namespace-agnostic when reading (LEDM namespaces drift across firmware), exact when writing.
/// </summary>
public static class MaintenanceRequests
{
    public const string InternalPrintDynNs = "http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21";
    public const string CalibrationNs = "http://www.hp.com/schemas/imaging/con/cnx/markingagentcalibration/2009/04/08";

    /// <summary>HPLIP's paths, used when the DiscoveryTree has no InternalPrint manifest saying otherwise.</summary>
    public const string InternalPrintCapPath = "/DevMgmt/InternalPrintCap.xml", InternalPrintDynPath = "/DevMgmt/InternalPrintDyn.xml";

    public const string CalibrationStatePath = "/Calibration/State", CalibrationSessionPath = "/Calibration/Session";

    /// <summary>DiscoveryTree <c>SupportedIfc</c> types (seen in published HP inkjet trees).</summary>
    public const string InternalPrintManifest = "ledm:hpLedmInternalPrintManifest", CalibrationManifest = "ledm:hpCnxCalibrationManifest";

    /// <summary>
    /// <c>&lt;ipdyn:InternalPrintDyn&gt;&lt;ipdyn:JobType&gt;…&lt;/ipdyn:JobType&gt;&lt;/ipdyn:InternalPrintDyn&gt;</c>, the body
    /// HP's own web page posts (as captured by hp-printer-maintenance and pqdiag). Only job types in
    /// <see cref="MaintenanceCatalog.KnownJobTypes"/>: nothing a printer sends back is ever echoed into a request.
    /// </summary>
    public static string InternalPrint(string jobType)
    {
        if (!MaintenanceCatalog.KnownJobTypes.Contains(jobType)) throw new ArgumentException($"Unknown internal print job type \"{jobType}\"", nameof(jobType));
        XNamespace ns = InternalPrintDynNs;
        var root = new XElement(ns + "InternalPrintDyn", new XAttribute(XNamespace.Xmlns + "ipdyn", ns), new XElement(ns + "JobType", jobType));
        return Declaration + root.ToString(SaveOptions.DisableFormatting);
    }

    /// <summary><c>&lt;cal:CalibrationState&gt;Printing&lt;/cal:CalibrationState&gt;</c>: start an alignment (HPLIP maint.py).</summary>
    public static string StartAlignment()
    {
        XNamespace ns = CalibrationNs;
        return Declaration + new XElement(ns + "CalibrationState", new XAttribute(XNamespace.Xmlns + "cal", ns), "Printing").ToString(SaveOptions.DisableFormatting);
    }

    private const string Declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>";

    /// <summary>
    /// Job types an InternalPrintCap lists. Firmware spells the element <c>JobType</c>, <c>jobType</c> or
    /// <c>InternalPrintJobType</c> (hp-printer-maintenance), so any element whose local name ends in "JobType" counts.
    /// </summary>
    public static IReadOnlyList<string> ParseJobTypes(XDocument cap) =>
        cap.Descendants()
            .Where(e => !e.HasElements && e.Name.LocalName.EndsWith("JobType", StringComparison.OrdinalIgnoreCase))
            .Select(e => e.Value.Trim())
            .Where(v => v.Length > 0)
            .Distinct(StringComparer.Ordinal)
            .ToList();

    /// <summary><c>dd:AlignmentMode</c> from ConsumableConfigDyn (automatic, semiAutomatic, manual); null when absent.</summary>
    public static string? ParseAlignmentMode(XDocument consumableConfigDyn) =>
        consumableConfigDyn.Descendants().FirstOrDefault(e => e.Name.LocalName == "AlignmentMode")?.Value.Trim() is { Length: > 0 } m ? m : null;

    /// <summary>Ink or toner, from the consumables' <c>ConsumableTypeEnum</c>.</summary>
    public static Marking ParseMarking(XDocument consumableConfigDyn) =>
        FromKinds(consumableConfigDyn.Descendants().Where(e => e.Name.LocalName == "ConsumableTypeEnum").Select(e => e.Value));

    /// <summary>Ink or toner from supply kinds (LEDM <c>ConsumableTypeEnum</c>, IPP <c>marker-types</c>); toner wins a mix.</summary>
    public static Marking FromKinds(IEnumerable<string> kinds)
    {
        var list = kinds.Where(k => !k.StartsWith("waste", StringComparison.OrdinalIgnoreCase)).ToList();
        if (list.Any(k => k.Contains("toner", StringComparison.OrdinalIgnoreCase))) return Marking.Toner;
        if (list.Any(k => k.Contains("ink", StringComparison.OrdinalIgnoreCase))) return Marking.Ink;
        return Marking.Unknown;
    }

    /// <summary>
    /// What the calibration state says about starting an alignment. HPLIP base/maint.py refuses on "Printing" (one is under
    /// way) and on "ParmsRequested" (an earlier session still waits for its parameters: restart the printer);
    /// hp-printer-maintenance names "Scanning" for the scanner-based step.
    /// </summary>
    public static CalibrationStatus ReadCalibration(XDocument state)
    {
        var leaves = state.Descendants().Prepend(state.Root!).ToList();
        if (leaves.Any(e => e.Name.LocalName == "ParmsRequested" || (!e.HasElements && e.Value.Trim() == "ParmsRequested")))
            return CalibrationStatus.AwaitingParameters;
        return leaves.Any(e => !e.HasElements && e.Name.LocalName is "CalibrationState" or "State" && e.Value.Trim() is "Printing" or "Scanning")
            ? CalibrationStatus.Running : CalibrationStatus.Idle;
    }
}

/// <summary>What <c>/Calibration/State</c> says about starting an alignment now.</summary>
public enum CalibrationStatus { Idle, Running, AwaitingParameters }
