using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Xml.Linq;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;

namespace InkvoltPrint.Core.Maintenance;

/// <summary>The outcome of one maintenance request, in words for the card.</summary>
public sealed record MaintenanceResult(bool Ok, string Message);

/// <summary>
/// Finds a printer's maintenance actions (reads only: GETs and IPP Get-Printer-Attributes) and sends one when asked.
/// A request is sent exactly once, never retried: a cleaning sent twice uses ink twice.
/// </summary>
public sealed class MaintenanceClient(PrinterConnection connection, string? userName = null)
{
    /// <summary>What Get-Printer-Attributes asks for: Identify-Printer support and the printer's maintenance page.</summary>
    public static readonly string[] IppAttributes =
        ["operations-supported", "identify-actions-supported", "identify-actions-default", "printer-supply-info-uri", "marker-types"];

    private static readonly TimeSpan PostTimeout = TimeSpan.FromSeconds(15);

    private DeviceHttp Http => connection.Http;

    public async Task<MaintenanceOptions> DetectAsync(CancellationToken ct = default)
    {
        var ledm = ReadLedmAsync(ct);
        var ipp = ReadIppAsync(ct);
        await Task.WhenAll(ledm, ipp).ConfigureAwait(false);
        var (hasLedm, jobs, dyn, alignment, marking) = ledm.Result;
        var attrs = ipp.Result;
        if (marking == Marking.Unknown && attrs is not null) marking = MaintenanceRequests.FromKinds(attrs.Strs("marker-types"));
        return MaintenanceCatalog.Detect(new MaintenanceSources
        {
            Host = Http.Host,
            HasLedm = hasLedm,
            HasCdm = connection.Cdm is not null,
            HasSnmp = connection.Snmp is not null,
            LedmJobTypes = jobs,
            LedmDynPath = dyn,
            AlignmentMode = alignment,
            Ipp = attrs,
            Marking = marking,
        });
    }

    private async Task<(bool, IReadOnlyList<string>?, string?, string?, Marking)> ReadLedmAsync(CancellationToken ct)
    {
        if (connection.Ledm is not { } ledm || await Try(() => ledm.GetTreeAsync(ct)).ConfigureAwait(false) is not { } tree)
            return (false, null, null, null, Marking.Unknown);

        // Paths from the InternalPrint manifest when the tree lists one, else HPLIP's fixed paths (a 404 there means none).
        var (capPath, dynPath) = (MaintenanceRequests.InternalPrintCapPath, MaintenanceRequests.InternalPrintDynPath);
        if (tree.ManifestFor(MaintenanceRequests.InternalPrintManifest) is { } manifestPath
            && await Try(() => ledm.GetPathAsync(manifestPath, ct)).ConfigureAwait(false) is { } manifest)
        {
            var map = LedmManifest.Parse(manifest);
            capPath = Find(map, "InternalPrintCap") ?? capPath;
            dynPath = Find(map, "InternalPrintDyn") ?? dynPath;
        }
        var consumables = Try(() => ledm.GetAsync(LedmResource.ConsumableConfigDyn, ct));
        var cap = await Try(() => ledm.GetPathAsync(capPath, ct)).ConfigureAwait(false);
        var jobs = cap is null ? null : MaintenanceRequests.ParseJobTypes(cap);
        var cc = await consumables.ConfigureAwait(false);
        var alignment = tree.ManifestFor(MaintenanceRequests.CalibrationManifest) is not null && cc is not null
            ? MaintenanceRequests.ParseAlignmentMode(cc) : null;
        return (true, jobs is { Count: > 0 } ? jobs : null, dynPath, alignment, cc is null ? Marking.Unknown : MaintenanceRequests.ParseMarking(cc));
    }

    private static string? Find(IReadOnlyDictionary<string, string> map, string type) =>
        map.FirstOrDefault(kv => kv.Key.EndsWith(type, StringComparison.Ordinal)).Value;

    private async Task<IppResponse?> ReadIppAsync(CancellationToken ct) =>
        connection.Ipp is { } ipp && await Try<IppResponse>(async () => await ipp.GetPrinterAttributesAsync(IppAttributes, ct).ConfigureAwait(false)).ConfigureAwait(false)
            is { Ok: true } r ? r : null;

    /// <summary>
    /// Sends the action once. LEDM requests go over HTTPS (the admin password, when the printer has one, never crosses in
    /// clear text) and throw <see cref="LedmAuthRequiredException"/> on 401/403 so the caller can ask for it.
    /// </summary>
    public async Task<MaintenanceResult> RunAsync(MaintenanceAction action, CancellationToken ct = default)
    {
        try
        {
            return action.Kind switch
            {
                MaintenanceKind.Identify => await IdentifyAsync(action, ct).ConfigureAwait(false),
                MaintenanceKind.Alignment => await AlignAsync(action, ct).ConfigureAwait(false),
                _ => await PostLedmAsync(action, action.Target!, MaintenanceRequests.InternalPrint(action.JobType!), ct).ConfigureAwait(false),
            };
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException)
        {
            if (NeverSent(ex) is { } why) return new MaintenanceResult(false, why);
            // Sent, then no answer: the printer may well be doing it. Saying so keeps a cleaning from being sent twice.
            return new MaintenanceResult(false, "The printer didn't answer, so the request may have started anyway. Check the printer before trying again.");
        }
    }

