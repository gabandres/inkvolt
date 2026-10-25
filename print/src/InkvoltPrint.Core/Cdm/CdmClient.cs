using System.Net;
using System.Text;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;

namespace InkvoltPrint.Core.Cdm;

/// <summary>A printer that answered CDM's identity: where (plain HTTP, or HTTPS when it sends HTTP there) and who it is.</summary>
public sealed record CdmProbe(Uri Root, ProductInfo Identity);

/// <summary>
/// HP CDM, read only (<see cref="CdmPaths"/>): identity, supplies and status of newer HP printers that have no LEDM. Only GETs
/// are ever sent: CDM also takes writes (resets, reboots, erases) that some firmware accepts without a password, so this
/// client has no way to send anything else. Settings stay out until HP documents them (README, Known limits).
/// </summary>
public sealed class CdmClient(DeviceHttp http, Uri root)
{
    /// <summary>Scheme, host and port the printer answers CDM on.</summary>
    public Uri Root { get; } = root;

    /// <summary>
    /// The identity over plain HTTP; over HTTPS (self-signed, pinned like the rest) when the printer redirects there or
    /// refuses plain HTTP. Null when it isn't a CDM printer (404, 400 from older firmware, 401/403, or no identity in the reply).
    /// </summary>
    public static async Task<CdmProbe?> ProbeAsync(DeviceHttp http, CancellationToken ct = default)
    {
        foreach (var root in new[] { http.HttpBase, http.HttpsBase })
        {
            HttpResponseMessage resp;
            try
            {
                resp = await http.GetAsync(new Uri(root, CdmPaths.Identity), ct: ct).ConfigureAwait(false);
            }
            catch (HttpRequestException ex) when (root == http.HttpBase && ex.HttpRequestError == HttpRequestError.ConnectionError
                                                  && ex.InnerException is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.ConnectionRefused })
            {
                continue; // plain HTTP refused outright: some printers only answer HTTPS
            }
            using (resp)
            {
                if (resp.StatusCode is HttpStatusCode.MovedPermanently or HttpStatusCode.Found or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect
                    && root == http.HttpBase && resp.Headers.Location is { } to
                    && (!to.IsAbsoluteUri || to.Scheme == Uri.UriSchemeHttps))
                    continue; // to HTTPS on the same printer (the location's host is never followed)
                if (!resp.IsSuccessStatusCode) return null;
                var json = await resp.Content.ReadAsStringAsync(ct).ConfigureAwait(false);
                return CdmParsers.ParseIdentity(json) is { } identity ? new CdmProbe(root, identity) : null;
            }
        }
        return null;
    }

    public async Task<ProductInfo?> GetIdentityAsync(CancellationToken ct = default) =>
        await GetAsync(CdmPaths.Identity, ct).ConfigureAwait(false) is { } json ? CdmParsers.ParseIdentity(json) : null;

    public async Task<IReadOnlyList<Consumable>?> GetSuppliesAsync(CancellationToken ct = default) =>
        await GetAsync(CdmPaths.Supplies, ct).ConfigureAwait(false) is { } json ? CdmParsers.ParseSupplies(json) : null;

    /// <summary>
    /// System status, print status and alerts, one after the other (CDM printers time out under bursts of requests, as the
    /// Home Assistant clients found). Null when the printer gives neither status.
    /// </summary>
    public async Task<PrinterStatus?> GetStatusAsync(CancellationToken ct = default)
    {
        var system = await GetAsync(CdmPaths.SystemStatus, ct).ConfigureAwait(false);
        var print = system is null ? await GetAsync(CdmPaths.PrintStatus, ct).ConfigureAwait(false) : null;
        if (system is null && print is null) return null;
        var alerts = await GetAsync(CdmPaths.Alerts, ct).ConfigureAwait(false);
        return CdmParsers.ParseStatus(system, print, alerts);
    }

    /// <summary>GET only: the body as text, null when the printer doesn't have it (404, or 400 / 403 / 405 from firmware without it).</summary>
    private async Task<string?> GetAsync(string path, CancellationToken ct)
    {
        using var resp = await http.GetAsync(new Uri(Root, path), ct: ct).ConfigureAwait(false);
        if (resp.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.BadRequest or HttpStatusCode.Forbidden or HttpStatusCode.MethodNotAllowed
            or HttpStatusCode.Unauthorized)
            return null;
        await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
        var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        return Encoding.UTF8.GetString(bytes);
    }
}
