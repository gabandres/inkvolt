using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

/// <summary>What the printer does about new HP firmware.</summary>
public enum FirmwareUpdateMode
{
    /// <summary>Never checks.</summary>
    Off,

    /// <summary>Checks and reports an available update; nothing installs until someone installs it.</summary>
    Notify,

    /// <summary>Checks and installs updates by itself.</summary>
    Automatic,
}

/// <summary>
/// HP LEDM web firmware update (<c>FirmwareUpdate</c> interface, found through its manifest): the automatic check and
/// automatic update switches, read from <c>FirmwareUpdateDyn</c> and offered only as far as <c>FirmwareUpdateCap</c>
/// marks them writable. <see cref="ConfigPath"/> is where a change is PUT (<c>/FirmwareUpdate/WebFWUpdate/Config</c>).
/// </summary>
public sealed record FirmwareUpdateSettings(
    FirmwareUpdateMode Mode,
    IReadOnlyList<FirmwareUpdateMode> Choices,
    string? Status,
    string? ConfigPath,
    XNamespace Namespace,
    bool HasCheck)
{
    public const string WebClass = "WebFWUpdate";

    public bool CanChange => Choices.Count > 1 && ConfigPath is not null;

    /// <summary>Null when the printer has no web firmware update settings.</summary>
    public static FirmwareUpdateSettings? Parse(XDocument dyn, XDocument? cap, string? configPath)
    {
        if (Pick(dyn) is not { } fw || fw.Kid("Config") is not { } config) return null;
        var check = config.KidValue("AutomaticCheck");
        var update = config.KidValue("AutomaticUpdate");
        if (check is null && update is null) return null;
        var mode = update == "enabled" ? FirmwareUpdateMode.Automatic
            : check == "enabled" ? FirmwareUpdateMode.Notify
            : FirmwareUpdateMode.Off;

        // Choices: the switches the Cap lets us flip both ways. Updating needs checking, so Notify needs both.
        var capConfig = cap is null ? null : Pick(cap)?.Kid("ConfigSupport");
        var updateWritable = update is not null && Writable(capConfig?.Kid("AutomaticUpdateSupport"));
        var checkWritable = check is not null && Writable(capConfig?.Kid("AutomaticCheckSupport"));
        var choices = new List<FirmwareUpdateMode>();
        if (updateWritable)
        {
            choices.Add(FirmwareUpdateMode.Automatic);
            if (checkWritable) choices.Add(FirmwareUpdateMode.Notify);
            choices.Add(FirmwareUpdateMode.Off);
        }
        return new FirmwareUpdateSettings(mode, choices, fw.Kid("State")?.KidValue("Status"), configPath, config.Name.Namespace, check is not null);
    }

    /// <summary>The complete <c>FirmwareUpdateConfig</c> document for <paramref name="mode"/>, in the printer's own namespace.</summary>
    public XDocument BuildPut(FirmwareUpdateMode mode)
    {
        var (check, update) = mode switch
        {
            FirmwareUpdateMode.Automatic => ("enabled", "enabled"),
            FirmwareUpdateMode.Notify => ("enabled", "disabled"),
            _ => ("disabled", "disabled"),
        };
        var root = new XElement(Namespace + "FirmwareUpdateConfig", new XAttribute(XNamespace.Xmlns + "fwudyn", Namespace));
        if (HasCheck) root.Add(new XElement(Namespace + "AutomaticCheck", check));
        root.Add(new XElement(Namespace + "AutomaticUpdate", update));
        return new XDocument(new XDeclaration("1.0", "UTF-8", null), root);
    }

    /// <summary>The update state in words, or null when there is nothing to say (idle).</summary>
    public string? StatusMessage => Status switch
    {
        null or "idle" => null,
        "available" => "A firmware update is available.",
        "notAvailable" => "The firmware is up to date.",
        "checkFailed" => "The printer's last update check failed.",
        "checking" => "Checking for updates…",
        "downloadPreparation" or "downloading" => "Downloading an update…",
        "installing" => "Installing an update…",
        "cancelling" => "Cancelling the update…",
        _ => StatusText.Humanize(Status),
    };

    /// <summary>The web-update entry (a printer may list several update classes), else the first.</summary>
    private static XElement? Pick(XDocument doc)
    {
        var root = doc.Root!;
        var all = root.All("FirmwareUpdate").Where(e => e.Kid("Class") is not null).ToList();
        return all.FirstOrDefault(e => e.KidValue("Class") == WebClass) ?? all.FirstOrDefault()
            ?? (root.Kid("Config") is not null ? root : null); // the bare /WebFWUpdate resource
    }

    private static bool Writable(XElement? support) =>
        support is not null
        && (string?)support.Attribute("access") is "readWrite" or null
        && support.Elements().Select(e => e.Value.Trim()).ToHashSet() is var values
        && values.Contains("enabled") && values.Contains("disabled");
}
