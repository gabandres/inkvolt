using InkvoltPrint.Core.Discovery;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Printing.Direct;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Printing;

/// <summary>Where <c>inkvoltprint print --printer</c> sends: a Windows queue, or straight to a printer over IPP (roadmap 2.1).</summary>
public abstract record BatchPrinterChoice
{
    public sealed record Queue(string Name) : BatchPrinterChoice;

    /// <param name="Endpoint">The printer's IPP endpoint (http or https, as <see cref="Ipp.IppClient"/> takes it).</param>
    /// <param name="Printer">The remembered printer it is (its certificate pins), or null for an address given on the command line.</param>
    public sealed record Direct(Uri Endpoint, string Name, InkvoltPrinter? Printer) : BatchPrinterChoice;
}

/// <summary>
/// What <c>--printer</c> names, decided as the window decides (<see cref="PrintRoutes"/>): an <c>ipp://</c> or <c>ipps://</c> address is
/// that printer, straight; a Windows queue's name is that queue; a printer Inkvolt Print remembers is its queue, or straight to it
/// (its last IPP address) when it has no queue or the person chose that for it. Whether the printer takes a format sent without a
/// driver is known only once it's asked (<see cref="DirectBatchQueue.ReadAsync"/>). Never a virtual printer (it would ask where to save).
/// </summary>
public static class BatchPrinterLookup
{
    /// <exception cref="BatchCommandException">There's no such printer, it's ambiguous, virtual, or nothing to print through.</exception>
    public static BatchPrinterChoice Find(string name, IReadOnlyList<SpoolerQueue> queues, InkvoltPrinters known)
    {
        var shown = BatchPrintText.Clean(name);
        if (name.Contains("://", StringComparison.Ordinal))
        {
            if (!name.StartsWith("ipp://", StringComparison.OrdinalIgnoreCase) && !name.StartsWith("ipps://", StringComparison.OrdinalIgnoreCase)
                || !Uri.TryCreate(name, UriKind.Absolute, out var typed) || typed.UserInfo.Length > 0 || typed.Query.Length > 0 || typed.Fragment.Length > 0
                || PrinterAddress.Parse(name) is not { Ipp: { } endpoint, Host: { } host })
                throw new BatchCommandException($"\"{shown}\" isn't a printer's address: give one as ipp://host/ipp/print or ipps://host/ipp/print.");
            return new BatchPrinterChoice.Direct(endpoint, host, known.Printers.FirstOrDefault(p => Same(p.IppUri, endpoint)));
        }

        SpoolerQueue? Named(string wanted) => queues.FirstOrDefault(q => string.Equals(q.Name, wanted, StringComparison.OrdinalIgnoreCase));
        var queue = Named(name);
        if (queue is null)
        {
            // A printer's name in Inkvolt Print: the queue set up for it, or the one that stands for it, when there is just one; or straight to it.
            var matches = known.Printers.Where(p => string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase)).ToList();
            if (matches.Count > 1) throw new BatchCommandException($"More than one printer is called \"{shown}\": use its queue's name.");
            if (matches.Count == 1)
            {
                var printer = matches[0];
                var byName = known.QueueNames.TryGetValue(printer.Uuid, out var stored) ? Named(stored) : null;
                var candidates = byName is not null ? [byName]
                    : queues.Where(q => !QueueKinds.IsVirtual(q) && QueueKinds.Unclaimed([q], new InkvoltPrinters([printer], known.QueueNames)).Count == 0).ToList();
                var chose = known.PrintDirect.Contains(printer.Uuid, StringComparer.OrdinalIgnoreCase);
                switch (PrintRoutes.Choose(candidates.Count > 0, printer.IppUri is not null, chose))
                {
                    case PrintRoute.Direct:
                        return new BatchPrinterChoice.Direct(printer.IppUri!, printer.Name, printer);
                    case PrintRoute.Queue when candidates.Count > 1:
                        throw new BatchCommandException($"\"{shown}\" has several Windows queues: use one's name ({string.Join(", ", candidates.Select(q => BatchPrintText.Clean(q.Name)))}).");
                    case PrintRoute.Queue:
                        queue = candidates[0];
                        break;
                    default:
                        throw new BatchCommandException($"\"{shown}\" isn't set up in Windows and Inkvolt Print hasn't reached it over IPP: press Set up on its page in Inkvolt Print, or use a queue's name.");
                }
            }
        }
        if (queue is null)
        {
            var names = queues.Where(q => !QueueKinds.IsVirtual(q)).Select(q => BatchPrintText.Clean(q.Name)).ToList();
            throw new BatchCommandException($"There is no printer \"{shown}\".{(names.Count > 0 ? $" Windows has: {string.Join(", ", names)}." : "")}");
        }
        // Print to PDF and the like would open a Save window nobody is there to answer, and no paper would come out.
        if (QueueKinds.IsVirtual(queue)) throw new BatchCommandException($"\"{BatchPrintText.Clean(queue.Name)}\" isn't a printer but a virtual one (it would ask where to save): choose a real one.");
        return new BatchPrinterChoice.Queue(queue.Name);
    }

    private static bool Same(Uri? a, Uri b) =>
        a is not null && string.Equals(a.Host, b.Host, StringComparison.OrdinalIgnoreCase) && a.Port == b.Port
        && string.Equals(a.AbsolutePath, b.AbsolutePath, StringComparison.Ordinal) && a.Scheme == b.Scheme;
}

/// <summary>
/// A remembered printer's certificate pins as Inkvolt Print keeps them, for the command line, which writes nothing: a pin that's
/// there must match; a printer with none is taken as it answers this once (nothing secret goes to it, only the pages).
/// </summary>
public sealed class ReadOnlyPins(InkvoltPrinters known, string uuid) : ICertificatePin
{
    public string? Get(int port) => known.CertificatePins.TryGetValue(CertificatePinKey.For(uuid, port), out var pin) ? pin : null;

    public string SetIfAbsent(int port, string sha256Hex) => Get(port) ?? sha256Hex;
}
