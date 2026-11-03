using System.Text;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Ledm;

/// <summary>Human text for LEDM status categories and alert IDs. Unknown IDs are de-camel-cased.</summary>
public static class StatusText
{
    // The words are read at the moment of use (the interface's language is chosen at start-up).
    private static readonly Dictionary<string, (Func<string> Text, Severity Sev)> Known = new(StringComparer.Ordinal)
    {
        ["ready"] = (() => CoreStrings.Status_Ready, Severity.Info),
        ["inPowerSave"] = (() => CoreStrings.Status_Ready, Severity.Info),
        ["initializing"] = (() => CoreStrings.Status_StartingUp, Severity.Info),
        ["processing"] = (() => CoreStrings.Status_Printing, Severity.Info),
        ["copying"] = (() => CoreStrings.Status_Copying, Severity.Info),
        ["scanProcessing"] = (() => CoreStrings.Status_Scanning, Severity.Info),
        ["coolDownMode"] = (() => CoreStrings.Status_CoolingDown, Severity.Info),
        ["cancelJob"] = (() => CoreStrings.Status_CancellingJob, Severity.Info),
        ["shuttingDown"] = (() => CoreStrings.Status_ShuttingDown, Severity.Info),
        ["upgrading"] = (() => CoreStrings.Status_UpdatingFirmware, Severity.Info),
        ["connectingToWeb"] = (() => CoreStrings.Status_ConnectingToWeb, Severity.Info),
        ["deviceInteraction"] = (() => CoreStrings.Status_BusyAtPanel, Severity.Info),
        ["trayEmptyOrOpen"] = (() => CoreStrings.Status_TrayEmptyOrOpen, Severity.Error),
        ["mediaPrompt"] = (() => CoreStrings.Status_LoadPaper, Severity.Error),
        ["unexpectedSizeInTray"] = (() => CoreStrings.Status_UnexpectedSizeInTray, Severity.Error),
        ["manualDuplex"] = (() => CoreStrings.Status_ManualDuplex, Severity.Warning),
        ["manuallyFeed"] = (() => CoreStrings.Status_ManualFeed, Severity.Warning),
        ["closeDoorOrCover"] = (() => CoreStrings.Status_CloseDoorOrCover, Severity.Error),
        ["cartridgeLow"] = (() => CoreStrings.Status_TonerLow, Severity.Warning),
        ["cartridgeVeryLow"] = (() => CoreStrings.Status_TonerVeryLow, Severity.Warning),
        ["orderCartridge"] = (() => CoreStrings.Status_OrderTonerSoon, Severity.Warning),
        ["replaceCartridgeOut"] = (() => CoreStrings.Status_ReplaceTonerCartridge, Severity.Error),
        ["cartridgeMissing"] = (() => CoreStrings.Status_TonerCartridgeMissing, Severity.Error),
        ["usedConsumable"] = (() => CoreStrings.Status_UsedCartridge, Severity.Warning),
        ["nonHPSupplyDetected"] = (() => CoreStrings.Status_NonHpCartridge, Severity.Warning),
        ["incompatibleConsumable"] = (() => CoreStrings.Status_IncompatibleCartridge, Severity.Error),
        ["tonerSealInPlace"] = (() => CoreStrings.Status_RemoveTonerSeal, Severity.Error),
        ["jamInPrinter"] = (() => CoreStrings.Status_PaperJam, Severity.Error),
        ["printerMispick"] = (() => CoreStrings.Status_PickUpFailed, Severity.Error),
        ["scannerAdfJam"] = (() => CoreStrings.Status_FeederJam, Severity.Error),
        ["scannerAdfMispick"] = (() => CoreStrings.Status_FeederPickUpFailed, Severity.Error),
        ["scannerAdfDoorOpen"] = (() => CoreStrings.Status_FeederDoorOpen, Severity.Error),
        ["insufficientMemory"] = (() => CoreStrings.Status_OutOfMemory, Severity.Error),
        ["printFailure"] = (() => CoreStrings.Status_PrintFailure, Severity.Error),
        ["printerError"] = (() => CoreStrings.Status_PrinterError, Severity.Error),
        ["upgradeFailed"] = (() => CoreStrings.Status_FirmwareUpdateFailed, Severity.Error),
        ["misprint"] = (() => CoreStrings.Status_Misprint, Severity.Warning),
        ["lightPipeBlocked"] = (() => CoreStrings.Status_SensorBlocked, Severity.Error),
        ["waitingForSupplyAssessment"] = (() => CoreStrings.Status_CheckingSupplies, Severity.Info),
    };

    private static string? Detail(string id) => id switch
    {
        "inPowerSave" => CoreStrings.Status_InPowerSave_Detail,
        "ready" => CoreStrings.Status_Ready_Detail,
        "trayEmptyOrOpen" => CoreStrings.Status_TrayEmptyOrOpen_Detail,
        "mediaPrompt" => CoreStrings.Status_MediaPrompt_Detail,
        "closeDoorOrCover" => CoreStrings.Status_CloseDoorOrCover_Detail,
        "jamInPrinter" => CoreStrings.Status_JamInPrinter_Detail,
        "replaceCartridgeOut" => CoreStrings.Status_ReplaceTonerCartridge_Detail,
        "cartridgeMissing" => CoreStrings.Status_TonerCartridgeMissing_Detail,
        "tonerSealInPlace" => CoreStrings.Status_RemoveTonerSeal_Detail,
        "manualDuplex" => CoreStrings.Status_ManualDuplex_Detail,
        _ => null,
    };

    public static bool IsKnown(string id) => Known.ContainsKey(id);

    /// <summary>One plain sentence on what the state means or what to do; null when the title says it all.</summary>
    public static string? Explain(string id) => Detail(id);

    public static string Describe(string id) => Known.TryGetValue(id, out var k) ? k.Text() : Humanize(id);

    public static Severity SeverityOf(string id) => Known.TryGetValue(id, out var k) ? k.Sev : Severity.Warning;

    public static string Humanize(string camel)
    {
        if (camel.Length == 0) return camel;
        var sb = new StringBuilder(camel.Length + 8);
        sb.Append(char.ToUpperInvariant(camel[0]));
        for (var i = 1; i < camel.Length; i++)
        {
            var c = camel[i];
            if (c is '_' or '-') sb.Append(' ');
            else if (char.IsUpper(c) && !char.IsUpper(camel[i - 1])) sb.Append(' ').Append(char.ToLowerInvariant(c));
            else sb.Append(c);
        }
        return sb.ToString();
    }
}
