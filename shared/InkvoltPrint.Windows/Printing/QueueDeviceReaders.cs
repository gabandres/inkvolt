using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Windows.Printing;

/// <summary>The ways a real queue printer is asked for more than the spooler says, in order: the printer over IPP through Windows (IPP over USB included).</summary>
public static class QueueDeviceReaders
{
    public static IReadOnlyList<IQueueDeviceReader> For(SpoolerQueue queue) =>
        QueueKinds.IsVirtual(queue) ? [] : [new IppQueueDeviceReader(queue)];
}
