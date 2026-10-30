using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Suite;

/// <summary>How Inkvolt PDF's Scan dialog reaches a scanner: eSCL over the network, or a driver on this PC (WIA, TWAIN).</summary>
public enum ScannerKind { Network, Wia, Twain }

/// <summary>
/// The Scan dialog's list of scanners, network (eSCL) and driver ones side by side: their keys (remembered as the last scanner),
/// labels, which WIA scanners to leave out because they are a network scanner already listed, and the sentences about what
/// couldn't be listed.
/// </summary>
public static class ScannerList
{
    /// <summary>The key remembered for a driver scanner: "wia:" or "twain:" and the driver's id.</summary>
    public static string Key(ScannerKind kind, string id) => kind switch
    {
        ScannerKind.Wia => "wia:" + id,
        ScannerKind.Twain => "twain:" + id,
        _ => id,
    };

    /// <summary>"Name  (host)", "Name  (USB · Windows driver)", "Name  (TWAIN driver)".</summary>
    public static string Label(ScannerKind kind, string name, string? host = null, bool remembered = true, string? connection = null) => kind switch
    {
        ScannerKind.Wia => $"{name}  ({(connection is null ? "" : connection + " · ")}Windows driver)",
        ScannerKind.Twain => $"{name}  (TWAIN driver)",
        _ => $"{name}  ({host}){(remembered ? "" : " · found on the network")}",
    };

    /// <summary>
    /// A WIA scanner that is Windows' own eSCL driver for a network scanner already in the list (the eSCL scanner's UUID in the
    /// driver's port, else <see cref="WiaMatch"/> by address or name): left out, the dialog scans it over eSCL itself.
    /// </summary>
    /// <param name="network">The listed network scanners: id (UUID), name and host.</param>
    public static bool IsListedOnTheNetwork(WiaDeviceInfo device, IReadOnlyList<ScanTarget> network)
    {
        if (!device.IsEscl || network.Count == 0) return false;
        var port = device.Port ?? "";
        if (network.Any(t => Uuid(t.Id) is { Length: > 0 } u && port.Contains(u, StringComparison.OrdinalIgnoreCase))) return true;
        return WiaMatch.Match(device, network) is not null;
    }

    private static string? Uuid(string id) => Guid.TryParse(id.Trim('{', '}'), out var g) ? g.ToString("D") : null;

    /// <summary>What the dialog says when nothing was found, given whether Windows' scanner list could be read.</summary>
    public static string NoneFound(bool driversRead) => driversRead
        ? "No scanner found. Turn the scanner on and connect it to this PC (USB) or to this network; Inkvolt Print can add a network one by its address."
        : "No scanner found on the network, and Windows' list of scanners didn't answer. Turn the scanner on and connect it, then open Scan again.";

    /// <summary>
    /// The line about TWAIN under the scanner list: null when TWAIN scanners were listed (or none are installed while the manager is),
    /// plain words when this PC has no 64-bit TWAIN manager or it failed.
    /// </summary>
    /// <param name="managerInstalled">TWAINDSM.dll is in Windows' system folder.</param>
    /// <param name="error">Listing failed with this, when it did.</param>
    public static string? TwainNote(bool managerInstalled, string? error) =>
        !managerInstalled
            ? "Scanners with only a TWAIN driver aren't listed: this PC has no 64-bit TWAIN manager (TWAINDSM.dll). Most scanners also " +
              "have a Windows driver and are listed; for one that doesn't, install its maker's 64-bit TWAIN driver, which brings the manager."
            : error is not null
                ? $"TWAIN scanners couldn't be listed: {error}"
                : null;
}