    /// <summary>
    /// Why this request's own failure proves nothing reached the printer, or null when it may have. Writes go on a new
    /// connection each (<see cref="DeviceHttp.SendOnceAsync"/>), so a failed TLS handshake (the printer's certificate no
    /// longer matches its pin, say) or a refused connection happened before a byte of the request was sent. Decided from
    /// the exception alone: <see cref="DeviceHttp.CertificateChanged"/> is sticky and shared by every port.
    /// </summary>
    internal static string? NeverSent(Exception ex)
    {
        for (var e = ex.InnerException; e is not null; e = e.InnerException)
        {
            if (e is System.Security.Authentication.AuthenticationException)
                return "Not sent: the secure connection to the printer failed. If its security certificate changed (after a reset or " +
                       "an update), check it under Printer settings; otherwise another device may be answering at its address.";
            if (e is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.ConnectionRefused })
                return "Not sent: the printer refused the connection. Check that it's on, then try again.";
        }
        return null;
    }

    private async Task<MaintenanceResult> AlignAsync(MaintenanceAction action, CancellationToken ct)
    {
        if (connection.Ledm is { } ledm && await Try(() => ledm.GetPathAsync(MaintenanceRequests.CalibrationStatePath, ct)).ConfigureAwait(false) is { } state)
        {
            switch (MaintenanceRequests.ReadCalibration(state))
            {
                case CalibrationStatus.Running:
                    return new MaintenanceResult(false, "An alignment is already under way on the printer. Finish it there first.");
                case CalibrationStatus.AwaitingParameters:
                    // HPLIP base/maint.py: "ParmsRequested" → "Restart device and start alignment".
                    return new MaintenanceResult(false, "An earlier alignment is still waiting to be finished on the printer. Finish it on the " +
                                                        "printer's control panel, or turn the printer off and on again, then try again.");
            }
        }
        return await PostLedmAsync(action, action.Target!, MaintenanceRequests.StartAlignment(), ct).ConfigureAwait(false);
    }

    private async Task<MaintenanceResult> PostLedmAsync(MaintenanceAction action, string path, string body, CancellationToken ct)
    {
        var target = Http.Https(path);
        using var req = new HttpRequestMessage(HttpMethod.Post, target)
        {
            Content = new StringContent(body, Encoding.UTF8, new MediaTypeHeaderValue("text/xml")),
        };
        // Newer HP web servers (nginx) check these against cross-site requests (hp-printer-maintenance, ews.py _post_xml).
        var origin = target.GetLeftPart(UriPartial.Authority);
        req.Headers.TryAddWithoutValidation("Origin", origin);
        req.Headers.TryAddWithoutValidation("Referer", origin + "/");
        req.Headers.TryAddWithoutValidation("X-Requested-With", "XMLHttpRequest");
        using var resp = await Http.SendOnceAsync(req, PostTimeout, ct).ConfigureAwait(false);
        return resp.StatusCode switch
        {
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden => throw new LedmAuthRequiredException(Http.HasCredentials),
            _ when resp.IsSuccessStatusCode => new MaintenanceResult(true, action.Sent),
            HttpStatusCode.NotFound or HttpStatusCode.MethodNotAllowed or HttpStatusCode.NotImplemented =>
                new MaintenanceResult(false, "The printer doesn't offer this to apps after all. Use its control panel or web page."),
            HttpStatusCode.Conflict or HttpStatusCode.ServiceUnavailable or HttpStatusCode.TooManyRequests =>
                new MaintenanceResult(false, "The printer is busy and didn't start it. Try again when it's idle."),
            var s => new MaintenanceResult(false, $"The printer refused it (HTTP {(int)s})."),
        };
    }

    private async Task<MaintenanceResult> IdentifyAsync(MaintenanceAction action, CancellationToken ct)
    {
        if (connection.Ipp is not { } ipp) return new MaintenanceResult(false, "The printer doesn't answer IPP any more.");
        IppResponse r;
        try
        {
            r = await ipp.IdentifyPrinterAsync(action.IdentifyActions, userName, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is DeviceHttpException or FormatException)
        {
            return new MaintenanceResult(false, $"The printer refused it ({ex.Message}).");
        }
        return r.StatusCode switch
        {
            < 0x0100 => new MaintenanceResult(true, action.Sent),
            // PWG 5100.13 §4.1: a printer SHOULD ask for an authenticated user and answers with one of these when it does.
            0x0401 or 0x0402 or 0x0403 => new MaintenanceResult(false, "The printer only does this for a signed-in user. Use its control panel or web page."),
            0x0501 => new MaintenanceResult(false, "The printer doesn't offer this after all."),
            var s => new MaintenanceResult(false, $"The printer refused it (IPP status 0x{s:X4})."),
        };
    }

    private static async Task<T?> Try<T>(Func<Task<T?>> read) where T : class
    {
        try { return await read().ConfigureAwait(false); }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex) || ex is System.Xml.XmlException)
        {
            return null;
        }
    }
}
