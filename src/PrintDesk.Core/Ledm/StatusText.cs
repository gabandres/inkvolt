using System.Text;
using PrintDesk.Core.Model;

namespace PrintDesk.Core.Ledm;

/// <summary>Human text for LEDM status categories and alert IDs. Unknown IDs are de-camel-cased.</summary>
public static class StatusText
{
    private static readonly Dictionary<string, (string Text, Severity Sev)> Known = new(StringComparer.Ordinal)
    {
        ["ready"] = ("Ready", Severity.Info),
        ["inPowerSave"] = ("Ready", Severity.Info),
        ["initializing"] = ("Starting up", Severity.Info),
        ["processing"] = ("Printing", Severity.Info),
        ["copying"] = ("Copying", Severity.Info),
        ["scanProcessing"] = ("Scanning", Severity.Info),
        ["coolDownMode"] = ("Cooling down", Severity.Info),
        ["cancelJob"] = ("Cancelling job", Severity.Info),
        ["shuttingDown"] = ("Shutting down", Severity.Info),
        ["upgrading"] = ("Updating firmware", Severity.Info),
        ["connectingToWeb"] = ("Connecting to web services", Severity.Info),
        ["deviceInteraction"] = ("Busy at the control panel", Severity.Info),
        ["trayEmptyOrOpen"] = ("Tray empty or open", Severity.Error),
        ["mediaPrompt"] = ("Load paper", Severity.Error),
        ["unexpectedSizeInTray"] = ("Unexpected paper size in tray", Severity.Error),
        ["manualDuplex"] = ("Turn the pages over for manual duplex", Severity.Warning),
        ["manuallyFeed"] = ("Waiting for manual feed", Severity.Warning),
        ["closeDoorOrCover"] = ("Close the door or cover", Severity.Error),
        ["cartridgeLow"] = ("Toner low", Severity.Warning),
        ["cartridgeVeryLow"] = ("Toner very low", Severity.Warning),
        ["orderCartridge"] = ("Order toner soon", Severity.Warning),
        ["replaceCartridgeOut"] = ("Replace the toner cartridge", Severity.Error),
        ["cartridgeMissing"] = ("Toner cartridge missing", Severity.Error),
        ["usedConsumable"] = ("Used cartridge installed", Severity.Warning),
        ["nonHPSupplyDetected"] = ("Non-HP cartridge detected", Severity.Warning),
        ["incompatibleConsumable"] = ("Incompatible cartridge", Severity.Error),
        ["tonerSealInPlace"] = ("Remove the toner seal", Severity.Error),
        ["jamInPrinter"] = ("Paper jam", Severity.Error),
        ["printerMispick"] = ("Paper pick-up failed", Severity.Error),
        ["scannerAdfJam"] = ("Document feeder jam", Severity.Error),
        ["scannerAdfMispick"] = ("Document feeder pick-up failed", Severity.Error),
        ["scannerAdfDoorOpen"] = ("Document feeder door open", Severity.Error),
        ["insufficientMemory"] = ("Out of memory", Severity.Error),
        ["printFailure"] = ("Print failure", Severity.Error),
        ["printerError"] = ("Printer error", Severity.Error),
        ["upgradeFailed"] = ("Firmware update failed", Severity.Error),
        ["misprint"] = ("Misprint", Severity.Warning),
        ["lightPipeBlocked"] = ("Sensor blocked", Severity.Error),
        ["waitingForSupplyAssessment"] = ("Checking supplies", Severity.Info),
    };

    private static readonly Dictionary<string, string> Details = new(StringComparer.Ordinal)
    {
        ["inPowerSave"] = "Sleeping to save power. It wakes up by itself when you print or scan.",
        ["ready"] = "Waiting for something to print or scan.",
        ["trayEmptyOrOpen"] = "Load paper into the tray and push it all the way in.",
        ["mediaPrompt"] = "Load paper, then press OK on the printer if it asks.",
        ["closeDoorOrCover"] = "A door or cover is open. Close it to continue.",
        ["jamInPrinter"] = "Open the front door, gently pull out the jammed paper, and close the door.",
        ["replaceCartridgeOut"] = "The toner cartridge is empty. Replace it to keep printing.",
        ["cartridgeMissing"] = "Insert the toner cartridge and close the front door.",
        ["tonerSealInPlace"] = "Pull the orange tab off the new toner cartridge.",
        ["manualDuplex"] = "Take the printed pages, turn them over, and put them back in the tray.",
    };

    public static bool IsKnown(string id) => Known.ContainsKey(id);

    /// <summary>One plain sentence on what the state means or what to do; null when the title says it all.</summary>
    public static string? Explain(string id) => Details.GetValueOrDefault(id);

    public static string Describe(string id) => Known.TryGetValue(id, out var k) ? k.Text : Humanize(id);

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
