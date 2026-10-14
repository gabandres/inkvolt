using System.Net;
using System.Net.Http.Headers;
using System.Runtime.CompilerServices;
using System.Text;
using System.Xml.Linq;
using PrintDesk.Core.Net;

namespace PrintDesk.Core.Escl;

/// <summary>eSCL (AirScan / Mopria scan) client. <paramref name="root"/> is the eSCL base, e.g. <c>http://host/eSCL/</c>.</summary>
public sealed class EsclClient(DeviceHttp http, Uri root)
{
    private static readonly TimeSpan PageTimeout = TimeSpan.FromMinutes(3);
    private ScannerCapabilities? _caps;

    public Uri Root { get; } = root.AbsoluteUri.EndsWith('/') ? root : new Uri(root.AbsoluteUri + "/");

    public async Task<ScannerCapabilities?> GetCapabilitiesAsync(CancellationToken ct = default)
    {
        if (_caps is not null) return _caps;
        var bytes = await http.GetBytesOrNullAsync(new Uri(Root, "ScannerCapabilities"), ct: ct).ConfigureAwait(false);
        return bytes is null ? null : _caps = ScannerCapabilities.Parse(Load(bytes));
    }

    public async Task<ScannerStatus> GetStatusAsync(CancellationToken ct = default)
    {
        var bytes = await http.GetBytesOrNullAsync(new Uri(Root, "ScannerStatus"), ct: ct).ConfigureAwait(false)
            ?? throw new InvalidOperationException("Scanner status not available");
        return ScannerStatus.Parse(Load(bytes));
    }

    /// <summary>
    /// Runs one scan job and yields each page as JPEG bytes. Platen jobs return one page; feeder jobs
    /// return pages until the device answers 404 (feeder empty). Cancelling deletes the job on the device.
    /// </summary>
    public async IAsyncEnumerable<byte[]> ScanAsync(ScanRequest request, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var caps = await GetCapabilitiesAsync(ct).ConfigureAwait(false) ?? throw new InvalidOperationException("Not an eSCL scanner");
        var status = await GetStatusAsync(ct).ConfigureAwait(false);
        if (request.Source != ScanSource.Platen && status.AdfState is not null && !status.AdfLoaded)
            throw new ScanException("Load the pages into the document feeder first.");
        if (!status.IsIdle && status.State != "Processing")
            throw new ScanException($"Scanner is {status.State.ToLowerInvariant()}.");

        var job = await CreateJobAsync(EsclXml.BuildScanSettings(request, caps), ct).ConfigureAwait(false);
        var done = false;
        try
        {
            for (var page = 0; ; page++)
            {
                var bytes = await NextDocumentAsync(job, ct).ConfigureAwait(false);
                if (bytes is null) break;
                yield return JpegFix.PatchZeroHeight(bytes);
                if (request.Source == ScanSource.Platen) break;
            }
            done = true;
        }
        finally
        {
            if (!done) await TryDeleteAsync(job).ConfigureAwait(false);
        }
    }

    private async Task<Uri> CreateJobAsync(XDocument settings, CancellationToken ct)
    {
        var body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + settings.Root!.ToString(SaveOptions.DisableFormatting);
        for (var attempt = 0; ; attempt++)
        {
            using var req = new HttpRequestMessage(HttpMethod.Post, new Uri(Root, "ScanJobs"))
            {
                Content = new StringContent(body, Encoding.UTF8, new MediaTypeHeaderValue("text/xml")),
            };
            using var resp = await http.SendAsync(req, TimeSpan.FromSeconds(15), ct).ConfigureAwait(false);
            if (resp.StatusCode == HttpStatusCode.ServiceUnavailable && attempt < 10)
            {
                await Task.Delay(1000, ct).ConfigureAwait(false); // warming up / busy
                continue;
            }
            if (resp.StatusCode == HttpStatusCode.Conflict) throw new ScanException("Scanner is busy with another job.");
            await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
            var location = resp.Headers.Location ?? throw new ScanException("Scanner did not return a job location.");
            // Resolve only the path against our base: Location often names the host by its .local name or another port.
            var path = location.IsAbsoluteUri ? location.AbsolutePath : location.OriginalString;
            return new Uri(Root, path.TrimEnd('/') + "/");
        }
    }

    private async Task<byte[]?> NextDocumentAsync(Uri job, CancellationToken ct)
    {
        for (var attempt = 0; ; attempt++)
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, new Uri(job, "NextDocument"));
            using var resp = await http.SendAsync(req, PageTimeout, ct).ConfigureAwait(false);
            switch (resp.StatusCode)
            {
                case HttpStatusCode.NotFound or HttpStatusCode.Gone:
                    return null;
                case HttpStatusCode.ServiceUnavailable when attempt < 60:
                    await Task.Delay(500, ct).ConfigureAwait(false);
                    continue;
            }
            await DeviceHttp.EnsureSuccessAsync(resp).ConfigureAwait(false);
            return await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
        }
    }

    private async Task TryDeleteAsync(Uri job)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Delete, job);
            using var _ = await http.SendAsync(req, TimeSpan.FromSeconds(5)).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is HttpRequestException or TimeoutException)
        {
            // Best effort; the device times stale jobs out on its own.
        }
    }

    private static XDocument Load(byte[] bytes)
    {
        using var ms = new MemoryStream(bytes);
        return XDocument.Load(ms);
    }
}

public sealed class ScanException(string message) : Exception(message);
