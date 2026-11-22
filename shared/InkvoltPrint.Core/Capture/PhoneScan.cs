using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;
using InkvoltPrint.Core.Sharing;

namespace InkvoltPrint.Core.Capture;

/// <summary>One request from the phone, as the server read its headers (the body is read only when <see cref="PhoneSession"/> asks).</summary>
/// <param name="Path">The request's path, without the query.</param>
/// <param name="Peer">Who asked: kept in memory for the session only, never logged.</param>
/// <param name="Cookie">The session cookie's value, when the request carried it.</param>
/// <param name="FromPage">The request carried <see cref="PhoneSession.PageHeader"/>: the page's own script sent it (a form on another site can't).</param>
public sealed record PhoneRequest(string Method, string Path, IPAddress Peer, string? Cookie = null, bool FromPage = false);

/// <summary>The answer, with the headers the page needs.</summary>
public sealed record PhoneReply(int Status, string? ContentType = null, byte[]? Body = null)
{
    /// <summary>A <c>Set-Cookie</c> header's value.</summary>
    public string? SetCookie { get; init; }

    /// <summary>The page's <c>Content-Security-Policy</c>.</summary>
    public string? ContentSecurityPolicy { get; init; }

    public int? RetryAfterSeconds { get; init; }

    public static PhoneReply Empty(int status) => new(status);
}

/// <summary>How much one phone may send (roadmap 4.6: bounded sizes and counts). Tests make them small.</summary>
public sealed record PhoneLimits
{
    /// <summary>Photos one scan takes; more are refused (429).</summary>
    public int MaxPhotos { get; init; } = 100;

    /// <summary>The largest photo taken (bytes); larger is refused unread (413).</summary>
    public int MaxPhotoBytes { get; init; } = PhotoInput.MaxBytes;

    /// <summary>Photos held while the PC makes pages of earlier ones; the phone's next upload waits past that.</summary>
    public int Waiting { get; init; } = 2;
}

/// <summary>Where a phone session stands.</summary>
public enum PhoneState
{
    /// <summary>The code is shown; no phone has opened the page yet.</summary>
    Waiting,

    /// <summary>A phone opened the page: only it may send.</summary>
    Paired,

    /// <summary>The phone said Done, or the PC ended the scan: nothing more is taken.</summary>
    Finished,
}

/// <summary>
/// One phone scan (roadmap 4.6): the page a phone's browser opens from the QR code, and the photos it sends, without the HTTP server
/// around it (Kestrel, over HTTPS: InkvoltPrint.Sharing). Every request is hostile until it shows it may: the path's one-time
/// <see cref="Token"/> (32 random bytes, compared in constant time) reaches the page; the page's script then pairs, and the first
/// phone to pair gets a session cookie (another 32 random bytes) bound to its address, after which no other device can pair or
/// send. Photos are read only from the paired phone, one at a time, at most <see cref="PhoneLimits.MaxPhotoBytes"/>, a JPEG or PNG
/// by their first bytes within <see cref="PhotoInput"/>'s pixel limits, at most <see cref="PhoneLimits.MaxPhotos"/>. Nothing names
/// a file on this PC, nothing is listed, nothing is kept after the scan. <see cref="Photos"/> completes when the phone says Done or
/// <see cref="Finish"/> is called.
/// </summary>
public sealed class PhoneSession
{
    public const string CookieName = "inkvolt-phone";

    /// <summary>The header the page's script sends with each POST; a cross-site form can't send it without a preflight nothing answers.</summary>
    public const string PageHeader = "X-Inkvolt-Phone";

    private readonly byte[] _token;
    private readonly string _pcName;
    private readonly PhoneLimits _limits;
    private readonly Channel<CapturedPhoto> _photos;
    private readonly SemaphoreSlim _upload = new(1, 1);
    private readonly Lock _gate = new();
    private byte[]? _secret;
    private IPAddress? _phone;
    private PhoneState _state = PhoneState.Waiting;
    private int _received;

