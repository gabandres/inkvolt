using System.Net;
using InkvoltPrint.Core.Maintenance;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Core.Ledm;

/// <summary>The outcome of asking the printer to copy: null <see cref="Problem"/> when it took the request.</summary>
public sealed record PrinterCopyResult(string? Problem)
{
    public bool Ok => Problem is null;
}

/// <summary>
/// The printer's own copier over LEDM (<see cref="LedmCopy"/>): found by reading only, and started by one PUT of the start
/// setting alone, sent exactly once (never retried: a copy sent twice uses paper twice) over HTTPS, so an admin password
/// never crosses in clear text. The printer copies with the settings on its control panel; nothing else on it is changed.
/// No Windows queue is involved.
/// </summary>
public sealed class PrinterCopier
{
    private readonly LedmClient _ledm;

    private PrinterCopier(LedmClient ledm, CopyStart start)
    {
        _ledm = ledm;
        Start = start;
    }

    /// <summary>Where the printer's start setting is and the command written to it.</summary>
    public CopyStart Start { get; }

    /// <summary>
    /// The copier when the printer's tree lists the copy documents and they offer a start (GETs only); null otherwise, also
    /// when a document can't be read.
    /// </summary>
    public static async Task<PrinterCopier?> DetectAsync(PrinterConnection connection, CancellationToken ct = default)
    {
        if (connection.Ledm is not { } ledm) return null;
        try
        {
            if (await ledm.GetTreeAsync(ct).ConfigureAwait(false) is not { } tree || !LedmCopy.Listed(tree)) return null;
            var cap = await ledm.GetAsync(LedmCopy.CapResource, ct).ConfigureAwait(false);
            var dyn = await ledm.GetAsync(LedmCopy.DynResource, ct).ConfigureAwait(false);
            return dyn is not null && LedmCopy.Read(dyn, cap) is { } start ? new PrinterCopier(ledm, start) : null;
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return null;
        }
    }

    /// <summary>
    /// Reads the copy settings again, then sends the one PUT that starts the copy. Throws
    /// <see cref="LedmAuthRequiredException"/> on 401/403 so the caller can ask for the admin password.
    /// </summary>
    public async Task<PrinterCopyResult> CopyAsync(CancellationToken ct = default)
    {
        string path;
        System.Xml.Linq.XDocument body;
        try
        {
            var tree = await _ledm.GetTreeAsync(ct).ConfigureAwait(false);
            if (tree?.UriFor(LedmCopy.DynResource) is not { } dynPath
                || await _ledm.GetAsync(LedmCopy.DynResource, ct).ConfigureAwait(false) is not { } dyn)
                return new PrinterCopyResult(CoreStrings.PrinterCopy_NotOffered);
            path = dynPath;
            body = LedmCopy.Build(dyn, Start);
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex) || ex is InvalidOperationException)
        {
            // Nothing was sent: the settings couldn't be read, or no longer have the shape the start was found in.
            return new PrinterCopyResult(CoreStrings.PrinterCopy_NotRead);
        }

        try
        {
            await _ledm.PutPathAsync(path, body, ct, once: true).ConfigureAwait(false);
            return new PrinterCopyResult(null);
        }
        catch (DeviceHttpException ex)
        {
            return new PrinterCopyResult(ex.Status switch
            {
                HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed or HttpStatusCode.NotImplemented => CoreStrings.PrinterCopy_NotOffered,
                HttpStatusCode.Conflict or HttpStatusCode.ServiceUnavailable or HttpStatusCode.TooManyRequests => CoreStrings.PrinterCopy_Busy,
                _ => CoreStrings.PrinterCopy_Refused,
            });
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException)
        {
            // Sent, then no answer: the printer may be copying. Saying so keeps a copy from being sent twice.
            return new PrinterCopyResult(MaintenanceClient.NeverSent(ex) ?? CoreStrings.PrinterCopy_MayHaveStarted);
        }
    }
}
