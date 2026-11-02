using System.Formats.Asn1;
using System.Net;
using System.Net.Sockets;
using System.Numerics;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// A whole certificate authority on this PC's loopback, for tests: a generated root, an intermediate, a signer and a
/// timestamp authority, with an OCSP responder, CRLs, issuer certificates and an RFC 3161 server behind the addresses
/// those certificates name. Nothing here needs the internet. Each path can be overridden to misbehave.
/// </summary>
internal sealed class LtvTestPki : IDisposable
{
    private readonly TcpListener _listener;
    private readonly CancellationTokenSource _stop = new();
    /// <summary>Keys are slow to make and these tests make many authorities, so they share a few: each authority's certificates use different ones.</summary>
    private static readonly Lazy<RSA>[] Keys = [.. Enumerable.Range(0, 8).Select(_ => new Lazy<RSA>(() => RSA.Create(2048)))];
    private int _nextKey;
    private readonly Dictionary<string, (BigInteger Serial, DateTimeOffset At)> _revoked = [];
    private readonly List<string> _hits = [];
    private BigInteger _nextSerial = 1000;

    public X509Certificate2 Root { get; }
    public X509Certificate2 Intermediate { get; }
    public X509Certificate2 Signer { get; }
    public X509Certificate2 Tsa { get; }
    public X509Certificate2 Responder { get; }
    public string BaseUrl { get; }

    /// <summary>When set, OCSP answers are signed by the delegated responder instead of the issuer.</summary>
    public bool DelegateOcsp { get; set; }

    /// <summary>Requests by path, as they arrive.</summary>
    public IReadOnlyList<string> Hits
    {
        get
        {
            lock (_hits) return [.. _hits];
        }
    }

    /// <summary>Stands in for a path: what it answers instead (raw HTTP response bytes).</summary>
    public Dictionary<string, Func<byte[], Task<byte[]>>> Overrides { get; } = [];

    public X509Certificate2Collection Anchors => [Root];

    /// <summary>A client that may reach this PC's loopback, as nothing else may.</summary>
    public LtvClient Client(TimeSpan? timeout = null) => new(allowLoopback: true, timeout: timeout, allowHttpTimestamp: true);

    public string TimestampUrl => $"{BaseUrl}/tsa";

    public LtvTestPki()
    {
        _listener = new TcpListener(IPAddress.Loopback, 0);
        _listener.Start();
        BaseUrl = $"http://127.0.0.1:{((IPEndPoint)_listener.LocalEndpoint).Port}";
        _ = AcceptLoop();

        Root = Issue("CN=Test Root CA,O=Inkvolt Tests,C=PR", null, ca: true, urls: false);
        Intermediate = Issue("CN=Test Intermediate CA,O=Inkvolt Tests,C=PR", Root, ca: true);
        Signer = Issue("CN=Test Long-Term Signer,O=Inkvolt Tests,C=PR", Intermediate, ca: false, ku: X509KeyUsageFlags.NonRepudiation | X509KeyUsageFlags.DigitalSignature);
        Tsa = Issue("CN=Test Timestamp Authority,O=Inkvolt Tests,C=PR", Root, ca: false, ku: X509KeyUsageFlags.DigitalSignature, eku: "1.3.6.1.5.5.7.3.8");
        Responder = Issue("CN=Test OCSP Responder,O=Inkvolt Tests,C=PR", Intermediate, ca: false, ku: X509KeyUsageFlags.DigitalSignature, eku: CertFactsEkuOcsp, noCheck: true, urls: false);
    }

    private const string CertFactsEkuOcsp = "1.3.6.1.5.5.7.3.9";