    /// <param name="pcName">This PC's name, shown on the page (encoded there).</param>
    public PhoneSession(string pcName, PhoneLimits? limits = null)
    {
        _pcName = pcName;
        _limits = limits ?? new PhoneLimits();
        Token = Base64Url(RandomNumberGenerator.GetBytes(32));
        _token = Encoding.ASCII.GetBytes(Token);
        _photos = Channel.CreateBounded<CapturedPhoto>(new BoundedChannelOptions(Math.Max(1, _limits.Waiting)) { SingleReader = true, SingleWriter = true });
    }

    /// <summary>The one-time code in the page's address (URL-safe Base64, 43 characters).</summary>
    public string Token { get; }

    /// <summary>The page's path: <c>/p/</c> and the token.</summary>
    public string PagePath => "/p/" + Token;

    /// <summary>The photos as they arrive, for <see cref="CaptureScanner"/>; completed at Done.</summary>
    public ChannelReader<CapturedPhoto> Photos => _photos.Reader;

    public PhoneState State
    {
        get { lock (_gate) return _state; }
    }

    /// <summary>Photos taken in so far.</summary>
    public int Received
    {
        get { lock (_gate) return _received; }
    }

    /// <summary>The state or the count changed (from the server's threads).</summary>
    public event Action? Changed;

    /// <summary>The PC ends the scan: the phone is told, nothing more is taken, the photos already in go on to be made pages.</summary>
    public void Finish()
    {
        lock (_gate)
        {
            if (_state == PhoneState.Finished) return;
            _state = PhoneState.Finished;
        }
        _photos.Writer.TryComplete();
        Raise();
    }

    /// <summary>
    /// Answers <paramref name="request"/>. <paramref name="readBody"/> reads the request's body, at most the bytes it's given (null when
    /// there are more); it's called only for a photo from the paired phone.
    /// </summary>
    public async Task<PhoneReply> HandleAsync(PhoneRequest request, Func<int, CancellationToken, Task<byte[]?>> readBody, CancellationToken ct)
    {
        // "/p/<token>" and, after it, the action: anything else is not here (no listing, no other path).
        if (!request.Path.StartsWith("/p/", StringComparison.Ordinal)) return PhoneReply.Empty(404);
        var rest = request.Path.AsSpan(3);
        var slash = rest.IndexOf('/');
        var token = slash < 0 ? rest : rest[..slash];
        var action = slash < 0 ? "" : rest[(slash + 1)..].ToString();
        Span<byte> asked = stackalloc byte[64];
        if (token.Length > asked.Length || Encoding.ASCII.GetBytes(token, asked) is var n && !CryptographicOperations.FixedTimeEquals(asked[..n], _token))
            return PhoneReply.Empty(404);
        var get = request.Method is "GET" or "HEAD";
        return action switch
        {
            "" when get => Page(),
            "" => PhoneReply.Empty(405),
            "pair" when request.Method == "POST" => Pair(request),
            "photo" when request.Method == "POST" => await PhotoAsync(request, readBody, ct).ConfigureAwait(false),
            "done" when request.Method == "POST" => Done(request),
            "pair" or "photo" or "done" => PhoneReply.Empty(405),
            _ => PhoneReply.Empty(404),
        };
    }

    /// <summary>The first phone to pair is the one; it pairs again (a reload) with its cookie, from its address.</summary>
    private PhoneReply Pair(PhoneRequest request)
    {
        if (!request.FromPage) return PhoneReply.Empty(403);
        lock (_gate)
        {
            if (_state == PhoneState.Finished) return Json(410, "ended");
            if (_state == PhoneState.Paired) return IsPhone(request) ? Json(200, "paired") : Json(403, "used");
            _secret = RandomNumberGenerator.GetBytes(32);
            _phone = SharePeers.Normal(request.Peer);
            _state = PhoneState.Paired;
        }
        Raise();
        return Json(200, "paired") with { SetCookie = $"{CookieName}={Base64Url(_secret!)}; Path={PagePath}; Secure; HttpOnly; SameSite=Strict" };
    }

