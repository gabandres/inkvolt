using System.Net;
using System.Web;

namespace InkvoltPrint.Core.Net;

/// <summary>
/// Offline stand-in for a printer's web server: answers <see cref="DeviceHttp"/> requests from captured device
/// documents and never opens a socket. Used by <c>InkvoltPrint.exe --demo</c> (screenshots, trying the app without a
/// printer) and by tests. A request path maps to a document name by replacing <c>/</c> with <c>_</c> and adding
/// <c>.xml</c> when there is no extension: <c>/DevMgmt/ProductStatusDyn.xml</c> → <c>DevMgmt_ProductStatusDyn.xml</c>,
/// <c>/eSCL/ScannerCapabilities</c> → <c>eSCL_ScannerCapabilities.xml</c>. Anything without a document is 404
/// (so IPP and product images are simply "not supported").
/// </summary>
/// <param name="document">Document name → bytes, or null when there is none.</param>
/// <param name="scanPage">JPEG returned for each eSCL scan job (one page); null: scanning fails with 404.</param>
/// <param name="scanArea">Instead of <paramref name="scanPage"/>: the JPEG for the job's scan region (width, height in 1/300 in).</param>
public sealed class FixtureHandler(Func<string, byte[]?> document, Func<byte[]>? scanPage = null, Func<int, int, byte[]>? scanArea = null)
    : HttpMessageHandler
{
    /// <summary>Address shown for the demo printer: RFC 5737 documentation range, never a real device.</summary>
    public const string DemoHost = "192.0.2.10";

    private const string JobPath = "/eSCL/ScanJobs/demo-1";
    private int _pagesLeft;
    private (int Width, int Height) _area = (2550, 3300);

    private bool CanScan => scanPage is not null || scanArea is not null;

    public static string DocumentName(string path)
    {
        var name = path.Trim('/').Replace('/', '_');
        return Path.HasExtension(name) ? name : name + ".xml";
    }

    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
    {
        var uri = request.RequestUri!;
        var path = uri.AbsolutePath;

        if (request.Method == HttpMethod.Get && path.EndsWith("/EventTable.xml", StringComparison.Ordinal)
                                             && request.Headers.Contains("If-None-Match"))
        {
            // LEDM long poll: nothing ever changes here, so hold the request like an idle printer, then 304.
            var wait = int.TryParse(HttpUtility.ParseQueryString(uri.Query)["timeout"], out var ds) ? ds * 100 : 60_000;
            await Task.Delay(Math.Clamp(wait, 1_000, 600_000), ct).ConfigureAwait(false);
            return Reply(request, HttpStatusCode.NotModified);
        }

        if (request.Method == HttpMethod.Post && path.EndsWith("/ScanJobs", StringComparison.Ordinal) && CanScan)
        {
            if (request.Content is not null) _area = Region(await request.Content.ReadAsStringAsync(ct).ConfigureAwait(false), _area);
            Interlocked.Exchange(ref _pagesLeft, 1);
            var created = Reply(request, HttpStatusCode.Created);
            created.Headers.Location = new Uri(JobPath, UriKind.Relative);
            return created;
        }
        if (request.Method == HttpMethod.Get && path == JobPath + "/NextDocument")
        {
            return CanScan && Interlocked.Exchange(ref _pagesLeft, 0) == 1
                ? Reply(request, HttpStatusCode.OK, scanArea?.Invoke(_area.Width, _area.Height) ?? scanPage!(), "image/jpeg")
                : Reply(request, HttpStatusCode.NotFound);
        }
        if (request.Method == HttpMethod.Delete) return Reply(request, HttpStatusCode.OK);
        // Settings writes are accepted and forgotten: the demo printer always reads back its captured settings.
        if (request.Method == HttpMethod.Put) return Reply(request, HttpStatusCode.OK);

        if (request.Method == HttpMethod.Get && document(DocumentName(path)) is { } bytes)
        {
            var ok = Reply(request, HttpStatusCode.OK, bytes, "text/xml");
            if (path.EndsWith("/EventTable.xml", StringComparison.Ordinal)) ok.Headers.TryAddWithoutValidation("ETag", "1-1");
            return ok;
        }
        return Reply(request, HttpStatusCode.NotFound);
    }

    /// <summary>The ScanSettings' region (Width, Height); the previous one if it can't be read.</summary>
    private static (int, int) Region(string settings, (int, int) fallback)
    {
        try
        {
            var region = System.Xml.Linq.XDocument.Parse(settings).Descendants().FirstOrDefault(e => e.Name.LocalName == "ScanRegion");
            var w = region?.Elements().FirstOrDefault(e => e.Name.LocalName == "Width")?.Value;
            var h = region?.Elements().FirstOrDefault(e => e.Name.LocalName == "Height")?.Value;
            return int.TryParse(w, out var wi) && int.TryParse(h, out var hi) && wi > 0 && hi > 0 ? (wi, hi) : fallback;
        }
        catch (System.Xml.XmlException)
        {
            return fallback;
        }
    }

    private static HttpResponseMessage Reply(HttpRequestMessage request, HttpStatusCode status, byte[]? body = null, string? type = null)
    {
        var resp = new HttpResponseMessage(status) { RequestMessage = request, Content = new ByteArrayContent(body ?? []) };
        if (type is not null) resp.Content.Headers.ContentType = new(type);
        return resp;
    }
}
