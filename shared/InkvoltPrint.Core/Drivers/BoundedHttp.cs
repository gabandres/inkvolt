using System.Net;

namespace InkvoltPrint.Core.Drivers;

/// <summary>Why a fetch was refused or failed: each said in words by <see cref="DriverText"/>.</summary>
public enum FetchProblem
{
    /// <summary>Not https, or a host not on the maker's list (a redirect to one included).</summary>
    NotMakersSite,
    TooManyRedirects,
    TooBig,

    /// <summary>Fewer bytes came than the server said it would send.</summary>
    CutShort,
    TimedOut,

    /// <summary>No answer, or an error status.</summary>
    Unreachable,
}

public sealed class FetchException(FetchProblem problem, string? detail = null) : Exception($"{problem}{(detail is null ? "" : $": {detail}")}")
{
    public FetchProblem Problem { get; } = problem;
}

/// <summary>
/// Reads a page or downloads a file from a maker's own site, everything it gets treated as hostile: https only, to hosts on the
/// maker's list only (each redirect checked the same way, at most 5), bounded in size (the server's length is checked before a
/// byte is read, and the bytes are counted as they come) and in time. Nothing is sent but the request for the address: no
/// cookies, no identifiers. Redirects are never followed by the handler (<see cref="CreateHandler"/>), only here.
/// </summary>
public sealed class BoundedHttp(HttpMessageHandler handler)
{
    private readonly HttpClient _client = new(handler, disposeHandler: false) { Timeout = Timeout.InfiniteTimeSpan };

    private const int MaxRedirects = 5;

    /// <summary>The handler the app uses: no redirects followed, no cookies kept, the system's proxy.</summary>
    public static HttpMessageHandler CreateHandler() => new SocketsHttpHandler
    {
        AllowAutoRedirect = false, UseCookies = false, AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate,
        ConnectTimeout = TimeSpan.FromSeconds(20),
    };

    /// <summary>A page's text (UTF-8), at most <paramref name="maxBytes"/>, within <paramref name="limit"/>.</summary>
    public async Task<string> GetTextAsync(Uri uri, IReadOnlyCollection<string> hosts, long maxBytes, TimeSpan limit, CancellationToken ct)
    {
        using var buffer = new MemoryStream();
        await FetchAsync(uri, hosts, maxBytes, limit, buffer, null, ct).ConfigureAwait(false);
        return System.Text.Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }

    /// <summary>
    /// Downloads to <paramref name="path"/> (made new; deleted again when anything goes wrong), at most <paramref name="maxBytes"/>,
    /// within <paramref name="limit"/>; <paramref name="progress"/> gets the bytes so far. The final address it came from is returned.
    /// </summary>
    public async Task<Uri> DownloadAsync(Uri uri, IReadOnlyCollection<string> hosts, long maxBytes, TimeSpan limit, string path, IProgress<long>? progress,
        CancellationToken ct)
    {
        try
        {
            await using var file = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None, 81920, useAsync: true);
            return await FetchAsync(uri, hosts, maxBytes, limit, file, progress, ct).ConfigureAwait(false);
        }
        catch
        {
            TryDelete(path);
            throw;
        }
    }

    internal static void TryDelete(string path)
    {
        try { File.Delete(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { System.Diagnostics.Trace.WriteLine($"driver download: {ex.Message}"); }
    }

    /// <summary>The host is the maker's: https, a name on the list exactly (no user info, no other port).</summary>
    public static bool IsAllowed(Uri uri, IReadOnlyCollection<string> hosts) =>
        uri.IsAbsoluteUri && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort && uri.UserInfo.Length == 0
        && hosts.Contains(uri.IdnHost, StringComparer.OrdinalIgnoreCase);

    private async Task<Uri> FetchAsync(Uri uri, IReadOnlyCollection<string> hosts, long maxBytes, TimeSpan limit, Stream into, IProgress<long>? progress,
        CancellationToken ct)
    {
        using var time = CancellationTokenSource.CreateLinkedTokenSource(ct);
        time.CancelAfter(limit);
        try
        {
            var at = uri;
            for (var hop = 0; ; hop++)
            {
                if (!IsAllowed(at, hosts)) throw new FetchException(FetchProblem.NotMakersSite, at.IdnHost);
                using var request = new HttpRequestMessage(HttpMethod.Get, at);
                request.Headers.UserAgent.ParseAdd("InkvoltPrint/1.0");
                using var response = await _client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, time.Token).ConfigureAwait(false);
                if ((int)response.StatusCode is >= 300 and < 400 && response.Headers.Location is { } next)
                {
                    if (hop >= MaxRedirects) throw new FetchException(FetchProblem.TooManyRedirects);
                    at = next.IsAbsoluteUri ? next : new Uri(at, next);
                    continue;
                }
                if (!response.IsSuccessStatusCode) throw new FetchException(FetchProblem.Unreachable, ((int)response.StatusCode).ToString(System.Globalization.CultureInfo.InvariantCulture));
                var length = response.Content.Headers.ContentLength;
                if (length > maxBytes) throw new FetchException(FetchProblem.TooBig);
                await using var body = await response.Content.ReadAsStreamAsync(time.Token).ConfigureAwait(false);
                var buffer = new byte[81920];
                long total = 0;
                int read;
                while ((read = await body.ReadAsync(buffer, time.Token).ConfigureAwait(false)) > 0)
                {
                    total += read;
                    if (total > maxBytes) throw new FetchException(FetchProblem.TooBig);
                    await into.WriteAsync(buffer.AsMemory(0, read), time.Token).ConfigureAwait(false);
                    progress?.Report(total);
                }
                if (length is { } expected && total != expected) throw new FetchException(FetchProblem.CutShort);
                return at;
            }
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new FetchException(FetchProblem.TimedOut);
        }
        catch (HttpRequestException ex)
        {
            throw new FetchException(FetchProblem.Unreachable, ex.Message);
        }
        catch (IOException ex) when (ex is not FileNotFoundException)
        {
            // The connection dropped part way (the stream ends with an error rather than short).
            throw new FetchException(FetchProblem.CutShort, ex.Message);
        }
    }
}