    /// <summary>The paired phone: its cookie (constant time) from the address it paired from. Inside <see cref="_gate"/>.</summary>
    private bool IsPhone(PhoneRequest request)
    {
        if (_secret is null || _phone is null || request.Cookie is not { Length: > 0 and <= 64 } cookie) return false;
        Span<byte> given = stackalloc byte[64];
        var n = Encoding.ASCII.GetBytes(cookie, given);
        var expected = Encoding.ASCII.GetBytes(Base64Url(_secret));
        return CryptographicOperations.FixedTimeEquals(given[..n], expected) & SharePeers.Normal(request.Peer).Equals(_phone);
    }

    private async Task<PhoneReply> PhotoAsync(PhoneRequest request, Func<int, CancellationToken, Task<byte[]?>> readBody, CancellationToken ct)
    {
        if (!request.FromPage) return PhoneReply.Empty(403);
        lock (_gate)
        {
            if (!IsPhone(request)) return Json(403, "used");
            if (_state == PhoneState.Finished) return Json(410, "ended");
            if (_received >= _limits.MaxPhotos) return Json(429, "too-many");
        }
        // One photo at a time: the page sends them in turn, so a second at once is someone else's doing.
        if (!await _upload.WaitAsync(0, ct).ConfigureAwait(false)) return Json(429, "busy") with { RetryAfterSeconds = 2 };
        try
        {
            var body = await readBody(_limits.MaxPhotoBytes, ct).ConfigureAwait(false);
            if (body is null) return Json(413, "too-big");
            if (PhotoInput.Inspect(body) is null) return Json(415, "not-a-photo");
            lock (_gate)
            {
                if (_state == PhoneState.Finished) return Json(410, "ended");
                if (_received >= _limits.MaxPhotos) return Json(429, "too-many");
            }
            try
            {
                await _photos.Writer.WriteAsync(new CapturedPhoto(body), ct).ConfigureAwait(false); // waits while the PC is behind
            }
            catch (ChannelClosedException)
            {
                return Json(410, "ended");
            }
            int count;
            lock (_gate) count = ++_received;
            Raise();
            return Json(200, "received", count);
        }
        finally
        {
            _upload.Release();
        }
    }

    private PhoneReply Done(PhoneRequest request)
    {
        if (!request.FromPage) return PhoneReply.Empty(403);
        lock (_gate)
        {
            if (!IsPhone(request)) return Json(403, "used");
        }
        Finish();
        return Json(200, "done", Received);
    }

    private static PhoneReply Json(int status, string state, int? pages = null) =>
        new(status, "application/json; charset=utf-8", JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object?> { ["state"] = state, ["pages"] = pages }));

    /// <summary>The page, with a fresh nonce for its script and style; nothing in it comes from a request.</summary>
    private PhoneReply Page()
    {
        var nonce = Base64Url(RandomNumberGenerator.GetBytes(16));
        return new PhoneReply(200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(PhonePage.Html(_pcName, nonce)))
        {
            ContentSecurityPolicy = $"default-src 'none'; script-src 'nonce-{nonce}'; style-src 'nonce-{nonce}'; img-src blob:; connect-src 'self'; "
                + "form-action 'none'; frame-ancestors 'none'; base-uri 'none'",
        };
    }

    private void Raise()
    {
        try { Changed?.Invoke(); }
        catch (Exception) { /* a listener's failure isn't the phone's */ }
    }

    internal static string Base64Url(byte[] bytes) => Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
}

/// <summary>What the phone server listens with: address and port, certificate, who may connect (peer, and this PC's address it reached), the session.</summary>
public sealed record PhoneListen(IPAddress Address, int Port, X509Certificate2 Certificate, Func<IPAddress, IPAddress, bool> AllowPeer, PhoneSession Session);

