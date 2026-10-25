using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

public enum SettingKind { Choice, Text, Integer }

/// <summary>
/// A curated, writable LEDM setting. <see cref="Path"/> is the element path (local names) below the Dyn
/// root; <see cref="KeySiblings"/> are elements copied next to the leaf so the device knows which
/// instance is meant (e.g. the tray's <c>InputBin</c>). Allowed values come from the matching Cap resource.
/// </summary>
public sealed record LedmSettingDef(
    string Key,
    string Label,
    string Group,
    string DynResource,
    string CapResource,
    string[] Path,
    string CapElement,
    SettingKind Kind,
    string[]? KeySiblings = null);

public sealed record LedmSetting(LedmSettingDef Def, string Value, IReadOnlyList<string> Choices, int? MaxLength, int? Min, int? Max)
{
    public string Display(string value) => Def.Kind == SettingKind.Choice ? SettingText.Display(Def.Key, value) : value;
}

public static class LedmSettingCatalog
{
    private const string Pc = LedmResource.ProductConfigDyn, PcCap = LedmResource.ProductConfigCap;
    private const string Pr = LedmResource.PrintConfigDyn, PrCap = LedmResource.PrintConfigCap;
    private const string Mh = LedmResource.MediaHandlingDyn, MhCap = LedmResource.MediaHandlingCap;

    public static readonly IReadOnlyList<LedmSettingDef> All =
    [
        new("FriendlyName", "Printer name", "General", Pc, PcCap, ["ProductSettings", "FriendlyName"], "FriendlyName", SettingKind.Text),
        new("DeviceLocation", "Location", "General", Pc, PcCap, ["ProductSettings", "DeviceInformation", "DeviceLocation"], "DeviceLocation", SettingKind.Text),
        new("PowerSaveTimeout", "Sleep after", "Power", Pc, PcCap, ["ProductSettings", "PowerSaveTimeout"], "PowerSaveTimerSupport", SettingKind.Choice),
        new("ShutDownDelay", "Turn off after", "Power", Pc, PcCap, ["ProductSettings", "ShutDownDelay"], "ShutDownDelaySupport", SettingKind.Choice),
        new("ShutDownDelayApply", "Delay turn-off while ports are active", "Power", Pc, PcCap, ["ProductSettings", "ShutDownDelayApply"], "ShutDownDelayApplySupport", SettingKind.Choice),
        new("Duplex", "Print on both sides by default", "Printing", Pc, PcCap, ["ProductSettings", "Duplex"], "DuplexSupport", SettingKind.Choice),
        new("DuplexBindingOption", "Two-sided binding", "Printing", Pc, PcCap, ["ProductSettings", "DuplexBindingOption"], "DuplexBindingOptionSupport", SettingKind.Choice),
        new("ManualFeed", "Manual feed", "Printing", Pc, PcCap, ["ProductSettings", "ManualFeed"], "ManualFeedSupport", SettingKind.Choice),
        new("DefaultPrintCopies", "Default copies", "Printing", Pr, PrCap, ["DefaultPrintCopies"], "DefaultPrintCopies", SettingKind.Integer),
        new("AutoContinue", "Continue automatically after errors", "Printing", Pr, PrCap, ["AutoContinue"], "PrintOptionAutoContinueSupport", SettingKind.Choice),
        new("MediaSizeName", "Tray paper size", "Paper", Mh, MhCap, ["InputTray", "MediaSizeName"], "MediaSizeNameSupport", SettingKind.Choice, ["InputBin"]),
        new("MediaType", "Tray paper type", "Paper", Mh, MhCap, ["InputTray", "MediaType"], "MediaTypeSupport", SettingKind.Choice, ["InputBin"]),
        new("MediaOutActionType", "When paper runs out", "Paper", Mh, MhCap, ["MediaHandlingInfo", "MediaOutActionType"], "MediaOutActionTypeSupport", SettingKind.Choice),
    ];

