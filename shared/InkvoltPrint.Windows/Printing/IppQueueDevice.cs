using System.Runtime.InteropServices.WindowsRuntime;
using InkvoltPrint.Core.Queues;
using Windows.Devices.Printers;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// Route 1: the printer behind a queue on Windows' IPP class driver, asked for its printer attributes through Windows'
/// <c>IppPrintDevice</c> (Windows 11; no administrator, no capability, read-only Get-Printer-Attributes). That's how an
/// IPP-over-USB printer (USB printer class, protocol 4) is reached: Windows sets it up on the IPP class driver and carries
/// the request over USB itself; the app never touches the USB device. On a network IPP or WSD queue it's the same call over
/// the network. Windows takes about 45 s to give up on a WSD printer that's off, so calls go through <see cref="TimedCalls{TKey,T}"/>:
/// off the calling thread, cut off in time, one per printer however many ask. Null for a queue that isn't an IPP one, before Windows
/// 11, or on any failure.
/// </summary>
public sealed class IppQueueDeviceReader(SpoolerQueue queue) : IQueueDeviceReader
{
    private static readonly TimedCalls<string, QueueDeviceReading?> Calls = new(TimeSpan.FromSeconds(7));

    public Task<QueueDeviceReading?> ReadAsync(CancellationToken ct) =>
        !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000) ? Task.FromResult<QueueDeviceReading?>(null) : new TimedQueueDeviceReader(Calls, queue.Name, Read).ReadAsync(ct);

    [System.Runtime.Versioning.SupportedOSPlatform("windows10.0.22000.0")]
    private QueueDeviceReading? Read()
    {
        try
        {
            if (!IppPrintDevice.IsIppPrinter(queue.Name) || IppPrintDevice.FromPrinterName(queue.Name) is not { } device) return null;
            var buffer = device.GetPrinterAttributesAsBuffer(IppQueueReading.Attributes);
            if (buffer is null || buffer.Length == 0 || buffer.Length > IppQueueReading.MaxBytes) return null;
            return IppQueueReading.From(buffer.ToArray(), QueueKinds.Connection(queue) == QueueConnection.Usb);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            System.Diagnostics.Trace.WriteLine($"queue IPP reading: {ex.GetType().Name} 0x{ex.HResult:X8}");
            return null;
        }
    }
}
