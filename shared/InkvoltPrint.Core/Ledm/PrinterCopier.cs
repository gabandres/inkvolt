using System.Net;
using System.Net.Http.Headers;
using System.Text;
using InkvoltPrint.Core.Maintenance;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Core.Ledm;

/// <summary>The outcome of asking the printer to copy: null <see cref="Problem"/> when it took the request.</summary>
public sealed record PrinterCopyResult(string? Problem)
{
    public bool Ok => Problem is null;
}

/// <summary>
/// The printer's own copier over LEDM (<see cref="LedmCopy"/>): found by reading only, and a copy sent exactly once
/// (<see cref="Net.DeviceHttp.SendOnceAsync"/>, never retried: a copy sent twice uses paper twice), over HTTPS so an admin
/// password never crosses in clear text. No Windows queue is involved.
/// </summary>
public sealed class PrinterCopier
{
    private static readonly TimeSpan PutTimeout = TimeSpan.FromSeconds(15);

    private readonly LedmClient _ledm;

    private PrinterCopier(LedmClient ledm, PrinterCopyOffer offer)
    {
        _ledm = ledm;
        Offer = offer;
    }

    public PrinterCopyOffer Offer { get; }

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
            return dyn is not null && LedmCopy.Read(dyn, cap) is { } offer ? new PrinterCopier(ledm, offer) : null;
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex))
        {
            return null;
        }
    }

    /// <summary>
    /// Reads the copy settings again, then sends one PUT that sets them and starts the copy. Throws
    /// <see cref="LedmAuthRequiredException"/> on 401/403 so the caller can ask for the admin password.
    /// </summary>
    public async Task<PrinterCopyResult> CopyAsync(PrinterCopyRequest request, CancellationToken ct = default)
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
            body = LedmCopy.Build(dyn, Offer, request);
        }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex) || ex is InvalidOperationException)
        {
            // Nothing was sent: the settings couldn't be read, or no longer have the shape the offer was made from.
            return new PrinterCopyResult(CoreStrings.PrinterCopy_NotRead);
        }

        var http = _ledm.Http;
        using var req = new HttpRequestMessage(HttpMethod.Put, http.Https(path))
        {
            Content = new StringContent(LedmClient.Serialize(body), Encoding.UTF8, new MediaTypeHeaderValue("text/xml")),
        };
        try
        {
            using var resp = await http.SendOnceAsync(req, PutTimeout, ct).ConfigureAwait(false);
            return resp.StatusCode switch
            {
                HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => throw new LedmAuthRequiredException(http.HasCredentials),
                _ when resp.IsSuccessStatusCode => new PrinterCopyResult(null),
                HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed or HttpStatusCode.NotImplemented =>
                    new PrinterCopyResult(CoreStrings.PrinterCopy_NotOffered),
                HttpStatusCode.Conflict or HttpStatusCode.ServiceUnavailable or HttpStatusCode.TooManyRequests =>
                    new PrinterCopyResult(CoreStrings.PrinterCopy_Busy),
                _ => new PrinterCopyResult(CoreStrings.PrinterCopy_Refused),
            };
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException)
        {
            // Sent, then no answer: the printer may be copying. Saying so keeps a copy from being sent twice.
            return new PrinterCopyResult(MaintenanceClient.NeverSent(ex) ?? CoreStrings.Maint_NoAnswerMayHaveStarted);
        }
    }
}