/// <summary>Starts the phone page's HTTPS server (Kestrel in the app). Fails with <see cref="SocketException"/> (AddressAlreadyInUse) when the port is taken.</summary>
public interface IPhoneHost
{
    Task<IShareListener> StartAsync(PhoneListen listen, CancellationToken ct);
}

/// <summary>
/// What phone scanning works through: the server, this PC's networks and the certificate (scanner sharing's: 3.1).
/// <paramref name="LoopbackOnly"/> (demo mode, tests): 127.0.0.1 only, any free port, a certificate made for the run.
/// </summary>
public sealed record PhoneEnvironment(IPhoneHost Host, IShareNetworks Networks, IShareCertificates Certificates, int Port = PhoneScan.DefaultPort, bool LoopbackOnly = false)
{
    public static PhoneEnvironment ThisPcOnly(IPhoneHost host) => new(host, NoNetworks.Instance, RunCertificates.Instance, 0, true);

    private sealed class NoNetworks : IShareNetworks
    {
        public static readonly NoNetworks Instance = new();

        public IReadOnlyList<LocalNetwork> Read() => [];

        public event Action? Changed
        {
            add { }
            remove { }
        }
    }

    private sealed class RunCertificates : IShareCertificates
    {
        public static readonly RunCertificates Instance = new();

        public X509Certificate2 Get(string hostName, DateTimeOffset now) => ShareCertificate.Ephemeral(hostName, now);
    }
}

/// <summary>An open phone scan: the session, the address its QR code holds, and the certificate's fingerprint. Disposing closes the port at once.</summary>
public sealed class PhoneLink : IAsyncDisposable
{
    private readonly IShareListener _listener;
    private readonly X509Certificate2 _certificate;
    private int _closed;

    internal PhoneLink(PhoneSession session, string url, IShareListener listener, X509Certificate2 certificate)
    {
        Session = session;
        Url = url;
        _listener = listener;
        _certificate = certificate;
        Fingerprint = ShareCertificate.Fingerprint(certificate);
    }

    public PhoneSession Session { get; }

    /// <summary>The page's address: https, this PC's address on the private network, the port and the one-time path.</summary>
    public string Url { get; }

    public string Fingerprint { get; }

    /// <summary>The QR code of <see cref="Url"/>, true for dark, <c>[row, column]</c>, without its quiet zone.</summary>
    public bool[,] Qr() => Imaging.QrCodes.Modules(Url, high: false);

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _closed, 1) != 0) return;
        Session.Finish();
        try
        {
            await _listener.DisposeAsync().ConfigureAwait(false);
        }
        finally
        {
            _certificate.Dispose();
        }
    }
}

/// <summary>What opening a phone scan gave: the link, or why there's none in plain words.</summary>
public sealed record PhoneOpening(PhoneLink? Link, string? Problem);

/// <summary>
/// Phone as a scanner over the home network (roadmap 4.6): opens a <see cref="PhoneSession"/> on its own HTTPS port
/// (<see cref="DefaultPort"/>), with scanner sharing's rules (3.1): only on networks Windows calls Private, only to devices on their
/// own subnets that came in on that interface (<see cref="SharePeers"/>), its certificate (<see cref="ShareCertificate"/>). The port
/// is open only while a phone scan is (the app opens it for one scan and closes it when the scan ends or the window closes).
/// </summary>
public static class PhoneScan
{
    /// <summary>The port (TCP, HTTPS); the packaged app's firewall rule opens it for private networks. Scanner sharing has 9780.</summary>
    public const int DefaultPort = 9781;

    /// <summary>The PC's line about the phone: waiting for it, connected, how many pages it sent, finished.</summary>
    public static string StatusText(PhoneState state, int received) => state switch
    {
        PhoneState.Waiting => CoreStrings.Phone_StatusWaiting,
        PhoneState.Paired when received == 0 => CoreStrings.Phone_StatusConnected,
        PhoneState.Paired => Plural.Of(received, CoreStrings.Phone_StatusReceived_One, CoreStrings.Phone_StatusReceived_Many),
        _ => Plural.Of(received, CoreStrings.Phone_StatusFinished_One, CoreStrings.Phone_StatusFinished_Many),
    };

