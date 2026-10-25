namespace InkvoltPrint.Core.Net;

/// <summary>
/// Several offline printers behind one transport (demo mode): each request goes to the handler for its host; other
/// hosts don't answer (a connection error, like a printer that's switched off). Owns and disposes the handlers.
/// </summary>
public sealed class HostRouter(IReadOnlyDictionary<string, HttpMessageHandler> hosts) : HttpMessageHandler
{
    private readonly Dictionary<string, HttpMessageInvoker> _invokers =
        hosts.ToDictionary(kv => kv.Key, kv => new HttpMessageInvoker(kv.Value, disposeHandler: true), StringComparer.OrdinalIgnoreCase);

    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
        request.RequestUri is { } uri && _invokers.TryGetValue(uri.Host, out var invoker)
            ? invoker.SendAsync(request, ct)
            : Task.FromException<HttpResponseMessage>(
                new HttpRequestException(HttpRequestError.ConnectionError, $"No demo printer at {request.RequestUri?.Host}", statusCode: null));

    protected override void Dispose(bool disposing)
    {
        if (disposing)
            foreach (var i in _invokers.Values) i.Dispose();
        base.Dispose(disposing);
    }
}