    /// <summary>Settings present in <paramref name="dyn"/> and marked readWrite in <paramref name="cap"/>.</summary>
    public static IEnumerable<LedmSetting> Read(IEnumerable<LedmSettingDef> defs, XDocument dyn, XDocument? cap)
    {
        foreach (var def in defs)
        {
            if (Find(dyn.Root!, def.Path) is not { } leaf) continue;
            var capEl = cap?.Root?.All(def.CapElement).FirstOrDefault();
            if (capEl is null || (string?)capEl.Attribute("access") is not ("readWrite" or null)) continue;

            var choices = def.Kind == SettingKind.Choice
                ? capEl.Elements().Select(e => e.Value.Trim()).Where(v => v.Length > 0).Distinct().ToList()
                : [];
            if (def.Kind == SettingKind.Choice && choices.Count == 0) continue;
            yield return new LedmSetting(def, leaf.Value.Trim(), choices,
                ((string?)capEl.Attribute("length")).ToInt(),
                ((string?)capEl.Attribute("min")).ToInt(),
                ((string?)capEl.Attribute("max")).ToInt());
        }
    }

    /// <summary>
    /// Builds a minimal PUT body containing only the changed leaves (plus key siblings), reusing the exact
    /// element names and namespaces from the device's current document so firmware schema drift is harmless.
    /// </summary>
    public static XDocument BuildPut(XDocument dyn, IEnumerable<(LedmSettingDef Def, string Value)> changes)
    {
        var src = dyn.Root!;
        var root = new XElement(src.Name, src.Attributes().Where(a => a.IsNamespaceDeclaration));
        foreach (var (def, value) in changes)
        {
            var srcNode = src;
            var dstNode = root;
            for (var i = 0; i < def.Path.Length; i++)
            {
                srcNode = srcNode.Kid(def.Path[i]) ?? throw new InvalidOperationException($"{def.Key} is not present on this printer");
                var dstChild = dstNode.Elements(srcNode.Name).FirstOrDefault();
                if (dstChild is null)
                {
                    dstChild = new XElement(srcNode.Name);
                    dstNode.Add(dstChild);
                    if (i == def.Path.Length - 2)
                        foreach (var key in def.KeySiblings ?? [])
                            if (srcNode.Kid(key) is { } k) dstChild.Add(new XElement(k));
                }
                dstNode = dstChild;
            }
            dstNode.Value = value;
        }
        return new XDocument(new XDeclaration("1.0", "UTF-8", null), root);
    }

    private static XElement? Find(XElement root, string[] path)
    {
        XElement? node = root;
        foreach (var name in path)
        {
            node = node.Kid(name);
            if (node is null) return null;
        }
        return node;
    }
}

public static class SettingText
{
    public static string Display(string key, string value) => (key, value) switch
    {
        (_, "enabled" or "on" or "true") => "On",
        (_, "disabled" or "off" or "false") => "Off",
        (_, "never") => "Never",
        (_, "longEdge") => "Long edge",
        (_, "shortEdge") => "Short edge",
        (_, "any") => "Any size",
        (_, "auto") => "Automatic",
        ("MediaSizeName", _) => MediaSize(value),
        _ => Duration(value) ?? StatusText.Humanize(value),
    };

    // "1minute", "15_minutes", "2hours" → "1 minute", "15 minutes", "2 hours"
    private static string? Duration(string v)
    {
        var t = v.Replace('_', ' ');
        var i = 0;
        while (i < t.Length && char.IsDigit(t[i])) i++;
        if (i == 0 || i == t.Length) return null;
        var unit = t[i..].Trim();
        return unit is "minute" or "minutes" or "hour" or "hours" or "second" or "seconds" ? $"{t[..i]} {unit}" : null;
    }

    // PWG self-describing names: "na_letter_8.5x11in" → "Letter (8.5x11in)"
    private static string MediaSize(string v)
    {
        var parts = v.Split('_');
        if (parts.Length < 3) return StatusText.Humanize(v);
        var name = string.Join(' ', parts[1..^1]).Replace('-', ' ');
        name = name.Length <= 3 && !name.Contains('x') ? name.ToUpperInvariant() : char.ToUpperInvariant(name[0]) + name[1..];
        return $"{name} ({parts[^1]})";
    }
}
