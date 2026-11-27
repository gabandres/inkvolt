using System.ComponentModel;
using System.Runtime.InteropServices;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// Whether Windows can use a print queue's driver: the PrintTicket provider every print through the queue starts with (WPF's
/// <c>PrintQueue.DefaultPrintTicket</c>, the Windows print dialog) opens for it. A Windows update can leave a driver it can't
/// load (seen on Windows 11 on Arm with the Microsoft IPP Class Driver: "PrintTicket provider failed to bind to printer. Win32
/// error: The system cannot find the file specified"); every app then fails to print to that queue until it is added again.
/// </summary>
public static class QueueDriver
{
    private const int InvalidPrinterName = unchecked((int)0x80070709); // HRESULT_FROM_WIN32(ERROR_INVALID_PRINTER_NAME)

    /// <summary>
    /// Null when the queue's driver opens (or the queue isn't there: printing reports that itself), else Windows' words for why it
    /// doesn't. Any thread; takes a few milliseconds to a second (the driver is loaded).
    /// </summary>
    public static string? Problem(string queueName)
    {
        int hr;
        try
        {
            hr = PTOpenProviderEx(queueName, 1, 1, out var provider, out _);
            if (hr >= 0)
            {
                PTCloseProvider(provider);
                return null;
            }
        }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException)
        {
            return null; // no PrintTicket API on this Windows: nothing to say
        }
        return hr == InvalidPrinterName ? null : Describe(hr);
    }

    /// <summary>True when <paramref name="ex"/> is WPF's failure to open a queue's PrintTicket provider (the driver can't be used).</summary>
    public static bool IsProviderFailure(Exception ex)
    {
        for (var e = ex; e is not null; e = e.InnerException)
            if (e.GetType().FullName == "System.Printing.PrintQueueException" && e.StackTrace?.Contains("PTProvider", StringComparison.Ordinal) == true)
                return true;
        return false;
    }

    private static string Describe(int hr) =>
        (hr & 0xFFFF0000) == 0x80070000 ? new Win32Exception(hr & 0xFFFF).Message : Marshal.GetExceptionForHR(hr)?.Message ?? $"0x{hr:X8}";

    [DllImport("prntvpt.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int PTOpenProviderEx(string printerName, int maxVersion, int prefVersion, out IntPtr provider, out int usedVersion);

    [DllImport("prntvpt.dll", ExactSpelling = true)]
    private static extern int PTCloseProvider(IntPtr provider);
}
