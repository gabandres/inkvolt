using System.Buffers.Binary;
using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Route 1: a queue on Windows' IPP class driver (an IPP-over-USB printer, or an IPP or WSD network one Windows set up itself)
/// asked for its printer attributes through Windows (<c>IppPrintDevice.GetPrinterAttributesAsBuffer</c>, Windows 11), read
/// with the same IPP mapping as a network printer's. Windows hands back the printer-attributes group of the printer's reply,
/// with or without its group tag; it's framed as a whole Get-Printer-Attributes response for <see cref="IppCodec.Decode"/>.
/// </summary>
public static class IppQueueReading
{
    /// <summary>The attributes asked for: the status and supplies a network printer is read for, without identifiers.</summary>
    public static readonly string[] Attributes =
    [
        "printer-state", "printer-state-reasons", "printer-state-message", "marker-names", "marker-levels", "marker-low-levels",
        "marker-high-levels", "marker-types", "marker-colors", "printer-alert", "printer-alert-description",
    ];

    /// <summary>Largest attribute group read (a real one is a few kilobytes).</summary>
    public const int MaxBytes = 256 * 1024;

    /// <summary>The reading from Windows' bytes; null when there are none, too many, or they can't be read.</summary>
    public static QueueDeviceReading? From(ReadOnlySpan<byte> group, bool usb)
    {
        if (group.IsEmpty || group.Length > MaxBytes) return null;
        var framed = new byte[8 + 1 + group.Length + 1];
        framed[0] = 1; framed[1] = 1; // version 1.1, status 0 (successful-ok), request id 1
        BinaryPrimitives.WriteInt32BigEndian(framed.AsSpan(4), 1);
        var at = 8;
        if (group[0] >= 0x10) framed[at++] = 0x04; // attributes without their group tag: printer-attributes
        group.CopyTo(framed.AsSpan(at));
        at += group.Length;
        framed[at++] = 0x03;
        IppResponse response;
        try
        {
            response = IppCodec.Decode(framed.AsSpan(0, at));
        }
        catch (FormatException)
        {
            return null;
        }
        if (!response.Attributes.ContainsKey("printer-state") && !response.Attributes.ContainsKey("marker-names")) return null;
        var status = IppClient.ToStatus(response);
        return new QueueDeviceReading(usb ? QueueReadingFrom.PrinterOverUsb : QueueReadingFrom.PrinterThroughWindows,
            status, [], IppClient.ToConsumables(response));
    }
}
