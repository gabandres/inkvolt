using System.Runtime.InteropServices;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// Route 2: the driver behind a queue, asked over Windows' bidirectional printing (<c>IBidiSpl2</c>; every Windows the app runs on,
/// as the user: <c>BIDI_ACCESS_USER</c>, no administrator). Only Get requests (<see cref="BidiQueueReading.Requests"/>), read with
/// <see cref="BidiQueueReading.From"/>. Most drivers have no bidi for these and fail the call or answer nothing: null, never an
/// error. A driver can hang here, so calls go through <see cref="TimedCalls{TKey,T}"/>: off the calling thread, cut off in time,
/// and one per printer however many callers ask (the app's page and Fleet). Only the error code is ever logged.
/// </summary>
public sealed class BidiQueueDeviceReader(SpoolerQueue queue) : IQueueDeviceReader
{
    private const uint BidiAccessUser = 2;
    private static readonly Guid BidiSplClsid = new("2A614240-A4C5-4C33-BD87-1BC709331639");
    private static readonly TimedCalls<string, QueueDeviceReading?> Calls = new(TimeSpan.FromSeconds(7));

    public Task<QueueDeviceReading?> ReadAsync(CancellationToken ct) => new TimedQueueDeviceReader(Calls, queue.Name, Read).ReadAsync(ct);

    private QueueDeviceReading? Read()
    {
        object? com = null;
        try
        {
            com = Activator.CreateInstance(Type.GetTypeFromCLSID(BidiSplClsid, throwOnError: true)!);
            var bidi = (IBidiSpl2)com!;
            bidi.BindDevice(queue.Name, BidiAccessUser);
            try
            {
                return BidiQueueReading.From(BidiQueueReading.Requests.Select(request => Ask(bidi, request)).ToList());
            }
            finally
            {
                bidi.UnbindDevice();
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            Trace(ex);
            return null;
        }
        finally
        {
            if (com is not null) Marshal.FinalReleaseComObject(com);
        }
    }

    private static string? Ask(IBidiSpl2 bidi, string request)
    {
        try
        {
            bidi.SendRecvXMLString(request, out var response);
            return response;
        }
        catch (Exception ex) when (ex is COMException or InvalidCastException or ArgumentException)
        {
            Trace(ex);
            return null;
        }
    }

    private static void Trace(Exception ex) => System.Diagnostics.Trace.WriteLine($"queue bidi reading: {ex.GetType().Name} 0x{ex.HResult:X8}");

    [ComImport, Guid("0E8F51B8-8273-4906-8E7B-BE453FFD2E2B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IBidiSpl2
    {
        void BindDevice([MarshalAs(UnmanagedType.LPWStr)] string deviceName, uint access);

        void UnbindDevice();

        void SendRecvXMLString([MarshalAs(UnmanagedType.BStr)] string request, [MarshalAs(UnmanagedType.BStr)] out string? response);

        void SendRecvXMLStream(nint request, out nint response); // not used; keeps the vtable's shape
    }
}
