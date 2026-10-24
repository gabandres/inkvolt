using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using InkvoltPrint.Core.Net;

namespace InkvoltPrint.Tests;

/// <summary>
/// Certificate pins are per TLS port: a printer may use one certificate for its web server (443) and another for IPPS
/// (631). Real TLS handshakes against throwaway servers on this PC's loopback address (no LAN, no printer).
/// </summary>
public class CertificatePinTests
{
    [Fact]
    public async Task Each_port_keeps_its_own_pin()
    {
        using var web = new TlsServer(SelfSigned());
        using var ipps = new TlsServer(SelfSigned());
        var pins = new MemoryPins();
        using var http = new DeviceHttp("127.0.0.1", pin: pins);

        Assert.Equal(HttpStatusCode.OK, (await http.GetAsync(web.Url)).StatusCode);
        Assert.Equal(HttpStatusCode.OK, (await http.GetAsync(ipps.Url)).StatusCode); // a different certificate, another port: fine
        Assert.Equal(HttpStatusCode.OK, (await http.GetAsync(web.Url)).StatusCode);

        Assert.False(http.CertificateChanged);
        Assert.Equal(web.Thumbprint, pins.Get(web.Port));
        Assert.Equal(ipps.Thumbprint, pins.Get(ipps.Port));
    }

    [Fact]
    public async Task A_changed_certificate_on_one_port_is_refused_without_touching_the_other()
    {
        using var web = new TlsServer(SelfSigned());
        using var ipps = new TlsServer(SelfSigned());
        var pins = new MemoryPins();
        pins.SetIfAbsent(ipps.Port, "00"); // pinned earlier to another certificate
        using var http = new DeviceHttp("127.0.0.1", pin: pins);

        await Assert.ThrowsAsync<HttpRequestException>(() => http.GetAsync(ipps.Url));
        Assert.True(http.CertificateChanged);
        Assert.Equal(HttpStatusCode.OK, (await http.GetAsync(web.Url)).StatusCode);
        Assert.Equal("00", pins.Get(ipps.Port));
    }

    [Fact]
    public async Task One_use_writes_keep_the_pin_and_a_changed_certificate_fails_before_sending()
    {
        using var web = new TlsServer(SelfSigned());
        var pins = new MemoryPins();
        using var http = new DeviceHttp("127.0.0.1", pin: pins);

        using (var first = new HttpRequestMessage(HttpMethod.Get, web.Url))
            Assert.Equal(HttpStatusCode.OK, (await http.SendOnceAsync(first)).StatusCode);
        Assert.Equal(web.Thumbprint, pins.Get(web.Port));

        using var changed = new TlsServer(SelfSigned());
        pins.SetIfAbsent(changed.Port, "00");
        using var refused = new HttpRequestMessage(HttpMethod.Get, changed.Url);
        var ex = await Assert.ThrowsAsync<HttpRequestException>(() => http.SendOnceAsync(refused));
        Assert.Contains(Inner(ex), e => e is System.Security.Authentication.AuthenticationException); // MaintenanceClient: "Not sent"
    }

    private static IEnumerable<Exception> Inner(Exception ex)
    {
        for (var e = ex.InnerException; e is not null; e = e.InnerException) yield return e;
    }

    [Fact]
    public void Pins_stored_before_ports_were_told_apart_stay_the_web_servers()
    {
        const string id = "12345678-1234-4abc-8def-123456789abc";
        Assert.Equal(id, CertificatePinKey.For(id, 443));
        Assert.Equal(id + ":631", CertificatePinKey.For(id, 631));
        Assert.True(CertificatePinKey.Belongs(id, id));
        Assert.True(CertificatePinKey.Belongs(id + ":631", id));
        Assert.False(CertificatePinKey.Belongs("12345678-1234-4abc-8def-123456789abd:631", id));
    }

    [Fact]
    public void The_admin_password_goes_only_to_the_web_server_port()
    {
        using var http = new DeviceHttp("192.0.2.11", new Echo());
        http.SetCredentials("admin", "secret");

        Assert.True(Sent(http, "https://192.0.2.11/DevMgmt/x.xml"));
        Assert.False(Sent(http, "https://192.0.2.11:631/ipp/print"));
        Assert.False(Sent(http, "http://192.0.2.11/DevMgmt/x.xml"));
    }

    private static bool Sent(DeviceHttp http, string url)
    {
        using var req = new HttpRequestMessage(HttpMethod.Get, url);
        using var _ = http.SendAsync(req).GetAwaiter().GetResult();
        return req.Headers.Authorization is not null;
    }

    private sealed class Echo : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { RequestMessage = request });
    }

    private static X509Certificate2 SelfSigned()
    {
        using var key = RSA.Create(2048);
        var req = new CertificateRequest("CN=127.0.0.1", key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        using var cert = req.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(1));
        // Schannel can't serve an ephemeral key: round-trip through PFX.
        return X509CertificateLoader.LoadPkcs12(cert.Export(X509ContentType.Pfx), null);
    }

    private sealed class MemoryPins : ICertificatePin
    {
        private readonly Dictionary<int, string> _pins = [];
        public string? Get(int port) { lock (_pins) return _pins.GetValueOrDefault(port); }
        public string SetIfAbsent(int port, string sha256Hex) { lock (_pins) return _pins.TryAdd(port, sha256Hex) ? sha256Hex : _pins[port]; }
    }

    /// <summary>A minimal HTTPS server on 127.0.0.1 answering every request with 200 "ok".</summary>
    private sealed class TlsServer : IDisposable
    {
        private readonly TcpListener _listener = new(IPAddress.Loopback, 0);
        private readonly X509Certificate2 _cert;
        private readonly CancellationTokenSource _stop = new();

        public TlsServer(X509Certificate2 cert)
        {
            _cert = cert;
            _listener.Start();
            _ = Task.Run(AcceptAsync);
        }

        public int Port => ((IPEndPoint)_listener.LocalEndpoint).Port;
        public Uri Url => new($"https://127.0.0.1:{Port}/");
        public string Thumbprint => Convert.ToHexString(SHA256.HashData(_cert.GetRawCertData()));

        private async Task AcceptAsync()
        {
            while (!_stop.IsCancellationRequested)
            {
                TcpClient client;
                try { client = await _listener.AcceptTcpClientAsync(_stop.Token); }
                catch (Exception) { return; }
                _ = Task.Run(() => ServeAsync(client));
            }
        }

        private async Task ServeAsync(TcpClient client)
        {
            using var _ = client;
            try
            {
                await using var tls = new SslStream(client.GetStream());
                await tls.AuthenticateAsServerAsync(_cert);
                var buffer = new byte[4096];
                var request = new StringBuilder();
                while (!request.ToString().Contains("\r\n\r\n", StringComparison.Ordinal))
                {
                    var n = await tls.ReadAsync(buffer);
                    if (n == 0) return;
                    request.Append(Encoding.ASCII.GetString(buffer, 0, n));
                }
                await tls.WriteAsync("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok"u8.ToArray());
            }
            catch (Exception)
            {
                // The client refused the certificate or went away.
            }
        }

        public void Dispose()
        {
            _stop.Cancel();
            _listener.Stop();
            _cert.Dispose();
        }
    }
}
