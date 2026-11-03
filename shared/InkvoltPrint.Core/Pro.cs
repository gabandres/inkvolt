using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core;

/// <summary>The features Inkvolt Pro unlocks in Inkvolt Print (print/ROADMAP.md, "Free and Pro"); the supply history export is the first built.</summary>
public enum ProFeature
{
    /// <summary>1.1: one CSV of the supply history across all printers (the chart and days left stay free).</summary>
    SupplyHistoryExport,

    /// <summary>2.4: saved batch-print lists, a dropped folder printed as it fills, the command line, the results as CSV.</summary>
    BatchPrintAutomation,

    /// <summary>2.6: the fleet page's CSV and JSON, <c>inkvoltprint status --all</c>, Fix all.</summary>
    FleetExport,

    /// <summary>3.1: a scanner shared on the network over eSCL.</summary>
    ScannerSharing,

    /// <summary>3.2: SNMPv3 (a community per printer stays free).</summary>
    SnmpV3,
}

/// <summary>
/// The Pro entitlement check for Inkvolt Print: the one place a Pro feature asks whether it may run (<see cref="Allows"/>),
/// nowhere else. Behind it is the suite's <see cref="ProCheck"/> for the "print" product: the key format, its verification,
/// the gate (<see cref="ProCheck.Enforced"/>, off while the apps launch) and the store are shared with Inkvolt PDF, so one
/// key listing both products licenses both apps, from wherever it was entered. Removing it never takes away a result
/// already made.
/// </summary>
public static class Pro
{
    /// <summary>The one switch, shared with Inkvolt PDF (<see cref="ProCheck.Enforced"/> says when it flips). Tests and the dev aids set it either way.</summary>
    public static bool Enforced
    {
        get => ProCheck.Enforced;
        internal set => ProCheck.Enforced = value;
    }

    public const string Product = ProKeys.ProductPrint;
    public const string PriceText = ProCheck.PriceText;
    public const string BuyUrl = ProCheck.BuyUrl;

    private static readonly ProCheck Check = new(Product);

    /// <summary>Where the key is kept. Setting it forgets what was read from the previous store.</summary>
    public static IProStore Store
    {
        get => Check.Store;
        set => Check.Store = value;
    }

    /// <summary>The installed licence, or null (none, or the stored key doesn't count: <see cref="Problem"/>).</summary>
    public static ProLicence? Licence => Check.Licence;

    /// <summary>Why the stored key doesn't count, when there is one and it doesn't; null otherwise.</summary>
    public static string? Problem => Check.Problem;

    /// <summary>True when <paramref name="feature"/> may run: always while <see cref="Enforced"/> is off, else with a licence.</summary>
    public static bool Allows(ProFeature feature) => Check.Allowed;

    /// <summary>Checks <paramref name="key"/>, keeps it in the <see cref="Store"/> and returns its licence; refuses with a reason.</summary>
    public static ProLicence Install(string key) => Check.Install(key);

    /// <summary>Forgets the key. What the Pro features made stays.</summary>
    public static void Remove() => Check.Remove();

    /// <summary>The feature's name as the window shows it.</summary>
    public static string Title(ProFeature feature) => feature switch
    {
        ProFeature.SupplyHistoryExport => CoreStrings.Pro_SupplyHistoryExport,
        ProFeature.BatchPrintAutomation => CoreStrings.Pro_BatchPrintAutomation,
        ProFeature.FleetExport => CoreStrings.Pro_FleetExport,
        ProFeature.ScannerSharing => CoreStrings.Pro_ScannerSharing,
        _ => "SNMPv3",
    };

    /// <summary>What the feature does, for a person who hasn't unlocked it.</summary>
    public static string Describe(ProFeature feature) => feature switch
    {
        ProFeature.SupplyHistoryExport => CoreStrings.Pro_SupplyHistoryExport_Describe,
        ProFeature.BatchPrintAutomation => CoreStrings.Pro_BatchPrintAutomation_Describe,
        ProFeature.FleetExport => CoreStrings.Pro_FleetExport_Describe,
        ProFeature.ScannerSharing => CoreStrings.Pro_ScannerSharing_Describe,
        _ => CoreStrings.Pro_Snmpv3_Describe,
    };

    /// <summary>What a person is told when a feature isn't unlocked.</summary>
    public static string Locked(ProFeature feature) => feature switch
    {
        ProFeature.SupplyHistoryExport => CoreStrings.Pro_SupplyHistoryExport_Locked,
        ProFeature.BatchPrintAutomation => CoreStrings.Pro_BatchPrintAutomation_Locked,
        ProFeature.FleetExport => CoreStrings.Pro_FleetExport_Locked,
        ProFeature.ScannerSharing => CoreStrings.Pro_ScannerSharing_Locked,
        _ => CoreStrings.Pro_Snmpv3_Locked,
    };

    /// <summary>Where to get a key and where to enter it (after <see cref="Locked"/> on the command line).</summary>
    public static string HowToGet => $"Inkvolt Pro is a one-time purchase ({PriceText}) at {BuyUrl}; Help › Inkvolt Pro… in Inkvolt Print enters the key, and a key entered in Inkvolt PDF counts here too.";
}