    /// <summary>The address a phone reaches this PC at: the first IPv4 address of a served network (lowest interface number), or null.</summary>
    public static IPAddress? AddressFor(IReadOnlyList<LocalNetwork> served) =>
        served.Where(n => n.Address.AddressFamily == AddressFamily.InterNetwork).OrderBy(n => n.InterfaceIndex).ThenBy(n => n.Address.ToString(), StringComparer.Ordinal)
            .Select(n => n.Address).FirstOrDefault();

    /// <summary>The page's address for <paramref name="address"/> and <paramref name="port"/>.</summary>
    public static string UrlFor(IPAddress address, int port, PhoneSession session) =>
        $"https://{(address.AddressFamily == AddressFamily.InterNetworkV6 ? $"[{address}]" : address.ToString())}:{port}{session.PagePath}";

    /// <summary>Opens a phone scan, or says why it can't (no private network, the port taken, the server didn't start).</summary>
    /// <param name="log">Told what happens, in plain words: never a device's address or the code.</param>
    public static async Task<PhoneOpening> OpenAsync(PhoneEnvironment env, string computerName, PhoneLimits? limits = null, Action<string>? log = null,
        TimeProvider? time = null, CancellationToken ct = default)
    {
        log ??= _ => { };
        IReadOnlyList<LocalNetwork> served = [];
        IPAddress? shown = IPAddress.Loopback;
        if (!env.LoopbackOnly)
        {
            try
            {
                served = SharePeers.Served(env.Networks.Read());
            }
            catch (Exception ex) // can't tell: serve nobody
            {
                log($"Phone scan: this PC's networks couldn't be read: {ex.Message}");
            }
            shown = AddressFor(served);
            if (shown is null) return new PhoneOpening(null, CoreStrings.Phone_NoPrivateNetwork);
        }
        X509Certificate2? certificate = null;
        IShareListener? listener = null;
        try
        {
            certificate = env.Certificates.Get(ShareDnssd.HostName(computerName), (time ?? TimeProvider.System).GetUtcNow());
            var session = new PhoneSession(computerName, limits);
            var loopback = env.LoopbackOnly;
            listener = await env.Host.StartAsync(new PhoneListen(loopback ? IPAddress.Loopback : IPAddress.IPv6Any, env.Port, certificate,
                (peer, local) => loopback ? IPAddress.IsLoopback(SharePeers.Normal(peer)) : SharePeers.Allows(peer, local, served), session), ct).ConfigureAwait(false);
            var port = listener.Port;
            log($"Phone scan: listening on port {port} ({(loopback ? "this PC only" : $"{served.Count} private network address(es)")}).");
            var link = new PhoneLink(session, UrlFor(shown, port, session), listener, certificate);
            (listener, certificate) = (null, null); // the link's now: it closes them
            return new PhoneOpening(link, null);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            await CloseAsync(listener, certificate, log).ConfigureAwait(false);
            log($"Phone scan didn't start: {ex.GetType().Name}: {ex.Message}");
            var inUse = ex is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse } || ex.InnerException is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse };
            return new PhoneOpening(null, inUse ? string.Format(CoreStrings.Phone_PortInUse, env.Port) : CoreStrings.Phone_Failed);
        }
        catch
        {
            await CloseAsync(listener, certificate, log).ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>What a failed open had opened, closed: nothing is left listening.</summary>
    private static async Task CloseAsync(IShareListener? listener, X509Certificate2? certificate, Action<string> log)
    {
        try
        {
            if (listener is not null) await listener.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            log($"Phone scan: not closed cleanly: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            certificate?.Dispose();
        }
    }
}
