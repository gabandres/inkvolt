using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Windows.Printing;

/// <summary>The ways a real queue printer is asked for more than the spooler says, in order: the printer over IPP through Windows (IPP over USB included), then its driver over bidi.</summary>
public static class QueueDeviceReaders
{
    public static IReadOnlyList<IQueueDeviceReader> For(SpoolerQueue queue) =>
        QueueKinds.IsVirtual(queue) ? []
        : BidiQueueReading.WorthAsking(queue) ? [new IppQueueDeviceReader(queue), new BidiQueueDeviceReader(queue)]
        : [new IppQueueDeviceReader(queue)];
}