    /// <summary>A certificate from this authority (from <paramref name="issuer"/>, self-signed when null), naming this server's addresses unless told otherwise.</summary>
    public X509Certificate2 Issue(string subject, X509Certificate2? issuer, bool ca = false, X509KeyUsageFlags? ku = null, string? eku = null, bool noCheck = false, bool urls = true,
        IEnumerable<string>? ocsp = null, IEnumerable<string>? crl = null, IEnumerable<string>? issuers = null)
    {
        var key = Keys[_nextKey++ % Keys.Length].Value;
        var req = new CertificateRequest(subject, key, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        req.CertificateExtensions.Add(new X509BasicConstraintsExtension(ca, false, 0, true));
        req.CertificateExtensions.Add(new X509KeyUsageExtension(ku ?? (ca ? X509KeyUsageFlags.KeyCertSign | X509KeyUsageFlags.CrlSign : X509KeyUsageFlags.DigitalSignature), true));
        if (eku is not null) req.CertificateExtensions.Add(new X509EnhancedKeyUsageExtension([new Oid(eku)], critical: true));
        req.CertificateExtensions.Add(new X509SubjectKeyIdentifierExtension(req.PublicKey, false));
        if (issuer is not null)
        {
            req.CertificateExtensions.Add(X509AuthorityKeyIdentifierExtension.CreateFromCertificate(issuer, includeKeyIdentifier: true, includeIssuerAndSerial: false));
            var issuerId = Id(issuer);
            ocsp ??= urls ? [$"{BaseUrl}/ocsp"] : [];
            crl ??= urls ? [$"{BaseUrl}/crl/{issuerId}.crl"] : [];
            issuers ??= urls ? [$"{BaseUrl}/cert/{issuerId}.cer"] : [];
            if (ocsp.Any() || issuers.Any()) req.CertificateExtensions.Add(new X509AuthorityInformationAccessExtension(ocsp, issuers));
            if (crl.Any()) req.CertificateExtensions.Add(CertificateRevocationListBuilder.BuildCrlDistributionPointExtension(crl));
        }
        if (noCheck) req.CertificateExtensions.Add(new X509Extension("1.3.6.1.5.5.7.48.1.5", [0x05, 0x00], false));
        var from = DateTimeOffset.UtcNow.AddDays(-30);
        var to = issuer is null ? DateTimeOffset.UtcNow.AddYears(5) : new DateTimeOffset(issuer.NotAfter.ToUniversalTime(), TimeSpan.Zero).AddDays(-1);
        X509Certificate2 cert;
        if (issuer is null) cert = req.CreateSelfSigned(from, to);
        else
        {
            var serial = (_nextSerial++).ToByteArray(isBigEndian: true);
            using var plain = req.Create(issuer, from, to, serial);
            cert = plain.CopyWithPrivateKey(key);
        }
        lock (_issued) _issued[Id(cert)] = cert;
        return cert;
    }

    private readonly Dictionary<string, X509Certificate2> _issued = [];

    private static string Id(X509Certificate2 c) => c.Thumbprint;

    /// <summary>From now on the OCSP responder and the CRL say this certificate was revoked at that time.</summary>
    public void Revoke(X509Certificate2 cert, DateTimeOffset at)
    {
        lock (_revoked) _revoked[cert.SerialNumber] = (new BigInteger(Convert.FromHexString(cert.SerialNumber), isUnsigned: false, isBigEndian: true), at);
    }

    /// <summary>The server's CA answer for a certificate's issuer.</summary>
    private X509Certificate2? IssuerOf(byte[] nameHash)
    {
        lock (_issued)
            return _issued.Values.FirstOrDefault(c => SHA1.HashData(c.SubjectName.RawData).AsSpan().SequenceEqual(nameHash));
    }

    /// <summary>An OCSP reply to a request, as this authority's responder writes it.</summary>
    public byte[] OcspReply(byte[] request, RSA? forgedKey = null, DateTimeOffset? thisUpdate = null)
    {
        var req = new AsnReader(request, AsnEncodingRules.DER).ReadSequence().ReadSequence().ReadSequence().ReadSequence();
        var certId = req.ReadSequence();
        var encodedId = new AsnReader(request, AsnEncodingRules.DER).ReadSequence().ReadSequence().ReadSequence().ReadSequence().ReadEncodedValue();
        certId.ReadEncodedValue();
        var issuerNameHash = certId.ReadOctetString();
        certId.ReadOctetString();
        var serial = certId.ReadInteger();
        var issuer = IssuerOf(issuerNameHash) ?? throw new InvalidOperationException("Unknown issuer asked about");
        var signer = DelegateOcsp && issuer.Thumbprint == Intermediate.Thumbprint ? Responder : issuer;
        var key = signer.GetRSAPrivateKey()!;
        var now = thisUpdate ?? DateTimeOffset.UtcNow;

        var tbs = new AsnWriter(AsnEncodingRules.DER);
        using (tbs.PushSequence())
        {
            using (tbs.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 2, true)))
                tbs.WriteOctetString(SHA1.HashData(signer.PublicKey.EncodedKeyValue.RawData));
            tbs.WriteGeneralizedTime(now, omitFractionalSeconds: true);
            using (tbs.PushSequence())
            using (tbs.PushSequence())
            {
                tbs.WriteEncodedValue(encodedId.Span);
                (BigInteger Serial, DateTimeOffset At)? hit = null;
                lock (_revoked)
                    foreach (var r in _revoked.Values)
                        if (r.Serial == serial)
                            hit = r;
                if (hit is { } revoked)
                    using (tbs.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 1, true)))
                        tbs.WriteGeneralizedTime(revoked.At, omitFractionalSeconds: true);
                else tbs.WriteNull(new Asn1Tag(TagClass.ContextSpecific, 0));
                tbs.WriteGeneralizedTime(now, omitFractionalSeconds: true);
                using (tbs.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)))
                    tbs.WriteGeneralizedTime(now.AddDays(7), omitFractionalSeconds: true);
            }
        }
        var tbsDer = tbs.Encode();
        var sig = (forgedKey ?? key).SignData(tbsDer, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);

        var basic = new AsnWriter(AsnEncodingRules.DER);
        using (basic.PushSequence())
        {
            basic.WriteEncodedValue(tbsDer);
            using (basic.PushSequence())
            {
                basic.WriteObjectIdentifier("1.2.840.113549.1.1.11");
                basic.WriteNull();
            }
            basic.WriteBitString(sig);
            if (!ReferenceEquals(signer, issuer))
                using (basic.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)))
                using (basic.PushSequence())
                    basic.WriteEncodedValue(signer.RawData);
        }
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteEnumeratedValue(LtvOcspStatus.Successful);
            using (w.PushSequence(new Asn1Tag(TagClass.ContextSpecific, 0, true)))
            using (w.PushSequence())
            {
                w.WriteObjectIdentifier("1.3.6.1.5.5.7.48.1.1");
                w.WriteOctetString(basic.Encode());
            }
        }
        return w.Encode();
    }

    private enum LtvOcspStatus { Successful = 0 }

    /// <summary>An OCSP request as the app writes one, for feeding <see cref="OcspReply"/> directly.</summary>
    public static byte[] OcspRequest(X509Certificate2 cert, X509Certificate2 issuer) => OcspResponse.Request(cert, issuer);

    /// <summary>The issuer's CRL now, listing what was revoked.</summary>
    public byte[] Crl(X509Certificate2 issuer)
    {
        var b = new CertificateRevocationListBuilder();
        lock (_revoked)
            foreach (var (serial, at) in _revoked.Values)
                b.AddEntry(serial.ToByteArray(isBigEndian: true), at);
        var now = DateTimeOffset.UtcNow;
        return b.Build(issuer, 1, now.AddDays(7), HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1, now.AddSeconds(-1));
    }

    /// <summary>An RFC 3161 reply from the test authority.</summary>
    public byte[] TimestampReply(byte[] requestDer)
    {
        Assert.True(Rfc3161TimestampRequest.TryDecode(requestDer, out var request, out _));
        var w = new AsnWriter(AsnEncodingRules.DER);
        using (w.PushSequence())
        {
            w.WriteInteger(1);
            w.WriteObjectIdentifier("1.2.3.4.5");
            using (w.PushSequence())
            {
                using (w.PushSequence()) w.WriteObjectIdentifier(request!.HashAlgorithmId.Value!);
                w.WriteOctetString(request.GetMessageHash().Span);
            }
            w.WriteInteger(RandomNumberGenerator.GetInt32(1, int.MaxValue));
            w.WriteGeneralizedTime(DateTimeOffset.UtcNow, omitFractionalSeconds: true);
            if (request.GetNonce() is { } nonce) w.WriteInteger(nonce.Span);
        }
        var cms = new SignedCms(new ContentInfo(new Oid("1.2.840.113549.1.9.16.1.4"), w.Encode()));
        var signer = new CmsSigner(SubjectIdentifierType.IssuerAndSerialNumber, Tsa) { DigestAlgorithm = new Oid("2.16.840.1.101.3.4.2.1"), IncludeOption = X509IncludeOption.EndCertOnly };
        signer.Certificates.Add(Root);
        signer.SignedAttributes.Add(new AsnEncodedData(Signing.SigningCertificateV2Oid, Signing.SigningCertificateV2(Tsa, HashAlgorithmName.SHA256)));
        cms.ComputeSignature(signer);
        var r = new AsnWriter(AsnEncodingRules.DER);
        using (r.PushSequence())
        {
            using (r.PushSequence()) r.WriteInteger(0);
            r.WriteEncodedValue(cms.Encode());
        }
        return r.Encode();
    }

    /// <summary>A request as a server sends it: status line, headers, body.</summary>
    public static byte[] Http(int status, byte[] body, params string[] headers)
    {
        var head = new StringBuilder($"HTTP/1.1 {status} X\r\nContent-Length: {body.Length}\r\nConnection: close\r\n");
        foreach (var h in headers) head.Append(h).Append("\r\n");
        head.Append("\r\n");
        return [.. Encoding.ASCII.GetBytes(head.ToString()), .. body];
    }

    private async Task AcceptLoop()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                var client = await _listener.AcceptTcpClientAsync(_stop.Token);
                _ = Serve(client);
            }
        }
        catch (Exception ex) when (ex is OperationCanceledException or SocketException or ObjectDisposedException)
        {
            // Stopped.
        }
    }

    private async Task Serve(TcpClient client)
    {
        using (client)
        {
            try
            {
                var stream = client.GetStream();
                var (path, body) = await ReadRequest(stream);
                lock (_hits) _hits.Add(path);
                var reply = await Answer(path, body);
                await stream.WriteAsync(reply);
                await stream.FlushAsync();
            }
            catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException or AsnContentException or InvalidOperationException or KeyNotFoundException)
            {
                // A client gone, or a request the test didn't mean.
            }
        }
    }

    private static async Task<(string Path, byte[] Body)> ReadRequest(NetworkStream stream)
    {
        var buffer = new List<byte>();
        var chunk = new byte[4096];
        int headerEnd;
        while ((headerEnd = IndexOfHeaderEnd(buffer)) < 0)
        {
            var n = await stream.ReadAsync(chunk);
            if (n == 0) throw new IOException("Closed early");
            buffer.AddRange(chunk.AsSpan(0, n));
        }
        var head = Encoding.ASCII.GetString(buffer.ToArray(), 0, headerEnd);
        var path = head.Split(' ', 3)[1];
        var length = 0;
        foreach (var line in head.Split("\r\n"))
            if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase)) length = int.Parse(line["Content-Length:".Length..].Trim());
        var total = headerEnd + 4 + length;
        while (buffer.Count < total)
        {
            var n = await stream.ReadAsync(chunk);
            if (n == 0) break;
            buffer.AddRange(chunk.AsSpan(0, n));
        }
        return (path, buffer.Skip(headerEnd + 4).Take(length).ToArray());
    }

    private static int IndexOfHeaderEnd(List<byte> b)
    {
        for (var i = 0; i + 3 < b.Count; i++)
            if (b[i] == '\r' && b[i + 1] == '\n' && b[i + 2] == '\r' && b[i + 3] == '\n') return i;
        return -1;
    }

    private async Task<byte[]> Answer(string path, byte[] body)
    {
        if (Overrides.TryGetValue(path, out var over)) return await over(body);
        if (path == "/ocsp") return Http(200, OcspReply(body), "Content-Type: application/ocsp-response");
        if (path == "/tsa") return Http(200, TimestampReply(body), "Content-Type: application/timestamp-reply");
        if (path.StartsWith("/crl/", StringComparison.Ordinal))
        {
            X509Certificate2 issuer;
            lock (_issued) issuer = _issued[path["/crl/".Length..^".crl".Length]];
            return Http(200, Crl(issuer));
        }
        if (path.StartsWith("/cert/", StringComparison.Ordinal))
        {
            X509Certificate2 cert;
            lock (_issued) cert = _issued[path["/cert/".Length..^".cer".Length]];
            return Http(200, cert.RawData);
        }
        return Http(404, []);
    }

    public void Dispose()
    {
        _stop.Cancel();
        _listener.Stop();
    }
}
